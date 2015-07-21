module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")
local ffi = require("ffi")

Layer2Switch = {}

function Layer2Switch:new (arg)
   local conf = config.parse_app_arg(arg) or nil
   local o = { ports = conf.ports,
               mactable = MacTable:new() }
   -- Set mac timeout
   o.timer = timer.new("Layer2Switch MAC timeout",
                       function ()
                          o.mactable:age()
                          if o.timer then timer.activate(o.timer) end
                       end,
                       (conf.timeout or 60)/2 * 1e9)
   timer.activate(o.timer)
   return setmetatable(o, {__index=Layer2Switch})
end

function Layer2Switch:stop ()
   self.timer = nil
end

function Layer2Switch:push ()
   -- Receive packets from ports, learn addresses, forward to endpoint.
   for _, port in ipairs(self.ports) do
      while not link.empty(self.input[port]) do
         local p = link.receive(self.input[port])
         self.mactable:insert(hash(packet.data(p)+6), port)
         link.transmit(self.output.tx, p)
      end
   end
   -- Receive packets from endpoint, forward to ports.
   while not link.empty(self.input.rx) do
      local p = link.receive(self.input.rx)
      local data = packet.data(p)
      local port
      if ethernet:is_mcast(data) then port = nil
      else port = self.mactable:lookup(hash(data)) end
      if port then
         link.transmit(self.output[port], p)
      else
         local copy = false
         for _, port in ipairs(self.ports) do
            if not copy then
               link.transmit(self.output[port], p)
               copy = true
            else
               link.transmit(self.output[port], packet.clone(p))
            end
         end
      end
   end
end

-- Dummy hash function for MAC addresses.
local hash_cache_32 = ffi.new("uint32_t *[1]")
local hash_cache_16 = ffi.new("uint16_t *[1]")
function hash (mac)
   hash_cache_32[0] = ffi.cast("uint32_t *", mac)
   hash_cache_16[0] = ffi.cast("uint16_t *", mac+4)
   return hash_cache_32[0][0] + hash_cache_16[0][0]
end

-- https://gist.github.com/lukego/4706097
-- Pretty much the data structure in the link above except entries are
-- not promoted on lookup.
MacTable = {}

function MacTable:new ()
   local o = { old = {}, new = {} }
   return setmetatable(o, {__index=MacTable})
end

function MacTable:insert(k, v)
   self.new[k] = v
   return v
end

function MacTable:lookup(k)
   return self.new[k] or self.old[k]
end

function MacTable:age()
   self.old, self.new = self.new, {}
end
