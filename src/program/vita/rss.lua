-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local siphash = require("lib.hash.siphash")
local ffi = require("ffi")
local rshift = bit.rshift

-- Minimal software receive-side scaling (RSS) app.

RSS = {
   name = "RSS",
   config = {
      offset = {default=0},
      length = {required=true},
      nqueues = {required=true},
      key = {}
   }
}

-- Distributes packets received on its input link to its output1..n links,
-- where n=nqueues, based on the packet contents specified by the continuous
-- field denoted by offset and length.

function RSS:new (conf)
   assert(conf.nqueues > 0 and  conf.nqueues < 2^16 - 1)
   conf.hash_inputs = ffi.new("uint8_t[?]", conf.length * link.max)
   conf.hash_outputs = ffi.new("uint32_t[?]", link.max)
   conf.multi_hash = siphash.make_multi_hash{
      size = conf.length,
      width = 'variable',
      key = conf.key or siphash.random_sip_hash_key()
   }
   return setmetatable(conf, {__index=RSS})
end

function RSS:link ()
   self.queues = {}
   for i = 1, self.nqueues do
      self.queues[i] = self.output["queue"..i]
   end
end

-- Taken from Alexander Gall’s apps/rss/rss.lua
local function distribute (hash, nqueues)
   -- Our SipHash implementation produces only even numbers to satisfy some
   -- ctable internals.
   local hash16 = ffi.cast("uint16_t", rshift(hash, 1))
   -- This relies on the hash being a 16-bit value
   return tonumber(rshift(hash16 * nqueues, 16) + 1)
end

function RSS:push ()
   local input = self.input.input
   local nreadable = link.nreadable(input)

   -- Compute hashes for field of length at offset for packets in input.
   local hash_inputs, hash_outputs = self.hash_inputs, self.hash_outputs
   local input_length, input_offset = self.length, self.offset
   for i = 1, nreadable do
      ffi.copy(hash_inputs + (i-1)*input_length,
               link.nth(input, i).data + input_offset,
               input_length)
   end
   self.multi_hash(hash_inputs, hash_outputs, nreadable)

   -- Distribute packets to queues based on hashes.
   local queues, nqueues = self.queues, self.nqueues
   for i = 0, nreadable - 1 do
      link.transmit(
         queues[distribute(hash_outputs[i], nqueues)],
         link.receive(input)
      )
   end
end

function selftest ()
   local synth = require("apps.test.synth")
   local basic_apps = require("apps.basic.basic_apps")
   local testconf = {offset=14, length=8, nqueues=7}
   local testpackets = {}
   for i = 1, testconf.nqueues * 100 do
      local p = packet.resize(packet.allocate(), 60)
      ffi.cast("uint64_t *", p.data+testconf.offset)[0] = math.random(2^64)-1
      testpackets[i] = p
   end

   local c = config.new()
   config.app(c, "source", synth.Synth, {packets=testpackets})
   config.app(c, "rss", RSS, testconf)
   config.app(c, "sink", basic_apps.Sink)
   config.link(c, "source.output -> rss.input")
   for queue = 1, testconf.nqueues do
      config.link(c, "rss.queue"..queue.." -> sink.input"..queue)
   end

   engine.configure(c)

   local txlink = engine.app_table.source.output.output
   local npackets = 10e6
   local start = os.clock()
   engine.main{
      done=function () return link.stats(txlink).txpackets >= npackets end
   }
   print(("%.2f Mpps"):format(npackets / (os.clock() - start) / 1e6))
   engine.report_links()
end
