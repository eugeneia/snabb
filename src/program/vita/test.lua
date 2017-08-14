-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local vita = require("program.vita.vita")
local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local ethernet= require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")

function test_packets ()
   local IMIX = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }
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

local c, private, public = vita.configure{
   private_nexthop = {mac="52:54:00:00:00:00"},
   public_nexthop = {mac="52:54:00:00:00:00"},
   node_ip4 = "192.168.10.1",
   routes = {
      {
         net_cidr4 = "192.168.10.0/24",
         gw_ip4 = "192.168.10.1",
         rx_sa = {
            spi = 0x0,
            mode = "aes-gcm-128-12",
            key = "00112233445566778899AABBCCDDEEFF",
            salt = "00112233"
         },
         tx_sa = {
            spi = 0x0,
            mode = "aes-gcm-128-12",
            key = "00112233445566778899AABBCCDDEEFF",
            salt = "00112233"
         }
      }
   }
}

config.link(c, public.output.." -> "..public.input)

config.app(c, "synth", Synth, {packets=test_packets()})

config.link(c, "synth.output -> "..private.input)

config.app(c, "sink", basic_apps.Sink)

config.link(c, private.output.." -> sink.input")

engine.configure(c)
engine.main({duration=10, report={showlinks=true}})

local stats = link.stats(engine.app_table["sink"].input.input)
print(stats.txbytes * 8 / 1e9 / 10 .. " Gbps")
