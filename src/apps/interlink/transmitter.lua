-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local shm = require("core.shm")
local interlink = require("lib.interlink")

local Transmitter = {
   config = {
      name = {required=true}
   }
}

function Transmitter:new (conf)
   local self = { interlink = interlink.attach(conf.name) }
   return setmetatable(self, {__index=Transmitter})
end

function Transmitter:push ()
   local i, r = self.input.input, self.interlink
   while not (interlink.full(r) or link.empty(i)) do
      interlink.insert(r, link.receive(i))
   end
   interlink.push(r)
end

function Transmitter:stop ()
   shm.unmap(self.interlink)
end

return Transmitter
