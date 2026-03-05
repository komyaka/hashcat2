/**
 * Author......: See docs/credits.txt
 * License.....: MIT
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

    // Private key is the input directly (32 bytes big-endian).
    // p.i[] is in hashcat LE word format (first byte in LSB of word 0).
    // secp256k1 expects k[0] = LSW, k[7] = MSW, each word in BE byte order.
    // Conversion: k[i] = hc_swap32_S(p.i[7-i])

    if (p.pw_len != 32) continue; // Private key must be exactly 32 bytes

    u32 prv_key[9];

    prv_key[0] = hc_swap32_S (p.i[7]);
    prv_key[1] = hc_swap32_S (p.i[6]);
    prv_key[2] = hc_swap32_S (p.i[5]);
    prv_key[3] = hc_swap32_S (p.i[4]);
    prv_key[4] = hc_swap32_S (p.i[3]);
    prv_key[5] = hc_swap32_S (p.i[2]);
    prv_key[6] = hc_swap32_S (p.i[1]);
    prv_key[7] = hc_swap32_S (p.i[0]);
    prv_key[8] = 0;

    // Validate private key range: 0 < prv_key < N (secp256k1 group order)
    if (prv_key[0] == 0 && prv_key[1] == 0 && prv_key[2] == 0 && prv_key[3] == 0 &&
        prv_key[4] == 0 && prv_key[5] == 0 && prv_key[6] == 0 && prv_key[7] == 0)
    {
      continue; // Private key cannot be zero
    }

    // Step 1: EC point multiplication pub_key = G * prv_key

    u32 x[8];
    u32 y[8];

    point_mul_xy (x, y, prv_key, &preG);

    // Step 2: compressed public key (33 bytes)

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

    // Step 3: HASH160 = RIPEMD-160(SHA-256(pub_key))

    sha256_ctx_t ctx;

    sha256_init   (&ctx);
    sha256_update (&ctx, pub_key, 33);
    sha256_final  (&ctx);

    u32 tmp[16] = { 0 };

    for (u32 i = 0; i < 8; i++) tmp[i] = ctx.h[i];
    /* tmp[8..15] already zero from { 0 } initializer */

    ripemd160_ctx_t rctx;

    ripemd160_init        (&rctx);
    ripemd160_update_swap (&rctx, tmp, 32);
    ripemd160_final       (&rctx);

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

    if (p.pw_len != 32) continue;

    u32 prv_key[9];

    prv_key[0] = hc_swap32_S (p.i[7]);
    prv_key[1] = hc_swap32_S (p.i[6]);
    prv_key[2] = hc_swap32_S (p.i[5]);
    prv_key[3] = hc_swap32_S (p.i[4]);
    prv_key[4] = hc_swap32_S (p.i[3]);
    prv_key[5] = hc_swap32_S (p.i[2]);
    prv_key[6] = hc_swap32_S (p.i[1]);
    prv_key[7] = hc_swap32_S (p.i[0]);
    prv_key[8] = 0;

    if (prv_key[0] == 0 && prv_key[1] == 0 && prv_key[2] == 0 && prv_key[3] == 0 &&
        prv_key[4] == 0 && prv_key[5] == 0 && prv_key[6] == 0 && prv_key[7] == 0)
    {
      continue;
    }

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
    /* tmp[8..15] already zero from { 0 } initializer */

    ripemd160_ctx_t rctx;

    ripemd160_init        (&rctx);
    ripemd160_update_swap (&rctx, tmp, 32);
    ripemd160_final       (&rctx);

    const u32 r0 = rctx.h[0];
    const u32 r1 = rctx.h[1];
    const u32 r2 = rctx.h[2];
    const u32 r3 = rctx.h[3];

    COMPARE_S_SCALAR (r0, r1, r2, r3);
  }
}
