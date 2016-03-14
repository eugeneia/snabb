local ffi = require("ffi")
local C = ffi.C
local datagram = require("lib.protocol.datagram")
local esp = require("lib.ipsec.esp")

-- When I set this to 30000 it runs fine
local npackets = 31000

_G.developer_debug = true

io.stdout:setvbuf("no") 
print("setup")

local packets = {}
print("allocate"..npackets)
for i = 1, npackets do
   -- When I skip the datagram and do `plain = packet.allocate()' it runs fine
   local d = datagram:new(packet.allocate())
   packets[i] = { plain = d:packet(), encapsulated = 0 }
end
print("encrypt")
local conf = { spi = 0x0,
               mode = "aes-128-gcm",
               keymat = "00112233445566778899AABBCCDDEEFF",
               salt = "00112233"}

-- When I comment out this line it runs fine
local enc, dec = esp.esp_v6_encrypt:new(conf), esp.esp_v6_decrypt:new(conf)

for i, p in ipairs(packets) do
   p.encapsulated = packet.clone(p.plain)
end
