-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local exchange = require("program.vita.exchange")
local icmp = require("program.vita.icmp")
local counter = require("core.counter")
local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local pf_match = require("pf.match")
local ffi = require("ffi")

local Dispatch = {
   buffer_t = ffi.typeof("struct { int fill; struct packet *packets[?]; }"),
   rules = nil,
   classifier = nil,
   buffers = nil,
   ninputs = nil
}

function Dispatch:configure_dispatch (rules)
   self.rules = rules
   local pattern = "match {"
   for idx, rule in ipairs(self.rules) do
      local call = (" => %s(%d)"):format(rule.action, idx-1)
      pattern = pattern.."\n"..rule.match..call
   end
   pattern = pattern.."\n}"
   self.classifier = pf_match.compile(pattern, {classify_native=true})
end

function Dispatch:link ()
   -- Adjust buffer size to number of input links.
   if self.ninputs ~= #self.input then
      self.ninputs = #self.input
      self.buffers = {}
      for idx, rule in ipairs(self.rules) do
         self.buffers[idx-1] = ffi.new(self.buffer_t, link.max * self.ninputs)
      end
   end
end

function Dispatch:preprocess (p) return p end

function Dispatch:push ()
   local classifier = self.classifier
   local buffers = self.buffers
   for _, input in ipairs(self.input) do
      while not link.empty(input) do
         local p = self:preprocess(link.receive(input))
         local buffer = buffers[classifier(p.data, p.length)]
         buffer.packets[buffer.fill] = p
         buffer.fill = buffer.fill + 1
      end
   end
   for idx, rule in ipairs(self.rules) do
      local buffer = buffers[idx-1]
      local method = self[rule.action]
      local output = self.output[rule.output or rule.action]
      for i = 0, buffer.fill-1 do
         method(self, buffer.packets[i], output)
      end
      buffer.fill = 0
   end
end


PrivateDispatch = setmetatable({
   name = "PrivateDispatch",
   config = {
      node_ip4 = {},
      node_ip6 = {}
   },
   shm = {
      ethertype_errors = {counter}
   }
}, {__index=Dispatch})

function PrivateDispatch:new (conf)
   local self = setmetatable({}, {__index=self})
   if conf.node_ip4 then
      self:configure_dispatch{
         {match=("ip dst host %s and icmp"):format(conf.node_ip4), action='icmp4'},
         {match=("ip dst host %s"):format(conf.node_ip4), action='protocol4_unreachable'},
         {match="ip", action='forward4'},
         {match="arp", action='arp'},
         {match="otherwise", action='reject_ethertype'}
      }
   elseif conf.node_ip6 then
      self:configure_dispatch{
         {match="ip6 and icmp6 and (ip6[40] = 135 or ip6[40] = 136)", action='nd'},
         {match=("ip6 dst host %s and icmp6"):format(conf.node_ip6), action='icmp6'},
         {match=("ip6 dst host %s"):format(conf.node_ip6), action='protocol6_unreachable'},
         {match="ip6", action='forward6'},
         {match="otherwise", action='reject_ethertype'}
      }
   else error("Need either node_ip4 or node_ip6.") end
   return self
end

function PrivateDispatch:forward4 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:forward6 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:icmp4 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:icmp6 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:arp (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:nd (p, output)
   link.transmit(output, p)
end

function PrivateDispatch:protocol4_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:protocol6_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PrivateDispatch:reject_ethertype (p)
   packet.free(p)
   counter.add(self.shm.ethertype_errors)
end


PublicDispatch = setmetatable({
   name = "PublicDispatch",
   config = {
      node_ip4 = {},
      node_ip6 = {}
   },
   shm = {
      rxerrors = {counter},
      ethertype_errors = {counter},
      protocol_errors = {counter},
      fragment_errors = {counter}
   }
}, {__index=Dispatch})

function PublicDispatch:new (conf)
   local self = setmetatable({}, {__index=self})
   if conf.node_ip4 then
      self:configure_dispatch{
         {match="ip[6:2] & 0x3FFF != 0", action='reject_fragment'},
         {match="ip proto esp", action='forward4'},
         {match=("ip proto %d"):format(exchange.PROTOCOL), action='protocol'},
         {match=("ip dst host %s and icmp"):format(conf.node_ip4), action='icmp4'},
         {match=("ip dst host %s"):format(conf.node_ip4), action='protocol4_unreachable'},
         {match="ip", action='reject_protocol'},
         {match="arp", action='arp'},
         {match="otherwise", action='reject_ethertype'}
      }
   elseif conf.node_ip6 then
      self:configure_dispatch{
         {match="ip6 proto esp", action='forward6'},
         {match=("ip6 proto %d"):format(exchange.PROTOCOL), action='protocol'},
         {match="ip6 and icmp6 and (ip6[40] = 135 or ip6[40] = 136)", action='nd'},
         {match=("ip6 dst host %s and icmp6"):format(conf.node_ip6), action='icmp6'},
         {match=("ip6 dst host %s"):format(conf.node_ip6), action='protocol6_unreachable'},
         {match="ip6", action='reject_protocol'},
         {match="otherwise", action='reject_ethertype'}
      }
   else error("Need either node_ip4 or node_ip6.") end
   return self
end

function PublicDispatch:forward4 (p, output)
   -- NB: Ignore potential differences between IP datagram and Ethernet size
   -- since the minimum ESP packet exceeds 60 bytes in payload.
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()+ipv4:sizeof()))
end

function PublicDispatch:forward6 (p, output)
   -- NB: Ignore potential differences between IP datagram and Ethernet size
   -- since the minimum ESP packet exceeds 60 bytes in payload.
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()+ipv6:sizeof()))
end

function PublicDispatch:protocol (p, output)
   if output then
      link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
   else
      self:reject_protocol(p)
   end
end

function PublicDispatch:icmp4 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PublicDispatch:icmp6 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PublicDispatch:arp (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PublicDispatch:nd (p, output)
   link.transmit(output, p)
end

function PublicDispatch:protocol4_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PublicDispatch:protocol6_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function PublicDispatch:reject_fragment (p)
   packet.free(p)
   counter.add(self.shm.rxerrors)
   counter.add(self.shm.fragment_errors)
end

function PublicDispatch:reject_protocol (p)
   packet.free(p)
   counter.add(self.shm.rxerrors)
   counter.add(self.shm.protocol_errors)
end

function PublicDispatch:reject_ethertype (p)
   packet.free(p)
   counter.add(self.shm.rxerrors)
   counter.add(self.shm.ethertype_errors)
end


InboundDispatch = setmetatable({
   name = "InboundDispatch",
   config = {
      node_ip4 = {},
      node_ip6 = {}
   },
   shm = {
      protocol_errors = {counter}
   }
}, {__index=Dispatch})

function InboundDispatch:new (conf)
   local self = setmetatable({}, {__index=self})
   if conf.node_ip4 then
      self.eth = ethernet:new{type=0x0800}
      self:configure_dispatch{
         {match=("ip dst host %s and icmp"):format(conf.node_ip4), action='icmp4'},
         {match=("ip dst host %s"):format(conf.node_ip4), action='protocol4_unreachable'},
         {match="ip", action='forward4'},
         {match="otherwise", action='reject_protocol'}
      }
   elseif conf.node_ip6 then
      self.eth = ethernet:new{type=0x86dd}
      self:configure_dispatch{
         {match=("ip6 dst host %s and icmp6"):format(conf.node_ip6), action='icmp6'},
         {match=("ip6 dst host %s"):format(conf.node_ip6), action='protocol6_unreachable'},
         {match="ip6", action='forward6'},
         {match="otherwise", action='reject_protocol'}
      }
   else error("Need either node_ip4 or node_ip6.") end
   return self
end

function InboundDispatch:preprocess (p)
   -- Encapsulate packet with Ethernet header to please pf.match (we receive
   -- plain IP frames on the input port.)
   return packet.prepend(p, self.eth:header(), ethernet:sizeof())
end

function InboundDispatch:forward4 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:forward6 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:icmp4 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:icmp6 (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:protocol4_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:protocol6_unreachable (p, output)
   link.transmit(output, packet.shiftleft(p, ethernet:sizeof()))
end

function InboundDispatch:reject_protocol (p)
   packet.free(p)
   counter.add(self.shm.protocol_errors)
end
