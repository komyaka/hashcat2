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

#define Theta1(s) (st[0 + s] ^ st[5 + s] ^ st[10 + s] ^ st[15 + s] ^ st[20 + s])

#define Theta2(s)               \
{                               \
  st[ 0 + s] ^= t;              \
  st[ 5 + s] ^= t;              \
  st[10 + s] ^= t;              \
  st[15 + s] ^= t;              \
  st[20 + s] ^= t;              \
}

#define Rho_Pi_Imm(j, k)        \
{                               \
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

#define KECCAK_ROUND(round_const)  \
{                                  \
  bc0 = Theta1 (0);                \
  bc1 = Theta1 (1);                \
  bc2 = Theta1 (2);                \
  bc3 = Theta1 (3);                \
  bc4 = Theta1 (4);                \
                                   \
  t = bc4 ^ hc_rotl64_S (bc1, 1); Theta2 (0); \
  t = bc0 ^ hc_rotl64_S (bc2, 1); Theta2 (1); \
  t = bc1 ^ hc_rotl64_S (bc3, 1); Theta2 (2); \
  t = bc2 ^ hc_rotl64_S (bc4, 1); Theta2 (3); \
  t = bc3 ^ hc_rotl64_S (bc0, 1); Theta2 (4); \
                                   \
  t = st[1];                       \
                                   \
  Rho_Pi_Imm (10,  1); Rho_Pi_Imm ( 7,  3); Rho_Pi_Imm (11,  6); Rho_Pi_Imm (17, 10); \
  Rho_Pi_Imm (18, 15); Rho_Pi_Imm ( 3, 21); Rho_Pi_Imm ( 5, 28); Rho_Pi_Imm (16, 36); \
  Rho_Pi_Imm ( 8, 45); Rho_Pi_Imm (21, 55); Rho_Pi_Imm (24,  2); Rho_Pi_Imm ( 4, 14); \
  Rho_Pi_Imm (15, 27); Rho_Pi_Imm (23, 41); Rho_Pi_Imm (19, 56); Rho_Pi_Imm (13,  8); \
  Rho_Pi_Imm (12, 25); Rho_Pi_Imm ( 2, 43); Rho_Pi_Imm (20, 62); Rho_Pi_Imm (14, 18); \
  Rho_Pi_Imm (22, 39); Rho_Pi_Imm ( 9, 61); Rho_Pi_Imm ( 6, 20); Rho_Pi_Imm ( 1, 44); \
                                   \
  Chi (0); Chi (5); Chi (10); Chi (15); Chi (20); \
                                   \
  st[0] ^= round_const;           \
}

DECLSPEC void keccak_transform_S (PRIVATE_AS u64 *st)
{
  u64 bc0, bc1, bc2, bc3, bc4, t;

  KECCAK_ROUND (KECCAK_RNDC_00);
  KECCAK_ROUND (KECCAK_RNDC_01);
  KECCAK_ROUND (KECCAK_RNDC_02);
  KECCAK_ROUND (KECCAK_RNDC_03);
  KECCAK_ROUND (KECCAK_RNDC_04);
  KECCAK_ROUND (KECCAK_RNDC_05);
  KECCAK_ROUND (KECCAK_RNDC_06);
  KECCAK_ROUND (KECCAK_RNDC_07);
  KECCAK_ROUND (KECCAK_RNDC_08);
  KECCAK_ROUND (KECCAK_RNDC_09);
  KECCAK_ROUND (KECCAK_RNDC_10);
  KECCAK_ROUND (KECCAK_RNDC_11);
  KECCAK_ROUND (KECCAK_RNDC_12);
  KECCAK_ROUND (KECCAK_RNDC_13);
  KECCAK_ROUND (KECCAK_RNDC_14);
  KECCAK_ROUND (KECCAK_RNDC_15);
  KECCAK_ROUND (KECCAK_RNDC_16);
  KECCAK_ROUND (KECCAK_RNDC_17);
  KECCAK_ROUND (KECCAK_RNDC_18);
  KECCAK_ROUND (KECCAK_RNDC_19);
  KECCAK_ROUND (KECCAK_RNDC_20);
  KECCAK_ROUND (KECCAK_RNDC_21);
  KECCAK_ROUND (KECCAK_RNDC_22);
  KECCAK_ROUND (KECCAK_RNDC_23);
}

// SHA3-256: rate=136 bytes (1088 bits), capacity=512 bits, padding=0x06
DECLSPEC void sha3_256_hash (PRIVATE_AS const u32 *pw, const u32 pw_len, PRIVATE_AS u32 *out)
{
  u64 st[25] = { 0 };

  const u32 rate = 136; // SHA3-256 rate in bytes

  // absorb password in LE byte order
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

  // remaining bytes + padding (no u8 temp buffer)
  const u32 rem = pw_len - pw_off;

  // rate / 8 = 17 u64 words per block
  // Process full u64 words from remaining data
  const u32 full_words = rem / 8;
  const u32 tail_bytes = rem % 8;

  for (u32 i = 0; i < full_words; i++)
  {
    const u32 idx = pw_off / 4 + i * 2;
    st[i] ^= hl32_to_64_S (pw[idx + 1], pw[idx]);
  }

  // Build the partial u64 word from remaining tail bytes + padding
  // The tail word index in the state
  const u32 tail_word = full_words;
  const u32 pw_base = pw_off + full_words * 8;

  u64 lane = 0;

  for (u32 b = 0; b < tail_bytes; b++)
  {
    const u32 abs_pos = pw_base + b;
    const u32 widx = abs_pos / 4;
    const u32 bidx = abs_pos % 4;
    const u64 byte_val = (u64)((pw[widx] >> (bidx * 8)) & 0xff);
    lane |= byte_val << (b * 8);
  }

  // SHA3-256 domain separation byte: 0x06 at position rem within the block
  // The padding byte goes at byte position tail_bytes within this u64 word
  lane |= ((u64) 0x06) << (tail_bytes * 8);

  st[tail_word] ^= lane;

  // Final bit of padding: 0x80 at byte position (rate - 1) = byte 135
  // rate - 1 = 135, word index = 135 / 8 = 16, byte offset = 135 % 8 = 7
  st[16] ^= ((u64) 0x80) << 56;

  keccak_transform_S (st);

  // squeeze: first 32 bytes (4 u64 = 8 u32)
  out[0] = l32_from_64_S (st[0]);
  out[1] = h32_from_64_S (st[0]);
  out[2] = l32_from_64_S (st[1]);
  out[3] = h32_from_64_S (st[1]);
  out[4] = l32_from_64_S (st[2]);
  out[5] = h32_from_64_S (st[2]);
  out[6] = l32_from_64_S (st[3]);
  out[7] = h32_from_64_S (st[3]);
}

KERNEL_FQ KERNEL_FA void m35901_mxx (KERN_ATTR_RULES ())
{
  const u64 gid = get_global_id (0);

  if (gid >= GID_CNT) return;

  secp256k1_t preG;

  set_precomputed_basepoint_g (&preG);

  COPY_PW (pws[gid]);

  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

  for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
  {
    pw_t p = PASTE_PW;

    p.pw_len = apply_rules (rules_buf[il_pos].cmds, p.i, p.pw_len);

    // SHA3-256 of passphrase
    u32 hash[8];

    sha3_256_hash (p.i, p.pw_len, hash);

    // hash is in LE byte order, need to convert for secp256k1 (expects reversed word order)
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
    for (u32 i = 8; i < 16; i++) tmp[i] = 0;

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

KERNEL_FQ KERNEL_FA void m35901_sxx (KERN_ATTR_RULES ())
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

  const u32 addr_type = salt_bufs[SALT_POS_HOST].salt_buf[0];

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
    for (u32 i = 8; i < 16; i++) tmp[i] = 0;

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
