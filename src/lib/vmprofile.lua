module(...,package.seeall)

ffi = require("ffi")

magic = 0x1d50f007
major = 2
minor = 0

vmstate = {
   interpreter = 0,
   ffi = 1,
   gc = 2,
   exit_handler = 3,
   recorder = 4,
   optimizer = 5,
   assembler = 6,
   max = 7
}

max_traces = 4097

ctype = ffi.typeof([[
   struct {
      uint32_t magic;
      uint16_t major, minor;
      uint64_t vm[]]..vmstate.max..[[];
      struct { uint64_t head, loop, other, gc; } trace[]]..max_traces..[[];
   }
]])
