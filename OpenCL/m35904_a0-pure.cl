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

// SHA3-256: rate=136, padding byte=0x06
DECLSPEC void sha3_256_hash (PRIVATE_AS const u32 *pw, const u32 pw_len, PRIVATE_AS u32 *out)
{
  u64 st[25] = { 0 };

  const u32 rate = 136;

  u32 pw_off = 0;

  while (pw_off + rate <= pw_len)
  {
    for (u32 i = 0; i < rate / 8; i++)
    {
      const u32 idx = pw_off / 4 + i * 2;
      st[i] ^= hl32_to_64_S (pw[idx + 1], pw[idx]);
    }

    keccak_transform_S (st);
    pw_off += rate;
  }

  u8 temp[136] = { 0 };

  for (u32 i = pw_off; i < pw_len; i++)
  {
    const u32 widx = i / 4;
    const u32 bidx = i % 4;
    temp[i - pw_off] = (pw[widx] >> (bidx * 8)) & 0xff;
  }

  const u32 rem = pw_len - pw_off;

  temp[rem] = 0x06;
  temp[rate - 1] |= 0x80;

  for (u32 i = 0; i < rate / 8; i++)
  {
    u64 v = 0;
    for (u32 j = 0; j < 8; j++)
    {
      v |= ((u64) temp[i * 8 + j]) << (j * 8);
    }
    st[i] ^= v;
  }

  keccak_transform_S (st);

  out[0] = l32_from_64_S (st[0]);
  out[1] = h32_from_64_S (st[0]);
  out[2] = l32_from_64_S (st[1]);
  out[3] = h32_from_64_S (st[1]);
  out[4] = l32_from_64_S (st[2]);
  out[5] = h32_from_64_S (st[2]);
  out[6] = l32_from_64_S (st[3]);
  out[7] = h32_from_64_S (st[3]);
}

// Keccak-256 of a 64-byte input (uncompressed pubkey x||y for Ethereum address)
DECLSPEC void keccak_256_64 (PRIVATE_AS const u32 *in, PRIVATE_AS u32 *out)
{
  u64 st[25] = { 0 };

  // 64 bytes < 136 byte rate, so single block

  st[0] = hl32_to_64_S (in[ 1], in[ 0]);
  st[1] = hl32_to_64_S (in[ 3], in[ 2]);
  st[2] = hl32_to_64_S (in[ 5], in[ 4]);
  st[3] = hl32_to_64_S (in[ 7], in[ 6]);
  st[4] = hl32_to_64_S (in[ 9], in[ 8]);
  st[5] = hl32_to_64_S (in[11], in[10]);
  st[6] = hl32_to_64_S (in[13], in[12]);
  st[7] = hl32_to_64_S (in[15], in[14]);

  // Keccak padding: 0x01 at byte 64, 0x80 at byte 135
  st[8] ^= 0x0000000000000001UL;
  st[16] ^= 0x8000000000000000UL;

  keccak_transform_S (st);

  // last 20 bytes = bytes 12..31 of output
  // output: st[0] bytes 0-7, st[1] bytes 8-15, st[2] bytes 16-23, st[3] bytes 24-31
  // We need bytes 12-31 = last 5 u32 words

  out[0] = h32_from_64_S (st[1]); // bytes 12-15
  out[1] = l32_from_64_S (st[2]); // bytes 16-19
  out[2] = h32_from_64_S (st[2]); // bytes 20-23
  out[3] = l32_from_64_S (st[3]); // bytes 24-27
  out[4] = h32_from_64_S (st[3]); // bytes 28-31
}

KERNEL_FQ KERNEL_FA void m35904_mxx (KERN_ATTR_RULES ())
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

    // Keccak-256 of passphrase to get private key
    u32 hash[8];

    sha3_256_hash (p.i, p.pw_len, hash);

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

    // Ethereum uses uncompressed public key (x || y) for address derivation
    // Store as big-endian bytes in u32 array (16 words = 64 bytes)
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

    // Keccak-256 of uncompressed public key, take last 20 bytes
    u32 addr[5];

    keccak_256_64 (pub_key, addr);

    // addr is in LE byte order from Keccak, swap to match digest format
    const u32 r0 = addr[0];
    const u32 r1 = addr[1];
    const u32 r2 = addr[2];
    const u32 r3 = addr[3];

    COMPARE_M_SCALAR (r0, r1, r2, r3);
  }
}

KERNEL_FQ KERNEL_FA void m35904_sxx (KERN_ATTR_RULES ())
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

    u32 hash[8];

    sha3_256_hash (p.i, p.pw_len, hash);

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
