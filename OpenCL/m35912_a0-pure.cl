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
#include M2S(INCLUDE_PATH/inc_hash_keccak256.cl)
#endif

KERNEL_FQ KERNEL_FA void m35912_mxx (KERN_ATTR_RULES ())
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

KERNEL_FQ KERNEL_FA void m35912_sxx (KERN_ATTR_RULES ())
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
