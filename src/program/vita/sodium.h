/* Use of this source code is governed by the Apache 2.0 license; see COPYING. */

// core.h
int sodium_init(void);

// randombytes.h:
void randombytes_buf(void * const buf, const size_t size);

// crypto_auth_hmacsha512256.h
enum {
  crypto_auth_hmacsha512256_BYTES = 32U,
  crypto_auth_hmacsha512256_KEYBYTES = 32U
};
int crypto_auth_hmacsha512256(unsigned char *out, const unsigned char *in,
                              unsigned long long inlen,const unsigned char *k);
int crypto_auth_hmacsha512256_verify(const unsigned char *h,
                                     const unsigned char *in,
                                     unsigned long long inlen,
                                     const unsigned char *k);

// crypto_scalarmult_curve25519.h
enum {
  crypto_scalarmult_curve25519_BYTES = 32U,
  crypto_scalarmult_curve25519_SCALARBYTES = 32U
};
int crypto_scalarmult_curve25519_base(unsigned char *q,
                                      const unsigned char *n);
int crypto_scalarmult_curve25519(unsigned char *q,
                                 const unsigned char *n,
                                 const unsigned char *p)

// crypto_generichash_blake2b.h
enum {
  crypto_generichash_blake2b_BYTES = 32U,
  crypto_generichash_blake2b_KEYBYTES = 32U
};
struct CRYPTO_ALIGN(64) crypto_generichash_blake2b_state {
    uint64_t h[8];
    uint64_t t[2];
    uint64_t f[2];
    uint8_t  buf[2 * 128];
    size_t   buflen;
    uint8_t  last_node;
} __attribute__ ((aligned(64)));
int crypto_generichash_blake2b_init(crypto_generichash_blake2b_state *state,
                                    const unsigned char *key,
                                    const size_t keylen, const size_t outlen);
int crypto_generichash_blake2b_update(crypto_generichash_blake2b_state *state,
                                      const unsigned char *in,
                                      unsigned long long inlen);
int crypto_generichash_blake2b_final(crypto_generichash_blake2b_state *state,
                                     unsigned char *out,
                                     const size_t outlen);
