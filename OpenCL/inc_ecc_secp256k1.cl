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
 * AMD-02 note: on GCN 3+ (Polaris and later) and RDNA, the AMD OpenCL
 * compiler recognises the pattern  acc64 = (u64)a32 * (u64)b32 + acc64
 * and emits the native v_mad_u64_u32 instruction (2-cycle fused multiply-add).
 * The three-word accumulator style used here minimises VGPR pressure: only
 * t0, t1, c are live at any one time (3 × u32 = 1.5 VGPRs), well within
 * AMD Polaris's 256-VGPR-per-wave budget.
 *
 * Internal temporaries use the _muladd_ prefix to avoid shadowing any
 * outer variable that might share a common short name.
 *
 * References:
 *   micro-ecc uECC.c (schoolbook multiply)
 *   CudaBrainSecp ptx_macros.cu (carry-chain pattern)
 *   lawliet89/gist (PTX mad.lo/mad.hi pattern, generalised here for u64)
 *   AMD GCN ISA manual: v_mad_u64_u32 (§8.7)
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
 *
 * AMD-04 optimisation: on IS_AMD, use select() builtin so the compiler emits
 * v_cndmask_b32 instructions that read VCC directly — avoiding the mask
 * arithmetic and letting the register allocator keep the carry in VCC.
 */
DECLSPEC void reduce_mod_p (PRIVATE_AS u32 *r, u32 c, PRIVATE_AS const u32 *p_arr)
{
  u32 tmp[8];

  /* Pass 1: subtract p if V = r + c*2^256 >= p */
  {
    const u32 borrow = sub (tmp, r, p_arr);

    /* Select tmp (r-p) when: c > 0 (carry means r+c*2^256 >= p) OR
     * borrow == 0 (r >= p so the subtraction did not underflow).          */
#if defined IS_AMD
    /* AMD: select() emits v_cndmask_b32 / VCC-based conditional-move. */
    const u32 use_tmp = (u32)((c != 0u) | (borrow == 0u));
    r[0] = select (r[0], tmp[0], use_tmp);
    r[1] = select (r[1], tmp[1], use_tmp);
    r[2] = select (r[2], tmp[2], use_tmp);
    r[3] = select (r[3], tmp[3], use_tmp);
    r[4] = select (r[4], tmp[4], use_tmp);
    r[5] = select (r[5], tmp[5], use_tmp);
    r[6] = select (r[6], tmp[6], use_tmp);
    r[7] = select (r[7], tmp[7], use_tmp);

    /* Update carry: if we selected tmp AND sub() wrapped (borrow==1),
     * the wrap-around absorbs one 2^256 unit from c.                    */
    c -= use_tmp & borrow & (u32)(c != 0u);
#else
    const u32 mask   = -(c | (borrow ^ 1u));

    r[0] = (tmp[0] & mask) | (r[0] & ~mask);
    r[1] = (tmp[1] & mask) | (r[1] & ~mask);
    r[2] = (tmp[2] & mask) | (r[2] & ~mask);
    r[3] = (tmp[3] & mask) | (r[3] & ~mask);
    r[4] = (tmp[4] & mask) | (r[4] & ~mask);
    r[5] = (tmp[5] & mask) | (r[5] & ~mask);
    r[6] = (tmp[6] & mask) | (r[6] & ~mask);
    r[7] = (tmp[7] & mask) | (r[7] & ~mask);

    /* Update carry c: when we selected tmp (mask == 0xFFFFFFFF) AND sub() wrapped
     * (borrow == 1, meaning stored r < p), the wrap-around absorbed one "2^256" unit
     * from c, so c must decrease by 1.  Three conditions are AND-ed together:
     *   (mask >> 31)  — 1 iff we selected tmp (subtracted), 0 otherwise
     *   borrow        — 1 iff sub() wrapped (r < p before subtraction)
     *   (c != 0u)     — guard against decrementing an already-zero c
     * When borrow == 0 (r >= p, no wrap), the "true" carry does not change. */
    c -= (mask >> 31) & borrow & (u32)(c != 0u);
#endif
  }

  /* Pass 2: subtract p again if still V >= p (handles c==2 and the c==1,r>=p case) */
  {
    const u32 borrow = sub (tmp, r, p_arr);

#if defined IS_AMD
    const u32 use_tmp = (u32)((c != 0u) | (borrow == 0u));
    r[0] = select (r[0], tmp[0], use_tmp);
    r[1] = select (r[1], tmp[1], use_tmp);
    r[2] = select (r[2], tmp[2], use_tmp);
    r[3] = select (r[3], tmp[3], use_tmp);
    r[4] = select (r[4], tmp[4], use_tmp);
    r[5] = select (r[5], tmp[5], use_tmp);
    r[6] = select (r[6], tmp[6], use_tmp);
    r[7] = select (r[7], tmp[7], use_tmp);
#else
    const u32 mask   = -(c | (borrow ^ 1u));

    r[0] = (tmp[0] & mask) | (r[0] & ~mask);
    r[1] = (tmp[1] & mask) | (r[1] & ~mask);
    r[2] = (tmp[2] & mask) | (r[2] & ~mask);
    r[3] = (tmp[3] & mask) | (r[3] & ~mask);
    r[4] = (tmp[4] & mask) | (r[4] & ~mask);
    r[5] = (tmp[5] & mask) | (r[5] & ~mask);
    r[6] = (tmp[6] & mask) | (r[6] & ~mask);
    r[7] = (tmp[7] & mask) | (r[7] & ~mask);
#endif
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

/*
 * Addition-chain inversion for secp256k1: computes r = a^(p-2) mod p.
 *
 * Uses the same addition chain as bitcoin-core/secp256k1 (src/field_impl.h,
 * secp256k1_fe_inv).  Exploits the long runs of 1-bits in p-2 by
 * pre-computing a^(2^k - 1) for several k values and then assembling the
 * full exponent from those blocks.
 *
 *   p-2 = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D
 *
 * Cost: 255 sqr_mod + 15 mul_mod  (vs. 256 sqr + ~128 mul for generic FLT)
 * Result is written to r[]; a[] is not modified.
 */
DECLSPEC void inv_mod_chain (PRIVATE_AS u32 *r, PRIVATE_AS const u32 *a)
{
  u32 x2[8], x3[8], x6[8], x9[8], x11[8], x22[8];
  u32 x44[8], x88[8], x176[8], x220[8], x223[8], t[8];

  /* x2 = a^(2^2 - 1) = a^3 */
  sqr_mod (x2, a);                        /* a^2          (1 sqr) */
  mul_mod (x2, x2, a);                    /* a^3          (1 mul) */

  /* x3 = a^(2^3 - 1) = a^7 */
  sqr_mod (x3, x2);                       /* a^6          (1 sqr) */
  mul_mod (x3, x3, a);                    /* a^7          (1 mul) */

  /* x6 = a^(2^6 - 1) = a^63 */
  sqr_mod (x6, x3);                       /* a^14 */
  sqr_mod (x6, x6);                       /* a^28 */
  sqr_mod (x6, x6);                       /* a^56         (3 sqr) */
  mul_mod (x6, x6, x3);                   /* a^63         (1 mul) */

  /* x9 = a^(2^9 - 1) = a^511 */
  sqr_mod (x9, x6);                       /* a^126 */
  sqr_mod (x9, x9);                       /* a^252 */
  sqr_mod (x9, x9);                       /* a^504        (3 sqr) */
  mul_mod (x9, x9, x3);                   /* a^511        (1 mul) */

  /* x11 = a^(2^11 - 1) = a^2047 */
  sqr_mod (x11, x9);                      /* a^1022 */
  sqr_mod (x11, x11);                     /* a^2044       (2 sqr) */
  mul_mod (x11, x11, x2);                 /* a^2047       (1 mul) */

  /* x22 = a^(2^22 - 1) */
  sqr_mod (x22, x11);
  #pragma unroll 10
  for (int i = 1; i < 11; i++) sqr_mod (x22, x22);  /* (11 sqr) */
  mul_mod (x22, x22, x11);               /*             (1 mul) */

  /* x44 = a^(2^44 - 1) */
  sqr_mod (x44, x22);
  #pragma unroll 21
  for (int i = 1; i < 22; i++) sqr_mod (x44, x44);  /* (22 sqr) */
  mul_mod (x44, x44, x22);              /*             (1 mul) */

  /* x88 = a^(2^88 - 1) */
  sqr_mod (x88, x44);
  #pragma unroll 43
  for (int i = 1; i < 44; i++) sqr_mod (x88, x88);  /* (44 sqr) */
  mul_mod (x88, x88, x44);             /*             (1 mul) */

  /* x176 = a^(2^176 - 1) */
  sqr_mod (x176, x88);
  #pragma unroll 87
  for (int i = 1; i < 88; i++) sqr_mod (x176, x176); /* (88 sqr) */
  mul_mod (x176, x176, x88);           /*             (1 mul) */

  /* x220 = a^(2^220 - 1) */
  sqr_mod (x220, x176);
  #pragma unroll 43
  for (int i = 1; i < 44; i++) sqr_mod (x220, x220); /* (44 sqr) */
  mul_mod (x220, x220, x44);           /*             (1 mul) */

  /* x223 = a^(2^223 - 1) */
  sqr_mod (x223, x220);
  sqr_mod (x223, x223);
  sqr_mod (x223, x223);                /* (3 sqr) */
  mul_mod (x223, x223, x3);           /*             (1 mul) */

  /*
   * Final assembly — encode the tail bits of p-2 after bit 223.
   *
   * p-2 = 2^256 - 2^32 - 979
   *     = (2^223-1)*2^33 + 2^32 + (2^22-1)*2^11 + ... (tail FC2D)
   *
   * After x223 we encode the remaining exponent via the sequence below,
   * which is derived from the binary pattern of the low 33 bits:
   *   bits 255..223 : (2^223-1) already handled by x223
   *   bit  32       : 0   → one zero in 0xFFFFFFFE limb
   *   bits 31..0    : FC2D = 1111_1100_0000_0000_0010_1101
   *
   * Squaring/multiply sequence (matches libsecp256k1 secp256k1_fe_inv):
   *   sqr×23, mul(x22)  → covers bits 255..233 from x223 + 22-bit block
   *   sqr×5,  mul(a)    → bit pattern ...00001
   *   sqr×3,  mul(x2)   → bit pattern ...011
   *   sqr×2,  mul(a)    → final two bits ...01
   *
   * Total for this section: 23+5+3+2 = 33 sqr + 4 mul
   * Grand total: 255 sqr + 15 mul
   */
  sqr_mod (t, x223);
  #pragma unroll 22
  for (int i = 1; i < 23; i++) sqr_mod (t, t);   /* (23 sqr) */
  mul_mod (t, t, x22);                             /*           (1 mul) */

  #pragma unroll 5
  for (int i = 0; i < 5; i++) sqr_mod (t, t);     /* (5 sqr)  */
  mul_mod (t, t, a);                               /*           (1 mul) */

  sqr_mod (t, t);
  sqr_mod (t, t);
  sqr_mod (t, t);                                  /* (3 sqr)  */
  mul_mod (t, t, x2);                              /*           (1 mul) */

  sqr_mod (t, t);
  sqr_mod (t, t);                                  /* (2 sqr)  */
  mul_mod (r, t, a);                               /*           (1 mul) */
}

/*
 * Optimised modular inverse using the addition chain above.
 * In-place: computes a = a^(p-2) mod p.
 * Cost: 255 sqr_mod + 15 mul_mod.
 */
DECLSPEC void inv_mod (PRIVATE_AS u32 *a)
{
  u32 result[8];
  inv_mod_chain (result, a);
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
 * Generic Fermat inverse (fallback / reference).
 * Computes a = a^(p-2) mod p via 256-iteration square-and-multiply.
 * In-place.  Kept for correctness comparison.
 * Cost: 255 sqr_mod + ~128 mul_mod (average).
 */
DECLSPEC void inv_mod_generic (PRIVATE_AS u32 *a)
{
  /*
   * Fermat's Little Theorem: a^(p-1) ≡ 1 (mod p) for prime p
   * Therefore: a^(-1) ≡ a^(p-2) (mod p)
   *
   * p-2 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D
   *
   * All 256 iterations always execute (constant-time, GPU-friendly).
   */
  u32 exp[8];
  exp[0] = SECP256K1_P0 - 2; /* 0xFFFFFC2F - 2 = 0xFFFFFC2D */
  exp[1] = SECP256K1_P1;     /* 0xFFFFFFFE */
  exp[2] = SECP256K1_P2;     /* 0xFFFFFFFF */
  exp[3] = SECP256K1_P3;     /* 0xFFFFFFFF */
  exp[4] = SECP256K1_P4;     /* 0xFFFFFFFF */
  exp[5] = SECP256K1_P5;     /* 0xFFFFFFFF */
  exp[6] = SECP256K1_P6;     /* 0xFFFFFFFF */
  exp[7] = SECP256K1_P7;     /* 0xFFFFFFFF */

  u32 base[8];
  base[0] = a[0]; base[1] = a[1]; base[2] = a[2]; base[3] = a[3];
  base[4] = a[4]; base[5] = a[5]; base[6] = a[6]; base[7] = a[7];

  u32 result[8] = { 0 };
  result[0] = 1;

  u32 temp[8];

  #pragma unroll 16
  for (u32 bit_idx = 0; bit_idx < 256; bit_idx++)
  {
    u32 limb_idx = bit_idx >> 5;
    u32 bit_pos  = bit_idx & 0x1f;
    u32 bit_set  = (exp[limb_idx] >> bit_pos) & 1;

    mul_mod (temp, result, base);

    u32 mask = -(bit_set);
    result[0] = (temp[0] & mask) | (result[0] & ~mask);
    result[1] = (temp[1] & mask) | (result[1] & ~mask);
    result[2] = (temp[2] & mask) | (result[2] & ~mask);
    result[3] = (temp[3] & mask) | (result[3] & ~mask);
    result[4] = (temp[4] & mask) | (result[4] & ~mask);
    result[5] = (temp[5] & mask) | (result[5] & ~mask);
    result[6] = (temp[6] & mask) | (result[6] & ~mask);
    result[7] = (temp[7] & mask) | (result[7] & ~mask);

    sqr_mod (base, base);
  }

  a[0] = result[0]; a[1] = result[1]; a[2] = result[2]; a[3] = result[3];
  a[4] = result[4]; a[5] = result[5]; a[6] = result[6]; a[7] = result[7];
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

  // Branch-free division by 2 mod p:
  // If t4 is odd, add p (making it even) then shift right 1.
  // mask = 0xffffffff if odd, 0x00000000 if even — no conditional branch.

  u32 t4_odd_mask = (t4[0] & 1u) ? 0xffffffffu : 0u; // 0xffffffff if odd, 0 if even

  u32 t[8];
  t[0] = SECP256K1_P0 & t4_odd_mask;
  t[1] = SECP256K1_P1 & t4_odd_mask;
  t[2] = SECP256K1_P2 & t4_odd_mask;
  t[3] = SECP256K1_P3 & t4_odd_mask;
  t[4] = SECP256K1_P4 & t4_odd_mask;
  t[5] = SECP256K1_P5 & t4_odd_mask;
  t[6] = SECP256K1_P6 & t4_odd_mask;
  t[7] = SECP256K1_P7 & t4_odd_mask;

  u32 c = add (t4, t4, t); // adds p if odd, adds 0 if even

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

  // Branch-free "multiply by 2 mod p" for t6 = 2*t4 mod p:
  // If the MSB of t4 is set, we need to add omega = (0x000003d1, 1) after left-shift.
  // mask = 0xffffffff if MSB set, 0 otherwise — no conditional branch.

  u32 t4_msb_mask = (t4[7] >> 31) ? 0xffffffffu : 0u; // 0xffffffff if MSB set, 0 otherwise

  u32 omega[8] = { 0x000003d1u & t4_msb_mask, 1u & t4_msb_mask, 0u, 0u, 0u, 0u, 0u, 0u };

  add (t6, t6, omega);

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

/*
 * Fill the w=6 precomputed basepoint table (384 u32 words) from compile-time constants.
 * Table layout: 16 odd multiples (1G, 3G, ..., 31G), each stored as (x, y, -y), 8 u32 each.
 * Total: 16 x 3 x 8 = 384 u32 = 1536 bytes.
 */
DECLSPEC void set_precomputed_basepoint_g_w6 (PRIVATE_AS secp256k1_w6_t *r)
{
  r->xy[  0] = SECP256K1_G_W6_PRE_000; r->xy[  1] = SECP256K1_G_W6_PRE_001;
  r->xy[  2] = SECP256K1_G_W6_PRE_002; r->xy[  3] = SECP256K1_G_W6_PRE_003;
  r->xy[  4] = SECP256K1_G_W6_PRE_004; r->xy[  5] = SECP256K1_G_W6_PRE_005;
  r->xy[  6] = SECP256K1_G_W6_PRE_006; r->xy[  7] = SECP256K1_G_W6_PRE_007;
  r->xy[  8] = SECP256K1_G_W6_PRE_008; r->xy[  9] = SECP256K1_G_W6_PRE_009;
  r->xy[ 10] = SECP256K1_G_W6_PRE_010; r->xy[ 11] = SECP256K1_G_W6_PRE_011;
  r->xy[ 12] = SECP256K1_G_W6_PRE_012; r->xy[ 13] = SECP256K1_G_W6_PRE_013;
  r->xy[ 14] = SECP256K1_G_W6_PRE_014; r->xy[ 15] = SECP256K1_G_W6_PRE_015;
  r->xy[ 16] = SECP256K1_G_W6_PRE_016; r->xy[ 17] = SECP256K1_G_W6_PRE_017;
  r->xy[ 18] = SECP256K1_G_W6_PRE_018; r->xy[ 19] = SECP256K1_G_W6_PRE_019;
  r->xy[ 20] = SECP256K1_G_W6_PRE_020; r->xy[ 21] = SECP256K1_G_W6_PRE_021;
  r->xy[ 22] = SECP256K1_G_W6_PRE_022; r->xy[ 23] = SECP256K1_G_W6_PRE_023;
  r->xy[ 24] = SECP256K1_G_W6_PRE_024; r->xy[ 25] = SECP256K1_G_W6_PRE_025;
  r->xy[ 26] = SECP256K1_G_W6_PRE_026; r->xy[ 27] = SECP256K1_G_W6_PRE_027;
  r->xy[ 28] = SECP256K1_G_W6_PRE_028; r->xy[ 29] = SECP256K1_G_W6_PRE_029;
  r->xy[ 30] = SECP256K1_G_W6_PRE_030; r->xy[ 31] = SECP256K1_G_W6_PRE_031;
  r->xy[ 32] = SECP256K1_G_W6_PRE_032; r->xy[ 33] = SECP256K1_G_W6_PRE_033;
  r->xy[ 34] = SECP256K1_G_W6_PRE_034; r->xy[ 35] = SECP256K1_G_W6_PRE_035;
  r->xy[ 36] = SECP256K1_G_W6_PRE_036; r->xy[ 37] = SECP256K1_G_W6_PRE_037;
  r->xy[ 38] = SECP256K1_G_W6_PRE_038; r->xy[ 39] = SECP256K1_G_W6_PRE_039;
  r->xy[ 40] = SECP256K1_G_W6_PRE_040; r->xy[ 41] = SECP256K1_G_W6_PRE_041;
  r->xy[ 42] = SECP256K1_G_W6_PRE_042; r->xy[ 43] = SECP256K1_G_W6_PRE_043;
  r->xy[ 44] = SECP256K1_G_W6_PRE_044; r->xy[ 45] = SECP256K1_G_W6_PRE_045;
  r->xy[ 46] = SECP256K1_G_W6_PRE_046; r->xy[ 47] = SECP256K1_G_W6_PRE_047;
  r->xy[ 48] = SECP256K1_G_W6_PRE_048; r->xy[ 49] = SECP256K1_G_W6_PRE_049;
  r->xy[ 50] = SECP256K1_G_W6_PRE_050; r->xy[ 51] = SECP256K1_G_W6_PRE_051;
  r->xy[ 52] = SECP256K1_G_W6_PRE_052; r->xy[ 53] = SECP256K1_G_W6_PRE_053;
  r->xy[ 54] = SECP256K1_G_W6_PRE_054; r->xy[ 55] = SECP256K1_G_W6_PRE_055;
  r->xy[ 56] = SECP256K1_G_W6_PRE_056; r->xy[ 57] = SECP256K1_G_W6_PRE_057;
  r->xy[ 58] = SECP256K1_G_W6_PRE_058; r->xy[ 59] = SECP256K1_G_W6_PRE_059;
  r->xy[ 60] = SECP256K1_G_W6_PRE_060; r->xy[ 61] = SECP256K1_G_W6_PRE_061;
  r->xy[ 62] = SECP256K1_G_W6_PRE_062; r->xy[ 63] = SECP256K1_G_W6_PRE_063;
  r->xy[ 64] = SECP256K1_G_W6_PRE_064; r->xy[ 65] = SECP256K1_G_W6_PRE_065;
  r->xy[ 66] = SECP256K1_G_W6_PRE_066; r->xy[ 67] = SECP256K1_G_W6_PRE_067;
  r->xy[ 68] = SECP256K1_G_W6_PRE_068; r->xy[ 69] = SECP256K1_G_W6_PRE_069;
  r->xy[ 70] = SECP256K1_G_W6_PRE_070; r->xy[ 71] = SECP256K1_G_W6_PRE_071;
  r->xy[ 72] = SECP256K1_G_W6_PRE_072; r->xy[ 73] = SECP256K1_G_W6_PRE_073;
  r->xy[ 74] = SECP256K1_G_W6_PRE_074; r->xy[ 75] = SECP256K1_G_W6_PRE_075;
  r->xy[ 76] = SECP256K1_G_W6_PRE_076; r->xy[ 77] = SECP256K1_G_W6_PRE_077;
  r->xy[ 78] = SECP256K1_G_W6_PRE_078; r->xy[ 79] = SECP256K1_G_W6_PRE_079;
  r->xy[ 80] = SECP256K1_G_W6_PRE_080; r->xy[ 81] = SECP256K1_G_W6_PRE_081;
  r->xy[ 82] = SECP256K1_G_W6_PRE_082; r->xy[ 83] = SECP256K1_G_W6_PRE_083;
  r->xy[ 84] = SECP256K1_G_W6_PRE_084; r->xy[ 85] = SECP256K1_G_W6_PRE_085;
  r->xy[ 86] = SECP256K1_G_W6_PRE_086; r->xy[ 87] = SECP256K1_G_W6_PRE_087;
  r->xy[ 88] = SECP256K1_G_W6_PRE_088; r->xy[ 89] = SECP256K1_G_W6_PRE_089;
  r->xy[ 90] = SECP256K1_G_W6_PRE_090; r->xy[ 91] = SECP256K1_G_W6_PRE_091;
  r->xy[ 92] = SECP256K1_G_W6_PRE_092; r->xy[ 93] = SECP256K1_G_W6_PRE_093;
  r->xy[ 94] = SECP256K1_G_W6_PRE_094; r->xy[ 95] = SECP256K1_G_W6_PRE_095;
  r->xy[ 96] = SECP256K1_G_W6_PRE_096; r->xy[ 97] = SECP256K1_G_W6_PRE_097;
  r->xy[ 98] = SECP256K1_G_W6_PRE_098; r->xy[ 99] = SECP256K1_G_W6_PRE_099;
  r->xy[100] = SECP256K1_G_W6_PRE_100; r->xy[101] = SECP256K1_G_W6_PRE_101;
  r->xy[102] = SECP256K1_G_W6_PRE_102; r->xy[103] = SECP256K1_G_W6_PRE_103;
  r->xy[104] = SECP256K1_G_W6_PRE_104; r->xy[105] = SECP256K1_G_W6_PRE_105;
  r->xy[106] = SECP256K1_G_W6_PRE_106; r->xy[107] = SECP256K1_G_W6_PRE_107;
  r->xy[108] = SECP256K1_G_W6_PRE_108; r->xy[109] = SECP256K1_G_W6_PRE_109;
  r->xy[110] = SECP256K1_G_W6_PRE_110; r->xy[111] = SECP256K1_G_W6_PRE_111;
  r->xy[112] = SECP256K1_G_W6_PRE_112; r->xy[113] = SECP256K1_G_W6_PRE_113;
  r->xy[114] = SECP256K1_G_W6_PRE_114; r->xy[115] = SECP256K1_G_W6_PRE_115;
  r->xy[116] = SECP256K1_G_W6_PRE_116; r->xy[117] = SECP256K1_G_W6_PRE_117;
  r->xy[118] = SECP256K1_G_W6_PRE_118; r->xy[119] = SECP256K1_G_W6_PRE_119;
  r->xy[120] = SECP256K1_G_W6_PRE_120; r->xy[121] = SECP256K1_G_W6_PRE_121;
  r->xy[122] = SECP256K1_G_W6_PRE_122; r->xy[123] = SECP256K1_G_W6_PRE_123;
  r->xy[124] = SECP256K1_G_W6_PRE_124; r->xy[125] = SECP256K1_G_W6_PRE_125;
  r->xy[126] = SECP256K1_G_W6_PRE_126; r->xy[127] = SECP256K1_G_W6_PRE_127;
  r->xy[128] = SECP256K1_G_W6_PRE_128; r->xy[129] = SECP256K1_G_W6_PRE_129;
  r->xy[130] = SECP256K1_G_W6_PRE_130; r->xy[131] = SECP256K1_G_W6_PRE_131;
  r->xy[132] = SECP256K1_G_W6_PRE_132; r->xy[133] = SECP256K1_G_W6_PRE_133;
  r->xy[134] = SECP256K1_G_W6_PRE_134; r->xy[135] = SECP256K1_G_W6_PRE_135;
  r->xy[136] = SECP256K1_G_W6_PRE_136; r->xy[137] = SECP256K1_G_W6_PRE_137;
  r->xy[138] = SECP256K1_G_W6_PRE_138; r->xy[139] = SECP256K1_G_W6_PRE_139;
  r->xy[140] = SECP256K1_G_W6_PRE_140; r->xy[141] = SECP256K1_G_W6_PRE_141;
  r->xy[142] = SECP256K1_G_W6_PRE_142; r->xy[143] = SECP256K1_G_W6_PRE_143;
  r->xy[144] = SECP256K1_G_W6_PRE_144; r->xy[145] = SECP256K1_G_W6_PRE_145;
  r->xy[146] = SECP256K1_G_W6_PRE_146; r->xy[147] = SECP256K1_G_W6_PRE_147;
  r->xy[148] = SECP256K1_G_W6_PRE_148; r->xy[149] = SECP256K1_G_W6_PRE_149;
  r->xy[150] = SECP256K1_G_W6_PRE_150; r->xy[151] = SECP256K1_G_W6_PRE_151;
  r->xy[152] = SECP256K1_G_W6_PRE_152; r->xy[153] = SECP256K1_G_W6_PRE_153;
  r->xy[154] = SECP256K1_G_W6_PRE_154; r->xy[155] = SECP256K1_G_W6_PRE_155;
  r->xy[156] = SECP256K1_G_W6_PRE_156; r->xy[157] = SECP256K1_G_W6_PRE_157;
  r->xy[158] = SECP256K1_G_W6_PRE_158; r->xy[159] = SECP256K1_G_W6_PRE_159;
  r->xy[160] = SECP256K1_G_W6_PRE_160; r->xy[161] = SECP256K1_G_W6_PRE_161;
  r->xy[162] = SECP256K1_G_W6_PRE_162; r->xy[163] = SECP256K1_G_W6_PRE_163;
  r->xy[164] = SECP256K1_G_W6_PRE_164; r->xy[165] = SECP256K1_G_W6_PRE_165;
  r->xy[166] = SECP256K1_G_W6_PRE_166; r->xy[167] = SECP256K1_G_W6_PRE_167;
  r->xy[168] = SECP256K1_G_W6_PRE_168; r->xy[169] = SECP256K1_G_W6_PRE_169;
  r->xy[170] = SECP256K1_G_W6_PRE_170; r->xy[171] = SECP256K1_G_W6_PRE_171;
  r->xy[172] = SECP256K1_G_W6_PRE_172; r->xy[173] = SECP256K1_G_W6_PRE_173;
  r->xy[174] = SECP256K1_G_W6_PRE_174; r->xy[175] = SECP256K1_G_W6_PRE_175;
  r->xy[176] = SECP256K1_G_W6_PRE_176; r->xy[177] = SECP256K1_G_W6_PRE_177;
  r->xy[178] = SECP256K1_G_W6_PRE_178; r->xy[179] = SECP256K1_G_W6_PRE_179;
  r->xy[180] = SECP256K1_G_W6_PRE_180; r->xy[181] = SECP256K1_G_W6_PRE_181;
  r->xy[182] = SECP256K1_G_W6_PRE_182; r->xy[183] = SECP256K1_G_W6_PRE_183;
  r->xy[184] = SECP256K1_G_W6_PRE_184; r->xy[185] = SECP256K1_G_W6_PRE_185;
  r->xy[186] = SECP256K1_G_W6_PRE_186; r->xy[187] = SECP256K1_G_W6_PRE_187;
  r->xy[188] = SECP256K1_G_W6_PRE_188; r->xy[189] = SECP256K1_G_W6_PRE_189;
  r->xy[190] = SECP256K1_G_W6_PRE_190; r->xy[191] = SECP256K1_G_W6_PRE_191;
  r->xy[192] = SECP256K1_G_W6_PRE_192; r->xy[193] = SECP256K1_G_W6_PRE_193;
  r->xy[194] = SECP256K1_G_W6_PRE_194; r->xy[195] = SECP256K1_G_W6_PRE_195;
  r->xy[196] = SECP256K1_G_W6_PRE_196; r->xy[197] = SECP256K1_G_W6_PRE_197;
  r->xy[198] = SECP256K1_G_W6_PRE_198; r->xy[199] = SECP256K1_G_W6_PRE_199;
  r->xy[200] = SECP256K1_G_W6_PRE_200; r->xy[201] = SECP256K1_G_W6_PRE_201;
  r->xy[202] = SECP256K1_G_W6_PRE_202; r->xy[203] = SECP256K1_G_W6_PRE_203;
  r->xy[204] = SECP256K1_G_W6_PRE_204; r->xy[205] = SECP256K1_G_W6_PRE_205;
  r->xy[206] = SECP256K1_G_W6_PRE_206; r->xy[207] = SECP256K1_G_W6_PRE_207;
  r->xy[208] = SECP256K1_G_W6_PRE_208; r->xy[209] = SECP256K1_G_W6_PRE_209;
  r->xy[210] = SECP256K1_G_W6_PRE_210; r->xy[211] = SECP256K1_G_W6_PRE_211;
  r->xy[212] = SECP256K1_G_W6_PRE_212; r->xy[213] = SECP256K1_G_W6_PRE_213;
  r->xy[214] = SECP256K1_G_W6_PRE_214; r->xy[215] = SECP256K1_G_W6_PRE_215;
  r->xy[216] = SECP256K1_G_W6_PRE_216; r->xy[217] = SECP256K1_G_W6_PRE_217;
  r->xy[218] = SECP256K1_G_W6_PRE_218; r->xy[219] = SECP256K1_G_W6_PRE_219;
  r->xy[220] = SECP256K1_G_W6_PRE_220; r->xy[221] = SECP256K1_G_W6_PRE_221;
  r->xy[222] = SECP256K1_G_W6_PRE_222; r->xy[223] = SECP256K1_G_W6_PRE_223;
  r->xy[224] = SECP256K1_G_W6_PRE_224; r->xy[225] = SECP256K1_G_W6_PRE_225;
  r->xy[226] = SECP256K1_G_W6_PRE_226; r->xy[227] = SECP256K1_G_W6_PRE_227;
  r->xy[228] = SECP256K1_G_W6_PRE_228; r->xy[229] = SECP256K1_G_W6_PRE_229;
  r->xy[230] = SECP256K1_G_W6_PRE_230; r->xy[231] = SECP256K1_G_W6_PRE_231;
  r->xy[232] = SECP256K1_G_W6_PRE_232; r->xy[233] = SECP256K1_G_W6_PRE_233;
  r->xy[234] = SECP256K1_G_W6_PRE_234; r->xy[235] = SECP256K1_G_W6_PRE_235;
  r->xy[236] = SECP256K1_G_W6_PRE_236; r->xy[237] = SECP256K1_G_W6_PRE_237;
  r->xy[238] = SECP256K1_G_W6_PRE_238; r->xy[239] = SECP256K1_G_W6_PRE_239;
  r->xy[240] = SECP256K1_G_W6_PRE_240; r->xy[241] = SECP256K1_G_W6_PRE_241;
  r->xy[242] = SECP256K1_G_W6_PRE_242; r->xy[243] = SECP256K1_G_W6_PRE_243;
  r->xy[244] = SECP256K1_G_W6_PRE_244; r->xy[245] = SECP256K1_G_W6_PRE_245;
  r->xy[246] = SECP256K1_G_W6_PRE_246; r->xy[247] = SECP256K1_G_W6_PRE_247;
  r->xy[248] = SECP256K1_G_W6_PRE_248; r->xy[249] = SECP256K1_G_W6_PRE_249;
  r->xy[250] = SECP256K1_G_W6_PRE_250; r->xy[251] = SECP256K1_G_W6_PRE_251;
  r->xy[252] = SECP256K1_G_W6_PRE_252; r->xy[253] = SECP256K1_G_W6_PRE_253;
  r->xy[254] = SECP256K1_G_W6_PRE_254; r->xy[255] = SECP256K1_G_W6_PRE_255;
  r->xy[256] = SECP256K1_G_W6_PRE_256; r->xy[257] = SECP256K1_G_W6_PRE_257;
  r->xy[258] = SECP256K1_G_W6_PRE_258; r->xy[259] = SECP256K1_G_W6_PRE_259;
  r->xy[260] = SECP256K1_G_W6_PRE_260; r->xy[261] = SECP256K1_G_W6_PRE_261;
  r->xy[262] = SECP256K1_G_W6_PRE_262; r->xy[263] = SECP256K1_G_W6_PRE_263;
  r->xy[264] = SECP256K1_G_W6_PRE_264; r->xy[265] = SECP256K1_G_W6_PRE_265;
  r->xy[266] = SECP256K1_G_W6_PRE_266; r->xy[267] = SECP256K1_G_W6_PRE_267;
  r->xy[268] = SECP256K1_G_W6_PRE_268; r->xy[269] = SECP256K1_G_W6_PRE_269;
  r->xy[270] = SECP256K1_G_W6_PRE_270; r->xy[271] = SECP256K1_G_W6_PRE_271;
  r->xy[272] = SECP256K1_G_W6_PRE_272; r->xy[273] = SECP256K1_G_W6_PRE_273;
  r->xy[274] = SECP256K1_G_W6_PRE_274; r->xy[275] = SECP256K1_G_W6_PRE_275;
  r->xy[276] = SECP256K1_G_W6_PRE_276; r->xy[277] = SECP256K1_G_W6_PRE_277;
  r->xy[278] = SECP256K1_G_W6_PRE_278; r->xy[279] = SECP256K1_G_W6_PRE_279;
  r->xy[280] = SECP256K1_G_W6_PRE_280; r->xy[281] = SECP256K1_G_W6_PRE_281;
  r->xy[282] = SECP256K1_G_W6_PRE_282; r->xy[283] = SECP256K1_G_W6_PRE_283;
  r->xy[284] = SECP256K1_G_W6_PRE_284; r->xy[285] = SECP256K1_G_W6_PRE_285;
  r->xy[286] = SECP256K1_G_W6_PRE_286; r->xy[287] = SECP256K1_G_W6_PRE_287;
  r->xy[288] = SECP256K1_G_W6_PRE_288; r->xy[289] = SECP256K1_G_W6_PRE_289;
  r->xy[290] = SECP256K1_G_W6_PRE_290; r->xy[291] = SECP256K1_G_W6_PRE_291;
  r->xy[292] = SECP256K1_G_W6_PRE_292; r->xy[293] = SECP256K1_G_W6_PRE_293;
  r->xy[294] = SECP256K1_G_W6_PRE_294; r->xy[295] = SECP256K1_G_W6_PRE_295;
  r->xy[296] = SECP256K1_G_W6_PRE_296; r->xy[297] = SECP256K1_G_W6_PRE_297;
  r->xy[298] = SECP256K1_G_W6_PRE_298; r->xy[299] = SECP256K1_G_W6_PRE_299;
  r->xy[300] = SECP256K1_G_W6_PRE_300; r->xy[301] = SECP256K1_G_W6_PRE_301;
  r->xy[302] = SECP256K1_G_W6_PRE_302; r->xy[303] = SECP256K1_G_W6_PRE_303;
  r->xy[304] = SECP256K1_G_W6_PRE_304; r->xy[305] = SECP256K1_G_W6_PRE_305;
  r->xy[306] = SECP256K1_G_W6_PRE_306; r->xy[307] = SECP256K1_G_W6_PRE_307;
  r->xy[308] = SECP256K1_G_W6_PRE_308; r->xy[309] = SECP256K1_G_W6_PRE_309;
  r->xy[310] = SECP256K1_G_W6_PRE_310; r->xy[311] = SECP256K1_G_W6_PRE_311;
  r->xy[312] = SECP256K1_G_W6_PRE_312; r->xy[313] = SECP256K1_G_W6_PRE_313;
  r->xy[314] = SECP256K1_G_W6_PRE_314; r->xy[315] = SECP256K1_G_W6_PRE_315;
  r->xy[316] = SECP256K1_G_W6_PRE_316; r->xy[317] = SECP256K1_G_W6_PRE_317;
  r->xy[318] = SECP256K1_G_W6_PRE_318; r->xy[319] = SECP256K1_G_W6_PRE_319;
  r->xy[320] = SECP256K1_G_W6_PRE_320; r->xy[321] = SECP256K1_G_W6_PRE_321;
  r->xy[322] = SECP256K1_G_W6_PRE_322; r->xy[323] = SECP256K1_G_W6_PRE_323;
  r->xy[324] = SECP256K1_G_W6_PRE_324; r->xy[325] = SECP256K1_G_W6_PRE_325;
  r->xy[326] = SECP256K1_G_W6_PRE_326; r->xy[327] = SECP256K1_G_W6_PRE_327;
  r->xy[328] = SECP256K1_G_W6_PRE_328; r->xy[329] = SECP256K1_G_W6_PRE_329;
  r->xy[330] = SECP256K1_G_W6_PRE_330; r->xy[331] = SECP256K1_G_W6_PRE_331;
  r->xy[332] = SECP256K1_G_W6_PRE_332; r->xy[333] = SECP256K1_G_W6_PRE_333;
  r->xy[334] = SECP256K1_G_W6_PRE_334; r->xy[335] = SECP256K1_G_W6_PRE_335;
  r->xy[336] = SECP256K1_G_W6_PRE_336; r->xy[337] = SECP256K1_G_W6_PRE_337;
  r->xy[338] = SECP256K1_G_W6_PRE_338; r->xy[339] = SECP256K1_G_W6_PRE_339;
  r->xy[340] = SECP256K1_G_W6_PRE_340; r->xy[341] = SECP256K1_G_W6_PRE_341;
  r->xy[342] = SECP256K1_G_W6_PRE_342; r->xy[343] = SECP256K1_G_W6_PRE_343;
  r->xy[344] = SECP256K1_G_W6_PRE_344; r->xy[345] = SECP256K1_G_W6_PRE_345;
  r->xy[346] = SECP256K1_G_W6_PRE_346; r->xy[347] = SECP256K1_G_W6_PRE_347;
  r->xy[348] = SECP256K1_G_W6_PRE_348; r->xy[349] = SECP256K1_G_W6_PRE_349;
  r->xy[350] = SECP256K1_G_W6_PRE_350; r->xy[351] = SECP256K1_G_W6_PRE_351;
  r->xy[352] = SECP256K1_G_W6_PRE_352; r->xy[353] = SECP256K1_G_W6_PRE_353;
  r->xy[354] = SECP256K1_G_W6_PRE_354; r->xy[355] = SECP256K1_G_W6_PRE_355;
  r->xy[356] = SECP256K1_G_W6_PRE_356; r->xy[357] = SECP256K1_G_W6_PRE_357;
  r->xy[358] = SECP256K1_G_W6_PRE_358; r->xy[359] = SECP256K1_G_W6_PRE_359;
  r->xy[360] = SECP256K1_G_W6_PRE_360; r->xy[361] = SECP256K1_G_W6_PRE_361;
  r->xy[362] = SECP256K1_G_W6_PRE_362; r->xy[363] = SECP256K1_G_W6_PRE_363;
  r->xy[364] = SECP256K1_G_W6_PRE_364; r->xy[365] = SECP256K1_G_W6_PRE_365;
  r->xy[366] = SECP256K1_G_W6_PRE_366; r->xy[367] = SECP256K1_G_W6_PRE_367;
  r->xy[368] = SECP256K1_G_W6_PRE_368; r->xy[369] = SECP256K1_G_W6_PRE_369;
  r->xy[370] = SECP256K1_G_W6_PRE_370; r->xy[371] = SECP256K1_G_W6_PRE_371;
  r->xy[372] = SECP256K1_G_W6_PRE_372; r->xy[373] = SECP256K1_G_W6_PRE_373;
  r->xy[374] = SECP256K1_G_W6_PRE_374; r->xy[375] = SECP256K1_G_W6_PRE_375;
  r->xy[376] = SECP256K1_G_W6_PRE_376; r->xy[377] = SECP256K1_G_W6_PRE_377;
  r->xy[378] = SECP256K1_G_W6_PRE_378; r->xy[379] = SECP256K1_G_W6_PRE_379;
  r->xy[380] = SECP256K1_G_W6_PRE_380; r->xy[381] = SECP256K1_G_W6_PRE_381;
  r->xy[382] = SECP256K1_G_W6_PRE_382; r->xy[383] = SECP256K1_G_W6_PRE_383;
}

/*
 * Scalar multiplication using w=6 wNAF with the PRIVATE_AS precomputed table.
 * Table: 16 odd multiples (1G, 3G, ..., 31G), each (x, y, -y) x 8 u32.
 * Uses byte-packed NAF from convert_to_wnaf_byte().
 */
DECLSPEC void point_mul_wnaf_w6 (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, SECP256K1_TMPS_TYPE const secp256k1_w6_t *tmps)
{
  u32 naf[SECP256K1_NAF_BYTE_SIZE] = { 0 };

  int loop_start = convert_to_wnaf_byte (naf, k);

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

  inv_mod (z1);

  u32 z2[8];

  mul_mod (z2, z1, z1);
  mul_mod (x1, x1, z2);

  mul_mod (z1, z2, z1);
  mul_mod (y1, y1, z1);
}

/*
 * Fill the w=6 precomputed basepoint table (384 u32 words) into shared/local memory.
 * All threads in the workgroup must call this function cooperatively.
 * A SYNC_THREADS() barrier is issued at the end.
 *
 * @param lm_xy  out: LOCAL_AS u32 array of size SECP256K1_W6_SHMEM_SIZE (384 words).
 * @param lid    in:  get_local_id(0).
 * @param lsz    in:  get_local_size(0).
 */
DECLSPEC void set_precomputed_basepoint_g_w6_lm (LOCAL_AS u32 *lm_xy, const u64 lid, const u64 lsz)
{
  const u32 SECP256K1_G_W6_CONSTANTS[384] = {
    SECP256K1_G_W6_PRE_000, SECP256K1_G_W6_PRE_001, SECP256K1_G_W6_PRE_002, SECP256K1_G_W6_PRE_003,
    SECP256K1_G_W6_PRE_004, SECP256K1_G_W6_PRE_005, SECP256K1_G_W6_PRE_006, SECP256K1_G_W6_PRE_007,
    SECP256K1_G_W6_PRE_008, SECP256K1_G_W6_PRE_009, SECP256K1_G_W6_PRE_010, SECP256K1_G_W6_PRE_011,
    SECP256K1_G_W6_PRE_012, SECP256K1_G_W6_PRE_013, SECP256K1_G_W6_PRE_014, SECP256K1_G_W6_PRE_015,
    SECP256K1_G_W6_PRE_016, SECP256K1_G_W6_PRE_017, SECP256K1_G_W6_PRE_018, SECP256K1_G_W6_PRE_019,
    SECP256K1_G_W6_PRE_020, SECP256K1_G_W6_PRE_021, SECP256K1_G_W6_PRE_022, SECP256K1_G_W6_PRE_023,
    SECP256K1_G_W6_PRE_024, SECP256K1_G_W6_PRE_025, SECP256K1_G_W6_PRE_026, SECP256K1_G_W6_PRE_027,
    SECP256K1_G_W6_PRE_028, SECP256K1_G_W6_PRE_029, SECP256K1_G_W6_PRE_030, SECP256K1_G_W6_PRE_031,
    SECP256K1_G_W6_PRE_032, SECP256K1_G_W6_PRE_033, SECP256K1_G_W6_PRE_034, SECP256K1_G_W6_PRE_035,
    SECP256K1_G_W6_PRE_036, SECP256K1_G_W6_PRE_037, SECP256K1_G_W6_PRE_038, SECP256K1_G_W6_PRE_039,
    SECP256K1_G_W6_PRE_040, SECP256K1_G_W6_PRE_041, SECP256K1_G_W6_PRE_042, SECP256K1_G_W6_PRE_043,
    SECP256K1_G_W6_PRE_044, SECP256K1_G_W6_PRE_045, SECP256K1_G_W6_PRE_046, SECP256K1_G_W6_PRE_047,
    SECP256K1_G_W6_PRE_048, SECP256K1_G_W6_PRE_049, SECP256K1_G_W6_PRE_050, SECP256K1_G_W6_PRE_051,
    SECP256K1_G_W6_PRE_052, SECP256K1_G_W6_PRE_053, SECP256K1_G_W6_PRE_054, SECP256K1_G_W6_PRE_055,
    SECP256K1_G_W6_PRE_056, SECP256K1_G_W6_PRE_057, SECP256K1_G_W6_PRE_058, SECP256K1_G_W6_PRE_059,
    SECP256K1_G_W6_PRE_060, SECP256K1_G_W6_PRE_061, SECP256K1_G_W6_PRE_062, SECP256K1_G_W6_PRE_063,
    SECP256K1_G_W6_PRE_064, SECP256K1_G_W6_PRE_065, SECP256K1_G_W6_PRE_066, SECP256K1_G_W6_PRE_067,
    SECP256K1_G_W6_PRE_068, SECP256K1_G_W6_PRE_069, SECP256K1_G_W6_PRE_070, SECP256K1_G_W6_PRE_071,
    SECP256K1_G_W6_PRE_072, SECP256K1_G_W6_PRE_073, SECP256K1_G_W6_PRE_074, SECP256K1_G_W6_PRE_075,
    SECP256K1_G_W6_PRE_076, SECP256K1_G_W6_PRE_077, SECP256K1_G_W6_PRE_078, SECP256K1_G_W6_PRE_079,
    SECP256K1_G_W6_PRE_080, SECP256K1_G_W6_PRE_081, SECP256K1_G_W6_PRE_082, SECP256K1_G_W6_PRE_083,
    SECP256K1_G_W6_PRE_084, SECP256K1_G_W6_PRE_085, SECP256K1_G_W6_PRE_086, SECP256K1_G_W6_PRE_087,
    SECP256K1_G_W6_PRE_088, SECP256K1_G_W6_PRE_089, SECP256K1_G_W6_PRE_090, SECP256K1_G_W6_PRE_091,
    SECP256K1_G_W6_PRE_092, SECP256K1_G_W6_PRE_093, SECP256K1_G_W6_PRE_094, SECP256K1_G_W6_PRE_095,
    SECP256K1_G_W6_PRE_096, SECP256K1_G_W6_PRE_097, SECP256K1_G_W6_PRE_098, SECP256K1_G_W6_PRE_099,
    SECP256K1_G_W6_PRE_100, SECP256K1_G_W6_PRE_101, SECP256K1_G_W6_PRE_102, SECP256K1_G_W6_PRE_103,
    SECP256K1_G_W6_PRE_104, SECP256K1_G_W6_PRE_105, SECP256K1_G_W6_PRE_106, SECP256K1_G_W6_PRE_107,
    SECP256K1_G_W6_PRE_108, SECP256K1_G_W6_PRE_109, SECP256K1_G_W6_PRE_110, SECP256K1_G_W6_PRE_111,
    SECP256K1_G_W6_PRE_112, SECP256K1_G_W6_PRE_113, SECP256K1_G_W6_PRE_114, SECP256K1_G_W6_PRE_115,
    SECP256K1_G_W6_PRE_116, SECP256K1_G_W6_PRE_117, SECP256K1_G_W6_PRE_118, SECP256K1_G_W6_PRE_119,
    SECP256K1_G_W6_PRE_120, SECP256K1_G_W6_PRE_121, SECP256K1_G_W6_PRE_122, SECP256K1_G_W6_PRE_123,
    SECP256K1_G_W6_PRE_124, SECP256K1_G_W6_PRE_125, SECP256K1_G_W6_PRE_126, SECP256K1_G_W6_PRE_127,
    SECP256K1_G_W6_PRE_128, SECP256K1_G_W6_PRE_129, SECP256K1_G_W6_PRE_130, SECP256K1_G_W6_PRE_131,
    SECP256K1_G_W6_PRE_132, SECP256K1_G_W6_PRE_133, SECP256K1_G_W6_PRE_134, SECP256K1_G_W6_PRE_135,
    SECP256K1_G_W6_PRE_136, SECP256K1_G_W6_PRE_137, SECP256K1_G_W6_PRE_138, SECP256K1_G_W6_PRE_139,
    SECP256K1_G_W6_PRE_140, SECP256K1_G_W6_PRE_141, SECP256K1_G_W6_PRE_142, SECP256K1_G_W6_PRE_143,
    SECP256K1_G_W6_PRE_144, SECP256K1_G_W6_PRE_145, SECP256K1_G_W6_PRE_146, SECP256K1_G_W6_PRE_147,
    SECP256K1_G_W6_PRE_148, SECP256K1_G_W6_PRE_149, SECP256K1_G_W6_PRE_150, SECP256K1_G_W6_PRE_151,
    SECP256K1_G_W6_PRE_152, SECP256K1_G_W6_PRE_153, SECP256K1_G_W6_PRE_154, SECP256K1_G_W6_PRE_155,
    SECP256K1_G_W6_PRE_156, SECP256K1_G_W6_PRE_157, SECP256K1_G_W6_PRE_158, SECP256K1_G_W6_PRE_159,
    SECP256K1_G_W6_PRE_160, SECP256K1_G_W6_PRE_161, SECP256K1_G_W6_PRE_162, SECP256K1_G_W6_PRE_163,
    SECP256K1_G_W6_PRE_164, SECP256K1_G_W6_PRE_165, SECP256K1_G_W6_PRE_166, SECP256K1_G_W6_PRE_167,
    SECP256K1_G_W6_PRE_168, SECP256K1_G_W6_PRE_169, SECP256K1_G_W6_PRE_170, SECP256K1_G_W6_PRE_171,
    SECP256K1_G_W6_PRE_172, SECP256K1_G_W6_PRE_173, SECP256K1_G_W6_PRE_174, SECP256K1_G_W6_PRE_175,
    SECP256K1_G_W6_PRE_176, SECP256K1_G_W6_PRE_177, SECP256K1_G_W6_PRE_178, SECP256K1_G_W6_PRE_179,
    SECP256K1_G_W6_PRE_180, SECP256K1_G_W6_PRE_181, SECP256K1_G_W6_PRE_182, SECP256K1_G_W6_PRE_183,
    SECP256K1_G_W6_PRE_184, SECP256K1_G_W6_PRE_185, SECP256K1_G_W6_PRE_186, SECP256K1_G_W6_PRE_187,
    SECP256K1_G_W6_PRE_188, SECP256K1_G_W6_PRE_189, SECP256K1_G_W6_PRE_190, SECP256K1_G_W6_PRE_191,
    SECP256K1_G_W6_PRE_192, SECP256K1_G_W6_PRE_193, SECP256K1_G_W6_PRE_194, SECP256K1_G_W6_PRE_195,
    SECP256K1_G_W6_PRE_196, SECP256K1_G_W6_PRE_197, SECP256K1_G_W6_PRE_198, SECP256K1_G_W6_PRE_199,
    SECP256K1_G_W6_PRE_200, SECP256K1_G_W6_PRE_201, SECP256K1_G_W6_PRE_202, SECP256K1_G_W6_PRE_203,
    SECP256K1_G_W6_PRE_204, SECP256K1_G_W6_PRE_205, SECP256K1_G_W6_PRE_206, SECP256K1_G_W6_PRE_207,
    SECP256K1_G_W6_PRE_208, SECP256K1_G_W6_PRE_209, SECP256K1_G_W6_PRE_210, SECP256K1_G_W6_PRE_211,
    SECP256K1_G_W6_PRE_212, SECP256K1_G_W6_PRE_213, SECP256K1_G_W6_PRE_214, SECP256K1_G_W6_PRE_215,
    SECP256K1_G_W6_PRE_216, SECP256K1_G_W6_PRE_217, SECP256K1_G_W6_PRE_218, SECP256K1_G_W6_PRE_219,
    SECP256K1_G_W6_PRE_220, SECP256K1_G_W6_PRE_221, SECP256K1_G_W6_PRE_222, SECP256K1_G_W6_PRE_223,
    SECP256K1_G_W6_PRE_224, SECP256K1_G_W6_PRE_225, SECP256K1_G_W6_PRE_226, SECP256K1_G_W6_PRE_227,
    SECP256K1_G_W6_PRE_228, SECP256K1_G_W6_PRE_229, SECP256K1_G_W6_PRE_230, SECP256K1_G_W6_PRE_231,
    SECP256K1_G_W6_PRE_232, SECP256K1_G_W6_PRE_233, SECP256K1_G_W6_PRE_234, SECP256K1_G_W6_PRE_235,
    SECP256K1_G_W6_PRE_236, SECP256K1_G_W6_PRE_237, SECP256K1_G_W6_PRE_238, SECP256K1_G_W6_PRE_239,
    SECP256K1_G_W6_PRE_240, SECP256K1_G_W6_PRE_241, SECP256K1_G_W6_PRE_242, SECP256K1_G_W6_PRE_243,
    SECP256K1_G_W6_PRE_244, SECP256K1_G_W6_PRE_245, SECP256K1_G_W6_PRE_246, SECP256K1_G_W6_PRE_247,
    SECP256K1_G_W6_PRE_248, SECP256K1_G_W6_PRE_249, SECP256K1_G_W6_PRE_250, SECP256K1_G_W6_PRE_251,
    SECP256K1_G_W6_PRE_252, SECP256K1_G_W6_PRE_253, SECP256K1_G_W6_PRE_254, SECP256K1_G_W6_PRE_255,
    SECP256K1_G_W6_PRE_256, SECP256K1_G_W6_PRE_257, SECP256K1_G_W6_PRE_258, SECP256K1_G_W6_PRE_259,
    SECP256K1_G_W6_PRE_260, SECP256K1_G_W6_PRE_261, SECP256K1_G_W6_PRE_262, SECP256K1_G_W6_PRE_263,
    SECP256K1_G_W6_PRE_264, SECP256K1_G_W6_PRE_265, SECP256K1_G_W6_PRE_266, SECP256K1_G_W6_PRE_267,
    SECP256K1_G_W6_PRE_268, SECP256K1_G_W6_PRE_269, SECP256K1_G_W6_PRE_270, SECP256K1_G_W6_PRE_271,
    SECP256K1_G_W6_PRE_272, SECP256K1_G_W6_PRE_273, SECP256K1_G_W6_PRE_274, SECP256K1_G_W6_PRE_275,
    SECP256K1_G_W6_PRE_276, SECP256K1_G_W6_PRE_277, SECP256K1_G_W6_PRE_278, SECP256K1_G_W6_PRE_279,
    SECP256K1_G_W6_PRE_280, SECP256K1_G_W6_PRE_281, SECP256K1_G_W6_PRE_282, SECP256K1_G_W6_PRE_283,
    SECP256K1_G_W6_PRE_284, SECP256K1_G_W6_PRE_285, SECP256K1_G_W6_PRE_286, SECP256K1_G_W6_PRE_287,
    SECP256K1_G_W6_PRE_288, SECP256K1_G_W6_PRE_289, SECP256K1_G_W6_PRE_290, SECP256K1_G_W6_PRE_291,
    SECP256K1_G_W6_PRE_292, SECP256K1_G_W6_PRE_293, SECP256K1_G_W6_PRE_294, SECP256K1_G_W6_PRE_295,
    SECP256K1_G_W6_PRE_296, SECP256K1_G_W6_PRE_297, SECP256K1_G_W6_PRE_298, SECP256K1_G_W6_PRE_299,
    SECP256K1_G_W6_PRE_300, SECP256K1_G_W6_PRE_301, SECP256K1_G_W6_PRE_302, SECP256K1_G_W6_PRE_303,
    SECP256K1_G_W6_PRE_304, SECP256K1_G_W6_PRE_305, SECP256K1_G_W6_PRE_306, SECP256K1_G_W6_PRE_307,
    SECP256K1_G_W6_PRE_308, SECP256K1_G_W6_PRE_309, SECP256K1_G_W6_PRE_310, SECP256K1_G_W6_PRE_311,
    SECP256K1_G_W6_PRE_312, SECP256K1_G_W6_PRE_313, SECP256K1_G_W6_PRE_314, SECP256K1_G_W6_PRE_315,
    SECP256K1_G_W6_PRE_316, SECP256K1_G_W6_PRE_317, SECP256K1_G_W6_PRE_318, SECP256K1_G_W6_PRE_319,
    SECP256K1_G_W6_PRE_320, SECP256K1_G_W6_PRE_321, SECP256K1_G_W6_PRE_322, SECP256K1_G_W6_PRE_323,
    SECP256K1_G_W6_PRE_324, SECP256K1_G_W6_PRE_325, SECP256K1_G_W6_PRE_326, SECP256K1_G_W6_PRE_327,
    SECP256K1_G_W6_PRE_328, SECP256K1_G_W6_PRE_329, SECP256K1_G_W6_PRE_330, SECP256K1_G_W6_PRE_331,
    SECP256K1_G_W6_PRE_332, SECP256K1_G_W6_PRE_333, SECP256K1_G_W6_PRE_334, SECP256K1_G_W6_PRE_335,
    SECP256K1_G_W6_PRE_336, SECP256K1_G_W6_PRE_337, SECP256K1_G_W6_PRE_338, SECP256K1_G_W6_PRE_339,
    SECP256K1_G_W6_PRE_340, SECP256K1_G_W6_PRE_341, SECP256K1_G_W6_PRE_342, SECP256K1_G_W6_PRE_343,
    SECP256K1_G_W6_PRE_344, SECP256K1_G_W6_PRE_345, SECP256K1_G_W6_PRE_346, SECP256K1_G_W6_PRE_347,
    SECP256K1_G_W6_PRE_348, SECP256K1_G_W6_PRE_349, SECP256K1_G_W6_PRE_350, SECP256K1_G_W6_PRE_351,
    SECP256K1_G_W6_PRE_352, SECP256K1_G_W6_PRE_353, SECP256K1_G_W6_PRE_354, SECP256K1_G_W6_PRE_355,
    SECP256K1_G_W6_PRE_356, SECP256K1_G_W6_PRE_357, SECP256K1_G_W6_PRE_358, SECP256K1_G_W6_PRE_359,
    SECP256K1_G_W6_PRE_360, SECP256K1_G_W6_PRE_361, SECP256K1_G_W6_PRE_362, SECP256K1_G_W6_PRE_363,
    SECP256K1_G_W6_PRE_364, SECP256K1_G_W6_PRE_365, SECP256K1_G_W6_PRE_366, SECP256K1_G_W6_PRE_367,
    SECP256K1_G_W6_PRE_368, SECP256K1_G_W6_PRE_369, SECP256K1_G_W6_PRE_370, SECP256K1_G_W6_PRE_371,
    SECP256K1_G_W6_PRE_372, SECP256K1_G_W6_PRE_373, SECP256K1_G_W6_PRE_374, SECP256K1_G_W6_PRE_375,
    SECP256K1_G_W6_PRE_376, SECP256K1_G_W6_PRE_377, SECP256K1_G_W6_PRE_378, SECP256K1_G_W6_PRE_379,
    SECP256K1_G_W6_PRE_380, SECP256K1_G_W6_PRE_381, SECP256K1_G_W6_PRE_382, SECP256K1_G_W6_PRE_383,
  };

  for (u64 i = lid; i < SECP256K1_W6_SHMEM_SIZE; i += lsz)
  {
    lm_xy[i] = SECP256K1_G_W6_CONSTANTS[i];
  }

  SYNC_THREADS ();
}

/*
 * Point multiplication using the w=6 precomputed table in shared/local memory.
 * Identical to point_mul_wnaf_w6() but reads the table from lm_xy (LOCAL_AS).
 * Must be preceded by set_precomputed_basepoint_g_w6_lm() in the same workgroup.
 */
DECLSPEC void point_mul_wnaf_w6_lm (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS const u32 *k, LOCAL_AS const u32 *lm_xy)
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

/*
 * GLV + wNAF w=5 scalar multiplication (Straus simultaneous method).
 *
 * Decomposes k = k1 + k2*lambda (mod n) using GLV endomorphism, then
 * simultaneously processes wNAF representations of |k1| and |k2|.
 * phi(P) = (beta*Px mod p, Py) applied to each precomputed point.
 *
 * Estimated cost: ~128 doublings + ~44 additions vs ~256 + ~51 for standard w=4.
 *
 * @param rx    out: x coordinate of k*G (8 u32).
 * @param ry    out: y coordinate of k*G (8 u32).
 * @param k     in:  256-bit scalar (8 u32 little-endian).
 * @param tmps  in:  w=5 precomputed table (secp256k1_w5_t).
 */
DECLSPEC void point_mul_glv_wnaf_w5 (PRIVATE_AS u32 *rx, PRIVATE_AS u32 *ry,
                                      PRIVATE_AS const u32 *k,
                                      SECP256K1_TMPS_TYPE const secp256k1_w5_t *tmps)
{
  /* Decompose k into k1, k2 using GLV Babai rounding. */
  u32 k1v[6]; /* [0..4] = magnitude, [5] = sign */
  u32 k2v[6];

  glv_decompose (k, k1v, k2v);

  /* Compute wNAF representations of |k1| and |k2|.
   * glv_decompose stores the magnitude in k1v[0..4], sign in k1v[5].
   * Build an 8-word scalar from the 5-word magnitude. */
  u32 k1_scalar[8] = { k1v[0], k1v[1], k1v[2], k1v[3], k1v[4], 0, 0, 0 };
  u32 k2_scalar[8] = { k2v[0], k2v[1], k2v[2], k2v[3], k2v[4], 0, 0, 0 };

  u32 naf1[SECP256K1_NAF_BYTE_SIZE] = { 0 };
  u32 naf2[SECP256K1_NAF_BYTE_SIZE] = { 0 };

  int loop1 = convert_to_wnaf_byte (naf1, k1_scalar);
  int loop2 = convert_to_wnaf_byte (naf2, k2_scalar);

  int loop_start = loop1 > loop2 ? loop1 : loop2;

  /* Load beta constant for phi(G) = (beta * Gx mod p, Gy). */
  u32 beta[8];
  beta[0] = SECP256K1_BETA0;
  beta[1] = SECP256K1_BETA1;
  beta[2] = SECP256K1_BETA2;
  beta[3] = SECP256K1_BETA3;
  beta[4] = SECP256K1_BETA4;
  beta[5] = SECP256K1_BETA5;
  beta[6] = SECP256K1_BETA6;
  beta[7] = SECP256K1_BETA7;

  /* Initialize accumulator; first non-zero digit sets it. */
  u32 rx_j[8], ry_j[8], rz_j[8];
  u32 initialized = 0;

  for (int pos = loop_start; pos >= 0; pos--)
  {
    if (initialized)
    {
      point_double (rx_j, ry_j, rz_j);
    }

    const u32 d1 = (naf1[pos >> 2] >> ((pos & 3) << 3)) & 0xff;
    const u32 d2 = (naf2[pos >> 2] >> ((pos & 3) << 3)) & 0xff;

    if (d1)
    {
      const u32 odd1 = d1 & 1;
      const u32 xp1  = ((d1 - 1 + odd1) >> 1) * 24;
      /* odd1==1: positive digit; negate if k1 sign is negative (k1v[5]==1) */
      u32 yp1;
      if ((odd1 == 1) != (k1v[5] == 0))
        yp1 = xp1 + 16; /* use -y */
      else
        yp1 = xp1 + 8;  /* use +y */

      u32 x2[8], y2[8];
      for (u32 i = 0; i < 8; i++) x2[i] = tmps->xy[xp1 + i];
      for (u32 i = 0; i < 8; i++) y2[i] = tmps->xy[yp1 + i];

      if (!initialized)
      {
        for (u32 i = 0; i < 8; i++) rx_j[i] = x2[i];
        for (u32 i = 0; i < 8; i++) ry_j[i] = y2[i];
        rz_j[0] = 1; for (u32 i = 1; i < 8; i++) rz_j[i] = 0;
        initialized = 1;
      }
      else
      {
        point_add (rx_j, ry_j, rz_j, x2, y2);
      }
    }

    if (d2)
    {
      const u32 odd2 = d2 & 1;
      const u32 xp2  = ((d2 - 1 + odd2) >> 1) * 24;
      u32 yp2;
      if ((odd2 == 1) != (k2v[5] == 0))
        yp2 = xp2 + 16;
      else
        yp2 = xp2 + 8;

      /* phi(P): multiply x by beta, keep y unchanged. */
      u32 base_x[8];
      for (u32 i = 0; i < 8; i++) base_x[i] = tmps->xy[xp2 + i];
      u32 phi_px[8], phi_py[8];
      mul_mod_ptx (phi_px, beta, base_x);
      for (u32 i = 0; i < 8; i++) phi_py[i] = tmps->xy[yp2 + i];

      if (!initialized)
      {
        for (u32 i = 0; i < 8; i++) rx_j[i] = phi_px[i];
        for (u32 i = 0; i < 8; i++) ry_j[i] = phi_py[i];
        rz_j[0] = 1; for (u32 i = 1; i < 8; i++) rz_j[i] = 0;
        initialized = 1;
      }
      else
      {
        point_add (rx_j, ry_j, rz_j, phi_px, phi_py);
      }
    }
  }

  /* Convert Jacobian to affine. */
  inv_mod (rz_j);

  u32 rz2[8];
  mul_mod (rz2, rz_j, rz_j);
  mul_mod (rx, rx_j, rz2);
  mul_mod (rz2, rz2, rz_j);
  mul_mod (ry, ry_j, rz2);
}

DECLSPEC void point_add_affine_G (PRIVATE_AS u32 *x1, PRIVATE_AS u32 *y1, PRIVATE_AS u32 *z1)
{
  /* Add the generator point G (affine) to the Jacobian point (x1:y1:z1).
   * G is stored as compile-time constants SECP256K1_G0..G7 (x) and
   * SECP256K1_G_PRE_COMPUTED_08..15 (y).
   * This is a thin wrapper around point_add() for use in Group Key Addition:
   * P_{i+1} = P_i + G.  Typical cost: ~2K GPU cycles vs ~194K for full point_mul. */
  u32 gx[8];
  gx[0] = SECP256K1_G0;
  gx[1] = SECP256K1_G1;
  gx[2] = SECP256K1_G2;
  gx[3] = SECP256K1_G3;
  gx[4] = SECP256K1_G4;
  gx[5] = SECP256K1_G5;
  gx[6] = SECP256K1_G6;
  gx[7] = SECP256K1_G7;

  u32 gy[8];
  gy[0] = SECP256K1_G_PRE_COMPUTED_08;
  gy[1] = SECP256K1_G_PRE_COMPUTED_09;
  gy[2] = SECP256K1_G_PRE_COMPUTED_10;
  gy[3] = SECP256K1_G_PRE_COMPUTED_11;
  gy[4] = SECP256K1_G_PRE_COMPUTED_12;
  gy[5] = SECP256K1_G_PRE_COMPUTED_13;
  gy[6] = SECP256K1_G_PRE_COMPUTED_14;
  gy[7] = SECP256K1_G_PRE_COMPUTED_15;

  point_add (x1, y1, z1, gx, gy);
}

DECLSPEC void point_double_xyzz (PRIVATE_AS u32 *X, PRIVATE_AS u32 *Y,
                                  PRIVATE_AS u32 *ZZ, PRIVATE_AS u32 *ZZZ)
{
  /* XYZZ point doubling for short Weierstrass curves with a=0 (secp256k1).
   * Formula: dbl-2008-s-1 from https://hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html
   * Cost: 1M + 5S + add + 2*2 + 1*3 + 1*4 + 1*8 (cheapest ops not counted).
   * Saves squarings vs Jacobian: 1M+5S here vs 1M+8S for dbl-2009-l Jacobian. */

  u32 U[8];
  add_mod (U, Y, Y);             /* U = 2*Y1 */

  u32 V[8];
  mul_mod (V, U, U);             /* V = U^2 = 4*Y1^2 */

  u32 W[8];
  mul_mod (W, U, V);             /* W = U*V = 8*Y1^3 */

  u32 S[8];
  mul_mod (S, X, V);             /* S = X1*V = 4*X1*Y1^2 */

  u32 M[8];
  mul_mod (M, X, X);             /* X1^2 */
  u32 M3[8];
  add_mod (M3, M, M);
  add_mod (M3, M3, M);           /* M = 3*X1^2 (a=0 so no ZZ term) */

  u32 S2[8];
  add_mod (S2, S, S);            /* 2*S */

  mul_mod (X, M3, M3);
  sub_mod (X, X, S2);
  sub_mod (X, X, S2);            /* X3 = M^2 - 2*S */

  u32 tmp[8];
  sub_mod (tmp, S, X);
  mul_mod (tmp, M3, tmp);        /* M3*(S-X3) */
  u32 WY[8];
  mul_mod (WY, W, Y);            /* W*Y1 */
  sub_mod (Y, tmp, WY);          /* Y3 = M*(S-X3) - W*Y1 */

  for (u32 i = 0; i < 8; i++) ZZ[i]  = V[i];   /* ZZ3 = V */
  for (u32 i = 0; i < 8; i++) ZZZ[i] = W[i];   /* ZZZ3 = W */
}

DECLSPEC void point_add_mixed_xyzz (PRIVATE_AS u32 *X1, PRIVATE_AS u32 *Y1,
                                     PRIVATE_AS u32 *ZZ1, PRIVATE_AS u32 *ZZZ1,
                                     PRIVATE_AS const u32 *x2, PRIVATE_AS const u32 *y2)
{
  /* XYZZ mixed addition: XYZZ point + affine point (z2=1, ZZ2=1, ZZZ2=1).
   * Formula: madd-2008-s from https://hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html
   * Cost: 7M + 4S + 9add + 3*2 + 1*4 (cheapest ops not counted). */

  u32 U2[8];
  mul_mod (U2, x2, ZZ1);         /* U2 = x2*ZZ1 */

  u32 S2[8];
  mul_mod (S2, y2, ZZZ1);        /* S2 = y2*ZZZ1 */

  u32 P[8];
  sub_mod (P, U2, X1);           /* P = U2 - X1 */

  u32 PP[8];
  mul_mod (PP, P, P);            /* PP = P^2 */

  u32 PPP[8];
  mul_mod (PPP, P, PP);          /* PPP = P*PP */

  u32 Q[8];
  mul_mod (Q, X1, PP);           /* Q = X1*PP */

  u32 R[8];
  sub_mod (R, S2, Y1);           /* R = S2 - Y1 */

  u32 Q2[8];
  add_mod (Q2, Q, Q);            /* 2*Q */

  u32 R2[8];
  mul_mod (R2, R, R);            /* R^2 */
  sub_mod (X1, R2, PPP);
  sub_mod (X1, X1, Q2);          /* X3 = R^2 - PPP - 2*Q */

  u32 tmp[8];
  sub_mod (tmp, Q, X1);
  mul_mod (tmp, R, tmp);         /* R*(Q-X3) */
  u32 Y1PPP[8];
  mul_mod (Y1PPP, Y1, PPP);      /* Y1*PPP */
  sub_mod (Y1, tmp, Y1PPP);      /* Y3 = R*(Q-X3) - Y1*PPP */

  mul_mod (ZZ1,  ZZ1,  PP);      /* ZZ3  = ZZ1*PP */
  mul_mod (ZZZ1, ZZZ1, PPP);     /* ZZZ3 = ZZZ1*PPP */
}

#ifdef SECP256K1_USE_COMB
DECLSPEC void point_mul_comb (PRIVATE_AS u32 *rx, PRIVATE_AS u32 *ry,
                               PRIVATE_AS const u32 *k)
{
  /* Fixed-base comb scalar multiplication using precomputed table for G.
   * d=4 (4 rows/teeth), w=64 (64 columns).  The 256-bit scalar k is split
   * into 4 64-bit sub-scalars k0..k3 (bits 0..63, 64..127, 128..191, 192..255).
   * Comb table T[i] = (i[0])*G + (i[1])*2^64*G + (i[2])*2^128*G + (i[3])*2^192*G,
   *   i = 0..15.  T[0] = identity (never accessed in non-trivial scalar).
   * Algorithm: for col = 63 downto 0:
   *   R = 2*R
   *   idx = k0[col] | (k1[col]<<1) | (k2[col]<<2) | (k3[col]<<3)
   *   if idx != 0: R += T[idx]
   * Total cost: 63 doublings + up to 64 point additions. */

  /* ---- comb table T[1..15]: (x, y) stored as 16 u32 words per point ---- */
  /* x words: [0]=low 32 bits .. [7]=high 32 bits; then y words same order  */
  const u32 comb_table[15][16] =
  {
    /* T[1]  = 1*G */
    { 0x16f81798, 0x59f2815b, 0x2dce28d9, 0x029bfcdb, 0xce870b07, 0x55a06295, 0xf9dcbbac, 0x79be667e,
      0xfb10d4b8, 0x9c47d08f, 0xa6855419, 0xfd17b448, 0x0e1108a8, 0x5da4fbfc, 0x26a3c465, 0x483ada77 },
    /* T[2]  = 2^64*G */
    { 0x42d0e6bd, 0x13b7e0e7, 0xdb0f5e53, 0xf774d163, 0x104d6ecb, 0x82a2147c, 0x243c4e25, 0x3322d401,
      0x6c28b2a0, 0x24f3a2e9, 0xa2873af6, 0x2805f63e, 0x4ddaf9b7, 0xbfb019bc, 0xe9664ef5, 0x56e70797 },
    /* T[3]  = G + 2^64*G */
    { 0x829d122a, 0xdca81127, 0x67e99549, 0x8f17f314, 0x6a8a9e73, 0x9b889085, 0x846dd99d, 0x583fdfd9,
      0x63c4eac4, 0xf3c7719e, 0xb734b37a, 0xb44685a3, 0x572a47a6, 0x9f92d2d6, 0x2ff57d81, 0xabc6232f },
    /* T[4]  = 2^128*G */
    { 0x9ec4c0da, 0x1b7b444c, 0x723ea335, 0xe88c5678, 0x981f162e, 0x9239c1ad, 0xf63b5f33, 0x8f68b9d2,
      0x501fff82, 0xf23cbf79, 0x95510bfd, 0xbbea2cfe, 0xb6be215d, 0xde1d90c2, 0xba063986, 0x662a9f2d },
    /* T[5]  = G + 2^128*G */
    { 0x114cbf09, 0x63c5e885, 0x7be77e3e, 0x2f27ce93, 0xf54a3e33, 0xdaa6d12d, 0x3eff872c, 0x8b300e51,
      0xb3b10a39, 0x26c6ff28, 0x9aaf7169, 0x08f6a7aa, 0x6b8238ea, 0x446f0d46, 0x7f43c0cc, 0x1cec3067 },
    /* T[6]  = 2^64*G + 2^128*G */
    { 0x075e9070, 0xba16ce6a, 0x9b5cfe37, 0xbc26893d, 0x9c510774, 0xe1ddadfe, 0xfe3ae2f4, 0x90922d88,
      0x5c08824a, 0x653943cc, 0xfce8f4bc, 0x06d74475, 0x533c615d, 0x8d101fa7, 0x742108a9, 0x7b1903f6 },
    /* T[7]  = G + 2^64*G + 2^128*G */
    { 0x6ebdc96c, 0x1bcfa45c, 0x1c7584ba, 0xe400bc04, 0x74cf531f, 0x6395e20e, 0xc5131b30, 0x1edd0bb1,
      0xe358cf9e, 0xa117161b, 0x2724d11c, 0xe490d6f0, 0xee6dd8c9, 0xf75062f6, 0xfba373e4, 0x31e03b2b },
    /* T[8]  = 2^192*G */
    { 0x2120e2b3, 0x7f3b58fa, 0x7f47f9aa, 0x7a58fdce, 0x4ce6e521, 0xe7be4ae3, 0x1f51bdba, 0xeaa649f2,
      0xba5ad93d, 0xd47a5305, 0xf13f7e59, 0x01a6b965, 0x9879aa5a, 0xc69a80f8, 0x5bbbb03a, 0xbe3279ed },
    /* T[9]  = G + 2^192*G */
    { 0x27bb4d71, 0xcf291a33, 0x33524832, 0x6caf7d6b, 0x766584ee, 0x6e0ee131, 0xd064c589, 0x160cb0f6,
      0x17136e8d, 0x9d5de554, 0x1aab720e, 0xe3f2d468, 0xccf75cc2, 0xd1378b49, 0xc4ff16e1, 0x6920c375 },
    /* T[10] = 2^64*G + 2^192*G */
    { 0x1a9ee611, 0x3eef9e96, 0x9cc37faf, 0xfe4d7bf3, 0xb321d965, 0x462aa9b3, 0x208736c5, 0x1702da3e,
      0x3a545ceb, 0xfba57bbf, 0x7ea858f5, 0x6dbcd766, 0x680d92f1, 0x088e897c, 0xbc626c80, 0x468c1fd8 },
    /* T[11] = G + 2^64*G + 2^192*G */
    { 0xb188660a, 0xb40f85c7, 0x99bc3c36, 0xc5873c19, 0x7f33b54c, 0x3c7b4541, 0x1f8c9bf8, 0x4cd3a93c,
      0x33099cb0, 0xf8dce380, 0x2edd2f33, 0x7a167dd6, 0x0ffe35b7, 0x576d8987, 0xc68ace5c, 0xd2de0386 },
    /* T[12] = 2^128*G + 2^192*G */
    { 0x6658bb08, 0x9a9e0a72, 0xc589607b, 0xe23c5f2a, 0xf2bfb4c8, 0xa048ca14, 0xc62c2291, 0x4d9a0f89,
      0x0f827294, 0x427b5f31, 0x9f2c35cd, 0x1ea7a8b5, 0x85a3c00f, 0x95442e56, 0x9b57975a, 0x8cb83121 },
    /* T[13] = G + 2^128*G + 2^192*G */
    { 0x51f5cf67, 0x4333f0da, 0xf4f0d3cb, 0x6d3ea47c, 0xa05a831f, 0x442fda14, 0x016d3e81, 0x6a496013,
      0xe52e0f48, 0xf647318c, 0x4a0d5ff1, 0x5ff3a66e, 0x61199ba8, 0x046ed81a, 0x3e79c23a, 0x578edf08 },
    /* T[14] = 2^64*G + 2^128*G + 2^192*G */
    { 0x3ea01ea7, 0xb8f996f8, 0x7497bb15, 0xc0045d33, 0x6205647c, 0xc4749dc9, 0x0efd22c9, 0xd8946054,
      0x12774ad5, 0x062dcb09, 0x8be06e3a, 0xcb13f310, 0x235de1a9, 0xca281d35, 0x69c3645c, 0xaf8a7412 },
    /* T[15] = G + 2^64*G + 2^128*G + 2^192*G */
    { 0xbeb8b1e2, 0x8808ca5f, 0xea0dda76, 0x0262b204, 0xddeb356b, 0xb6fffffc, 0xfbb83870, 0x52de253a,
      0x8f8d21ea, 0x961f40c0, 0x002f03ed, 0x89686278, 0x38e421ea, 0x0ff834d7, 0xd36fb8db, 0x3a270d6f }
  };

  /* Initialize accumulator to "infinity" by tracking `initialized` flag. */
  u32 acc_x[8] = { 0 };
  u32 acc_y[8] = { 0 };
  u32 acc_z[8] = { 0 };
  u32 initialized = 0;

  /* Process 64 columns, high bit first. */
  for (int col = 63; col >= 0; col--)
  {
    /* Double the accumulator. */
    if (initialized)
    {
      point_double (acc_x, acc_y, acc_z);
    }

    /* Build the 4-bit column index.
     * k0 = bits  0..63  of k -> k[0], k[1]
     * k1 = bits 64..127 of k -> k[2], k[3]
     * k2 = bits128..191 of k -> k[4], k[5]
     * k3 = bits192..255 of k -> k[6], k[7]  */
    const u32 word0 = (u32)(col >> 5);   /* which u32 word (0 or 1) within each 64-bit band */
    const u32 bit0  = (u32)(col & 31);

    const u32 b0 = (k[word0    ] >> bit0) & 1;
    const u32 b1 = (k[word0 + 2] >> bit0) & 1;
    const u32 b2 = (k[word0 + 4] >> bit0) & 1;
    const u32 b3 = (k[word0 + 6] >> bit0) & 1;

    const u32 idx = b0 | (b1 << 1) | (b2 << 2) | (b3 << 3);

    if (idx != 0)
    {
      u32 tx[8], ty[8];
      for (u32 i = 0; i < 8; i++) tx[i] = comb_table[idx - 1][i];
      for (u32 i = 0; i < 8; i++) ty[i] = comb_table[idx - 1][i + 8];

      if (!initialized)
      {
        for (u32 i = 0; i < 8; i++) acc_x[i] = tx[i];
        for (u32 i = 0; i < 8; i++) acc_y[i] = ty[i];
        acc_z[0] = 1;
        for (u32 i = 1; i < 8; i++) acc_z[i] = 0;
        initialized = 1;
      }
      else
      {
        point_add (acc_x, acc_y, acc_z, tx, ty);
      }
    }
  }

  /* Convert Jacobian to affine. */
  inv_mod (acc_z);
  u32 acc_z2[8];
  mul_mod (acc_z2, acc_z, acc_z);
  mul_mod (rx, acc_x, acc_z2);
  mul_mod (acc_z2, acc_z2, acc_z);
  mul_mod (ry, acc_y, acc_z2);
}
#endif /* SECP256K1_USE_COMB */
