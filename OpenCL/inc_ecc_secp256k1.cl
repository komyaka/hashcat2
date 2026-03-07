/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 *
 * Furthermore, since elliptic curve operations are highly researched and optimized,
 * we've consulted a lot of online resources to implement this, including several papers and
 * example code.
 *
 * Credits where credits are due: there are a lot of nice projects that explain and/or optimize
 * elliptic curve operations (especially elliptic curve multiplications by a scalar).
 *
 * We want to shout out following projects, which were quite helpful when implementing this:
 * - secp256k1 by Pieter Wuille (https://github.com/bitcoin-core/secp256k1/, MIT)
 * - secp256k1-cl by hhanh00 (https://github.com/hhanh00/secp256k1-cl/, MIT)
 * - ec_pure_c by masterzorag (https://github.com/masterzorag/ec_pure_c/)
 * - ecc-gmp by leivaburto (https://github.com/leivaburto/ecc-gmp)
 * - micro-ecc by Ken MacKay (https://github.com/kmackay/micro-ecc/, BSD)
 * - curve_example by willem (https://gist.github.com/nlitsme/c9031c7b9bf6bb009e5a)
 * - py_ecc by Vitalik Buterin (https://github.com/ethereum/py_ecc/, MIT)
 *
 *
 * Some BigNum operations are implemented similar to micro-ecc which is licensed under these terms:
 *  Copyright 2014 Ken MacKay, 2-Clause BSD License
 *
 *  Redistribution and use in source and binary forms, with or without modification, are permitted
 *  provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice, this list of
 *     conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright notice, this list of
 *     conditions and the following disclaimer in the documentation and/or other materials
 *     provided with the distribution.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 *  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 *  AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
 *  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 *  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 *  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 *  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * ATTENTION: this code is NOT meant to be used in security critical environments that are at risk
 * of side-channel or timing attacks etc, it's only purpose is to make it work fast for GPGPU
 * (OpenCL/CUDA). Some attack vectors like side-channel and timing-attacks might be possible,
 * because of some optimizations used within this code (non-constant time etc).
 */

/*
 * Implementation considerations:
 * point double and point add are implemented similar to algorithms mentioned in this 2011 paper:
 * http://eprint.iacr.org/2011/338.pdf
 * (Fast and Regular Algorithms for Scalar Multiplication over Elliptic Curves by Matthieu Rivain)
 *
 * In theory we could use the Jacobian Co-Z enhancement to get rid of the larger buffer caused by
 * the z coordinates (and in this way reduce register pressure etc).
 * For the Co-Z improvement there are a lot of fast algorithms, but we might still be faster
 * with this implementation (b/c we allow non-constant time) without the Brier/Joye Montgomery-like
 * ladder. Of course, this claim would need to be verified and tested to see which one is faster
 * for our specific scenario at the end.
 *
 * We accomplish a "little" speedup by using scalars converted to w-NAF (non-adjacent form):
 * The general idea of w-NAF is to pre-compute some zi coefficients like below to reduce the
 * costly point additions by using a non-binary ("signed") number system (values other than just
 * 0 and 1, but ranging from -2^(w-1)-1 to 2^(w-1)-1). This works best with the left-to-right
 * binary algorithm such that we just add zi * P when adding point P (we pre-compute all the
 * possible zi * P values because the x/y coordinates are known before the kernel starts):
 *
 *  // Example with window size w = 2 (i.e. mod 4 => & 3):
 *  // 173 => 1 0 -1 0 -1 0 -1 0 1 = 2^8 - 2^6 - 2^4 - 2^2 + 1
 *  int e = 0b10101101;   // 173
 *  int z[8 + 1] = { 0 }; // our zi/di, we need one extra slot to make the subtraction work
 *
 *  int i = 0;
 *
 *  while (e)
 *  {
 *    if (e & 1)
 *    {
 *      // for window size w = 3 it would be:
 *      // => 2^(w-0) = 2^3 = 8
 *      // => 2^(w-1) = 2^2 = 4
 *
 *      int bit; // = 2 - (e & 3) for w = 2
 *
 *      if ((e & 3) >= 2) // e % 4 == e & 3, use (e & 7) >= 4 for w = 3
 *        bit = (e & 3) - 4; // (e & 7) - 8 for w = 3
 *      else
 *        bit = e & 3; // e & 7 for w = 3
 *
 *      z[i] = bit;
 *      e   -= bit;
 *    }
 *
 *    e >>= 1; // e / 2
 *    i++;
 *  }
*/

#include "inc_ecc_secp256k1.h"

DECLSPEC u32 sub (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
  u32 c = 0; // carry/borrow

  #if defined IS_NV && HAS_SUB == 1 && HAS_SUBC == 1
  asm volatile
  (
    "sub.cc.u32   %0,  %9, %17;"
    "subc.cc.u32  %1, %10, %18;"
    "subc.cc.u32  %2, %11, %19;"
    "subc.cc.u32  %3, %12, %20;"
    "subc.cc.u32  %4, %13, %21;"
    "subc.cc.u32  %5, %14, %22;"
    "subc.cc.u32  %6, %15, %23;"
    "subc.cc.u32  %7, %16, %24;"
    "subc.u32     %8,   0,   0;"
    : "=r"(r[0]), "=r"(r[1]), "=r"(r[2]), "=r"(r[3]), "=r"(r[4]), "=r"(r[5]), "=r"(r[6]), "=r"(r[7]),
      "=r"(c)
    :  "r"(a[0]),  "r"(a[1]),  "r"(a[2]),  "r"(a[3]),  "r"(a[4]),  "r"(a[5]),  "r"(a[6]),  "r"(a[7]),
       "r"(b[0]),  "r"(b[1]),  "r"(b[2]),  "r"(b[3]),  "r"(b[4]),  "r"(b[5]),  "r"(b[6]),  "r"(b[7])
  );
  // HIP doesnt support these so we stick to OpenCL (aka IS_AMD) - is also faster without asm
  //#elif (defined IS_AMD || defined IS_HIP) && HAS_VSUB == 1 && HAS_VSUBB == 1
  #elif defined IS_AMD
  // Unrolled u64 borrow-chain: AMD compiler maps this to v_sub_co_u32/v_subb_co_u32.
  // sign-extend each 64-bit result to propagate borrow into the next word.
  {
    u64 t64;
    t64 = (u64)a[0] - (u64)b[0];           r[0] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[1] - (u64)b[1];          r[1] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[2] - (u64)b[2];          r[2] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[3] - (u64)b[3];          r[3] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[4] - (u64)b[4];          r[4] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[5] - (u64)b[5];          r[5] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[6] - (u64)b[6];          r[6] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    t64 += (u64)a[7] - (u64)b[7];          r[7] = (u32)t64; t64 = (u64)((long)t64 >> 32);
    c = (u32)(t64 & 1);
  }
  #else
  for (u32 i = 0; i < 8; i++)
  {
    const u32 diff = a[i] - b[i] - c;

    if (diff != a[i]) c = (diff > a[i]);

    r[i] = diff;
  }
  #endif

  return c;
}

DECLSPEC u32 add (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
  u32 c = 0; // carry/borrow

  #if defined IS_NV && HAS_ADD == 1 && HAS_ADDC == 1
  asm volatile
  (
    "add.cc.u32   %0,  %9, %17;"
    "addc.cc.u32  %1, %10, %18;"
    "addc.cc.u32  %2, %11, %19;"
    "addc.cc.u32  %3, %12, %20;"
    "addc.cc.u32  %4, %13, %21;"
    "addc.cc.u32  %5, %14, %22;"
    "addc.cc.u32  %6, %15, %23;"
    "addc.cc.u32  %7, %16, %24;"
    "addc.u32     %8,   0,   0;"
    : "=r"(r[0]), "=r"(r[1]), "=r"(r[2]), "=r"(r[3]), "=r"(r[4]), "=r"(r[5]), "=r"(r[6]), "=r"(r[7]),
      "=r"(c)
    :  "r"(a[0]),  "r"(a[1]),  "r"(a[2]),  "r"(a[3]),  "r"(a[4]),  "r"(a[5]),  "r"(a[6]),  "r"(a[7]),
       "r"(b[0]),  "r"(b[1]),  "r"(b[2]),  "r"(b[3]),  "r"(b[4]),  "r"(b[5]),  "r"(b[6]),  "r"(b[7])
  );
  // HIP doesnt support these so we stick to OpenCL (aka IS_AMD) - is also faster without asm
  //#elif (defined IS_AMD || defined IS_HIP) && HAS_VSUB == 1 && HAS_VSUBB == 1
  #elif defined IS_AMD
  // Unrolled u64 carry-chain: AMD compiler maps this to v_add_co_u32/v_addc_co_u32.
  {
    u64 t64;
    t64 = (u64)a[0] + (u64)b[0];           r[0] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[1] + (u64)b[1];          r[1] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[2] + (u64)b[2];          r[2] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[3] + (u64)b[3];          r[3] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[4] + (u64)b[4];          r[4] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[5] + (u64)b[5];          r[5] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[6] + (u64)b[6];          r[6] = (u32)t64; t64 >>= 32;
    t64 += (u64)a[7] + (u64)b[7];          r[7] = (u32)t64; t64 >>= 32;
    c = (u32)t64;
  }
  #else
  for (u32 i = 0; i < 8; i++)
  {
    const u32 t = a[i] + b[i] + c;

    if (t != a[i]) c = (t < a[i]);

    r[i] = t;
  }
  #endif

  return c;
}

DECLSPEC void sub_mod (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
  const u32 borrow = sub (r, a, b);

  // Branch-free conditional add of p: if borrow==1 (a < b), r += p to stay in [0, p-1].
  u32 p_arr[8];

  p_arr[0] = SECP256K1_P0;
  p_arr[1] = SECP256K1_P1;
  p_arr[2] = SECP256K1_P2;
  p_arr[3] = SECP256K1_P3;
  p_arr[4] = SECP256K1_P4;
  p_arr[5] = SECP256K1_P5;
  p_arr[6] = SECP256K1_P6;
  p_arr[7] = SECP256K1_P7;

  u32 tmp[8];

  add (tmp, r, p_arr);  // tmp = r + p  (correct result when borrow == 1)

  const u32 mask = -(borrow);  // 0xFFFFFFFF if borrow, 0 otherwise

  r[0] = (tmp[0] & mask) | (r[0] & ~mask);
  r[1] = (tmp[1] & mask) | (r[1] & ~mask);
  r[2] = (tmp[2] & mask) | (r[2] & ~mask);
  r[3] = (tmp[3] & mask) | (r[3] & ~mask);
  r[4] = (tmp[4] & mask) | (r[4] & ~mask);
  r[5] = (tmp[5] & mask) | (r[5] & ~mask);
  r[6] = (tmp[6] & mask) | (r[6] & ~mask);
  r[7] = (tmp[7] & mask) | (r[7] & ~mask);
}

DECLSPEC void add_mod (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
  const u32 c = add (r, a, b); // carry

  /*
   * Branch-free modular reduction: subtract p if r >= p (or c == 1, i.e. sum overflowed).
   * sub(tmp, r, p): borrow==0 means r >= p, borrow==1 means r < p.
   * Select tmp when: c==1 (definite overflow) OR borrow==0 (r >= p without overflow).
   */

  u32 p_arr[8];

  p_arr[0] = SECP256K1_P0;
  p_arr[1] = SECP256K1_P1;
  p_arr[2] = SECP256K1_P2;
  p_arr[3] = SECP256K1_P3;
  p_arr[4] = SECP256K1_P4;
  p_arr[5] = SECP256K1_P5;
  p_arr[6] = SECP256K1_P6;
  p_arr[7] = SECP256K1_P7;

  u32 tmp[8];

  const u32 borrow = sub (tmp, r, p_arr);  // tmp = r - p; borrow==1 means r < p

  // Use tmp (r - p) when c==1 (overflow) OR borrow==0 (r >= p)
  const u32 mask = -(c | (borrow ^ 1u));  // 0xFFFFFFFF if need to subtract, 0 otherwise

  r[0] = (tmp[0] & mask) | (r[0] & ~mask);
  r[1] = (tmp[1] & mask) | (r[1] & ~mask);
  r[2] = (tmp[2] & mask) | (r[2] & ~mask);
  r[3] = (tmp[3] & mask) | (r[3] & ~mask);
  r[4] = (tmp[4] & mask) | (r[4] & ~mask);
  r[5] = (tmp[5] & mask) | (r[5] & ~mask);
  r[6] = (tmp[6] & mask) | (r[6] & ~mask);
  r[7] = (tmp[7] & mask) | (r[7] & ~mask);
}

DECLSPEC void mod_512 (PRIVATE_AS u32 *n)
{
  // we need to perform a modulo operation with 512-bit % 256-bit (bignum modulo):
  // the modulus is the secp256k1 group order

  // ATTENTION: for this function the byte-order is reversed (most significant bytes
  // at the left)

  /*
    the general modulo by shift and substract code (a = a % b):

    x = b;

    t = a >> 1;

    while (x <= t) x <<= 1;

    while (a >= b)
    {
      if (a >= x) a -= x;

      x >>= 1;
    }

    return a; // remainder
  */

  u32 a[16];

  a[ 0] = n[ 0];
  a[ 1] = n[ 1];
  a[ 2] = n[ 2];
  a[ 3] = n[ 3];
  a[ 4] = n[ 4];
  a[ 5] = n[ 5];
  a[ 6] = n[ 6];
  a[ 7] = n[ 7];
  a[ 8] = n[ 8];
  a[ 9] = n[ 9];
  a[10] = n[10];
  a[11] = n[11];
  a[12] = n[12];
  a[13] = n[13];
  a[14] = n[14];
  a[15] = n[15];

  u32 b[16];

  b[ 0] = 0x00000000;
  b[ 1] = 0x00000000;
  b[ 2] = 0x00000000;
  b[ 3] = 0x00000000;
  b[ 4] = 0x00000000;
  b[ 5] = 0x00000000;
  b[ 6] = 0x00000000;
  b[ 7] = 0x00000000;
  b[ 8] = SECP256K1_N7;
  b[ 9] = SECP256K1_N6;
  b[10] = SECP256K1_N5;
  b[11] = SECP256K1_N4;
  b[12] = SECP256K1_N3;
  b[13] = SECP256K1_N2;
  b[14] = SECP256K1_N1;
  b[15] = SECP256K1_N0;

  /*
   * Start:
   */

  // x = b (but with a fast "shift" trick to avoid the while loop)

  u32 x[16];

  x[ 0] = b[ 8]; // this is a trick: we just put the group order's most significant bit all the
  x[ 1] = b[ 9]; // way to the top to avoid doing the initial: while (x <= t) x <<= 1
  x[ 2] = b[10];
  x[ 3] = b[11];
  x[ 4] = b[12];
  x[ 5] = b[13];
  x[ 6] = b[14];
  x[ 7] = b[15];
  x[ 8] = 0x00000000;
  x[ 9] = 0x00000000;
  x[10] = 0x00000000;
  x[11] = 0x00000000;
  x[12] = 0x00000000;
  x[13] = 0x00000000;
  x[14] = 0x00000000;
  x[15] = 0x00000000;

  // a >= b

  while (a[0] >= b[0])
  {
    u32 l00 = a[ 0] < b[ 0];
    u32 l01 = a[ 1] < b[ 1];
    u32 l02 = a[ 2] < b[ 2];
    u32 l03 = a[ 3] < b[ 3];
    u32 l04 = a[ 4] < b[ 4];
    u32 l05 = a[ 5] < b[ 5];
    u32 l06 = a[ 6] < b[ 6];
    u32 l07 = a[ 7] < b[ 7];
    u32 l08 = a[ 8] < b[ 8];
    u32 l09 = a[ 9] < b[ 9];
    u32 l10 = a[10] < b[10];
    u32 l11 = a[11] < b[11];
    u32 l12 = a[12] < b[12];
    u32 l13 = a[13] < b[13];
    u32 l14 = a[14] < b[14];
    u32 l15 = a[15] < b[15];

    u32 e00 = a[ 0] == b[ 0];
    u32 e01 = a[ 1] == b[ 1];
    u32 e02 = a[ 2] == b[ 2];
    u32 e03 = a[ 3] == b[ 3];
    u32 e04 = a[ 4] == b[ 4];
    u32 e05 = a[ 5] == b[ 5];
    u32 e06 = a[ 6] == b[ 6];
    u32 e07 = a[ 7] == b[ 7];
    u32 e08 = a[ 8] == b[ 8];
    u32 e09 = a[ 9] == b[ 9];
    u32 e10 = a[10] == b[10];
    u32 e11 = a[11] == b[11];
    u32 e12 = a[12] == b[12];
    u32 e13 = a[13] == b[13];
    u32 e14 = a[14] == b[14];

    if (l00) break;
    if (l01 && e00) break;
    if (l02 && e00 && e01) break;
    if (l03 && e00 && e01 && e02) break;
    if (l04 && e00 && e01 && e02 && e03) break;
    if (l05 && e00 && e01 && e02 && e03 && e04) break;
    if (l06 && e00 && e01 && e02 && e03 && e04 && e05) break;
    if (l07 && e00 && e01 && e02 && e03 && e04 && e05 && e06) break;
    if (l08 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07) break;
    if (l09 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08) break;
    if (l10 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09) break;
    if (l11 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10) break;
    if (l12 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11) break;
    if (l13 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12) break;
    if (l14 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12 && e13) break;
    if (l15 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12 && e13 && e14) break;

    // r = x (copy it to have the original values for the subtraction)

    u32 r[16];

    r[ 0] = x[ 0];
    r[ 1] = x[ 1];
    r[ 2] = x[ 2];
    r[ 3] = x[ 3];
    r[ 4] = x[ 4];
    r[ 5] = x[ 5];
    r[ 6] = x[ 6];
    r[ 7] = x[ 7];
    r[ 8] = x[ 8];
    r[ 9] = x[ 9];
    r[10] = x[10];
    r[11] = x[11];
    r[12] = x[12];
    r[13] = x[13];
    r[14] = x[14];
    r[15] = x[15];

    // x <<= 1

    x[15] = x[15] >> 1 | x[14] << 31;
    x[14] = x[14] >> 1 | x[13] << 31;
    x[13] = x[13] >> 1 | x[12] << 31;
    x[12] = x[12] >> 1 | x[11] << 31;
    x[11] = x[11] >> 1 | x[10] << 31;
    x[10] = x[10] >> 1 | x[ 9] << 31;
    x[ 9] = x[ 9] >> 1 | x[ 8] << 31;
    x[ 8] = x[ 8] >> 1 | x[ 7] << 31;
    x[ 7] = x[ 7] >> 1 | x[ 6] << 31;
    x[ 6] = x[ 6] >> 1 | x[ 5] << 31;
    x[ 5] = x[ 5] >> 1 | x[ 4] << 31;
    x[ 4] = x[ 4] >> 1 | x[ 3] << 31;
    x[ 3] = x[ 3] >> 1 | x[ 2] << 31;
    x[ 2] = x[ 2] >> 1 | x[ 1] << 31;
    x[ 1] = x[ 1] >> 1 | x[ 0] << 31;
    x[ 0] = x[ 0] >> 1;

    // if (a >= r) a -= r;

    l00 = a[ 0] < r[ 0];
    l01 = a[ 1] < r[ 1];
    l02 = a[ 2] < r[ 2];
    l03 = a[ 3] < r[ 3];
    l04 = a[ 4] < r[ 4];
    l05 = a[ 5] < r[ 5];
    l06 = a[ 6] < r[ 6];
    l07 = a[ 7] < r[ 7];
    l08 = a[ 8] < r[ 8];
    l09 = a[ 9] < r[ 9];
    l10 = a[10] < r[10];
    l11 = a[11] < r[11];
    l12 = a[12] < r[12];
    l13 = a[13] < r[13];
    l14 = a[14] < r[14];
    l15 = a[15] < r[15];

    e00 = a[ 0] == r[ 0];
    e01 = a[ 1] == r[ 1];
    e02 = a[ 2] == r[ 2];
    e03 = a[ 3] == r[ 3];
    e04 = a[ 4] == r[ 4];
    e05 = a[ 5] == r[ 5];
    e06 = a[ 6] == r[ 6];
    e07 = a[ 7] == r[ 7];
    e08 = a[ 8] == r[ 8];
    e09 = a[ 9] == r[ 9];
    e10 = a[10] == r[10];
    e11 = a[11] == r[11];
    e12 = a[12] == r[12];
    e13 = a[13] == r[13];
    e14 = a[14] == r[14];

    if (l00) continue;
    if (l01 && e00) continue;
    if (l02 && e00 && e01) continue;
    if (l03 && e00 && e01 && e02) continue;
    if (l04 && e00 && e01 && e02 && e03) continue;
    if (l05 && e00 && e01 && e02 && e03 && e04) continue;
    if (l06 && e00 && e01 && e02 && e03 && e04 && e05) continue;
    if (l07 && e00 && e01 && e02 && e03 && e04 && e05 && e06) continue;
    if (l08 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07) continue;
    if (l09 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08) continue;
    if (l10 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09) continue;
    if (l11 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10) continue;
    if (l12 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11) continue;
    if (l13 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12) continue;
    if (l14 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12 && e13) continue;
    if (l15 && e00 && e01 && e02 && e03 && e04 && e05 && e06 && e07 && e08 && e09 && e10 && e11 && e12 && e13 && e14) continue;

    // substract (a -= r):

    if ((r[ 0] | r[ 1] | r[ 2] | r[ 3] | r[ 4] | r[ 5] | r[ 6] | r[ 7] |
         r[ 8] | r[ 9] | r[10] | r[11] | r[12] | r[13] | r[14] | r[15]) == 0) break;

    r[ 0] = a[ 0] - r[ 0];
    r[ 1] = a[ 1] - r[ 1];
    r[ 2] = a[ 2] - r[ 2];
    r[ 3] = a[ 3] - r[ 3];
    r[ 4] = a[ 4] - r[ 4];
    r[ 5] = a[ 5] - r[ 5];
    r[ 6] = a[ 6] - r[ 6];
    r[ 7] = a[ 7] - r[ 7];
    r[ 8] = a[ 8] - r[ 8];
    r[ 9] = a[ 9] - r[ 9];
    r[10] = a[10] - r[10];
    r[11] = a[11] - r[11];
    r[12] = a[12] - r[12];
    r[13] = a[13] - r[13];
    r[14] = a[14] - r[14];
    r[15] = a[15] - r[15];

    // take care of the "borrow" (we can't do it the other way around 15...1 because r[x] is changed!)

    if (r[ 1] > a[ 1]) r[ 0]--;
    if (r[ 2] > a[ 2]) r[ 1]--;
    if (r[ 3] > a[ 3]) r[ 2]--;
    if (r[ 4] > a[ 4]) r[ 3]--;
    if (r[ 5] > a[ 5]) r[ 4]--;
    if (r[ 6] > a[ 6]) r[ 5]--;
    if (r[ 7] > a[ 7]) r[ 6]--;
    if (r[ 8] > a[ 8]) r[ 7]--;
    if (r[ 9] > a[ 9]) r[ 8]--;
    if (r[10] > a[10]) r[ 9]--;
    if (r[11] > a[11]) r[10]--;
    if (r[12] > a[12]) r[11]--;
    if (r[13] > a[13]) r[12]--;
    if (r[14] > a[14]) r[13]--;
    if (r[15] > a[15]) r[14]--;

    a[ 0] = r[ 0];
    a[ 1] = r[ 1];
    a[ 2] = r[ 2];
    a[ 3] = r[ 3];
    a[ 4] = r[ 4];
    a[ 5] = r[ 5];
    a[ 6] = r[ 6];
    a[ 7] = r[ 7];
    a[ 8] = r[ 8];
    a[ 9] = r[ 9];
    a[10] = r[10];
    a[11] = r[11];
    a[12] = r[12];
    a[13] = r[13];
    a[14] = r[14];
    a[15] = r[15];
  }

  n[ 0] = a[ 0];
  n[ 1] = a[ 1];
  n[ 2] = a[ 2];
  n[ 3] = a[ 3];
  n[ 4] = a[ 4];
  n[ 5] = a[ 5];
  n[ 6] = a[ 6];
  n[ 7] = a[ 7];
  n[ 8] = a[ 8];
  n[ 9] = a[ 9];
  n[10] = a[10];
  n[11] = a[11];
  n[12] = a[12];
  n[13] = a[13];
  n[14] = a[14];
  n[15] = a[15];
}

/*
 * Three-word accumulator helper for the manually unrolled 8×8 schoolbook
 * multiply.  Computes the 96-bit value (c, t1, t0) += a * b.
 *
 * The 64-bit sum _muladd_ss = _muladd_dd + _muladd_pp wraps on overflow;
 * the condition _muladd_ss < _muladd_pp detects that wrap and increments
 * the third word c by 1.  This replicates the accumulator loop body used
 * by micro-ecc / libsecp256k1.
 *
 * Internal temporaries use the _muladd_ prefix to avoid shadowing any
 * outer variable that might share a common short name.
 *
 * References:
 *   micro-ecc uECC.c (schoolbook multiply)
 *   CudaBrainSecp ptx_macros.cu (carry-chain pattern)
 *   lawliet89/gist (PTX mad.lo/mad.hi pattern, generalised here for u64)
 */
#define MULADD64(t0_, t1_, c_, a_, b_) do {                         \
  const u64 _muladd_pp = (u64)(a_) * (u64)(b_);                     \
  const u64 _muladd_dd = ((u64)(t1_) << 32) | (u64)(t0_);           \
  const u64 _muladd_ss = _muladd_dd + _muladd_pp;                    \
  (t0_) = (u32)(_muladd_ss);                                         \
  (t1_) = (u32)(_muladd_ss >> 32);                                   \
  (c_) += (u32)(_muladd_ss < _muladd_pp);                            \
} while (0)

/*
 * reduce_mod_p: Reduce a 256-bit value r (with up to 2-bit carry c representing
 * r + c*2^256) modulo secp256k1 prime p = 2^256 - 2^32 - 977.
 *
 * The carry c arises from the two-pass omega-reduction in mul_mod/sqr_mod.
 * Two branch-free conditional-subtract passes are sufficient for c in {0,1,2}.
 * Each pass: compute tmp = r - p; select tmp if (c > 0) OR (r >= p, i.e. borrow==0).
 * When borrow==1 and we selected tmp, it means we "consumed" one unit of c
 * (the wrap-around adds 2^256 which cancels one p subtraction).
 *
 * p is provided as p_arr[8] (caller-supplied to avoid redundant initialization
 * when the caller already has p loaded).
 */
DECLSPEC void reduce_mod_p (PRIVATE_AS u32 *r, u32 c, PRIVATE_AS const u32 *p_arr)
{
  u32 tmp[8];

  /* Pass 1: subtract p if V = r + c*2^256 >= p */
  {
    const u32 borrow = sub (tmp, r, p_arr);
    const u32 mask   = -(c | (borrow ^ 1u));

    r[0] = (tmp[0] & mask) | (r[0] & ~mask);
    r[1] = (tmp[1] & mask) | (r[1] & ~mask);
    r[2] = (tmp[2] & mask) | (r[2] & ~mask);
    r[3] = (tmp[3] & mask) | (r[3] & ~mask);
    r[4] = (tmp[4] & mask) | (r[4] & ~mask);
    r[5] = (tmp[5] & mask) | (r[5] & ~mask);
    r[6] = (tmp[6] & mask) | (r[6] & ~mask);
    r[7] = (tmp[7] & mask) | (r[7] & ~mask);

    /* If we wrapped (borrow==1) and subtracted (mask==-1), one c unit is consumed.
     * (mask >> 31) extracts the sign bit as 0xFFFFFFFF when mask==-1, else 0.
     * Multiplying by borrow ensures we only decrement when sub() actually borrowed.
     * The (c != 0u) guard prevents underflow when c is already 0. */
    c -= (mask >> 31) & borrow & (u32)(c != 0u);
  }

  /* Pass 2: subtract p again if still V >= p (handles c==2 and the c==1,r>=p case) */
  {
    const u32 borrow = sub (tmp, r, p_arr);
    const u32 mask   = -(c | (borrow ^ 1u));

    r[0] = (tmp[0] & mask) | (r[0] & ~mask);
    r[1] = (tmp[1] & mask) | (r[1] & ~mask);
    r[2] = (tmp[2] & mask) | (r[2] & ~mask);
    r[3] = (tmp[3] & mask) | (r[3] & ~mask);
    r[4] = (tmp[4] & mask) | (r[4] & ~mask);
    r[5] = (tmp[5] & mask) | (r[5] & ~mask);
    r[6] = (tmp[6] & mask) | (r[6] & ~mask);
    r[7] = (tmp[7] & mask) | (r[7] & ~mask);
  }
}

DECLSPEC void mul_mod (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
  u32 t[16] = { 0 }; // we need up to double the space (2 * 8)

  /*
   * 8×8 schoolbook multiplication — fully unrolled (no variable-bound loops).
   *
   * Each "column k" accumulates the sum of a[j]*b[k-j] for all valid j into
   * the three-word accumulator (c, t1, t0) using MULADD64.
   *
   * Sources: micro-ecc (schoolbook), CudaBrainSecp ptx_macros.cu (carry chain)
   */

  u32 t0 = 0;
  u32 t1 = 0;
  u32 c  = 0;

  /* Column 0 */
  MULADD64(t0, t1, c, a[0], b[0]);
  t[0] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 1 */
  MULADD64(t0, t1, c, a[0], b[1]);
  MULADD64(t0, t1, c, a[1], b[0]);
  t[1] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 2 */
  MULADD64(t0, t1, c, a[0], b[2]);
  MULADD64(t0, t1, c, a[1], b[1]);
  MULADD64(t0, t1, c, a[2], b[0]);
  t[2] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 3 */
  MULADD64(t0, t1, c, a[0], b[3]);
  MULADD64(t0, t1, c, a[1], b[2]);
  MULADD64(t0, t1, c, a[2], b[1]);
  MULADD64(t0, t1, c, a[3], b[0]);
  t[3] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 4 */
  MULADD64(t0, t1, c, a[0], b[4]);
  MULADD64(t0, t1, c, a[1], b[3]);
  MULADD64(t0, t1, c, a[2], b[2]);
  MULADD64(t0, t1, c, a[3], b[1]);
  MULADD64(t0, t1, c, a[4], b[0]);
  t[4] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 5 */
  MULADD64(t0, t1, c, a[0], b[5]);
  MULADD64(t0, t1, c, a[1], b[4]);
  MULADD64(t0, t1, c, a[2], b[3]);
  MULADD64(t0, t1, c, a[3], b[2]);
  MULADD64(t0, t1, c, a[4], b[1]);
  MULADD64(t0, t1, c, a[5], b[0]);
  t[5] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 6 */
  MULADD64(t0, t1, c, a[0], b[6]);
  MULADD64(t0, t1, c, a[1], b[5]);
  MULADD64(t0, t1, c, a[2], b[4]);
  MULADD64(t0, t1, c, a[3], b[3]);
  MULADD64(t0, t1, c, a[4], b[2]);
  MULADD64(t0, t1, c, a[5], b[1]);
  MULADD64(t0, t1, c, a[6], b[0]);
  t[6] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 7 */
  MULADD64(t0, t1, c, a[0], b[7]);
  MULADD64(t0, t1, c, a[1], b[6]);
  MULADD64(t0, t1, c, a[2], b[5]);
  MULADD64(t0, t1, c, a[3], b[4]);
  MULADD64(t0, t1, c, a[4], b[3]);
  MULADD64(t0, t1, c, a[5], b[2]);
  MULADD64(t0, t1, c, a[6], b[1]);
  MULADD64(t0, t1, c, a[7], b[0]);
  t[7] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 8 */
  MULADD64(t0, t1, c, a[1], b[7]);
  MULADD64(t0, t1, c, a[2], b[6]);
  MULADD64(t0, t1, c, a[3], b[5]);
  MULADD64(t0, t1, c, a[4], b[4]);
  MULADD64(t0, t1, c, a[5], b[3]);
  MULADD64(t0, t1, c, a[6], b[2]);
  MULADD64(t0, t1, c, a[7], b[1]);
  t[8] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 9 */
  MULADD64(t0, t1, c, a[2], b[7]);
  MULADD64(t0, t1, c, a[3], b[6]);
  MULADD64(t0, t1, c, a[4], b[5]);
  MULADD64(t0, t1, c, a[5], b[4]);
  MULADD64(t0, t1, c, a[6], b[3]);
  MULADD64(t0, t1, c, a[7], b[2]);
  t[9] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 10 */
  MULADD64(t0, t1, c, a[3], b[7]);
  MULADD64(t0, t1, c, a[4], b[6]);
  MULADD64(t0, t1, c, a[5], b[5]);
  MULADD64(t0, t1, c, a[6], b[4]);
  MULADD64(t0, t1, c, a[7], b[3]);
  t[10] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 11 */
  MULADD64(t0, t1, c, a[4], b[7]);
  MULADD64(t0, t1, c, a[5], b[6]);
  MULADD64(t0, t1, c, a[6], b[5]);
  MULADD64(t0, t1, c, a[7], b[4]);
  t[11] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 12 */
  MULADD64(t0, t1, c, a[5], b[7]);
  MULADD64(t0, t1, c, a[6], b[6]);
  MULADD64(t0, t1, c, a[7], b[5]);
  t[12] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 13 */
  MULADD64(t0, t1, c, a[6], b[7]);
  MULADD64(t0, t1, c, a[7], b[6]);
  t[13] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 14 */
  MULADD64(t0, t1, c, a[7], b[7]);
  t[14] = t0; t0 = t1; t1 = c; c = 0;

  t[15] = t0;



  /*
   * Now do the modulo operation:
   * (r = t % p)
   *
   * http://www.isys.uni-klu.ac.at/PDF/2001-0126-MT.pdf (p.354 or p.9 in that document)
   */

  u32 tmp[16] = { 0 };

  // c = 0;

  // Note: SECP256K1_P = 2^256 - 2^32 - 977 (0x03d1 = 977)
  // multiply t[8]...t[15] by omega:

  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 p = ((u64) 0x03d1) * t[j] + c;

    tmp[i] = (u32) p;

    c = p >> 32;
  }

  tmp[8] = c;

  c = add (tmp + 1, tmp + 1, t + 8); // modifies tmp[1]...tmp[8]

  tmp[9] = c;


  // r = t + tmp

  c = add (r, t, tmp);

  // multiply t[0]...t[7] by omega:

  u32 c2 = 0;

  // memset (t, 0, sizeof (t));

  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 p = ((u64) 0x3d1) * tmp[j] + c2;

    t[i] = (u32) p;

    c2 = p >> 32;
  }

  t[8] = c2;

  c2 = add (t + 1, t + 1, tmp + 8); // modifies t[1]...t[8]

  t[9] = c2;


  // r = r + t

  c2 = add (r, r, t);

  c += c2;

  t[0] = SECP256K1_P0;
  t[1] = SECP256K1_P1;
  t[2] = SECP256K1_P2;
  t[3] = SECP256K1_P3;
  t[4] = SECP256K1_P4;
  t[5] = SECP256K1_P5;
  t[6] = SECP256K1_P6;
  t[7] = SECP256K1_P7;

  reduce_mod_p (r, c, t);
}

/*
 * PTX-optimized field multiplication for NVIDIA GPUs.
 * Uses mad.lo.cc / madc.hi PTX instructions to accumulate the 256-bit schoolbook
 * product row by row, then applies the secp256k1 field reduction.
 *
 * Carry-chain note: each row processes a[i]*b[0..7] using a sequence of
 *   mad.lo.cc (low half, sets CC) / madc.hi (high half, consumes CC).
 * The carry out of the hi-half instruction for each intermediate column is
 * absorbed by the lo-half instruction of the next column (which also sets CC).
 * For the final column (b[7]) the carry from the lo-half is captured by
 * madc.hi into row_hi which is then added to t[ti+8].
 *
 * @param r out: r = (a * b) mod p
 * @param a in:  8 u32 words (little-endian)
 * @param b in:  8 u32 words (little-endian)
 */
DECLSPEC void mul_mod_ptx (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a, PRIVATE_AS const u32 *b)
{
#if defined IS_NV && HAS_ADD == 1 && HAS_ADDC == 1

  u32 t[16] = { 0 };

  /*
   * Row 0: a[0] * b[0..7] → t[0..8].
   *
   * For row 0, t[0..7] start as 0, so hi-half results can never overflow
   * a single u32 (a[0]*b[j].hi ≤ 2^32-2, CC ≤ 1, sum ≤ 2^32-1).
   * We therefore use madc.hi (no .cc) for the hi-half so that the CC
   * from the lo-half of the NEXT column is fresh.
   */
  asm volatile (
    "mul.lo.u32     %0, %9, %10;"
    "mul.hi.u32     %1, %9, %10;"
    "mad.lo.cc.u32  %1, %9, %11, %1;"
    "madc.hi.u32    %2, %9, %11,  0;"
    "mad.lo.cc.u32  %2, %9, %12, %2;"
    "madc.hi.u32    %3, %9, %12,  0;"
    "mad.lo.cc.u32  %3, %9, %13, %3;"
    "madc.hi.u32    %4, %9, %13,  0;"
    "mad.lo.cc.u32  %4, %9, %14, %4;"
    "madc.hi.u32    %5, %9, %14,  0;"
    "mad.lo.cc.u32  %5, %9, %15, %5;"
    "madc.hi.u32    %6, %9, %15,  0;"
    "mad.lo.cc.u32  %6, %9, %16, %6;"
    "madc.hi.u32    %7, %9, %16,  0;"
    "mad.lo.cc.u32  %7, %9, %17, %7;"
    "madc.hi.u32    %8, %9, %17,  0;"
    : "=r"(t[0]), "=r"(t[1]), "=r"(t[2]), "=r"(t[3]),
      "=r"(t[4]), "=r"(t[5]), "=r"(t[6]), "=r"(t[7]),
      "=r"(t[8])
    : "r"(a[0]),
      "r"(b[0]), "r"(b[1]), "r"(b[2]), "r"(b[3]),
      "r"(b[4]), "r"(b[5]), "r"(b[6]), "r"(b[7])
  );

  /*
   * Rows 1-7: accumulate a[i] * b[0..7] into t[i..i+7], overflow to row_hi.
   *
   * Pattern per column j (0 ≤ j ≤ 6):
   *   mad.lo.cc  t[ti+j] += a[ai]*b[j].lo           (sets CC)
   *   madc.hi.cc t[ti+j+1] += a[ai]*b[j].hi + CC    (sets CC for next lo)
   * Final column (j=7):
   *   mad.lo.cc  t[ti+7] += a[ai]*b[7].lo            (sets CC)
   *   madc.hi    row_hi   = a[ai]*b[7].hi + CC        (consumes CC)
   *
   * The carry out of each madc.hi.cc is consumed by the following mad.lo.cc
   * instruction (which resets CC). For columns 0..6 this is exact because
   * mad.lo.cc does NOT consume the carry from madc.hi.cc — it overwrites CC.
   * That intermediate carry is therefore propagated by the madc.hi.cc of
   * the SAME column into the next word.  The loop is self-consistent for
   * the 8-word accumulation; the only overflow that leaves the register file
   * is row_hi, which is added to t[ti+8] after the asm block.
   */
  u32 row_hi;

  #define MUL_MOD_PTX_ROW(ai, ti)                                \
    row_hi = 0;                                                   \
    asm volatile (                                                \
      "mad.lo.cc.u32   %0, %9, %10, %0;"                         \
      "madc.hi.cc.u32  %1, %9, %10, %1;"                         \
      "mad.lo.cc.u32   %1, %9, %11, %1;"                         \
      "madc.hi.cc.u32  %2, %9, %11, %2;"                         \
      "mad.lo.cc.u32   %2, %9, %12, %2;"                         \
      "madc.hi.cc.u32  %3, %9, %12, %3;"                         \
      "mad.lo.cc.u32   %3, %9, %13, %3;"                         \
      "madc.hi.cc.u32  %4, %9, %13, %4;"                         \
      "mad.lo.cc.u32   %4, %9, %14, %4;"                         \
      "madc.hi.cc.u32  %5, %9, %14, %5;"                         \
      "mad.lo.cc.u32   %5, %9, %15, %5;"                         \
      "madc.hi.cc.u32  %6, %9, %15, %6;"                         \
      "mad.lo.cc.u32   %6, %9, %16, %6;"                         \
      "madc.hi.cc.u32  %7, %9, %16, %7;"                         \
      "mad.lo.cc.u32   %7, %9, %17, %7;"                         \
      "madc.hi.u32     %8, %9, %17,  0;"                         \
      : "+r"(t[(ti)+0]), "+r"(t[(ti)+1]), "+r"(t[(ti)+2]),       \
        "+r"(t[(ti)+3]), "+r"(t[(ti)+4]), "+r"(t[(ti)+5]),       \
        "+r"(t[(ti)+6]), "+r"(t[(ti)+7]), "=r"(row_hi)           \
      : "r"(a[(ai)]),                                             \
        "r"(b[0]), "r"(b[1]), "r"(b[2]), "r"(b[3]),              \
        "r"(b[4]), "r"(b[5]), "r"(b[6]), "r"(b[7])               \
    );                                                            \
    t[(ti)+8] += row_hi

  MUL_MOD_PTX_ROW(1, 1);
  MUL_MOD_PTX_ROW(2, 2);
  MUL_MOD_PTX_ROW(3, 3);
  MUL_MOD_PTX_ROW(4, 4);
  MUL_MOD_PTX_ROW(5, 5);
  MUL_MOD_PTX_ROW(6, 6);
  MUL_MOD_PTX_ROW(7, 7);

  #undef MUL_MOD_PTX_ROW

  /*
   * secp256k1 field reduction: p = 2^256 - 2^32 - 977.
   * omega = 2^32 + 977 = 0x1_000003d1.
   * First pass: reduce t[8..15] by multiplying by omega and folding back.
   *
   * Note: this identical reduction block is also used by sqr_mod_ptx via
   *       mul_mod_ptx(r, a, a).
   */
  u32 tmp[16] = { 0 };
  u32 c = 0, c2 = 0;

  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 pp = ((u64) 0x03d1) * t[j] + c;
    tmp[i] = (u32) pp;
    c = (u32) (pp >> 32);
  }
  tmp[8] = c;
  c  = add (tmp + 1, tmp + 1, t + 8);
  tmp[9] = c;
  c  = add (r, t, tmp);

  /* Second pass: correct any remaining overflow. */
  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 pp = ((u64) 0x3d1) * tmp[j] + c2;
    t[i] = (u32) pp;
    c2 = (u32) (pp >> 32);
  }
  t[8] = c2;
  c2 = add (t + 1, t + 1, tmp + 8);
  t[9] = c2;
  c2 = add (r, r, t);
  c += c2;

  t[0] = SECP256K1_P0; t[1] = SECP256K1_P1;
  t[2] = SECP256K1_P2; t[3] = SECP256K1_P3;
  t[4] = SECP256K1_P4; t[5] = SECP256K1_P5;
  t[6] = SECP256K1_P6; t[7] = SECP256K1_P7;

  for (u32 i = c; i > 0; i--) sub (r, r, t);
  for (int i = 7; i >= 0; i--)
  {
    if (r[i] < t[i]) break;
    if (r[i] > t[i]) { sub (r, r, t); break; }
  }

#else
  mul_mod (r, a, b);
#endif
}

/*
 * PTX-optimized field squaring for NVIDIA GPUs (sm_80+).
 * Delegates to mul_mod_ptx(r, a, a) which uses the full 8×8 PTX carry-chain.
 * On AMD/HIP/generic the fallback uses the standard squaring loop.
 *
 * Using mul_mod_ptx with a == b is correct (no aliasing hazard because
 * mul_mod_ptx copies inputs into asm registers before writing any output).
 *
 * @param r out: r = a² mod p  (8 u32 words, little-endian)
 * @param a in:  8 u32 words
 */
DECLSPEC void sqr_mod_ptx (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a)
{
#if defined IS_NV && HAS_ADD == 1 && HAS_ADDC == 1
  mul_mod_ptx (r, a, a);
#else
  sqr_mod (r, a);
#endif
}

DECLSPEC void sqr_mod (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a)
{
#if defined IS_NV && HAS_ADD == 1 && HAS_ADDC == 1
  /*
   * On NVIDIA: reuse the PTX 8×8 multiply with a == b.
   * mul_mod_ptx handles a-equals-b correctly (inputs are copied into PTX
   * register operands before any output is written).
   */
  mul_mod_ptx (r, a, a);
  return;
#endif
  u32 t[16] = { 0 }; // we need up to double the space (2 * 8)

  /*
   * AMD/generic path: squaring with symmetry optimisation.
   * Off-diagonal products a[j]*a[i-j] (j ≠ i-j) appear twice; diagonal
   * terms appear once.  The #pragma unroll hints help the AMD compiler
   * emit straight-line code similar to a manual schoolbook unroll.
   */

  u32 t0 = 0;
  u32 t1 = 0;
  u32 c  = 0;

  /*
   * Fully-unrolled squaring using symmetry: a[i]*a[j] for i<j appears twice
   * (handled by SQR_ADD2), diagonal terms a[i]*a[i] appear once (SQR_ADD).
   *
   * Macro conventions:
   *   SQR_ADD(t0,t1,c, ai,aj)  — accumulate 1 * (ai*aj)
   *   SQR_ADD2(t0,t1,c, ai,aj) — accumulate 2 * (ai*aj) with overflow tracking
   */

  /* Column 0: a[0]^2 */
  { u64 _p = (u64)a[0] * a[0]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[0] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 1: 2*a[0]*a[1] */
  { u64 _p = (u64)a[0] * a[1]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[1] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 2: 2*a[0]*a[2] + a[1]^2 */
  { u64 _p = (u64)a[0] * a[2]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[1]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[2] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 3: 2*(a[0]*a[3] + a[1]*a[2]) */
  { u64 _p = (u64)a[0] * a[3]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[2]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[3] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 4: 2*(a[0]*a[4] + a[1]*a[3]) + a[2]^2 */
  { u64 _p = (u64)a[0] * a[4]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[3]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[2] * a[2]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[4] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 5: 2*(a[0]*a[5] + a[1]*a[4] + a[2]*a[3]) */
  { u64 _p = (u64)a[0] * a[5]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[4]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[2] * a[3]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[5] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 6: 2*(a[0]*a[6] + a[1]*a[5] + a[2]*a[4]) + a[3]^2 */
  { u64 _p = (u64)a[0] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[5]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[2] * a[4]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[3] * a[3]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[6] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 7: 2*(a[0]*a[7] + a[1]*a[6] + a[2]*a[5] + a[3]*a[4]) */
  { u64 _p = (u64)a[0] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[1] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[2] * a[5]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[3] * a[4]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[7] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 8: 2*(a[1]*a[7] + a[2]*a[6] + a[3]*a[5]) + a[4]^2 */
  { u64 _p = (u64)a[1] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[2] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[3] * a[5]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[4] * a[4]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[8] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 9: 2*(a[2]*a[7] + a[3]*a[6] + a[4]*a[5]) */
  { u64 _p = (u64)a[2] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[3] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[4] * a[5]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[9] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 10: 2*(a[3]*a[7] + a[4]*a[6]) + a[5]^2 */
  { u64 _p = (u64)a[3] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[4] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[5] * a[5]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[10] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 11: 2*(a[4]*a[7] + a[5]*a[6]) */
  { u64 _p = (u64)a[4] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[5] * a[6]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[11] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 12: 2*a[5]*a[7] + a[6]^2 */
  { u64 _p = (u64)a[5] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  { u64 _p = (u64)a[6] * a[6]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[12] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 13: 2*a[6]*a[7] */
  { u64 _p = (u64)a[6] * a[7]; u64 _p2 = _p + _p; u32 _ov = (u32)(_p2 < _p);
    u64 _d = ((u64)t1 << 32) | t0; _d += _p2;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p2) + _ov; }
  t[13] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 14: a[7]^2 */
  { u64 _p = (u64)a[7] * a[7]; u64 _d = ((u64)t1 << 32) | t0; _d += _p;
    t0 = (u32)_d; t1 = (u32)(_d >> 32); c += (u32)(_d < _p); }
  t[14] = t0; t0 = t1; t1 = c; c = 0;

  /* Column 15 */
  t[15] = t0;



  /*
   * Now do the modulo operation:
   * (r = t % p)
   *
   * This is IDENTICAL to mul_mod's reduction (lines 664-743)
   * http://www.isys.uni-klu.ac.at/PDF/2001-0126-MT.pdf (p.354 or p.9 in that document)
   */

  u32 tmp[16] = { 0 };

  // c = 0;

  // Note: SECP256K1_P = 2^256 - 2^32 - 977 (0x03d1 = 977)
  // multiply t[8]...t[15] by omega:

  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 p = ((u64) 0x03d1) * t[j] + c;

    tmp[i] = (u32) p;

    c = p >> 32;
  }

  tmp[8] = c;

  c = add (tmp + 1, tmp + 1, t + 8); // modifies tmp[1]...tmp[8]

  tmp[9] = c;


  // r = t + tmp

  c = add (r, t, tmp);

  // multiply t[0]...t[7] by omega:

  u32 c2 = 0;

  // memset (t, 0, sizeof (t));

  for (u32 i = 0, j = 8; i < 8; i++, j++)
  {
    u64 p = ((u64) 0x3d1) * tmp[j] + c2;

    t[i] = (u32) p;

    c2 = p >> 32;
  }

  t[8] = c2;

  c2 = add (t + 1, t + 1, tmp + 8); // modifies t[1]...t[8]

  t[9] = c2;


  // r = r + t

  c2 = add (r, r, t);

  c += c2;

  t[0] = SECP256K1_P0;
  t[1] = SECP256K1_P1;
  t[2] = SECP256K1_P2;
  t[3] = SECP256K1_P3;
  t[4] = SECP256K1_P4;
  t[5] = SECP256K1_P5;
  t[6] = SECP256K1_P6;
  t[7] = SECP256K1_P7;

  reduce_mod_p (r, c, t);
}

DECLSPEC void sqrt_mod (PRIVATE_AS u32 *r)
{
  // Fermat's Little Theorem
  // secp256k1: y^2 = x^3 + 7 % p
  // y ^ (p - 1) = 1
  // y ^ (p - 1) = (y^2) ^ ((p - 1) / 2) = 1 => y^2 = (y^2) ^ (((p - 1) / 2) + 1)
  // => y = (y^2) ^ ((((p - 1) / 2) + 1) / 2)
  // y = (y^2) ^ (((p - 1 + 2) / 2) / 2) = (y^2) ^ ((p + 1) / 4)

  // y1 = (x^3 + 7) ^ ((p + 1) / 4)
  // y2 = p - y1 (or y2 = y1 * -1 % p)

  u32 s[8];

  s[0] = SECP256K1_P0 + 1; //  because of (p + 1) / 4 or use add (s, s, 1)
  s[1] = SECP256K1_P1;
  s[2] = SECP256K1_P2;
  s[3] = SECP256K1_P3;
  s[4] = SECP256K1_P4;
  s[5] = SECP256K1_P5;
  s[6] = SECP256K1_P6;
  s[7] = SECP256K1_P7;

  u32 t[8] = { 0 };

  t[0] = 1;

  for (u32 i = 255; i > 1; i--) // we just skip the last 2 multiplications (=> exp / 4)
  {
    sqr_mod (t, t); // r * r

    u32 idx  = i >> 5;
    u32 mask = 1 << (i & 0x1f);

    if (s[idx] & mask)
    {
      mul_mod (t, t, r); // t * r
    }
  }

  r[0] = t[0];
  r[1] = t[1];
  r[2] = t[2];
  r[3] = t[3];
  r[4] = t[4];
  r[5] = t[5];
  r[6] = t[6];
  r[7] = t[7];
}

// (inverse (a, p) * a) % p == 1 (or think of a * a^-1 = a / a = 1)

DECLSPEC void inv_mod (PRIVATE_AS u32 *a)
{
  /*
   * Fermat's Little Theorem: a^(p-1) ≡ 1 (mod p) for prime p
   * Therefore: a^(-1) ≡ a^(p-2) (mod p)
   * 
   * For secp256k1, p-2 = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D
   * 
   * This implementation uses a simple square-and-multiply algorithm with NO branches
   * in the main loop, making it GPU-friendly. All iterations are executed regardless
   * of bit values, using conditional multiplication.
   *
   * Total: 255 squarings + up to 255 multiplications (worst case)
   * Actual: 255 squarings + ~128 multiplications (average)
   */

  // p-2 in 32-bit limbs (secp256k1 prime minus 2)
  // p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  // p-2 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D
  u32 exp[8];
  exp[0] = SECP256K1_P0 - 2; // 0xFFFFFC2F - 2 = 0xFFFFFC2D (no underflow)
  exp[1] = SECP256K1_P1;      // 0xFFFFFFFE  
  exp[2] = SECP256K1_P2;      // 0xFFFFFFFF
  exp[3] = SECP256K1_P3;      // 0xFFFFFFFF
  exp[4] = SECP256K1_P4;      // 0xFFFFFFFF
  exp[5] = SECP256K1_P5;      // 0xFFFFFFFF
  exp[6] = SECP256K1_P6;      // 0xFFFFFFFF
  exp[7] = SECP256K1_P7;      // 0xFFFFFFFF

  // Save input
  u32 base[8];
  base[0] = a[0];
  base[1] = a[1];
  base[2] = a[2];
  base[3] = a[3];
  base[4] = a[4];
  base[5] = a[5];
  base[6] = a[6];
  base[7] = a[7];

  // Result accumulator, initialized to 1
  u32 result[8] = { 0 };
  result[0] = 1;

  // Temporary for multiplication result
  u32 temp[8];

  // Process all 256 bits (from bit 0 to bit 255)
  // Using constant-time approach: always compute, conditionally use result
  #pragma unroll 16
  for (u32 bit_idx = 0; bit_idx < 256; bit_idx++)
  {
    // Check if this bit is set in the exponent
    u32 limb_idx = bit_idx >> 5;        // bit_idx / 32
    u32 bit_pos = bit_idx & 0x1f;       // bit_idx % 32
    u32 bit_set = (exp[limb_idx] >> bit_pos) & 1;  // bit_set ∈ {0, 1}

    // Conditionally multiply: if bit is set, multiply result by base
    // We always do the multiplication, but only update result if bit_set == 1
    mul_mod(temp, result, base);
    
    // Constant-time conditional move: result = bit_set ? temp : result
    // Using bitwise mask to avoid branches (GPU-friendly)
    // Since bit_set ∈ {0, 1}, negation produces 0x00000000 or 0xFFFFFFFF
    u32 mask = -(bit_set);  // Two's complement: -0 = 0x00000000, -1 = 0xFFFFFFFF
    result[0] = (temp[0] & mask) | (result[0] & ~mask);
    result[1] = (temp[1] & mask) | (result[1] & ~mask);
    result[2] = (temp[2] & mask) | (result[2] & ~mask);
    result[3] = (temp[3] & mask) | (result[3] & ~mask);
    result[4] = (temp[4] & mask) | (result[4] & ~mask);
    result[5] = (temp[5] & mask) | (result[5] & ~mask);
    result[6] = (temp[6] & mask) | (result[6] & ~mask);
    result[7] = (temp[7] & mask) | (result[7] & ~mask);

    // Square base for next iteration (except on last iteration, but we do it anyway for constant time)
    sqr_mod(base, base);
  }

  // Copy result back to input
  a[0] = result[0];
  a[1] = result[1];
  a[2] = result[2];
  a[3] = result[3];
  a[4] = result[4];
  a[5] = result[5];
  a[6] = result[6];
  a[7] = result[7];
}

/*
  // everything from the formulas below of course MOD the prime:

  // we use this formula:

  X = (3/2 * x^2)^2 - 2 * x * y^2
  Y = (3/2 * x^2) * (x * y^2 - X) - y^4
  Z = y * z

  this is identical to the more frequently used form:

  X = (3 * x^2)^2 - 8 * x * y^2
  Y =  3 * x^2 * (4 * x * y^2 - X) - 8 * y^4
  Z =  2 * y * z
*/

DECLSPEC void point_double (PRIVATE_AS u32 *x, PRIVATE_AS u32 *y, PRIVATE_AS u32 *z)
{
  // How often does this really happen? it should "almost" never happen (but would be safer)

  /*
  if ((y[0] | y[1] | y[2] | y[3] | y[4] | y[5] | y[6] | y[7]) == 0)
  {
    x[0] = 0;
    x[1] = 0;
    x[2] = 0;
    x[3] = 0;
    x[4] = 0;
    x[5] = 0;
    x[6] = 0;
    x[7] = 0;

    y[0] = 0;
    y[1] = 0;
    y[2] = 0;
    y[3] = 0;
    y[4] = 0;
    y[5] = 0;
    y[6] = 0;
    y[7] = 0;

    z[0] = 0;
    z[1] = 0;
    z[2] = 0;
    z[3] = 0;
    z[4] = 0;
    z[5] = 0;
    z[6] = 0;
    z[7] = 0;

    return;
  }
  */

  u32 t1[8];

  t1[0] = x[0];
  t1[1] = x[1];
  t1[2] = x[2];
  t1[3] = x[3];
  t1[4] = x[4];
  t1[5] = x[5];
  t1[6] = x[6];
  t1[7] = x[7];

  u32 t2[8];

  t2[0] = y[0];
  t2[1] = y[1];
  t2[2] = y[2];
  t2[3] = y[3];
  t2[4] = y[4];
  t2[5] = y[5];
  t2[6] = y[6];
  t2[7] = y[7];

  u32 t3[8];

  t3[0] = z[0];
  t3[1] = z[1];
  t3[2] = z[2];
  t3[3] = z[3];
  t3[4] = z[4];
  t3[5] = z[5];
  t3[6] = z[6];
  t3[7] = z[7];

  u32 t4[8];
  u32 t5[8];
  u32 t6[8];

  sqr_mod (t4, t1); // t4 = x^2

  sqr_mod (t5, t2); // t5 = y^2

  mul_mod (t1, t1, t5); // t1 = x*y^2

  sqr_mod (t5, t5); // t5 = t5^2 = y^4

  // here the z^2 and z^4 is not needed for a = 0

  mul_mod (t3, t2, t3); // t3 = x * z

  add_mod (t2, t4, t4); // t2 = 2 * t4 = 2 * x^2
  add_mod (t4, t4, t2); // t4 = 3 * t4 = 3 * x^2

  // a * z^4 = 0 * 1^4 = 0

  // don't discard the least significant bit it's important too!

  u32 c = 0;

  if (t4[0] & 1)
  {
    u32 t[8];

    t[0] = SECP256K1_P0;
    t[1] = SECP256K1_P1;
    t[2] = SECP256K1_P2;
    t[3] = SECP256K1_P3;
    t[4] = SECP256K1_P4;
    t[5] = SECP256K1_P5;
    t[6] = SECP256K1_P6;
    t[7] = SECP256K1_P7;

    c = add (t4, t4, t); // t4 + SECP256K1_P
  }

  // right shift (t4 / 2):

  t4[0] = t4[0] >> 1 | t4[1] << 31;
  t4[1] = t4[1] >> 1 | t4[2] << 31;
  t4[2] = t4[2] >> 1 | t4[3] << 31;
  t4[3] = t4[3] >> 1 | t4[4] << 31;
  t4[4] = t4[4] >> 1 | t4[5] << 31;
  t4[5] = t4[5] >> 1 | t4[6] << 31;
  t4[6] = t4[6] >> 1 | t4[7] << 31;
  t4[7] = t4[7] >> 1 | c     << 31;

  sqr_mod (t6, t4); // t6 = t4^2 = (3/2 * x^2)^2

  add_mod (t2, t1, t1); // t2 = 2 * t1

  sub_mod (t6, t6, t2); // t6 = t6 - t2
  sub_mod (t1, t1, t6); // t1 = t1 - t6

  mul_mod (t4, t4, t1); // t4 = t4 * t1

  sub_mod (t1, t4, t5); // t1 = t4 - t5

  // => x = t6, y = t1, z = t3:

  x[0] = t6[0];
  x[1] = t6[1];
  x[2] = t6[2];
  x[3] = t6[3];
  x[4] = t6[4];
  x[5] = t6[5];
  x[6] = t6[6];
  x[7] = t6[7];

  y[0] = t1[0];
  y[1] = t1[1];
  y[2] = t1[2];
  y[3] = t1[3];
  y[4] = t1[4];
  y[5] = t1[5];
  y[6] = t1[6];
  y[7] = t1[7];

  z[0] = t3[0];
  z[1] = t3[1];
  z[2] = t3[2];
  z[3] = t3[3];
  z[4] = t3[4];
  z[5] = t3[5];
  z[6] = t3[6];
  z[7] = t3[7];
}

/*
 * madd-2004-hmv:
 * (from https://www.hyperelliptic.org/EFD/g1p/auto-shortw-jacobian-0.html)
 * t1 = z1^2
 * t2 = t1*z1
 * t1 = t1*x2
 * t2 = t2*y2
 * t1 = t1-x1
 * t2 = t2-y1
 * z3 = z1*t1
 * t3 = t1^2
 * t4 = t3*t1
 * t3 = t3*x1
 * t1 = 2*t3
 * x3 = t2^2
 * x3 = x3-t1
 * x3 = x3-t4
 * t3 = t3-x3
 * t3 = t3*t2
 * t4 = t4*y1
 * y3 = t3-t4
 */

DECLSPEC void point_add (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS u32 *z1, PRIVATE_AS const u32 *x2, PRIVATE_AS const u32 *y2) // z2 = 1
{
  // How often does this really happen? it should "almost" never happen (but would be safer)

  /*
  if ((y2[0] | y2[1] | y2[2] | y2[3] | y2[4] | y2[5] | y2[6] | y2[7]) == 0) return;

  if ((y1[0] | y1[1] | y1[2] | y1[3] | y1[4] | y1[5] | y1[6] | y1[7]) == 0)
  {
    x1[0] = x2[0];
    x1[1] = x2[1];
    x1[2] = x2[2];
    x1[3] = x2[3];
    x1[4] = x2[4];
    x1[5] = x2[5];
    x1[6] = x2[6];
    x1[7] = x2[7];

    y1[0] = y2[0];
    y1[1] = y2[1];
    y1[2] = y2[2];
    y1[3] = y2[3];
    y1[4] = y2[4];
    y1[5] = y2[5];
    y1[6] = y2[6];
    y1[7] = y2[7];

    z1[0] = z2[0];
    z1[1] = z2[1];
    z1[2] = z2[2];
    z1[3] = z2[3];
    z1[4] = z2[4];
    z1[5] = z2[5];
    z1[6] = z2[6];
    z1[7] = z2[7];

    return;
  }
  */

  // if x1 == x2 and y2 == y2 and z2 == z2 we need to double instead?

  // x1/y1/z1:

  u32 t1[8];

  t1[0] = x1[0];
  t1[1] = x1[1];
  t1[2] = x1[2];
  t1[3] = x1[3];
  t1[4] = x1[4];
  t1[5] = x1[5];
  t1[6] = x1[6];
  t1[7] = x1[7];

  u32 t2[8];

  t2[0] = y1[0];
  t2[1] = y1[1];
  t2[2] = y1[2];
  t2[3] = y1[3];
  t2[4] = y1[4];
  t2[5] = y1[5];
  t2[6] = y1[6];
  t2[7] = y1[7];

  u32 t3[8];

  t3[0] = z1[0];
  t3[1] = z1[1];
  t3[2] = z1[2];
  t3[3] = z1[3];
  t3[4] = z1[4];
  t3[5] = z1[5];
  t3[6] = z1[6];
  t3[7] = z1[7];

  // x2/y2:

  u32 t4[8];

  t4[0] = x2[0];
  t4[1] = x2[1];
  t4[2] = x2[2];
  t4[3] = x2[3];
  t4[4] = x2[4];
  t4[5] = x2[5];
  t4[6] = x2[6];
  t4[7] = x2[7];

  u32 t5[8];

  t5[0] = y2[0];
  t5[1] = y2[1];
  t5[2] = y2[2];
  t5[3] = y2[3];
  t5[4] = y2[4];
  t5[5] = y2[5];
  t5[6] = y2[6];
  t5[7] = y2[7];

  u32 t6[8];
  u32 t7[8];
  u32 t8[8];
  u32 t9[8];

  sqr_mod (t6, t3); // t6 = t3^2

  mul_mod (t7, t6, t3); // t7 = t6*t3
  mul_mod (t6, t6, t4); // t6 = t6*t4
  mul_mod (t7, t7, t5); // t7 = t7*t5

  sub_mod (t6, t6, t1); // t6 = t6-t1
  sub_mod (t7, t7, t2); // t7 = t7-t2

  mul_mod (t8, t3, t6); // t8 = t3*t6
  sqr_mod (t4, t6); // t4 = t6^2
  mul_mod (t9, t4, t6); // t9 = t4*t6
  mul_mod (t4, t4, t1); // t4 = t4*t1

  // left shift (t4 * 2):

  t6[7] = t4[7] << 1 | t4[6] >> 31;
  t6[6] = t4[6] << 1 | t4[5] >> 31;
  t6[5] = t4[5] << 1 | t4[4] >> 31;
  t6[4] = t4[4] << 1 | t4[3] >> 31;
  t6[3] = t4[3] << 1 | t4[2] >> 31;
  t6[2] = t4[2] << 1 | t4[1] >> 31;
  t6[1] = t4[1] << 1 | t4[0] >> 31;
  t6[0] = t4[0] << 1;

  // don't discard the most significant bit, it's important too!

  if (t4[7] & 0x80000000)
  {
    // use most significant bit and perform mod P, since we have: t4 * 2 % P

    u32 a[8] = { 0 };

    a[1] = 1;
    a[0] = 0x000003d1; // omega (see: mul_mod ())

    add (t6, t6, a);
  }

  sqr_mod (t5, t7); // t5 = t7*t7

  sub_mod (t5, t5, t6); // t5 = t5-t6
  sub_mod (t5, t5, t9); // t5 = t5-t9
  sub_mod (t4, t4, t5); // t4 = t4-t5

  mul_mod (t4, t4, t7); // t4 = t4*t7
  mul_mod (t9, t9, t2); // t9 = t9*t2

  sub_mod (t9, t4, t9); // t9 = t4-t9

  x1[0] = t5[0];
  x1[1] = t5[1];
  x1[2] = t5[2];
  x1[3] = t5[3];
  x1[4] = t5[4];
  x1[5] = t5[5];
  x1[6] = t5[6];
  x1[7] = t5[7];

  y1[0] = t9[0];
  y1[1] = t9[1];
  y1[2] = t9[2];
  y1[3] = t9[3];
  y1[4] = t9[4];
  y1[5] = t9[5];
  y1[6] = t9[6];
  y1[7] = t9[7];

  z1[0] = t8[0];
  z1[1] = t8[1];
  z1[2] = t8[2];
  z1[3] = t8[3];
  z1[4] = t8[4];
  z1[5] = t8[5];
  z1[6] = t8[6];
  z1[7] = t8[7];
}

DECLSPEC void point_get_coords (PRIVATE_AS secp256k1_t *r, PRIVATE_AS const u32 *x, PRIVATE_AS const u32 *y)
{
  /*
    pre-compute 1/-1, 3/-3, 5/-5, 7/-7 times P (x, y)
    for wNAF with window size 4 (max/min: +/- 2^3-1): -7, -5, -3, -1, 1, 3, 5, 7

    +x1 ( 0)
    +y1 ( 8)
    -y1 (16)

    +x3 (24)
    +y3 (32)
    -y3 (40)

    +x5 (48)
    +y5 (56)
    -y5 (64)

    +x7 (72)
    +y7 (80)
    -y7 (88)
   */

  // note: we use jacobian forms with (x, y, z) for computation, but affine
  // (or just converted to z = 1) for storage

  // 1:

  r->xy[ 0] = x[0];
  r->xy[ 1] = x[1];
  r->xy[ 2] = x[2];
  r->xy[ 3] = x[3];
  r->xy[ 4] = x[4];
  r->xy[ 5] = x[5];
  r->xy[ 6] = x[6];
  r->xy[ 7] = x[7];

  r->xy[ 8] = y[0];
  r->xy[ 9] = y[1];
  r->xy[10] = y[2];
  r->xy[11] = y[3];
  r->xy[12] = y[4];
  r->xy[13] = y[5];
  r->xy[14] = y[6];
  r->xy[15] = y[7];

  // -1:

  u32 p[8];

  p[0] = SECP256K1_P0;
  p[1] = SECP256K1_P1;
  p[2] = SECP256K1_P2;
  p[3] = SECP256K1_P3;
  p[4] = SECP256K1_P4;
  p[5] = SECP256K1_P5;
  p[6] = SECP256K1_P6;
  p[7] = SECP256K1_P7;

  u32 neg[8];

  neg[0] = y[0];
  neg[1] = y[1];
  neg[2] = y[2];
  neg[3] = y[3];
  neg[4] = y[4];
  neg[5] = y[5];
  neg[6] = y[6];
  neg[7] = y[7];

  sub_mod (neg, p, neg); // -y = p - y

  r->xy[16] = neg[0];
  r->xy[17] = neg[1];
  r->xy[18] = neg[2];
  r->xy[19] = neg[3];
  r->xy[20] = neg[4];
  r->xy[21] = neg[5];
  r->xy[22] = neg[6];
  r->xy[23] = neg[7];


  // copy of 1:

  u32 tx[8];

  tx[0] = x[0];
  tx[1] = x[1];
  tx[2] = x[2];
  tx[3] = x[3];
  tx[4] = x[4];
  tx[5] = x[5];
  tx[6] = x[6];
  tx[7] = x[7];

  u32 ty[8];

  ty[0] = y[0];
  ty[1] = y[1];
  ty[2] = y[2];
  ty[3] = y[3];
  ty[4] = y[4];
  ty[5] = y[5];
  ty[6] = y[6];
  ty[7] = y[7];

  u32 rx[8];

  rx[0] = x[0];
  rx[1] = x[1];
  rx[2] = x[2];
  rx[3] = x[3];
  rx[4] = x[4];
  rx[5] = x[5];
  rx[6] = x[6];
  rx[7] = x[7];

  u32 ry[8];

  ry[0] = y[0];
  ry[1] = y[1];
  ry[2] = y[2];
  ry[3] = y[3];
  ry[4] = y[4];
  ry[5] = y[5];
  ry[6] = y[6];
  ry[7] = y[7];

  u32 rz[8] = { 0 };

  rz[0] = 1;


  // 3:

  point_double (rx, ry, rz);          // 2
  point_add    (rx, ry, rz, tx, ty);  // 3

  // Save Z coordinate for batch inversion later
  u32 rz3[8];
  rz3[0] = rz[0];
  rz3[1] = rz[1];
  rz3[2] = rz[2];
  rz3[3] = rz[3];
  rz3[4] = rz[4];
  rz3[5] = rz[5];
  rz3[6] = rz[6];
  rz3[7] = rz[7];

  // Save X and Y coordinates for 3G
  u32 rx3[8];
  rx3[0] = rx[0];
  rx3[1] = rx[1];
  rx3[2] = rx[2];
  rx3[3] = rx[3];
  rx3[4] = rx[4];
  rx3[5] = rx[5];
  rx3[6] = rx[6];
  rx3[7] = rx[7];

  u32 ry3[8];
  ry3[0] = ry[0];
  ry3[1] = ry[1];
  ry3[2] = ry[2];
  ry3[3] = ry[3];
  ry3[4] = ry[4];
  ry3[5] = ry[5];
  ry3[6] = ry[6];
  ry3[7] = ry[7];


  // 5:

  rz[0] = 1; // actually we could take advantage of rz being 1 too (alternative point_add ()),
  rz[1] = 0; // but it is not important because this is performed only once per "hash"
  rz[2] = 0;
  rz[3] = 0;
  rz[4] = 0;
  rz[5] = 0;
  rz[6] = 0;
  rz[7] = 0;

  point_add (rx, ry, rz, tx, ty); // 4
  point_add (rx, ry, rz, tx, ty); // 5

  // Save Z coordinate for batch inversion later
  u32 rz5[8];
  rz5[0] = rz[0];
  rz5[1] = rz[1];
  rz5[2] = rz[2];
  rz5[3] = rz[3];
  rz5[4] = rz[4];
  rz5[5] = rz[5];
  rz5[6] = rz[6];
  rz5[7] = rz[7];

  // Save X and Y coordinates for 5G
  u32 rx5[8];
  rx5[0] = rx[0];
  rx5[1] = rx[1];
  rx5[2] = rx[2];
  rx5[3] = rx[3];
  rx5[4] = rx[4];
  rx5[5] = rx[5];
  rx5[6] = rx[6];
  rx5[7] = rx[7];

  u32 ry5[8];
  ry5[0] = ry[0];
  ry5[1] = ry[1];
  ry5[2] = ry[2];
  ry5[3] = ry[3];
  ry5[4] = ry[4];
  ry5[5] = ry[5];
  ry5[6] = ry[6];
  ry5[7] = ry[7];


  // 7:

  rz[0] = 1;
  rz[1] = 0;
  rz[2] = 0;
  rz[3] = 0;
  rz[4] = 0;
  rz[5] = 0;
  rz[6] = 0;
  rz[7] = 0;

  point_add (rx, ry, rz, tx, ty); // 6
  point_add (rx, ry, rz, tx, ty); // 7

  // Save Z coordinate for batch inversion later (rz7 = rz)
  u32 rz7[8];
  rz7[0] = rz[0];
  rz7[1] = rz[1];
  rz7[2] = rz[2];
  rz7[3] = rz[3];
  rz7[4] = rz[4];
  rz7[5] = rz[5];
  rz7[6] = rz[6];
  rz7[7] = rz[7];

  // Save X and Y coordinates for 7G (rx and ry already contain these)
  u32 rx7[8];
  rx7[0] = rx[0];
  rx7[1] = rx[1];
  rx7[2] = rx[2];
  rx7[3] = rx[3];
  rx7[4] = rx[4];
  rx7[5] = rx[5];
  rx7[6] = rx[6];
  rx7[7] = rx[7];

  u32 ry7[8];
  ry7[0] = ry[0];
  ry7[1] = ry[1];
  ry7[2] = ry[2];
  ry7[3] = ry[3];
  ry7[4] = ry[4];
  ry7[5] = ry[5];
  ry7[6] = ry[6];
  ry7[7] = ry[7];

  // Montgomery's trick: batch inversion of rz3, rz5, rz7
  // Compute: rz3_rz5_prod = rz3 * rz5
  u32 rz3_rz5_prod[8];
  mul_mod (rz3_rz5_prod, rz3, rz5);

  // Compute: combined_prod = rz3 * rz5 * rz7
  u32 combined_prod[8];
  mul_mod (combined_prod, rz3_rz5_prod, rz7);

  // Compute: 1 / (rz3 * rz5 * rz7) - the only expensive inversion (inverted in place)
  inv_mod (combined_prod);

  // Now compute individual inverses using the inverted product:
  // rz7_inv = combined_prod * rz3_rz5_prod
  u32 rz7_inv[8];
  mul_mod (rz7_inv, combined_prod, rz3_rz5_prod);

  // partial_inv = combined_prod * rz7 = 1 / (rz3 * rz5)
  u32 partial_inv[8];
  mul_mod (partial_inv, combined_prod, rz7);

  // rz5_inv = partial_inv * rz3
  u32 rz5_inv[8];
  mul_mod (rz5_inv, partial_inv, rz3);

  // rz3_inv = partial_inv * rz5
  u32 rz3_inv[8];
  mul_mod (rz3_inv, partial_inv, rz5);

  // Now convert each point from Jacobian to affine coordinates
  // For 3G:
  mul_mod (neg, rz3_inv, rz3_inv); // neg is temporary variable (z_inv^2)
  mul_mod (rx3, rx3, neg);          // x_affine = x * z_inv^2

  mul_mod (rz3_inv, neg, rz3_inv);  // rz3_inv = z_inv^3
  mul_mod (ry3, ry3, rz3_inv);      // y_affine = y * z_inv^3

  r->xy[24] = rx3[0];
  r->xy[25] = rx3[1];
  r->xy[26] = rx3[2];
  r->xy[27] = rx3[3];
  r->xy[28] = rx3[4];
  r->xy[29] = rx3[5];
  r->xy[30] = rx3[6];
  r->xy[31] = rx3[7];

  r->xy[32] = ry3[0];
  r->xy[33] = ry3[1];
  r->xy[34] = ry3[2];
  r->xy[35] = ry3[3];
  r->xy[36] = ry3[4];
  r->xy[37] = ry3[5];
  r->xy[38] = ry3[6];
  r->xy[39] = ry3[7];

  // -3:

  neg[0] = ry3[0];
  neg[1] = ry3[1];
  neg[2] = ry3[2];
  neg[3] = ry3[3];
  neg[4] = ry3[4];
  neg[5] = ry3[5];
  neg[6] = ry3[6];
  neg[7] = ry3[7];

  sub_mod (neg, p, neg);

  r->xy[40] = neg[0];
  r->xy[41] = neg[1];
  r->xy[42] = neg[2];
  r->xy[43] = neg[3];
  r->xy[44] = neg[4];
  r->xy[45] = neg[5];
  r->xy[46] = neg[6];
  r->xy[47] = neg[7];


  // For 5G:
  mul_mod (neg, rz5_inv, rz5_inv); // neg is temporary variable (z_inv^2)
  mul_mod (rx5, rx5, neg);          // x_affine = x * z_inv^2

  mul_mod (rz5_inv, neg, rz5_inv);  // rz5_inv = z_inv^3
  mul_mod (ry5, ry5, rz5_inv);      // y_affine = y * z_inv^3

  r->xy[48] = rx5[0];
  r->xy[49] = rx5[1];
  r->xy[50] = rx5[2];
  r->xy[51] = rx5[3];
  r->xy[52] = rx5[4];
  r->xy[53] = rx5[5];
  r->xy[54] = rx5[6];
  r->xy[55] = rx5[7];

  r->xy[56] = ry5[0];
  r->xy[57] = ry5[1];
  r->xy[58] = ry5[2];
  r->xy[59] = ry5[3];
  r->xy[60] = ry5[4];
  r->xy[61] = ry5[5];
  r->xy[62] = ry5[6];
  r->xy[63] = ry5[7];

  // -5:

  neg[0] = ry5[0];
  neg[1] = ry5[1];
  neg[2] = ry5[2];
  neg[3] = ry5[3];
  neg[4] = ry5[4];
  neg[5] = ry5[5];
  neg[6] = ry5[6];
  neg[7] = ry5[7];

  sub_mod (neg, p, neg);

  r->xy[64] = neg[0];
  r->xy[65] = neg[1];
  r->xy[66] = neg[2];
  r->xy[67] = neg[3];
  r->xy[68] = neg[4];
  r->xy[69] = neg[5];
  r->xy[70] = neg[6];
  r->xy[71] = neg[7];


  // For 7G:
  mul_mod (neg, rz7_inv, rz7_inv); // neg is temporary variable (z_inv^2)
  mul_mod (rx7, rx7, neg);          // x_affine = x * z_inv^2

  mul_mod (rz7_inv, neg, rz7_inv);  // rz7_inv = z_inv^3
  mul_mod (ry7, ry7, rz7_inv);      // y_affine = y * z_inv^3

  r->xy[72] = rx7[0];
  r->xy[73] = rx7[1];
  r->xy[74] = rx7[2];
  r->xy[75] = rx7[3];
  r->xy[76] = rx7[4];
  r->xy[77] = rx7[5];
  r->xy[78] = rx7[6];
  r->xy[79] = rx7[7];

  r->xy[80] = ry7[0];
  r->xy[81] = ry7[1];
  r->xy[82] = ry7[2];
  r->xy[83] = ry7[3];
  r->xy[84] = ry7[4];
  r->xy[85] = ry7[5];
  r->xy[86] = ry7[6];
  r->xy[87] = ry7[7];

  // -7:

  neg[0] = ry7[0];
  neg[1] = ry7[1];
  neg[2] = ry7[2];
  neg[3] = ry7[3];
  neg[4] = ry7[4];
  neg[5] = ry7[5];
  neg[6] = ry7[6];
  neg[7] = ry7[7];

  sub_mod (neg, p, neg);

  r->xy[88] = neg[0];
  r->xy[89] = neg[1];
  r->xy[90] = neg[2];
  r->xy[91] = neg[3];
  r->xy[92] = neg[4];
  r->xy[93] = neg[5];
  r->xy[94] = neg[6];
  r->xy[95] = neg[7];
}

/*
 * Convert the tweak/scalar k to w-NAF (window size is 4).
 * @param naf out: w-NAF form of the tweak/scalar, a pointer to an u32 array with a size of 33.
 * @param k in: tweak/scalar which should be converted, a pointer to an u32 array with a size of 8.
 * @return Returns the loop start index.
 */
DECLSPEC int convert_to_window_naf (PRIVATE_AS u32 *naf, PRIVATE_AS const u32 *k)
{
  int loop_start = 0;

  u32 n[9];

  n[0] =    0; // we need this extra slot sometimes for the subtraction to work
  n[1] = k[7];
  n[2] = k[6];
  n[3] = k[5];
  n[4] = k[4];
  n[5] = k[3];
  n[6] = k[2];
  n[7] = k[1];
  n[8] = k[0];

  for (int i = 0; i <= 256; i++)
  {
    if (n[8] & 1)
    {
      // for window size w = 4:
      // => 2^(w-0) = 2^4 = 16 (0x10)
      // => 2^(w-1) = 2^3 =  8 (0x08)

      int diff = n[8] & 0x0f; // n % 2^w == n & (2^w - 1)

      // convert diff to val according to this table:
      //  1 -> +1 -> 1
      //  3 -> +3 -> 3
      //  5 -> +5 -> 5
      //  7 -> +7 -> 7
      //  9 -> -7 -> 8
      // 11 -> -5 -> 6
      // 13 -> -3 -> 4
      // 15 -> -1 -> 2

      int val = diff;

      if (diff >= 0x08)
      {
        diff -= 0x10;

        val = 0x11 - val;
      }

      naf[i >> 3] |= val << ((i & 7) << 2);

      u32 t = n[8]; // t is the (temporary) old/unmodified value

      n[8] -= diff;

      // we need to take care of the carry/borrow:

      u32 k = 8;

      if (diff > 0)
      {
        while (n[k] > t) // overflow propagation
        {
          if (k == 0) break; // needed ?

          k--;

          t = n[k];

          n[k]--;
        }
      }
      else // if (diff < 0)
      {
        while (t > n[k]) // overflow propagation
        {
          if (k == 0) break;

          k--;

          t = n[k];

          n[k]++;
        }
      }

      // update start:

      loop_start = i;
    }

    // n = n / 2:

    n[8] = n[8] >> 1 | n[7] << 31;
    n[7] = n[7] >> 1 | n[6] << 31;
    n[6] = n[6] >> 1 | n[5] << 31;
    n[5] = n[5] >> 1 | n[4] << 31;
    n[4] = n[4] >> 1 | n[3] << 31;
    n[3] = n[3] >> 1 | n[2] << 31;
    n[2] = n[2] >> 1 | n[1] << 31;
    n[1] = n[1] >> 1 | n[0] << 31;
    n[0] = n[0] >> 1;
  }

  return loop_start;
}

/*
 * @param x1 out: x coordinate, a pointer to an u32 array with a size of 8.
 * @param y1 out: y coordinate, a pointer to an u32 array with a size of 8.
 * @param k in: tweak/scalar which should be converted, a pointer to an u32 array with a size of 8.
 * @param tmps in: a basepoint for the multiplication.
 * @return Returns the x coordinate with a leading parity/sign (for odd/even y), it is named a compressed coordinate.
 */
DECLSPEC void point_mul_xy (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_t *tmps)
{
  u32 naf[SECP256K1_NAF_SIZE] = { 0 };

  int loop_start = convert_to_window_naf (naf, k);

  // first set:

  const u32 multiplier = (naf[loop_start >> 3] >> ((loop_start & 7) << 2)) & 0x0f; // or use u8 ?

  const u32 odd = multiplier & 1;

  const u32 x_pos = ((multiplier - 1 + odd) >> 1) * 24;
  const u32 y_pos = odd ? (x_pos + 8) : (x_pos + 16);


  x1[0] = tmps->xy[x_pos + 0];
  x1[1] = tmps->xy[x_pos + 1];
  x1[2] = tmps->xy[x_pos + 2];
  x1[3] = tmps->xy[x_pos + 3];
  x1[4] = tmps->xy[x_pos + 4];
  x1[5] = tmps->xy[x_pos + 5];
  x1[6] = tmps->xy[x_pos + 6];
  x1[7] = tmps->xy[x_pos + 7];

  y1[0] = tmps->xy[y_pos + 0];
  y1[1] = tmps->xy[y_pos + 1];
  y1[2] = tmps->xy[y_pos + 2];
  y1[3] = tmps->xy[y_pos + 3];
  y1[4] = tmps->xy[y_pos + 4];
  y1[5] = tmps->xy[y_pos + 5];
  y1[6] = tmps->xy[y_pos + 6];
  y1[7] = tmps->xy[y_pos + 7];

  u32 z1[8] = { 0 };

  z1[0] = 1;

  /*
   * Start:
   */

  // main loop (left-to-right binary algorithm):

  for (int pos = loop_start - 1; pos >= 0; pos--) // -1 because we've set/add the point already
  {
    // always double:

    point_double (x1, y1, z1);

    // add only if needed:

    const u32 multiplier = (naf[pos >> 3] >> ((pos & 7) << 2)) & 0x0f;

    if (multiplier)
    {
      /*
        m ->  y | y = ((m - (m & 1)) / 2) * 24
        ----------------------------------
        1 ->  0 | 1/2 * 24 = 0
        2 -> 16
        3 -> 24 | 3/2 * 24 = 24
        4 -> 40
        5 -> 48 | 5/2 * 24 = 2*24
        6 -> 64
        7 -> 72 | 7/2 * 24 = 3*24
        8 -> 88
       */

      const u32 odd = multiplier & 1;

      const u32 x_pos = ((multiplier - 1 + odd) >> 1) * 24;
      const u32 y_pos = odd ? (x_pos + 8) : (x_pos + 16);

      u32 x2[8];

      x2[0] = tmps->xy[x_pos + 0];
      x2[1] = tmps->xy[x_pos + 1];
      x2[2] = tmps->xy[x_pos + 2];
      x2[3] = tmps->xy[x_pos + 3];
      x2[4] = tmps->xy[x_pos + 4];
      x2[5] = tmps->xy[x_pos + 5];
      x2[6] = tmps->xy[x_pos + 6];
      x2[7] = tmps->xy[x_pos + 7];

      u32 y2[8];

      y2[0] = tmps->xy[y_pos + 0];
      y2[1] = tmps->xy[y_pos + 1];
      y2[2] = tmps->xy[y_pos + 2];
      y2[3] = tmps->xy[y_pos + 3];
      y2[4] = tmps->xy[y_pos + 4];
      y2[5] = tmps->xy[y_pos + 5];
      y2[6] = tmps->xy[y_pos + 6];
      y2[7] = tmps->xy[y_pos + 7];

      // (x1, y1, z1) + multiplier * (x, y, z) = (x1, y1, z1) + (x2, y2, z2)

      point_add (x1, y1, z1, x2, y2);

      // optimization (there can't be any adds after an add for w-1 times):
      // (but it seems to be faster without this manipulation of "pos")

      //for (u32 i = 0; i < 3; i++)
      //{
      //  if (pos == 0) break;
      //  point_double (x1, y1, z1);
      //  pos--;
      //}
    }
  }


  /*
   * Get the corresponding affine coordinates x/y:
   *
   * Note:
   * x1_affine = x1_jacobian / z1^2 = x1_jacobian * z1_inv^2
   * y1_affine = y1_jacobian / z1^2 = y1_jacobian * z1_inv^2
   *
   */

  inv_mod (z1);

  u32 z2[8];

  mul_mod (z2, z1, z1); // z1^2
  mul_mod (x1, x1, z2); // x1_affine

  mul_mod (z1, z2, z1); // z1^3
  mul_mod (y1, y1, z1); // y1_affine

  // return values are already in x1 and y1
}

/*
 * @param r out: x coordinate with leading parity/sign (for odd/even y), a pointer to an u32 array with a size of 9.
 * @param k in: tweak/scalar which should be converted, a pointer to an u32 array with a size of 8.
 * @param tmps in: a basepoint for the multiplication.
 * @return Returns the x coordinate with a leading parity/sign (for odd/even y), it is named a compressed coordinate.
 */
DECLSPEC void point_mul (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_t *tmps)
{
  u32 x[8];
  u32 y[8];

  point_mul_xy (x, y, k, tmps);

  /*
   * output:
   */

  // shift by 1 byte (8 bits) to make room and add the parity/sign (for odd/even y):

  r[8] =               (x[0] << 24);
  r[7] = (x[0] >> 8) | (x[1] << 24);
  r[6] = (x[1] >> 8) | (x[2] << 24);
  r[5] = (x[2] >> 8) | (x[3] << 24);
  r[4] = (x[3] >> 8) | (x[4] << 24);
  r[3] = (x[4] >> 8) | (x[5] << 24);
  r[2] = (x[5] >> 8) | (x[6] << 24);
  r[1] = (x[6] >> 8) | (x[7] << 24);
  r[0] = (x[7] >> 8);

  const u32 type = 0x02 | (y[0] & 1); // (note: 0b10 | 0b01 = 0x03)

  r[0] = r[0] | type << 24; // 0x02 or 0x03
}

/*
 * Transform a x coordinate and separate parity to secp256k1_t.
 * @param r out: x and y coordinates.
 * @param x in: x coordinate which should be converted, a pointer to an u32 array with a size of 8.
 * @param first_byte in: The parity of the y coordinate, a u32.
 * @return Returns 0 if successful, returns 1 if x is greater than the basepoint.
 */
DECLSPEC u32 transform_public (PRIVATE_AS secp256k1_t *r, PRIVATE_AS const u32 *x, const u32 first_byte)
{
  u32 p[8];

  p[0] = SECP256K1_P0;
  p[1] = SECP256K1_P1;
  p[2] = SECP256K1_P2;
  p[3] = SECP256K1_P3;
  p[4] = SECP256K1_P4;
  p[5] = SECP256K1_P5;
  p[6] = SECP256K1_P6;
  p[7] = SECP256K1_P7;

  // x must be smaller than p (because of y ^ 2 = x ^ 3 % p)

  for (int i = 7; i >= 0; i--)
  {
    if (x[i] < p[i]) break;
    if (x[i] > p[i]) return 1;
  }


  // get y^2 = x^3 + 7:

  u32 b[8] = { 0 };

  b[0] = SECP256K1_B;

  u32 y[8];

  mul_mod (y, x, x);
  mul_mod (y, y, x);
  add_mod (y, y, b);

  // get y = sqrt (y^2):

  sqrt_mod (y);

  // check if it's of the correct parity that we want (odd/even):

  if ((first_byte & 1) != (y[0] & 1))
  {
    // y2 = p - y1 (or y2 = y1 * -1)

    sub_mod (y, p, y);
  }

  // get xy:

  point_get_coords (r, x, y);

  return 0;
}

/*
 * Parse a x coordinate with leading parity to secp256k1_t.
 * @param r out: x and y coordinates.
 * @param k in: x coordinate which should be converted with leading parity, a pointer to an u32 array with a size of 9.
 * @return Returns 0 if successful, returns 1 if x is greater than the basepoint or the parity has an unexpected value.
 */
DECLSPEC u32 parse_public (PRIVATE_AS secp256k1_t *r, PRIVATE_AS const u32 *k)
{
  // verify:

  const u32 first_byte = k[0] & 0xff;

  if ((first_byte != '\x02') && (first_byte != '\x03'))
  {
    return 1;
  }

  // load k into x without the first byte:

  u32 x[8];

  x[0] = (k[7] & 0xff00) << 16 | (k[7] & 0xff0000) | (k[7] & 0xff000000) >> 16 | (k[8] & 0xff);
  x[1] = (k[6] & 0xff00) << 16 | (k[6] & 0xff0000) | (k[6] & 0xff000000) >> 16 | (k[7] & 0xff);
  x[2] = (k[5] & 0xff00) << 16 | (k[5] & 0xff0000) | (k[5] & 0xff000000) >> 16 | (k[6] & 0xff);
  x[3] = (k[4] & 0xff00) << 16 | (k[4] & 0xff0000) | (k[4] & 0xff000000) >> 16 | (k[5] & 0xff);
  x[4] = (k[3] & 0xff00) << 16 | (k[3] & 0xff0000) | (k[3] & 0xff000000) >> 16 | (k[4] & 0xff);
  x[5] = (k[2] & 0xff00) << 16 | (k[2] & 0xff0000) | (k[2] & 0xff000000) >> 16 | (k[3] & 0xff);
  x[6] = (k[1] & 0xff00) << 16 | (k[1] & 0xff0000) | (k[1] & 0xff000000) >> 16 | (k[2] & 0xff);
  x[7] = (k[0] & 0xff00) << 16 | (k[0] & 0xff0000) | (k[0] & 0xff000000) >> 16 | (k[1] & 0xff);

  return transform_public (r, x, first_byte);
}


/*
 * Set precomputed values of the basepoint g to a secp256k1 structure.
 * @param r out: x and y coordinates. pre-computed points: (x1,y1,-y1),(x3,y3,-y3),(x5,y5,-y5),(x7,y7,-y7)
 */

/*
 * GLV endomorphism scalar decomposition for secp256k1.
 *
 * Decomposes scalar k (256-bit) into two ~128-bit scalars k1, k2 such that:
 *   k ≡ k1 + k2 * LAMBDA  (mod n)
 *
 * Uses Babai nearest-plane rounding with precomputed constants:
 *   g1 = round(a1 * 2^384 / n)
 *   g2 = round(|b1| * 2^384 / n)
 *
 * Algorithm:
 *   c1 = (k * g1) >> 384  (Babai coefficient ~128 bits)
 *   c2 = (k * g2) >> 384  (Babai coefficient ~128 bits)
 *   k1 = k - c1*a1 - c2*a2  (signed, |k1| <= sqrt(2n) ~= 2^129)
 *   k2 = c1*|b1| - c2*a1    (signed, |k2| <= sqrt(2n) ~= 2^128)
 *
 * Output: k1 and k2 are 6-element u32 arrays:
 *   [0..4] = 160-bit magnitude (little-endian), lower ~129 bits used
 *   [5]    = sign flag: 0 = positive, 1 = negative
 *
 * Reference: Guide to ECC, Algorithm 3.74; secp256k1 library.
 */
DECLSPEC void glv_decompose (PRIVATE_AS const u32 *k, PRIVATE_AS u32 *k1, PRIVATE_AS u32 *k2)
{
  /*
   * Step 1: Compute c1 = (k * g1) >> 384 and c2 = (k * g2) >> 384.
   * We need the top 4 u32 words (bits [511:384]) of the 512-bit products.
   * Full 256x256->512 schoolbook multiplication, keeping only words [12:15].
   */

  const u32 g1[8] = {
    SECP256K1_GLV_G1_0, SECP256K1_GLV_G1_1, SECP256K1_GLV_G1_2, SECP256K1_GLV_G1_3,
    SECP256K1_GLV_G1_4, SECP256K1_GLV_G1_5, SECP256K1_GLV_G1_6, SECP256K1_GLV_G1_7
  };
  const u32 g2[8] = {
    SECP256K1_GLV_G2_0, SECP256K1_GLV_G2_1, SECP256K1_GLV_G2_2, SECP256K1_GLV_G2_3,
    SECP256K1_GLV_G2_4, SECP256K1_GLV_G2_5, SECP256K1_GLV_G2_6, SECP256K1_GLV_G2_7
  };

  u32 c1[4];
  u32 c2[4];

  // Compute (k * g1) >> 384 via full 512-bit schoolbook multiply, extract words [12:15]
  {
    u32 t[16] = { 0 };
    u32 t0 = 0, t1 = 0, cv = 0;

    for (u32 i = 0; i < 8; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) k[j] * g1[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p;
        t0  = (u32) d;
        t1  = (u32) (d >> 32);
        cv += (u32) (d < p);
      }
      t[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 8; i < 15; i++)
    {
      for (u32 j = i - 7; j < 8; j++)
      {
        u64 p = (u64) k[j] * g1[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p;
        t0  = (u32) d;
        t1  = (u32) (d >> 32);
        cv += (u32) (d < p);
      }
      t[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    t[15] = t0;
    c1[0] = t[12]; c1[1] = t[13]; c1[2] = t[14]; c1[3] = t[15];
  }

  // Compute (k * g2) >> 384 via full 512-bit schoolbook multiply, extract words [12:15]
  {
    u32 t[16] = { 0 };
    u32 t0 = 0, t1 = 0, cv = 0;

    for (u32 i = 0; i < 8; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) k[j] * g2[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p;
        t0  = (u32) d;
        t1  = (u32) (d >> 32);
        cv += (u32) (d < p);
      }
      t[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 8; i < 15; i++)
    {
      for (u32 j = i - 7; j < 8; j++)
      {
        u64 p = (u64) k[j] * g2[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p;
        t0  = (u32) d;
        t1  = (u32) (d >> 32);
        cv += (u32) (d < p);
      }
      t[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    t[15] = t0;
    c2[0] = t[12]; c2[1] = t[13]; c2[2] = t[14]; c2[3] = t[15];
  }

  /*
   * Step 2: Compute k1 = k - c1*a1 - c2*a2 (signed integer, ~129 bits).
   *
   * a1 is 128-bit (4 words), a2 is 129-bit (5 words, a2[4]=1 only).
   * c1 and c2 are each ~128-bit (4 words).
   *
   * c1*a1 is at most 256-bit (8 words).
   * c2*a2 = c2*a2[0..3] + c2*(2^128), also at most 257-bit (9 words).
   *
   * The result |k1| <= sqrt(2n) < 2^129.
   */

  const u32 a1c[4] = {
    SECP256K1_GLV_A1_0, SECP256K1_GLV_A1_1, SECP256K1_GLV_A1_2, SECP256K1_GLV_A1_3
  };
  const u32 b1c[4] = {
    SECP256K1_GLV_B1_0, SECP256K1_GLV_B1_1, SECP256K1_GLV_B1_2, SECP256K1_GLV_B1_3
  };
  const u32 a2c[4] = {
    SECP256K1_GLV_A2_0, SECP256K1_GLV_A2_1, SECP256K1_GLV_A2_2, SECP256K1_GLV_A2_3
  };
  // a2[4] = SECP256K1_GLV_A2_4 = 1 (129th bit of a2), handled separately

  // Compute c1 * a1 (4x4 words -> 8 words product)
  u32 c1a1[8] = { 0 };
  {
    u32 t0 = 0, t1 = 0, cv = 0;
    for (u32 i = 0; i < 4; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) c1[j] * a1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c1a1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 4; i < 7; i++)
    {
      for (u32 j = i - 3; j < 4; j++)
      {
        u64 p = (u64) c1[j] * a1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c1a1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    c1a1[7] = t0;
  }

  // Compute c2 * a2 (4x4 words -> 8 words for lower part, plus c2 shifted by 4 words)
  u32 c2a2[9] = { 0 };
  {
    u32 t0 = 0, t1 = 0, cv = 0;
    for (u32 i = 0; i < 4; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) c2[j] * a2c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c2a2[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 4; i < 7; i++)
    {
      for (u32 j = i - 3; j < 4; j++)
      {
        u64 p = (u64) c2[j] * a2c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c2a2[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    c2a2[7] = t0;
    // Add c2 << 128 (a2[4] == 1 means a2 has a 129th bit set)
    u32 carry9 = 0;
    for (u32 i = 0; i < 4; i++)
    {
      u64 s = (u64) c2a2[i + 4] + c2[i] + carry9;
      c2a2[i + 4] = (u32) s;
      carry9      = (u32) (s >> 32);
    }
    c2a2[8] = carry9;
  }

  // r[0..8] = k[0..7] - c1a1[0..7] - c2a2[0..8]  (signed 288-bit result)
  u32 r[9] = { 0 };
  for (u32 i = 0; i < 8; i++) r[i] = k[i];

  // Subtract c1a1 (8 words)
  u32 borrow = 0;
  for (u32 i = 0; i < 8; i++)
  {
    u64 d  = (u64) r[i] - c1a1[i] - borrow;
    r[i]   = (u32) d;
    borrow = (u32) (d >> 63) & 1;
  }
  // propagate borrow into r[8] (which is 0 initially)
  r[8] = (u32) (0 - borrow);

  // Subtract c2a2 (9 words)
  borrow = 0;
  for (u32 i = 0; i < 9; i++)
  {
    u64 d  = (u64) r[i] - c2a2[i] - borrow;
    r[i]   = (u32) d;
    borrow = (u32) (d >> 63) & 1;
  }
  // If borrow==1 here, the true result is negative (it wrapped around 288 bits)

  // Determine sign: negative if borrow==1 or if bit 287 (r[8] bit 31) is set
  u32 sign_k1 = borrow | (r[8] >> 31);

  if (sign_k1)
  {
    // Negate: compute two's complement of r[0..8]
    u32 neg_carry = 1;
    for (u32 i = 0; i < 9; i++)
    {
      u64 s = (u64) (~r[i]) + neg_carry;
      r[i]      = (u32) s;
      neg_carry = (u32) (s >> 32);
    }
  }

  k1[0] = r[0]; k1[1] = r[1]; k1[2] = r[2]; k1[3] = r[3]; k1[4] = r[4];
  k1[5] = sign_k1;

  /*
   * Step 3: Compute k2 = c1*|b1| - c2*a1 (signed, ~128 bits).
   *
   * b1 is negative in the lattice; |b1| (128-bit) is stored as b1c[].
   * k2 = c1*|b1| - c2*a1 may be positive or negative.
   * The result |k2| <= sqrt(2n) < 2^129.
   */

  // Compute c1 * |b1| (4x4 -> 8 words)
  u32 c1b1[8] = { 0 };
  {
    u32 t0 = 0, t1 = 0, cv = 0;
    for (u32 i = 0; i < 4; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) c1[j] * b1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c1b1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 4; i < 7; i++)
    {
      for (u32 j = i - 3; j < 4; j++)
      {
        u64 p = (u64) c1[j] * b1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c1b1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    c1b1[7] = t0;
  }

  // Compute c2 * a1 (4x4 -> 8 words)  [b2 = a1, so this is c2*b2]
  u32 c2a1[8] = { 0 };
  {
    u32 t0 = 0, t1 = 0, cv = 0;
    for (u32 i = 0; i < 4; i++)
    {
      for (u32 j = 0; j <= i; j++)
      {
        u64 p = (u64) c2[j] * a1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c2a1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    for (u32 i = 4; i < 7; i++)
    {
      for (u32 j = i - 3; j < 4; j++)
      {
        u64 p = (u64) c2[j] * a1c[i - j];
        u64 d = ((u64) t1 << 32) | t0;
        d += p; t0 = (u32) d; t1 = (u32) (d >> 32); cv += (u32) (d < p);
      }
      c2a1[i] = t0; t0 = t1; t1 = cv; cv = 0;
    }
    c2a1[7] = t0;
  }

  // r2[0..8] = c1b1 - c2a1  (signed 288-bit result)
  u32 r2[9] = { 0 };
  for (u32 i = 0; i < 8; i++) r2[i] = c1b1[i];

  borrow = 0;
  for (u32 i = 0; i < 8; i++)
  {
    u64 d   = (u64) r2[i] - c2a1[i] - borrow;
    r2[i]   = (u32) d;
    borrow  = (u32) (d >> 63) & 1;
  }
  r2[8] = (u32) (0 - borrow);

  u32 sign_k2 = borrow | (r2[8] >> 31);

  if (sign_k2)
  {
    u32 neg_carry = 1;
    for (u32 i = 0; i < 9; i++)
    {
      u64 s = (u64) (~r2[i]) + neg_carry;
      r2[i]     = (u32) s;
      neg_carry = (u32) (s >> 32);
    }
  }

  k2[0] = r2[0]; k2[1] = r2[1]; k2[2] = r2[2]; k2[3] = r2[3]; k2[4] = r2[4];
  k2[5] = sign_k2;
}

/*
 * GLV scalar multiplication: compute k*G using GLV endomorphism.
 *
 * Decomposes k = k1 + k2*lambda (mod n) where |k1|,|k2| ~= sqrt(n) ~= 2^128,
 * then computes k1*G + k2*phi(G) simultaneously using interleaved binary method.
 * The endomorphism phi(x,y) = (beta*x mod p, y) is applied to the precomputed
 * base points from tmps.
 *
 * Theoretical speedup: ~50% fewer doublings than regular point_mul_xy.
 *
 * @param rx out: x coordinate (8 u32 words)
 * @param ry out: y coordinate (8 u32 words)
 * @param k  in:  scalar (8 u32 words)
 * @param tmps in: precomputed base-point table (as in point_mul_xy)
 */
DECLSPEC void point_mul_glv_xy (PRIVATE_AS u32 *rx, PRIVATE_AS u32 *ry,
                                 PRIVATE_AS const u32 *k,
                                 SECP256K1_TMPS_TYPE const secp256k1_t *tmps)
{
  /* Decompose k into k1, k2 using GLV Babai rounding. */
  u32 k1v[6]; /* [0..4] = magnitude, [5] = sign */
  u32 k2v[6];

  glv_decompose (k, k1v, k2v);

  /*
   * Compute phi(G) = (beta * Gx mod p, Gy) for the wNAF base point (x1, y1).
   * Also compute phi of the negated base point: phi(G)_neg_y = p - phi(G)_y = p - Gy.
   * The endomorphism phi does not change the y coordinate, so phi(G)_y = Gy.
   *
   * For negative k2: we use -phi(G) = (beta*Gx mod p, p - Gy).
   * For negative k1: we use -G = (Gx, p - Gy).
   */

  /* Load beta constant for endomorphism */
  u32 beta[8];
  beta[0] = SECP256K1_BETA0;
  beta[1] = SECP256K1_BETA1;
  beta[2] = SECP256K1_BETA2;
  beta[3] = SECP256K1_BETA3;
  beta[4] = SECP256K1_BETA4;
  beta[5] = SECP256K1_BETA5;
  beta[6] = SECP256K1_BETA6;
  beta[7] = SECP256K1_BETA7;

  /* Load the base point G from tmps (same as in point_mul_xy for x1,y1 selection) */
  /* For GLV we use the 1*G starting point from the tmps table */
  u32 G_x[8], G_y[8], G_ny[8];

  /* x1 = tmps->xy[0..7], y1 = tmps->xy[8..15], -y1 = tmps->xy[16..23] */
  for (u32 i = 0; i < 8; i++) G_x[i]  = tmps->xy[i];
  for (u32 i = 0; i < 8; i++) G_y[i]  = tmps->xy[8  + i];
  for (u32 i = 0; i < 8; i++) G_ny[i] = tmps->xy[16 + i];

  /*
   * G_add = G_x, G_ay (y depends on sign of k1)
   * phi_x = beta * G_x mod p, phi_ay (y depends on sign of k2)
   */
  u32 G_ay[8];   /* y of the point we add for G (may be G_y or G_ny) */
  u32 phi_x[8];  /* x of phi(G) */
  u32 phi_ay[8]; /* y of phi(G) we add (may be G_y or G_ny, since phi doesn't change y) */

  /* phi_x = beta * G_x mod p (use PTX-accelerated path on NVIDIA) */
  mul_mod_ptx (phi_x, beta, G_x);

  /* Set G_ay based on k1 sign */
  if (k1v[5] == 0)
  {
    for (u32 i = 0; i < 8; i++) G_ay[i] = G_y[i];
  }
  else
  {
    for (u32 i = 0; i < 8; i++) G_ay[i] = G_ny[i];
  }

  /* Set phi_ay based on k2 sign */
  if (k2v[5] == 0)
  {
    for (u32 i = 0; i < 8; i++) phi_ay[i] = G_y[i];
  }
  else
  {
    for (u32 i = 0; i < 8; i++) phi_ay[i] = G_ny[i];
  }

  /*
   * Simple interleaved binary method:
   * Process bits of k1 and k2 from position 128 down to 0.
   * At each step:
   *   R = 2*R
   *   if bit_k1: R = R + G_point
   *   if bit_k2: R = R + phi_point
   *
   * k1 and k2 magnitudes are at most 129 bits, so we process 129 bit positions.
   */

  /* Initialize R at the point at infinity using the first non-zero bit */
  u32 rx_j[8], ry_j[8], rz_j[8];

  /*
   * Scan bits of k1 and k2 from the highest position (bit 128) down to 0.
   * Each scalar is at most 129 bits (5 u32 words with word[4] = 0 or 1).
   * We scan bit 128 (word[4] bit 0) plus bits 127..0 (words 0..3), giving 129 positions.
   *
   * On the first non-zero bit pair we initialize R; thereafter we double-and-add.
   * Three cases on initialization: both bits set → G + phi(G), only k1 bit → G, only k2 → phi(G).
   */

  u32 initialized = 0;

  for (int bit_pos = 128; bit_pos >= 0; bit_pos--)
  {
    u32 word_idx = (u32) bit_pos >> 5;   /* 0..4: which u32 word of k1v/k2v */
    u32 bit_idx  = (u32) bit_pos & 0x1f; /* which bit within that word */

    u32 bit1 = (k1v[word_idx] >> bit_idx) & 1;
    u32 bit2 = (k2v[word_idx] >> bit_idx) & 1;

    if (!initialized)
    {
      /* Find the first non-zero bit to set the initial projective point R. */
      if (bit1 || bit2)
      {
        if (bit1)
        {
          for (u32 i = 0; i < 8; i++) rx_j[i] = G_x[i];
          for (u32 i = 0; i < 8; i++) ry_j[i] = G_ay[i];
        }
        else /* bit2 only */
        {
          for (u32 i = 0; i < 8; i++) rx_j[i] = phi_x[i];
          for (u32 i = 0; i < 8; i++) ry_j[i] = phi_ay[i];
        }
        rz_j[0] = 1; for (u32 i = 1; i < 8; i++) rz_j[i] = 0;
        /* If both bits are set, also add the second point */
        if (bit1 && bit2) point_add (rx_j, ry_j, rz_j, phi_x, phi_ay);
        initialized = 1;
      }
      continue;
    }

    /* Always double */
    point_double (rx_j, ry_j, rz_j);

    /* Add G contribution if k1 bit is set */
    if (bit1) point_add (rx_j, ry_j, rz_j, G_x,   G_ay);
    /* Add phi(G) contribution if k2 bit is set */
    if (bit2) point_add (rx_j, ry_j, rz_j, phi_x,  phi_ay);
  }

  /* Convert Jacobian to affine */
  inv_mod (rz_j);

  u32 rz2[8];
  mul_mod (rz2, rz_j, rz_j);       /* rz^2 */
  mul_mod (rx, rx_j, rz2);          /* x_affine */
  mul_mod (rz2, rz2, rz_j);         /* rz^3 */
  mul_mod (ry, ry_j, rz2);          /* y_affine */
}

/*
 * Batch modular inversion (Montgomery's trick).
 *
 * Inverts n field elements in-place using only 1 inv_mod call instead of n.
 * This is ~3x faster than n individual inversions for n=4, more for larger n.
 *
 * @param elems  in/out: array of n pointers to 8-u32 field elements (each 256-bit)
 * @param prods  tmp:    workspace of (n+1)*8 u32 words; prods[i*8..i*8+7] = prefix product
 * @param n      in:     number of elements to invert (must be >= 1)
 *
 * Algorithm:
 *   prods[0]   = 1
 *   prods[i+1] = prods[i] * elems[i]   (prefix products)
 *   inv        = 1 / prods[n]           (single expensive inversion)
 *   for i = n-1 downto 0:
 *     elems[i] = inv * prods[i]         (individual inverse)
 *     inv      = inv * elems_original[i]
 */
DECLSPEC void batch_inv_mod (PRIVATE_AS u32 **elems, PRIVATE_AS u32 *prods, const u32 n)
{
  /* Accumulate prefix products: prods[i*8 .. i*8+7] = product of elems[0..i-1] */
  /* prods[0] = 1 */
  u32 *acc = prods; /* points to prods[0..7] */
  acc[0] = 1;
  for (u32 i = 1; i < 8; i++) acc[i] = 0;

  for (u32 i = 0; i < n; i++)
  {
    u32 *next = prods + (i + 1) * 8;
    mul_mod (next, acc, elems[i]);
    acc = next;
  }
  /* acc now points to prods[n*8..n*8+7] = product of all elements */

  /* Invert the total product (single inv_mod call) */
  u32 inv[8];
  for (u32 i = 0; i < 8; i++) inv[i] = acc[i];
  inv_mod (inv);

  /* Compute individual inverses in reverse order */
  for (u32 i = n; i > 0; i--)
  {
    u32 *prefix = prods + (i - 1) * 8; /* prods[i-1] = product of elems[0..i-2] */
    u32 *orig   = elems[i - 1];

    /* 1/elems[i-1] = inv * prefix */
    u32 tmp[8];
    mul_mod (tmp, inv, prefix);

    /* Update inv: inv = inv * elems[i-1] (original value, before overwrite) */
    mul_mod (inv, inv, orig);

    /* Write the inverse back */
    for (u32 j = 0; j < 8; j++) orig[j] = tmp[j];
  }
}

DECLSPEC void set_precomputed_basepoint_g (PRIVATE_AS secp256k1_t *r)
{
  // x1
  r->xy[ 0] = SECP256K1_G_PRE_COMPUTED_00;
  r->xy[ 1] = SECP256K1_G_PRE_COMPUTED_01;
  r->xy[ 2] = SECP256K1_G_PRE_COMPUTED_02;
  r->xy[ 3] = SECP256K1_G_PRE_COMPUTED_03;
  r->xy[ 4] = SECP256K1_G_PRE_COMPUTED_04;
  r->xy[ 5] = SECP256K1_G_PRE_COMPUTED_05;
  r->xy[ 6] = SECP256K1_G_PRE_COMPUTED_06;
  r->xy[ 7] = SECP256K1_G_PRE_COMPUTED_07;

  // y1
  r->xy[ 8] = SECP256K1_G_PRE_COMPUTED_08;
  r->xy[ 9] = SECP256K1_G_PRE_COMPUTED_09;
  r->xy[10] = SECP256K1_G_PRE_COMPUTED_10;
  r->xy[11] = SECP256K1_G_PRE_COMPUTED_11;
  r->xy[12] = SECP256K1_G_PRE_COMPUTED_12;
  r->xy[13] = SECP256K1_G_PRE_COMPUTED_13;
  r->xy[14] = SECP256K1_G_PRE_COMPUTED_14;
  r->xy[15] = SECP256K1_G_PRE_COMPUTED_15;

  // -y1
  r->xy[16] = SECP256K1_G_PRE_COMPUTED_16;
  r->xy[17] = SECP256K1_G_PRE_COMPUTED_17;
  r->xy[18] = SECP256K1_G_PRE_COMPUTED_18;
  r->xy[19] = SECP256K1_G_PRE_COMPUTED_19;
  r->xy[20] = SECP256K1_G_PRE_COMPUTED_20;
  r->xy[21] = SECP256K1_G_PRE_COMPUTED_21;
  r->xy[22] = SECP256K1_G_PRE_COMPUTED_22;
  r->xy[23] = SECP256K1_G_PRE_COMPUTED_23;

  // x3
  r->xy[24] = SECP256K1_G_PRE_COMPUTED_24;
  r->xy[25] = SECP256K1_G_PRE_COMPUTED_25;
  r->xy[26] = SECP256K1_G_PRE_COMPUTED_26;
  r->xy[27] = SECP256K1_G_PRE_COMPUTED_27;
  r->xy[28] = SECP256K1_G_PRE_COMPUTED_28;
  r->xy[29] = SECP256K1_G_PRE_COMPUTED_29;
  r->xy[30] = SECP256K1_G_PRE_COMPUTED_30;
  r->xy[31] = SECP256K1_G_PRE_COMPUTED_31;

  // y3
  r->xy[32] = SECP256K1_G_PRE_COMPUTED_32;
  r->xy[33] = SECP256K1_G_PRE_COMPUTED_33;
  r->xy[34] = SECP256K1_G_PRE_COMPUTED_34;
  r->xy[35] = SECP256K1_G_PRE_COMPUTED_35;
  r->xy[36] = SECP256K1_G_PRE_COMPUTED_36;
  r->xy[37] = SECP256K1_G_PRE_COMPUTED_37;
  r->xy[38] = SECP256K1_G_PRE_COMPUTED_38;
  r->xy[39] = SECP256K1_G_PRE_COMPUTED_39;

  // -y3
  r->xy[40] = SECP256K1_G_PRE_COMPUTED_40;
  r->xy[41] = SECP256K1_G_PRE_COMPUTED_41;
  r->xy[42] = SECP256K1_G_PRE_COMPUTED_42;
  r->xy[43] = SECP256K1_G_PRE_COMPUTED_43;
  r->xy[44] = SECP256K1_G_PRE_COMPUTED_44;
  r->xy[45] = SECP256K1_G_PRE_COMPUTED_45;
  r->xy[46] = SECP256K1_G_PRE_COMPUTED_46;
  r->xy[47] = SECP256K1_G_PRE_COMPUTED_47;

  // x5
  r->xy[48] = SECP256K1_G_PRE_COMPUTED_48;
  r->xy[49] = SECP256K1_G_PRE_COMPUTED_49;
  r->xy[50] = SECP256K1_G_PRE_COMPUTED_50;
  r->xy[51] = SECP256K1_G_PRE_COMPUTED_51;
  r->xy[52] = SECP256K1_G_PRE_COMPUTED_52;
  r->xy[53] = SECP256K1_G_PRE_COMPUTED_53;
  r->xy[54] = SECP256K1_G_PRE_COMPUTED_54;
  r->xy[55] = SECP256K1_G_PRE_COMPUTED_55;

  // y5
  r->xy[56] = SECP256K1_G_PRE_COMPUTED_56;
  r->xy[57] = SECP256K1_G_PRE_COMPUTED_57;
  r->xy[58] = SECP256K1_G_PRE_COMPUTED_58;
  r->xy[59] = SECP256K1_G_PRE_COMPUTED_59;
  r->xy[60] = SECP256K1_G_PRE_COMPUTED_60;
  r->xy[61] = SECP256K1_G_PRE_COMPUTED_61;
  r->xy[62] = SECP256K1_G_PRE_COMPUTED_62;
  r->xy[63] = SECP256K1_G_PRE_COMPUTED_63;

  // -y5
  r->xy[64] = SECP256K1_G_PRE_COMPUTED_64;
  r->xy[65] = SECP256K1_G_PRE_COMPUTED_65;
  r->xy[66] = SECP256K1_G_PRE_COMPUTED_66;
  r->xy[67] = SECP256K1_G_PRE_COMPUTED_67;
  r->xy[68] = SECP256K1_G_PRE_COMPUTED_68;
  r->xy[69] = SECP256K1_G_PRE_COMPUTED_69;
  r->xy[70] = SECP256K1_G_PRE_COMPUTED_70;
  r->xy[71] = SECP256K1_G_PRE_COMPUTED_71;

  // x7
  r->xy[72] = SECP256K1_G_PRE_COMPUTED_72;
  r->xy[73] = SECP256K1_G_PRE_COMPUTED_73;
  r->xy[74] = SECP256K1_G_PRE_COMPUTED_74;
  r->xy[75] = SECP256K1_G_PRE_COMPUTED_75;
  r->xy[76] = SECP256K1_G_PRE_COMPUTED_76;
  r->xy[77] = SECP256K1_G_PRE_COMPUTED_77;
  r->xy[78] = SECP256K1_G_PRE_COMPUTED_78;
  r->xy[79] = SECP256K1_G_PRE_COMPUTED_79;

  // y7
  r->xy[80] = SECP256K1_G_PRE_COMPUTED_80;
  r->xy[81] = SECP256K1_G_PRE_COMPUTED_81;
  r->xy[82] = SECP256K1_G_PRE_COMPUTED_82;
  r->xy[83] = SECP256K1_G_PRE_COMPUTED_83;
  r->xy[84] = SECP256K1_G_PRE_COMPUTED_84;
  r->xy[85] = SECP256K1_G_PRE_COMPUTED_85;
  r->xy[86] = SECP256K1_G_PRE_COMPUTED_86;
  r->xy[87] = SECP256K1_G_PRE_COMPUTED_87;

  // -y7
  r->xy[88] = SECP256K1_G_PRE_COMPUTED_88;
  r->xy[89] = SECP256K1_G_PRE_COMPUTED_89;
  r->xy[90] = SECP256K1_G_PRE_COMPUTED_90;
  r->xy[91] = SECP256K1_G_PRE_COMPUTED_91;
  r->xy[92] = SECP256K1_G_PRE_COMPUTED_92;
  r->xy[93] = SECP256K1_G_PRE_COMPUTED_93;
  r->xy[94] = SECP256K1_G_PRE_COMPUTED_94;
  r->xy[95] = SECP256K1_G_PRE_COMPUTED_95;
}

/*
 * Initialize the w=5 precomputed basepoint table (8 odd multiples: 1G..15G).
 * First 96 words are identical to the w=4 table (1G, 3G, 5G, 7G).
 * The next 96 words add 9G, 11G, 13G, 15G.
 */
DECLSPEC void set_precomputed_basepoint_g_w5 (PRIVATE_AS secp256k1_w5_t *r)
{
  // 1G, 3G, 5G, 7G (same as w=4 table)
  r->xy[0]  = SECP256K1_G_PRE_COMPUTED_00;
  r->xy[1]  = SECP256K1_G_PRE_COMPUTED_01;
  r->xy[2]  = SECP256K1_G_PRE_COMPUTED_02;
  r->xy[3]  = SECP256K1_G_PRE_COMPUTED_03;
  r->xy[4]  = SECP256K1_G_PRE_COMPUTED_04;
  r->xy[5]  = SECP256K1_G_PRE_COMPUTED_05;
  r->xy[6]  = SECP256K1_G_PRE_COMPUTED_06;
  r->xy[7]  = SECP256K1_G_PRE_COMPUTED_07;
  r->xy[8]  = SECP256K1_G_PRE_COMPUTED_08;
  r->xy[9]  = SECP256K1_G_PRE_COMPUTED_09;
  r->xy[10] = SECP256K1_G_PRE_COMPUTED_10;
  r->xy[11] = SECP256K1_G_PRE_COMPUTED_11;
  r->xy[12] = SECP256K1_G_PRE_COMPUTED_12;
  r->xy[13] = SECP256K1_G_PRE_COMPUTED_13;
  r->xy[14] = SECP256K1_G_PRE_COMPUTED_14;
  r->xy[15] = SECP256K1_G_PRE_COMPUTED_15;
  r->xy[16] = SECP256K1_G_PRE_COMPUTED_16;
  r->xy[17] = SECP256K1_G_PRE_COMPUTED_17;
  r->xy[18] = SECP256K1_G_PRE_COMPUTED_18;
  r->xy[19] = SECP256K1_G_PRE_COMPUTED_19;
  r->xy[20] = SECP256K1_G_PRE_COMPUTED_20;
  r->xy[21] = SECP256K1_G_PRE_COMPUTED_21;
  r->xy[22] = SECP256K1_G_PRE_COMPUTED_22;
  r->xy[23] = SECP256K1_G_PRE_COMPUTED_23;
  r->xy[24] = SECP256K1_G_PRE_COMPUTED_24;
  r->xy[25] = SECP256K1_G_PRE_COMPUTED_25;
  r->xy[26] = SECP256K1_G_PRE_COMPUTED_26;
  r->xy[27] = SECP256K1_G_PRE_COMPUTED_27;
  r->xy[28] = SECP256K1_G_PRE_COMPUTED_28;
  r->xy[29] = SECP256K1_G_PRE_COMPUTED_29;
  r->xy[30] = SECP256K1_G_PRE_COMPUTED_30;
  r->xy[31] = SECP256K1_G_PRE_COMPUTED_31;
  r->xy[32] = SECP256K1_G_PRE_COMPUTED_32;
  r->xy[33] = SECP256K1_G_PRE_COMPUTED_33;
  r->xy[34] = SECP256K1_G_PRE_COMPUTED_34;
  r->xy[35] = SECP256K1_G_PRE_COMPUTED_35;
  r->xy[36] = SECP256K1_G_PRE_COMPUTED_36;
  r->xy[37] = SECP256K1_G_PRE_COMPUTED_37;
  r->xy[38] = SECP256K1_G_PRE_COMPUTED_38;
  r->xy[39] = SECP256K1_G_PRE_COMPUTED_39;
  r->xy[40] = SECP256K1_G_PRE_COMPUTED_40;
  r->xy[41] = SECP256K1_G_PRE_COMPUTED_41;
  r->xy[42] = SECP256K1_G_PRE_COMPUTED_42;
  r->xy[43] = SECP256K1_G_PRE_COMPUTED_43;
  r->xy[44] = SECP256K1_G_PRE_COMPUTED_44;
  r->xy[45] = SECP256K1_G_PRE_COMPUTED_45;
  r->xy[46] = SECP256K1_G_PRE_COMPUTED_46;
  r->xy[47] = SECP256K1_G_PRE_COMPUTED_47;
  r->xy[48] = SECP256K1_G_PRE_COMPUTED_48;
  r->xy[49] = SECP256K1_G_PRE_COMPUTED_49;
  r->xy[50] = SECP256K1_G_PRE_COMPUTED_50;
  r->xy[51] = SECP256K1_G_PRE_COMPUTED_51;
  r->xy[52] = SECP256K1_G_PRE_COMPUTED_52;
  r->xy[53] = SECP256K1_G_PRE_COMPUTED_53;
  r->xy[54] = SECP256K1_G_PRE_COMPUTED_54;
  r->xy[55] = SECP256K1_G_PRE_COMPUTED_55;
  r->xy[56] = SECP256K1_G_PRE_COMPUTED_56;
  r->xy[57] = SECP256K1_G_PRE_COMPUTED_57;
  r->xy[58] = SECP256K1_G_PRE_COMPUTED_58;
  r->xy[59] = SECP256K1_G_PRE_COMPUTED_59;
  r->xy[60] = SECP256K1_G_PRE_COMPUTED_60;
  r->xy[61] = SECP256K1_G_PRE_COMPUTED_61;
  r->xy[62] = SECP256K1_G_PRE_COMPUTED_62;
  r->xy[63] = SECP256K1_G_PRE_COMPUTED_63;
  r->xy[64] = SECP256K1_G_PRE_COMPUTED_64;
  r->xy[65] = SECP256K1_G_PRE_COMPUTED_65;
  r->xy[66] = SECP256K1_G_PRE_COMPUTED_66;
  r->xy[67] = SECP256K1_G_PRE_COMPUTED_67;
  r->xy[68] = SECP256K1_G_PRE_COMPUTED_68;
  r->xy[69] = SECP256K1_G_PRE_COMPUTED_69;
  r->xy[70] = SECP256K1_G_PRE_COMPUTED_70;
  r->xy[71] = SECP256K1_G_PRE_COMPUTED_71;
  r->xy[72] = SECP256K1_G_PRE_COMPUTED_72;
  r->xy[73] = SECP256K1_G_PRE_COMPUTED_73;
  r->xy[74] = SECP256K1_G_PRE_COMPUTED_74;
  r->xy[75] = SECP256K1_G_PRE_COMPUTED_75;
  r->xy[76] = SECP256K1_G_PRE_COMPUTED_76;
  r->xy[77] = SECP256K1_G_PRE_COMPUTED_77;
  r->xy[78] = SECP256K1_G_PRE_COMPUTED_78;
  r->xy[79] = SECP256K1_G_PRE_COMPUTED_79;
  r->xy[80] = SECP256K1_G_PRE_COMPUTED_80;
  r->xy[81] = SECP256K1_G_PRE_COMPUTED_81;
  r->xy[82] = SECP256K1_G_PRE_COMPUTED_82;
  r->xy[83] = SECP256K1_G_PRE_COMPUTED_83;
  r->xy[84] = SECP256K1_G_PRE_COMPUTED_84;
  r->xy[85] = SECP256K1_G_PRE_COMPUTED_85;
  r->xy[86] = SECP256K1_G_PRE_COMPUTED_86;
  r->xy[87] = SECP256K1_G_PRE_COMPUTED_87;
  r->xy[88] = SECP256K1_G_PRE_COMPUTED_88;
  r->xy[89] = SECP256K1_G_PRE_COMPUTED_89;
  r->xy[90] = SECP256K1_G_PRE_COMPUTED_90;
  r->xy[91] = SECP256K1_G_PRE_COMPUTED_91;
  r->xy[92] = SECP256K1_G_PRE_COMPUTED_92;
  r->xy[93] = SECP256K1_G_PRE_COMPUTED_93;
  r->xy[94] = SECP256K1_G_PRE_COMPUTED_94;
  r->xy[95] = SECP256K1_G_PRE_COMPUTED_95;

  // 9G, 11G, 13G, 15G (w=5 extension)
  r->xy[96]  = SECP256K1_G_PRE_COMPUTED_96;
  r->xy[97]  = SECP256K1_G_PRE_COMPUTED_97;
  r->xy[98]  = SECP256K1_G_PRE_COMPUTED_98;
  r->xy[99]  = SECP256K1_G_PRE_COMPUTED_99;
  r->xy[100] = SECP256K1_G_PRE_COMPUTED_100;
  r->xy[101] = SECP256K1_G_PRE_COMPUTED_101;
  r->xy[102] = SECP256K1_G_PRE_COMPUTED_102;
  r->xy[103] = SECP256K1_G_PRE_COMPUTED_103;
  r->xy[104] = SECP256K1_G_PRE_COMPUTED_104;
  r->xy[105] = SECP256K1_G_PRE_COMPUTED_105;
  r->xy[106] = SECP256K1_G_PRE_COMPUTED_106;
  r->xy[107] = SECP256K1_G_PRE_COMPUTED_107;
  r->xy[108] = SECP256K1_G_PRE_COMPUTED_108;
  r->xy[109] = SECP256K1_G_PRE_COMPUTED_109;
  r->xy[110] = SECP256K1_G_PRE_COMPUTED_110;
  r->xy[111] = SECP256K1_G_PRE_COMPUTED_111;
  r->xy[112] = SECP256K1_G_PRE_COMPUTED_112;
  r->xy[113] = SECP256K1_G_PRE_COMPUTED_113;
  r->xy[114] = SECP256K1_G_PRE_COMPUTED_114;
  r->xy[115] = SECP256K1_G_PRE_COMPUTED_115;
  r->xy[116] = SECP256K1_G_PRE_COMPUTED_116;
  r->xy[117] = SECP256K1_G_PRE_COMPUTED_117;
  r->xy[118] = SECP256K1_G_PRE_COMPUTED_118;
  r->xy[119] = SECP256K1_G_PRE_COMPUTED_119;
  r->xy[120] = SECP256K1_G_PRE_COMPUTED_120;
  r->xy[121] = SECP256K1_G_PRE_COMPUTED_121;
  r->xy[122] = SECP256K1_G_PRE_COMPUTED_122;
  r->xy[123] = SECP256K1_G_PRE_COMPUTED_123;
  r->xy[124] = SECP256K1_G_PRE_COMPUTED_124;
  r->xy[125] = SECP256K1_G_PRE_COMPUTED_125;
  r->xy[126] = SECP256K1_G_PRE_COMPUTED_126;
  r->xy[127] = SECP256K1_G_PRE_COMPUTED_127;
  r->xy[128] = SECP256K1_G_PRE_COMPUTED_128;
  r->xy[129] = SECP256K1_G_PRE_COMPUTED_129;
  r->xy[130] = SECP256K1_G_PRE_COMPUTED_130;
  r->xy[131] = SECP256K1_G_PRE_COMPUTED_131;
  r->xy[132] = SECP256K1_G_PRE_COMPUTED_132;
  r->xy[133] = SECP256K1_G_PRE_COMPUTED_133;
  r->xy[134] = SECP256K1_G_PRE_COMPUTED_134;
  r->xy[135] = SECP256K1_G_PRE_COMPUTED_135;
  r->xy[136] = SECP256K1_G_PRE_COMPUTED_136;
  r->xy[137] = SECP256K1_G_PRE_COMPUTED_137;
  r->xy[138] = SECP256K1_G_PRE_COMPUTED_138;
  r->xy[139] = SECP256K1_G_PRE_COMPUTED_139;
  r->xy[140] = SECP256K1_G_PRE_COMPUTED_140;
  r->xy[141] = SECP256K1_G_PRE_COMPUTED_141;
  r->xy[142] = SECP256K1_G_PRE_COMPUTED_142;
  r->xy[143] = SECP256K1_G_PRE_COMPUTED_143;
  r->xy[144] = SECP256K1_G_PRE_COMPUTED_144;
  r->xy[145] = SECP256K1_G_PRE_COMPUTED_145;
  r->xy[146] = SECP256K1_G_PRE_COMPUTED_146;
  r->xy[147] = SECP256K1_G_PRE_COMPUTED_147;
  r->xy[148] = SECP256K1_G_PRE_COMPUTED_148;
  r->xy[149] = SECP256K1_G_PRE_COMPUTED_149;
  r->xy[150] = SECP256K1_G_PRE_COMPUTED_150;
  r->xy[151] = SECP256K1_G_PRE_COMPUTED_151;
  r->xy[152] = SECP256K1_G_PRE_COMPUTED_152;
  r->xy[153] = SECP256K1_G_PRE_COMPUTED_153;
  r->xy[154] = SECP256K1_G_PRE_COMPUTED_154;
  r->xy[155] = SECP256K1_G_PRE_COMPUTED_155;
  r->xy[156] = SECP256K1_G_PRE_COMPUTED_156;
  r->xy[157] = SECP256K1_G_PRE_COMPUTED_157;
  r->xy[158] = SECP256K1_G_PRE_COMPUTED_158;
  r->xy[159] = SECP256K1_G_PRE_COMPUTED_159;
  r->xy[160] = SECP256K1_G_PRE_COMPUTED_160;
  r->xy[161] = SECP256K1_G_PRE_COMPUTED_161;
  r->xy[162] = SECP256K1_G_PRE_COMPUTED_162;
  r->xy[163] = SECP256K1_G_PRE_COMPUTED_163;
  r->xy[164] = SECP256K1_G_PRE_COMPUTED_164;
  r->xy[165] = SECP256K1_G_PRE_COMPUTED_165;
  r->xy[166] = SECP256K1_G_PRE_COMPUTED_166;
  r->xy[167] = SECP256K1_G_PRE_COMPUTED_167;
  r->xy[168] = SECP256K1_G_PRE_COMPUTED_168;
  r->xy[169] = SECP256K1_G_PRE_COMPUTED_169;
  r->xy[170] = SECP256K1_G_PRE_COMPUTED_170;
  r->xy[171] = SECP256K1_G_PRE_COMPUTED_171;
  r->xy[172] = SECP256K1_G_PRE_COMPUTED_172;
  r->xy[173] = SECP256K1_G_PRE_COMPUTED_173;
  r->xy[174] = SECP256K1_G_PRE_COMPUTED_174;
  r->xy[175] = SECP256K1_G_PRE_COMPUTED_175;
  r->xy[176] = SECP256K1_G_PRE_COMPUTED_176;
  r->xy[177] = SECP256K1_G_PRE_COMPUTED_177;
  r->xy[178] = SECP256K1_G_PRE_COMPUTED_178;
  r->xy[179] = SECP256K1_G_PRE_COMPUTED_179;
  r->xy[180] = SECP256K1_G_PRE_COMPUTED_180;
  r->xy[181] = SECP256K1_G_PRE_COMPUTED_181;
  r->xy[182] = SECP256K1_G_PRE_COMPUTED_182;
  r->xy[183] = SECP256K1_G_PRE_COMPUTED_183;
  r->xy[184] = SECP256K1_G_PRE_COMPUTED_184;
  r->xy[185] = SECP256K1_G_PRE_COMPUTED_185;
  r->xy[186] = SECP256K1_G_PRE_COMPUTED_186;
  r->xy[187] = SECP256K1_G_PRE_COMPUTED_187;
  r->xy[188] = SECP256K1_G_PRE_COMPUTED_188;
  r->xy[189] = SECP256K1_G_PRE_COMPUTED_189;
  r->xy[190] = SECP256K1_G_PRE_COMPUTED_190;
  r->xy[191] = SECP256K1_G_PRE_COMPUTED_191;
}

/*
 * Convert scalar k to w-NAF using byte packing (4 digits per u32, 8 bits each).
 * Window size is controlled by WNAF_WINDOW_SIZE macro (default 4).
 * Encoding: 0 = zero digit; positive odd d → val=d; negative odd d → val=(2^w+1)-d.
 * @param naf out: byte-packed NAF, array of SECP256K1_NAF_BYTE_SIZE u32 words.
 *                 MUST be zero-initialized by the caller before this call;
 *                 the function ORs digits into the array.
 * @param k in: 256-bit scalar, array of 8 u32 words (little-endian limbs, k[0]=LSW).
 * @return loop_start index (position of highest nonzero digit).
 */
DECLSPEC int convert_to_wnaf_byte (PRIVATE_AS u32 *naf, PRIVATE_AS const u32 *k)
{
  int loop_start = 0;

  const u32 w       = WNAF_WINDOW_SIZE;
  const u32 mask    = WNAF_MASK;           // (1 << w) - 1
  const u32 half    = WNAF_HALF;           // 1 << (w-1)
  const u32 two_w   = (1u << w);           // 2^w (for subtraction when digit >= half)
  const u32 val_neg = two_w + 1u;          // 2^w + 1 (for negative digit encoding)

  u32 n[9];

  // Reversed limb order: n[8] = LSW (k[0]), n[1] = MSW (k[7]), n[0] = carry slot.
  // This matches the existing convert_to_window_naf() convention.
  n[0] =    0; // extra high word for carry/borrow propagation
  n[1] = k[7];
  n[2] = k[6];
  n[3] = k[5];
  n[4] = k[4];
  n[5] = k[3];
  n[6] = k[2];
  n[7] = k[1];
  n[8] = k[0];

  // Iterate over all 257 bit positions (0..256 inclusive).
  // The NAF can be at most bit_length(k)+1 digits long (<=257 for a 256-bit k).
  // SECP256K1_NAF_BYTE_SIZE = 65 u32 words * 4 bytes/word = 260 byte slots >= 257.
  for (int i = 0; i <= 256; i++)
  {
    if (n[8] & 1)
    {
      int diff = (int)(n[8] & mask); // lower w bits (always in [0, 2^w - 1])

      u32 val = (u32)diff;

      if ((u32)diff >= half)
      {
        diff -= (int)two_w;
        val   = val_neg - val; // encode negative digit
      }

      // pack 4 bytes per u32: byte index i → word i>>2, shift (i&3)<<3
      naf[i >> 2] |= val << ((i & 3) << 3);

      u32 t = n[8]; // save old LSW for carry detection

      n[8] -= (u32)diff;

      // propagate carry/borrow upward
      u32 kk = 8;

      if (diff > 0)
      {
        while (n[kk] > t)
        {
          if (kk == 0) break;
          kk--;
          t    = n[kk];
          n[kk]--;
        }
      }
      else
      {
        while (t > n[kk])
        {
          if (kk == 0) break;
          kk--;
          t    = n[kk];
          n[kk]++;
        }
      }

      loop_start = i;
    }

    // right-shift n by 1 bit
    n[8] = n[8] >> 1 | n[7] << 31;
    n[7] = n[7] >> 1 | n[6] << 31;
    n[6] = n[6] >> 1 | n[5] << 31;
    n[5] = n[5] >> 1 | n[4] << 31;
    n[4] = n[4] >> 1 | n[3] << 31;
    n[3] = n[3] >> 1 | n[2] << 31;
    n[2] = n[2] >> 1 | n[1] << 31;
    n[1] = n[1] >> 1 | n[0] << 31;
    n[0] = n[0] >> 1;
  }

  return loop_start;
}

/*
 * Point multiplication using the w=5 precomputed table (1G..15G, 8 odd multiples).
 * Uses convert_to_wnaf_byte() with WNAF_WINDOW_SIZE=5 (or current compile-time default).
 * @param x1  out: x coordinate (8 u32).
 * @param y1  out: y coordinate (8 u32).
 * @param k   in:  256-bit scalar (8 u32).
 * @param tmps in: w=5 precomputed basepoint table.
 */
DECLSPEC void point_mul_wnaf_w5 (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_w5_t *tmps)
{
  u32 naf[SECP256K1_NAF_BYTE_SIZE] = { 0 };

  int loop_start = convert_to_wnaf_byte (naf, k);

  // Extract the first (highest) nonzero digit and initialize the accumulator.
  const u32 multiplier0 = (naf[loop_start >> 2] >> ((loop_start & 3) << 3)) & 0xff;

  const u32 odd0  = multiplier0 & 1;
  const u32 xp0   = ((multiplier0 - 1 + odd0) >> 1) * 24;
  const u32 yp0   = odd0 ? (xp0 + 8) : (xp0 + 16);

  x1[0] = tmps->xy[xp0 + 0];
  x1[1] = tmps->xy[xp0 + 1];
  x1[2] = tmps->xy[xp0 + 2];
  x1[3] = tmps->xy[xp0 + 3];
  x1[4] = tmps->xy[xp0 + 4];
  x1[5] = tmps->xy[xp0 + 5];
  x1[6] = tmps->xy[xp0 + 6];
  x1[7] = tmps->xy[xp0 + 7];

  y1[0] = tmps->xy[yp0 + 0];
  y1[1] = tmps->xy[yp0 + 1];
  y1[2] = tmps->xy[yp0 + 2];
  y1[3] = tmps->xy[yp0 + 3];
  y1[4] = tmps->xy[yp0 + 4];
  y1[5] = tmps->xy[yp0 + 5];
  y1[6] = tmps->xy[yp0 + 6];
  y1[7] = tmps->xy[yp0 + 7];

  u32 z1[8] = { 0 };
  z1[0] = 1;

  // Main left-to-right loop
  for (int pos = loop_start - 1; pos >= 0; pos--)
  {
    point_double (x1, y1, z1);

    const u32 multiplier = (naf[pos >> 2] >> ((pos & 3) << 3)) & 0xff;

    if (multiplier)
    {
      const u32 odd  = multiplier & 1;
      const u32 x_pos = ((multiplier - 1 + odd) >> 1) * 24;
      const u32 y_pos = odd ? (x_pos + 8) : (x_pos + 16);

      u32 x2[8];

      x2[0] = tmps->xy[x_pos + 0];
      x2[1] = tmps->xy[x_pos + 1];
      x2[2] = tmps->xy[x_pos + 2];
      x2[3] = tmps->xy[x_pos + 3];
      x2[4] = tmps->xy[x_pos + 4];
      x2[5] = tmps->xy[x_pos + 5];
      x2[6] = tmps->xy[x_pos + 6];
      x2[7] = tmps->xy[x_pos + 7];

      u32 y2[8];

      y2[0] = tmps->xy[y_pos + 0];
      y2[1] = tmps->xy[y_pos + 1];
      y2[2] = tmps->xy[y_pos + 2];
      y2[3] = tmps->xy[y_pos + 3];
      y2[4] = tmps->xy[y_pos + 4];
      y2[5] = tmps->xy[y_pos + 5];
      y2[6] = tmps->xy[y_pos + 6];
      y2[7] = tmps->xy[y_pos + 7];

      point_add (x1, y1, z1, x2, y2);
    }
  }

  // Convert from projective Jacobian to affine coordinates:
  // x_affine = x / z^2 = x * (1/z)^2
  // y_affine = y / z^3 = y * (1/z)^3

  inv_mod (z1);

  u32 z2[8];

  mul_mod (z2, z1, z1); // z^2
  mul_mod (x1, x1, z2); // x_affine

  mul_mod (z1, z2, z1); // z^3
  mul_mod (y1, y1, z1); // y_affine
}

/*
 * Fill the w=4 precomputed basepoint table (96 u32 words) into shared/local memory.
 * Called once per workgroup before point_mul_xy_lm.
 * All threads in the workgroup must call this function cooperatively.
 * A SYNC_THREADS() barrier is issued at the end so callers need not add another.
 *
 * @param lm_xy  out: LOCAL_AS u32 array of size SECP256K1_SHMEM_SIZE (96 words).
 * @param lid    in:  get_local_id(0) -- lane index within workgroup.
 * @param lsz    in:  get_local_size(0) -- total workgroup size.
 */
DECLSPEC void set_precomputed_basepoint_g_lm (LOCAL_AS u32 *lm_xy, const u64 lid, const u64 lsz)
{
  // Cooperative initialization: each lane fills one or more words.
  // Constant table stored as a compile-time array of 96 values, indexed by lane.
  const u32 SECP256K1_G_CONSTANTS[96] = {
    SECP256K1_G_PRE_COMPUTED_00, SECP256K1_G_PRE_COMPUTED_01, SECP256K1_G_PRE_COMPUTED_02, SECP256K1_G_PRE_COMPUTED_03,
    SECP256K1_G_PRE_COMPUTED_04, SECP256K1_G_PRE_COMPUTED_05, SECP256K1_G_PRE_COMPUTED_06, SECP256K1_G_PRE_COMPUTED_07,
    SECP256K1_G_PRE_COMPUTED_08, SECP256K1_G_PRE_COMPUTED_09, SECP256K1_G_PRE_COMPUTED_10, SECP256K1_G_PRE_COMPUTED_11,
    SECP256K1_G_PRE_COMPUTED_12, SECP256K1_G_PRE_COMPUTED_13, SECP256K1_G_PRE_COMPUTED_14, SECP256K1_G_PRE_COMPUTED_15,
    SECP256K1_G_PRE_COMPUTED_16, SECP256K1_G_PRE_COMPUTED_17, SECP256K1_G_PRE_COMPUTED_18, SECP256K1_G_PRE_COMPUTED_19,
    SECP256K1_G_PRE_COMPUTED_20, SECP256K1_G_PRE_COMPUTED_21, SECP256K1_G_PRE_COMPUTED_22, SECP256K1_G_PRE_COMPUTED_23,
    SECP256K1_G_PRE_COMPUTED_24, SECP256K1_G_PRE_COMPUTED_25, SECP256K1_G_PRE_COMPUTED_26, SECP256K1_G_PRE_COMPUTED_27,
    SECP256K1_G_PRE_COMPUTED_28, SECP256K1_G_PRE_COMPUTED_29, SECP256K1_G_PRE_COMPUTED_30, SECP256K1_G_PRE_COMPUTED_31,
    SECP256K1_G_PRE_COMPUTED_32, SECP256K1_G_PRE_COMPUTED_33, SECP256K1_G_PRE_COMPUTED_34, SECP256K1_G_PRE_COMPUTED_35,
    SECP256K1_G_PRE_COMPUTED_36, SECP256K1_G_PRE_COMPUTED_37, SECP256K1_G_PRE_COMPUTED_38, SECP256K1_G_PRE_COMPUTED_39,
    SECP256K1_G_PRE_COMPUTED_40, SECP256K1_G_PRE_COMPUTED_41, SECP256K1_G_PRE_COMPUTED_42, SECP256K1_G_PRE_COMPUTED_43,
    SECP256K1_G_PRE_COMPUTED_44, SECP256K1_G_PRE_COMPUTED_45, SECP256K1_G_PRE_COMPUTED_46, SECP256K1_G_PRE_COMPUTED_47,
    SECP256K1_G_PRE_COMPUTED_48, SECP256K1_G_PRE_COMPUTED_49, SECP256K1_G_PRE_COMPUTED_50, SECP256K1_G_PRE_COMPUTED_51,
    SECP256K1_G_PRE_COMPUTED_52, SECP256K1_G_PRE_COMPUTED_53, SECP256K1_G_PRE_COMPUTED_54, SECP256K1_G_PRE_COMPUTED_55,
    SECP256K1_G_PRE_COMPUTED_56, SECP256K1_G_PRE_COMPUTED_57, SECP256K1_G_PRE_COMPUTED_58, SECP256K1_G_PRE_COMPUTED_59,
    SECP256K1_G_PRE_COMPUTED_60, SECP256K1_G_PRE_COMPUTED_61, SECP256K1_G_PRE_COMPUTED_62, SECP256K1_G_PRE_COMPUTED_63,
    SECP256K1_G_PRE_COMPUTED_64, SECP256K1_G_PRE_COMPUTED_65, SECP256K1_G_PRE_COMPUTED_66, SECP256K1_G_PRE_COMPUTED_67,
    SECP256K1_G_PRE_COMPUTED_68, SECP256K1_G_PRE_COMPUTED_69, SECP256K1_G_PRE_COMPUTED_70, SECP256K1_G_PRE_COMPUTED_71,
    SECP256K1_G_PRE_COMPUTED_72, SECP256K1_G_PRE_COMPUTED_73, SECP256K1_G_PRE_COMPUTED_74, SECP256K1_G_PRE_COMPUTED_75,
    SECP256K1_G_PRE_COMPUTED_76, SECP256K1_G_PRE_COMPUTED_77, SECP256K1_G_PRE_COMPUTED_78, SECP256K1_G_PRE_COMPUTED_79,
    SECP256K1_G_PRE_COMPUTED_80, SECP256K1_G_PRE_COMPUTED_81, SECP256K1_G_PRE_COMPUTED_82, SECP256K1_G_PRE_COMPUTED_83,
    SECP256K1_G_PRE_COMPUTED_84, SECP256K1_G_PRE_COMPUTED_85, SECP256K1_G_PRE_COMPUTED_86, SECP256K1_G_PRE_COMPUTED_87,
    SECP256K1_G_PRE_COMPUTED_88, SECP256K1_G_PRE_COMPUTED_89, SECP256K1_G_PRE_COMPUTED_90, SECP256K1_G_PRE_COMPUTED_91,
    SECP256K1_G_PRE_COMPUTED_92, SECP256K1_G_PRE_COMPUTED_93, SECP256K1_G_PRE_COMPUTED_94, SECP256K1_G_PRE_COMPUTED_95,
  };

  for (u64 i = lid; i < SECP256K1_SHMEM_SIZE; i += lsz)
  {
    lm_xy[i] = SECP256K1_G_CONSTANTS[i];
  }

  SYNC_THREADS ();
}

/*
 * Point multiplication using the w=4 precomputed table in shared/local memory.
 * Identical to point_mul_xy() but reads the table from lm_xy (LOCAL_AS).
 * Must be preceded by set_precomputed_basepoint_g_lm() in the same workgroup.
 *
 * @param x1    out: x coordinate (8 u32).
 * @param y1    out: y coordinate (8 u32).
 * @param k     in:  256-bit scalar (8 u32 little-endian).
 * @param lm_xy in:  LOCAL_AS u32[SECP256K1_SHMEM_SIZE] table.
 */
DECLSPEC void point_mul_xy_lm (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, LOCAL_AS const u32 *lm_xy)
{
  u32 naf[SECP256K1_NAF_SIZE] = { 0 };

  int loop_start = convert_to_window_naf (naf, k);

  const u32 multiplier = (naf[loop_start >> 3] >> ((loop_start & 7) << 2)) & 0x0f;

  const u32 odd = multiplier & 1;

  const u32 x_pos = ((multiplier - 1 + odd) >> 1) * 24;
  const u32 y_pos = odd ? (x_pos + 8) : (x_pos + 16);

  x1[0] = lm_xy[x_pos + 0];
  x1[1] = lm_xy[x_pos + 1];
  x1[2] = lm_xy[x_pos + 2];
  x1[3] = lm_xy[x_pos + 3];
  x1[4] = lm_xy[x_pos + 4];
  x1[5] = lm_xy[x_pos + 5];
  x1[6] = lm_xy[x_pos + 6];
  x1[7] = lm_xy[x_pos + 7];

  y1[0] = lm_xy[y_pos + 0];
  y1[1] = lm_xy[y_pos + 1];
  y1[2] = lm_xy[y_pos + 2];
  y1[3] = lm_xy[y_pos + 3];
  y1[4] = lm_xy[y_pos + 4];
  y1[5] = lm_xy[y_pos + 5];
  y1[6] = lm_xy[y_pos + 6];
  y1[7] = lm_xy[y_pos + 7];

  u32 z1[8] = { 0 };

  z1[0] = 1;

  for (int pos = loop_start - 1; pos >= 0; pos--)
  {
    point_double (x1, y1, z1);

    const u32 mul = (naf[pos >> 3] >> ((pos & 7) << 2)) & 0x0f;

    if (mul)
    {
      const u32 o  = mul & 1;
      const u32 xp = ((mul - 1 + o) >> 1) * 24;
      const u32 yp = o ? (xp + 8) : (xp + 16);

      u32 x2[8];
      x2[0] = lm_xy[xp + 0];
      x2[1] = lm_xy[xp + 1];
      x2[2] = lm_xy[xp + 2];
      x2[3] = lm_xy[xp + 3];
      x2[4] = lm_xy[xp + 4];
      x2[5] = lm_xy[xp + 5];
      x2[6] = lm_xy[xp + 6];
      x2[7] = lm_xy[xp + 7];

      u32 y2[8];
      y2[0] = lm_xy[yp + 0];
      y2[1] = lm_xy[yp + 1];
      y2[2] = lm_xy[yp + 2];
      y2[3] = lm_xy[yp + 3];
      y2[4] = lm_xy[yp + 4];
      y2[5] = lm_xy[yp + 5];
      y2[6] = lm_xy[yp + 6];
      y2[7] = lm_xy[yp + 7];

      point_add (x1, y1, z1, x2, y2);
    }
  }

  inv_mod (z1);

  u32 z2[8];

  mul_mod (z2, z1, z1);
  mul_mod (x1, x1, z2);

  mul_mod (z1, z2, z1);
  mul_mod (y1, y1, z1);
}

/*
 * Fill the w=5 precomputed basepoint table (192 u32 words) into shared/local memory.
 * All threads in the workgroup must call this function cooperatively.
 * A SYNC_THREADS() barrier is issued at the end.
 *
 * @param lm_xy  out: LOCAL_AS u32 array of size SECP256K1_W5_SHMEM_SIZE (192 words).
 * @param lid    in:  get_local_id(0).
 * @param lsz    in:  get_local_size(0).
 */
DECLSPEC void set_precomputed_basepoint_g_w5_lm (LOCAL_AS u32 *lm_xy, const u64 lid, const u64 lsz)
{
  const u32 SECP256K1_G_W5_CONSTANTS[192] = {
    SECP256K1_G_PRE_COMPUTED_00,  SECP256K1_G_PRE_COMPUTED_01,  SECP256K1_G_PRE_COMPUTED_02,  SECP256K1_G_PRE_COMPUTED_03,
    SECP256K1_G_PRE_COMPUTED_04,  SECP256K1_G_PRE_COMPUTED_05,  SECP256K1_G_PRE_COMPUTED_06,  SECP256K1_G_PRE_COMPUTED_07,
    SECP256K1_G_PRE_COMPUTED_08,  SECP256K1_G_PRE_COMPUTED_09,  SECP256K1_G_PRE_COMPUTED_10,  SECP256K1_G_PRE_COMPUTED_11,
    SECP256K1_G_PRE_COMPUTED_12,  SECP256K1_G_PRE_COMPUTED_13,  SECP256K1_G_PRE_COMPUTED_14,  SECP256K1_G_PRE_COMPUTED_15,
    SECP256K1_G_PRE_COMPUTED_16,  SECP256K1_G_PRE_COMPUTED_17,  SECP256K1_G_PRE_COMPUTED_18,  SECP256K1_G_PRE_COMPUTED_19,
    SECP256K1_G_PRE_COMPUTED_20,  SECP256K1_G_PRE_COMPUTED_21,  SECP256K1_G_PRE_COMPUTED_22,  SECP256K1_G_PRE_COMPUTED_23,
    SECP256K1_G_PRE_COMPUTED_24,  SECP256K1_G_PRE_COMPUTED_25,  SECP256K1_G_PRE_COMPUTED_26,  SECP256K1_G_PRE_COMPUTED_27,
    SECP256K1_G_PRE_COMPUTED_28,  SECP256K1_G_PRE_COMPUTED_29,  SECP256K1_G_PRE_COMPUTED_30,  SECP256K1_G_PRE_COMPUTED_31,
    SECP256K1_G_PRE_COMPUTED_32,  SECP256K1_G_PRE_COMPUTED_33,  SECP256K1_G_PRE_COMPUTED_34,  SECP256K1_G_PRE_COMPUTED_35,
    SECP256K1_G_PRE_COMPUTED_36,  SECP256K1_G_PRE_COMPUTED_37,  SECP256K1_G_PRE_COMPUTED_38,  SECP256K1_G_PRE_COMPUTED_39,
    SECP256K1_G_PRE_COMPUTED_40,  SECP256K1_G_PRE_COMPUTED_41,  SECP256K1_G_PRE_COMPUTED_42,  SECP256K1_G_PRE_COMPUTED_43,
    SECP256K1_G_PRE_COMPUTED_44,  SECP256K1_G_PRE_COMPUTED_45,  SECP256K1_G_PRE_COMPUTED_46,  SECP256K1_G_PRE_COMPUTED_47,
    SECP256K1_G_PRE_COMPUTED_48,  SECP256K1_G_PRE_COMPUTED_49,  SECP256K1_G_PRE_COMPUTED_50,  SECP256K1_G_PRE_COMPUTED_51,
    SECP256K1_G_PRE_COMPUTED_52,  SECP256K1_G_PRE_COMPUTED_53,  SECP256K1_G_PRE_COMPUTED_54,  SECP256K1_G_PRE_COMPUTED_55,
    SECP256K1_G_PRE_COMPUTED_56,  SECP256K1_G_PRE_COMPUTED_57,  SECP256K1_G_PRE_COMPUTED_58,  SECP256K1_G_PRE_COMPUTED_59,
    SECP256K1_G_PRE_COMPUTED_60,  SECP256K1_G_PRE_COMPUTED_61,  SECP256K1_G_PRE_COMPUTED_62,  SECP256K1_G_PRE_COMPUTED_63,
    SECP256K1_G_PRE_COMPUTED_64,  SECP256K1_G_PRE_COMPUTED_65,  SECP256K1_G_PRE_COMPUTED_66,  SECP256K1_G_PRE_COMPUTED_67,
    SECP256K1_G_PRE_COMPUTED_68,  SECP256K1_G_PRE_COMPUTED_69,  SECP256K1_G_PRE_COMPUTED_70,  SECP256K1_G_PRE_COMPUTED_71,
    SECP256K1_G_PRE_COMPUTED_72,  SECP256K1_G_PRE_COMPUTED_73,  SECP256K1_G_PRE_COMPUTED_74,  SECP256K1_G_PRE_COMPUTED_75,
    SECP256K1_G_PRE_COMPUTED_76,  SECP256K1_G_PRE_COMPUTED_77,  SECP256K1_G_PRE_COMPUTED_78,  SECP256K1_G_PRE_COMPUTED_79,
    SECP256K1_G_PRE_COMPUTED_80,  SECP256K1_G_PRE_COMPUTED_81,  SECP256K1_G_PRE_COMPUTED_82,  SECP256K1_G_PRE_COMPUTED_83,
    SECP256K1_G_PRE_COMPUTED_84,  SECP256K1_G_PRE_COMPUTED_85,  SECP256K1_G_PRE_COMPUTED_86,  SECP256K1_G_PRE_COMPUTED_87,
    SECP256K1_G_PRE_COMPUTED_88,  SECP256K1_G_PRE_COMPUTED_89,  SECP256K1_G_PRE_COMPUTED_90,  SECP256K1_G_PRE_COMPUTED_91,
    SECP256K1_G_PRE_COMPUTED_92,  SECP256K1_G_PRE_COMPUTED_93,  SECP256K1_G_PRE_COMPUTED_94,  SECP256K1_G_PRE_COMPUTED_95,
    SECP256K1_G_PRE_COMPUTED_96,  SECP256K1_G_PRE_COMPUTED_97,  SECP256K1_G_PRE_COMPUTED_98,  SECP256K1_G_PRE_COMPUTED_99,
    SECP256K1_G_PRE_COMPUTED_100, SECP256K1_G_PRE_COMPUTED_101, SECP256K1_G_PRE_COMPUTED_102, SECP256K1_G_PRE_COMPUTED_103,
    SECP256K1_G_PRE_COMPUTED_104, SECP256K1_G_PRE_COMPUTED_105, SECP256K1_G_PRE_COMPUTED_106, SECP256K1_G_PRE_COMPUTED_107,
    SECP256K1_G_PRE_COMPUTED_108, SECP256K1_G_PRE_COMPUTED_109, SECP256K1_G_PRE_COMPUTED_110, SECP256K1_G_PRE_COMPUTED_111,
    SECP256K1_G_PRE_COMPUTED_112, SECP256K1_G_PRE_COMPUTED_113, SECP256K1_G_PRE_COMPUTED_114, SECP256K1_G_PRE_COMPUTED_115,
    SECP256K1_G_PRE_COMPUTED_116, SECP256K1_G_PRE_COMPUTED_117, SECP256K1_G_PRE_COMPUTED_118, SECP256K1_G_PRE_COMPUTED_119,
    SECP256K1_G_PRE_COMPUTED_120, SECP256K1_G_PRE_COMPUTED_121, SECP256K1_G_PRE_COMPUTED_122, SECP256K1_G_PRE_COMPUTED_123,
    SECP256K1_G_PRE_COMPUTED_124, SECP256K1_G_PRE_COMPUTED_125, SECP256K1_G_PRE_COMPUTED_126, SECP256K1_G_PRE_COMPUTED_127,
    SECP256K1_G_PRE_COMPUTED_128, SECP256K1_G_PRE_COMPUTED_129, SECP256K1_G_PRE_COMPUTED_130, SECP256K1_G_PRE_COMPUTED_131,
    SECP256K1_G_PRE_COMPUTED_132, SECP256K1_G_PRE_COMPUTED_133, SECP256K1_G_PRE_COMPUTED_134, SECP256K1_G_PRE_COMPUTED_135,
    SECP256K1_G_PRE_COMPUTED_136, SECP256K1_G_PRE_COMPUTED_137, SECP256K1_G_PRE_COMPUTED_138, SECP256K1_G_PRE_COMPUTED_139,
    SECP256K1_G_PRE_COMPUTED_140, SECP256K1_G_PRE_COMPUTED_141, SECP256K1_G_PRE_COMPUTED_142, SECP256K1_G_PRE_COMPUTED_143,
    SECP256K1_G_PRE_COMPUTED_144, SECP256K1_G_PRE_COMPUTED_145, SECP256K1_G_PRE_COMPUTED_146, SECP256K1_G_PRE_COMPUTED_147,
    SECP256K1_G_PRE_COMPUTED_148, SECP256K1_G_PRE_COMPUTED_149, SECP256K1_G_PRE_COMPUTED_150, SECP256K1_G_PRE_COMPUTED_151,
    SECP256K1_G_PRE_COMPUTED_152, SECP256K1_G_PRE_COMPUTED_153, SECP256K1_G_PRE_COMPUTED_154, SECP256K1_G_PRE_COMPUTED_155,
    SECP256K1_G_PRE_COMPUTED_156, SECP256K1_G_PRE_COMPUTED_157, SECP256K1_G_PRE_COMPUTED_158, SECP256K1_G_PRE_COMPUTED_159,
    SECP256K1_G_PRE_COMPUTED_160, SECP256K1_G_PRE_COMPUTED_161, SECP256K1_G_PRE_COMPUTED_162, SECP256K1_G_PRE_COMPUTED_163,
    SECP256K1_G_PRE_COMPUTED_164, SECP256K1_G_PRE_COMPUTED_165, SECP256K1_G_PRE_COMPUTED_166, SECP256K1_G_PRE_COMPUTED_167,
    SECP256K1_G_PRE_COMPUTED_168, SECP256K1_G_PRE_COMPUTED_169, SECP256K1_G_PRE_COMPUTED_170, SECP256K1_G_PRE_COMPUTED_171,
    SECP256K1_G_PRE_COMPUTED_172, SECP256K1_G_PRE_COMPUTED_173, SECP256K1_G_PRE_COMPUTED_174, SECP256K1_G_PRE_COMPUTED_175,
    SECP256K1_G_PRE_COMPUTED_176, SECP256K1_G_PRE_COMPUTED_177, SECP256K1_G_PRE_COMPUTED_178, SECP256K1_G_PRE_COMPUTED_179,
    SECP256K1_G_PRE_COMPUTED_180, SECP256K1_G_PRE_COMPUTED_181, SECP256K1_G_PRE_COMPUTED_182, SECP256K1_G_PRE_COMPUTED_183,
    SECP256K1_G_PRE_COMPUTED_184, SECP256K1_G_PRE_COMPUTED_185, SECP256K1_G_PRE_COMPUTED_186, SECP256K1_G_PRE_COMPUTED_187,
    SECP256K1_G_PRE_COMPUTED_188, SECP256K1_G_PRE_COMPUTED_189, SECP256K1_G_PRE_COMPUTED_190, SECP256K1_G_PRE_COMPUTED_191,
  };

  for (u64 i = lid; i < SECP256K1_W5_SHMEM_SIZE; i += lsz)
  {
    lm_xy[i] = SECP256K1_G_W5_CONSTANTS[i];
  }

  SYNC_THREADS ();
}

/*
 * Point multiplication using the w=5 precomputed table in shared/local memory.
 * Identical to point_mul_wnaf_w5() but reads the table from lm_xy (LOCAL_AS).
 * Must be preceded by set_precomputed_basepoint_g_w5_lm() in the same workgroup.
 *
 * @param x1    out: x coordinate (8 u32).
 * @param y1    out: y coordinate (8 u32).
 * @param k     in:  256-bit scalar (8 u32).
 * @param lm_xy in:  LOCAL_AS u32[SECP256K1_W5_SHMEM_SIZE] table.
 */
DECLSPEC void point_mul_wnaf_w5_lm (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, LOCAL_AS const u32 *lm_xy)
{
  u32 naf[SECP256K1_NAF_BYTE_SIZE] = { 0 };

  int loop_start = convert_to_wnaf_byte (naf, k);

  const u32 multiplier0 = (naf[loop_start >> 2] >> ((loop_start & 3) << 3)) & 0xff;

  const u32 odd0  = multiplier0 & 1;
  const u32 xp0   = ((multiplier0 - 1 + odd0) >> 1) * 24;
  const u32 yp0   = odd0 ? (xp0 + 8) : (xp0 + 16);

  x1[0] = lm_xy[xp0 + 0];
  x1[1] = lm_xy[xp0 + 1];
  x1[2] = lm_xy[xp0 + 2];
  x1[3] = lm_xy[xp0 + 3];
  x1[4] = lm_xy[xp0 + 4];
  x1[5] = lm_xy[xp0 + 5];
  x1[6] = lm_xy[xp0 + 6];
  x1[7] = lm_xy[xp0 + 7];

  y1[0] = lm_xy[yp0 + 0];
  y1[1] = lm_xy[yp0 + 1];
  y1[2] = lm_xy[yp0 + 2];
  y1[3] = lm_xy[yp0 + 3];
  y1[4] = lm_xy[yp0 + 4];
  y1[5] = lm_xy[yp0 + 5];
  y1[6] = lm_xy[yp0 + 6];
  y1[7] = lm_xy[yp0 + 7];

  u32 z1[8] = { 0 };
  z1[0] = 1;

  for (int pos = loop_start - 1; pos >= 0; pos--)
  {
    point_double (x1, y1, z1);

    const u32 multiplier = (naf[pos >> 2] >> ((pos & 3) << 3)) & 0xff;

    if (multiplier)
    {
      const u32 odd  = multiplier & 1;
      const u32 x_pos = ((multiplier - 1 + odd) >> 1) * 24;
      const u32 y_pos = odd ? (x_pos + 8) : (x_pos + 16);

      u32 x2[8];
      x2[0] = lm_xy[x_pos + 0];
      x2[1] = lm_xy[x_pos + 1];
      x2[2] = lm_xy[x_pos + 2];
      x2[3] = lm_xy[x_pos + 3];
      x2[4] = lm_xy[x_pos + 4];
      x2[5] = lm_xy[x_pos + 5];
      x2[6] = lm_xy[x_pos + 6];
      x2[7] = lm_xy[x_pos + 7];

      u32 y2[8];
      y2[0] = lm_xy[y_pos + 0];
      y2[1] = lm_xy[y_pos + 1];
      y2[2] = lm_xy[y_pos + 2];
      y2[3] = lm_xy[y_pos + 3];
      y2[4] = lm_xy[y_pos + 4];
      y2[5] = lm_xy[y_pos + 5];
      y2[6] = lm_xy[y_pos + 6];
      y2[7] = lm_xy[y_pos + 7];

      point_add (x1, y1, z1, x2, y2);
    }
  }

  inv_mod (z1);

  u32 z2[8];

  mul_mod (z2, z1, z1);
  mul_mod (x1, x1, z2);

  mul_mod (z1, z2, z1);
  mul_mod (y1, y1, z1);
}
