
module(..., package.seeall)

-- YANG list data structure

-- Some constraints:
--
--  * need to support YANG features (multiple keys [strings, numbers, ...?], ordered-by user)
--  * need to support huge lists (>64k lwaftr binding table with ip/psid keys)

-- XXX need LUA52COMPAT

local List = {}

function new (opt)
   local self = {
      map = {},
      vector = {},
      index = {},
      opt = opt
   }
   return setmetatable(self, List)
end

function List:__len ()
   return #self.vector
end

function List:__index (k)
   return self.vector[self.map[List.findkey(k, self.index, self.opt.nkeys)]]
end

function List.findkey (k, index, n)
   n = n or 1
   if n == 1 then
      return k
   else
      assert(#k == n, "Need "..n.."keys but only got "..#k)
      while n > 0 do
         n = n - 1
         index = index[k[#k-n]]
         if index == nil then
            break
         end
      end
      return index
   end
end

function List:__newindex (k, v)
   local existing = List.findkey(k, self.index, self.opt.nkeys)
   if existing ~= nil then
      k = existing
   else
      k = List.newkey(k, self.index, self.opt.nkeys)
   end
   local idx = self.map[k]
   if v ~= nil then
      if idx == nil then
         idx = #self.vector+1
         self.map[k] = idx
      end
      self.vector[idx] = v
   elseif idx ~= nil then
      self.map[k] = nil
      table.remove(self.vector, idx)
   end
end

function List.newkey (k, index, n)
   n = n or 1
   if n == 1 then
      return k
   else
      assert(#k == n, "Need "..n.."keys but only got "..#k)
      -- maybe make fresh k?
      while n > 1 do
         n = n - 1
         local p = k[#k-n]
         if index[p] == nil then
            index[p] = {}
         end
         index = index[p]
      end
      index[k[#k]] = k
      return k
   end
end

function List:__ipairs ()
   local function next (self, idx)
      idx = idx + 1
      if idx <= #self.vector then
         return idx, self.vector[idx]
      end
   end
   return next, self, 0
end

function List:__pairs ()
   error("NYI")
end

function selftest ()
   local l1 = new{}
   l1.foo = 'bar'
   l1[12] = 'baz'
   print(#l1, l1.foo)
   for i, v in ipairs(l1) do
      print(i, v)
   end

   local l2 = new{nkeys=2}
   l2[{'foo', 'bar'}] = 1
   l2[{'foo', 'baz'}] = 2
   l2[{'bar', 'zop'}] = 3
   print(#l2, l2[{'bar', 'zop'}], l2[{'foo', 'baz'}], l2[{'foo', 'bar'}])
   for i, v in ipairs(l2) do
      print(i, v)
   end

   -- local tab = {}
   -- for i=1, 1e8 do
   --    tab[i] = i
   -- end
   -- print(tab[10e5])
   -- table.remove(tab, 10e5)
   -- print(tab[10e5])
   -- local map = {}
   -- local yang_util = require("lib.yang.util")
   -- for i=1,1e7 do
   --    ip = yang_util.ipv4_ntop(math.random(0xffffffff))
   --    map[ip] = i
   -- end
   -- local n = 0 
   -- for k,v in pairs(map) do
   --    n = n + 1
   -- end
   -- print(n)
end