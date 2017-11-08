-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local S = require("syscall")
local ffi = require("ffi")
local shm = require("core.shm")
local counter = require("core.counter")
local lib = require("core.lib")
local ipv4 = require("lib.protocol.ipv4")
local yang = require("lib.yang.yang")
local logger = lib.logger_new({ rate = 32, module = 'KeyManager' })
require("lib.sodium_h")
local C = ffi.C

PROTOCOL = 99 -- “Any private encryption scheme”

KeyManager = {
   name = "KeyManager",
   config = {
      node_ip4 = {required=true},
      routes = {required=true},
      esp_keyfile = {required=true},
      dsp_keyfile = {required=true},
      negotiation_ttl = {default=10},
      sa_ttl = {default=(7 * 24 * 60 * 60)}
   },
   shm = {
      rxerrors = {counter},
      route_errors = {counter},
      authentication_errors = {counter},
      negotiations_expired = {counter},
      keypairs_exchanged = {counter},
      keypairs_expired = {counter}
   }
}

local status = { expired = 0, negotiating = 1, ready = 2 }

function KeyManager:new (conf)
   local o = {
      node_ip4n = ipv4:pton(conf.node_ip4),
      routes = {},
      esp_keyfile = shm.root.."/"..shm.resolve(conf.esp_keyfile),
      dsp_keyfile = shm.root.."/"..shm.resolve(conf.dsp_keyfile),
      negotiation_ttl = conf.negotiation_ttl,
      sa_ttl = conf.sa_ttl,
      ip = ipv4:new({})
   }
   for id, route in pairs(conf.routes) do
      o.routes[#o.routes+1] = {
         id = id,
         gw_ip4 = route.gw_ip4,
         gw_ip4n = ipv4:pton(route.gw_ip4), -- for fast compare
         preshared_key = lib.hexundump(
            route.preshared_key,
            C.crypto_aead_xchacha20poly1305_ietf_KEYBYTES
         ),
         status = status.expired,
         tx_sa = nil, rx_sa = nil,
         timeout = nil
      }
   end
   assert(not (C.sodium_init() < 0), "Failed to initialize libsodium.")
   return setmetatable(o, { __index = KeyManager })
end

function KeyManager:push ()
   local input = self.input.input
   while not link.empty(input) do
      local request = link.receive(input)
      self:handle_negotiation(request)
      packet.free(request)
   end
   for _, route in ipairs(self.routes) do
      if route.status == status.expired then
         self:negotiate(route)
      end
   end
end

--[[
function KeyManager:reconfig ()
   -- TODO: reconfigure without clobbering SAs
end
]]--

local function randombytes (n)
   local bytes = ffi.new("uint8_t[?]", n)
   C.randombytes_buf(bytes, n)
   return bytes
end

function KeyManager:negotiate (route)
   logger:log("Sending key exchange request to "..route.gw_ip4)

   route.status = status.negotiating
   self:set_negotiation_timeout(route)

   route.tx_sa = {
      mode = "aes-gcm-128-12",
      spi = math.max(1, ffi.cast("uint32_t *", randombytes(2))[0]),
      key = lib.hexdump(ffi.string(randombytes(16), 16)),
      salt = lib.hexdump(ffi.string(randombytes(4), 4))
   }

   link.transmit(self.output.output, self:request(route))
end

function KeyManager:handle_negotiation (request)
   local route, sa = self:parse_request(request)
   if not route then
      counter.add(self.shm.rxerrors)
      logger:log("Ignoring malformed key exchange request")
      return
   end

   logger:log("Received key exchange request from "..route.gw_ip4)

   route.rx_sa = sa

   if route.status == status.negotiating then
      counter.add(self.shm.keypairs_exchanged)
      logger:log("Completed key exchange with "..route.gw_ip4)
      route.status = status.ready
      timer.deactivate(route.timeout)
      self:set_sa_timeout(route)
      self:commit_ephemeral_keys()
   else
      self:negotiate(route)
   end
end

function KeyManager:set_negotiation_timeout (route)
   route.timeout = timer.new(
      "negotiation_ttl",
      function ()
         counter.add(self.shm.negotiations_expired)
         logger:log("Expiring keys for "..route.gw_ip4.." (negotiation_ttl)")
         self:expire_route(route)
      end,
      self.negotiation_ttl * 1e9
   )
   timer.activate(route.timeout)
end

function KeyManager:set_sa_timeout (route)
   route.timeout = timer.new(
      "sa_ttl",
      function ()
         counter.add(self.shm.keypairs_expired)
         logger:log("Expiring keys for "..route.gw_ip4.." (sa_ttl)")
         self:expire_route(route)
      end,
      self.sa_ttl * 1e9
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

local request_t = ffi.typeof([[struct {
  uint32_t spi;
  uint8_t key[16];
  uint8_t salt[4];
} __attribute__((packed))]])

local request_t_ptr_t = ffi.typeof("$*", request_t)
local request_t_length = ffi.sizeof(request_t)

local request_trailer_t = ffi.typeof([[struct {
  uint8_t icv[]]..C.crypto_aead_xchacha20poly1305_ietf_ABYTES..[[];
  uint8_t nonce[]]..C.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES..[[];
} __attribute__((packed))]])

local request_trailer_t_ptr_t = ffi.typeof("$*", request_trailer_t)
local request_trailer_t_length = ffi.sizeof(request_trailer_t)

local request_length =
   ipv4:sizeof() + request_t_length + request_trailer_t_length

local request_aad_length = 8 -- IPv4 source and destination addresses

function KeyManager:request (route)
   local request = packet.allocate()

   self.ip:new({
         total_length = request_length,
         ttl = 64,
         protocol = PROTOCOL,
         src = self.node_ip4n,
         dst = route.gw_ip4n
   })
   packet.append(request, self.ip:header(), ipv4:sizeof())

   packet.resize(request, request_length)

   local body = ffi.cast(request_t_ptr_t, request.data + ipv4:sizeof())
   body.spi = lib.htonl(route.tx_sa.spi)
   ffi.copy(body.key, lib.hexundump(route.tx_sa.key, 16), 16)
   ffi.copy(body.salt, lib.hexundump(route.tx_sa.salt, 4), 4)

   local trailer = ffi.cast(request_trailer_t_ptr_t,
                            request.data + ipv4:sizeof() + request_t_length)
   C.randombytes_buf(trailer.nonce,
                     C.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES)

   local ciphertext = ffi.cast("uint8_t *", body)

   C.crypto_aead_xchacha20poly1305_ietf_encrypt(
      -- encrypt in-place, no clen_p
      ciphertext, nil, ciphertext, request_t_length,
      -- use src and dst IP as additional authentication data
      request.data, request_aad_length,
      -- no secret nonce (nsec), use nonce from trailer and route’s key
      nil, trailer.nonce, route.preshared_key
   )

   return request
end

function KeyManager:parse_request (request)
   if request.length ~= request_length then return end

   self.ip:new_from_mem(request.data, ipv4:sizeof())
   if self.ip:protocol() ~= PROTOCOL or not self.ip:dst_eq(self.node_ip4n) then
      return
   end

   local route = nil
   for _, r in ipairs(self.routes) do
      if self.ip:src_eq(r.gw_ip4n) then
         route = r
         break
      end
   end
   if not route then
      counter.add(self.shm.route_errors)
      return
   end

   local body = ffi.cast(request_t_ptr_t, request.data + ipv4:sizeof())
   local trailer = ffi.cast(request_trailer_t_ptr_t,
                            request.data + ipv4:sizeof() + request_t_length)
   local ciphertext = ffi.cast("uint8_t *", body)

   if 0 ~= C.crypto_aead_xchacha20poly1305_ietf_decrypt(
      -- decrypt in-place, no secret nonce (nsec), no mlen_p
      ciphertext, nil, nil, ciphertext,
      -- cyphertext length
      request_t_length + C.crypto_aead_xchacha20poly1305_ietf_ABYTES,
      -- authenticate src and dst addresses
      request.data, request_aad_length,
      -- use nonce from trailer and route’s key
      trailer.nonce, route.preshared_key
   ) then
      counter.add(self.shm.authentication_errors)
      return
   end

   local sa = {
      mode = "aes-gcm-128-12",
      spi = lib.ntohl(body.spi),
      key = lib.hexdump(ffi.string(body.key, 16)),
      salt = lib.hexdump(ffi.string(body.salt, 4))
   }

   return route, sa
end

local function store_ephemeral_keys (path, keys)
   local f = assert(io.open(path, "w"), "Unable to open file: "..path)
   yang.print_data_for_schema_by_name('vita-ephemeral-keys', {route=keys}, f)
   f:close()
end

-- ephemeral_keys := { { gw_ip4=(IPv4), [ sa=(SA) ] }, ... }
function KeyManager:commit_ephemeral_keys ()
   local esp_keys, dsp_keys = {}, {}
   for _, route in ipairs(self.routes) do
      esp_keys[route.id] = {
         gw_ip4 = route.gw_ip4,
         sa = (route.status == status.ready) and route.tx_sa or nil
      }
      dsp_keys[route.id] = {
         gw_ip4 = route.gw_ip4,
         sa = (route.status == status.ready) and route.rx_sa or nil
      }
   end
   store_ephemeral_keys(self.esp_keyfile, esp_keys)
   store_ephemeral_keys(self.dsp_keyfile, dsp_keys)
end
