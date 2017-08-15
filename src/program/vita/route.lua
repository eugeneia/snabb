-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local lpm = require("lib.lpm.lpm4_248").LPM4_248
local cltable = require("lib.cltable")
local ffi = require("ffi")

-- route := { net_cidr4=(CIDR4), gw_ip4=(IPv4), rx_sa=(SA), tx_sa(SA) }

PrivateRouter = {
   config = {
      routes = {required=true}
   }
}

function PrivateRouter:new (conf)
   local o = {
      routes = {},
      eth = ethernet:new({}),
      ip4 = ipv4:new({})
   }
   for _, route in ipairs(conf.routes) do
      o.routes[#o.routes+1] = {
         net_cidr4 = assert(route.net_cidr4, "Missing net_cidr4"),
         link = nil
      }
   end
   return setmetatable(o, {__index = PrivateRouter})
end

function PrivateRouter:link ()
   self.routing_table4 = lpm:new()
   for key, route in ipairs(self.routes) do
      route.link = self.output[config.link_name(route.net_cidr4)]
      self.routing_table4:add_string(route.net_cidr4, key)
   end
   self.routing_table4:build()
end

function PrivateRouter:find_route4 (dst)
   local route = self.routes[self.routing_table4:search_bytes(dst)]
   return route and route.link
end

function PrivateRouter:push ()
   local input, eth, ip4 = self.input.input, self.eth, self.ip4
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      eth:new_from_mem(p.data, p.length)
      if eth:type() == 0x0800 then -- IPv4
         p = packet.shiftleft(p, ethernet:sizeof())
         ip4:new_from_mem(p.data, p.length)
         local route = self:find_route4(ip4:dst())
         if not route then
            packet.free(p)
         else
            link.transmit(route, p)
         end
      else
         packet.free(p)
      end
   end
end



PublicRouter = {
   config = {
      routes = {required=true}
   }
}

function PublicRouter:new (conf)
   local o = {
      routes = {},
      eth = ethernet:new({}),
      ip4 = ipv4:new({})
   }
   for _, route in ipairs(conf.routes) do
      o.routes[#o.routes+1] = {
         gw_ip4 = assert(route.gw_ip4, "Missing gw_ip4")
      }
   end
   return setmetatable(o, {__index = PublicRouter})
end

function PublicRouter:link ()
   self.routing_table4 = cltable.new{key_type=ffi.typeof("uint8_t[4]")}
   for _, route in ipairs(self.routes) do
      local l = self.output[config.link_name(route.gw_ip4)]
      if l then self.routing_table4[ipv4:pton(route.gw_ip4)] = l end
   end
end

function PublicRouter:find_route4 (src)
   return self.routing_table4[src]
end

function PublicRouter:push ()
   local input, eth, ip4 = self.input.input, self.eth, self.ip4
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      eth:new_from_mem(p.data, p.length)
      if eth:type() == 0x0800 then -- IPv4
         p = packet.shiftleft(p, ethernet:sizeof())
         ip4:new_from_mem(p.data, p.length)
         local route = self:find_route4(ip4:src())
         if not route then
            packet.free(p)
         else
            link.transmit(route, packet.shiftleft(p, ipv4:sizeof()))
         end
      else
         packet.free(p)
      end
   end
end
