/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 *
 * Module 35905 — Bitcoin Private Key Hex (P2PKH/Bech32/P2SH) + Reversed
 * Attack mode a1: combinatorial
 */

//#define NEW_SIMD_CODE

#define SECP256K1_TMPS_TYPE PRIVATE_AS

#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif

DECLSPEC u32 hex_nibble_S (const u32 c)
{
  return (c > '9') ? ((c | 0x20u) - 'a' + 10u) : (c - '0');
}

DECLSPEC u32 hex8_to_u32_S (const u32 w0, const u32 w1)
{
  const u32 b0 = (hex_nibble_S ((w0 >>  0) & 0xff) << 4) | hex_nibble_S ((w0 >>  8) & 0xff);
  const u32 b1 = (hex_nibble_S ((w0 >> 16) & 0xff) << 4) | hex_nibble_S ((w0 >> 24) & 0xff);
  const u32 b2 = (hex_nibble_S ((w1 >>  0) & 0xff) << 4) | hex_nibble_S ((w1 >>  8) & 0xff);
  const u32 b3 = (hex_nibble_S ((w1 >> 16) & 0xff) << 4) | hex_nibble_S ((w1 >> 24) & 0xff);

  return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

DECLSPEC void decode_prv_key (PRIVATE_AS u32 *prv_key, PRIVATE_AS const u32 *w)
{
  prv_key[7] = hex8_to_u32_S (w[ 0], w[ 1]);
  prv_key[6] = hex8_to_u32_S (w[ 2], w[ 3]);
  prv_key[5] = hex8_to_u32_S (w[ 4], w[ 5]);
  prv_key[4] = hex8_to_u32_S (w[ 6], w[ 7]);
  prv_key[3] = hex8_to_u32_S (w[ 8], w[ 9]);
  prv_key[2] = hex8_to_u32_S (w[10], w[11]);
  prv_key[1] = hex8_to_u32_S (w[12], w[13]);
  prv_key[0] = hex8_to_u32_S (w[14], w[15]);
  prv_key[8] = 0;
}

DECLSPEC void reverse_prv_key (PRIVATE_AS u32 *prv_rev, PRIVATE_AS const u32 *prv)
{
  prv_rev[0] = hc_swap32_S (prv[7]);
  prv_rev[1] = hc_swap32_S (prv[6]);
  prv_rev[2] = hc_swap32_S (prv[5]);
  prv_rev[3] = hc_swap32_S (prv[4]);
  prv_rev[4] = hc_swap32_S (prv[3]);
  prv_rev[5] = hc_swap32_S (prv[2]);
  prv_rev[6] = hc_swap32_S (prv[1]);
  prv_rev[7] = hc_swap32_S (prv[0]);
  prv_rev[8] = 0;
}

DECLSPEC void prv_to_hash160 (PRIVATE_AS u32 *rctx_h, PRIVATE_AS const u32 *prv_key,
                               LOCAL_AS const u32 *lm_w5,
                               const u32 addr_type)
{
  u32 x[8];
  u32 y[8];

  point_mul_glv_wnaf_w5_lm (x, y, prv_key, lm_w5);

  u32 pub_key[16] = { 0 };

  const u32 type = 0x02 | (y[0] & 1);

  pub_key[8] =               (x[0] << 24);
  pub_key[7] = (x[0] >>  8) | (x[1] << 24);
  pub_key[6] = (x[1] >>  8) | (x[2] << 24);
  pub_key[5] = (x[2] >>  8) | (x[3] << 24);
  pub_key[4] = (x[3] >>  8) | (x[4] << 24);
  pub_key[3] = (x[4] >>  8) | (x[5] << 24);
  pub_key[2] = (x[5] >>  8) | (x[6] << 24);
  pub_key[1] = (x[6] >>  8) | (x[7] << 24);
  pub_key[0] = (x[7] >>  8) | (type  << 24);

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

  if (addr_type == 1)
  {
    tmp[0] = (rctx.h[0] << 16) | 0x1400u;
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

  rctx_h[0] = rctx.h[0];
  rctx_h[1] = rctx.h[1];
  rctx_h[2] = rctx.h[2];
  rctx_h[3] = rctx.h[3];
  rctx_h[4] = rctx.h[4];
}

KERNEL_FQ KERNEL_FA void m35905_mxx (KERN_ATTR_BASIC ())
{
  const u64 gid = get_global_id (0);
  const u64 lid = get_local_id (0);
  const u64 lsz = get_local_size (0);

  LOCAL_AS u32 lm_w5[SECP256K1_W5_SHMEM_SIZE];

  set_precomputed_basepoint_g_w5_lm (lm_w5, lid, lsz);


  if (gid >= GID_CNT) return;

  // Copy base password words to local buffer
  u32 pw_buf0[4];
  u32 pw_buf1[4];

  pw_buf0[0] = pws[gid].i[0];
  pw_buf0[1] = pws[gid].i[1];
  pw_buf0[2] = pws[gid].i[2];
  pw_buf0[3] = pws[gid].i[3];
  pw_buf1[0] = pws[gid].i[4];
  pw_buf1[1] = pws[gid].i[5];
  pw_buf1[2] = pws[gid].i[6];
  pw_buf1[3] = pws[gid].i[7];

  const u32 pw_l_len = pws[gid].pw_len & 63;


  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    const u32 pw_r_len = combs_buf[il_pos].pw_len;

    const u32 pw_len = (pw_l_len + pw_r_len) & 63;

    if (pw_len != 64) continue;

    u32 wordbuf[16] = { 0 };

    wordbuf[ 0] = pw_buf0[0];
    wordbuf[ 1] = pw_buf0[1];
    wordbuf[ 2] = pw_buf0[2];
    wordbuf[ 3] = pw_buf0[3];
    wordbuf[ 4] = pw_buf1[0];
    wordbuf[ 5] = pw_buf1[1];
    wordbuf[ 6] = pw_buf1[2];
    wordbuf[ 7] = pw_buf1[3];
    wordbuf[ 8] = combs_buf[il_pos].i[0];
    wordbuf[ 9] = combs_buf[il_pos].i[1];
    wordbuf[10] = combs_buf[il_pos].i[2];
    wordbuf[11] = combs_buf[il_pos].i[3];
    wordbuf[12] = combs_buf[il_pos].i[4];
    wordbuf[13] = combs_buf[il_pos].i[5];
    wordbuf[14] = combs_buf[il_pos].i[6];
    wordbuf[15] = combs_buf[il_pos].i[7];

    u32 prv_key[9];

    decode_prv_key (prv_key, wordbuf);

    u32 hash160[5];

    prv_to_hash160 (hash160, prv_key, lm_w5, addr_type);

    const u32 r0 = hash160[0];
    const u32 r1 = hash160[1];
    const u32 r2 = hash160[2];
    const u32 r3 = hash160[3];

    COMPARE_M_SCALAR (r0, r1, r2, r3);

    u32 prv_rev[9];

    reverse_prv_key (prv_rev, prv_key);

    prv_to_hash160 (hash160, prv_rev, lm_w5, addr_type);

    const u32 rr0 = hash160[0];
    const u32 rr1 = hash160[1];
    const u32 rr2 = hash160[2];
    const u32 rr3 = hash160[3];

    COMPARE_M_SCALAR (rr0, rr1, rr2, rr3);
  }
}

KERNEL_FQ KERNEL_FA void m35905_sxx (KERN_ATTR_BASIC ())
{
  const u64 gid = get_global_id (0);
  const u64 lid = get_local_id (0);
  const u64 lsz = get_local_size (0);

  LOCAL_AS u32 lm_w5[SECP256K1_W5_SHMEM_SIZE];

  set_precomputed_basepoint_g_w5_lm (lm_w5, lid, lsz);


  if (gid >= GID_CNT) return;

  const u32 search[4] =
  {
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R0],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R1],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R2],
    digests_buf[DIGESTS_OFFSET_HOST].digest_buf[DGST_R3]
  };

  u32 pw_buf0[4];
  u32 pw_buf1[4];

  pw_buf0[0] = pws[gid].i[0];
  pw_buf0[1] = pws[gid].i[1];
  pw_buf0[2] = pws[gid].i[2];
  pw_buf0[3] = pws[gid].i[3];
  pw_buf1[0] = pws[gid].i[4];
  pw_buf1[1] = pws[gid].i[5];
  pw_buf1[2] = pws[gid].i[6];
  pw_buf1[3] = pws[gid].i[7];

  const u32 pw_l_len = pws[gid].pw_len & 63;


  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    const u32 pw_r_len = combs_buf[il_pos].pw_len;

    const u32 pw_len = (pw_l_len + pw_r_len) & 63;

    if (pw_len != 64) continue;

    u32 wordbuf[16] = { 0 };

    wordbuf[ 0] = pw_buf0[0];
    wordbuf[ 1] = pw_buf0[1];
    wordbuf[ 2] = pw_buf0[2];
    wordbuf[ 3] = pw_buf0[3];
    wordbuf[ 4] = pw_buf1[0];
    wordbuf[ 5] = pw_buf1[1];
    wordbuf[ 6] = pw_buf1[2];
    wordbuf[ 7] = pw_buf1[3];
    wordbuf[ 8] = combs_buf[il_pos].i[0];
    wordbuf[ 9] = combs_buf[il_pos].i[1];
    wordbuf[10] = combs_buf[il_pos].i[2];
    wordbuf[11] = combs_buf[il_pos].i[3];
    wordbuf[12] = combs_buf[il_pos].i[4];
    wordbuf[13] = combs_buf[il_pos].i[5];
    wordbuf[14] = combs_buf[il_pos].i[6];
    wordbuf[15] = combs_buf[il_pos].i[7];

    u32 prv_key[9];

    decode_prv_key (prv_key, wordbuf);

    u32 hash160[5];

    prv_to_hash160 (hash160, prv_key, lm_w5, addr_type);

    const u32 r0 = hash160[0];
    const u32 r1 = hash160[1];
    const u32 r2 = hash160[2];
    const u32 r3 = hash160[3];

    COMPARE_S_SCALAR (r0, r1, r2, r3);

    u32 prv_rev[9];

    reverse_prv_key (prv_rev, prv_key);

    prv_to_hash160 (hash160, prv_rev, lm_w5, addr_type);

    const u32 rr0 = hash160[0];
    const u32 rr1 = hash160[1];
    const u32 rr2 = hash160[2];
    const u32 rr3 = hash160[3];

    COMPARE_S_SCALAR (rr0, rr1, rr2, rr3);
  }
}
