module(...,package.seeall)

local shm = require("core.shm")
local vmprofile = require("lib.vmprofile")
local S = require("syscall")

local TraceHealthMonitor = {}

function new ()
   local monitor = setmetatable(
      {
         name = ("trace-health-monitor(%d)"):format(S.getpid()),
         interval = 5 * 1e9, -- Every five seconds
         profiles = nil,
         -- Last and current head/loop/interpreted sample counts. The “last”
         -- set holds counts from the last sampling, and is used to construct
         -- the “current” set by subtracting the counts from the next sampling.
         last_head = 0,
         last_loop = 0,
         last_interpreted = 0,
         current_head = nil,
         current_loop = nil,
         current_interpreted = nil,
         busy = 0 -- Busyness level 0-2
      },
      {__index=TraceHealthMonitor}
   )
   return monitor:timer()
end

function TraceHealthMonitor:open_profiles ()
   local profiles = {}
   for _, zone in ipairs(shm.children("engine/vmprofile")) do
      local profile =
         shm.open("engine/vmprofile/"..zone, vmprofile.ctype, 'read-only')
      assert(profile.magic == vmprofile.magic)
      assert(profile.major >= vmprofile.major)
      assert(profile.minor >= vmprofile.minor)
      table.insert(profiles, profile)
   end
   self.profiles = profiles
end

function TraceHealthMonitor:timer ()
   return timer.new(
      self.name,
      function () self:monitor() end,
      self.interval, 'repeating'
   )
end

function TraceHealthMonitor:sample ()
   local head, loop, interpreted = 0, 0, 0

   -- Sum head, loop, and interpreted counts.
   for _, profile in ipairs(self.profiles) do
      for i = 0, vmprofile.max_traces do
         head = head + profile.trace[i].head
         loop = loop + profile.trace[i].loop
      end
      interpreted = interpreted + profile.vm[vmprofile.vmstate.interpreter]
   end

   self.current_head = head - self.last_head
   self.current_loop = loop - self.last_loop
   self.current_interpreted = interpreted - self.last_interpreted

   self.last_head = head
   self.last_loop = loop
   self.last_interpreted = interpreted
end

function TraceHealthMonitor:monitor ()
   if not self.profiles then
      self:open_profiles()
   end

   self:sample()

   if engine.sleep == 0 then
      self.busy = self.busy + 1
   else
      self.busy = 0
   end

   if self.busy > 1 then
      -- If the engine load is high, we assume that we can determine the
      -- overall health of traces by comparing how much time is spent in
      -- head vs loop vs interpreter.
      if self.current_head > self.current_loop
         or self.current_interpreted > self.current_loop
      then
         -- If we think the hot traces are bad, we flush the trace cache,
         -- hoping to get a better set next time.
         print(
            ("%s: flushing traces (h: %d, l: %d, i: %d)")
               :format(self.name,
                       tonumber(self.current_head),
                       tonumber(self.current_loop),
                       tonumber(self.current_interpreted))
         )
         jit.flush()
      end
   end
end
