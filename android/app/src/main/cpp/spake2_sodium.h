// SPAKE2 over Ed25519, wire-compatible with BoringSSL's SPAKE2 (the one adb
// pairing uses: SPAKE2_CTX_new / SPAKE2_generate_msg / SPAKE2_process_msg,
// with the default "password scalar hack" on).
//
// All group and scalar arithmetic is libsodium's (crypto_core_ed25519_* and
// crypto_scalarmult_ed25519_*); this file only orchestrates the protocol and
// never touches field elements itself. libsodium is reached through
// [spake2_api] so the same code links directly (host tests) or through
// dlopen (the Android app, which already bundles libsodium.so).
#ifndef WHISPER_SPAKE2_SODIUM_H
#define WHISPER_SPAKE2_SODIUM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPAKE2_ROLE_ALICE 0  // adb pairing client
#define SPAKE2_ROLE_BOB 1    // adb pairing server (adbd)

#define SPAKE2_MSG_BYTES 32
#define SPAKE2_KEY_BYTES 64
#define SPAKE2_MAX_NAME 64

typedef struct {
  void (*randombytes_buf)(void *buf, size_t size);
  void (*scalar_reduce)(unsigned char *r, const unsigned char *s);
  void (*scalar_mul)(unsigned char *z, const unsigned char *x,
                     const unsigned char *y);
  int (*scalar_invert)(unsigned char *recip, const unsigned char *s);
  int (*core_add)(unsigned char *r, const unsigned char *p,
                  const unsigned char *q);
  int (*core_sub)(unsigned char *r, const unsigned char *p,
                  const unsigned char *q);
  int (*base_noclamp)(unsigned char *q, const unsigned char *n);
  int (*noclamp)(unsigned char *q, const unsigned char *n,
                 const unsigned char *p);
  int (*sha512)(unsigned char *out, const unsigned char *in,
                unsigned long long inlen);
} spake2_api;

typedef struct {
  int role;
  unsigned char my_name[SPAKE2_MAX_NAME];
  size_t my_name_len;
  unsigned char their_name[SPAKE2_MAX_NAME];
  size_t their_name_len;
  unsigned char s[32];   // 8·x mod L: the ephemeral scalar (cofactor cleared)
  unsigned char t[32];   // h(pw)·8⁻¹ mod L: scales 8M / 8N to the mask
  unsigned char ph[64];  // SHA-512(password), unreduced (transcript input)
  unsigned char my_msg[SPAKE2_MSG_BYTES];
  int state;  // 0 init, 1 message generated, 2 key derived
} spake2_ctx;

// Precomputes 8M, 8N and 8⁻¹ once. Returns 0 on success.
int spake2_setup(const spake2_api *api);

// Names are the raw bytes BoringSSL is given (adb includes the trailing NUL).
int spake2_ctx_init(spake2_ctx *ctx, int role, const unsigned char *my_name,
                    size_t my_name_len, const unsigned char *their_name,
                    size_t their_name_len);

// x64 may be NULL (random) or 64 bytes to fix the ephemeral scalar (tests).
int spake2_generate(spake2_ctx *ctx, const spake2_api *api,
                    const unsigned char *password, size_t password_len,
                    const unsigned char *x64,
                    unsigned char out_msg[SPAKE2_MSG_BYTES]);

int spake2_process(spake2_ctx *ctx, const spake2_api *api,
                   const unsigned char their_msg[SPAKE2_MSG_BYTES],
                   unsigned char out_key[SPAKE2_KEY_BYTES]);

#ifdef __cplusplus
}
#endif

#endif  // WHISPER_SPAKE2_SODIUM_H
