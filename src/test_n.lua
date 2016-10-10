local ffi = require("ffi")
local ethernet = require("lib.protocol.ethernet")
local m = ffi.new("uint8_t[6]")

local x = 0
for i = 1,1e6 do
   m[i%5] = i
   x = x + ethernet:n_bcast(m)
end
print(x)
