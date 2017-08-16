-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local lib = require("core.lib")
local shm = require("core.shm")
local route = require("program.vita.route")
local tunnel = require("program.vita.tunnel")
local nexthop = require("program.vita.nexthop")
local exchange = require("program.vita.exchange")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local C = require("ffi").C

local confspec = {
   node_ip4 = {required=true},
   routes = {required=true},
   public_nexthop = {required=true},  -- { mac(MAC) }
   private_nexthop = {required=true}, -- { mac(MAC) }
   esp_keyfile = {default="group/esp_ephemeral_keys"},
   dsp_keyfile = {default="group/dsp_ephemeral_keys"},
   negotiation_ttl = {},
   sa_ttl = {},
   testing = {}
}

function configure_router (conf)
   conf = lib.parse(conf, confspec)
   local c = config.new()

   config.app(c, "PrivateRouter", route.PrivateRouter, {routes=conf.routes})
   config.app(c, "PrivateNextHop", nexthop.NextHop4, conf.private_nexthop)

   config.app(c, "PublicRouter", route.PublicRouter, {
                 routes = conf.routes,
                 node_ip4 = conf.node_ip4
   })
   config.app(c, "PublicNextHop", nexthop.NextHop4, conf.public_nexthop)

   config.app(c, "KeyExchange", exchange.KeyManager, {
                 routes = conf.routes,
                 esp_keyfile = conf.esp_keyfile,
                 dsp_keyfile = conf.dsp_keyfile,
                 negotation_ttl = conf.negotation_ttl,
                 sa_ttl = conf.sa_ttl,
                 testing = conf.testing
   })
   config.link(c, "PublicRouter.protocol -> KeyExchange.input")
   config.link(c, "KeyExchange.output -> PublicNextHop.protocol")

   for _, route in ipairs(conf.routes) do
      local private_in = "PrivateRouter."..config.link_name(route.net_cidr4)
      local public_out = "PublicNextHop."..config.link_name(route.gw_ip4)
      local ESP_in = "ESP_"..config.link_name(route.gw_ip4).."_in"
      local ESP_out = "ESP_"..config.link_name(route.gw_ip4).."_out"
      local Tunnel = "Tunnel_"..config.link_name(route.gw_ip4)
      config.app(c, ESP_in, Transmitter, {name="group/interlink/"..ESP_in})
      config.app(c, ESP_out, Receiver, {name="group/interlink/"..ESP_out})
      config.app(c, Tunnel, tunnel.Tunnel4,
                 {src=conf.node_ip4, dst=route.gw_ip4})
      config.link(c, private_in.." -> "..ESP_in..".input")
      config.link(c, ESP_out..".output -> "..Tunnel..".input")
      config.link(c, Tunnel..".output -> "..public_out)
      local public_in = "PublicRouter."..config.link_name(route.gw_ip4)
      local private_out = "PrivateNextHop."..config.link_name(route.net_cidr4)
      local DSP_in = "DSP_"..config.link_name(route.gw_ip4).."_in"
      local DSP_out = "DSP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, DSP_in, Transmitter, {name="group/interlink/"..DSP_in})
      config.app(c, DSP_out, Receiver, {name="group/interlink/"..DSP_out})
      config.link(c, public_in.." -> "..DSP_in..".input")
      config.link(c, DSP_out..".output -> "..private_out)
   end

   local private_links = {
      input = "PrivateRouter.input",
      output = "PrivateNextHop.output"
   }
   local public_links = {
      input = "PublicRouter.input",
      output = "PublicNextHop.output"
   }
   return c, private_links, public_links
end


-- ephemeral_keys := { { gw_ip4=(IPv4), [ sa=(SA) ] }, ... }   (see exchange)

function configure_esp (ephemeral_keys)
   local c = config.new()

   for _, route in ipairs(ephemeral_keys) do
      -- Configure interlink receiver/transmitter for route
      local ESP_in = "ESP_"..config.link_name(route.gw_ip4).."_in"
      local ESP_out = "ESP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, ESP_in, Receiver, {name="group/interlink/"..ESP_in})
      config.app(c, ESP_out, Transmitter, {name="group/interlink/"..ESP_out})
      -- Configure SA if present
      if route.sa then
         local ESP = "ESP_"..route.sa.spi
         config.app(c, ESP, tunnel.Encapsulate, route.sa)
         config.link(c, ESP_in..".output -> "..ESP..".input4")
         config.link(c, ESP..".output -> "..ESP_out..".input")
      end
   end

   return c
end

function configure_dsp (ephemeral_keys)
   local c = config.new()

   for _, route in ipairs(ephemeral_keys) do
      -- Configure interlink receiver/transmitter for route
      local DSP_in = "DSP_"..config.link_name(route.gw_ip4).."_in"
      local DSP_out = "DSP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, DSP_in, Receiver, {name="group/interlink/"..DSP_in})
      config.app(c, DSP_out, Transmitter, {name="group/interlink/"..DSP_out})
      -- Configure SA if present
      if route.sa then
         local DSP = "DSP_"..route.sa.spi
         config.app(c, DSP, tunnel.Decapsulate, route.sa)
         config.link(c, DSP_in..".output -> "..DSP..".input")
         config.link(c, DSP..".output4 -> "..DSP_out..".input")
      end
   end

   return c
end

function esp_worker (keyfile, reconf_interval)
   keyfile = shm.root.."/"..shm.resolve(
      keyfile or confspec.esp_keyfile.default
   )
   engine.log = true
   listen_confpath(keyfile, configure_esp, reconf_interval)
end

function dsp_worker (keyfile, reconf_interval)
   keyfile = shm.root.."/"..shm.resolve(
      keyfile or confspec.dsp_keyfile.default
   )
   -- engine.log = true
   listen_confpath(keyfile, configure_dsp, reconf_interval)
end


function listen_confpath (confpath, loader, interval)
   interval = interval or 1e9

   local mtime = 0
   local needs_reconfigure = true
   timer.activate(timer.new(
      "check-for-reconfigure",
      function () needs_reconfigure = C.stat_mtime(confpath) ~= mtime end,
      interval,
      "repeating"
   ))

   local function run_loader ()
      return loader(lib.load_conf(confpath))
   end

   while true do
      needs_reconfigure = false
      local success, c = pcall(run_loader)
      if success then
         print("Reconfigure: loaded "..confpath)
         mtime = C.stat_mtime(confpath)
         engine.configure(c)
      else
         print("Reconfigure: error: "..c)
      end
      engine.main({done=function() return needs_reconfigure end})
   end
end
