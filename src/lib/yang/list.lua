
module(..., package.seeall)

-- YANG list data structure

-- Some constraints:
--
--  * need to support YANG features (multiple keys [strings, numbers, ...?], ordered-by user)
--  * need to support huge lists (>64k lwaftr binding table with ip/psid keys)

-- XXX need LUA52COMPAT

local List = {}

function List:new (keys)
   assert(type(keys) == 'table', "unsupported keys type: "..type(keys))
   assert(#keys > 0, "need at least one key field")
   local self = {
      values = {},
      index = {},
      keys = keys
   }
   return setmetatable(self, {__index=List})
end

function List:len ()
   return #self.values
end

function List:nth (idx)
   return self.values[idx]
end

function List:find (value)
   assert(type(value) == 'table', "unsupported value type: "..type(value))
   local res = self.index
   for _, field in ipairs(self.keys) do
      local key = value[field]
      assert(key ~= nil, "missing key field: "..field)
      res = res[key]
      if not res then
         break
      end
   end
   return res
end

function List:get (value)
   local idx = self:find(value)
   if idx then
      return self:nth(idx)
   end
end

local function checkidx (n)
   assert(n == math.floor(n) and n > 0,
      "index is not a positive integer: "..n)
end

function List:insert (idx, value)
   checkidx(idx)
   assert(idx <= self:len()+1, "index out of bounds: "..idx)
   assert(self:find(value) == nil, "value for key already exists")
   -- insert and index value
   table.insert(self.values, idx, value)
   -- index value
   self:_index(idx)
   -- update indices
   for i = idx+1, self:len() do
      self:_index(i)
   end
end

function List:remove (idx)
   checkidx(idx)
   assert(idx <= self:len(), "index out of bounds: "..idx)
   -- deindex
   self:_deindex(idx)
   -- remove value
   table.remove(self.values, idx)
   -- update indices
   for i = idx, self:len() do
      self:_index(i)
   end
end

function List:add (value)
   self:insert(self:len()+1, value)
end

function List:update (value)
   self.values[self:find(value)] = value
end

function List:iterate ()
   return ipairs(self.values)
end

function List:_index (idx)
   local value = self.values[idx]
   local index = self.index
   for n, field in ipairs(self.keys) do
      local key = value[field]
      if n < #self.keys then
         if index[key] == nil then
            index[key] = {}
         end
         index = index[key]
      else
         index[key] = idx
      end
   end
end

function List:_deindex (idx)
   local function empty (t)
      for k,v in pairs(t) do
         return false
      end
      return true
   end
   local value = self.values[idx]
   local function rec (index, n)
      local field = self.keys[n]
      local key = value[field]
      if n < #self.keys then
         rec(index[key], n+1)
         if empty(index[key]) then
            index[key] = nil
         end
      else
         index[key] = nil
      end
   end
   rec(self.index, 1)
end      

local ListMeta = {}

function new (keys)
   return setmetatable({list=List:new(keys)}, ListMeta)
end

function ListMeta:__len ()
   return self.list:len()
end

function ListMeta:__index (key)
   if type(key) == 'number' then
      return self.list:nth(key)
   else
      return self.list[key]
   end
end

function ListMeta:__newindex (idx, value)
   if value ~= nil then
      self.list:insert(idx, value)
   else
      self.list:remove(idx)
   end
end

function ListMeta:__ipairs ()
   return self.list:iterate()
end

ListMeta.__pairs = ListMeta.__ipairs


function selftest ()
   local l1 = new{'k'}
   l1:add{k=1, v='foo'}
   l1:add{k=3, v='bar'}
   assert(#l1 == 2)
   assert(l1[1].k == 1, l1[1].v == 'foo')
   for i, v in ipairs(l1) do
      assert(i <= 2)
      local kv = {[1]='foo', [3]='bar'}
      assert(v.v == assert(kv[v.k]))
   end

   local l2 = new{'a', 'b'}
   l2:add{a='foo', b='bar', c=1}
   l2:add{a='foo', b='baz', c=2}
   l2:add{a='bar', b='zop', c=3}
   assert(#l2 == 3)
   assert(l2:get{a='bar', b='zop'}.c == 3)
   assert(l2:get{a='foo', b='baz'}.c == 2)
   assert(l2:get{a='foo', b='bar'}.c == 1)
   for i, v in pairs(l2) do
      assert(i == v.c)
   end
   l2[2] = {a='new', b='new', c=0.5}
   assert(l2:get{a='bar', b='zop'}.c == 3)
   assert(l2:get{a='foo', b='baz'}.c == 2)
   assert(l2:get{a='new', b='new'}.c == 0.5)
   assert(l2:get{a='foo', b='bar'}.c == 1)
   l2[l2:find{a='new', b='new'}] = nil
   assert(l2:get{a='bar', b='zop'}.c == 3)
   assert(l2:get{a='foo', b='baz'}.c == 2)
   assert(l2:get{a='foo', b='bar'}.c == 1)
   for i, v in pairs(l2) do
      assert(i == v.c)
   end
   l2:update{a='bar', b='zop', c=300}
   assert(l2:get{a='bar', b='zop'}.c == 300)

   local function fail (f)
      local ok, err = pcall(f)
      assert(not ok)
      print("should fail: "..err)
   end

   fail(function () l2[7] = {a='foo', b='bar', c=1} end)
   fail(function () l2[1] = {a='foo', b='bar', c=1} end)
   fail(function () l2[1] = {a='foo'} end)
   fail(function () l2[1] = true end)
   fail(function () l2[7] = nil end)
   fail(function () l2[0] = {a='new', b='new', c=0.5} end)
   fail(function () l2[1.3] = {a='new', b='new', c=0.5} end)
   fail(function () l2:find{a='foo'} end)
   fail(function () l2:find(12) end)

   -- local yang_util = require("lib.yang.util")
   -- local l = new{'ip', 'port'}
   -- for i=1, 1e7 do
   --    l:add{ip=yang_util.ipv4_ntop(math.random(0xffffffff)), port=i}
   -- end
   -- print(l[1e5].ip)
   -- print(l:get{ip=l[1e5].ip, port=l[1e5].port}.ip)
   -- l:remove(1e5)
   -- print(l:find{ip=l[1e5].ip, port=l[1e5].port})
   -- l[1e5] = {ip="1.2.3.4", port=1234}
   -- print(l:find{ip="1.2.3.4", port=1234})
end