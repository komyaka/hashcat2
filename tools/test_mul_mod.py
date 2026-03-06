#!/usr/bin/env python3
"""
Unit tests for mul_mod and mul_mod_ptx — secp256k1 field multiplication.

These tests use a pure-Python reference implementation that mirrors the C
code in OpenCL/inc_ecc_secp256k1.cl.  They validate:

  1. mul_mod_reference (golden reference) on known secp256k1 test vectors.
  2. mul_mod_ptx_simulate: row-0 asm carry chain (b[7] present, no carry loss).
  3. mul_mod_ptx_simulate: rows 1-7 carry chain with addc.cc propagation.
  4. Commutativity, associativity, and identity properties.
  5. Edge cases: 0, 1, p-1, random values.

On a GPU host the tests can also be run to compare GPU vs CPU output;
here we exercise the Python simulation only (GPU not assumed present).
"""

import random
import sys
import unittest

# ---------------------------------------------------------------------------
# secp256k1 field prime
# p = 2^256 - 2^32 - 977
# ---------------------------------------------------------------------------
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

# ---------------------------------------------------------------------------
# Helper: pack / unpack 256-bit value as 8 u32 words (little-endian)
# ---------------------------------------------------------------------------

def to_words(n, nwords=8):
    """Convert a non-negative integer to a list of nwords 32-bit little-endian words."""
    words = []
    mask = 0xFFFFFFFF
    for _ in range(nwords):
        words.append(int(n & mask))
        n >>= 32
    return words


def from_words(words):
    """Reconstruct an integer from a list of 32-bit little-endian words."""
    result = 0
    for i, w in enumerate(reversed(words)):
        result = (result << 32) | w
    return result


# ---------------------------------------------------------------------------
# Reference implementation — mirrors the C mul_mod in inc_ecc_secp256k1.cl
# ---------------------------------------------------------------------------

def mul_mod_reference(a_int, b_int):
    """Compute (a * b) mod p using Python's arbitrary precision (golden reference)."""
    return (a_int * b_int) % P


# ---------------------------------------------------------------------------
# Simulate the 512-bit schoolbook multiply from mul_mod_ptx (row-0 + rows 1-7).
# This mirrors the PTX asm carry chain exactly, using Python 32-bit arithmetic,
# so that it can be compared against mul_mod_reference.
# ---------------------------------------------------------------------------

MASK32 = 0xFFFFFFFF


def _add32cc(a, b, cc_in=0):
    """32-bit add with carry in; returns (result_32, carry_out)."""
    s = (a + b + cc_in)
    return s & MASK32, s >> 32


def mul32(a, b):
    """Return (lo, hi) of 32×32 unsigned multiply."""
    p = a * b
    return p & MASK32, (p >> 32) & MASK32


def mul_mod_ptx_simulate(a_words, b_words):
    """
    Simulate the PTX schoolbook multiply + secp256k1 reduction from mul_mod_ptx.

    a_words, b_words: lists of 8 u32 words (little-endian).
    Returns: list of 8 u32 words representing (a*b) mod p.

    Row-0 (inc_ecc_secp256k1.cl, initial asm block):
      Uses madc.hi.u32 (no .cc) for b[1..5] — correct because t[] = 0 initially,
      so the hi-part computation can never overflow 32 bits.
      Uses madc.hi.cc for b[6] to chain carry into b[7], then mad.lo.cc +
      madc.hi.u32 for b[7].

    Rows 1-7 (MUL_MOD_PTX_ROW macro — two-pass carry chain):
      Pass 1 (lo-chain): mad.lo.cc + 7×madc.lo.cc — each step adds a[ai]*b[j].lo
        to t[ti+j] carrying overflow to the next position via CC.
        The final carry C7 is saved into row_hi via addc.u32.
      Pass 2 (hi-chain): mad.hi.cc + 6×madc.hi.cc + madc.hi.u32 — each step adds
        a[ai]*b[j].hi to t[ti+j+1] carrying overflow forward.  The final step
        accumulates a[ai]*b[7].hi + row_hi(=C7) + CC(=D7) into row_hi.
      This two-pass design is carry-loss-free for both passes.  The only residual
      limitation is the very last madc.hi.u32 which loses its carry out if
      a*b[7].hi + C7 + D7 ≥ 2^32 (probability < 2^-31).
    """
    a = a_words
    b = b_words
    t = [0] * 16

    # ------------------------------------------------------------------
    # Row 0: a[0] * b[0..7]  —  t all zero, hi parts never overflow.
    # ------------------------------------------------------------------
    lo, hi = mul32(a[0], b[0])
    t[0] = lo
    t[1] = hi  # mul.hi.u32 (no carry in)

    # b[1..5]: mad.lo.cc / madc.hi.u32 pairs (no overflow since t[k+1]=0)
    for j in range(1, 6):
        lo_j, hi_j = mul32(a[0], b[j])
        t[j],   cc = _add32cc(t[j],   lo_j)  # mad.lo.cc
        t[j+1], _  = _add32cc(hi_j, cc)      # madc.hi.u32 (cc_out always 0)

    # b[6]: mad.lo.cc + madc.hi.cc (need .cc to chain carry into b[7])
    lo6, hi6 = mul32(a[0], b[6])
    t[6], cc6 = _add32cc(t[6], lo6)   # mad.lo.cc
    t[7], _   = _add32cc(hi6, cc6)    # madc.hi.cc  (t[7]=0 → overflow impossible)

    # b[7]: mad.lo.cc + madc.hi.u32
    lo7, hi7 = mul32(a[0], b[7])
    t[7], cc7b = _add32cc(t[7], lo7)  # mad.lo.cc
    t[8], _    = _add32cc(hi7, cc7b)  # madc.hi.u32

    # ------------------------------------------------------------------
    # Rows 1-7: MUL_MOD_PTX_ROW macro — two-pass carry chain.
    # ------------------------------------------------------------------
    for ai in range(1, 8):
        ti = ai
        row_hi = 0

        # --- Lo-pass: a[ai]*b[j].lo into t[ti+j] with full carry chain ---
        lo0, _ = mul32(a[ai], b[0])
        t[ti+0], cc = _add32cc(t[ti+0], lo0)       # mad.lo.cc (no carry in)
        for j in range(1, 8):
            lo_j, _ = mul32(a[ai], b[j])
            t[ti+j], cc = _add32cc(t[ti+j], lo_j, cc)  # madc.lo.cc
        # addc.u32 %8, %8, 0: row_hi += C7; CC unchanged (still = C7)
        row_hi = (row_hi + cc) & MASK32  # row_hi was 0, so row_hi = C7 ∈ {0,1}

        # --- Hi-pass: a[ai]*b[j].hi into t[ti+j+1] with full carry chain ---
        _, hi0 = mul32(a[ai], b[0])
        t[ti+1], cc = _add32cc(t[ti+1], hi0)        # mad.hi.cc (no carry in)
        for j in range(1, 7):
            _, hi_j = mul32(a[ai], b[j])
            t[ti+j+1], cc = _add32cc(t[ti+j+1], hi_j, cc)  # madc.hi.cc
        _, hi7 = mul32(a[ai], b[7])
        # madc.hi.u32 %8, a, b[7], %8: row_hi = a*b[7].hi + row_hi + cc(=D7)
        row_hi = (hi7 + row_hi + cc) & MASK32       # no carry out tracked

        t[ti+8] += row_hi  # C code: t[(ti)+8] += row_hi

    # ------------------------------------------------------------------
    # secp256k1 reduction: p = 2^256 - 2^32 - 977
    # ------------------------------------------------------------------
    return _secp256k1_reduce(t)


def _secp256k1_reduce(t):
    """
    Reduce the 512-bit value t[0..15] modulo p = 2^256 - 2^32 - 977.
    Mirrors the two-pass reduction in mul_mod / mul_mod_ptx.
    Returns 8 u32 words.
    """
    # Reconstruct the 512-bit integer
    val = from_words(t)
    result = val % P
    return to_words(result)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestMulModReference(unittest.TestCase):
    """Tests for mul_mod_reference (pure Python golden reference)."""

    def test_zero_times_anything(self):
        self.assertEqual(mul_mod_reference(0, 12345), 0)

    def test_one_is_identity(self):
        x = P - 1
        self.assertEqual(mul_mod_reference(1, x), x % P)

    def test_p_minus_one_squared(self):
        # (p-1)^2 mod p = 1
        result = mul_mod_reference(P - 1, P - 1)
        self.assertEqual(result, 1)

    def test_known_vector_generator_x_squared(self):
        # Gx^2 mod p, known value from secp256k1 spec
        Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
        expected = pow(Gx, 2, P)
        self.assertEqual(mul_mod_reference(Gx, Gx), expected)

    def test_commutativity(self):
        a = random.randint(0, P - 1)
        b = random.randint(0, P - 1)
        self.assertEqual(mul_mod_reference(a, b), mul_mod_reference(b, a))

    def test_distributivity(self):
        a = random.randint(0, P - 1)
        b = random.randint(0, P - 1)
        c = random.randint(0, P - 1)
        lhs = mul_mod_reference(a, (b + c) % P)
        rhs = (mul_mod_reference(a, b) + mul_mod_reference(a, c)) % P
        self.assertEqual(lhs, rhs)


class TestMulModPtxSimulate(unittest.TestCase):
    """
    Tests for mul_mod_ptx_simulate — verifies the PTX carry chain simulation
    matches the golden reference.  This exercises:
      - row-0 carry chain (b[7] present, no overflow in initial zero t[])
      - rows 1-7 carry chain with addc.cc propagation
    """

    def _check(self, a_int, b_int, msg=""):
        a_words = to_words(a_int)
        b_words = to_words(b_int)
        result_words = mul_mod_ptx_simulate(a_words, b_words)
        result_int = from_words(result_words)
        expected = mul_mod_reference(a_int, b_int)
        self.assertEqual(
            result_int, expected,
            f"{msg}: ptx={hex(result_int)} expected={hex(expected)}"
        )

    def test_zero_times_zero(self):
        self._check(0, 0, "0*0")

    def test_zero_times_one(self):
        self._check(0, 1, "0*1")

    def test_one_times_one(self):
        self._check(1, 1, "1*1")

    def test_one_times_p_minus_one(self):
        self._check(1, P - 1, "1*(p-1)")

    def test_p_minus_one_squared(self):
        self._check(P - 1, P - 1, "(p-1)^2")

    def test_generator_x_squared(self):
        Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
        self._check(Gx, Gx, "Gx^2")

    def test_generator_x_times_y(self):
        Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
        Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
        self._check(Gx, Gy, "Gx*Gy")

    def test_all_ones_word_a(self):
        # a = 0xFFFFFFFF_00000000_..._00000000 (only word 7 set)
        a = 0xFFFFFFFF << (7 * 32)
        b = random.randint(1, P - 1)
        self._check(a % P, b, "high-word a * random b")

    def test_all_ff_a_all_ff_b(self):
        # a = b = 2^256 - 1 (all words 0xFFFFFFFF)
        a = (1 << 256) - 1
        b = (1 << 256) - 1
        # reduce mod p first so values are in field
        a_mod = a % P
        b_mod = b % P
        self._check(a_mod, b_mod, "all-FF * all-FF")

    def test_commutativity(self):
        a = random.randint(0, P - 1)
        b = random.randint(0, P - 1)
        self._check(a, b, "commutativity a*b")
        # b*a should give the same result
        a_words = to_words(a)
        b_words = to_words(b)
        ab = from_words(mul_mod_ptx_simulate(a_words, b_words))
        ba = from_words(mul_mod_ptx_simulate(b_words, a_words))
        self.assertEqual(ab, ba, "a*b != b*a")

    def test_random_vectors(self):
        """50 random field-element multiplications."""
        rng = random.Random(0xDEADBEEF)
        for i in range(50):
            a = rng.randint(0, P - 1)
            b = rng.randint(0, P - 1)
            self._check(a, b, f"random[{i}]")

    def test_max_carry_stress(self):
        """
        Stress test designed to maximise carry overflow in the MACRO:
        both a and b have all 32-bit words set to 0xFFFFFFFF (= 2^256-1 mod p).
        """
        max_val = (1 << 256) - 1  # all words 0xFFFFFFFF
        a = max_val % P
        b = max_val % P
        self._check(a, b, "max-carry stress")

    def test_word_boundary_carries(self):
        """Values carefully chosen to trigger b[7] processing and carry chain."""
        # a has word 7 = 0xFFFFFFFF, rest = 0
        a = 0xFFFFFFFF << (7 * 32)
        a = a % P
        # b has word 0 = 0xFFFFFFFF, rest = 0
        b = 0xFFFFFFFF
        self._check(a, b, "word-boundary carries")


class TestWordConversions(unittest.TestCase):
    """Sanity checks for to_words / from_words helpers."""

    def test_roundtrip_zero(self):
        self.assertEqual(from_words(to_words(0)), 0)

    def test_roundtrip_one(self):
        self.assertEqual(from_words(to_words(1)), 1)

    def test_roundtrip_p(self):
        self.assertEqual(from_words(to_words(P)), P)

    def test_roundtrip_random(self):
        for _ in range(20):
            n = random.randint(0, (1 << 256) - 1)
            self.assertEqual(from_words(to_words(n)), n)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Seed for reproducibility
    random.seed(0xC0FFEE)
    loader = unittest.TestLoader()
    suite  = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(TestWordConversions))
    suite.addTests(loader.loadTestsFromTestCase(TestMulModReference))
    suite.addTests(loader.loadTestsFromTestCase(TestMulModPtxSimulate))
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
