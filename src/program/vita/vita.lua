-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local lib = require("core.lib")
local shm = require("core.shm")
local worker = require("core.worker")
local dispatch = require("program.vita.dispatch")
local ttl = require("program.vita.ttl")
local route = require("program.vita.route")
local tunnel = require("program.vita.tunnel")
local nexthop = require("program.vita.nexthop")
local exchange = require("program.vita.exchange")
local icmp = require("program.vita.icmp")
      schemata = require("program.vita.schemata")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local intel_mp = require("apps.intel_mp.intel_mp")
local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local numa = require("lib.numa")
local yang = require("lib.yang.yang")
local cltable = require("lib.cltable")
local pci = require("lib.hardware.pci")
local S = require("syscall")
local ffi = require("ffi")
local usage = require("program.vita.README_inc")
local confighelp = require("program.vita.README_config_inc")

local ptree = require("lib.ptree.ptree")
local generic_schema_support = require("lib.ptree.support").generic_schema_config_support
local CPUSet = require("lib.cpuset")

local confspec = {
   private_interface = {required=true},
   public_interface = {required=true},
   mtu = {default=8937},
   route = {required=true},
   negotiation_ttl = {},
   sa_ttl = {}
}

local ifspec = {
   pci = {required=true},
   ip4 = {required=true},
   nexthop_ip4 = {required=true},
   mac = {},
   nexthop_mac = {}
}

local function derive_local_unicast_mac (prefix, ip4)
   local mac = ffi.new("uint8_t[?]", 6)
   mac[0] = prefix[1]
   mac[1] = prefix[2]
   ffi.copy(mac+2, ipv4:pton(ip4), 4)
   -- First bit = 0 indicates unicast, second bit = 1 means locally
   -- administered.
   assert(bit.band(bit.bor(prefix[1], 0x02), 0xFE) == prefix[1],
          "Non-unicast or non-local MAC address: "..ethernet:ntop(mac))
   return ethernet:ntop(mac)
end

local function parse_ifconf (conf, mac_prefix)
   conf = lib.parse(conf, ifspec)
   conf.mac = conf.mac or derive_local_unicast_mac(mac_prefix, conf.ip4)
   return conf
end

local function parse_conf (conf)
   conf = lib.parse(conf, confspec)
   conf.private_interface = parse_ifconf(conf.private_interface, {0x2a, 0xbb})
   conf.public_interface = parse_ifconf(conf.public_interface, {0x3a, 0xbb})
   return conf
end

local sa_db_path = "group/sa_db"

-- Vita command-line interface (CLI)
function run (args)
   local long_opt = {
      help = "h",
      ["config-help"] = "H",
      cpu = "c"
   }

   local opt = {}
   local cpuset = CPUSet.new()

   local function exit_usage (status) print(usage) main.exit(status) end

   function opt.h () exit_usage(0) end

   function opt.H () print(confighelp) main.exit(0) end

   function opt.c (arg) cpuset:add_from_string(arg) end

   args = lib.dogetopt(args, opt, "hHc:", long_opt)

   if #args > 0 then exit_usage(1) end
   run_vita(vita_workers, {}, cpuset)
end

-- Vita runs as a process tree that reconfigures itself at runtime based on key
-- exchange and expiration. The key manager maintains a current SA database in
-- sa_db_path (relative to the process group) which is polled and applied by
-- the supervisor. NB: naturally, the SA database must not affect key manager
-- configuration.
-- This function does not halt except for fatal error situations.
function run_vita (setup_fn, initial_conf, cpuset)
   local sa_db_path = shm.root.."/"..shm.resolve(sa_db_path)

   -- Schema support: because Vita configurations are generally shallow we
   -- choose to reliably delegate all configuration transitions to core.app by
   -- making sure that setup_fn receives a fresh configuration every time it is
   -- called.
   local schema_support = {
      compute_config_actions = function(old_graph, new_graph)
         return engine.compute_config_actions(old_graph, new_graph)
      end,
      update_mutable_objects_embedded_in_app_initargs = function () end,
      compute_state_reader = generic_schema_support.compute_state_reader,
      configuration_for_worker = generic_schema_support.configuration_for_worker,
      process_states = generic_schema_support.process_states,
      compute_apps_to_restart_after_configuration_update = function () end,
      translators = {}
   }
   local function setup_fn_fresh (new_conf)
      return setup_fn(lib.deepcopy(new_conf))
   end

   -- Setup supervisor
   local supervisor = ptree.new_manager{
      schema_name = 'vita-esp-gateway',
      schema_support = schema_support,
      initial_configuration = initial_conf,
      setup_fn = setup_fn_fresh,
      cpuset = cpuset
   }

   -- Listen for SA database changes.
   local notify_fd, sa_db_wd = assert(S.inotify_init("cloexec, nonblock"))
   local function sa_db_needs_reload ()
      if not sa_db_wd then
         sa_db_wd = notify_fd:inotify_add_watch(sa_db_path, "close_write")
         -- sa_db_wd ~= nil means the SA database was newly created and we
         -- should load it.
         return (sa_db_wd ~= nil)
      else
         local events, err = notify_fd:inotify_read()
         -- Any event indicates the SA database was written to and we should
         -- reload it.
         return not (err and assert(err.again, err)) and #events > 0
      end
   end

   -- This is how we imperatively incorporate the SA database into the
   -- configuration proper. NB: see schema_support and setup_fn_fresh above.
   local function merge_sa_db (sa_db)
      return function (current_config)
         current_config.outbound_sa = sa_db.outbound_sa
         current_config.inbound_sa = sa_db.inbound_sa
         return current_config
      end
   end

   -- Ensure I/O is line-buffered.
   io.stdout:setvbuf("line")
   io.stderr:setvbuf("line")

   -- Run the supervisor while keeping up to date with SA database changes.
   while true do
      supervisor:main({duration=1})
      if sa_db_needs_reload() then
         local success, sa_db = pcall(
            load_config, schemata['ephemeral-keys'], sa_db_path
         )
         if success then
            supervisor:update_configuration(merge_sa_db(sa_db), 'set', '/')
         else
            supervisor:warn("Failed to read SA database %s: %s",
                            sa_db_path, sa_db)
         end
      end
   end
end

function vita_workers (conf)
   return {
      key_manager = configure_exchange(conf),
      outbound_router = configure_private_router_with_nic(conf),
      inbound_router = configure_public_router_with_nic(conf),
      encapsulate = configure_esp(conf),
      decapsulate =  configure_dsp(conf)
   }
end

function configure_private_router (conf, append)
   conf = parse_conf(conf)
   local c = append or config.new()

   config.app(c, "PrivateDispatch", dispatch.PrivateDispatch, {
                 node_ip4 = conf.private_interface.ip4
   })
   config.app(c, "OutboundTTL", ttl.DecrementTTL)
   config.app(c, "PrivateRouter", route.PrivateRouter, {
                 routes = conf.route,
                 mtu = conf.mtu
   })
   config.app(c, "PrivateICMP4", icmp.ICMP4, {
                 node_ip4 = conf.private_interface.ip4,
                 nexthop_mtu = conf.mtu
   })
   config.app(c, "InboundDispatch", dispatch.InboundDispatch, {
                 node_ip4 = conf.private_interface.ip4
   })
   config.app(c, "InboundTTL", ttl.DecrementTTL)
   config.app(c, "InboundICMP4", icmp.ICMP4, {
                 node_ip4 = conf.private_interface.ip4
   })
   config.app(c, "PrivateNextHop", nexthop.NextHop4, {
                 node_mac = conf.private_interface.mac,
                 node_ip4 = conf.private_interface.ip4,
                 nexthop_ip4 = conf.private_interface.nexthop_ip4,
                 nexthop_mac = conf.private_interface.nexthop_mac
   })
   config.link(c, "PrivateDispatch.forward4 -> OutboundTTL.input")
   config.link(c, "PrivateDispatch.icmp4 -> PrivateICMP4.input")
   config.link(c, "PrivateDispatch.arp -> PrivateNextHop.arp")
   config.link(c, "PrivateDispatch.protocol4_unreachable -> PrivateICMP4.protocol_unreachable")
   config.link(c, "OutboundTTL.output -> PrivateRouter.input")
   config.link(c, "OutboundTTL.time_exceeded -> PrivateICMP4.transit_ttl_exceeded")
   config.link(c, "PrivateRouter.fragmentation_needed -> PrivateICMP4.fragmentation_needed")
   config.link(c, "PrivateICMP4.output -> PrivateNextHop.icmp4")
   config.link(c, "InboundDispatch.forward4 -> InboundTTL.input")
   config.link(c, "InboundDispatch.icmp4 -> InboundICMP4.input")
   config.link(c, "InboundDispatch.protocol4_unreachable -> InboundICMP4.protocol_unreachable")
   config.link(c, "InboundTTL.output -> PrivateNextHop.forward")
   config.link(c, "InboundTTL.time_exceeded -> InboundICMP4.transit_ttl_exceeded")
   config.link(c, "InboundICMP4.output -> PrivateRouter.control")

   for id, route in pairs(conf.route) do
      local private_in = "PrivateRouter."..id
      local ESP_in = "ESP_"..id.."_in"
      config.app(c, ESP_in, Transmitter)
      config.link(c, private_in.." -> "..ESP_in..".input")

      local private_out = "InboundDispatch."..id
      local DSP_out = "DSP_"..id.."_out"
      config.app(c, DSP_out, Receiver)
      config.link(c, DSP_out..".output -> "..private_out)
   end

   local private_links = {
      input = "PrivateDispatch.input",
      output = "PrivateNextHop.output"
   }
   return c, private_links
end

function configure_public_router (conf, append)
   conf = parse_conf(conf)
   local c = append or config.new()

   config.app(c, "PublicDispatch", dispatch.PublicDispatch, {
                 node_ip4 = conf.public_interface.ip4
   })
   config.app(c, "PublicRouter", route.PublicRouter, {
                 routes = conf.route
   })
   config.app(c, "PublicICMP4", icmp.ICMP4, {
                 node_ip4 = conf.public_interface.ip4
   })
   config.app(c, "PublicNextHop", nexthop.NextHop4, {
                 node_mac = conf.public_interface.mac,
                 node_ip4 = conf.public_interface.ip4,
                 nexthop_ip4 = conf.public_interface.nexthop_ip4,
                 nexthop_mac = conf.public_interface.nexthop_mac
   })
   config.link(c, "PublicDispatch.forward4 -> PublicRouter.input")
   config.link(c, "PublicDispatch.icmp4 -> PublicICMP4.input")
   config.link(c, "PublicDispatch.arp -> PublicNextHop.arp")
   config.link(c, "PublicDispatch.protocol4_unreachable -> PublicICMP4.protocol_unreachable")
   config.link(c, "PublicICMP4.output -> PublicNextHop.icmp4")

   config.app(c, "Protocol_in", Transmitter)
   config.app(c, "Protocol_out", Receiver)
   config.link(c, "PublicDispatch.protocol -> Protocol_in.input")
   config.link(c, "Protocol_out.output -> PublicNextHop.protocol")

   for id, route in pairs(conf.route) do
      local public_in = "PublicRouter."..id
      local DSP_in = "DSP_"..id.."_in"
      config.app(c, DSP_in, Transmitter)
      config.link(c, public_in.." -> "..DSP_in..".input")

      local public_out = "PublicNextHop."..id
      local ESP_out = "ESP_"..id.."_out"
      local Tunnel = "Tunnel_"..id
      config.app(c, ESP_out, Receiver)
      config.app(c, Tunnel, tunnel.Tunnel4,
                 {src=conf.public_interface.ip4, dst=route.gw_ip4})
      config.link(c, ESP_out..".output -> "..Tunnel..".input")
      config.link(c, Tunnel..".output -> "..public_out)
   end

   local public_links = {
      input = "PublicDispatch.input",
      output = "PublicNextHop.output"
   }

   return c, public_links
end

local function nic_config (conf, interface)
   numa.check_affinity_for_pci_addresses({conf[interface].pci})
   local needs_vmdq = pci.canonical(conf.private_interface.pci)
                   == pci.canonical(conf.public_interface.pci)
   return {
      pciaddr = conf[interface].pci,
      vmdq = needs_vmdq,
      macaddr = needs_vmdq and conf[interface].mac
   }
end

function configure_private_router_with_nic (conf, append)
   conf = parse_conf(conf)

   local c, private =
      configure_private_router(conf, append or config.new())

   config.app(c, "PrivateNIC", intel_mp.Intel,
              nic_config(conf, 'private_interface'))
   config.link(c, "PrivateNIC.output -> "..private.input)
   config.link(c, private.output.." -> PrivateNIC.input")

   return c
end

function configure_public_router_with_nic (conf, append)
   conf = parse_conf(conf)

   local c, public =
      configure_public_router(conf, append or config.new())

   config.app(c, "PublicNIC", intel_mp.Intel,
              nic_config(conf, 'public_interface'))
   config.link(c, "PublicNIC.output -> "..public.input)
   config.link(c, public.output.." -> PublicNIC.input")

   return c
end

function configure_exchange (conf, append)
   conf = parse_conf(conf)
   local c = append or config.new()

   config.app(c, "KeyExchange", exchange.KeyManager, {
                 node_ip4 = conf.public_interface.ip4,
                 routes = conf.route,
                 sa_db_path = sa_db_path,
                 negotiation_ttl = conf.negotiation_ttl,
                 sa_ttl = conf.sa_ttl
   })
   config.app(c, "Protocol_in", Receiver)
   config.app(c, "Protocol_out", Transmitter)
   config.link(c, "Protocol_in.output -> KeyExchange.input")
   config.link(c, "KeyExchange.output -> Protocol_out.input")

   return c
end

-- sa_db := { outbound_sa={<spi>=(SA), ...}, inbound_sa={<spi>=(SA), ...} }
-- (see exchange)

function configure_esp (sa_db, append)
   local c = append or config.new()

   if not sa_db.outbound_sa then return c end

   for key, sa in cltable.pairs(sa_db.outbound_sa) do
      -- Configure interlink receiver/transmitter for outbound SA
      local ESP_in = "ESP_"..sa.route.."_in"
      local ESP_out = "ESP_"..sa.route.."_out"
      config.app(c, ESP_in, Receiver)
      config.app(c, ESP_out, Transmitter)
      -- Configure outbound SA
      local ESP = "ESP_"..sa.route
      config.app(c, ESP, tunnel.Encapsulate, {
                    spi = key.spi,
                    aead = sa.aead,
                    key = sa.key,
                    salt = sa.salt
      })
      config.link(c, ESP_in..".output -> "..ESP..".input4")
      config.link(c, ESP..".output -> "..ESP_out..".input")
   end

   return c
end

function configure_dsp (sa_db, append)
   local c = append or config.new()

   if not sa_db.inbound_sa then return c end

   for key, sa in cltable.pairs(sa_db.inbound_sa) do
      -- Configure interlink receiver/transmitter for inbound SA
      local DSP_in = "DSP_"..sa.route.."_in"
      local DSP_out = "DSP_"..sa.route.."_out"
      config.app(c, DSP_in, Receiver)
      config.app(c, DSP_out, Transmitter)
      -- Configure inbound SA
      local DSP = "DSP_"..sa.route
      config.app(c, DSP, tunnel.Decapsulate, {
                    spi = key.spi,
                    aead = sa.aead,
                    key = sa.key,
                    salt = sa.salt
      })
      config.link(c, DSP_in..".output -> "..DSP..".input")
      config.link(c, DSP..".output4 -> "..DSP_out..".input")
   end

   return c
end

function load_config (schema, confpath)
   return yang.load_config_for_schema(
      schema, lib.readfile(confpath, "a*"), confpath
   )
end
