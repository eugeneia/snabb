-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local lib = require("core.lib")
local route = require("program.vita.route")
local tunnel = require("program.vita.tunnel")
local nexthop = require("program.vita.nexthop")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")

local confspec = {
   node_ip4 = {required=true},
   routes = {required=true},
   public_nexthop = {required=true}, -- { mac(MAC) }
   private_nexthop = {required=true} -- { mac(MAC) }
}

function setup_interlinks (conf)
   for _, route in ipairs(conf.routes) do
      interlink.create("group/interlink/ESP_in_"..route.tx_sa.spi)
      interlink.create("group/interlink/ESP_out_"..route.tx_sa.spi)
      interlink.create("group/interlink/DSP_in_"..route.rx_sa.spi)
      interlink.create("group/interlink/DSP_out_"..route.rx_sa.spi)
   end
end

function configure_router (conf)
   conf = lib.parse(conf, confspec)
   local c = config.new()

   config.app(c, "PrivateRouter", route.PrivateRouter, {routes=conf.routes})
   config.app(c, "PrivateNextHop", nexthop.NextHop4, conf.private_nexthop)
   config.app(c, "PublicRouter", route.PublicRouter, {routes=conf.routes})
   config.app(c, "PublicNextHop", nexthop.NextHop4, conf.public_nexthop)

   for _, route in ipairs(conf.routes) do
      local private_in = "PrivateRouter."..config.link_name(route.net_cidr4)
      local public_out = "PublicNextHop."..config.link_name(route.gw_ip4)
      local ESP_in = "ESP_in_"..route.tx_sa.spi
      local ESP_out = "ESP_out_"..route.tx_sa.spi
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
      local DSP_in = "DSP_in_"..route.rx_sa.spi
      local DSP_out = "DSP_out_"..route.rx_sa.spi
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

function configure_esp (conf)
   conf = lib.parse(conf, confspec)
   local c = config.new()

   for _, route in ipairs(conf.routes) do
      local ESP = "ESP_"..route.tx_sa.spi
      local ESP_in = "ESP_in_"..route.tx_sa.spi
      local ESP_out = "ESP_out_"..route.tx_sa.spi
      config.app(c, ESP, tunnel.Encapsulate, route.tx_sa)
      config.app(c, ESP_in, Receiver, {name="group/interlink/"..ESP_in})
      config.app(c, ESP_out, Transmitter, {name="group/interlink/"..ESP_out})
      config.link(c, ESP_in..".output -> "..ESP..".input4")
      config.link(c, ESP..".output -> "..ESP_out..".input")
   end

   return c
end

function configure_dsp (conf)
   conf = lib.parse(conf, confspec)
   local c = config.new()

   for _, route in ipairs(conf.routes) do
      local DSP = "DSP_"..route.rx_sa.spi
      local DSP_in = "DSP_in_"..route.rx_sa.spi
      local DSP_out = "DSP_out_"..route.rx_sa.spi
      config.app(c, DSP, tunnel.Decapsulate, route.rx_sa)
      config.app(c, DSP_in, Receiver, {name="group/interlink/"..DSP_in})
      config.app(c, DSP_out, Transmitter, {name="group/interlink/"..DSP_out})
      config.link(c, DSP_in..".output -> "..DSP..".input")
      config.link(c, DSP..".output4 -> "..DSP_out..".input")
   end

   return c
end

function offload_worker (configure, confpath)
   local conf = lib.load_conf(confpath)
   engine.configure(configure(conf))
   engine.main()
end

function offload_worker_esp (confpath)
   offload_worker(configure_esp, confpath)
end

function offload_worker_dsp (confpath)
   offload_worker(configure_dsp, confpath)
end
