-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")

NextHop4 = {
   config = {
      mac = {required=true}
   }
}

function NextHop4:new (conf)
   local o = {
      eth = ethernet:new{
         dst = ethernet:pton(conf.mac),
         type = 0x0800 -- IPv4
      }
   }
   return setmetatable(o, {__index = NextHop4})
end

function NextHop4:encapsulate (p)
   return packet.prepend(p, self.eth:header_ptr(), ethernet:sizeof())
end

function NextHop4:push ()
   local output = self.output.output
   for _, input in ipairs(self.input) do
      for _=1,link.nreadable(input) do
         link.transmit(output, self:encapsulate(link.receive(input)))
      end
   end
end
