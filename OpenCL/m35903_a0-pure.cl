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
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#include M2S(INCLUDE_PATH/inc_hash_keccak256.cl)
#endif

KERNEL_FQ KERNEL_FA void m35903_mxx (KERN_ATTR_RULES ())
{
  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

  COPY_PW (pws[gid]);

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    // SHA-256 of passphrase to get private key
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

    // Ethereum: uncompressed public key (x || y) in big-endian
    u32 pub_key[16];

    pub_key[ 0] = hc_swap32_S (x[7]);
    pub_key[ 1] = hc_swap32_S (x[6]);
    pub_key[ 2] = hc_swap32_S (x[5]);
    pub_key[ 3] = hc_swap32_S (x[4]);
    pub_key[ 4] = hc_swap32_S (x[3]);
    pub_key[ 5] = hc_swap32_S (x[2]);
    pub_key[ 6] = hc_swap32_S (x[1]);
    pub_key[ 7] = hc_swap32_S (x[0]);
    pub_key[ 8] = hc_swap32_S (y[7]);
    pub_key[ 9] = hc_swap32_S (y[6]);
    pub_key[10] = hc_swap32_S (y[5]);
    pub_key[11] = hc_swap32_S (y[4]);
    pub_key[12] = hc_swap32_S (y[3]);
    pub_key[13] = hc_swap32_S (y[2]);
    pub_key[14] = hc_swap32_S (y[1]);
    pub_key[15] = hc_swap32_S (y[0]);

    u32 addr[5];

    keccak_256_64 (pub_key, addr);

    const u32 r0 = addr[0];
    const u32 r1 = addr[1];
    const u32 r2 = addr[2];
    const u32 r3 = addr[3];

    COMPARE_M_SCALAR (r0, r1, r2, r3);
  }
}

KERNEL_FQ KERNEL_FA void m35903_sxx (KERN_ATTR_RULES ())
{
  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

  const u32 search[4] =
  {
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R0],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R1],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R2],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R3]
  };

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

  COPY_PW (pws[gid]);

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

    u32 pub_key[16];

    pub_key[ 0] = hc_swap32_S (x[7]);
    pub_key[ 1] = hc_swap32_S (x[6]);
    pub_key[ 2] = hc_swap32_S (x[5]);
    pub_key[ 3] = hc_swap32_S (x[4]);
    pub_key[ 4] = hc_swap32_S (x[3]);
    pub_key[ 5] = hc_swap32_S (x[2]);
    pub_key[ 6] = hc_swap32_S (x[1]);
    pub_key[ 7] = hc_swap32_S (x[0]);
    pub_key[ 8] = hc_swap32_S (y[7]);
    pub_key[ 9] = hc_swap32_S (y[6]);
    pub_key[10] = hc_swap32_S (y[5]);
    pub_key[11] = hc_swap32_S (y[4]);
    pub_key[12] = hc_swap32_S (y[3]);
    pub_key[13] = hc_swap32_S (y[2]);
    pub_key[14] = hc_swap32_S (y[1]);
    pub_key[15] = hc_swap32_S (y[0]);

    u32 addr[5];

    keccak_256_64 (pub_key, addr);

    const u32 r0 = addr[0];
    const u32 r1 = addr[1];
    const u32 r2 = addr[2];
    const u32 r3 = addr[3];

    COMPARE_S_SCALAR (r0, r1, r2, r3);
  }
}
