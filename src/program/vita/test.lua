-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local lib = require("core.lib")
local worker = require("core.worker")
local vita = require("program.vita.vita")
local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local ethernet= require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")

-- sudo ./snabb snsh program/vita/test.lua [<pktsize>|IMIX] [<npackets>]
-- default is 10 million packets at IMIX                (-:

local IMIX = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }

function test_packets (pktsize)
   pktsize = pktsize ~= "IMIX" and tonumber(pktsize)
   local sizes = (pktsize and {pktsize}) or IMIX
   local packets = {}
   for _, size in ipairs(sizes) do
      local payload_size = size - ethernet:sizeof() - ipv4:sizeof()
      assert(payload_size >= 0, "Negative payload_size :-(")
      local d = datagram:new(packet.resize(packet.allocate(), payload_size))
      d:push(ipv4:new{ src = ipv4:pton("192.168.10.100"),
                       dst = ipv4:pton("192.168.10.200") })
      d:push(ethernet:new{ src = ethernet:pton("52:54:00:00:00:00"),
                           dst = ethernet:pton("52:54:00:00:00:00"),
                           type = 0x0800 })
      packets[#packets+1] = d:packet()
   end
   return packets
end


local c, private, public = vita.configure_router{
   private_nexthop = {mac="52:54:00:00:00:00"},
   public_nexthop = {mac="52:54:00:00:00:00"},
   node_ip4 = "192.168.10.1",
   routes = {
      {
         net_cidr4 = "192.168.10.0/24",
         gw_ip4 = "192.168.10.1",
         preshared_key = string.rep("00", 512)
      }
   }
}

config.link(c, public.output.." -> "..public.input)

config.app(c, "synth", Synth, {packets=test_packets(main.parameters[1]), backpressure=true})
config.link(c, "synth.output -> "..private.input)

config.app(c, "sink", basic_apps.Sink)
config.link(c, private.output.." -> sink.input")


engine.log = true
engine.configure(c)

worker.start("ESP", [[require("program.vita.vita").esp_worker()]])
worker.start("DSP", [[require("program.vita.vita").dsp_worker()]])


-- adapted from snabbnfv traffic

local npackets = tonumber(main.parameters[2]) or 10e6
local get_monotonic_time = require("ffi").C.get_monotonic_time
local counter = require("core.counter")
local start, packets, bytes = 0, 0, 0
local function done ()
   local input = link.stats(engine.app_table.sink.input.input)
   if start == 0 and input.txpackets > 0 then
      -- started receiving, record time and packet count
      packets = input.txpackets
      bytes = input.txbytes
      start = get_monotonic_time()
   end
   return input.txpackets - packets >= npackets
end

engine.main({done=done, report={showlinks=true}})
local finish = get_monotonic_time()

local runtime = finish - start
local breaths = tonumber(counter.read(engine.breaths))
local input = link.stats(engine.app_table.sink.input.input)
packets = input.txpackets - packets
bytes = input.txbytes - bytes

for w, s in pairs(worker.status()) do
   print(("worker %s: pid=%s alive=%s status=%s"):format(
         w, s.pid, s.alive, s.status))
end

print(("Processed %.1f million packets in %.2f seconds (%d bytes; %.2f Gbps)"):format(packets / 1e6, runtime, bytes, bytes * 8.0 / 1e9 / runtime))
print(("Made %s breaths: %.2f packets per breath; %.2fus per breath"):format(lib.comma_value(breaths), packets / breaths, runtime / breaths * 1e6))
print(("Rate(Mpps):\t%.3f"):format(packets / runtime / 1e6))
