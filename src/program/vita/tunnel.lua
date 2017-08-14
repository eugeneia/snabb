-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local esp = require("lib.ipsec.esp")
local ipv4 = require("lib.protocol.ipv4")

-- sa := { spi=(SPI), mode=(STRING), key(KEY), salt(SALT),
--         [ window_size(UINT), resync_threshold(UINT), resync_attempts(UINT),
--           auditing(BOOL) ] }

-- https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
local NextHeaderIPv4 = 4

Encapsulate = {
   config = {
      spi = {required=true},
      mode = {required=true},
      key = {required=true},
      salt = {required=true}
   }
}

function Encapsulate:new (sa)
   return setmetatable({sa = esp.encrypt:new(sa)}, {__index = Encapsulate})
end

function Encapsulate:push ()
   local output, sa = self.output.output, self.sa
   local input4 = self.input.input4
   for _=1,link.nreadable(input4) do
      local p = link.receive(input4)
      local p_enc = sa:encapsulate_tunnel(p, NextHeaderIPv4)
      if p_enc then link.transmit(output, p_enc)
      else packet.free(p) end
   end
end


Decapsulate = {
   config = {
      spi = {required=true},
      mode = {required=true},
      key = {required=true},
      salt = {required=true},
      window_size = {},
      resync_threshold = {},
      resync_attempts = {},
      auditing = {}
   }
}

function Decapsulate:new (sa)
   return setmetatable({sa = esp.decrypt:new(sa)}, {__index = Decapsulate})
end

function Decapsulate:push ()
   local input, sa = self.input.input, self.sa
   local output4 = self.output.output4
   for _=1,link.nreadable(input) do
      local p_enc = link.receive(input)
      local p, next_header = sa:decapsulate_tunnel(p_enc)
      if p and next_header == NextHeaderIPv4 then
         link.transmit(output4, p)
      else
         packet.free(p_enc)
      end
   end
end


Tunnel4 = {
   config = {
      src = {required=true},
      dst = {required=true}
   }
}

function Tunnel4:new (conf)
   local o = {
      ip_template = ipv4:new{
         src = ipv4:pton(conf.src),
         dst = ipv4:pton(conf.dst),
         protocol = esp.PROTOCOL
      },
      ip = ipv4:new{}
   }
   return setmetatable(o, {__index = Tunnel4})
end

function Tunnel4:encapsulate (p)
   p = packet.prepend(p, self.ip_template:header_ptr(), ipv4:sizeof())
   self.ip:new_from_mem(p.data, p.length)
   self.ip:total_length(p.length)
   self.ip:checksum()
   return p
end

function Tunnel4:push ()
   local input, output = self.input.input, self.output.output
   for _=1,link.nreadable(input) do
      link.transmit(output, self:encapsulate(link.receive(input)))
   end
end
