/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 *
 * Shared Keccak-256 / SHA3-256 implementation for hashcat modules.
 *
 * Provides:
 *   keccak_transform_S  — fully unrolled 24-round Keccak permutation (no loops, no
 *                         runtime table lookups); use Rho_Pi_Imm with compile-time
 *                         immediate rotation constants for maximum GPU performance.
 *   keccak_256_64       — Keccak-256 of a fixed 64-byte input (Ethereum pubkey hash).
 *   keccak_256_hash     — Keccak-256 of an arbitrary-length password; uses register-only
 *                         padding (no u8 temp[] stack buffer) to minimise register spill.
 *   sha3_256_hash       — SHA3-256 of an arbitrary-length password (same as keccak_256_hash
 *                         but with the 0x06 domain-separation byte instead of 0x01).
 *
 * NOTE: "Original Keccak-256" (pad 0x01) is what Ethereum uses.
 *       "SHA3-256" (FIPS 202, pad 0x06) is the standardised variant.
 *       They differ only in the padding byte.
 */

/* --------------------------------------------------------------------------
 * Keccak round constants (24 values, 64-bit each)
 * -------------------------------------------------------------------------- */

#define Theta1(s) (st[0 + s] ^ st[5 + s] ^ st[10 + s] ^ st[15 + s] ^ st[20 + s])

#define Theta2(s)               \
{                               \
  st[ 0 + s] ^= t;              \
  st[ 5 + s] ^= t;              \
  st[10 + s] ^= t;              \
  st[15 + s] ^= t;              \
  st[20 + s] ^= t;              \
}

/*
 * Rho_Pi_Imm — unrolled Rho+Pi step with immediate-constant rotation amount k.
 * The compiler sees all 24 rotation amounts at compile time and can emit a single
 * rotate instruction without any runtime table lookups.
 */
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

/*
 * KECCAK_ROUND — one full Keccak round (Theta + Rho + Pi + Chi + Iota).
 * All 24 Rho_Pi_Imm indices/rotations are compile-time constants so the GPU
 * compiler can fully unroll and schedule them optimally.
 */
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

/* --------------------------------------------------------------------------
 * keccak_transform_S — fully unrolled 24-round Keccak-f[1600] permutation.
 *
 * Performance vs. the loop-based version (m35902/35903/35904/35912 original):
 *  - No loop counter → no branch overhead per round
 *  - No runtime table reads (keccakf_piln / keccakf_rotc arrays eliminated)
 *  - All 24 rotation amounts are immediate constants → single-cycle VROT/VSHL
 *  - Compiler can schedule all 24 rounds as a straight-line block
 *  - Estimated 2–3× faster on AMD RDNA / NVIDIA Ampere
 * -------------------------------------------------------------------------- */
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

/* --------------------------------------------------------------------------
 * keccak_256_64 — Keccak-256 of a fixed 64-byte input.
 *
 * Used to hash the uncompressed public key (x||y, 64 bytes) for Ethereum
 * address derivation.  The 64-byte input fits in a single Keccak rate block
 * (rate = 136 bytes for Keccak-256), so no multi-block processing is needed.
 *
 * Padding: original Keccak-256 (0x01 at byte 64, 0x80 at byte 135).
 *
 * Output: last 20 bytes of the 32-byte Keccak-256 digest (bytes 12–31),
 *         stored as 5 u32 words in big-endian order for address comparison.
 * -------------------------------------------------------------------------- */
DECLSPEC void keccak_256_64 (PRIVATE_AS const u32 *in, PRIVATE_AS u32 *out)
{
  u64 st[25] = { 0 };

  /* Absorb all 8 u64 words of the 64-byte input */
  st[0] = hl32_to_64_S (in[ 1], in[ 0]);
  st[1] = hl32_to_64_S (in[ 3], in[ 2]);
  st[2] = hl32_to_64_S (in[ 5], in[ 4]);
  st[3] = hl32_to_64_S (in[ 7], in[ 6]);
  st[4] = hl32_to_64_S (in[ 9], in[ 8]);
  st[5] = hl32_to_64_S (in[11], in[10]);
  st[6] = hl32_to_64_S (in[13], in[12]);
  st[7] = hl32_to_64_S (in[15], in[14]);

  /*
   * Original Keccak-256 padding (NOT SHA3; Ethereum uses original Keccak):
   *   0x01 at byte 64  → st[8], byte 0  → low bit of st[8]
   *   0x80 at byte 135 → st[16], byte 7 → high bit of st[16]
   */
  st[8]  ^= 0x0000000000000001ULL;
  st[16] ^= 0x8000000000000000ULL;

  keccak_transform_S (st);

  /*
   * Squeeze: we need bytes 12–31 of the output (last 20 bytes = Ethereum addr).
   * st[0] = bytes 0–7, st[1] = bytes 8–15, st[2] = bytes 16–23, st[3] = bytes 24–31.
   * bytes 12–15 = high 32 bits of st[1]
   * bytes 16–31 = st[2] and st[3] in full
   */
  out[0] = h32_from_64_S (st[1]); /* bytes 12–15 */
  out[1] = l32_from_64_S (st[2]); /* bytes 16–19 */
  out[2] = h32_from_64_S (st[2]); /* bytes 20–23 */
  out[3] = l32_from_64_S (st[3]); /* bytes 24–27 */
  out[4] = h32_from_64_S (st[3]); /* bytes 28–31 */
}

/* --------------------------------------------------------------------------
 * keccak_256_hash_impl — variable-length Keccak-256/SHA3-256 absorb+squeeze.
 *
 * Handles arbitrary password lengths using register-only padding — no u8
 * temp[136] stack buffer.  This is critical for AMD/NVIDIA GPUs where a
 * 136-byte stack array costs ~34 VGPRs and can push total register usage over
 * the hardware limit, causing catastrophic register spilling.
 *
 * Parameters:
 *   pw        — password words (little-endian u32 array, hashcat convention)
 *   pw_len    — password length in bytes
 *   out       — 8 u32 output words (256-bit digest, little-endian)
 *   pad_byte  — 0x01 for original Keccak-256, 0x06 for SHA3-256 (FIPS 202)
 * -------------------------------------------------------------------------- */
DECLSPEC void keccak_256_hash_impl (PRIVATE_AS const u32 *pw, const u32 pw_len, PRIVATE_AS u32 *out, const u8 pad_byte)
{
  u64 st[25] = { 0 };

  /* Keccak-256 rate = 1088 bits = 136 bytes = 17 u64 words */
  const u32 rate = 136;

  u32 pw_off = 0;

  /* Multi-block absorb (only triggered for pw_len >= 136, which is rare
   * for typical passwords but handles long inputs correctly) */
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

  /* Remaining bytes: rem < 136 */
  const u32 rem        = pw_len - pw_off;
  const u32 full_words = rem / 8;   /* number of complete u64 words in remainder */
  const u32 tail_bytes = rem % 8;   /* leftover bytes after the last complete u64 */

  /* Absorb complete u64 words from the remainder */
  for (u32 i = 0; i < full_words; i++)
  {
    const u32 idx = pw_off / 4 + i * 2;
    st[i] ^= hl32_to_64_S (pw[idx + 1], pw[idx]);
  }

  /*
   * Build the partial u64 lane that straddles the end of the password
   * and the start of the padding — entirely in registers, no temp buffer.
   *
   * Layout (little-endian): bytes [0..tail_bytes-1] = password tail,
   *                          byte  [tail_bytes]      = pad_byte,
   *                          bytes [tail_bytes+1..7] = 0x00.
   */
  const u32 pw_base = pw_off + full_words * 8;
  u64 lane = 0;

  for (u32 b = 0; b < tail_bytes; b++)
  {
    const u32 abs_pos = pw_base + b;
    const u32 widx    = abs_pos / 4;
    const u32 bidx    = abs_pos % 4;
    lane |= ((u64)((pw[widx] >> (bidx * 8)) & 0xff)) << (b * 8);
  }

  lane |= ((u64) pad_byte) << (tail_bytes * 8);

  st[full_words] ^= lane;

  /*
   * Final padding bit: 0x80 at byte (rate - 1) = byte 135.
   * rate - 1 = 135 → u64 word index = 135 / 8 = 16, byte offset = 7
   * → high bit of st[16].
   */
  st[16] ^= 0x8000000000000000ULL;

  keccak_transform_S (st);

  /* Squeeze first 32 bytes (4 u64 words = 8 u32 words) */
  out[0] = l32_from_64_S (st[0]);
  out[1] = h32_from_64_S (st[0]);
  out[2] = l32_from_64_S (st[1]);
  out[3] = h32_from_64_S (st[1]);
  out[4] = l32_from_64_S (st[2]);
  out[5] = h32_from_64_S (st[2]);
  out[6] = l32_from_64_S (st[3]);
  out[7] = h32_from_64_S (st[3]);
}

/*
 * keccak_256_hash — original Keccak-256 (Ethereum, pad = 0x01).
 * Thin wrapper over keccak_256_hash_impl; the constant pad_byte is visible
 * to the compiler at the call site so it can be inlined and optimised away.
 */
DECLSPEC void keccak_256_hash (PRIVATE_AS const u32 *pw, const u32 pw_len, PRIVATE_AS u32 *out)
{
  keccak_256_hash_impl (pw, pw_len, out, 0x01);
}

/*
 * sha3_256_hash — SHA3-256 (FIPS 202, pad = 0x06).
 * Thin wrapper over keccak_256_hash_impl.
 */
DECLSPEC void sha3_256_hash (PRIVATE_AS const u32 *pw, const u32 pw_len, PRIVATE_AS u32 *out)
{
  keccak_256_hash_impl (pw, pw_len, out, 0x06);
}
