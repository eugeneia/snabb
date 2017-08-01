-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- These apps implement ESP encapsulation and decapsulation with AES-128-GCM.

module(..., package.seeall)
local esp = require("lib.ipsec.esp")
local counter = require("core.counter")
local C = require("ffi").C

AES128gcmEnc = {
   config = {
      spi = {required=true},
      key = {required=true},
      salt = {required=true}
   },
   shm = {
      txerrors = {counter}
   }
}

function AES128gcmEnc:new (conf)
   local self = {}
   self.encrypt = esp.esp_v6_encrypt:new{
      mode = "aes-128-gcm",
      spi = conf.spi,
      key = conf.key,
      salt = conf.salt}
   return setmetatable(self, {__index = AES128gcmEnc})
end

function AES128gcmEnc:push ()
   local input = self.input.decapsulated
   local output = self.output.encapsulated
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      if self.encrypt:encapsulate(p) then
         link.transmit(output, p)
      else
         packet.free(p)
         counter.add(self.shm.txerrors)
      end
   end
end

AES128gcmDec = {
   config = {
      spi = {required=true},
      key = {required=true},
      salt =  {required=true},
      receive_window = {},
      resync_threshold = {},
      resync_attempts = {},
      auditing = {}
   },
   shm = {
      rxerrors = {counter}
   }
}

function AES128gcmDec:new (conf)
   local self = {}
   self.decrypt = esp.esp_v6_decrypt:new{
      mode = "aes-128-gcm",
      spi = conf.spi,
      key = conf.key,
      salt = conf.salt,
      window_size = conf.receive_window,
      resync_threshold = conf.resync_threshold,
      resync_attempts = conf.resync_attempts,
      auditing = conf.auditing}
   return setmetatable(self, {__index = AES128gcmDec})
end

function AES128gcmDec:push ()
   local input = self.input.encapsulated
   local output = self.output.decapsulated
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      if self.decrypt:decapsulate(p) then
         link.transmit(output, p)
      else
         packet.free(p)
         counter.add(self.shm.rxerrors)
      end
   end
end
