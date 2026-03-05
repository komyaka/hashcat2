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

KERNEL_FQ KERNEL_FA void m35900_mxx (KERN_ATTR_RULES ())
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

  /* addr_type is uniform across all threads for the same salt; hoist it
   * outside the per-candidate loop to avoid repeated global-memory reads. */
  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

  /**
   * loop
   */

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    // Step 1: SHA-256 hash of passphrase to get private key

    sha256_ctx_t sha_ctx;

    sha256_init        (&sha_ctx);
    sha256_update_swap (&sha_ctx, p.i, p.pw_len);
    sha256_final       (&sha_ctx);

    // private key in big-endian (sha256 output)
    // secp256k1 expects little-endian word order

    u32 prv_key[9];

    prv_key[0] = sha_ctx.h[7];
    prv_key[1] = sha_ctx.h[6];
    prv_key[2] = sha_ctx.h[5];
    prv_key[3] = sha_ctx.h[4];
    prv_key[4] = sha_ctx.h[3];
    prv_key[5] = sha_ctx.h[2];
    prv_key[6] = sha_ctx.h[1];
    prv_key[7] = sha_ctx.h[0];
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

    // Step 4: HASH160 = RIPEMD-160(SHA-256(pub_key))

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

    if (addr_type == 1)
    {
      // P2SH: compute HASH160(0x0014 || hash160)
      tmp[0] = (rctx.h[0] << 16) | (0x1400);
      tmp[1] = (rctx.h[1] << 16) | (rctx.h[0] >> 16);
      tmp[2] = (rctx.h[2] << 16) | (rctx.h[1] >> 16);
      tmp[3] = (rctx.h[3] << 16) | (rctx.h[2] >> 16);
      tmp[4] = (rctx.h[4] << 16) | (rctx.h[3] >> 16);
      tmp[5] = (rctx.h[4] >> 16);
      tmp[6] = 0; tmp[7] = 0;
      /* tmp[8..15] already zero from { 0 } initializer */

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

KERNEL_FQ KERNEL_FA void m35900_sxx (KERN_ATTR_RULES ())
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

  /* addr_type is uniform across all threads for the same salt; hoist it
   * outside the per-candidate loop to avoid repeated global-memory reads. */
  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

  /**
   * loop
   */

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    sha256_ctx_t sha_ctx;

    sha256_init        (&sha_ctx);
    sha256_update_swap (&sha_ctx, p.i, p.pw_len);
    sha256_final       (&sha_ctx);

    u32 prv_key[9];

    prv_key[0] = sha_ctx.h[7];
    prv_key[1] = sha_ctx.h[6];
    prv_key[2] = sha_ctx.h[5];
    prv_key[3] = sha_ctx.h[4];
    prv_key[4] = sha_ctx.h[3];
    prv_key[5] = sha_ctx.h[2];
    prv_key[6] = sha_ctx.h[1];
    prv_key[7] = sha_ctx.h[0];
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
    /* tmp[8..15] already zero from { 0 } initializer */

    ripemd160_ctx_t rctx;

    ripemd160_init        (&rctx);
    ripemd160_update_swap (&rctx, tmp, 32);
    ripemd160_final       (&rctx);

    if (addr_type == 1)
    {
      // P2SH: compute HASH160(0x0014 || hash160)
      tmp[0] = (rctx.h[0] << 16) | (0x1400);
      tmp[1] = (rctx.h[1] << 16) | (rctx.h[0] >> 16);
      tmp[2] = (rctx.h[2] << 16) | (rctx.h[1] >> 16);
      tmp[3] = (rctx.h[3] << 16) | (rctx.h[2] >> 16);
      tmp[4] = (rctx.h[4] << 16) | (rctx.h[3] >> 16);
      tmp[5] = (rctx.h[4] >> 16);
      tmp[6] = 0; tmp[7] = 0;
      /* tmp[8..15] already zero from { 0 } initializer */

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
