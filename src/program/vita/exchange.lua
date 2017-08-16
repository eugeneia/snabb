-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local S = require("syscall")
local shm = require("core.shm")
local lib = require("core.lib")
local ipv4 = require("lib.protocol.ipv4")

PROTOCOL = 253 -- “Use for experimentation and testing”

KeyManager = {
   config = {
      routes = {required=true},
      esp_keyfile = {required=true},
      dsp_keyfile = {required=true},
      negotiation_ttl = {default=10},
      sa_ttl = {default=(7 * 24 * 60 * 60)},
      testing = {default=false}
   }
}

local status = { expired = 0, negotiating = 1, ready = 2 }

function KeyManager:new (conf)
   local o = {
      routes = {},
      esp_keyfile = shm.root.."/"..shm.resolve(conf.esp_keyfile),
      dsp_keyfile = shm.root.."/"..shm.resolve(conf.dsp_keyfile),
      negotiation_ttl = conf.negotiation_ttl,
      sa_ttl = conf.sa_ttl,
      testing = conf.testing
   }
   for _, route in ipairs(conf.routes) do
      o.routes[#o.routes+1] = {
         gw_ip4 = route.gw_ip4,
         gw_ip4n = ipv4:pton(route.gw_ip4), -- for fast compare
         preshared_key = lib.hexundump(route.preshared_key, 512),
         status = status.expired,
         tx_sa = nil, rx_sa = nil,
         timeout = nil
      }
   end
   return setmetatable(o, { __index = KeyManager })
end

function KeyManager:push ()
   local input, output = self.input.input, self.output.output
   for _=1,link.nreadable(input) do
      local request = link.receive(input)
      -- TODO: handle key exchange request or reply
      --  * call self:start_negotiation(route) when starting negotiation
      --  * deactivate route.timeout (negotiation_ttl)
      --  * set route.timeout to sa_ttl and activate
      --  * call self:commit_ephemeral_keys() when negotiation is complete
      packet.free(request)
   end
   for _, route in ipairs(self.routes) do
      if route.status == status.expired then
         self:start_negotiation(route)
         self:negotiate(route)
      end
   end
end

--[[
function KeyManager:reconfig ()
   -- TODO: reconfigure without clobbering SAs
end
]]--

function KeyManager:negotiate (route)
   if not self.testing then
      -- TODO: should send key exchange request here
   else
      self:negotiate_testing(route)
   end
end

function KeyManager:start_negotiation (route)
   route.status = status.negotiating
   route.timeout = timer.new(
      "negotiation_ttl",
      function () self:expire_route(route) end,
      self.negotiation_ttl * 1e9
   )
   timer.activate(route.timeout)
end

function KeyManager:expire_route (route)
   route.status = status.expired
   route.tx_sa = nil
   route.rx_sa = nil
   route.timeout = nil
   self:commit_ephemeral_keys()
end

-- ephemeral_keys := { { gw_ip4=(IPv4), [ sa=(SA) ] }, ... }
function KeyManager:commit_ephemeral_keys ()
   local esp_conf, dsp_conf = {}, {}
   for _, route in ipairs(self.routes) do
      esp_conf[#esp_conf+1] = {
         gw_ip4 = route.gw_ip4,
         sa = (route.status == status.ready) and route.tx_sa
      }
      dsp_conf[#dsp_conf+1] = {
         gw_ip4 = route.gw_ip4,
         sa = (route.status == status.ready) and route.rx_sa
      }
   end
   lib.store_conf(self.esp_keyfile, esp_conf)
   lib.store_conf(self.dsp_keyfile, dsp_conf)
end


function KeyManager:negotiate_testing (route)
   print("WARNING: Negotiating testing SAs to "..route.gw_ip4)
   print("    ...: (If you didn’t expect this, something is very wrong!)")
   route.status = status.ready
   local test_sa = {
      spi = 0x0,
      mode = "aes-gcm-128-12",
      key = "00112233445566778899AABBCCDDEEFF",
      salt = "00112233"
   }
   route.tx_sa = test_sa
   route.rx_sa = test_sa
   timer.deactivate(route.timeout)
   route.timeout = timer.new(
      "sa_ttl",
      function () self:expire_route(route) end,
      self.sa_ttl * 1e9
   )
   timer.activate(route.timeout)
   self:commit_ephemeral_keys()
end
