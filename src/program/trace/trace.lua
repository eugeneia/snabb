-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local ffi = require("ffi")
local C = ffi.C
local shm = require("core.shm")
local lib = require("core.lib")
local vmprofile = require("lib.vmprofile")
local vmstate = vmprofile.vmstate
local top = require("program.top.top")
local usage = require("program.trace.README_inc")

local pid -- PID of process to attach to

function run (args)
   local opts, opt = {help = "h", pid = "p"}, {}

   function opt.h () print(usage) main.exit() end

   function opt.p (arg) pid = arg end

   args = lib.dogetopt(args, opt, "hp:", opts)

   pid = top.select_snabb_instance(pid)

   local subcommand = args[1]; table.remove(args, 1)

   if     subcommand == "profile" then profile(args)
   elseif subcommand == "inspect" then inspect(args)
   else print(usage) main.exit(1) end
end

function profile (args)
   local opts, opt = {duration = "d", traces = "t", gc = "m", what = "w"}, {}
   local duration, report_traces, report_gc

   function opt.d (arg)
      duration = tonumber(arg)
      if not duration then print("Not a number: "..arg) main.exit(1) end
   end

   function opt.t (arg) report_traces = true end

   function opt.m (arg) report_gc = true end

   if #lib.dogetopt(args, opt, "d:tm", opts) > 0 then
      print(usage) main.exit(1)
   end

   local profiles = "/"..pid.."/engine/vmprofile"
   local zones = {}
   for _, zone in ipairs(shm.children(profiles)) do
      local profile =
         shm.open(profiles.."/"..zone, vmprofile.ctype, 'read-only')
      assert(profile.magic == vmprofile.magic)
      assert(profile.major >= vmprofile.major)
      assert(profile.minor >= vmprofile.minor)
      zones[zone] = profile
   end

   local function take_snapshot (snapshot)
      for zone, profile in pairs(zones) do
         local dst = ffi.new(vmprofile.ctype)
         ffi.copy(ffi.cast("char *", dst), ffi.cast("char *", profile),
                  ffi.sizeof(vmprofile.ctype))
         snapshot[zone] = dst
      end
   end

   local function rebase_snapshot (snapshot, checkpoint)
      for zone, profile in pairs(snapshot) do
         local diff = checkpoint[zone]
         if diff then
            for _, state in pairs(vmprofile.vmstate) do
               profile.vm[state] = profile.vm[state] - diff.vm[state]
            end
            for i = 0, vmprofile.max_traces-1 do
               local t, ta = profile.trace[i], diff.trace[i]
               t.head = t.head - ta.head
               t.loop = t.loop - ta.loop
               t.other = t.other - ta.other
               t.gc = t.gc - ta.gc
            end
         end
      end
   end

   local a, b = {}, {}

   take_snapshot(a)

   if duration then
      C.usleep(duration * 1e6)
      take_snapshot(b)
      rebase_snapshot(b, a)
   else
      b = a
   end

   local function cent (n, d)
      return ("%5.2f"):format(tonumber(n) / tonumber(d) * 100)
   end

   local function overview ()
      local total_samples = 0
      local samples_by_zone = {}
      local samples_by_kind = {
         head = 0,
         loop = 0,
         interpreter = 0,
         ffi = 0,
         gc = 0,
         jit = 0
      }

      for zone, profile in pairs(b) do
         local samples = 0
         for _, state in pairs(vmprofile.vmstate) do
            samples = samples + profile.vm[state]
         end

         samples_by_kind.interpreter = samples_by_kind.interpreter
            + profile.vm[vmstate.interpreter]
            + profile.vm[vmstate.exit_handler]
         samples_by_kind.ffi = samples_by_kind.ffi + profile.vm[vmstate.ffi]
         samples_by_kind.gc = samples_by_kind.gc + profile.vm[vmstate.gc]
         samples_by_kind.jit = samples_by_kind.jit
            + profile.vm[vmstate.recorder]
            + profile.vm[vmstate.optimizer]

         for i = 0, vmprofile.max_traces-1 do local t = profile.trace[i]
            samples = samples + t.head + t.loop + t.other + t.gc

            samples_by_kind.head = samples_by_kind.head + t.head
            samples_by_kind.loop = samples_by_kind.loop + t.loop
            samples_by_kind.ffi = samples_by_kind.ffi + t.other
            samples_by_kind.gc = samples_by_kind.gc + t.gc
         end

         total_samples = total_samples + samples

         table.insert(samples_by_zone, {zone = zone, samples = samples})
      end

      if total_samples == 0 then print("No samples.") main.exit(1) end

      table.sort(samples_by_zone,
                 function (x, y) return x.samples > y.samples end)

      local what_row = {1, 5, 5, 5, 5, 5, 12 }
      top.print_row(what_row, {"", "HEAD", "LOOP", "FFI", "GC", "JIT", "INTERPRETER"})
      top.print_row(what_row, {
                       "%",
                       cent(samples_by_kind.head, total_samples),
                       cent(samples_by_kind.loop, total_samples),
                       cent(samples_by_kind.ffi, total_samples),
                       cent(samples_by_kind.gc, total_samples),
                       cent(samples_by_kind.jit, total_samples),
                       cent(samples_by_kind.interpreter, total_samples)
      })

      print()

      local zones_row = {5, 71}
      top.print_row(zones_row, {"%", "ZONE"})
      for _, t in ipairs(samples_by_zone) do
         if t.samples > 0 then
            top.print_row(zones_row, {cent(t.samples, total_samples), t.zone})
         end
      end

      print()

      print("Total samples:", tonumber(total_samples))
   end

   local function traces ()
      local trace_samples = 0
      local samples_by_trace = {}

      for zone, profile in pairs(b) do
         for i = 0, vmprofile.max_traces-1 do local t = profile.trace[i]
            local trace = {
               id = i,
               zone = zone,
               profile = t,
               samples = t.head + t.loop + t.other + t.gc
            }
            trace_samples = trace_samples + trace.samples
            table.insert(samples_by_trace, trace)
         end
      end

      if trace_samples == 0 then print("No trace samples.") main.exit(1) end

      table.sort(samples_by_trace,
                 function (x, y) return x.samples > y.samples end)

      local traces_row = {5, 5, 5, 5, 5, 5, 41}
      top.print_row(traces_row,
                    {"%","HEAD","LOOP","FFI","GC","ID","ZONE"})
      for _, trace in ipairs(samples_by_trace) do
         if trace.samples > 0 then
            top.print_row(traces_row, {
                             cent(trace.samples, trace_samples),
                             cent(trace.profile.head, trace_samples),
                             cent(trace.profile.loop, trace_samples),
                             cent(trace.profile.other, trace_samples),
                             cent(trace.profile.gc, trace_samples),
                             tostring(trace.id),
                             trace.zone
            })
         end
      end
   end

   local function gc ()
      local gc_samples = 0
      local gc_by_trace = {}

      for zone, profile in pairs(b) do
         for i = 0, vmprofile.max_traces-1 do local t = profile.trace[i]
            local trace = { id = i, zone = zone, samples = t.gc }
            gc_samples = gc_samples + t.gc
            table.insert(gc_by_trace, trace)
         end
      end

      if gc_samples == 0 then print("No GC samples.") main.exit(1) end

      table.sort(gc_by_trace,
                 function (x, y) return x.samples > y.samples end)

      local traces_row = {5, 5, 65}
      top.print_row(traces_row, {"%","ID","ZONE"})
      for _, trace in ipairs(gc_by_trace) do
         if trace.samples > 0 then
            top.print_row(traces_row, { cent(trace.samples, gc_samples),
                                        tostring(trace.id),
                                        trace.zone })
         end
      end
   end

   if     report_traces then traces()
   elseif report_gc     then gc()
   else                      overview() end
end

function inspect (args)
   local opts, opt = {jdump = "j", bytecode = "b", ir = "i", mcode = "m"}, {}

   local jdump = shm.root.."/"..shm.resolve("/"..pid.."/jdump")

   local output
   local function set_output (type)
      if not output then
         output = type
      else
         print("Supply only one: of --bytecode / --ir / --mcode")
         main.exit(1)
      end
   end

   function opt.j (arg) jdump = arg end

   function opt.b (arg) set_output('bytecode') end

   function opt.i (arg) set_output('ir') end

   function opt.m (arg) set_output('mcode') end

   args = lib.dogetopt(args, opt, "j:abim", opts)

   if #args ~= 1 then
      print(usage) main.exit(1)
   end

   local id = tonumber(args[1])
   if not id then print("Not a valid trace id: "..args[1]) main.exit(1) end

   local file, error = io.open(jdump)
   if not file then print(error) main.exit(1) end

   local info
   while true do
      local l = file:read("*l")
      if not l then break end

      local trace = tonumber(l:match("^%-%-%-%- TRACE ([%d]+) start"))
      local parent, exit = l:match("start ([%w]+)/([%w]+)")
      local start = l:match("[%w]+/[%w]+ (.*)$") or l:match("start (.*)$")

      if trace == id then
         local bytecode = ""
         while true do
            l = file:read("*l")
            if not l:match("^%-%-%-%-") then bytecode = bytecode..l.."\n"
            else break end
         end

         if not l:match("^%-%-%-%- TRACE [%d]+ abort") then

            local ir = ""
            while true do
               l = file:read("*l")
               if not l:match("^%-%-%-%-") then ir = ir..l.."\n"
               else break end
            end

            local mcode = ""
            while true do
               l = file:read("*l")
               if not l:match("^%-%-%-%-") then mcode = mcode..l.."\n"
               else break end
            end

            info = {
               start = start,
               parent = parent,
               exit = exit,
               bytecode = bytecode,
               ir = ir,
               mcode = mcode,
               stop = assert(l:match("^%-%-%-%- TRACE [%d]+ stop %-> (.*)$"))
            }
         end

         _ = file:read("*l") -- read terminating newline
      end
   end

   if not info.start then
      print("No such trace.")
      main.exit(1)
   end

   if output then
      io.write(info[output])
   else
      print(info.start
               ..((info.parent and " ("..info.parent.."/"..info.exit..")")
                     or "")
               .." -> "..info.stop)
   end
end
