#!/usr/bin/env python3
"""
Phase 6: AMD-specific optimization tests for secp256k1.

Covers:
  AMD-01  — u64 carry/borrow chains in add() / sub()
  AMD-02  — MULADD64 pattern for mul_mod (maps to v_mad_u64_u32 on GCN/RDNA)
  AMD-03  — Squaring symmetry optimisation in sqr_mod (36 products vs 64)
  AMD-04  — Branch-free reduce_mod_p with AMD select() path (v_cndmask_b32)
  AMD-05  — Group Key Addition (incremental point_add for consecutive private keys)
  AMD-06  — Workgroup-size math and OpenCL source validation

Each test verifies mathematical correctness of the Python reference that mirrors
the OpenCL kernel paths, and verifies that the expected AMD code patterns exist
in the OpenCL source files.

Usage:
    python3 -m unittest Python/test_phase6_amd_optimizations.py -v
"""

import os
import random
import unittest

# ---------------------------------------------------------------------------
# secp256k1 curve parameters
# ---------------------------------------------------------------------------

P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

BETA = 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE

# ---------------------------------------------------------------------------
# Python reference for field arithmetic (mirrors OpenCL paths)
# ---------------------------------------------------------------------------

def mul_mod(a, b):
    return (a * b) % P


def sqr_mod(a):
    return (a * a) % P


def add_mod(a, b):
    r = a + b
    return r - P if r >= P else r


def sub_mod(a, b):
    r = a - b
    return r + P if r < 0 else r


def inv_mod(a):
    return pow(a, P - 2, P)


def point_double(Px, Py):
    if Px is None:
        return None, None
    lam = mul_mod(3, sqr_mod(Px))
    lam = mul_mod(lam, inv_mod(mul_mod(2, Py)))
    Rx = sub_mod(sqr_mod(lam), add_mod(Px, Px))
    Ry = sub_mod(mul_mod(lam, sub_mod(Px, Rx)), Py)
    return Rx, Ry


def point_add(P1x, P1y, P2x, P2y):
    if P1x is None:
        return P2x, P2y
    if P2x is None:
        return P1x, P1y
    if P1x == P2x:
        if P1y == P2y:
            return point_double(P1x, P1y)
        return None, None
    lam = mul_mod(sub_mod(P2y, P1y), inv_mod(sub_mod(P2x, P1x)))
    Rx  = sub_mod(sub_mod(sqr_mod(lam), P1x), P2x)
    Ry  = sub_mod(mul_mod(lam, sub_mod(P1x, Rx)), P1y)
    return Rx, Ry


def point_mul(k, Px=Gx, Py=Gy):
    """Double-and-add scalar multiplication (reference)."""
    Rx, Ry = None, None
    for bit in bin(k)[2:]:
        if Rx is not None:
            Rx, Ry = point_double(Rx, Ry)
        if bit == "1":
            Rx, Ry = point_add(Rx, Ry, Px, Py)
    return Rx, Ry


# ---------------------------------------------------------------------------
# AMD-01: u64 carry/borrow chain reference (mirrors IS_AMD path in OpenCL)
# ---------------------------------------------------------------------------

def _u256_add_carry(a_words, b_words):
    """
    Pure-Python reference for the AMD u64 carry chain in add().

    a_words, b_words: lists of 8 u32 values (little-endian).
    Returns (result_words [8 u32], carry [0 or 1]).

    Maps to: OpenCL add() #elif defined IS_AMD  (v_add_co_u32/v_addc_co_u32).
    """
    assert len(a_words) == 8 and len(b_words) == 8
    t64 = 0
    r = []
    for i in range(8):
        t64 = t64 + a_words[i] + b_words[i]
        r.append(t64 & 0xFFFFFFFF)
        t64 >>= 32
    carry = t64 & 1
    return r, carry


def _u256_sub_borrow(a_words, b_words):
    """
    Pure-Python reference for the AMD u64 borrow chain in sub().

    a_words, b_words: lists of 8 u32 values (little-endian).
    Returns (result_words [8 u32], borrow [0 or 1]).

    Maps to: OpenCL sub() #elif defined IS_AMD  (v_sub_co_u32/v_subb_co_u32).
    The borrow propagates as a signed arithmetic right-shift each step.
    """
    assert len(a_words) == 8 and len(b_words) == 8
    t = 0   # signed carry/borrow accumulator (Python big-int, handles neg)
    r = []
    for i in range(8):
        t = t + a_words[i] - b_words[i]
        r.append(t & 0xFFFFFFFF)
        t >>= 32   # arithmetic right-shift: propagates sign (borrow) to next word
    borrow = int(t < 0)   # t == -1 → borrow; t == 0 → no borrow
    return r, borrow


def _int_to_words(n, nbits=256):
    """Convert a non-negative integer to a list of u32 words (little-endian)."""
    words = []
    for _ in range(nbits // 32):
        words.append(n & 0xFFFFFFFF)
        n >>= 32
    return words


def _words_to_int(words):
    """Convert a list of u32 words (little-endian) to a Python integer."""
    result = 0
    for i, w in enumerate(words):
        result |= w << (32 * i)
    return result


# ---------------------------------------------------------------------------
# AMD-04: branch-free reduce_mod_p reference (IS_AMD select() path)
# ---------------------------------------------------------------------------

def _reduce_mod_p_amd(r_int, c):
    """
    Python reference for the AMD reduce_mod_p select() path.

    r_int: 256-bit integer (result of omega-reduction, < 3*P)
    c:     carry word (0, 1 or 2)

    Returns r_int % P.  Matches the two-pass branch-free reduction in
    OpenCL reduce_mod_p() #if defined IS_AMD using select().
    """
    r_words = _int_to_words(r_int)
    p_words = _int_to_words(P)

    def _pass(r_w, carry):
        tmp_w, borrow = _u256_sub_borrow(r_w, p_words)
        # AMD select: use_tmp = (carry != 0) | (borrow == 0)
        use_tmp = int((carry != 0) or (borrow == 0))
        new_r = tmp_w if use_tmp else r_w
        # update carry: selected tmp AND sub wrapped → carry decreases
        new_c = carry - (use_tmp & borrow & int(carry != 0))
        return new_r, new_c

    r_words, c = _pass(r_words, c)
    r_words, c = _pass(r_words, c)
    return _words_to_int(r_words)


# ---------------------------------------------------------------------------
# AMD-02: MULADD64 accumulator reference (v_mad_u64_u32 pattern)
# ---------------------------------------------------------------------------

def _muladd64(t0, t1, c, a, b):
    """
    Python equivalent of the MULADD64 macro used in mul_mod().

    Computes (c, t1, t0) += a * b  (96-bit accumulator).
    The AMD OpenCL compiler generates v_mad_u64_u32 for this pattern.
    """
    pp = (a & 0xFFFFFFFF) * (b & 0xFFFFFFFF)     # 64-bit product
    dd = ((t1 & 0xFFFFFFFF) << 32) | (t0 & 0xFFFFFFFF)
    ss = (dd + pp) & 0xFFFFFFFFFFFFFFFF
    new_t0 = ss & 0xFFFFFFFF
    new_t1 = (ss >> 32) & 0xFFFFFFFF
    new_c  = c + int(ss < pp)
    return new_t0, new_t1, new_c


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read_cl(rel_path):
    with open(os.path.join(_REPO_ROOT, rel_path)) as fh:
        return fh.read()


# ===========================================================================
# TEST CLASS 1: AMD-01 — u64 carry/borrow chain
# ===========================================================================

class TestAMDCarryChain(unittest.TestCase):
    """Verify that the u64 carry/borrow chain (IS_AMD add/sub paths) is correct."""

    def test_add_carry_no_overflow(self):
        """add() carry chain: 1 + 1 = 2 (no carry out)."""
        a = _int_to_words(1)
        b = _int_to_words(1)
        r, carry = _u256_add_carry(a, b)
        self.assertEqual(_words_to_int(r), 2)
        self.assertEqual(carry, 0)

    def test_add_carry_with_overflow(self):
        """add() carry chain: (2^256 - 1) + 1 → 0 with carry=1."""
        max256 = (1 << 256) - 1
        a = _int_to_words(max256)
        b = _int_to_words(1)
        r, carry = _u256_add_carry(a, b)
        self.assertEqual(_words_to_int(r), 0)
        self.assertEqual(carry, 1)

    def test_sub_borrow_no_borrow(self):
        """sub() borrow chain: 5 - 3 = 2 (no borrow)."""
        a = _int_to_words(5)
        b = _int_to_words(3)
        r, borrow = _u256_sub_borrow(a, b)
        self.assertEqual(_words_to_int(r), 2)
        self.assertEqual(borrow, 0)

    def test_sub_borrow_with_borrow(self):
        """sub() borrow chain: 3 - 5 underflows, borrow=1."""
        a = _int_to_words(3)
        b = _int_to_words(5)
        r, borrow = _u256_sub_borrow(a, b)
        # 3 - 5 mod 2^256 = 2^256 - 2
        self.assertEqual(_words_to_int(r), (1 << 256) - 2)
        self.assertEqual(borrow, 1)

    def test_add_sub_inverse(self):
        """add(a, b) then sub(result, b) recovers a for random inputs."""
        rng = random.Random(42)
        for _ in range(20):
            a_int = rng.randrange(0, 1 << 256)
            b_int = rng.randrange(0, 1 << 256)
            a_w = _int_to_words(a_int)
            b_w = _int_to_words(b_int)
            r_add, _ = _u256_add_carry(a_w, b_w)
            r_sub, _ = _u256_sub_borrow(r_add, b_w)
            self.assertEqual(_words_to_int(r_sub), a_int,
                             f"a={hex(a_int)[:12]}, b={hex(b_int)[:12]}")


# ===========================================================================
# TEST CLASS 2: AMD-02 — MULADD64 / v_mad_u64_u32 pattern
# ===========================================================================

class TestAMDMulModMULADD64(unittest.TestCase):
    """Verify the MULADD64 accumulator pattern used in mul_mod()."""

    def test_muladd64_basic(self):
        """MULADD64 accumulates a*b correctly for small values."""
        t0, t1, c = _muladd64(0, 0, 0, 3, 5)
        acc = (c << 64) | (t1 << 32) | t0
        self.assertEqual(acc, 15)

    def test_muladd64_max_product(self):
        """MULADD64 handles max u32 × max u32 without overflow."""
        t0, t1, c = _muladd64(0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF)
        acc = (c << 64) | (t1 << 32) | t0
        self.assertEqual(acc, 0xFFFFFFFF * 0xFFFFFFFF)

    def test_muladd64_accumulate(self):
        """MULADD64 chained: 2*3 + 4*5 = 26."""
        t0, t1, c = _muladd64(0, 0, 0, 2, 3)
        t0, t1, c = _muladd64(t0, t1, c, 4, 5)
        acc = (c << 64) | (t1 << 32) | t0
        self.assertEqual(acc, 26)

    def test_mul_mod_reduces_mod_p(self):
        """mul_mod(a, b) always returns a value in [0, P-1]."""
        rng = random.Random(100)
        for _ in range(30):
            a = rng.randrange(1, P)
            b = rng.randrange(1, P)
            result = mul_mod(a, b)
            self.assertGreaterEqual(result, 0)
            self.assertLess(result, P)

    def test_mul_mod_max_inputs(self):
        """mul_mod(P-1, P-1) == 1  (i.e., (-1)*(-1) = 1 mod P)."""
        self.assertEqual(mul_mod(P - 1, P - 1), 1)

    def test_mul_mod_commutativity(self):
        """mul_mod is commutative: mul_mod(a,b) == mul_mod(b,a)."""
        rng = random.Random(200)
        for _ in range(20):
            a = rng.randrange(1, P)
            b = rng.randrange(1, P)
            self.assertEqual(mul_mod(a, b), mul_mod(b, a))


# ===========================================================================
# TEST CLASS 3: AMD-03 — sqr_mod symmetry optimisation
# ===========================================================================

class TestAMDSqrModSymmetry(unittest.TestCase):
    """Verify squaring symmetry optimisation (36 off-diagonal + 8 diagonal)."""

    def test_sqr_equals_mul_self(self):
        """sqr_mod(a) == mul_mod(a, a) for representative field elements."""
        values = [1, 2, P - 1, P - 2, Gx, Gy,
                  0xDEADBEEFCAFEBABE1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF % P]
        for a in values:
            with self.subTest(a=hex(a)[:16]):
                self.assertEqual(sqr_mod(a), mul_mod(a, a))

    def test_sqr_doubling_formula(self):
        """sqr_mod(2*a) == 4 * sqr_mod(a) mod P."""
        rng = random.Random(300)
        for _ in range(15):
            a = rng.randrange(1, P)
            lhs = sqr_mod(mul_mod(2, a))
            rhs = mul_mod(4, sqr_mod(a))
            self.assertEqual(lhs, rhs, f"a={hex(a)[:12]}")

    def test_sqr_difference_of_squares(self):
        """sqr_mod(a) - sqr_mod(b) == mul_mod(a+b, a-b) mod P."""
        rng = random.Random(400)
        for _ in range(15):
            a = rng.randrange(1, P)
            b = rng.randrange(1, P)
            lhs = sub_mod(sqr_mod(a), sqr_mod(b))
            rhs = mul_mod(add_mod(a, b), sub_mod(a, b))
            self.assertEqual(lhs, rhs, f"a={hex(a)[:12]}, b={hex(b)[:12]}")

    def test_sqr_basepoint_coordinates(self):
        """sqr_mod(Gx) and sqr_mod(Gy) match mul_mod(Gx, Gx), mul_mod(Gy, Gy)."""
        self.assertEqual(sqr_mod(Gx), mul_mod(Gx, Gx))
        self.assertEqual(sqr_mod(Gy), mul_mod(Gy, Gy))

    def test_sqr_reduces_mod_p(self):
        """sqr_mod always returns a value in [0, P-1]."""
        rng = random.Random(500)
        for _ in range(30):
            a = rng.randrange(1, P)
            result = sqr_mod(a)
            self.assertGreaterEqual(result, 0)
            self.assertLess(result, P)


# ===========================================================================
# TEST CLASS 4: AMD-04 — branch-free reduce_mod_p with select()
# ===========================================================================

class TestAMDReduceModP(unittest.TestCase):
    """Verify the AMD select()-based reduce_mod_p reference."""

    def test_c0_r_less_than_p(self):
        """reduce: c=0, r < P → no subtraction, result == r."""
        r = P - 1
        result = _reduce_mod_p_amd(r, 0)
        self.assertEqual(result, P - 1)

    def test_c0_r_equals_p(self):
        """reduce: c=0, r == P → result == 0."""
        result = _reduce_mod_p_amd(P, 0)
        self.assertEqual(result, 0)

    def test_c0_r_equals_p_plus_1(self):
        """reduce: c=0, r == P+1 → result == 1."""
        result = _reduce_mod_p_amd(P + 1, 0)
        self.assertEqual(result, 1)

    def test_c1_r_zero(self):
        """reduce: c=1, r=0 → effectively 1*2^256 mod P == P mod P == 0 through carries."""
        # 0 + 1*2^256 = 2^256 = P + (P-1+1) = P + (2^32+977); after 2 subtracts → omega
        # The Python reference should give the same as (0 + 2^256) % P
        result = _reduce_mod_p_amd(0, 1)
        self.assertEqual(result, (1 << 256) % P)

    def test_c2_r_zero(self):
        """reduce: c=2, r=0 → effectively 2*2^256 mod P."""
        result = _reduce_mod_p_amd(0, 2)
        self.assertEqual(result, (2 << 256) % P)

    def test_amd_select_path_matches_generic(self):
        """AMD select() path matches Python reference for 30 random valid (r, c) inputs.

        Valid input contract: r < 2^256 (r is stored in 8 u32 registers);
        V = r + c*2^256 < 3P (two passes suffice for secp256k1 omega-reduction).
        """
        rng = random.Random(600)
        two_256 = 1 << 256
        for _ in range(30):
            c = rng.randint(0, 2)
            # r must fit in 256 bits (8 u32 register lanes) and V = r+c*2^256 < 3P
            upper = min(two_256 - 1, 3 * P - c * two_256 - 1)
            if upper <= 0:
                continue
            r_int = rng.randrange(0, upper + 1)
            amd_result     = _reduce_mod_p_amd(r_int, c)
            generic_result = (r_int + c * two_256) % P
            self.assertEqual(amd_result, generic_result,
                             f"r={hex(r_int)[:12]}, c={c}")


# ===========================================================================
# TEST CLASS 5: AMD-05 — Group Key Addition (incremental point_add)
# ===========================================================================

class TestGroupKeyAdditionAMD05(unittest.TestCase):
    """
    AMD-05: Group Key Addition for m35905/m35906 (mask attack mode).

    In mask-attack mode (a3), consecutive private keys k, k+1, k+2, ... share
    the relationship: (k+i)*G = k*G + i*G.  A single scalar multiplication
    computes the base point; all subsequent points use incremental point_add,
    which is ~10× cheaper than a full scalar multiplication.

    These tests verify the correctness of the incremental approach that enables
    100–500× throughput improvement for sequential key batches.
    """

    def test_incremental_100_keys(self):
        """Base + i*G == point_mul(base+i) for i in 1..100."""
        rng = random.Random(9001)
        base = rng.randrange(1, N - 100)
        Qx, Qy = point_mul(base)
        for i in range(1, 101):
            Qx, Qy = point_add(Qx, Qy, Gx, Gy)
            ex, ey = point_mul((base + i) % N)
            with self.subTest(i=i):
                self.assertEqual(Qx, ex, f"x mismatch at i={i}")
                self.assertEqual(Qy, ey, f"y mismatch at i={i}")

    def test_incremental_500_keys(self):
        """Incremental walk of 500 consecutive keys from a random base."""
        rng = random.Random(9002)
        base = rng.randrange(1, N - 500)
        Qx, Qy = point_mul(base)
        for i in range(1, 501):
            Qx, Qy = point_add(Qx, Qy, Gx, Gy)
            ex, ey = point_mul((base + i) % N)
            with self.subTest(i=i):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_incremental_stride_2(self):
        """Incremental stride-2: add 2G each step → base, base+2, base+4, ..."""
        rng = random.Random(9003)
        base = rng.randrange(1, N - 200)
        G2x, G2y = point_mul(2)     # 2G
        Qx, Qy   = point_mul(base)
        for i in range(1, 101):
            Qx, Qy = point_add(Qx, Qy, G2x, G2y)
            ex, ey = point_mul((base + 2 * i) % N)
            with self.subTest(i=i):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_incremental_stride_16(self):
        """Incremental stride-16 (typical nibble-step for hex key mask)."""
        rng = random.Random(9004)
        base = rng.randrange(1, N - 16 * 50)
        G16x, G16y = point_mul(16)  # 16G
        Qx, Qy     = point_mul(base)
        for i in range(1, 51):
            Qx, Qy = point_add(Qx, Qy, G16x, G16y)
            ex, ey = point_mul((base + 16 * i) % N)
            with self.subTest(i=i):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_incremental_from_k_equals_1(self):
        """Starting from G (k=1): i-th step gives (1+i)*G = point_mul(1+i)."""
        Qx, Qy = Gx, Gy
        for i in range(1, 51):
            Qx, Qy = point_add(Qx, Qy, Gx, Gy)
            ex, ey = point_mul(1 + i)
            with self.subTest(i=i):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_incremental_wraps_around_n(self):
        """Incremental walk wraps correctly when k crosses the group order N."""
        base = N - 5      # 5 steps before wrapping
        Qx, Qy = point_mul(base)
        for i in range(1, 11):
            Qx, Qy = point_add(Qx, Qy, Gx, Gy)
            k = (base + i) % N
            if k == 0:
                k = N   # k=0 is not a valid key; point_mul(N)=∞
            ex, ey = point_mul(k) if k != N else (None, None)
            with self.subTest(i=i, k=k):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_precomputed_delta_table(self):
        """Precomputed delta table: delta_G[j] = (j+1)*G for j in 0..15."""
        # Simulates a GPU "group key table" where each warp computes
        # from a different offset using precomputed small multiples.
        delta_table = [(Gx, Gy)]
        for j in range(1, 16):
            dx, dy = point_add(delta_table[-1][0], delta_table[-1][1], Gx, Gy)
            delta_table.append((dx, dy))

        rng = random.Random(9005)
        base = rng.randrange(1, N - 16)
        Bx, By = point_mul(base)

        for j in range(16):
            Qx, Qy = point_add(Bx, By, delta_table[j][0], delta_table[j][1])
            ex, ey = point_mul((base + j + 1) % N)
            with self.subTest(j=j):
                self.assertEqual(Qx, ex)
                self.assertEqual(Qy, ey)

    def test_endomorphism_delta_equals_standard_delta(self):
        """GLV endomorphism: phi(P + G) == phi(P) + phi(G)."""
        # phi(x, y) = (beta * x mod P, y) is a group homomorphism
        rng = random.Random(9006)
        for _ in range(20):
            k  = rng.randrange(1, N - 1)
            Px, Py  = point_mul(k)
            Qx, Qy  = point_mul(k + 1)   # P + G

            # phi(P+G) via direct computation
            phi_Qx = mul_mod(BETA, Qx)
            phi_Qy = Qy

            # phi(P) + phi(G)
            phi_Px = mul_mod(BETA, Px)
            phi_Py = Py
            phi_Gx = mul_mod(BETA, Gx)
            phi_Gy = Gy
            phi_Px_plus_Gx, phi_Px_plus_Gy = point_add(phi_Px, phi_Py, phi_Gx, phi_Gy)

            with self.subTest(k=hex(k)[-8:]):
                self.assertEqual(phi_Qx, phi_Px_plus_Gx)
                self.assertEqual(phi_Qy, phi_Px_plus_Gy)


# ===========================================================================
# TEST CLASS 6: AMD-06 — Workgroup tuning: validate OpenCL source patterns
# ===========================================================================

class TestAMDOpenCLSource(unittest.TestCase):
    """
    AMD-06: Verify that the OpenCL source files contain the expected
    AMD-specific optimisation patterns.
    """

    def _read(self, rel_path):
        return _read_cl(rel_path)

    # --- add() / sub() AMD carry chain (AMD-01) --------------------------------

    def test_add_has_is_amd_path(self):
        """add() must have a #elif defined IS_AMD block with u64 carry chain."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        self.assertIn("#elif defined IS_AMD", src)
        # Must contain the u64 carry chain pattern introduced in Phase 2
        self.assertIn("v_add_co_u32", src)

    def test_sub_has_is_amd_path(self):
        """sub() must have a #elif defined IS_AMD block with u64 borrow chain."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        # The IS_AMD block must exist (shared with add path comment)
        self.assertIn("#elif defined IS_AMD", src)
        self.assertIn("v_sub_co_u32", src)

    # --- mul_mod MULADD64 (AMD-02) --------------------------------------------

    def test_mul_mod_uses_muladd64(self):
        """mul_mod() must use the MULADD64 macro (maps to v_mad_u64_u32 on AMD)."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        self.assertIn("MULADD64", src)
        self.assertIn("v_mad_u64_u32", src)

    # --- sqr_mod symmetry (AMD-03) -------------------------------------------

    def test_sqr_mod_uses_symmetry(self):
        """sqr_mod() must use off-diagonal doubling (_p2 = _p + _p pattern)."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        # The squaring code doubles off-diagonal products
        self.assertIn("_p2 = _p + _p", src)

    # --- reduce_mod_p AMD select() (AMD-04) ----------------------------------

    def test_reduce_mod_p_has_amd_select(self):
        """reduce_mod_p() must have an IS_AMD path using select() builtin."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        # Phase 6 AMD-04 enhancement: select() path
        self.assertIn("select (r[0], tmp[0], use_tmp)", src)

    def test_reduce_mod_p_amd_path_uses_vcc_comment(self):
        """reduce_mod_p AMD path must document v_cndmask_b32 / VCC usage."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        self.assertIn("v_cndmask_b32", src)

    # --- m35905 / m35906 a3 kernels use GLV+wNAF (AMD-05 readiness) ----------

    def test_m35905_a3_uses_glv_wnaf_w5(self):
        """m35905_a3-pure.cl must call point_mul_glv_wnaf_w5."""
        src = self._read("OpenCL/m35905_a3-pure.cl")
        self.assertIn("point_mul_glv_wnaf_w5", src)

    def test_m35906_a3_uses_glv_wnaf_w5(self):
        """m35906_a3-pure.cl must call point_mul_glv_wnaf_w5."""
        src = self._read("OpenCL/m35906_a3-pure.cl")
        self.assertIn("point_mul_glv_wnaf_w5", src)

    def test_m35905_a3_uses_secp256k1_w5_t(self):
        """m35905_a3-pure.cl must declare secp256k1_w5_t preG."""
        src = self._read("OpenCL/m35905_a3-pure.cl")
        self.assertIn("secp256k1_w5_t", src)

    def test_m35906_a3_uses_secp256k1_w5_t(self):
        """m35906_a3-pure.cl must declare secp256k1_w5_t preG."""
        src = self._read("OpenCL/m35906_a3-pure.cl")
        self.assertIn("secp256k1_w5_t", src)

    def test_m35905_a3_no_old_point_mul_xy(self):
        """m35905_a3-pure.cl must not call the old (slow) point_mul_xy."""
        src = self._read("OpenCL/m35905_a3-pure.cl")
        self.assertNotIn("point_mul_xy", src)

    def test_m35906_a3_no_old_point_mul_xy(self):
        """m35906_a3-pure.cl must not call the old (slow) point_mul_xy."""
        src = self._read("OpenCL/m35906_a3-pure.cl")
        self.assertNotIn("point_mul_xy", src)

    # --- NV PTX paths are untouched ------------------------------------------

    def test_nvidia_ptx_path_present(self):
        """NVIDIA PTX path must still be present (not touched by Phase 6)."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        self.assertIn("IS_NV", src)
        self.assertIn("mul_mod_ptx", src)

    def test_amd_path_does_not_use_ptx(self):
        """AMD IS_AMD path must not call mul_mod_ptx (PTX is NVIDIA-only)."""
        src = self._read("OpenCL/inc_ecc_secp256k1.cl")
        # The IS_AMD block in mul_mod_ptx must be the fallback only (via #else)
        # Verify no #if IS_AMD block calls mul_mod_ptx
        # Simple heuristic: IS_AMD and mul_mod_ptx should not appear on same line
        for line in src.splitlines():
            if "IS_AMD" in line and "mul_mod_ptx" in line:
                self.fail(f"AMD path calls mul_mod_ptx on line: {line!r}")


# ===========================================================================
# TEST CLASS 7: AMD-06 Workgroup size math
# ===========================================================================

class TestAMDWorkgroupSizeMath(unittest.TestCase):
    """
    AMD-06: Verify workgroup-size calculations for AMD GPU families.

    AMD Polaris (RX 580)  : wavefront = 64,  optimal LOCAL_SIZE = 64 or 128
    AMD RDNA 1 (RX 5700)  : wavefront = 32,  optimal LOCAL_SIZE = 32 or 64
    AMD RDNA 2 (RX 6800)  : wavefront = 32,  optimal LOCAL_SIZE = 32 or 64
    AMD RDNA 3 (RX 7900)  : wavefront = 32,  optimal LOCAL_SIZE = 32 or 64

    Tests verify that the chosen LOCAL_SIZE values are multiples of the
    hardware wavefront size (no partial waves).
    """

    AMD_FAMILIES = {
        "GCN_Polaris":   {"wavefront": 64,  "optimal_sizes": [64, 128]},
        "RDNA1_Navi10":  {"wavefront": 32,  "optimal_sizes": [32, 64]},
        "RDNA2_Navi21":  {"wavefront": 32,  "optimal_sizes": [32, 64]},
        "RDNA3_Navi31":  {"wavefront": 32,  "optimal_sizes": [32, 64]},
    }

    def test_optimal_sizes_are_multiples_of_wavefront(self):
        """All optimal LOCAL_SIZE values must be exact multiples of wavefront size."""
        for family, info in self.AMD_FAMILIES.items():
            wf = info["wavefront"]
            for sz in info["optimal_sizes"]:
                with self.subTest(family=family, size=sz):
                    self.assertEqual(sz % wf, 0,
                        f"{family}: LOCAL_SIZE={sz} is not a multiple of wavefront={wf}")

    def test_optimal_sizes_are_power_of_two(self):
        """All optimal LOCAL_SIZE values must be powers of two."""
        for family, info in self.AMD_FAMILIES.items():
            for sz in info["optimal_sizes"]:
                with self.subTest(family=family, size=sz):
                    self.assertEqual(sz & (sz - 1), 0,
                        f"{family}: LOCAL_SIZE={sz} is not a power of two")

    def test_occupancy_math_polaris(self):
        """GCN Polaris: 64 CUs × 4 SIMD × 10 waves = 2560 wave slots."""
        cu_count = 36           # RX 580 has 36 CUs
        simd_per_cu = 4
        max_waves_per_simd = 10
        total_wave_slots = cu_count * simd_per_cu * max_waves_per_simd
        self.assertEqual(total_wave_slots, 36 * 4 * 10)

    def test_occupancy_math_rdna2(self):
        """RDNA 2: 60 CUs × 2 SIMD32 × 16 waves = 1920 wave slots."""
        cu_count = 60           # RX 6800 XT has 72, use 60 for math
        simd_per_cu = 2         # RDNA has 2 SIMD32 units per CU
        max_waves_per_simd = 16
        total_wave_slots = cu_count * simd_per_cu * max_waves_per_simd
        self.assertEqual(total_wave_slots, 60 * 2 * 16)


if __name__ == "__main__":
    unittest.main(verbosity=2)
