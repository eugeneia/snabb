-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local vita = require("program.vita.vita")
local worker = require("core.worker")
local lib = require("core.lib")
local loadgen = require("apps.lwaftr.loadgen")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
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
      source_name = {required=true},
      accuracy = {default=.01},
      attempts = {default=30},
      initial_rate = {default=100e6}, -- 100 Mbps
      report_interval = {default=1},
      gauge_interval = {default=.05},
      plateau_duration = {default=5},
      exit_on_completion = {default=false}
   }
}

function GaugeThroughput:new (conf)
   local self = setmetatable(conf, { __index = GaugeThroughput })
   self.report = lib.logger_new({module=self.name})
   self.packets, self.bits = 0, 0, 0
   self:init()
   return self
end

function GaugeThroughput:init ()
   self.report_snapshot = self:snapshot()
   self.gauge_snapshot = self:snapshot()
   self.report_interval = lib.throttle(self.report_interval)
   self.gauge_interval = lib.throttle(self.gauge_interval)
   self.retry = 0
   self.gauge_state = 'warm_up'
end

function GaugeThroughput:push ()
   -- Accumulate RX stats.
   local input, output = self.input.input, self.output.output
   while not link.empty(input) do
      local p = link.receive(input)
      self.packets = self.packets + 1
      self.bits = self.bits + packet.physical_bits(p)
      packet.free(p)
   end
   -- Report throughput statistics.
   if self.report_interval() then
      self:report_rate()
   end
   -- Gauge partial drop rate (PDR).
   if self.gauge_interval() then
      GaugeThroughput[self.gauge_state](self) -- fsm
   end
end

function GaugeThroughput:report_rate ()
   local current = self:snapshot()
   local runtime, pps, bps, loss =
      self:delta_rate(self.report_snapshot, current)
   self.report:log(("%.0fs / %.3f Mpps / %.3f Gbps (GbE) / %.1f %%loss"):
         format(runtime, pps / 1e6, bps / 1e9, math.max(0, loss) * 100))
   self.report_snapshot = current
end

function GaugeThroughput:warm_up ()
   -- Wait for initial ARP, AKE, etc., then set initial_rate.
   if self.packets > engine.pull_npackets * 2 then
      self.gauge_state = 'find_limit'
      self.rate = self.initial_rate
      engine.app_table[self.source_name]:set_rate(self.rate)
   end
end

function GaugeThroughput:find_limit ()
   local current = self:snapshot()
   local _, _, _, loss = self:delta_rate(self.gauge_snapshot, current)
   -- Grow rate by accuracy...
   if loss < self.accuracy then
      self.rate = self.rate * (1 + self.accuracy)
      engine.app_table[self.source_name]:set_rate(self.rate)
      self.retry = 1
   else
      self.retry = self.retry + 1
   end
   self.gauge_snapshot = current
   -- ...until we reach the PDR ceiling.
   if self.retry > self.attempts then
      self.gauge_state = 'plateau1'
   end
end

function GaugeThroughput:plateau1 ()
   -- (undo last rate increases)
   self.rate = self.rate * (1 - self.accuracy * 2)
   engine.app_table[self.source_name]:set_rate(self.rate)
   self.gauge_snapshot = self:snapshot()
   self.gauge_interval = lib.timeout(self.plateau_duration / 4)
   self.gauge_state = 'plateau2'
end

function GaugeThroughput:plateau2 ()
   self:report_rate()
   -- Take final measurement with adjusted rate.
   local current = self:snapshot()
   local _, _, _, loss = self:delta_rate(self.gauge_snapshot, current)
   self.rate = self.rate * (1 - loss)
   engine.app_table[self.source_name]:set_rate(self.rate)
   self.gauge_interval = lib.timeout(self.plateau_duration)
   self.report_interval= self.gauge_interval
   self.gauge_state = 'complete'
end

function GaugeThroughput:complete ()
   -- Reset fsm (start new gauge). Possibly exit process.
   self:init()
   if self.exit_on_completion then
      main.exit()
   end
end

-- Get number of source packets emitted (depends on source app).
function GaugeThroughput:source_packets ()
   local source_app = engine.app_table[self.source_name]
   if source_app and source_app.output.output then
      local source_link = link.stats(source_app.output.output)
      return source_link.txpackets + source_link.txdrop
   else
      return 0
   end
end

-- Checkpoint throughput statistics.
function GaugeThroughput:snapshot ()
   return { now = engine.now(),
            txpackets = self:source_packets(),
            packets = self.packets,
            bits = self.bits }
end

-- Compute rate stats for delta.
function GaugeThroughput:delta_rate (t1, t2)
   local delta = {}
   for k, v in pairs(t1) do
      delta[k] = t2[k] - v
   end
   return delta.now,                          -- runtime
          delta.packets / delta.now,          -- pps
          delta.bits / delta.now,             -- bps
          1 - delta.packets / delta.txpackets -- loss%
end


-- Testing setups for Vita

-- Run Vita in software benchmark mode.
function run_softbench (testcfg, gaugecfg, cpuspec)
   local testconf = {
      private_interface = {
         nexthop_mac = private_interface_defaults.mac.default
      },
      packet_size = testcfg.packet_size,
      nroutes = testcfg.nroutes,
      sa_ttl = testcfg.sa_ttl,
      negotiation_ttl = testcfg.nroutes
   }

   local function configure_softbench_gauge ()
      local c = config.new()

      config.app(c, "traffic", TrafficPattern, testconf)
      config.app(c, "loadgen", loadgen.RateLimitedRepeater, {})
      config.link(c, "traffic.output -> loadgen.input")

      config.app(c, "gauge", GaugeThroughput, {
                    name = "SoftBench",
                    source_name = "loadgen",
                    accuracy = gaugecfg.accuracy,
                    initial_rate = gaugecfg.initial_rate,
                    plateau_duration = gaugecfg.plateau_duration,
                    attempts = 100, -- anti-noise
                    exit_on_completion = true
      })

      config.app(c, "softbench_in", Transmitter)
      config.link(c, "loadgen.output -> softbench_in.input")

      config.app(c, "softbench_out", Receiver)
      config.link(c, "softbench_out.output -> gauge.input")

      return c
   end

   local function softbench_workers (conf, cpuset)
      local gauge_cpu = table.remove(cpuset)
      local workers, attributes = vita.capsule_workers(conf, cpuset)
      workers.key_manager = vita.configure_exchange(conf)
      attributes.key_manager = {scheduling={cpu=cpuset[1]}}
      workers.private_gauge_router = configure_private_router_softbench(conf)
      attributes.private_gauge_router = {scheduling={cpu=cpuset[2]}}
      workers.public_loopback_router = configure_public_router_loopback(conf)
      attributes.public_loopback_router = {scheduling={cpu=cpuset[3]}}
      workers.softbench_gauge = configure_softbench_gauge()
      attributes.softbench_gauge = {scheduling={cpu=gauge_cpu}}
      return workers, attributes
   end

   local function wait_gauge ()
      if not worker.status().softbench_gauge.alive then
         main.exit()
      end
   end
   timer.activate(timer.new('wait_gauge', wait_gauge, 1e9/10, 'repeating'))

   local cpuset = {}
   if cpuspec then
      cpuset = vita.parse_cpuset(cpuspec)
   end

   vita.run_vita{
      setup_fn = softbench_workers,
      initial_configuration = gen_configuration(testconf),
      cpuset = cpuset
   }
end

function configure_private_router_softbench (conf)
   local c, private = vita.configure_private_router(conf)

   if private then
      config.app(c, "softbench_in", Receiver)
      config.link(c, "softbench_in.output -> "..private.input)
      config.app(c, "softbench_out", Transmitter)
      config.link(c, private.output.." -> softbench_out.input")
   end

   return c
end

function configure_public_router_loopback (conf, append)
   local c, public = vita.configure_public_router(conf, append)

   if public then
      config.link(c, public.output.." -> "..public.input)
   end

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
