local ffi = require("ffi")
local ethernet = require("lib.protocol.ethernet")

local m = {}
for i= 1,1e5 do m[i] = ffi.new("uint8_t[6]") end

local x = 0
for i = 1,#m do
   x = x + ethernet:n_bcast(m[i])
end
print(x)
