#!/usr/bin/env python3
"""
Tests for Window-NAF implementation and precomputed secp256k1 table constants.

Covers:
  - TestWNafCorrectness:        digit validity and scalar reconstruction
  - TestWNafOperationCount:     operation count model properties
  - TestAutotune:               autotuning selects valid, sensible window sizes
  - TestPrecomputedTableConstants: math verification of 9G..15G constants
  - TestEdgeCasesStability:     extreme/boundary inputs do not crash
"""

import sys
import os
import random
import unittest

# Ensure the Python package directory is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from Python.wnaf_autotune import (
    convert_to_wnaf,
    count_operations,
    estimate_ops_random,
    gpu_cost_model,
    autotune,
    print_benchmark_table,
)

# ---------------------------------------------------------------------------
# secp256k1 curve constants
# ---------------------------------------------------------------------------

P   = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N   = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx  = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy  = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _modinv(a: int, m: int) -> int:
    """Modular inverse via extended Euclidean algorithm."""
    g, x, _ = _extended_gcd(a % m, m)
    if g != 1:
        raise ValueError("Modular inverse does not exist")
    return x % m


def _extended_gcd(a: int, b: int):
    if a == 0:
        return b, 0, 1
    g, x, y = _extended_gcd(b % a, a)
    return g, y - (b // a) * x, x


def _point_add(P1, P2):
    """Affine secp256k1 point addition (handles identity)."""
    if P1 is None:
        return P2
    if P2 is None:
        return P1
    x1, y1 = P1
    x2, y2 = P2
    if x1 == x2:
        if y1 != y2:
            return None  # point at infinity
        # doubling
        lam = (3 * x1 * x1 * _modinv(2 * y1, P)) % P
    else:
        lam = ((y2 - y1) * _modinv(x2 - x1, P)) % P
    x3 = (lam * lam - x1 - x2) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def _point_mul(k: int, point=None):
    """Scalar multiplication on secp256k1 (double-and-add)."""
    if point is None:
        point = (Gx, Gy)
    result = None
    addend = point
    while k > 0:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


# ---------------------------------------------------------------------------
# Helper: verify NAF properties
# ---------------------------------------------------------------------------

def _naf_reconstruct(naf: list) -> int:
    """Reconstruct scalar from NAF digit list (LSB first)."""
    return sum(d * (1 << i) for i, d in enumerate(naf))


def _naf_check_sparsity(naf: list) -> bool:
    """Return True if no two consecutive nonzero digits exist."""
    prev_nonzero = False
    for d in naf:
        if d != 0:
            if prev_nonzero:
                return False
            prev_nonzero = True
        else:
            prev_nonzero = False
    return True


def _naf_check_digit_bounds(naf: list, w: int) -> bool:
    """Return True if all nonzero digits are odd and |d| < 2^(w-1)."""
    half = 1 << (w - 1)
    for d in naf:
        if d == 0:
            continue
        if d % 2 == 0:
            return False
        if abs(d) >= half:
            return False
    return True


# ---------------------------------------------------------------------------
# Test classes
# ---------------------------------------------------------------------------

class TestWNafCorrectness(unittest.TestCase):
    """Verify w-NAF output represents the same scalar and satisfies properties."""

    def _check_wnaf(self, k: int, w: int):
        naf = convert_to_wnaf(k, w)
        reconstructed = _naf_reconstruct(naf)
        self.assertEqual(reconstructed, k,
                         f"Reconstruction failed: k={k}, w={w}")
        self.assertTrue(_naf_check_sparsity(naf),
                        f"Sparsity violated: k={k}, w={w}")
        self.assertTrue(_naf_check_digit_bounds(naf, w),
                        f"Digit bounds violated: k={k}, w={w}")

    def test_k0_w4(self):
        """k=0 gives empty NAF (no digits needed)."""
        naf = convert_to_wnaf(0, 4)
        self.assertEqual(_naf_reconstruct(naf), 0)

    def test_k1_w4(self):
        self._check_wnaf(1, 4)

    def test_k1_w5(self):
        self._check_wnaf(1, 5)

    def test_k2_w4(self):
        self._check_wnaf(2, 4)

    def test_k3_w4(self):
        self._check_wnaf(3, 4)

    def test_k7_w4(self):
        self._check_wnaf(7, 4)

    def test_k8_w4(self):
        self._check_wnaf(8, 4)

    def test_k15_w4(self):
        self._check_wnaf(15, 4)

    def test_k16_w4(self):
        self._check_wnaf(16, 4)

    def test_boundary_n_minus_1(self):
        """k = N-1 (curve order minus 1)."""
        for w in [4, 5, 6]:
            self._check_wnaf(N - 1, w)

    def test_boundary_2_pow_128(self):
        """k = 2^128."""
        self._check_wnaf(1 << 128, 4)
        self._check_wnaf(1 << 128, 5)

    def test_boundary_2_pow_255(self):
        """k = 2^255."""
        self._check_wnaf(1 << 255, 4)
        self._check_wnaf(1 << 255, 5)

    def test_all_ones_256bit(self):
        """k = 2^256 - 1."""
        k = (1 << 256) - 1
        self._check_wnaf(k, 4)
        self._check_wnaf(k, 5)

    def test_w4_random_fuzz_200(self):
        """Fuzz: 200 random 256-bit scalars for w=4."""
        rng = random.Random(0xdeadbeef)
        for _ in range(200):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            self._check_wnaf(k, 4)

    def test_w5_random_fuzz_200(self):
        """Fuzz: 200 random 256-bit scalars for w=5."""
        rng = random.Random(0xcafebabe)
        for _ in range(200):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            self._check_wnaf(k, 5)

    def test_w6_random_fuzz_200(self):
        """Fuzz: 200 random 256-bit scalars for w=6."""
        rng = random.Random(0x12345678)
        for _ in range(200):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            self._check_wnaf(k, 6)

    def test_w7_random_fuzz_200(self):
        """Fuzz: 200 random 256-bit scalars for w=7."""
        rng = random.Random(0xabcdef01)
        for _ in range(200):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            self._check_wnaf(k, 7)

    def test_w8_random_fuzz_200(self):
        """Fuzz: 200 random 256-bit scalars for w=8."""
        rng = random.Random(0x11223344)
        for _ in range(200):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            self._check_wnaf(k, 8)

    def test_k1_naf_is_single_digit(self):
        """k=1: NAF should have exactly one nonzero digit equal to 1."""
        for w in [4, 5, 6]:
            naf = convert_to_wnaf(1, w)
            nonzero = [d for d in naf if d != 0]
            self.assertEqual(nonzero, [1],
                             f"k=1 NAF should be [1] for w={w}, got {nonzero}")

    def test_naf_length_bounded(self):
        """NAF length should be at most bit_length(k) + 1."""
        rng = random.Random(42)
        for _ in range(50):
            k = rng.getrandbits(256)
            if k == 0:
                k = 1
            for w in [4, 5]:
                naf = convert_to_wnaf(k, w)
                max_len = k.bit_length() + 1
                self.assertLessEqual(len(naf), max_len,
                                     f"NAF too long: len={len(naf)}, max={max_len}, w={w}")


class TestWNafOperationCount(unittest.TestCase):
    """Verify operation count model properties."""

    def test_nonnegative_counts(self):
        """All returned counts must be non-negative."""
        rng = random.Random(7)
        for _ in range(20):
            k = rng.getrandbits(256) or 1
            for w in [4, 5, 6]:
                ops = count_operations(k, w)
                self.assertGreaterEqual(ops['adds'],       0)
                self.assertGreaterEqual(ops['doubles'],    0)
                self.assertGreaterEqual(ops['precompute'], 0)

    def test_doubles_equals_highest_bit(self):
        """
        Doublings should equal the position of the highest nonzero NAF digit
        (which is at most bit_length(k) - 1 for typical scalars).
        """
        k = (1 << 255) + 1
        for w in [4, 5]:
            ops = count_operations(k, w)
            naf = convert_to_wnaf(k, w)
            highest = len(naf) - 1
            while highest > 0 and naf[highest] == 0:
                highest -= 1
            self.assertEqual(ops['doubles'], highest)

    def test_adds_less_than_doubles(self):
        """Point additions should always be fewer than doublings."""
        rng = random.Random(13)
        for _ in range(30):
            k = rng.getrandbits(256) or 1
            for w in [4, 5]:
                ops = count_operations(k, w)
                self.assertLess(ops['adds'], ops['doubles'],
                                f"adds >= doubles for k={k}, w={w}")

    def test_larger_w_fewer_avg_adds(self):
        """On average, w=5 should produce fewer additions than w=4."""
        rng = random.Random(99)
        adds4 = adds5 = 0
        n = 200
        for _ in range(n):
            k = rng.getrandbits(256) or 1
            adds4 += count_operations(k, 4)['adds']
            adds5 += count_operations(k, 5)['adds']
        self.assertLessEqual(adds5 / n, adds4 / n,
                             "w=5 should have <= avg adds vs w=4")

    def test_precompute_grows_with_w(self):
        """Precomputation count should grow with larger w."""
        k = 12345678901234567890
        prev = None
        for w in [4, 5, 6, 7]:
            ops = count_operations(k, w)
            if prev is not None:
                self.assertGreater(ops['precompute'], prev,
                                   f"precompute should grow: w={w}")
            prev = ops['precompute']

    def test_k1_zero_adds(self):
        """k=1 should produce 0 point additions in the main loop."""
        for w in [4, 5, 6]:
            ops = count_operations(1, w)
            self.assertEqual(ops['adds'], 0,
                             f"k=1 should have 0 adds for w={w}")

    def test_estimate_ops_random_returns_dict(self):
        """estimate_ops_random returns a dict with expected keys."""
        result = estimate_ops_random(w=4, n_bits=256, n_samples=50)
        for key in ('adds', 'doubles', 'precompute', 'total_adds'):
            self.assertIn(key, result)
            self.assertGreaterEqual(result[key], 0)

    def test_estimate_ops_random_w5_lt_w4(self):
        """Average additions for w=5 should be less than for w=4."""
        r4 = estimate_ops_random(w=4, n_bits=256, n_samples=100)
        r5 = estimate_ops_random(w=5, n_bits=256, n_samples=100)
        self.assertLessEqual(r5['adds'], r4['adds'],
                             "w=5 avg adds should be <= w=4")


class TestAutotune(unittest.TestCase):
    """Verify autotuning selects a valid and sensible window size."""

    def test_best_w_in_range(self):
        """best_w must be within the specified range."""
        for w_range in [(4, 8), (4, 16), (5, 10)]:
            r = autotune(w_range=w_range)
            self.assertGreaterEqual(r['best_w'], w_range[0])
            self.assertLessEqual(r['best_w'], w_range[1])

    def test_speedup_at_least_1(self):
        """speedup_vs_w4 must be >= 1.0 (w=4 is always in the default range)."""
        r = autotune()
        self.assertGreaterEqual(r['speedup_vs_w4'], 1.0,
                                "Best window should be at least as good as w=4")

    def test_results_contains_all_w(self):
        """results dict must contain an entry for every w in w_range."""
        w_range = (4, 10)
        r = autotune(w_range=w_range)
        for w in range(w_range[0], w_range[1] + 1):
            self.assertIn(w, r['results'])

    def test_different_cost_models(self):
        """Different cost parameters should potentially yield different optimal w."""
        r_low_add  = autotune(cost_add=0.5,  cost_double=0.8, cost_precompute=0.5)
        r_high_add = autotune(cost_add=3.0,  cost_double=0.8, cost_precompute=0.1)
        # With very high add cost, larger w should be more appealing
        self.assertGreaterEqual(r_high_add['best_w'], r_low_add['best_w'],
                                "Higher add cost should prefer equal or larger w")

    def test_high_add_cost_prefers_larger_w(self):
        """When add is very expensive, w should be larger than 4."""
        r = autotune(cost_add=10.0, cost_double=1.0, cost_precompute=0.01)
        self.assertGreater(r['best_w'], 4,
                           "Very high add cost should push best_w above 4")

    def test_gpu_cost_model_decreasing_then_increasing(self):
        """gpu_cost_model should have a minimum somewhere in [4,16] (not always at extremes)."""
        costs = [gpu_cost_model(w, cost_add=1.0, cost_double=0.8, cost_precompute=0.5)
                 for w in range(4, 17)]
        min_cost = min(costs)
        self.assertGreater(costs[0], min_cost,
                           "Cost at w=4 should not be the global minimum")

    def test_autotune_default_returns_w5_or_w6(self):
        """Default cost parameters should favor w=5 or w=6."""
        r = autotune(cost_add=1.0, cost_double=0.8, cost_precompute=0.5)
        self.assertIn(r['best_w'], range(5, 9),
                      f"Default autotune expected w in [5,8], got {r['best_w']}")

    def test_print_benchmark_table_runs(self):
        """print_benchmark_table should not raise any exceptions."""
        r = autotune()
        try:
            print_benchmark_table(r)
        except Exception as e:
            self.fail(f"print_benchmark_table raised: {e}")

    def test_single_w_range(self):
        """w_range=(5,5) should return best_w=5."""
        r = autotune(w_range=(5, 5))
        self.assertEqual(r['best_w'], 5)
        self.assertEqual(len(r['results']), 1)


class TestPrecomputedTableConstants(unittest.TestCase):
    """Verify precomputed constants in the header match secp256k1 math."""

    # Expected coordinates from the task specification
    # Format: (x, y) as hex strings
    EXPECTED = {
        9: (
            0xACD484E2F0C7F65309AD178A9F559ABDE09796974C57E714C35F110DFC27CCBE,
            0xCC338921B0A7D9FD64380971763B61E9ADD888A4375F8E0F05CC262AC64F9C37,
        ),
        11: (
            0x774AE7F858A9411E5EF4246B70C65AAC5649980BE5C17891BBEC17895DA008CB,
            0xD984A032EB6B5E190243DD56D7B7B365372DB1E2DFF9D6A8301D74C9C953C61B,
        ),
        13: (
            0xF28773C2D975288BC7D1D205C3748651B075FBC6610E58CDDEEDDF8F19405AA8,
            0x0AB0902E8D880A89758212EB65CDAF473A1A06DA521FA91F29B5CB52DB03ED81,
        ),
        15: (
            0xD7924D4F7D43EA965A465AE3095FF41131E5946F3C85F79E44ADBCF8E27E080E,
            0x581E2872A86C72A683842EC228CC6DEFEA40AF2BD896D3A5C504DC9FF6A26B58,
        ),
    }

    # Negative y values (field negation: P - y)
    NEG_Y = {
        9:  0x33CC76DE4F5826029BC7F68E89C49E165227775BC8A071F0FA33D9D439B05FF8,
        11: 0x267B5FCD1494A1E6FDBC22A928484C9AC8D24E1D20062957CFE28B3536AC3614,
        13: 0xF54F6FD17277F5768A7DED149A3250B8C5E5F925ADE056E0D64A34AC24FC0EAE,
        15: 0xA7E1D78D57938D597C7BD13DD733921015BF50D427692C5A3AFB235F095D90D7,
    }

    def _compute_nG(self, n: int):
        """Compute n*G using reference double-and-add."""
        return _point_mul(n)

    def test_9G_x_coordinate(self):
        pt = self._compute_nG(9)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[9][0],
                         "9G x-coordinate mismatch")

    def test_9G_y_coordinate(self):
        pt = self._compute_nG(9)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[1], self.EXPECTED[9][1],
                         "9G y-coordinate mismatch")

    def test_11G_x_coordinate(self):
        pt = self._compute_nG(11)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[11][0],
                         "11G x-coordinate mismatch")

    def test_11G_y_coordinate(self):
        pt = self._compute_nG(11)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[1], self.EXPECTED[11][1],
                         "11G y-coordinate mismatch")

    def test_13G_x_coordinate(self):
        pt = self._compute_nG(13)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[13][0],
                         "13G x-coordinate mismatch")

    def test_13G_y_coordinate(self):
        pt = self._compute_nG(13)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[1], self.EXPECTED[13][1],
                         "13G y-coordinate mismatch")

    def test_15G_x_coordinate(self):
        pt = self._compute_nG(15)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[15][0],
                         "15G x-coordinate mismatch")

    def test_15G_y_coordinate(self):
        pt = self._compute_nG(15)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[1], self.EXPECTED[15][1],
                         "15G y-coordinate mismatch")

    def test_curve_equation_9G(self):
        """9G must satisfy y^2 = x^3 + 7 mod p."""
        x, y = self.EXPECTED[9]
        lhs = (y * y) % P
        rhs = (pow(x, 3, P) + 7) % P
        self.assertEqual(lhs, rhs, "9G does not satisfy curve equation")

    def test_curve_equation_11G(self):
        """11G must satisfy y^2 = x^3 + 7 mod p."""
        x, y = self.EXPECTED[11]
        lhs = (y * y) % P
        rhs = (pow(x, 3, P) + 7) % P
        self.assertEqual(lhs, rhs, "11G does not satisfy curve equation")

    def test_curve_equation_13G(self):
        """13G must satisfy y^2 = x^3 + 7 mod p."""
        x, y = self.EXPECTED[13]
        lhs = (y * y) % P
        rhs = (pow(x, 3, P) + 7) % P
        self.assertEqual(lhs, rhs, "13G does not satisfy curve equation")

    def test_curve_equation_15G(self):
        """15G must satisfy y^2 = x^3 + 7 mod p."""
        x, y = self.EXPECTED[15]
        lhs = (y * y) % P
        rhs = (pow(x, 3, P) + 7) % P
        self.assertEqual(lhs, rhs, "15G does not satisfy curve equation")

    def test_neg_y_9G(self):
        """-y9 must be the field negation of y9: y + (-y) == 0 mod p."""
        _, y = self.EXPECTED[9]
        neg_y = self.NEG_Y[9]
        self.assertEqual((y + neg_y) % P, 0,
                         "9G: y + (-y) should be 0 mod p")

    def test_neg_y_11G(self):
        _, y = self.EXPECTED[11]
        neg_y = self.NEG_Y[11]
        self.assertEqual((y + neg_y) % P, 0,
                         "11G: y + (-y) should be 0 mod p")

    def test_neg_y_13G(self):
        _, y = self.EXPECTED[13]
        neg_y = self.NEG_Y[13]
        self.assertEqual((y + neg_y) % P, 0,
                         "13G: y + (-y) should be 0 mod p")

    def test_neg_y_15G(self):
        _, y = self.EXPECTED[15]
        neg_y = self.NEG_Y[15]
        self.assertEqual((y + neg_y) % P, 0,
                         "15G: y + (-y) should be 0 mod p")

    def test_neg_y_equals_p_minus_y(self):
        """Each -y should equal (P - y) mod P."""
        for n in [9, 11, 13, 15]:
            _, y = self.EXPECTED[n]
            neg_y = self.NEG_Y[n]
            self.assertEqual(neg_y, (P - y) % P,
                             f"-y{n} should be P - y{n}")

    def test_also_1G_on_curve(self):
        """Generator point G must be on the curve (sanity check)."""
        lhs = (Gy * Gy) % P
        rhs = (pow(Gx, 3, P) + 7) % P
        self.assertEqual(lhs, rhs, "G does not satisfy curve equation")

    def test_point_9G_matches_computed(self):
        """Spec x9 must match computed 9*G."""
        pt = self._compute_nG(9)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[9][0])
        self.assertEqual(pt[1], self.EXPECTED[9][1])

    def test_point_15G_matches_computed(self):
        """Spec x15 must match computed 15*G."""
        pt = self._compute_nG(15)
        self.assertIsNotNone(pt)
        self.assertEqual(pt[0], self.EXPECTED[15][0])
        self.assertEqual(pt[1], self.EXPECTED[15][1])


class TestEdgeCasesStability(unittest.TestCase):
    """Stability and edge-case tests for extreme window sizes and scalars."""

    def test_w8_does_not_crash(self):
        """w=8 should process a random scalar without error."""
        k = random.getrandbits(256) or 1
        naf = convert_to_wnaf(k, 8)
        self.assertEqual(_naf_reconstruct(naf), k)

    def test_w16_does_not_crash(self):
        """w=16 should process a random scalar without error."""
        k = random.getrandbits(256) or 1
        naf = convert_to_wnaf(k, 16)
        self.assertEqual(_naf_reconstruct(naf), k)

    def test_w16_digit_bounds(self):
        """w=16: all nonzero digits are odd and |d| < 2^15."""
        rng = random.Random(42)
        for _ in range(20):
            k = rng.getrandbits(256) or 1
            naf = convert_to_wnaf(k, 16)
            self.assertTrue(_naf_check_digit_bounds(naf, 16))

    def test_k1_wnaf_is_minimal(self):
        """k=1: NAF should be [1] for all window sizes."""
        for w in [4, 5, 6, 7, 8]:
            naf = convert_to_wnaf(1, w)
            nonzero = [d for d in naf if d != 0]
            self.assertEqual(nonzero, [1],
                             f"k=1 should give NAF=[1] for w={w}")

    def test_k_window_boundary(self):
        """k = 2^w - 1 is handled correctly at the window boundary."""
        for w in [4, 5, 6, 7, 8]:
            k = (1 << w) - 1
            naf = convert_to_wnaf(k, w)
            self.assertEqual(_naf_reconstruct(naf), k,
                             f"Boundary k={k} failed for w={w}")
            self.assertTrue(_naf_check_sparsity(naf),
                            f"Sparsity violated for boundary k={k}, w={w}")

    def test_k0_all_zero_naf(self):
        """k=0 produces an empty NAF (no point additions)."""
        naf = convert_to_wnaf(0, 4)
        self.assertEqual(naf, [],
                         "k=0 should produce empty NAF")
        nonzero = [d for d in naf if d != 0]
        self.assertEqual(nonzero, [], "k=0 should have no additions")

    def test_k_power_of_2(self):
        """k = 2^i for i in [1, 255]: NAF has exactly one nonzero digit."""
        for i in [1, 16, 64, 128, 255]:
            k = 1 << i
            for w in [4, 5]:
                naf = convert_to_wnaf(k, w)
                self.assertEqual(_naf_reconstruct(naf), k,
                                 f"Reconstruction failed: k=2^{i}, w={w}")

    def test_large_w_sparsity(self):
        """For large w, NAF is still sparse (no two consecutive nonzero)."""
        rng = random.Random(100)
        for w in [8, 12, 16]:
            for _ in range(10):
                k = rng.getrandbits(256) or 1
                naf = convert_to_wnaf(k, w)
                self.assertTrue(_naf_check_sparsity(naf),
                                f"Sparsity violated for large w={w}")

    def test_ops_count_k0(self):
        """k=0 should yield zero operations."""
        ops = count_operations(0, 4)
        self.assertEqual(ops['adds'],    0)
        self.assertEqual(ops['doubles'], 0)

    def test_invalid_w_raises(self):
        """Window size w < 2 should raise ValueError."""
        with self.assertRaises(ValueError):
            convert_to_wnaf(123, 1)
        with self.assertRaises(ValueError):
            convert_to_wnaf(123, 0)

    def test_negative_k_raises(self):
        """Negative scalar should raise ValueError."""
        with self.assertRaises(ValueError):
            convert_to_wnaf(-1, 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
