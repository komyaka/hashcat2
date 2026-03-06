#!/usr/bin/env python3
"""
Unit tests for the GLV (Gallant-Lambert-Vanstone) scalar decomposition
as implemented in OpenCL/inc_ecc_secp256k1.cl (glv_decompose function).

The algorithm splits a 256-bit scalar k into two ~128-bit scalars k1, k2 such
that k ≡ k1 + k2 * lambda (mod n) using Babai nearest-plane rounding with
precomputed constants G1, G2, A1, B1, A2.

Tests verify:
  1. k ≡ k1 + k2 * lambda (mod n)          for every test vector
  2. |k1| < 2^129                            for every test vector
  3. |k2| < 2^129                            for every test vector
  4. GLV lattice property: a1^2 + |b1|*a2 = n
  5. lambda is a primitive cube root of unity mod n

References:
  - OpenCL/inc_ecc_secp256k1.h  (constants SECP256K1_GLV_*)
  - OpenCL/inc_ecc_secp256k1.cl (glv_decompose implementation)
  - libsecp256k1 src/scalar_impl.h (secp256k1_scalar_split_lambda)
"""

import unittest

# ---------------------------------------------------------------------------
# secp256k1 parameters
# ---------------------------------------------------------------------------

# Curve order n
SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

# GLV endomorphism lambda: cube root of 1 mod n
# phi(P) = lambda * P  (scalar action, corresponds to (x,y) -> (beta*x, y))
SECP256K1_LAMBDA = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72

# ---------------------------------------------------------------------------
# GLV decomposition constants (from OpenCL/inc_ecc_secp256k1.h)
# ---------------------------------------------------------------------------

# a1 = 0x3086D221A7D46BCDE86C90E49284EB15
_A1 = 0x3086D221A7D46BCDE86C90E49284EB15

# |b1| = 0xE4437ED6010E88286F547FA90ABFE4C3  (b1 is negative in the lattice)
_B1 = 0xE4437ED6010E88286F547FA90ABFE4C3

# a2 = 0x114CA50F7A8E2F3F657C1108D9D44CFD8  (129-bit, high bit = SECP256K1_GLV_A2_4 = 1)
_A2 = 0x114CA50F7A8E2F3F657C1108D9D44CFD8

# Babai rounding constants (little-endian u32 words from the header):
#   G1_words = [0x45dbb031, 0xe893209a, 0x71e8ca7f, 0x3daa8a14,
#               0x9284eb15, 0xe86c90e4, 0xa7d46bcd, 0x3086d221]
#   G2_words = [0x8ac47f71, 0x1571b4ae, 0x9df506c6, 0x221208ac,
#               0x0abfe4c4, 0x6f547fa9, 0x010e8828, 0xe4437ed6]
_G1_WORDS = [0x45dbb031, 0xe893209a, 0x71e8ca7f, 0x3daa8a14,
             0x9284eb15, 0xe86c90e4, 0xa7d46bcd, 0x3086d221]
_G2_WORDS = [0x8ac47f71, 0x1571b4ae, 0x9df506c6, 0x221208ac,
             0x0abfe4c4, 0x6f547fa9, 0x010e8828, 0xe4437ed6]
_G1 = sum(_G1_WORDS[i] * (1 << (32 * i)) for i in range(8))
_G2 = sum(_G2_WORDS[i] * (1 << (32 * i)) for i in range(8))


# ---------------------------------------------------------------------------
# Python implementation mirroring the C/OpenCL glv_decompose function
# ---------------------------------------------------------------------------

def glv_decompose(k):
    """
    Python model of glv_decompose() from OpenCL/inc_ecc_secp256k1.cl.

    Decomposes scalar k (0 < k < n) into signed 129-bit scalars k1, k2 s.t.:
      k ≡ k1 + k2 * lambda (mod n)
      |k1| < 2^129
      |k2| < 2^129

    Algorithm (Babai nearest-plane, matching libsecp256k1):
      c1 = floor(k * G1 / 2^384)   — Babai coefficient for a1/b1 lattice vector
      c2 = floor(k * G2 / 2^384)   — Babai coefficient for a2/b2 lattice vector
      k1 = k - c1*a1 - c2*a2
      k2 = c1*|b1| - c2*a1

    Returns (k1, k2) as signed Python integers.
    """
    c1 = (k * _G1) >> 384
    c2 = (k * _G2) >> 384
    k1 = k - c1 * _A1 - c2 * _A2
    k2 = c1 * _B1 - c2 * _A1
    return k1, k2


# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

class TestGlvDecomposeConstants(unittest.TestCase):
    """Sanity-checks on the secp256k1 GLV constants."""

    def test_lambda_is_primitive_cube_root_of_unity(self):
        """lambda^2 + lambda + 1 ≡ 0 (mod n)."""
        n, lam = SECP256K1_N, SECP256K1_LAMBDA
        self.assertNotEqual(lam, 1)
        self.assertEqual((lam * lam + lam + 1) % n, 0)

    def test_lambda_cubed_is_one(self):
        """lambda^3 ≡ 1 (mod n)."""
        n, lam = SECP256K1_N, SECP256K1_LAMBDA
        self.assertEqual(pow(lam, 3, n), 1)

    def test_lattice_property(self):
        """a1^2 + |b1| * a2 == n  (GLV lattice identity)."""
        self.assertEqual(_A1 * _A1 + _B1 * _A2, SECP256K1_N)

    def test_babai_constants_accuracy(self):
        """G1 ≈ round(a1 * 2^384 / n) and G2 ≈ round(|b1| * 2^384 / n)."""
        exact_g1 = _A1 * (1 << 384) // SECP256K1_N
        exact_g2 = _B1 * (1 << 384) // SECP256K1_N
        self.assertIn(_G1, (exact_g1, exact_g1 + 1))
        self.assertIn(_G2, (exact_g2, exact_g2 + 1))

    def test_a1_and_b1_are_128_bit(self):
        """a1 and |b1| must fit in 128 bits for the 4-word C representation."""
        self.assertLess(_A1, 1 << 128)
        self.assertLess(_B1, 1 << 128)

    def test_a2_is_129_bit(self):
        """a2 must fit in 129 bits (the 5th word in C is 0 or 1)."""
        self.assertLess(_A2, 1 << 129)


class TestGlvDecomposeInvariant(unittest.TestCase):
    """Core correctness: k1 + k2*lambda ≡ k (mod n), |k1|,|k2| < 2^129."""

    # ------------------------------------------------------------------
    # Helper
    # ------------------------------------------------------------------

    def _check(self, k, label=""):
        """Assert all three GLV invariants for scalar k."""
        n = SECP256K1_N
        lam = SECP256K1_LAMBDA
        k1, k2 = glv_decompose(k)

        # Invariant 1: reconstruction
        self.assertEqual(
            k % n, (k1 + k2 * lam) % n,
            f"{label}: k1 + k2*lambda != k (mod n)\n"
            f"  k  = {hex(k)}\n  k1 = {k1}\n  k2 = {k2}",
        )
        # Invariant 2 & 3: half-size bound
        self.assertLess(
            abs(k1), 1 << 129,
            f"{label}: |k1| >= 2^129 (got {abs(k1).bit_length()} bits)",
        )
        self.assertLess(
            abs(k2), 1 << 129,
            f"{label}: |k2| >= 2^129 (got {abs(k2).bit_length()} bits)",
        )

    # ------------------------------------------------------------------
    # Boundary / special scalars
    # ------------------------------------------------------------------

    def test_k_equals_one(self):
        self._check(1, "k=1")

    def test_k_equals_two(self):
        self._check(2, "k=2")

    def test_k_equals_n_minus_one(self):
        self._check(SECP256K1_N - 1, "k=n-1")

    def test_k_equals_n_minus_two(self):
        self._check(SECP256K1_N - 2, "k=n-2")

    def test_k_equals_lambda(self):
        self._check(SECP256K1_LAMBDA, "k=lambda")

    def test_k_equals_lambda_minus_one(self):
        self._check(SECP256K1_LAMBDA - 1, "k=lambda-1")

    def test_k_equals_lambda_plus_one(self):
        self._check(SECP256K1_LAMBDA + 1, "k=lambda+1")

    def test_k_equals_half_n(self):
        self._check(SECP256K1_N // 2, "k=n//2")

    def test_k_equals_third_n(self):
        self._check(SECP256K1_N // 3, "k=n//3")

    def test_k_equals_2_pow_128(self):
        self._check(1 << 128, "k=2^128")

    def test_k_equals_2_pow_128_minus_one(self):
        self._check((1 << 128) - 1, "k=2^128-1")

    def test_k_equals_2_pow_129(self):
        self._check(1 << 129, "k=2^129")

    def test_k_equals_2_pow_255(self):
        self._check((1 << 255) % SECP256K1_N, "k=2^255 mod n")

    def test_k_small_powers_of_two(self):
        """k = 2^i for i in [0, 63)."""
        for i in range(63):
            self._check(1 << i, f"k=2^{i}")

    # ------------------------------------------------------------------
    # All-bits patterns
    # ------------------------------------------------------------------

    def test_k_all_ones_128_bit(self):
        self._check((1 << 128) - 1, "k=2^128-1 (all ones 128-bit)")

    def test_k_alternating_bits_aa(self):
        k = int("AA" * 32, 16) % SECP256K1_N
        self._check(k, "k=0xAAAA...AA mod n")

    def test_k_alternating_bits_55(self):
        k = int("55" * 32, 16) % SECP256K1_N
        self._check(k, "k=0x5555...55 mod n")

    # ------------------------------------------------------------------
    # Known test vectors
    # ------------------------------------------------------------------

    def test_known_vectors(self):
        """
        Deterministic test vectors verifiable against libsecp256k1.
        For each k, the GLV invariants must hold regardless of the actual
        (k1, k2) values produced (the decomposition is not unique).
        """
        vectors = [
            0x0000000000000000000000000000000000000000000000000000000000000001,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140,
            0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF,
            0xDEADBEEFCAFEBABE1234567890ABCDEF0123456789ABCDEF0123456789ABCDEF,
            0x0000000000000000000000000000000100000000000000000000000000000000,
            0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,
            0x5555555555555555555555555555555555555555555555555555555555555555,
        ]
        for raw in vectors:
            k = raw % SECP256K1_N
            if k == 0:
                continue
            self._check(k, f"known vector 0x{k:064x}")

    # ------------------------------------------------------------------
    # Pseudo-random sweep (deterministic, no random module needed)
    # ------------------------------------------------------------------

    def test_deterministic_sweep(self):
        """
        100 deterministic scalars evenly spaced over [1, n-1].
        Tests the invariant for a broad spread of inputs.
        """
        n = SECP256K1_N
        for i in range(1, 101):
            k = (n * i // 101) % n
            if k == 0:
                k = i
            self._check(k, f"sweep i={i}")

    def test_lattice_multiples(self):
        """Scalars at multiples of a1 and |b1| mod n."""
        n = SECP256K1_N
        for mult in range(1, 20):
            k1 = (_A1 * mult) % n
            k2 = (_B1 * mult) % n
            if k1:
                self._check(k1, f"a1*{mult} mod n")
            if k2:
                self._check(k2, f"|b1|*{mult} mod n")

    # ------------------------------------------------------------------
    # Bound tightness
    # ------------------------------------------------------------------

    def test_decomposition_bound_is_strictly_less_than_2_pow_129(self):
        """
        For 500 evenly-spread scalars, verify that both |k1| and |k2|
        are strictly less than 2^129 (not just ≤ 2^129).
        """
        n = SECP256K1_N
        limit = 1 << 129
        for i in range(1, 501):
            k = (n * i // 501) % n
            if k == 0:
                continue
            k1, k2 = glv_decompose(k)
            self.assertLess(abs(k1), limit, f"i={i}: |k1| >= 2^129")
            self.assertLess(abs(k2), limit, f"i={i}: |k2| >= 2^129")


if __name__ == "__main__":
    unittest.main(verbosity=2)
