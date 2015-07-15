module(..., package.seeall)

local lib = require("core.lib")
local bridge = require("apps.bridge.learning").bridge
local usage = require("program.gc.README_inc")
local ffi = require("ffi")
local C = ffi.C

local long_opts = {
   help          = "h",
   ["long-help"] = "H"
}

local short_usage = [[Usage:
  labswitch [OPTIONS] <confpath>

  -h, --help
                             Print this usage information.
  -H, --long-help
                             Print complete usage information including
                             description of the configuration file
                             format.

Run labswitch with <confpath>. The configuration at <confpath> will be
reloaded when it changes.
]]

function run (args)
   local opt = {}
   function opt.H (arg) print(usage)       main.exit(1) end
   function opt.h (arg) print(short_usage) main.exit(1) end
   args = lib.dogetopt(args, opt, "hH", long_opts)
   if #args ~= 1 then opt.h() end
   local confpath = args[1]

   engine.log = true
   local mtime = 0
   while true do
      local mtime2 = C.stat_mtime(confpath)
      if mtime2 ~= mtime then
         print("Loading " .. confpath)
         local status, config = pcall(
            function ()
               return labswitch(lib.load_conf(confpath))
            end)
         if status then engine.configure(config) engine.report_links()
         else print("Error loading configuration: "..config) end
         mtime = mtime2
      end
      engine.main({duration=1, no_report=true})
      -- Flush buffered log messages every 1s
      io.flush()
   end
end

-- <ports> = {
--     <name> = {
--         apps = {
--             <appname> = { <classspec>, <config> },
--             ...
--         },
--         rx = "<appname>.<port>",
--         tx = "<appname>.<port>",
--         [ links = { <linkspec>, ... } ]
--     },
--     ...
-- }
function labswitch (ports)
   local c = config.new()

   local function mesh(name, link)
      return "bridge_"..name..((link and "."..link) or "")
   end

   -- Configure bridge mesh for ports.
   for port, _ in pairs(ports) do
      local mesh_ports = {}
      for mesh_port, _ in pairs(ports) do
         if mesh_port ~= port then
            table.insert(mesh_ports, mesh_port)
         end
      end
      local bridge_config = { ports = { "l2" },
                              split_horizon_groups = { mesh = mesh_ports } }
      lib.store_conf("/tmp/"..mesh(port), bridge_config)
      config.app(c, mesh(port), bridge, bridge_config)
   end
   for port, _ in pairs(ports) do
      for mesh_port, _ in pairs(ports) do
         if mesh_port ~= port then
            config.link(c, mesh(port, mesh_port).."->"..mesh(mesh_port, port))
         end
      end
   end

   -- Configure port apps and links.
   for name, port in pairs(ports) do
      -- Create apps.
      for name, app in pairs(port.apps) do
         local class_spec, conf = app[1], app[2]
         config.app(c, name, load_class(class_spec), conf)
      end
      -- Link rx/tx to bridge.
      config.link(c, mesh(name, "l2").."->"..port.rx)
      config.link(c, port.tx.."->"..mesh(name, "l2"))
      -- Create auxiliary links.
      if port.links then
         for _, linkspec in ipairs(port.links) do
            config.link(c, linkspec)
         end
      end
   end

   return c
end

function load_class (spec)
   local module, symbol = spec:match("^([a-zA-Z_\\.]+)/([a-zA-Z_\\.]+)$")
   if module and symbol then return require(module)[symbol]
   else error("Invalid class spec: "..spec) end
end

function selftest ()
   function replay_port (name, capfile)
      return { apps = { [name.."_tx"] = { "apps.pcap.pcap/PcapReader", capfile },
                        [name.."_rx"] = { "apps.basic.basic_apps/Sink" } },
               rx = name.."_rx.input",
               tx = name.."_tx.output" }
   end
   engine.configure(labswitch({
      a = replay_port("a", "program/labswitch/test_a.pcap"),
      b = replay_port("b", "program/labswitch/test_b.pcap"),
      c = replay_port("c", "program/labswitch/test_c.pcap")
   }))
   engine.main({duration=0.1})
   engine.report_links()
end
