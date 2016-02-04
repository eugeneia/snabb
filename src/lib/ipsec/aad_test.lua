module(..., package.seeall)
local ffi = require("ffi")
local C = ffi.C
require("apps.ipsec.aes_128_gcm_h")

function selftest ()
   local gcm_data = ffi.new("gcm_data[1] __attribute__((aligned(16)))")
   local keymat = ffi.new("uint8_t[16]")
   C.aes_keyexp_128_enc_avx(keymat, gcm_data[0].expanded_keys)
   local hash_subkey = ffi.new("uint8_t[?] __attribute__((aligned(16)))", 128)
   C.aesni_gcm_precomp_avx_gen4(gcm_data, hash_subkey)
   local iv_size = 16
   local iv = ffi.new("uint8_t[?] __attribute__((aligned(16)))", 16)
   iv[12] = 0x1
   local aad_size = 12
   local aad = ffi.new("uint8_t[?] __attribute__((aligned(16)))", aad_size+4)
   local auth_size = 16
   local auth1 = ffi.new("uint8_t[?] __attribute__((aligned(16)))", auth_size)
   local auth2 = ffi.new("uint8_t[?] __attribute__((aligned(16)))", auth_size)
   local length = 100
   local p = ffi.new("uint8_t[?]", length)
   C.aesni_gcm_enc_avx_gen4(gcm_data,
                              p, p, length,
                              iv,
                              aad, aad_size,
                              auth1, auth_size)
   aad[0] = 42 -- Change AAD
   C.aesni_gcm_dec_avx_gen4(gcm_data,
                              p, p, length,
                              iv,
                              aad, aad_size,
                              auth2, auth_size)
   assert(C.memcmp(auth1, auth2, auth_size) ~= 0, "AAD fail.")
end
