-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

-- Poptrie, see
--   http://conferences.sigcomm.org/sigcomm/2015/pdf/papers/p57.pdf

local ffi = require("ffi")
local bit = require("bit")
local band, bor, lshift, rshift, bnot =
   bit.band, bit.bor, bit.lshift, bit.rshift, bit.bnot

local Poptrie = {
   k = 6,
   node_t = ffi.typeof([[struct {
      uint64_t leafvec, vector;
      uint32_t base0, base1;
   }]]),
   leaf_t = ffi.typeof("uint16_t")
}

local function array (t, s)
   return ffi.new(ffi.typeof("$[?]", t), s)
end

function new (init)
   local num_default = 4
   local pt = {
      nodes = init.nodes or array(Poptrie.node_t, num_default),
      num_nodes = (init.nodes and assert(init.num_nodes)) or num_default,
      leaves = init.leaves or array(Poptrie.leaf_t, num_default),
      num_leaves = (init.leaves and assert(init.num_leaves)) or num_default
   }
   return setmetatable(pt, {__index=Poptrie})
end

function Poptrie:grow_nodes ()
   self.num_nodes = self.num_nodes * 2
   local new_nodes = array(Poptrie.node_t, self.num_nodes)
   ffi.copy(new_nodes, self.nodes, ffi.sizeof(self.nodes))
   self.nodes = new_nodes
end

function Poptrie:grow_leaves ()
   self.num_leaves = self.num_leaves * 2
   local new_leaves = array(Poptrie.leaf_t, self.num_leaves)
   ffi.copy(new_leaves, self.leaves, ffi.sizeof(self.leaves))
   self.leaves = new_leaves
end

-- XXX - Generalize for key=uint8_t[?]
local function extract (key, offset, length)
   return band(rshift(key, offset), lshift(1, length) - 1)
end

-- Add key/value pair to RIB (intermediary binary trie)
-- key=uint8_t[?], length=uint16_t, value=uint16_t
function Poptrie:add (key, length, value)
   assert(value)
   local function add (node, offset)
      if offset == length then
         node.value = value
      elseif extract(key, offset, 1) == 0 then
         node.left = add(node.left or {}, offset + 1)
      elseif extract(key, offset, 1) == 1 then
         node.right = add(node.right or {}, offset + 1)
      else error("invalid state") end
      return node
   end
   self.rib = add(self.rib or {}, 0)
end

-- Longest prefix match on RIB
function Poptrie:rib_lookup (key, length, root)
   local function lookup (node, offset, value)
      value = node.value or value
      if offset == length then
         return {value=value, left=node.left, right=node.right}
      elseif extract(key, offset, 1) == 0 and node.left then
         return lookup(node.left, offset + 1, value)
      elseif extract(key, offset, 1) == 1 and node.right then
         return lookup(node.right, offset + 1, value)
      else
         return {value=value}
      end
   end
   return lookup(root or self.rib, 0)
end

-- Compress RIB into Poptrie
function Poptrie:build (rib, node, leaf_base, node_base)
   -- When called without arguments, create the root node.
   rib = rib or self.rib
   leaf_base = leaf_base or 0
   node_base = node_base or 0
   if not node then
      -- Allocate this node, grow nodes array if necessary.
      while node_base >= self.num_nodes do
         self:grow_nodes()
      end
      node = self.nodes[node_base]
      node_base = node_base + 1
   end
   -- Initialize node base pointers.
   node.base0 = leaf_base
   node.base1 = node_base
   -- Allocate and initialize leaves.
   for index = 0, 2^Poptrie.k - 1 do
      local child = self:rib_lookup(index, Poptrie.k, rib)
      if not (child.left or child.right) then
         -- XXX - compress
         while leaf_base >= self.num_leaves do
            self:grow_leaves()
         end
         self.leaves[leaf_base] = child.value or 0
         leaf_base = leaf_base + 1
      end
   end
   -- Allocate and build child nodes.
   for index = 0, 2^Poptrie.k - 1 do
      local child = self:rib_lookup(index, Poptrie.k, rib)
      if child.left or child.right then
         node.vector = bor(node.vector, lshift(1ULL, index))
         while node_base >= self.num_nodes do
            self:grow_nodes()
         end
         leaf_base, node_base =
            self:build(child, self.nodes[node_base], leaf_base, node_base + 1)
      end
   end
   -- Return new leaf_base and node_base pointers.
   return leaf_base, node_base
end

-- http://graphics.stanford.edu/~seander/bithacks.html#CountBitsSetNaive
local function popcnt (v) -- popcaan
   local c = 0
   while v > 0 do
      c = c + band(v, 1)
      v = rshift(v, 1)
   end
   return c
end

function bin (number)
   local digits = {"0", "1"}
   local s = ""
   repeat
      local remainder = number % 2
      s = digits[tonumber(remainder+1)]..s
      number = (number - remainder) / 2
   until number == 0
   return s
end

-- [Algorithm 1] lookup(t = (N , L), key); the lookup procedure for the address
-- key in the tree t (when k = 6). The function extract(key, off, len) extracts
-- bits of length len, starting with the offset off, from the address key.
-- N and L represent arrays of internal nodes and leaves, respectively.
-- << denotes the shift instruction of bits. Numerical literals with the UL and
-- ULL suffixes denote 32-bit and 64-bit unsigned integers, respectively.
-- Vector and base are the variables to hold the contents of the node’s fields.
--
-- if [direct pointing] then
--    index = extract(key, 0, t.s);
--    dindex = t.D[index].direct index;
--    if (dindex & (1UL << 31)) then
--       return dindex & ((1UL << 31) - 1);
--    end if
--    index = dindex;
--    offset = t.s;
-- else
--    index = 0;
--    offset = 0;
-- end if
-- vector = t.N [index].vector;
-- v = extract(key, offset, 6);
-- while (vector & (1ULL << v)) do
--    base = t.N [index].base1;
--    bc = popcnt(vector & ((2ULL << v) - 1));
--    index = base + bc - 1;
--    vector = t.N [index].vector;
--    offset += 6;
--    v = extract(key, offset, 6);
-- end while
-- base = t.N [index].base0;
-- if [leaf compression] then
--    bc = popcnt(t.N [index].leafvec & ((2ULL << v) - 1));
-- else
--    bc = popcnt((∼t.N [index].vector) & ((2ULL << v) - 1));
-- end if
-- return t.L[base + bc - 1];
--
function Poptrie:lookup (key)
   local N, L = self.nodes, self.leaves
   local index = 0
   local node = N[index]
   local offset = 0
   local v = extract(key, offset, Poptrie.k)
   while band(node.vector, lshift(1ULL, v)) ~= 0 do
      local base = N[index].base1
      local bc = popcnt(band(node.vector, lshift(2ULL, v) - 1))
      index = base + bc - 1
      node = N[index]
      offset = offset + Poptrie.k
      v = extract(key, offset, Poptrie.k)
   end
   local base = node.base0
   local bc = popcnt(band(bnot(node.vector), lshift(2ULL, v) - 1))
   return L[base + bc - 1]
end

function selftest ()
   local t = new{}
   -- Test RIB
   t:add(0x00, 8, 1) -- 00000000
   t:add(0x0F, 8, 2) -- 00001111
   t:add(0x07, 4, 3) --     0111
   t:add(0xFF, 8, 4) -- 11111111
   t:add(0xFF, 5, 5) --    11111
   local n = t:rib_lookup(0x0, 1)
   assert(not n.value and n.left and not n.right)
   local n = t:rib_lookup(0x00, 8)
   assert(n.value == 1 and not (n.left or n.right))
   local n = t:rib_lookup(0x07, 3)
   assert(not n.value and (n.left and n.right))
   local n = t:rib_lookup(0x0, 1, n)
   assert(n.value == 3 and not (n.left or n.right))
   local n = t:rib_lookup(0xFF, 5)
   assert(n.value == 5 and (not n.left) and n.right)
   local n = t:rib_lookup(0x0F, 3, n)
   assert(n.value == 4 and not (n.left or n.right))
   local n = t:rib_lookup(0x3F, 8)
   print(n.value, n.left, n.right)
   -- Test FIB
   local leaf_base, node_base = t:build()
   print(t:lookup(0x00)) -- 00000000
   print(t:lookup(0x03)) -- 00000011
   print(t:lookup(0x07)) -- 00000111
   print(t:lookup(0x0F)) -- 00001111
   print(t:lookup(0x1F)) -- 00011111
   print(t:lookup(0x3F)) -- 00111111
   print(t:lookup(0xFF)) -- 11111111
end
