// sodium/core.h
int sodium_init(void);

// sodium/randombytes.h:
void randombytes_buf(void * const buf, const size_t size);

// sodium/crypto_aead_xchacha20poly1305.h
enum {
  crypto_aead_xchacha20poly1305_ietf_NPUBBYTES = 24U,
  crypto_aead_xchacha20poly1305_ietf_KEYBYTES = 32U,
  crypto_aead_xchacha20poly1305_ietf_ABYTES = 16U
};
int crypto_aead_xchacha20poly1305_ietf_encrypt(unsigned char *c,
                                               unsigned long long *clen_p,
                                               const unsigned char *m,
                                               unsigned long long mlen,
                                               const unsigned char *ad,
                                               unsigned long long adlen,
                                               const unsigned char *nsec,
                                               const unsigned char *npub,
                                               const unsigned char *k);
int crypto_aead_xchacha20poly1305_ietf_decrypt(unsigned char *m,
                                               unsigned long long *mlen_p,
                                               unsigned char *nsec,
                                               const unsigned char *c,
                                               unsigned long long clen,
                                               const unsigned char *ad,
                                               unsigned long long adlen,
                                               const unsigned char *npub,
                                               const unsigned char *k);
