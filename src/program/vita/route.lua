-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local arp = require("lib.protocol.arp")
local esp = require("lib.ipsec.esp")
local exchange = require("program.vita.exchange")
local lpm = require("lib.lpm.lpm4_248").LPM4_248
local ctable = require("lib.ctable")
local lq = require("program.vita.lib.lq")
local ffi = require("ffi")


-- Shared buffers, predicates, …

local eth_list = lq.packet_list()
local ip4_list = lq.packet_list()
local fwd4_list = lq.packet_list()
local arp_list = lq.packet_list()
local protocol_list = lq.packet_list()

local eth_size = lq.MinSize(ethernet:sizeof())
local eth_strip = lq.Strip(ethernet:sizeof())
local ip4_size = lq.MinSize(ipv4:sizeof())

local eth = ethernet:new({})
local ip4 = ipv4:new({})

local function is_ip4 (p)
   eth:new_from_mem(p.data, ethernet:sizeof())
   return eth:type() == 0x0800
end

local function is_arp (p)
   eth:new_from_mem(p.data, ethernet:sizeof())
   return eth:type() == arp.ETHERTYPE
end

local function is_esp4 (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   return ip4:protocol() == esp.PROTOCOL
end

local function is_protocol (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   return ip4:protocol() == exchange.PROTOCOL
end

local function ok_ipsum (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   return ip4:checksum_ok()
end

local function has_ttl4 (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   return ip4:ttl() > 1
end

local function decrement_ttl4 (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   ip4:ttl(ip4:ttl() - 1)
   ip4:checksum()
   return p
end


-- route := { net_cidr4=(CIDR4), gw_ip4=(IPv4), preshared_key=(KEY) }

PrivateRouter = {
   name = "PrivateRouter",
   config = {
      routes = {required=true}
   }
}

function PrivateRouter:new (conf)
   local o = { routes = {} }
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

function PrivateRouter:push ()
   local input = self.input.input
   local eth_list = lq.free(eth_list)
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      if eth_size(p) then
         lq.append(eth_list, p)
      else
         packet.free(p)
      end
   end

   local fwd4_list = lq.filter(is_ip4, eth_list, fwd4_list)
   fwd4_list = lq.map(eth_strip, fwd4_list)
   fwd4_list = lq.filter(ip4_size, fwd4_list)
   fwd4_list = lq.filter(ok_ipsum, fwd4_list)
   fwd4_list = lq.filter(has_ttl4, fwd4_list)
   fwd4_list = lq.map(decrement_ttl4, fwd4_list)
   for _, i in lq.entries(fwd4_list) do
      self:forward4(lq.get(i, fwd4_list))
   end

   local arp_output = self.output.arp
   local arp_list = lq.filter(is_arp, eth_list, arp_list)
   arp_list = lq.map(eth_strip, arp_list)
   for _, i in lq.entries(arp_list) do
      link.transmit(arp_output, lq.get(i, arp_list))
   end
end

function PrivateRouter:find_route4 (dst)
   local route = self.routes[self.routing_table4:search_bytes(dst)]
   return route and route.link
end

function PrivateRouter:forward4 (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   local route = self:find_route4(ip4:dst())
   if route then
      link.transmit(route, p)
   else
      packet.free(p)
   end
end


PublicRouter = {
   name = "PublicRouter",
   config = {
      routes = {required=true},
      node_ip4 = {required=true}
   }
}

function PublicRouter:new (conf)
   local o = { routes = {} }
   for _, route in ipairs(conf.routes) do
      o.routes[#o.routes+1] = {
         gw_ip4 = assert(route.gw_ip4, "Missing gw_ip4"),
         link = nil
      }
   end
   return setmetatable(o, {__index = PublicRouter})
end

function PublicRouter:link ()
   local ipv4_addr_t = ffi.typeof("uint8_t[4]")
   local index_t = ffi.typeof("uint32_t")
   self.routing_table4 = ctable.new{
      key_type = ipv4_addr_t,
      value_type = index_t
   }
   for index, route in ipairs(self.routes) do
      assert(ffi.cast(index_t, index) == index, "index overflow")
      route.link = self.output[config.link_name(route.gw_ip4)]
      if route.link then
         self.routing_table4:add(ipv4:pton(route.gw_ip4), index)
      end
   end
end

function PublicRouter:push ()
   local input = self.input.input
   local eth_list = lq.free(eth_list)
   for _=1,link.nreadable(input) do
      local p = link.receive(input)
      if eth_size(p) then
         lq.append(eth_list, p)
      else
         packet.free(p)
      end
   end

   local ip4_list = lq.free(ip4_list)
   ip4_list = lq.filter(is_ip4, eth_list, ip4_list)
   ip4_list = lq.map(eth_strip, ip4_list)
   ip4_list = lq.filter(ip4_size, ip4_list)

   local fwd4_list = lq.filter(is_esp4, ip4_list, fwd4_list)
   fwd4_list = lq.filter(ok_ipsum, fwd4_list)
   fwd4_list = lq.filter(has_ttl4, fwd4_list)
   fwd4_list = lq.map(decrement_ttl4, fwd4_list)
   for _, i in lq.entries(fwd4_list) do
      self:forward4(lq.get(i, fwd4_list))
   end

   local protocol_output = self.output.protocol
   local protocol_list = lq.filter(is_protocol, ip4_list, protocol_list)
   for _, i in lq.entries(protocol_list) do
      link.transmit(protocol_output, lq.get(i, protocol_list))
   end


   local arp_output = self.output.arp
   local arp_list = lq.filter(is_arp, eth_list, arp_list)
   arp_list = lq.map(eth_strip, arp_list)
   for _, i in lq.entries(arp_list) do
      link.transmit(arp_output, lq.get(i, arp_list))
   end
end

function PublicRouter:find_route4 (src)
   return self.routes[self.routing_table4:lookup_ptr(src).value].link
end

function PublicRouter:forward4 (p)
   ip4:new_from_mem(p.data, ipv4:sizeof())
   local route = self:find_route4(ip4:src())
   if route then
      link.transmit(route, packet.shiftleft(p, ipv4:sizeof()))
   else
      packet.free(p)
   end
end

