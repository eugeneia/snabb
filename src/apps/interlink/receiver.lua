-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local shm = require("core.shm")
local interlink = require("lib.interlink")

local Receiver = {
   config = {
      name = {required=true},
      create = {default=false}
   }
}

function Receiver:new (conf)
   local self = {}
   if conf.create then
      self.interlink = interlink.create(conf.name)
      self.destroy = conf.name
   else
      self.interlink = interlink.open(conf.name)
   end
   interlink.init(self.interlink)
   return setmetatable(self, {__index=Receiver})
end

function Receiver:pull ()
   local o, r, n = self.output.output, self.interlink, 0
   if not o then return end -- don’t forward packets until connected
   while not interlink.empty(r) and n < engine.pull_npackets do
      link.transmit(o, interlink.extract(r))
      n = n + 1
   end
   interlink.pull(r)
end

function Receiver:stop ()
   shm.unmap(self.interlink)
   if self.destroy then
      shm.unlink(self.destroy)
   end
end

return Receiver
