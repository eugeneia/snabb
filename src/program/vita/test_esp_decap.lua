-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local AES128gcmDec = require("apps.ipsec.esp").AES128gcmDec

function start (interlink_in, interlink_out)
   local c = config.new()

   config.app(c, "rx", Receiver, {name=interlink_in})
   config.app(c, "dec", AES128gcmDec, {
                 spi = 0x0,
                 key = "00112233445566778899AABBCCDDEEFF",
                 salt = "00112233"
   })
   config.link(c, "rx.output->dec.encapsulated")

   config.app(c, "tx", Transmitter, {name=interlink_out})
   config.link(c, "dec.decapsulated->tx.input")

   engine.configure(c)
   engine.main()
end
