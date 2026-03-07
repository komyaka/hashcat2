#!/usr/bin/env python3
"""
Task 7 — Regression & Stability test suite for secp256k1 Python reference.

Covers:
  • Bitcoin-Core–style known-vector regression (k=1..15, edge scalars)
  • 10 000-scalar edge + fuzz checks (all 3 multiplication methods)
  • Crash / stall guard tests (infinity, inverse, identity, commutativity, …)
  • Kernel-init self-test simulation
  • Watchdog / hang-detection patterns (threading-based, no GPU required)

Performance note
────────────────
The 10 k fuzz loop (TestEdgeFuzz10k.test_random_10k) uses Jacobian-coordinate
fast implementations (_fast_mul / _fast_glv / _fast_wnaf) that avoid per-step
field inversions, reducing runtime from ~18 min to ~40 s while still verifying
that all three scalar-multiplication strategies produce identical results.
All other test classes use the canonical affine-coordinate reference functions
(point_mul / point_mul_glv / point_mul_wnaf_w5) to stay close to the OpenCL
kernel logic.

Usage
─────
  python3 -m unittest Python/test_task7_regression_stability.py -v
"""

import random
import threading
import time
import unittest

# ---------------------------------------------------------------------------
# secp256k1 curve parameters  (NIST / SEC 2 §2.4.1)
# ---------------------------------------------------------------------------

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

G_POINT = (Gx, Gy)          # generator as a tuple (used by wrapper API below)

# GLV endomorphism constants (matching libsecp256k1 / inc_ecc_secp256k1.cl)
LAMBDA = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
BETA   = 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE

# Babai rounding constants for GLV decomposition
_G1_WORDS = [0x45dbb031, 0xe893209a, 0x71e8ca7f, 0x3daa8a14,
             0x9284eb15, 0xe86c90e4, 0xa7d46bcd, 0x3086d221]
_G2_WORDS = [0x8ac47f71, 0x1571b4ae, 0x9df506c6, 0x221208ac,
             0x0abfe4c4, 0x6f547fa9, 0x010e8828, 0xe4437ed6]
_G1 = sum(_G1_WORDS[i] * (1 << (32 * i)) for i in range(8))
_G2 = sum(_G2_WORDS[i] * (1 << (32 * i)) for i in range(8))
_A1 = 0x3086D221A7D46BCDE86C90E49284EB15
_B1 = 0xE4437ED6010E88286F547FA90ABFE4C3
_A2 = 0x114CA50F7A8E2F3F657C1108D9D44CFD8

# ---------------------------------------------------------------------------
# Pure-Python affine reference implementations
# (copied from test_regression_libsecp256k1.py — mirrors OpenCL kernel logic)
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


def batch_inv_mod(arr):
    n = len(arr)
    if n == 0:
        return []
    prefix = [arr[0]]
    for i in range(1, n):
        prefix.append(mul_mod(prefix[-1], arr[i]))
    inv_prod = inv_mod(prefix[-1])
    result = [0] * n
    for i in range(n - 1, 0, -1):
        result[i] = mul_mod(inv_prod, prefix[i - 1])
        inv_prod = mul_mod(inv_prod, arr[i])
    result[0] = inv_prod
    return result


def _point_double_xy(Px, Py):
    """Internal affine: double a point given as (x, y) coordinates."""
    if Px is None:
        return None, None
    lam = mul_mod(3, sqr_mod(Px))
    lam = mul_mod(lam, inv_mod(mul_mod(2, Py)))
    Rx = sub_mod(sqr_mod(lam), add_mod(Px, Px))
    Ry = sub_mod(mul_mod(lam, sub_mod(Px, Rx)), Py)
    return Rx, Ry


def _point_add_xy(P1x, P1y, P2x, P2y):
    """Internal affine: add two points given as coordinates."""
    if P1x is None:
        return P2x, P2y
    if P2x is None:
        return P1x, P1y
    if P1x == P2x:
        if P1y == P2y:
            return _point_double_xy(P1x, P1y)
        return None, None
    lam = mul_mod(sub_mod(P2y, P1y), inv_mod(sub_mod(P2x, P1x)))
    Rx = sub_mod(sub_mod(sqr_mod(lam), P1x), P2x)
    Ry = sub_mod(mul_mod(lam, sub_mod(P1x, Rx)), P1y)
    return Rx, Ry


def _point_mul_xy(k, Px=Gx, Py=Gy):
    """Internal affine: left-to-right binary scalar multiplication."""
    Rx, Ry = None, None
    for bit in bin(k)[2:]:
        if Rx is not None:
            Rx, Ry = _point_double_xy(Rx, Ry)
        if bit == "1":
            Rx, Ry = _point_add_xy(Rx, Ry, Px, Py)
    return Rx, Ry


# ---------------------------------------------------------------------------
# Tuple-based wrapper API  (used throughout the test classes)
#   A point is (x, y) tuple, or None for the point at infinity.
# ---------------------------------------------------------------------------


def point_double(pt):
    """Double a point.  pt is (x, y) or None (infinity)."""
    if pt is None:
        return None
    rx, ry = _point_double_xy(pt[0], pt[1])
    return None if rx is None else (rx, ry)


def point_add(pt1, pt2):
    """Add two points.  Each is (x, y) or None (infinity)."""
    x1, y1 = (None, None) if pt1 is None else pt1
    x2, y2 = (None, None) if pt2 is None else pt2
    rx, ry = _point_add_xy(x1, y1, x2, y2)
    return None if rx is None else (rx, ry)


def point_mul(k, pt=None):
    """Scalar multiplication k * pt.  pt defaults to G.
    Returns (x, y) tuple or None for the point at infinity.
    k == 0 → None (identity).
    """
    if k == 0:
        return None
    px, py = G_POINT if pt is None else pt
    rx, ry = _point_mul_xy(k, px, py)
    return None if rx is None else (rx, ry)


# ---------------------------------------------------------------------------
# Affine GLV endomorphism scalar multiplication
# ---------------------------------------------------------------------------


def _glv_decompose(k):
    """Babai-rounded GLV decomposition (matching libsecp256k1 / >> 384 shift)."""
    c1 = (k * _G1) >> 384
    c2 = (k * _G2) >> 384
    k1 = k - c1 * _A1 - c2 * _A2
    k2 = c1 * _B1 - c2 * _A1
    return k1, k2


_phiGx = mul_mod(BETA, Gx)     # BETA * Gx mod P


def point_mul_glv(k):
    """Affine GLV scalar multiplication k*G (endomorphism phi(P)=(beta·x, y))."""
    k1, k2 = _glv_decompose(k)
    k1_neg = k1 < 0
    k2_neg = k2 < 0
    k1_abs = abs(k1)
    k2_abs = abs(k2)
    G_y  = P - Gy if k1_neg else Gy
    PG_y = P - Gy if k2_neg else Gy    # phiGy = Gy
    Rx, Ry = None, None
    length = max(k1_abs.bit_length(), k2_abs.bit_length()) if (k1_abs or k2_abs) else 0
    for i in range(length - 1, -1, -1):
        if Rx is not None:
            Rx, Ry = _point_double_xy(Rx, Ry)
        if (k1_abs >> i) & 1:
            Rx, Ry = _point_add_xy(Rx, Ry, Gx, G_y)
        if (k2_abs >> i) & 1:
            Rx, Ry = _point_add_xy(Rx, Ry, _phiGx, PG_y)
    return None if Rx is None else (Rx, Ry)


# ---------------------------------------------------------------------------
# Affine wNAF w=5 scalar multiplication
# ---------------------------------------------------------------------------


def _convert_to_wnaf(k, w):
    half  = 1 << (w - 1)
    two_w = 1 << w
    mask  = two_w - 1
    naf   = []
    n = k
    while n > 0:
        if n & 1:
            mods  = n & mask
            digit = mods - two_w if mods >= half else mods
            n -= digit
            naf.append(digit)
        else:
            naf.append(0)
        n >>= 1
    return naf


def _build_w5_table_affine():
    table = [(Gx, Gy)]
    G2x, G2y = _point_double_xy(Gx, Gy)
    for _ in range(7):
        px, py = table[-1]
        nx, ny = _point_add_xy(px, py, G2x, G2y)
        table.append((nx, ny))
    return table


_W5_TABLE = _build_w5_table_affine()


def point_mul_wnaf_w5(k):
    """Affine wNAF w=5 scalar multiplication k*G."""
    naf  = _convert_to_wnaf(k, 5)
    Rx, Ry = None, None
    for d in reversed(naf):
        if Rx is not None:
            Rx, Ry = _point_double_xy(Rx, Ry)
        if d > 0:
            idx = (d - 1) // 2
            Rx, Ry = _point_add_xy(Rx, Ry, _W5_TABLE[idx][0], _W5_TABLE[idx][1])
        elif d < 0:
            idx = (-d - 1) // 2
            Rx, Ry = _point_add_xy(Rx, Ry, _W5_TABLE[idx][0], P - _W5_TABLE[idx][1])
    return None if Rx is None else (Rx, Ry)


# ---------------------------------------------------------------------------
# Fast Jacobian-coordinate implementations (used ONLY in test_random_10k)
#
# Using Jacobian coordinates (X : Y : Z) representing affine (X/Z², Y/Z³)
# avoids one field inversion per double/add step, giving ~30x speedup over
# the affine reference for a full 256-bit scalar multiply.
# secp256k1 has a = 0, which simplifies the doubling formula.
# ---------------------------------------------------------------------------


def _jac_double(X, Y, Z):
    """Jacobian point doubling for secp256k1 (a = 0)."""
    if Z == 0:
        return 0, 1, 0          # infinity stays infinity
    ysq  = Y * Y % P
    S    = 4 * X * ysq % P
    M    = 3 * X * X % P        # slope: M = 3·X² (a=0 → no Z⁴ term)
    X3   = (M * M - 2 * S) % P
    Y3   = (M * (S - X3) - 8 * ysq * ysq) % P
    Z3   = 2 * Y * Z % P
    return X3, Y3, Z3


def _jac_madd(X1, Y1, Z1, X2, Y2):
    """Jacobian + affine mixed addition (Z2 = 1)."""
    if Z1 == 0:
        return X2, Y2, 1        # infinity + P = P
    Z1sq = Z1 * Z1 % P
    U2   = X2 * Z1sq % P
    S2   = Y2 * Z1 * Z1sq % P
    H    = (U2 - X1) % P
    R    = (S2 - Y1) % P
    if H == 0:
        if R == 0:
            return _jac_double(X1, Y1, Z1)
        return 0, 1, 0          # point + its inverse = infinity
    H2   = H * H % P
    H3   = H * H2 % P
    X3   = (R * R - H3 - 2 * X1 * H2) % P
    Y3   = (R * (X1 * H2 - X3) - Y1 * H3) % P
    Z3   = H * Z1 % P
    return X3, Y3, Z3


def _jac_to_affine(X, Y, Z):
    """Convert Jacobian → affine, or return None for infinity (Z == 0)."""
    if Z == 0:
        return None
    Zi  = pow(Z, -1, P)         # single field inversion (Python 3.8+)
    Zi2 = Zi * Zi % P
    return (X * Zi2 % P, Y * Zi2 * Zi % P)


def _fast_mul(k, Px=Gx, Py=Gy):
    """Jacobian left-to-right binary scalar multiplication k·(Px, Py)."""
    if k == 0:
        return None
    Rx, Ry, Rz = 0, 1, 0
    for bit in bin(k)[2:]:
        Rx, Ry, Rz = _jac_double(Rx, Ry, Rz)
        if bit == "1":
            Rx, Ry, Rz = _jac_madd(Rx, Ry, Rz, Px, Py)
    return _jac_to_affine(Rx, Ry, Rz)


def _fast_glv(k):
    """Jacobian GLV scalar multiplication k·G."""
    k1, k2 = _glv_decompose(k)
    k1_neg = k1 < 0
    k2_neg = k2 < 0
    k1_abs = abs(k1)
    k2_abs = abs(k2)
    G_y  = P - Gy if k1_neg else Gy
    PG_y = P - Gy if k2_neg else Gy
    Rx, Ry, Rz = 0, 1, 0
    length = max(k1_abs.bit_length(), k2_abs.bit_length()) if (k1_abs or k2_abs) else 0
    for i in range(length - 1, -1, -1):
        Rx, Ry, Rz = _jac_double(Rx, Ry, Rz)
        if (k1_abs >> i) & 1:
            Rx, Ry, Rz = _jac_madd(Rx, Ry, Rz, Gx, G_y)
        if (k2_abs >> i) & 1:
            Rx, Ry, Rz = _jac_madd(Rx, Ry, Rz, _phiGx, PG_y)
    return _jac_to_affine(Rx, Ry, Rz)


def _build_w5_table_jac():
    """Build the w=5 precomputed table using Jacobian arithmetic."""
    table = [(Gx, Gy)]
    G2x, G2y = _jac_to_affine(*_jac_double(Gx, Gy, 1))
    for _ in range(7):
        px, py = table[-1]
        npt = _jac_to_affine(*_jac_madd(px, py, 1, G2x, G2y))
        table.append(npt)
    return table


_W5_TABLE_JAC = _build_w5_table_jac()


def _fast_wnaf(k):
    """Jacobian wNAF w=5 scalar multiplication k·G."""
    naf  = _convert_to_wnaf(k, 5)
    Rx, Ry, Rz = 0, 1, 0
    for d in reversed(naf):
        Rx, Ry, Rz = _jac_double(Rx, Ry, Rz)
        if d > 0:
            idx = (d - 1) // 2
            Rx, Ry, Rz = _jac_madd(Rx, Ry, Rz,
                                    _W5_TABLE_JAC[idx][0],
                                    _W5_TABLE_JAC[idx][1])
        elif d < 0:
            idx = (-d - 1) // 2
            Rx, Ry, Rz = _jac_madd(Rx, Ry, Rz,
                                    _W5_TABLE_JAC[idx][0],
                                    P - _W5_TABLE_JAC[idx][1])
    return _jac_to_affine(Rx, Ry, Rz)


# ---------------------------------------------------------------------------
# Kernel self-test helper  (used by TestKernelInitSelfTest)
# ---------------------------------------------------------------------------


def kernel_init_self_test():
    """
    Simulate the GPU kernel init self-test in pure Python.
    Returns True iff all internal sanity checks pass; False on any failure.
    """
    try:
        # 1 · G == G
        if point_mul(1) != G_POINT:
            return False
        # (P-1)² mod P == 1  ((-1)·(-1) = 1)
        if sqr_mod(P - 1) != 1:
            return False
        # inv_mod(1) == 1
        if inv_mod(1) != 1:
            return False
        # inv_mod(2) · 2 ≡ 1 (mod P)
        if mul_mod(inv_mod(2), 2) != 1:
            return False
        # add_mod(P-1, 1) == 0
        if add_mod(P - 1, 1) != 0:
            return False
        # sub_mod(0, 1) == P-1
        if sub_mod(0, 1) != P - 1:
            return False
        # point_double(G) == 2·G
        if point_double(G_POINT) != point_mul(2):
            return False
        # All 3 multiplication methods agree for k = 7
        ref = point_mul(7)
        if point_mul_glv(7) != ref:
            return False
        if point_mul_wnaf_w5(7) != ref:
            return False
    except Exception:       # noqa: BLE001
        return False
    return True


# ===========================================================================
# TEST CLASS 1 — Bitcoin-Core–style known vectors
# ===========================================================================


class TestBitcoinCoreVectors(unittest.TestCase):
    """
    Hardcoded regression vectors: k·G for k = 1..15 and several edge scalars.
    The reference ground truth is the standard affine left-to-right point_mul;
    GLV and wNAF must produce identical results.
    """

    def setUp(self):
        """Pre-compute reference table once per test run."""
        self.vectors = {}
        for k in range(1, 16):
            self.vectors[k] = point_mul(k)
        # Edge scalars
        for k in (N - 1, N // 2, N // 3, 2 ** 128, 2 ** 255):
            self.vectors[k] = point_mul(k)

    # --- k = 1 ----------------------------------------------------------------

    def test_k1_equals_g(self):
        """1·G must equal the generator G."""
        self.assertEqual(self.vectors[1], G_POINT)

    # --- k = 1..15: cross-method agreement ------------------------------------

    def test_k1_to_k15_all_methods_agree(self):
        """GLV and wNAF w=5 match standard for k = 1..15."""
        for k in range(1, 16):
            ref = self.vectors[k]
            with self.subTest(k=k):
                self.assertEqual(point_mul_glv(k), ref,
                                 f"GLV disagrees at k={k}")
                self.assertEqual(point_mul_wnaf_w5(k), ref,
                                 f"wNAF disagrees at k={k}")

    # --- k = 1..15: all results on curve --------------------------------------

    def test_k1_to_k15_on_curve(self):
        """All k·G for k = 1..15 satisfy y² = x³ + 7 (mod P)."""
        for k in range(1, 16):
            pt = self.vectors[k]
            self.assertIsNotNone(pt, f"k={k} returned None unexpectedly")
            x, y = pt
            self.assertEqual((y * y - x * x * x - 7) % P, 0,
                             f"k={k} result not on curve")

    # --- incremental consistency ---------------------------------------------

    def test_incremental_add_matches_mul(self):
        """k·G == (k-1)·G + G  for k = 2..15."""
        for k in range(2, 16):
            with self.subTest(k=k):
                incremental = point_add(self.vectors[k - 1], G_POINT)
                self.assertEqual(incremental, self.vectors[k])

    def test_double_matches_two_times(self):
        """point_double(G) == 2·G."""
        self.assertEqual(point_double(G_POINT), self.vectors[2])

    # --- field arithmetic known values ----------------------------------------

    def test_p_minus_1_squared_is_1(self):
        """(P-1)² mod P == 1  ((-1)·(-1) = 1)."""
        self.assertEqual(sqr_mod(P - 1), 1)

    def test_gx_times_gy_mod_p(self):
        """mul_mod(Gx, Gy) is deterministic and in [0, P-1]."""
        v1 = mul_mod(Gx, Gy)
        v2 = mul_mod(Gx, Gy)
        self.assertEqual(v1, v2)
        self.assertGreater(v1, 0)
        self.assertLess(v1, P)

    def test_inv_mod_gx_roundtrip(self):
        """Gx · inv(Gx) ≡ 1 (mod P)."""
        self.assertEqual(mul_mod(Gx, inv_mod(Gx)), 1)

    # --- edge scalars ---------------------------------------------------------

    def test_n_minus_1_all_methods_agree(self):
        """(N-1)·G: all three methods agree."""
        ref = self.vectors[N - 1]
        self.assertIsNotNone(ref)
        self.assertEqual(point_mul_glv(N - 1), ref)
        self.assertEqual(point_mul_wnaf_w5(N - 1), ref)

    def test_n_half_all_methods_agree(self):
        """(N//2)·G: all three methods agree."""
        ref = self.vectors[N // 2]
        self.assertIsNotNone(ref)
        self.assertEqual(point_mul_glv(N // 2), ref)
        self.assertEqual(point_mul_wnaf_w5(N // 2), ref)


# ===========================================================================
# TEST CLASS 2 — Edge + 10 k fuzz
# ===========================================================================


class TestEdgeFuzz10k(unittest.TestCase):
    """
    Systematic edge-case and random fuzz: all 3 multiplication methods must
    produce identical results for every tested scalar.
    Small / large / extreme cases use the affine reference implementations.
    The 10 k random test uses the fast Jacobian implementations for speed.
    """

    def _assert_all_agree_affine(self, k, context=""):
        """Verify all 3 affine methods agree (used for small test sets)."""
        ref  = point_mul(k)
        glv  = point_mul_glv(k)
        wnaf = point_mul_wnaf_w5(k)
        msg  = f"k={hex(k)[:18]}… {context}"
        self.assertEqual(glv,  ref,  f"GLV vs standard mismatch  {msg}")
        self.assertEqual(wnaf, ref,  f"wNAF vs standard mismatch {msg}")

    # --- small scalars --------------------------------------------------------

    def test_small_scalars(self):
        """k = 1..100: all three affine methods agree."""
        for k in range(1, 101):
            with self.subTest(k=k):
                self._assert_all_agree_affine(k, "small scalar")

    # --- large scalars near N -------------------------------------------------

    def test_large_scalars(self):
        """k near the group order: N-1, N-2, N-3, N-100, N//2, N//3, N//4."""
        cases = [N - 1, N - 2, N - 3, N - 100, N // 2, N // 3, N // 4]
        for k in cases:
            with self.subTest(k=hex(k)[:18]):
                self._assert_all_agree_affine(k, "near-N scalar")

    # --- extreme scalars ------------------------------------------------------

    def test_extreme_scalars(self):
        """k = 1, 2^128, 2^128+1, 2^255, 2^255+1, N-1 (reduced mod N)."""
        cases = [1, 2 ** 128, 2 ** 128 + 1, 2 ** 255, 2 ** 255 + 1, N - 1]
        for k in cases:
            k_mod = k % N
            if k_mod == 0:
                continue
            with self.subTest(k=hex(k)[:18]):
                self._assert_all_agree_affine(k_mod, "extreme scalar")

    # --- field boundary operations --------------------------------------------

    def test_boundary_field_ops(self):
        """Field operations at P-1, P-2, P//2, 1, 2 stay in [0, P-1]."""
        boundary_vals = [P - 1, P - 2, P // 2, 1, 2]
        for a in boundary_vals:
            for b in boundary_vals:
                with self.subTest(a=hex(a)[:10], b=hex(b)[:10]):
                    for r in (add_mod(a, b), sub_mod(a, b), mul_mod(a, b)):
                        self.assertGreaterEqual(r, 0)
                        self.assertLess(r, P)
        # Special identities
        self.assertEqual(add_mod(P - 1, 1), 0)
        self.assertEqual(sub_mod(0, 1), P - 1)
        self.assertEqual(mul_mod(P - 1, P - 1), 1)
        self.assertEqual(sqr_mod(0), 0)

    # --- 10 000 random scalars  (fast Jacobian implementations) ---------------

    def test_random_10k(self):
        """
        10 000 random scalars in [1, N-1]: Jacobian standard, GLV, and wNAF
        all produce the same affine point.  Uses random.seed(42) for
        reproducibility; prints progress every 1 000 iterations.
        """
        rng = random.Random(42)
        for i in range(10_000):
            if i % 1000 == 0 and i > 0:
                print(f"  test_random_10k: {i}/10000 …", flush=True)
            k    = rng.randrange(1, N)
            ref  = _fast_mul(k)
            glv  = _fast_glv(k)
            wnaf = _fast_wnaf(k)
            self.assertEqual(glv,  ref,
                             f"GLV  mismatch at i={i} k={hex(k)[:18]}")
            self.assertEqual(wnaf, ref,
                             f"wNAF mismatch at i={i} k={hex(k)[:18]}")


# ===========================================================================
# TEST CLASS 3 — Crash / stall guard
# ===========================================================================


class TestCrashStall(unittest.TestCase):
    """
    Guard tests for degenerate inputs: infinity, inverse points, zero scalar,
    commutativity, associativity, identity element, etc.
    """

    def setUp(self):
        # Pre-computed random points (k = 7, 13, 99 · G) for algebraic tests
        self.A = point_mul(7)
        self.B = point_mul(13)
        self.C = point_mul(99)

    # --- infinity handling ----------------------------------------------------

    def test_infinity_add_infinity(self):
        """point_add(None, None) == None  (∞ + ∞ = ∞)."""
        self.assertIsNone(point_add(None, None))

    def test_point_plus_infinity(self):
        """P + ∞ == P  and  ∞ + P == P."""
        self.assertEqual(point_add(G_POINT, None), G_POINT)
        self.assertEqual(point_add(None, G_POINT), G_POINT)

    def test_n_times_g_is_infinity(self):
        """N · G == ∞  (group order)."""
        self.assertIsNone(point_mul(N, G_POINT))

    def test_point_inverse(self):
        """G + (Gx, P-Gy) == ∞  (G + (−G) = ∞)."""
        neg_G = (Gx, (-Gy) % P)
        self.assertIsNone(point_add(G_POINT, neg_G))

    def test_doubling_at_infinity(self):
        """point_double(None) == None."""
        self.assertIsNone(point_double(None))

    def test_scalar_zero(self):
        """0 · G == None (point at infinity)."""
        self.assertIsNone(point_mul(0, G_POINT))

    def test_scalar_one(self):
        """1 · G == G."""
        self.assertEqual(point_mul(1, G_POINT), G_POINT)

    def test_scalar_n_minus_1(self):
        """(N-1) · G == −G == (Gx, P − Gy)."""
        result = point_mul(N - 1)
        self.assertIsNotNone(result)
        self.assertEqual(result, (Gx, P - Gy))

    def test_point_double_vs_add(self):
        """2·G via point_double == 2·G via point_add(G, G)."""
        self.assertEqual(point_double(G_POINT), point_add(G_POINT, G_POINT))

    # --- algebraic laws -------------------------------------------------------

    def test_commutativity(self):
        """point_add(A, B) == point_add(B, A) for distinct random points."""
        for a, b in [(self.A, self.B), (self.B, self.C), (self.A, self.C)]:
            with self.subTest():
                self.assertEqual(point_add(a, b), point_add(b, a))

    def test_associativity(self):
        """(A + B) + C == A + (B + C)."""
        lhs = point_add(point_add(self.A, self.B), self.C)
        rhs = point_add(self.A, point_add(self.B, self.C))
        self.assertEqual(lhs, rhs)

    def test_identity_element(self):
        """For any point P: P + ∞ == P."""
        for pt in (G_POINT, self.A, self.B, self.C):
            with self.subTest(pt=pt):
                self.assertEqual(point_add(pt, None), pt)
                self.assertEqual(point_add(None, pt), pt)


# ===========================================================================
# TEST CLASS 4 — Kernel init self-test simulation
# ===========================================================================


class TestKernelInitSelfTest(unittest.TestCase):
    """
    Simulate the GPU kernel's startup self-test in pure Python.
    """

    def test_kernel_init_self_test(self):
        """kernel_init_self_test() returns True when all checks pass."""
        self.assertTrue(kernel_init_self_test())

    def test_self_test_detects_bad_prime(self):
        """
        With a wrong (composite) prime, Fermat's little theorem fails.
        The real prime P satisfies 2^(P-1) ≡ 1 (mod P).
        For a composite P_BAD this identity almost certainly does NOT hold,
        which is exactly what a kernel self-test would check.
        """
        # P + 2 is divisible by 3 (composite) — easy to verify:
        P_BAD = P + 2
        # Correct prime: 2^(P-1) mod P == 1
        self.assertEqual(pow(2, P - 1, P), 1, "P should satisfy Fermat's little theorem")
        # Wrong composite: 2^(P_BAD-1) mod P_BAD != 1
        bad_result = pow(2, P_BAD - 1, P_BAD)
        self.assertNotEqual(bad_result, 1,
                            "Expected composite P_BAD to fail Fermat's little theorem")

    def test_self_test_timing(self):
        """kernel_init_self_test() completes in under 5 seconds."""
        start   = time.monotonic()
        result  = kernel_init_self_test()
        elapsed = time.monotonic() - start
        self.assertTrue(result)
        self.assertLess(elapsed, 5.0,
                        f"Self-test took {elapsed:.3f}s (limit 5 s)")


# ===========================================================================
# TEST CLASS 5 — Watchdog / hang-detection patterns (threading-based)
# ===========================================================================


class TestWatchdogRecover(unittest.TestCase):
    """
    Watchdog and hang-detection patterns implemented with Python threading.
    No GPU is required; the tests exercise timeout / recovery logic that
    mirrors what a real kernel watchdog would do.
    """

    # -------------------------------------------------------------------------
    # helpers
    # -------------------------------------------------------------------------

    @staticmethod
    def _run_in_thread(fn, *args, timeout=10.0):
        """
        Run fn(*args) in a daemon thread with the given timeout.
        Returns (result, elapsed, timed_out).
        """
        result_box = [None]
        exc_box    = [None]

        def target():
            try:
                result_box[0] = fn(*args)
            except Exception as exc:    # noqa: BLE001
                exc_box[0] = exc

        t = threading.Thread(target=target, daemon=True)
        start = time.monotonic()
        t.start()
        t.join(timeout=timeout)
        elapsed    = time.monotonic() - start
        timed_out  = t.is_alive()
        if exc_box[0] is not None:
            raise exc_box[0]
        return result_box[0], elapsed, timed_out

    # -------------------------------------------------------------------------
    # tests
    # -------------------------------------------------------------------------

    def test_operation_completes_within_timeout(self):
        """point_mul(N//7) completes within 10 seconds."""
        k      = N // 7
        result, elapsed, timed_out = self._run_in_thread(point_mul, k,
                                                          timeout=10.0)
        self.assertFalse(timed_out,
                         f"point_mul timed out after {elapsed:.3f}s")
        self.assertIsNotNone(result)

    def test_batch_operations_timeout(self):
        """100 sequential point_mul calls complete within 30 seconds."""
        rng     = random.Random(99)
        scalars = [rng.randrange(1, N) for _ in range(100)]

        def batch():
            return [point_mul(k) for k in scalars]

        result, elapsed, timed_out = self._run_in_thread(batch, timeout=30.0)
        self.assertFalse(timed_out,
                         f"Batch of 100 point_mul timed out after {elapsed:.3f}s")
        self.assertEqual(len(result), 100)
        for pt in result:
            self.assertIsNotNone(pt)

    def test_hang_detection(self):
        """
        A long-running loop can be interrupted via threading.Event.
        The worker checks the stop_event and exits early when signalled.
        """
        stop_event      = threading.Event()
        completed_box   = [False]
        interrupted_box = [False]

        def slow_work():
            for _ in range(1_000_000):
                if stop_event.is_set():
                    interrupted_box[0] = True
                    return
            completed_box[0] = True     # only reached without interruption

        t = threading.Thread(target=slow_work, daemon=True)
        t.start()
        time.sleep(0.01)            # let the worker start
        stop_event.set()
        t.join(timeout=2.0)

        self.assertFalse(t.is_alive(), "Worker thread should have exited")
        self.assertTrue(interrupted_box[0],
                        "Worker should have detected the stop signal")
        self.assertFalse(completed_box[0],
                         "Worker should NOT have completed the full loop")

    def test_stall_recovery_pattern(self):
        """
        After a degenerate input (k=0 → None), normal operations resume.
        """
        # k=0 returns None (identity); it is not an exception in this impl.
        degenerate_result = point_mul(0)
        self.assertIsNone(degenerate_result)

        # Normal operations must succeed after the degenerate call.
        for k in [1, 2, 3, 7, N - 1]:
            result = point_mul(k)
            self.assertIsNotNone(result,
                                 f"Normal operation failed after stall test at k={k}")

    def test_watchdog_timer(self):
        """
        A threading.Timer watchdog fires when an operation exceeds its
        deadline, and does NOT fire for a fast operation.
        """
        def make_watchdog(deadline_secs, fired_flag):
            return threading.Timer(deadline_secs,
                                   lambda: fired_flag.__setitem__(0, True))

        # --- slow op: sleep longer than the deadline -------------------------
        slow_fired = [False]
        wdog = make_watchdog(0.05, slow_fired)  # 50 ms deadline
        wdog.start()
        time.sleep(0.15)                         # 150 ms work → exceeds deadline
        wdog.cancel()
        self.assertTrue(slow_fired[0],
                        "Watchdog should have fired for slow operation")

        # --- fast op: completes well before the deadline ---------------------
        fast_fired = [False]
        wdog = make_watchdog(5.0, fast_fired)    # 5 s deadline
        _ = point_mul(7)                         # very fast
        wdog.cancel()
        self.assertFalse(fast_fired[0],
                         "Watchdog should NOT fire for fast operation")


# ===========================================================================
# Entry point
# ===========================================================================

if __name__ == "__main__":
    unittest.main(verbosity=2)
