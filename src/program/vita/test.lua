-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local lib = require("core.lib")
local worker = require("core.worker")
local vita = require("program.vita.vita")
local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local ethernet= require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")

-- sudo ./snabb snsh [<pktsize>]
-- default is IMIX

function test_packets ()
   local size = tonumber(main.parameters[1])
   local IMIX = (size and {size}) or { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }
   local packets = {}
   for _, size in ipairs(IMIX) do
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

local conf = lib.load_conf("program/vita/test.conf")

worker.start("ESP",
[[require("program.vita.vita").offload_worker_esp("program/vita/test.conf")]])
worker.start("DSP",
[[require("program.vita.vita").offload_worker_dsp("program/vita/test.conf")]])

local c, private, public = vita.configure_router(conf)

config.link(c, public.output.." -> "..public.input)

config.app(c, "synth", Synth, {packets=test_packets()})

config.link(c, "synth.output -> "..private.input)

config.app(c, "sink", basic_apps.Sink)

config.link(c, private.output.." -> sink.input")

engine.configure(c)
engine.main({duration=10, report={showlinks=true}})

for w, s in pairs(worker.status()) do
   print(("worker %s: pid=%s alive=%s status=%s"):format(
         w, s.pid, s.alive, s.status))
end

local stats = link.stats(engine.app_table["sink"].input.input)
print(stats.txbytes * 8 / 1e9 / 10 .. " Gbps")
