// See spake2_sodium.h. The construction mirrors BoringSSL's
// crypto/curve25519/spake25519.cc step by step; comments name the
// BoringSSL step each line reproduces.
#include "spake2_sodium.h"

#include <string.h>

// BoringSSL's fixed points (spake25519.cc, "encoded:" lines). They may carry
// a small-order component, so they are only ever used through 8·M / 8·N.
static const unsigned char kM[32] = {
    0x5a, 0xda, 0x7e, 0x4b, 0xf6, 0xdd, 0xd9, 0xad, 0xb6, 0x62, 0x6d,
    0x32, 0x13, 0x1c, 0x6b, 0x5c, 0x51, 0xa1, 0xe3, 0x47, 0xa3, 0x47,
    0x8f, 0x53, 0xcf, 0xcf, 0x44, 0x1b, 0x88, 0xee, 0xd1, 0x2e};
static const unsigned char kN[32] = {
    0x10, 0xe3, 0xdf, 0x0a, 0xe3, 0x7d, 0x8e, 0x7a, 0x99, 0xb5, 0xfe,
    0x74, 0xb4, 0x46, 0x72, 0x10, 0x3d, 0xbd, 0xdc, 0xbd, 0x06, 0xaf,
    0x68, 0x0d, 0x71, 0x32, 0x9a, 0x11, 0x69, 0x3b, 0xc7, 0x78};

static unsigned char g_m8[32];   // 8·M, in the prime-order subgroup
static unsigned char g_n8[32];   // 8·N
static unsigned char g_inv8[32]; // 8⁻¹ mod L
static int g_ready = 0;

// 8·P by three doublings. crypto_core_ed25519_add works on the whole curve,
// unlike crypto_scalarmult_ed25519_*, which refuse points outside the
// prime-order subgroup (M and N may be).
static int times8(const spake2_api *api, unsigned char out[32],
                  const unsigned char p[32]) {
  unsigned char a[32], b[32];
  if (api->core_add(a, p, p) != 0) return -1;  // 2P
  if (api->core_add(b, a, a) != 0) return -1;  // 4P
  if (api->core_add(out, b, b) != 0) return -1; // 8P
  return 0;
}

int spake2_setup(const spake2_api *api) {
  if (g_ready) return 0;
  unsigned char eight[32] = {8};
  if (times8(api, g_m8, kM) != 0) return -1;
  if (times8(api, g_n8, kN) != 0) return -1;
  if (api->scalar_invert(g_inv8, eight) != 0) return -1;
  g_ready = 1;
  return 0;
}

int spake2_ctx_init(spake2_ctx *ctx, int role, const unsigned char *my_name,
                    size_t my_name_len, const unsigned char *their_name,
                    size_t their_name_len) {
  if (my_name_len > SPAKE2_MAX_NAME || their_name_len > SPAKE2_MAX_NAME) {
    return -1;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->role = role;
  memcpy(ctx->my_name, my_name, my_name_len);
  ctx->my_name_len = my_name_len;
  memcpy(ctx->their_name, their_name, their_name_len);
  ctx->their_name_len = their_name_len;
  return 0;
}

int spake2_generate(spake2_ctx *ctx, const spake2_api *api,
                    const unsigned char *password, size_t password_len,
                    const unsigned char *x64,
                    unsigned char out_msg[SPAKE2_MSG_BYTES]) {
  if (!g_ready || ctx->state != 0) return -1;

  // private_tmp = 64 random bytes; x25519_sc_reduce → x = r mod L.
  unsigned char r[64], x[32];
  if (x64 != NULL) {
    memcpy(r, x64, 64);
  } else {
    api->randombytes_buf(r, sizeof r);
  }
  api->scalar_reduce(x, r);
  // BoringSSL's private_key is 8·x (left_shift_3), used against the base
  // point and the peer's point, both of prime order L, so 8·x mod L gives
  // the same points and keeps the scalar below 2^255 (libsodium clears that
  // bit).
  unsigned char eight[32] = {8};
  api->scalar_mul(ctx->s, x, eight);

  // P = private_key·B.
  unsigned char P[32];
  if (api->base_noclamp(P, ctx->s) != 0) return -1;

  // password_hash = SHA-512(password); w = sc_reduce(password_hash). With
  // the password-scalar hack (BoringSSL's default, adb's too) the mask is
  // w·M' where M' is M's prime-order part: w·M' = (w·8⁻¹)·(8·M).
  if (api->sha512(ctx->ph, password, password_len) != 0) return -1;
  unsigned char w[32];
  api->scalar_reduce(w, ctx->ph);
  api->scalar_mul(ctx->t, w, g_inv8);

  unsigned char mask[32];
  const unsigned char *base = ctx->role == SPAKE2_ROLE_ALICE ? g_m8 : g_n8;
  if (api->noclamp(mask, ctx->t, base) != 0) return -1;

  // P* = P + mask.
  if (api->core_add(ctx->my_msg, P, mask) != 0) return -1;
  memcpy(out_msg, ctx->my_msg, SPAKE2_MSG_BYTES);
  ctx->state = 1;
  return 0;
}

// update_with_length_prefix: u64 little-endian length, then the bytes.
static size_t put(unsigned char *buf, size_t at, const unsigned char *data,
                  size_t len) {
  for (int i = 0; i < 8; i++) {
    buf[at + i] = (unsigned char)((unsigned long long)len >> (8 * i));
  }
  memcpy(buf + at + 8, data, len);
  return at + 8 + len;
}

int spake2_process(spake2_ctx *ctx, const spake2_api *api,
                   const unsigned char their_msg[SPAKE2_MSG_BYTES],
                   unsigned char out_key[SPAKE2_KEY_BYTES]) {
  if (!g_ready || ctx->state != 1) return -1;

  // Unmask the peer: Q = Q* − w·(N' or M').
  unsigned char peers_mask[32], Q[32];
  const unsigned char *base = ctx->role == SPAKE2_ROLE_ALICE ? g_n8 : g_m8;
  if (api->noclamp(peers_mask, ctx->t, base) != 0) return -1;
  if (api->core_sub(Q, their_msg, peers_mask) != 0) return -1;

  // dh = private_key·Q. libsodium refuses a Q outside the prime-order
  // subgroup; an honest peer's Q (8·y·B) is always inside, so a refusal
  // means a broken or malicious peer and pairing fails.
  unsigned char dh[32];
  if (api->noclamp(dh, ctx->s, Q) != 0) return -1;

  unsigned char t[8 * 6 + 2 * SPAKE2_MAX_NAME + 32 * 3 + 64];
  size_t n = 0;
  if (ctx->role == SPAKE2_ROLE_ALICE) {
    n = put(t, n, ctx->my_name, ctx->my_name_len);
    n = put(t, n, ctx->their_name, ctx->their_name_len);
    n = put(t, n, ctx->my_msg, 32);
    n = put(t, n, their_msg, 32);
  } else {
    n = put(t, n, ctx->their_name, ctx->their_name_len);
    n = put(t, n, ctx->my_name, ctx->my_name_len);
    n = put(t, n, their_msg, 32);
    n = put(t, n, ctx->my_msg, 32);
  }
  n = put(t, n, dh, 32);
  n = put(t, n, ctx->ph, 64);
  if (api->sha512(out_key, t, n) != 0) return -1;
  ctx->state = 2;
  return 0;
}
