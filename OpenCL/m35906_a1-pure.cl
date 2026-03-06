/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 *
 * Module 35906 — Ethereum Private Key Hex + Reversed
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
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif

CONSTANT_VK u64a keccakf_rndc[24] =
{
  KECCAK_RNDC_00, KECCAK_RNDC_01, KECCAK_RNDC_02, KECCAK_RNDC_03,
  KECCAK_RNDC_04, KECCAK_RNDC_05, KECCAK_RNDC_06, KECCAK_RNDC_07,
  KECCAK_RNDC_08, KECCAK_RNDC_09, KECCAK_RNDC_10, KECCAK_RNDC_11,
  KECCAK_RNDC_12, KECCAK_RNDC_13, KECCAK_RNDC_14, KECCAK_RNDC_15,
  KECCAK_RNDC_16, KECCAK_RNDC_17, KECCAK_RNDC_18, KECCAK_RNDC_19,
  KECCAK_RNDC_20, KECCAK_RNDC_21, KECCAK_RNDC_22, KECCAK_RNDC_23
};

#ifndef KECCAK_ROUNDS
#define KECCAK_ROUNDS 24
#endif

#define Theta1(s) (st[0 + s] ^ st[5 + s] ^ st[10 + s] ^ st[15 + s] ^ st[20 + s])

#define Theta2(s)               \
{                               \
  st[ 0 + s] ^= t;              \
  st[ 5 + s] ^= t;              \
  st[10 + s] ^= t;              \
  st[15 + s] ^= t;              \
  st[20 + s] ^= t;              \
}

#define Rho_Pi(s)               \
{                               \
  u32 j = keccakf_piln[s];      \
  u32 k = keccakf_rotc[s];      \
  bc0 = st[j];                  \
  st[j] = hc_rotl64_S (t, k);   \
  t = bc0;                      \
}

#define Chi(s)                  \
{                               \
  bc0 = st[0 + s];              \
  bc1 = st[1 + s];              \
  bc2 = st[2 + s];              \
  bc3 = st[3 + s];              \
  bc4 = st[4 + s];              \
  st[0 + s] ^= ~bc1 & bc2;      \
  st[1 + s] ^= ~bc2 & bc3;      \
  st[2 + s] ^= ~bc3 & bc4;      \
  st[3 + s] ^= ~bc4 & bc0;      \
  st[4 + s] ^= ~bc0 & bc1;      \
}

DECLSPEC void keccak_transform_S (PRIVATE_AS u64 *st)
{
  const u8 keccakf_rotc[24] =
  {
     1,  3,  6, 10, 15, 21, 28, 36, 45, 55,  2, 14,
    27, 41, 56,  8, 25, 43, 62, 18, 39, 61, 20, 44
  };

  const u8 keccakf_piln[24] =
  {
    10,  7, 11, 17, 18,  3,  5, 16,  8, 21, 24,  4,
    15, 23, 19, 13, 12,  2, 20, 14, 22,  9,  6,  1
  };

  int round;

  for (round = 0; round < KECCAK_ROUNDS; round++)
  {
    u64 bc0 = Theta1 (0);
    u64 bc1 = Theta1 (1);
    u64 bc2 = Theta1 (2);
    u64 bc3 = Theta1 (3);
    u64 bc4 = Theta1 (4);

    u64 t;

    t = bc4 ^ hc_rotl64_S (bc1, 1); Theta2 (0);
    t = bc0 ^ hc_rotl64_S (bc2, 1); Theta2 (1);
    t = bc1 ^ hc_rotl64_S (bc3, 1); Theta2 (2);
    t = bc2 ^ hc_rotl64_S (bc4, 1); Theta2 (3);
    t = bc3 ^ hc_rotl64_S (bc0, 1); Theta2 (4);

    t = st[1];

    Rho_Pi (0);  Rho_Pi (1);  Rho_Pi (2);  Rho_Pi (3);
    Rho_Pi (4);  Rho_Pi (5);  Rho_Pi (6);  Rho_Pi (7);
    Rho_Pi (8);  Rho_Pi (9);  Rho_Pi (10); Rho_Pi (11);
    Rho_Pi (12); Rho_Pi (13); Rho_Pi (14); Rho_Pi (15);
    Rho_Pi (16); Rho_Pi (17); Rho_Pi (18); Rho_Pi (19);
    Rho_Pi (20); Rho_Pi (21); Rho_Pi (22); Rho_Pi (23);

    Chi (0); Chi (5); Chi (10); Chi (15); Chi (20);

    st[0] ^= keccakf_rndc[round];
  }
}

DECLSPEC void keccak_256_64 (PRIVATE_AS const u32 *in, PRIVATE_AS u32 *out)
{
  u64 st[25] = { 0 };

  st[0] = hl32_to_64_S (in[ 1], in[ 0]);
  st[1] = hl32_to_64_S (in[ 3], in[ 2]);
  st[2] = hl32_to_64_S (in[ 5], in[ 4]);
  st[3] = hl32_to_64_S (in[ 7], in[ 6]);
  st[4] = hl32_to_64_S (in[ 9], in[ 8]);
  st[5] = hl32_to_64_S (in[11], in[10]);
  st[6] = hl32_to_64_S (in[13], in[12]);
  st[7] = hl32_to_64_S (in[15], in[14]);

  st[8] ^= 0x0000000000000001UL;
  st[16] ^= 0x8000000000000000UL;

  keccak_transform_S (st);

  out[0] = h32_from_64_S (st[1]);
  out[1] = l32_from_64_S (st[2]);
  out[2] = h32_from_64_S (st[2]);
  out[3] = l32_from_64_S (st[3]);
  out[4] = h32_from_64_S (st[3]);
}

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

DECLSPEC void prv_to_eth_addr (PRIVATE_AS u32 *addr, PRIVATE_AS const u32 *prv_key,
                                SECP256K1_TMPS_TYPE secp256k1_t *preG)
{
  u32 x[8];
  u32 y[8];

  point_mul_xy (x, y, prv_key, preG);

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

  keccak_256_64 (pub_key, addr);
}

KERNEL_FQ KERNEL_FA void m35906_mxx (KERN_ATTR_BASIC ())
{
  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

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

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

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

    u32 addr[5];

    prv_to_eth_addr (addr, prv_key, &preG);

    const u32 r0 = addr[0];
    const u32 r1 = addr[1];
    const u32 r2 = addr[2];
    const u32 r3 = addr[3];

    COMPARE_M_SCALAR (r0, r1, r2, r3);

    u32 prv_rev[9];

    reverse_prv_key (prv_rev, prv_key);

    prv_to_eth_addr (addr, prv_rev, &preG);

    const u32 rr0 = addr[0];
    const u32 rr1 = addr[1];
    const u32 rr2 = addr[2];
    const u32 rr3 = addr[3];

    COMPARE_M_SCALAR (rr0, rr1, rr2, rr3);
  }
}

KERNEL_FQ KERNEL_FA void m35906_sxx (KERN_ATTR_BASIC ())
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

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

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

    u32 addr[5];

    prv_to_eth_addr (addr, prv_key, &preG);

    const u32 r0 = addr[0];
    const u32 r1 = addr[1];
    const u32 r2 = addr[2];
    const u32 r3 = addr[3];

    COMPARE_S_SCALAR (r0, r1, r2, r3);

    u32 prv_rev[9];

    reverse_prv_key (prv_rev, prv_key);

    prv_to_eth_addr (addr, prv_rev, &preG);

    const u32 rr0 = addr[0];
    const u32 rr1 = addr[1];
    const u32 rr2 = addr[2];
    const u32 rr3 = addr[3];

    COMPARE_S_SCALAR (rr0, rr1, rr2, rr3);
  }
}
