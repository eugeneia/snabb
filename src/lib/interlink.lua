-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

-- Based on MCRingBuffer, see
--   http://www.cse.cuhk.edu.hk/%7Epclee/www/pubs/ipdps10.pdf

local shm = require("core.shm")
local ffi = require("ffi")
local band = require("bit").band
local full_memory_barrier = ffi.C.full_memory_barrier
local waitfor = require("core.lib").waitfor

local SIZE = link.max + 1
local CACHELINE = 64 -- XXX - make dynamic
local INT = ffi.sizeof("int")

assert(band(SIZE, SIZE-1) == 0, "SIZE is not a power of two")

local status = { Locked = 0, Unlocked = 1 }

ffi.cdef([[ struct interlink {
   char pad0[]]..CACHELINE..[[];
   int read, write, lock;
   char pad1[]]..CACHELINE-3*INT..[[];
   int lwrite, nread;
   char pad2[]]..CACHELINE-2*INT..[[];
   int lread, nwrite;
   char pad3[]]..CACHELINE-2*INT..[[];
   struct packet *packets[]]..SIZE..[[];
}]])

function create (name)
   local r = shm.create(name, "struct interlink")
--   r.nwrite = link.max -- “full” until initialized
   return r
end

function open (name)
   local r = shm.open(name, "struct interlink")
   return r
end

function inittx (r)
   waitfor(function () return r.lock ~= status.Locked end)
   full_memory_barrier()
end

function init (r) -- initialization must be performed by consumer
   assert(r.packets[0] == ffi.new("void *")) -- only satisfied if uninitialized
   for i = 0, link.max do
      r.packets[i] = packet.allocate()
   end
   -- r.nwrite = 0
   full_memory_barrier()
   r.lock = status.Unlocked
end

local function NEXT (i)
   return band(i + 1, link.max)
end

function full (r)
   local after_nwrite = NEXT(r.nwrite)
   if after_nwrite == r.lread then
      if after_nwrite == r.read then
         return true
      end
      r.lread = r.read
   end
end

function insert (r, p)
   assert(p.length > 0, "insert 0")
   assert(not full(r), "overflow (full)")
   assert(r.packets[r.nwrite].length == 0, "overflow")
   packet.free(r.packets[r.nwrite])
   r.packets[r.nwrite] = p
   r.nwrite = NEXT(r.nwrite)
end

function push (r)
   full_memory_barrier()
   r.write = r.nwrite
end

function empty (r)
   if r.nread == r.lwrite then
      if r.nread == r.write then
         return true
      end
      r.lwrite = r.write
   end
end

function extract (r)
   assert(not empty(r), "underflow (empty)")
   local p = r.packets[r.nread]
   assert(p.length > 0, "underflow")
   r.packets[r.nread] = packet.allocate()
   r.nread = NEXT(r.nread)
   return p
end

function pull (r)
   full_memory_barrier()
   r.read = r.nread
end
