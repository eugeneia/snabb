-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local lib = require("core.lib")
local route = require("program.vita.route")
local tunnel = require("program.vita.tunnel")
local nexthop = require("program.vita.nexthop")

local confspec = {
   node_ip4 = {required=true},
   routes = {required=true},
   public_nexthop = {required=true}, -- { mac(MAC) }
   private_nexthop = {required=true} -- { mac(MAC) }
}

function configure (conf)
   conf = lib.parse(conf, confspec)
   local c = config.new()

   config.app(c, "PrivateRouter", route.PrivateRouter, {routes=conf.routes})
   config.app(c, "PrivateNextHop", nexthop.NextHop4, conf.private_nexthop)
   config.app(c, "PublicRouter", route.PublicRouter, {routes=conf.routes})
   config.app(c, "PublicNextHop", nexthop.NextHop4, conf.public_nexthop)

   for _, route in ipairs(conf.routes) do
      local private_in = "PrivateRouter."..config.link_name(route.net_cidr4)
      local public_out = "PublicNextHop."..config.link_name(route.gw_ip4)
      local ESP = "ESP_"..route.tx_sa.spi
      local Tunnel = "Tunnel_"..config.link_name(route.gw_ip4)
      config.app(c, ESP, tunnel.Encapsulate, route.tx_sa)
      config.app(c, Tunnel, tunnel.Tunnel4,
                 {src=conf.node_ip4, dst=route.gw_ip4})
      config.link(c, private_in.." -> "..ESP..".input4")
      config.link(c, ESP..".output -> "..Tunnel..".input")
      config.link(c, Tunnel..".output -> "..public_out)
      local public_in = "PublicRouter."..config.link_name(route.gw_ip4)
      local private_out = "PrivateNextHop."..config.link_name(route.net_cidr4)
      local DSP = "DSP_"..route.rx_sa.spi
      config.app(c, DSP, tunnel.Decapsulate, route.rx_sa)
      config.link(c, public_in.." -> "..DSP..".input")
      config.link(c, DSP..".output4 -> "..private_out)
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
