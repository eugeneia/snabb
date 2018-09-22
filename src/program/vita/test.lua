-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local vita = require("program.vita.vita")
local worker = require("core.worker")
local counter = require("core.counter")
local lib = require("core.lib")
local CPUSet = require("lib.cpuset")
local get_monotonic_time = require("ffi").C.get_monotonic_time
local loadgen = require("apps.lwaftr.loadgen")
local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")
local yang = require("lib.yang.yang")


-- Testing apps for Vita

TrafficPattern = {}

function TrafficPattern:new (testconf)
   return setmetatable({ packets = gen_packets(testconf) },
      { __index = TrafficPattern })
end

function TrafficPattern:pull ()
   while #self.packets > 0 and not link.full(self.output.output) do
      link.transmit(self.output.output, table.remove(self.packets, 1))
   end
end

function TrafficPattern:stop ()
   while #self.packets > 0 do
      packet.free(table.remove(self.packets))
   end
end

GaugeThroughput = {
   config = {
      name = {default="GaugeThroughput"},
      loadgen_name = {required=true},
      accuracy = {default=0.01},
      attempts = {default=25},
      rate = {default=100e6}, -- 100 Mbps
      exit_on_completion = {default=false}
   }
}

function GaugeThroughput:new (conf)
   local self = setmetatable(conf, { __index = GaugeThroughput })
   self.report = lib.logger_new({module=self.name})
   self.progress_throttle = lib.throttle(1)
   self.gauge_throttle = lib.throttle(0.05)
   self.retry = 0
   self:init{start=false}
   return self
end

function GaugeThroughput:push ()
   local input, output = self.input.input, self.output.output
   while not link.empty(input) do
      local p = link.receive(input)
      self:count(p)
      packet.free(p)
   end
   if self.progress_throttle() then
      self:progress()
   end
   if self.gauge_throttle() and self:gauge() then
      if self.exit_on_completion then
         main.exit()
      end
   end
end

function GaugeThroughput:progress ()
   local loss =  self:get_loss()
   if self.start then
      local runtime = get_monotonic_time() - self.start
      local pps = self.packets / runtime
      local bps = self.bits / runtime
      self.report:log(("%.3f Mpps / %.3f Gbps (on GbE) / %.2f %%loss"):
            format(pps / 1e6, bps / 1e9, math.max(0, loss) * 100))
   else
      self.report:log(("- Mpps / - Gbps (on GbE) / %.2f %%loss"):
            format(math.max(0, loss) * 100))
   end
end

function GaugeThroughput:gauge ()
   -- Exempt warmup packets from gauge.
   if not self.start and self.packets > engine.pull_npackets*2 then
      self:set_rate(self.rate)
      self:init{start=true}
   -- Gauge throughput.
   elseif self.start then
      local loss = self:get_loss()
      if loss < self.accuracy then
         self:set_rate(self.rate * (1 + self.accuracy))
         self.retry = 0
      else
         self.retry = self.retry + 1
      end
      if self.retry >= self.attempts then
         return true
      end
      self:init{start=true}
   end
end

function GaugeThroughput:init (opt)
   self.start = opt.start and get_monotonic_time()
   self.txpackets = (opt.start and self:get_txpackets()) or 0
   self.packets, self.bits = 0, 0
end

function GaugeThroughput:count (p)
   self.packets = self.packets + 1
   self.bits = self.bits + packet.physical_bits(p)
end

function GaugeThroughput:get_txpackets ()
   local txlink = link.stats(engine.app_table[self.loadgen_name].output.output)
   return txlink.rxpackets
end

function GaugeThroughput:get_loss ()
   return 1 - self.packets / (self:get_txpackets() - self.txpackets)
end

function GaugeThroughput:set_rate (rate)
   engine.app_table[self.loadgen_name]:set_rate(rate)
   self.rate = rate
end


-- Testing setups for Vita

-- Run Vita in software benchmark mode.
function run_softbench (pktsize, tolerance, nroutes, cpuspec)
   local testconf = {
      private_interface = {
         nexthop_mac = private_interface_defaults.mac.default
      },
      packet_size = pktsize,
      nroutes = nroutes,
      negotiation_ttl = nroutes
   }

   local function configure_private_router_softbench (conf)
      local c, private = vita.configure_private_router(conf)

      config.app(c, "traffic", TrafficPattern, testconf)
      config.app(c, "loadgen", loadgen.RateLimitedRepeater, {})
      config.link(c, "traffic.output -> loadgen.input")

      config.app(c, "gauge", GaugeThroughput, {
                    name = "SoftBench",
                    loadgen_name = "loadgen",
                    accuracy = tolerance,
                    exit_on_completion = true
      })

      if private then
         config.link(c, "loadgen.output -> "..private.input)
         config.link(c, private.output.." -> gauge.input")
      end

      return c
   end

   local function softbench_workers (conf)
      return {
         key_manager = vita.configure_exchange(conf),
         inbound_gauge_router = configure_private_router_softbench(conf),
         outbound_loopback_router = configure_public_router_loopback(conf),
         encapsulate = vita.configure_esp(conf),
         decapsulate =  vita.configure_dsp(conf)
      }
   end

   local function wait_gauge ()
      if not worker.status().inbound_gauge_router.alive then
         main.exit()
      end
   end
   timer.activate(timer.new('wait_gauge', wait_gauge, 1e9/10, 'repeating'))

   local cpuset = CPUSet:new()
   if cpuspec then
      CPUSet.global_cpuset():add_from_string(cpuspec)
   end

   vita.run_vita{
      setup_fn = softbench_workers,
      initial_configuration = gen_configuration(testconf),
      cpuset = cpuspec and CPUSet:new():add_from_string(cpuspec)
   }
end

function configure_public_router_loopback (conf, append)
   local c, public = vita.configure_public_router(conf, append)

   if not conf.public_interface then return c end

   config.link(c, public.output.." -> "..public.input)

   return c
end


-- Test case generation for Vita via synthetic traffic and configurations.
-- Exposes configuration knobs like “number of routes” and “packet size”.
--
-- Produces a set of test packets and a matching vita-esp-gateway configuration
-- in loopback mode by default. I.e., potentially many routes to a single
-- destination.

defaults = {
   private_interface = {},
   public_interface = {},
   route_prefix = {default="172.16"},
   nroutes = {default=1},
   packet_size = {default="IMIX"},
   sa_ttl = {default=16},
   negotiation_ttl = {default=1}
}
private_interface_defaults = {
   pci = {default="00:00.0"},
   mac = {default="02:00:00:00:00:01"}, -- needed because used in sim. packets
   ip4 = {default="172.16.0.10"},
   nexthop_ip4 = {default="172.16.1.1"},
   nexthop_mac = {}
}
public_interface_defaults = {
   pci = {default="00:00.0"},
   mac = {},
   ip4 = {default="172.16.0.10"},
   nexthop_ip4 = {default="172.16.0.10"},
   nexthop_mac = {}
}

traffic_templates = {
   -- Internet Mix, see https://en.wikipedia.org/wiki/Internet_Mix
   IMIX = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }
}

local function parse_gentestconf (conf)
   conf = lib.parse(conf, defaults)
   conf.private_interface = lib.parse(conf.private_interface,
                                      private_interface_defaults)
   conf.public_interface = lib.parse(conf.public_interface,
                                     public_interface_defaults)
   assert(conf.nroutes >= 0 and conf.nroutes <= 255,
          "Invalid number of routes: "..conf.nroutes)
   return conf
end

function gen_packet (conf, route, size)
   local payload_size = size - ethernet:sizeof() - ipv4:sizeof()
   assert(payload_size >= 0, "Negative payload_size :-(")
   local d = datagram:new(packet.resize(packet.allocate(), payload_size))
   d:push(ipv4:new{ src = ipv4:pton(conf.private_interface.nexthop_ip4),
                    dst = ipv4:pton(conf.route_prefix.."."..route..".1"),
                    total_length = ipv4:sizeof() + payload_size,
                    ttl = 64 })
   d:push(ethernet:new{ dst = ethernet:pton(conf.private_interface.mac),
                        type = 0x0800 })
   local p = d:packet()
   -- Pad to minimum Ethernet frame size (excluding four octet CRC)
   return packet.resize(p, math.max(60, p.length))
end

-- Return simulation packets for test conf.
function gen_packets (conf)
   conf = parse_gentestconf(conf)
   local sim_packets = {}
   local sizes = traffic_templates[conf.packet_size]
              or {tonumber(conf.packet_size)}
   for _, size in ipairs(sizes) do
      for route = 1, conf.nroutes do
         table.insert(sim_packets, gen_packet(conf, route, size))
      end
   end
   return sim_packets
end

-- Return Vita config for test conf.
function gen_configuration (conf)
   conf = parse_gentestconf(conf)
   local cfg = {
      private_interface = conf.private_interface,
      public_interface = conf.public_interface,
      route = {},
      negotiation_ttl = conf.negotiation_ttl,
      sa_ttl = conf.sa_ttl
   }
   for route = 1, conf.nroutes do
      cfg.route["test"..route] = {
         net_cidr4 = conf.route_prefix.."."..route..".0/24",
         gw_ip4 = conf.public_interface.nexthop_ip4,
         preshared_key = string.rep("00", 32),
         spi = 1000+route
      }
   end
   return cfg
end

-- Include vita-gentest YANG schema.
yang.add_schema(require("program.vita.vita_gentest_yang",
                        "program/vita/vita-gentest.yang"))
schemata = {
   ['gentest'] = yang.load_schema_by_name('vita-gentest')
}
