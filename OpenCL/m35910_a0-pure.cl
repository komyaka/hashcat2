/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 *
 * Module 35910 — Bitcoin Brainwallet (BLAKE2b-256, P2PKH/Bech32/P2SH)
 * Pipeline: passphrase → BLAKE2b-256 → private_key → G·k → compressed_pubkey
 *           → SHA256 → RIPEMD160 → hash160 → Bitcoin address
 */

//#define NEW_SIMD_CODE

#define SECP256K1_TMPS_TYPE PRIVATE_AS

#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_blake2b.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif

KERNEL_FQ KERNEL_FA void m35910_mxx (KERN_ATTR_RULES ())
{
  /**
   * modifier
   */

  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

  /**
   * base
   */

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

  COPY_PW (pws[gid]);

  /**
   * loop
   */

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    // Step 1: BLAKE2b-256 hash of passphrase → private key

    blake2b_ctx_t b2b_ctx;

    blake2b_256_init   (&b2b_ctx);
    blake2b_update     (&b2b_ctx, p.i, p.pw_len);
    blake2b_final      (&b2b_ctx);

    // BLAKE2b stores output in little-endian u64 words.
    // Convert to u32 array (LE words) then byte-swap for secp256k1 big-endian convention.

    u32 hash[8];

    hash[0] = l32_from_64_S (b2b_ctx.h[0]);
    hash[1] = h32_from_64_S (b2b_ctx.h[0]);
    hash[2] = l32_from_64_S (b2b_ctx.h[1]);
    hash[3] = h32_from_64_S (b2b_ctx.h[1]);
    hash[4] = l32_from_64_S (b2b_ctx.h[2]);
    hash[5] = h32_from_64_S (b2b_ctx.h[2]);
    hash[6] = l32_from_64_S (b2b_ctx.h[3]);
    hash[7] = h32_from_64_S (b2b_ctx.h[3]);

    // secp256k1 scalar: little-endian u32 array, [0] = least significant
    // hash bytes 0-3 are the most-significant bytes of the 256-bit value (big-endian)

    u32 prv_key[9];

    prv_key[0] = hc_swap32_S (hash[7]);
    prv_key[1] = hc_swap32_S (hash[6]);
    prv_key[2] = hc_swap32_S (hash[5]);
    prv_key[3] = hc_swap32_S (hash[4]);
    prv_key[4] = hc_swap32_S (hash[3]);
    prv_key[5] = hc_swap32_S (hash[2]);
    prv_key[6] = hc_swap32_S (hash[1]);
    prv_key[7] = hc_swap32_S (hash[0]);
    prv_key[8] = 0;

    // Step 2: EC point multiplication pub_key = G * prv_key

    u32 x[8];
    u32 y[8];

    point_mul_xy (x, y, prv_key, &preG);

    // Step 3: compressed public key (33 bytes)

    u32 pub_key[16] = { 0 };

    const u32 type = 0x02 | (y[0] & 1);

    pub_key[8] =               (x[0] << 24);
    pub_key[7] = (x[0] >> 8) | (x[1] << 24);
    pub_key[6] = (x[1] >> 8) | (x[2] << 24);
    pub_key[5] = (x[2] >> 8) | (x[3] << 24);
    pub_key[4] = (x[3] >> 8) | (x[4] << 24);
    pub_key[3] = (x[4] >> 8) | (x[5] << 24);
    pub_key[2] = (x[5] >> 8) | (x[6] << 24);
    pub_key[1] = (x[6] >> 8) | (x[7] << 24);
    pub_key[0] = (x[7] >> 8) | (type << 24);

    // Step 4: HASH160 = RIPEMD-160(SHA-256(compressed_pubkey))

    sha256_ctx_t ctx;

    sha256_init   (&ctx);
    sha256_update (&ctx, pub_key, 33);
    sha256_final  (&ctx);

    u32 tmp[16] = { 0 };

    for (u32 i = 0; i < 8; i++) tmp[i] = ctx.h[i];

    ripemd160_ctx_t rctx;

    ripemd160_init        (&rctx);
    ripemd160_update_swap (&rctx, tmp, 32);
    ripemd160_final       (&rctx);

    // Check if address type is P2SH (salt_buf[0] == 1)
    const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

    if (addr_type == 1)
    {
      // P2SH: compute HASH160(0x0014 || hash160)
      tmp[0] = (rctx.h[0] << 16) | (0x1400);
      tmp[1] = (rctx.h[1] << 16) | (rctx.h[0] >> 16);
      tmp[2] = (rctx.h[2] << 16) | (rctx.h[1] >> 16);
      tmp[3] = (rctx.h[3] << 16) | (rctx.h[2] >> 16);
      tmp[4] = (rctx.h[4] << 16) | (rctx.h[3] >> 16);
      tmp[5] = (rctx.h[4] >> 16);
      for (u32 i = 6; i < 16; i++) tmp[i] = 0;

      sha256_init        (&ctx);
      sha256_update_swap (&ctx, tmp, 22);
      sha256_final       (&ctx);

      for (u32 i = 0; i < 8; i++) tmp[i] = ctx.h[i];

      ripemd160_init        (&rctx);
      ripemd160_update_swap (&rctx, tmp, 32);
      ripemd160_final       (&rctx);
    }

    const u32 r0 = rctx.h[0];
    const u32 r1 = rctx.h[1];
    const u32 r2 = rctx.h[2];
    const u32 r3 = rctx.h[3];

    COMPARE_M_SCALAR (r0, r1, r2, r3);
  }
}

KERNEL_FQ KERNEL_FA void m35910_sxx (KERN_ATTR_RULES ())
{
  /**
   * modifier
   */

  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

  /**
   * digest
   */

  const u32 search[4] =
  {
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R0],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R1],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R2],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R3]
  };

  /**
   * base
   */

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

  COPY_PW (pws[gid]);

  /**
   * loop
   */

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    blake2b_ctx_t b2b_ctx;

    blake2b_256_init   (&b2b_ctx);
    blake2b_update     (&b2b_ctx, p.i, p.pw_len);
    blake2b_final      (&b2b_ctx);

    u32 hash[8];

    hash[0] = l32_from_64_S (b2b_ctx.h[0]);
    hash[1] = h32_from_64_S (b2b_ctx.h[0]);
    hash[2] = l32_from_64_S (b2b_ctx.h[1]);
    hash[3] = h32_from_64_S (b2b_ctx.h[1]);
    hash[4] = l32_from_64_S (b2b_ctx.h[2]);
    hash[5] = h32_from_64_S (b2b_ctx.h[2]);
    hash[6] = l32_from_64_S (b2b_ctx.h[3]);
    hash[7] = h32_from_64_S (b2b_ctx.h[3]);

    u32 prv_key[9];

    prv_key[0] = hc_swap32_S (hash[7]);
    prv_key[1] = hc_swap32_S (hash[6]);
    prv_key[2] = hc_swap32_S (hash[5]);
    prv_key[3] = hc_swap32_S (hash[4]);
    prv_key[4] = hc_swap32_S (hash[3]);
    prv_key[5] = hc_swap32_S (hash[2]);
    prv_key[6] = hc_swap32_S (hash[1]);
    prv_key[7] = hc_swap32_S (hash[0]);
    prv_key[8] = 0;

    u32 x[8];
    u32 y[8];

    point_mul_xy (x, y, prv_key, &preG);

    u32 pub_key[16] = { 0 };

    const u32 type = 0x02 | (y[0] & 1);

    pub_key[8] =               (x[0] << 24);
    pub_key[7] = (x[0] >> 8) | (x[1] << 24);
    pub_key[6] = (x[1] >> 8) | (x[2] << 24);
    pub_key[5] = (x[2] >> 8) | (x[3] << 24);
    pub_key[4] = (x[3] >> 8) | (x[4] << 24);
    pub_key[3] = (x[4] >> 8) | (x[5] << 24);
    pub_key[2] = (x[5] >> 8) | (x[6] << 24);
    pub_key[1] = (x[6] >> 8) | (x[7] << 24);
    pub_key[0] = (x[7] >> 8) | (type << 24);

    sha256_ctx_t ctx;

    sha256_init   (&ctx);
    sha256_update (&ctx, pub_key, 33);
    sha256_final  (&ctx);

    u32 tmp[16] = { 0 };

    for (u32 i = 0; i < 8; i++) tmp[i] = ctx.h[i];

    ripemd160_ctx_t rctx;

    ripemd160_init        (&rctx);
    ripemd160_update_swap (&rctx, tmp, 32);
    ripemd160_final       (&rctx);

    const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

    if (addr_type == 1)
    {
      tmp[0] = (rctx.h[0] << 16) | (0x1400);
      tmp[1] = (rctx.h[1] << 16) | (rctx.h[0] >> 16);
      tmp[2] = (rctx.h[2] << 16) | (rctx.h[1] >> 16);
      tmp[3] = (rctx.h[3] << 16) | (rctx.h[2] >> 16);
      tmp[4] = (rctx.h[4] << 16) | (rctx.h[3] >> 16);
      tmp[5] = (rctx.h[4] >> 16);
      for (u32 i = 6; i < 16; i++) tmp[i] = 0;

      sha256_init        (&ctx);
      sha256_update_swap (&ctx, tmp, 22);
      sha256_final       (&ctx);

      for (u32 i = 0; i < 8; i++) tmp[i] = ctx.h[i];

      ripemd160_init        (&rctx);
      ripemd160_update_swap (&rctx, tmp, 32);
      ripemd160_final       (&rctx);
    }

    const u32 r0 = rctx.h[0];
    const u32 r1 = rctx.h[1];
    const u32 r2 = rctx.h[2];
    const u32 r3 = rctx.h[3];

    COMPARE_S_SCALAR (r0, r1, r2, r3);
  }
}
