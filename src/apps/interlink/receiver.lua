-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local shm = require("core.shm")
local interlink = require("lib.interlink")

local Receiver = {
   config = {
      name = {required=true}
   }
}

function Receiver:new (conf)
   local self = { interlink = interlink.attach(conf.name),
                  shm_name = conf.name }
   interlink.init(self.interlink)
   return setmetatable(self, {__index=Receiver})
end

function Receiver:pull ()
   local o, r, n = self.output.output, self.interlink, 0
   if not o then return end -- don’t pull unless output link present
   while not interlink.empty(r) and n < engine.pull_npackets do
      link.transmit(o, interlink.extract(r))
      n = n + 1
   end
   interlink.pull(r)
end

function Receiver:stop ()
   shm.unmap(self.interlink)
   shm.unlink(self.shm_name)
end

return Receiver
