-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ffi = require("ffi")

-- Auxillary functions for “functional” packet processing over lists

local packet_list_t =
   ffi.typeof("struct {int cursor; struct packet *buffer[?];}")

function packet_list ()
   return ffi.new(packet_list_t, link.max)
end

function append (list, p)
   list.buffer[list.cursor] = p
   list.cursor = list.cursor + 1
end

function free (list)
   for i = 0, list.cursor - 1 do
      local p = list.buffer[i]
      if p then
         packet.free(p)
      end
   end
   list.cursor = 0
   return list
end

function map (f, from, to)
   to = to or from
   for i = 0, from.cursor - 1 do
      to.buffer[i] = f(from.buffer[i])
   end
   return to
end

function filter (predicate, from, to)
   to = to or from
   local to_cursor, from_cursor = 0, 0
   for i = 0, from.cursor - 1 do
      local p = from.buffer[i]
      if predicate(p) then
         to.buffer[to_cursor] = p
         to_cursor = to_cursor + 1
      elseif from == to then
         packet.free(p)
      else
         from.buffer[from_cursor] = p
         from_cursor = from_cursor + 1
      end
   end
   from.cursor = from_cursor
   to.cursor = to_cursor
   return to
end

local function list_gen (list, state)
   local buffer, cursor, next_state = list.buffer, list.cursor, nil
   if state < cursor then
      next_state = state + 1
   end
   return next_state, buffer[state]
end

function ipairs (list)
   return list_gen, list, 0
end


function MinSize (n)
   return function (p) return p.length >= n end
end

function Strip (bytes)
   return function (p) return packet.shiftleft(p, bytes) end
end
