-- This class derives from lib.bridge.base and implements a "learning
-- bridge" using a Bloom filter (provided by lib.bloom_filter) to
-- store the set of MAC source addresses of packets arriving on each
-- port.
--
-- Two Bloom storage cells called mac_table and mac_shadow are
-- allocated for each port connected to the bridge.  For each packet
-- arriving on a port, the MAC source address is stored in both cells.
-- The mac_table cell is used during packet forwarding while
-- mac_shadow is used to time out the learned addresses.
--
-- When a packet is received on a port, its MAC destination address is
-- looked up in the mac_table cells of all associated output
-- ports. The packet is sent on all ports for which the lookup results
-- in a match, replicating the packet if necessary.  A destination can
-- be associated with multiple output ports, either because the
-- address has actually been learned on multiple ports or due to false
-- positives in the lookup operation, which are inevitable for Bloom
-- filters.
--
-- Multicast MAC addresses are always flooded to all output ports
-- associated with the input port.
--
-- The timing out of learned addresses is implemented by periodically
-- copying mac_shadow to mac_table and clearing mac_shadow for every
-- port.  I.e., mac_table contains only the addresses learned during
-- the past timeout interval.
--
-- Configuration variables (via the "config" table in the generic
-- configuration of the base class)
--
--   mac_table_size (default 1000)
--
--     Expected maximum number of MAC addresses to store in each
--     per-port Bloom filter.
--
--   fp_rate (default 0.001)
--
--     Maximum rate of false-positives for lookups in the Bloom
--     filters, provided the number of distinct objects stored in the
--     filter does not exceed mac_table_size.
--
--   timeout (default 60 seconds)
--
--     Timeout for learned MAC addresses in seconds.
--
--   verbose (default false)
--
--     If true, a diagnostic message containing the storage cell usage
--     of each mac_table is printed to stdout
--

module(..., package.seeall)

local ffi = require("ffi")
local bridge_base = require("apps.bridge.base").bridge
local packet = require("core.packet")
local link = require("core.link")
local ethernet = require("lib.protocol.ethernet")

local empty, receive, transmit = link.empty, link.receive, link.transmit
local clone = packet.clone

bridge = subClass(bridge_base)
bridge._name = "learning bridge"

local default_config = { mac_table_size = 1000, fp_rate = 0.001,
                         timeout = 60, verbose = false }

function bridge:new (arg)
   local o = bridge:superClass().new(self, arg)
   local conf = o._conf or {}
   for k, v in pairs(default_config) do
      if not conf[k] then
         conf[k] = v
      end
   end
   o._nsrc_ports = #o._src_ports
   o._port_index = 1
   -- Per-port MAC tables
   o._filters = {}
   for _, port in ipairs(o._src_ports) do
      o._filters[port] = lru:new()
   end

   timer.activate(timer.new("mac_learn_timeout",
                               function (t)
                                  for _, filter in ipairs(o._filters) do
                                     filter:age()
                                  end
                               end,
                               conf.timeout *1e9, 'repeating')
                 )

   -- Caches for various cdata pointer objects to avoid boxing in the
   -- push() loop
   o._cache = {
      p = ffi.new("struct packet *[1]"),
      dst = ffi.new("uint8_t *[1]"),
      src = ffi.new("uint8_t *[1]")
   }
   return o
end

-- We only process a single input port for each call of the push()
-- method to reduce the number of nested loops.  A better
-- understanding of the JIT compiler is needed to decide whether this
-- is actually a good thing or not.  Empirical data suggests it is :)
function bridge:push()
   local src_port = self._src_ports[self._port_index]
   local l_in = self.input[src_port]
   while not empty(l_in) do
      local cache = self._cache
      local dst_ports = self._dst_ports
      local p = cache.p
      local dst = cache.dst
      local src = cache.src
      local dst_hash = nil
      local filters = self._filters
      p[0] = receive(l_in)

      dst[0] = packet.data(p[0])
      src[0] = dst[0] + 6

      -- Hash dst unless packet is multicast packet.
      local is_mcast = ethernet:is_mcast(dst[0])
      if not is_mcast then dst_hash = hash(dst[0]) end

      -- Store the source MAC address in source port MAC table
      filters[src_port]:insert(hash(src[0]), true)

      local ports = dst_ports[src_port]
      local copy = false
      local j = 1
      while ports[j] do
         local dst_port = ports[j]
         if is_mcast or filters[dst_port]:lookup(dst_hash) then
            if not copy then
               transmit(self.output[dst_port], p[0])
               copy = true
            else
               transmit(self.output[dst_port], clone(p[0]))
            end
         end
         j = j + 1
      end
      if not copy then
         -- The source MAC address is unknown, flood the packet to
         -- all ports
         local output = self.output
         transmit(output[ports[1]], p[0])
         local j = 2
         while ports[j] do
            transmit(output[ports[j]], clone(p[0]))
            j = j + 1
         end
      end
   end -- of while not empty(l_in)
   if self._port_index == self._nsrc_ports then
      self._port_index = 1
   else
      self._port_index = self._port_index + 1
   end
end


-- Don't judge!
function hash (mac)
   return (mac[0]+mac[1]*2+mac[2]*3+mac[3]*4+mac[4]*5+mac[5]*6) % 997
end

-- https://gist.github.com/lukego/4706097
lru = subClass(nil)

function lru:new ()
   local o = lru:superClass().new(self)
   o.old, o.new = {}, {}
   return o
end

function lru:insert(k, v)
   self.new[k] = v
   return v
end

function lru:lookup(k)
   return self.new[k] or self:insert(k, self.old[k])
end

function lru:age()
   self.old, self.new = self.new, {}
end
