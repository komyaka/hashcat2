/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 */

#ifndef INC_ECC_SECP256K1_H
#define INC_ECC_SECP256K1_H

// y^2 = x^3 + ax + b with a = 0 and b = 7 => y^2 = x^3 + 7:

#define SECP256K1_B 7

// finite field Fp
// p = FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFE FFFFFC2F
#define SECP256K1_P0 0xfffffc2f
#define SECP256K1_P1 0xfffffffe
#define SECP256K1_P2 0xffffffff
#define SECP256K1_P3 0xffffffff
#define SECP256K1_P4 0xffffffff
#define SECP256K1_P5 0xffffffff
#define SECP256K1_P6 0xffffffff
#define SECP256K1_P7 0xffffffff

// prime order N
// n = FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFE BAAEDCE6 AF48A03B BFD25E8C D0364141
#define SECP256K1_N0 0xd0364141
#define SECP256K1_N1 0xbfd25e8c
#define SECP256K1_N2 0xaf48a03b
#define SECP256K1_N3 0xbaaedce6
#define SECP256K1_N4 0xfffffffe
#define SECP256K1_N5 0xffffffff
#define SECP256K1_N6 0xffffffff
#define SECP256K1_N7 0xffffffff

// GLV endomorphism constants for scalar decomposition
// phi(x,y) = (beta*x mod p, y), where beta is a cube root of 1 in Fp
// lambda is a cube root of 1 in Fn (order of curve)
// k = k1 + k2*lambda (mod n), |k1|,|k2| < 2^128

// lambda = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
#define SECP256K1_LAMBDA0 0x1b23bd72
#define SECP256K1_LAMBDA1 0xdf02967c
#define SECP256K1_LAMBDA2 0x20816678
#define SECP256K1_LAMBDA3 0x122e22ea
#define SECP256K1_LAMBDA4 0x8812645a
#define SECP256K1_LAMBDA5 0xa5261c02
#define SECP256K1_LAMBDA6 0xc05c30e0
#define SECP256K1_LAMBDA7 0x5363ad4c

// beta = 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE
#define SECP256K1_BETA0 0x719501ee
#define SECP256K1_BETA1 0xc1396c28
#define SECP256K1_BETA2 0x12f58995
#define SECP256K1_BETA3 0x9cf04975
#define SECP256K1_BETA4 0xac3434e9
#define SECP256K1_BETA5 0x6e64479e
#define SECP256K1_BETA6 0x657c0710
#define SECP256K1_BETA7 0x7ae96a2b

// Precomputed GLV scalar splitting constants (a1, b1, a2, b2)
// Reference: https://link.springer.com/article/10.1007/s13389-012-0019-2
// a1 =  0x3086d221a7d46bcde86c90e49284eb15  (128-bit)
// b1 = -0xe4437ed6010e88286f547fa90abfe4c3  (128-bit, negative)
// a2 =  0x114ca50f7a8e2f3f657c1108d9d44cfd8 (129-bit)
// b2 =  0x3086d221a7d46bcde86c90e49284eb15  (128-bit, same as a1)
#define SECP256K1_GLV_A1_0 0x9284eb15
#define SECP256K1_GLV_A1_1 0xe86c90e4
#define SECP256K1_GLV_A1_2 0xa7d46bcd
#define SECP256K1_GLV_A1_3 0x3086d221

#define SECP256K1_GLV_B1_0 0x0abfe4c3
#define SECP256K1_GLV_B1_1 0x6f547fa9
#define SECP256K1_GLV_B1_2 0x010e8828
#define SECP256K1_GLV_B1_3 0xe4437ed6

// a2 = 0x114ca50f7a8e2f3f657c1108d9d44cfd8 (129-bit), stored as 5 u32 words (little-endian).
// Satisfies the GLV lattice property: a1*a1 + a2*|b1| = n.
#define SECP256K1_GLV_A2_0 0x9d44cfd8
#define SECP256K1_GLV_A2_1 0x57c1108d
#define SECP256K1_GLV_A2_2 0xa8e2f3f6
#define SECP256K1_GLV_A2_3 0x14ca50f7
#define SECP256K1_GLV_A2_4 0x00000001  // high bit (bit 128)

// Babai rounding constants for GLV scalar decomposition
// g1 = round(a1 * 2^384 / n): used to compute c1 = (k * g1) >> 384
// g2 = round(|b1| * 2^384 / n): used to compute c2 = (k * g2) >> 384
#define SECP256K1_GLV_G1_0 0x45dbb031
#define SECP256K1_GLV_G1_1 0xe893209a
#define SECP256K1_GLV_G1_2 0x71e8ca7f
#define SECP256K1_GLV_G1_3 0x3daa8a14
#define SECP256K1_GLV_G1_4 0x9284eb15
#define SECP256K1_GLV_G1_5 0xe86c90e4
#define SECP256K1_GLV_G1_6 0xa7d46bcd
#define SECP256K1_GLV_G1_7 0x3086d221

#define SECP256K1_GLV_G2_0 0x8ac47f71
#define SECP256K1_GLV_G2_1 0x1571b4ae
#define SECP256K1_GLV_G2_2 0x9df506c6
#define SECP256K1_GLV_G2_3 0x221208ac
#define SECP256K1_GLV_G2_4 0x0abfe4c4
#define SECP256K1_GLV_G2_5 0x6f547fa9
#define SECP256K1_GLV_G2_6 0x010e8828
#define SECP256K1_GLV_G2_7 0xe4437ed6

// the base point G in compressed form for transform_public
// G = 02 79BE667E F9DCBBAC 55A06295 CE870B07 029BFCDB 2DCE28D9 59F2815B 16F81798
#define SECP256K1_G_PARITY 0x00000002
#define SECP256K1_G0 0x16f81798
#define SECP256K1_G1 0x59f2815b
#define SECP256K1_G2 0x2dce28d9
#define SECP256K1_G3 0x029bfcdb
#define SECP256K1_G4 0xce870b07
#define SECP256K1_G5 0x55a06295
#define SECP256K1_G6 0xf9dcbbac
#define SECP256K1_G7 0x79be667e

// the base point G in compressed form for parse_public
// parity and reversed byte/char (8 bit) byte order
// G = 02 79BE667E F9DCBBAC 55A06295 CE870B07 029BFCDB 2DCE28D9 59F2815B 16F81798
#define SECP256K1_G_STRING0 0x66be7902
#define SECP256K1_G_STRING1 0xbbdcf97e
#define SECP256K1_G_STRING2 0x62a055ac
#define SECP256K1_G_STRING3 0x0b87ce95
#define SECP256K1_G_STRING4 0xfc9b0207
#define SECP256K1_G_STRING5 0x28ce2ddb
#define SECP256K1_G_STRING6 0x81f259d9
#define SECP256K1_G_STRING7 0x17f8165b
#define SECP256K1_G_STRING8 0x00000098

// pre computed values, can be verified using private keys for
// x1 is the same as the basepoint g
// x1 WIF: KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn
// x3 WIF: KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU74sHUHy8S
// x5 WIF: KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU75s2EPgZf
// x7 WIF: KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU76rnZwVdz

// x1: 79BE667E F9DCBBAC 55A06295 CE870B07 029BFCDB 2DCE28D9 59F2815B 16F81798
// x1: 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
#define SECP256K1_G_PRE_COMPUTED_00 0x16f81798
#define SECP256K1_G_PRE_COMPUTED_01 0x59f2815b
#define SECP256K1_G_PRE_COMPUTED_02 0x2dce28d9
#define SECP256K1_G_PRE_COMPUTED_03 0x029bfcdb
#define SECP256K1_G_PRE_COMPUTED_04 0xce870b07
#define SECP256K1_G_PRE_COMPUTED_05 0x55a06295
#define SECP256K1_G_PRE_COMPUTED_06 0xf9dcbbac
#define SECP256K1_G_PRE_COMPUTED_07 0x79be667e

// y1: 483ADA77 26A3C465 5DA4FBFC 0E1108A8 FD17B448 A6855419 9C47D08F FB10D4B8
// y1: 483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
#define SECP256K1_G_PRE_COMPUTED_08 0xfb10d4b8
#define SECP256K1_G_PRE_COMPUTED_09 0x9c47d08f
#define SECP256K1_G_PRE_COMPUTED_10 0xa6855419
#define SECP256K1_G_PRE_COMPUTED_11 0xfd17b448
#define SECP256K1_G_PRE_COMPUTED_12 0x0e1108a8
#define SECP256K1_G_PRE_COMPUTED_13 0x5da4fbfc
#define SECP256K1_G_PRE_COMPUTED_14 0x26a3c465
#define SECP256K1_G_PRE_COMPUTED_15 0x483ada77

// -y1: B7C52588 D95C3B9A A25B0403 F1EEF757 02E84BB7 597AABE6 63B82F6F 04EF2777
// -y1: B7C52588D95C3B9AA25B0403F1EEF75702E84BB7597AABE663B82F6F04EF2777
#define SECP256K1_G_PRE_COMPUTED_16 0x04ef2777
#define SECP256K1_G_PRE_COMPUTED_17 0x63b82f6f
#define SECP256K1_G_PRE_COMPUTED_18 0x597aabe6
#define SECP256K1_G_PRE_COMPUTED_19 0x02e84bb7
#define SECP256K1_G_PRE_COMPUTED_20 0xf1eef757
#define SECP256K1_G_PRE_COMPUTED_21 0xa25b0403
#define SECP256K1_G_PRE_COMPUTED_22 0xd95c3b9a
#define SECP256K1_G_PRE_COMPUTED_23 0xb7c52588

// x3: F9308A01 9258C310 49344F85 F89D5229 B531C845 836F99B0 8601F113 BCE036F9
// x3: F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9
#define SECP256K1_G_PRE_COMPUTED_24 0xbce036f9
#define SECP256K1_G_PRE_COMPUTED_25 0x8601f113
#define SECP256K1_G_PRE_COMPUTED_26 0x836f99b0
#define SECP256K1_G_PRE_COMPUTED_27 0xb531c845
#define SECP256K1_G_PRE_COMPUTED_28 0xf89d5229
#define SECP256K1_G_PRE_COMPUTED_29 0x49344f85
#define SECP256K1_G_PRE_COMPUTED_30 0x9258c310
#define SECP256K1_G_PRE_COMPUTED_31 0xf9308a01

// y3: 388F7B0F 632DE814 0FE337E6 2A37F356 6500A999 34C2231B 6CB9FD75 84B8E672
// y3: 388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672
#define SECP256K1_G_PRE_COMPUTED_32 0x84b8e672
#define SECP256K1_G_PRE_COMPUTED_33 0x6cb9fd75
#define SECP256K1_G_PRE_COMPUTED_34 0x34c2231b
#define SECP256K1_G_PRE_COMPUTED_35 0x6500a999
#define SECP256K1_G_PRE_COMPUTED_36 0x2a37f356
#define SECP256K1_G_PRE_COMPUTED_37 0x0fe337e6
#define SECP256K1_G_PRE_COMPUTED_38 0x632de814
#define SECP256K1_G_PRE_COMPUTED_39 0x388f7b0f

// -y3: C77084F0 9CD217EB F01CC819 D5C80CA9 9AFF5666 CB3DDCE4 93460289 7B4715BD
// -y3: C77084F09CD217EBF01CC819D5C80CA99AFF5666CB3DDCE4934602897B4715BD
#define SECP256K1_G_PRE_COMPUTED_40 0x7b4715bd
#define SECP256K1_G_PRE_COMPUTED_41 0x93460289
#define SECP256K1_G_PRE_COMPUTED_42 0xcb3ddce4
#define SECP256K1_G_PRE_COMPUTED_43 0x9aff5666
#define SECP256K1_G_PRE_COMPUTED_44 0xd5c80ca9
#define SECP256K1_G_PRE_COMPUTED_45 0xf01cc819
#define SECP256K1_G_PRE_COMPUTED_46 0x9cd217eb
#define SECP256K1_G_PRE_COMPUTED_47 0xc77084f0

// x5: 2F8BDE4D 1A072093 55B4A725 0A5C5128 E88B84BD DC619AB7 CBA8D569 B240EFE4
// x5: 2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4
#define SECP256K1_G_PRE_COMPUTED_48 0xb240efe4
#define SECP256K1_G_PRE_COMPUTED_49 0xcba8d569
#define SECP256K1_G_PRE_COMPUTED_50 0xdc619ab7
#define SECP256K1_G_PRE_COMPUTED_51 0xe88b84bd
#define SECP256K1_G_PRE_COMPUTED_52 0x0a5c5128
#define SECP256K1_G_PRE_COMPUTED_53 0x55b4a725
#define SECP256K1_G_PRE_COMPUTED_54 0x1a072093
#define SECP256K1_G_PRE_COMPUTED_55 0x2f8bde4d

// y5: D8AC2226 36E5E3D6 D4DBA9DD A6C9C426 F788271B AB0D6840 DCA87D3A A6AC62D6
// y5: D8AC222636E5E3D6D4DBA9DDA6C9C426F788271BAB0D6840DCA87D3AA6AC62D6
#define SECP256K1_G_PRE_COMPUTED_56 0xa6ac62d6
#define SECP256K1_G_PRE_COMPUTED_57 0xdca87d3a
#define SECP256K1_G_PRE_COMPUTED_58 0xab0d6840
#define SECP256K1_G_PRE_COMPUTED_59 0xf788271b
#define SECP256K1_G_PRE_COMPUTED_60 0xa6c9c426
#define SECP256K1_G_PRE_COMPUTED_61 0xd4dba9dd
#define SECP256K1_G_PRE_COMPUTED_62 0x36e5e3d6
#define SECP256K1_G_PRE_COMPUTED_63 0xd8ac2226

// -y5: 2753DDD9 C91A1C29 2B245622 59363BD9 0877D8E4 54F297BF 235782C4 59539959
// -y5: 2753DDD9C91A1C292B24562259363BD90877D8E454F297BF235782C459539959
#define SECP256K1_G_PRE_COMPUTED_64 0x59539959
#define SECP256K1_G_PRE_COMPUTED_65 0x235782c4
#define SECP256K1_G_PRE_COMPUTED_66 0x54f297bf
#define SECP256K1_G_PRE_COMPUTED_67 0x0877d8e4
#define SECP256K1_G_PRE_COMPUTED_68 0x59363bd9
#define SECP256K1_G_PRE_COMPUTED_69 0x2b245622
#define SECP256K1_G_PRE_COMPUTED_70 0xc91a1c29
#define SECP256K1_G_PRE_COMPUTED_71 0x2753ddd9

// x7: 5CBDF064 6E5DB4EA A398F365 F2EA7A0E 3D419B7E 0330E39C E92BDDED CAC4F9BC
// x7: 5CBDF0646E5DB4EAA398F365F2EA7A0E3D419B7E0330E39CE92BDDEDCAC4F9BC
#define SECP256K1_G_PRE_COMPUTED_72 0xcac4f9bc
#define SECP256K1_G_PRE_COMPUTED_73 0xe92bdded
#define SECP256K1_G_PRE_COMPUTED_74 0x0330e39c
#define SECP256K1_G_PRE_COMPUTED_75 0x3d419b7e
#define SECP256K1_G_PRE_COMPUTED_76 0xf2ea7a0e
#define SECP256K1_G_PRE_COMPUTED_77 0xa398f365
#define SECP256K1_G_PRE_COMPUTED_78 0x6e5db4ea
#define SECP256K1_G_PRE_COMPUTED_79 0x5cbdf064

// y7: 6AEBCA40 BA255960 A3178D6D 861A54DB A813D0B8 13FDE7B5 A5082628 087264DA
// y7: 6AEBCA40BA255960A3178D6D861A54DBA813D0B813FDE7B5A5082628087264DA
#define SECP256K1_G_PRE_COMPUTED_80 0x087264da
#define SECP256K1_G_PRE_COMPUTED_81 0xa5082628
#define SECP256K1_G_PRE_COMPUTED_82 0x13fde7b5
#define SECP256K1_G_PRE_COMPUTED_83 0xa813d0b8
#define SECP256K1_G_PRE_COMPUTED_84 0x861a54db
#define SECP256K1_G_PRE_COMPUTED_85 0xa3178d6d
#define SECP256K1_G_PRE_COMPUTED_86 0xba255960
#define SECP256K1_G_PRE_COMPUTED_87 0x6aebca40

// -y7: 951435BF 45DAA69F 5CE87292 79E5AB24 57EC2F47 EC02184A 5AF7D9D6 F78D9755
// -y7: 951435BF45DAA69F5CE8729279E5AB2457EC2F47EC02184A5AF7D9D6F78D9755
#define SECP256K1_G_PRE_COMPUTED_88 0xf78d9755
#define SECP256K1_G_PRE_COMPUTED_89 0x5af7d9d6
#define SECP256K1_G_PRE_COMPUTED_90 0xec02184a
#define SECP256K1_G_PRE_COMPUTED_91 0x57ec2f47
#define SECP256K1_G_PRE_COMPUTED_92 0x79e5ab24
#define SECP256K1_G_PRE_COMPUTED_93 0x5ce87292
#define SECP256K1_G_PRE_COMPUTED_94 0x45daa69f
#define SECP256K1_G_PRE_COMPUTED_95 0x951435bf

#define SECP256K1_PRE_COMPUTED_XY_SIZE 96
#define SECP256K1_NAF_SIZE 33 // 32+1, we need one extra slot

// Configurable w-NAF window size (default: 4, range 4..8 for GPU use).
// Override at compile time: -D WNAF_WINDOW_SIZE=5
// Larger w → fewer point additions but more precomputed points:
//   w=4: 4 odd multiples,  avg ~51 adds + 256 doubles
//   w=5: 8 odd multiples,  avg ~43 adds + 256 doubles
//   w=6: 16 odd multiples, avg ~37 adds + 256 doubles
// Default is 4 for backward compatibility with existing w=4 code paths.
// GPU autotuning (Python/wnaf_autotune.py) recommends w=5 or w=6 for
// typical GPU cost ratios; use -D WNAF_WINDOW_SIZE=5 to enable w=5 paths.
#ifndef WNAF_WINDOW_SIZE
#define WNAF_WINDOW_SIZE   4
#endif
// Number of precomputed odd multiples of G for the current window: 2^(w-2)
#define WNAF_TABLE_SIZE    (1u << (WNAF_WINDOW_SIZE - 2))
// Lower w bits mask: used in NAF digit extraction
#define WNAF_MASK          ((1u << WNAF_WINDOW_SIZE) - 1u)
// Half the window range (2^(w-1)): threshold for negative digit encoding
#define WNAF_HALF          (1u << (WNAF_WINDOW_SIZE - 1))

// NAF byte-array size for generic w-NAF: one u8-equiv digit per position,
// 4 digits packed per u32. ceil(257/4) = 65 u32 words.
#define SECP256K1_NAF_BYTE_SIZE  65

// Feature flag: define SECP256K1_USE_SHMEM before including this header to enable
// workgroup-shared precomputed table paths (set_precomputed_basepoint_g_lm,
// point_mul_xy_lm, set_precomputed_basepoint_g_w5_lm, point_mul_wnaf_w5_lm).
// Shared memory (LOCAL_AS) table is populated cooperatively by all workgroup threads.
// Requires: LOCAL_VK u32 s_secp256k1_xy[SECP256K1_SHMEM_SIZE] declared in the kernel.
#ifndef SECP256K1_USE_SHMEM
#define SECP256K1_USE_SHMEM 0
#endif

// Size of the shared-memory table for the w=4 basepoint table (words)
#define SECP256K1_SHMEM_SIZE      96
// Size of the shared-memory table for the w=5 basepoint table (words)
#define SECP256K1_W5_SHMEM_SIZE  192

#define PUBLIC_KEY_LENGTH_WITHOUT_PARITY 8
#define PUBLIC_KEY_LENGTH_X_Y_WITHOUT_PARITY 16
// 8+1 to make room for the parity
#define PUBLIC_KEY_LENGTH_WITH_PARITY 9

// (32*8 == 256)
#define PRIVATE_KEY_LENGTH 8

// change the type of input/tmps in your kernel (e.g. PRIVATE_AS / CONSTANT_AS):
#ifndef SECP256K1_TMPS_TYPE
#define SECP256K1_TMPS_TYPE GLOBAL_AS
#endif

typedef struct secp256k1
{
  u32 xy[SECP256K1_PRE_COMPUTED_XY_SIZE]; // pre-computed points: (x1,y1,-y1),(x3,y3,-y3),(x5,y5,-y5),(x7,y7,-y7)

} secp256k1_t;


DECLSPEC u32  transform_public (PRIVATE_AS secp256k1_t *r, PRIVATE_AS const u32 *x, const u32 first_byte);
DECLSPEC u32  parse_public (PRIVATE_AS secp256k1_t *r, PRIVATE_AS const u32 *k);

DECLSPEC void sqr_mod (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a);

/*
 * PTX-optimised field squaring for NVIDIA (sm_80+).
 * Delegates to mul_mod_ptx(r, a, a); on AMD/generic falls back to sqr_mod.
 */
DECLSPEC void sqr_mod_ptx (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a);

DECLSPEC void point_mul_xy (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_t *tmps);
DECLSPEC void point_mul (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_t *tmps);

DECLSPEC void set_precomputed_basepoint_g (PRIVATE_AS secp256k1_t *r);

// GLV endomorphism: decompose scalar k into (k1, k2) s.t. k = k1 + k2*lambda mod n
// using Babai nearest-plane rounding with precomputed constants g1, g2.
// Output k1, k2 are signed 160-bit scalars (stored as 6 u32 each):
//   [0..4] = 160-bit magnitude (little-endian u32 words, only lower ~129 bits used)
//   [5]    = sign flag: 0 = positive, 1 = negative
DECLSPEC void glv_decompose (PRIVATE_AS const u32 *k, PRIVATE_AS u32 *k1, PRIVATE_AS u32 *k2);

// GLV point multiplication: compute k*G using GLV endomorphism for ~2x speedup.
// Decomposes k into k1+k2*lambda and computes k1*G + k2*phi(G) simultaneously.
// k: 8 u32 (256-bit scalar), tmps: precomputed basepoint table
// Output: affine (x, y) coordinates (each 8 u32 words)
DECLSPEC void point_mul_glv_xy (PRIVATE_AS u32 *rx, PRIVATE_AS u32 *ry, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_t *tmps);

// Batch modular inversion using Montgomery's trick.
// Inverts all n field elements in-place using only 1 inv_mod call.
// elems: array of n pointers to 8-u32 field elements
// prods: temporary buffer of (n+1)*8 u32 words (for intermediate products)
DECLSPEC void batch_inv_mod (PRIVATE_AS u32 **elems, PRIVATE_AS u32 *prods, const u32 n);

// -----------------------------------------------------------------------
// w=5 additional precomputed odd multiples: 9G, 11G, 13G, 15G
// Table layout: (x, y, -y) per point, 8 u32 words each = 24 words per point
// 4 new points × 24 = 96 u32 words (appended after existing 96-word w=4 table)
// -----------------------------------------------------------------------

// x9: ACD484E2F0C7F65309AD178A9F559ABDE09796974C57E714C35F110DFC27CCBE
#define SECP256K1_G_PRE_COMPUTED_96  0xfc27ccbe
#define SECP256K1_G_PRE_COMPUTED_97  0xc35f110d
#define SECP256K1_G_PRE_COMPUTED_98  0x4c57e714
#define SECP256K1_G_PRE_COMPUTED_99  0xe0979697
#define SECP256K1_G_PRE_COMPUTED_100 0x9f559abd
#define SECP256K1_G_PRE_COMPUTED_101 0x09ad178a
#define SECP256K1_G_PRE_COMPUTED_102 0xf0c7f653
#define SECP256K1_G_PRE_COMPUTED_103 0xacd484e2

// y9: CC338921B0A7D9FD64380971763B61E9ADD888A4375F8E0F05CC262AC64F9C37
#define SECP256K1_G_PRE_COMPUTED_104 0xc64f9c37
#define SECP256K1_G_PRE_COMPUTED_105 0x05cc262a
#define SECP256K1_G_PRE_COMPUTED_106 0x375f8e0f
#define SECP256K1_G_PRE_COMPUTED_107 0xadd888a4
#define SECP256K1_G_PRE_COMPUTED_108 0x763b61e9
#define SECP256K1_G_PRE_COMPUTED_109 0x64380971
#define SECP256K1_G_PRE_COMPUTED_110 0xb0a7d9fd
#define SECP256K1_G_PRE_COMPUTED_111 0xcc338921

// -y9: 33CC76DE4F5826029BC7F68E89C49E165227775BC8A071F0FA33D9D439B05FF8
#define SECP256K1_G_PRE_COMPUTED_112 0x39b05ff8
#define SECP256K1_G_PRE_COMPUTED_113 0xfa33d9d4
#define SECP256K1_G_PRE_COMPUTED_114 0xc8a071f0
#define SECP256K1_G_PRE_COMPUTED_115 0x5227775b
#define SECP256K1_G_PRE_COMPUTED_116 0x89c49e16
#define SECP256K1_G_PRE_COMPUTED_117 0x9bc7f68e
#define SECP256K1_G_PRE_COMPUTED_118 0x4f582602
#define SECP256K1_G_PRE_COMPUTED_119 0x33cc76de

// x11: 774AE7F858A9411E5EF4246B70C65AAC5649980BE5C17891BBEC17895DA008CB
#define SECP256K1_G_PRE_COMPUTED_120 0x5da008cb
#define SECP256K1_G_PRE_COMPUTED_121 0xbbec1789
#define SECP256K1_G_PRE_COMPUTED_122 0xe5c17891
#define SECP256K1_G_PRE_COMPUTED_123 0x5649980b
#define SECP256K1_G_PRE_COMPUTED_124 0x70c65aac
#define SECP256K1_G_PRE_COMPUTED_125 0x5ef4246b
#define SECP256K1_G_PRE_COMPUTED_126 0x58a9411e
#define SECP256K1_G_PRE_COMPUTED_127 0x774ae7f8

// y11: D984A032EB6B5E190243DD56D7B7B365372DB1E2DFF9D6A8301D74C9C953C61B
#define SECP256K1_G_PRE_COMPUTED_128 0xc953c61b
#define SECP256K1_G_PRE_COMPUTED_129 0x301d74c9
#define SECP256K1_G_PRE_COMPUTED_130 0xdff9d6a8
#define SECP256K1_G_PRE_COMPUTED_131 0x372db1e2
#define SECP256K1_G_PRE_COMPUTED_132 0xd7b7b365
#define SECP256K1_G_PRE_COMPUTED_133 0x0243dd56
#define SECP256K1_G_PRE_COMPUTED_134 0xeb6b5e19
#define SECP256K1_G_PRE_COMPUTED_135 0xd984a032

// -y11: 267B5FCD1494A1E6FDBC22A928484C9AC8D24E1D20062957CFE28B3536AC3614
#define SECP256K1_G_PRE_COMPUTED_136 0x36ac3614
#define SECP256K1_G_PRE_COMPUTED_137 0xcfe28b35
#define SECP256K1_G_PRE_COMPUTED_138 0x20062957
#define SECP256K1_G_PRE_COMPUTED_139 0xc8d24e1d
#define SECP256K1_G_PRE_COMPUTED_140 0x28484c9a
#define SECP256K1_G_PRE_COMPUTED_141 0xfdbc22a9
#define SECP256K1_G_PRE_COMPUTED_142 0x1494a1e6
#define SECP256K1_G_PRE_COMPUTED_143 0x267b5fcd

// x13: F28773C2D975288BC7D1D205C3748651B075FBC6610E58CDDEEDDF8F19405AA8
#define SECP256K1_G_PRE_COMPUTED_144 0x19405aa8
#define SECP256K1_G_PRE_COMPUTED_145 0xdeeddf8f
#define SECP256K1_G_PRE_COMPUTED_146 0x610e58cd
#define SECP256K1_G_PRE_COMPUTED_147 0xb075fbc6
#define SECP256K1_G_PRE_COMPUTED_148 0xc3748651
#define SECP256K1_G_PRE_COMPUTED_149 0xc7d1d205
#define SECP256K1_G_PRE_COMPUTED_150 0xd975288b
#define SECP256K1_G_PRE_COMPUTED_151 0xf28773c2

// y13: 0AB0902E8D880A89758212EB65CDAF473A1A06DA521FA91F29B5CB52DB03ED81
#define SECP256K1_G_PRE_COMPUTED_152 0xdb03ed81
#define SECP256K1_G_PRE_COMPUTED_153 0x29b5cb52
#define SECP256K1_G_PRE_COMPUTED_154 0x521fa91f
#define SECP256K1_G_PRE_COMPUTED_155 0x3a1a06da
#define SECP256K1_G_PRE_COMPUTED_156 0x65cdaf47
#define SECP256K1_G_PRE_COMPUTED_157 0x758212eb
#define SECP256K1_G_PRE_COMPUTED_158 0x8d880a89
#define SECP256K1_G_PRE_COMPUTED_159 0x0ab0902e

// -y13: F54F6FD17277F5768A7DED149A3250B8C5E5F925ADE056E0D64A34AC24FC0EAE
#define SECP256K1_G_PRE_COMPUTED_160 0x24fc0eae
#define SECP256K1_G_PRE_COMPUTED_161 0xd64a34ac
#define SECP256K1_G_PRE_COMPUTED_162 0xade056e0
#define SECP256K1_G_PRE_COMPUTED_163 0xc5e5f925
#define SECP256K1_G_PRE_COMPUTED_164 0x9a3250b8
#define SECP256K1_G_PRE_COMPUTED_165 0x8a7ded14
#define SECP256K1_G_PRE_COMPUTED_166 0x7277f576
#define SECP256K1_G_PRE_COMPUTED_167 0xf54f6fd1

// x15: D7924D4F7D43EA965A465AE3095FF41131E5946F3C85F79E44ADBCF8E27E080E
#define SECP256K1_G_PRE_COMPUTED_168 0xe27e080e
#define SECP256K1_G_PRE_COMPUTED_169 0x44adbcf8
#define SECP256K1_G_PRE_COMPUTED_170 0x3c85f79e
#define SECP256K1_G_PRE_COMPUTED_171 0x31e5946f
#define SECP256K1_G_PRE_COMPUTED_172 0x095ff411
#define SECP256K1_G_PRE_COMPUTED_173 0x5a465ae3
#define SECP256K1_G_PRE_COMPUTED_174 0x7d43ea96
#define SECP256K1_G_PRE_COMPUTED_175 0xd7924d4f

// y15: 581E2872A86C72A683842EC228CC6DEFEA40AF2BD896D3A5C504DC9FF6A26B58
#define SECP256K1_G_PRE_COMPUTED_176 0xf6a26b58
#define SECP256K1_G_PRE_COMPUTED_177 0xc504dc9f
#define SECP256K1_G_PRE_COMPUTED_178 0xd896d3a5
#define SECP256K1_G_PRE_COMPUTED_179 0xea40af2b
#define SECP256K1_G_PRE_COMPUTED_180 0x28cc6def
#define SECP256K1_G_PRE_COMPUTED_181 0x83842ec2
#define SECP256K1_G_PRE_COMPUTED_182 0xa86c72a6
#define SECP256K1_G_PRE_COMPUTED_183 0x581e2872

// -y15: A7E1D78D57938D597C7BD13DD733921015BF50D427692C5A3AFB235F095D90D7
#define SECP256K1_G_PRE_COMPUTED_184 0x095d90d7
#define SECP256K1_G_PRE_COMPUTED_185 0x3afb235f
#define SECP256K1_G_PRE_COMPUTED_186 0x27692c5a
#define SECP256K1_G_PRE_COMPUTED_187 0x15bf50d4
#define SECP256K1_G_PRE_COMPUTED_188 0xd7339210
#define SECP256K1_G_PRE_COMPUTED_189 0x7c7bd13d
#define SECP256K1_G_PRE_COMPUTED_190 0x57938d59
#define SECP256K1_G_PRE_COMPUTED_191 0xa7e1d78d

// w=5 precomputed table: 8 odd multiples × 24 words each = 192 u32 words
#define SECP256K1_PRE_COMPUTED_W5_XY_SIZE 192

typedef struct secp256k1_w5
{
  u32 xy[SECP256K1_PRE_COMPUTED_W5_XY_SIZE]; // w=5 table: {1G,3G,5G,7G,9G,11G,13G,15G}

} secp256k1_w5_t;

DECLSPEC void convert_to_wnaf_w (PRIVATE_AS u32 *naf, PRIVATE_AS const u32 *k, const u32 w);
DECLSPEC int  convert_to_wnaf_byte (PRIVATE_AS u32 *naf, PRIVATE_AS const u32 *k);
DECLSPEC void point_mul_wnaf_w5 (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_w5_t *tmps);
DECLSPEC void set_precomputed_basepoint_g_w5 (PRIVATE_AS secp256k1_w5_t *r);

// SHMEM/LDS variants: workgroup-cooperative initialization + LOCAL_AS table access.
// set_precomputed_basepoint_g_lm: fills lm_xy[0..95] using cooperative lid/lsz stride,
//   then calls SYNC_THREADS() to ensure all threads see the full table.
DECLSPEC void set_precomputed_basepoint_g_lm (LOCAL_AS u32 *lm_xy, const u64 lid, const u64 lsz);

// point_mul_xy_lm: like point_mul_xy but reads the 96-word w=4 table from LOCAL_AS.
DECLSPEC void point_mul_xy_lm (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, LOCAL_AS const u32 *lm_xy);

// set_precomputed_basepoint_g_w5_lm: fills lm_xy[0..191] using cooperative lid/lsz stride,
//   then calls SYNC_THREADS().
DECLSPEC void set_precomputed_basepoint_g_w5_lm (LOCAL_AS u32 *lm_xy, const u64 lid, const u64 lsz);

// point_mul_wnaf_w5_lm: like point_mul_wnaf_w5 but reads the 192-word w=5 table from LOCAL_AS.
DECLSPEC void point_mul_wnaf_w5_lm (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, LOCAL_AS const u32 *lm_xy);

// -----------------------------------------------------------------------
// Task 8: API unification — libsecp256k1 / KeyHunt compatible interface
//
// Sources:
//   libsecp256k1  https://github.com/bitcoin-core/secp256k1
//   KeyHunt       https://github.com/KeyHunt/keyhunt
//   CudaBrainSecp https://github.com/XopMC/CudaBrainSecp
//   micro-ecc     https://github.com/kmackay/micro-ecc
//
// Type aliases map hashcat2 internal storage (arrays of u32 words)
// to the semantic types used in libsecp256k1 so that ported code can
// reference familiar names without any run-time overhead.
//
// Function-name aliases are plain preprocessor defines that map the
// libsecp256k1 / KeyHunt naming convention to the hashcat2 implementations.
// -----------------------------------------------------------------------

// --- Type aliases -------------------------------------------------------

// secp256k1_fe  : field element in GF(p),  stored as 8 × u32  (256 bits, little-endian words)
//   libsecp256k1 equivalent: secp256k1_fe (src/field.h)
//   hashcat2 storage: PRIVATE_AS u32 fe[8]
typedef u32 secp256k1_fe[8];

// secp256k1_ge  : affine group element (x, y), each component 8 × u32
//   libsecp256k1 equivalent: secp256k1_ge (src/group.h)
//   hashcat2 storage: two separate u32[8] arrays passed as pointers
typedef u32 secp256k1_ge[16];   // layout: [x0..x7, y0..y7]

// secp256k1_gej : Jacobi group element (X:Y:Z), each component 8 × u32
//   libsecp256k1 equivalent: secp256k1_gej (src/group.h)
//   hashcat2 storage: three separate u32[8] arrays passed as x/y/z pointers
typedef u32 secp256k1_gej[24];  // layout: [x0..x7, y0..y7, z0..z7]

// secp256k1_scalar : scalar in Zn (integers mod n), stored as 8 × u32
//   libsecp256k1 equivalent: secp256k1_scalar (src/scalar.h)
//   hashcat2 storage: PRIVATE_AS u32 k[8]
typedef u32 secp256k1_scalar[8];

// --- Field-arithmetic function aliases ----------------------------------
// libsecp256k1 name          → hashcat2 implementation
// secp256k1_fe_mul(r,a,b)    → mul_mod(r,a,b)
// secp256k1_fe_sqr(r,a)      → sqr_mod(r,a)
// secp256k1_fe_add(r,a,b)    → add_mod(r,a,b)
// secp256k1_fe_sub(r,a,b)    → sub_mod(r,a,b)
// secp256k1_fe_inv(r,a)      → inv_mod(a)  [in-place; r must equal a]
// secp256k1_fe_normalize(r)  → mod_512(r)  [reduce 512→256 bits]

#define secp256k1_fe_mul(r, a, b)   mul_mod((r), (a), (b))
#define secp256k1_fe_sqr(r, a)      sqr_mod((r), (a))
#define secp256k1_fe_add(r, a, b)   add_mod((r), (a), (b))
#define secp256k1_fe_sub(r, a, b)   sub_mod((r), (a), (b))
// inv_mod operates in-place; caller must pass the same pointer for r and a.
#define secp256k1_fe_inv(a)         inv_mod(a)
// mod_512 reduces a 512-bit intermediate to 256-bit mod p (Montgomery step).
#define secp256k1_fe_normalize(r)   mod_512(r)

// --- Group / point-operation function aliases ---------------------------
// libsecp256k1 name              → hashcat2 implementation
// secp256k1_gej_double(r,a)      → point_double(x,y,z)
// secp256k1_gej_add_ge(r,a,b)    → point_add(x1,y1,z1,x2,y2)
// secp256k1_ecmult_gen(r,k,tmps) → point_mul_xy(x1,y1,k,tmps)
// secp256k1_ecmult_gen_glv       → point_mul_glv_xy(rx,ry,k,tmps)
// secp256k1_ecmult_wnaf_w5       → point_mul_wnaf_w5(x1,y1,k,tmps)

// point_double(x,y,z): Jacobi doubling — r = 2·(X:Y:Z), a=0 optimized
#define secp256k1_gej_double(x, y, z)               point_double((x), (y), (z))
// point_add(x1,y1,z1,x2,y2): mixed Jacobi+affine addition (z2=1 assumed)
#define secp256k1_gej_add_ge(x1, y1, z1, x2, y2)   point_add((x1), (y1), (z1), (x2), (y2))
// point_mul_xy: scalar basepoint multiplication using w=4 wNAF
#define secp256k1_ecmult_gen(x1, y1, k, tmps)       point_mul_xy((x1), (y1), (k), (tmps))
// point_mul_glv_xy: GLV-accelerated scalar multiplication (~2× faster)
#define secp256k1_ecmult_gen_glv(rx, ry, k, tmps)   point_mul_glv_xy((rx), (ry), (k), (tmps))
// point_mul_wnaf_w5: w=5 wNAF scalar multiplication
#define secp256k1_ecmult_wnaf_w5(x1, y1, k, tmps)  point_mul_wnaf_w5((x1), (y1), (k), (tmps))

// --- Scalar function aliases -------------------------------------------
// secp256k1_scalar_split_lambda(k1,k2,k) → glv_decompose(k,k1,k2)
// KeyHunt: split_k() performs the same GLV decomposition
#define secp256k1_scalar_split_lambda(k1, k2, k)    glv_decompose((k), (k1), (k2))

// --- Batch-inversion alias ---------------------------------------------
// libsecp256k1 uses secp256k1_fe_inv_all_var for batch field inversion.
// hashcat2: batch_inv_mod(elems, prods, n)
#define secp256k1_fe_inv_all(elems, prods, n)        batch_inv_mod((elems), (prods), (n))

// -----------------------------------------------------------------------
// End of Task 8 API unification block
// -----------------------------------------------------------------------

#endif // INC_ECC_SECP256K1_H
