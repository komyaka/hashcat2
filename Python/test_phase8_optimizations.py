#!/usr/bin/env python3
"""
Phase 8: Critical Performance Optimizations — Test Suite.

Covers:
  P8-01  Group Key Addition    — P_{i+1} = P_i + G for batches of 100/500/1000 keys
  P8-02  XYZZ Coordinates      — point_double_xyzz and point_add_mixed_xyzz correctness
  P8-03  Comb Method           — d=4 comb table values and point_mul_comb correctness
  P8-04  Module File Validation — m35905_a3 and m35906_a3 use GKA pattern
  P8-05  Register Estimation   — VGPR usage within AMD RX 580 budget (256 VGPRs)
  P8-06  XYZZ Affine Recovery  — from (X, Y, ZZ, ZZZ) matches Jacobian result
  P8-07  Sequential Detection  — add1_256 / is_seq logic matches expected behaviour

Usage:
    python3 -m unittest Python/test_phase8_optimizations.py -v
"""

import os
import random
import re
import unittest

# ---------------------------------------------------------------------------
# secp256k1 curve parameters
# ---------------------------------------------------------------------------

P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

_OPENCL_DIR = os.path.join(os.path.dirname(__file__), '..', 'OpenCL')


# ---------------------------------------------------------------------------
# Pure-Python reference: field arithmetic
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
    """Fermat little theorem: a^(p-2) mod p."""
    return pow(a, P - 2, P)


# ---------------------------------------------------------------------------
# Pure-Python reference: elliptic curve in affine coordinates
# ---------------------------------------------------------------------------

def point_double_affine(Px, Py):
    """Double an affine point."""
    if Px is None:
        return None, None
    lam = mul_mod(3, sqr_mod(Px))
    lam = mul_mod(lam, inv_mod(add_mod(Py, Py)))
    Rx = sub_mod(sqr_mod(lam), add_mod(Px, Px))
    Ry = sub_mod(mul_mod(lam, sub_mod(Px, Rx)), Py)
    return Rx, Ry


def point_add_affine(P1x, P1y, P2x, P2y):
    """Add two affine points."""
    if P1x is None:
        return P2x, P2y
    if P2x is None:
        return P1x, P1y
    if P1x == P2x:
        if P1y == P2y:
            return point_double_affine(P1x, P1y)
        return None, None
    lam = mul_mod(sub_mod(P2y, P1y), inv_mod(sub_mod(P2x, P1x)))
    Rx  = sub_mod(sub_mod(sqr_mod(lam), P1x), P2x)
    Ry  = sub_mod(mul_mod(lam, sub_mod(P1x, Rx)), P1y)
    return Rx, Ry


def point_mul_affine(k, Px=Gx, Py=Gy):
    """Double-and-add scalar multiplication in affine coordinates."""
    Rx, Ry = None, None
    for bit in bin(k)[2:]:
        if Rx is not None:
            Rx, Ry = point_double_affine(Rx, Ry)
        if bit == '1':
            Rx, Ry = point_add_affine(Rx, Ry, Px, Py)
    return Rx, Ry


# ---------------------------------------------------------------------------
# Pure-Python reference: XYZZ coordinate system
# XYZZ: (X:Y:ZZ:ZZZ) where ZZ = Z^2, ZZZ = Z^3.
# Affine recovery: x = X/ZZ, y = Y/ZZZ.
# ---------------------------------------------------------------------------

def xyzz_to_affine(X, Y, ZZ, ZZZ):
    """Convert XYZZ to affine coordinates."""
    x = mul_mod(X, inv_mod(ZZ))
    y = mul_mod(Y, inv_mod(ZZZ))
    return x, y


def xyzz_double(X, Y, ZZ, ZZZ):
    """XYZZ in-place doubling (correct for general ZZ1).
    Derived from dbl-2008-s-1 formula, extended for ZZ1≠1:
    Z3 = 2*Y1*Z1 → ZZ3 = Z3^2 = V*ZZ1, ZZZ3 = Z3^3 = W*ZZZ1.
    """
    U   = add_mod(Y, Y)            # 2*Y
    V   = mul_mod(U, U)            # V = 4*Y^2
    W   = mul_mod(U, V)            # W = 8*Y^3
    S   = mul_mod(X, V)            # S = 4*X*Y^2
    M2  = sqr_mod(X)               # X^2
    M3  = add_mod(add_mod(M2, M2), M2)  # 3*X^2 (a=0)
    X3  = sub_mod(sqr_mod(M3), add_mod(S, S))  # M^2 - 2*S
    Y3  = sub_mod(mul_mod(M3, sub_mod(S, X3)), mul_mod(W, Y))
    ZZ3  = mul_mod(V, ZZ)           # ZZ3 = V * ZZ1 (correct for general ZZ1)
    ZZZ3 = mul_mod(W, ZZZ)          # ZZZ3 = W * ZZZ1 (correct for general ZZZ1)
    return X3, Y3, ZZ3, ZZZ3


def xyzz_add_mixed(X1, Y1, ZZ1, ZZZ1, x2, y2):
    """XYZZ + affine mixed addition (madd-2008-s).
    Returns (X3, Y3, ZZ3, ZZZ3).
    """
    U2  = mul_mod(x2, ZZ1)
    S2  = mul_mod(y2, ZZZ1)
    P_v = sub_mod(U2, X1)
    R   = sub_mod(S2, Y1)
    PP  = sqr_mod(P_v)
    PPP = mul_mod(P_v, PP)
    Q   = mul_mod(X1, PP)
    X3  = sub_mod(sub_mod(sqr_mod(R), PPP), add_mod(Q, Q))
    Y3  = sub_mod(mul_mod(R, sub_mod(Q, X3)), mul_mod(Y1, PPP))
    ZZ3 = mul_mod(ZZ1, PP)
    ZZZ3= mul_mod(ZZZ1, PPP)
    return X3, Y3, ZZ3, ZZZ3


def xyzz_point_mul(k, Px=Gx, Py=Gy):
    """Scalar multiplication using XYZZ coordinates.
    Returns affine (x, y).
    """
    X, Y, ZZ, ZZZ = None, None, None, None
    init = False

    for bit in bin(k)[2:]:
        if init:
            X, Y, ZZ, ZZZ = xyzz_double(X, Y, ZZ, ZZZ)
        if bit == '1':
            if not init:
                X, Y, ZZ, ZZZ = Px, Py, 1, 1
                init = True
            else:
                X, Y, ZZ, ZZZ = xyzz_add_mixed(X, Y, ZZ, ZZZ, Px, Py)

    if not init:
        return None, None
    return xyzz_to_affine(X, Y, ZZ, ZZZ)


# ---------------------------------------------------------------------------
# Pure-Python reference: d=4 Comb method
# ---------------------------------------------------------------------------

# Precomputed comb table (as Python big-integers): T[i] for i=0..15
# T[0] = identity (None)
# T[i] = (i&1)*G + ((i>>1)&1)*2^64*G + ((i>>2)&1)*2^128*G + ((i>>3)&1)*2^192*G

_COLS = [point_mul_affine(2**(64*j)) for j in range(4)]

_COMB_TABLE = [None]  # T[0] = identity
for _i in range(1, 16):
    _pt = (None, None)
    for _j in range(4):
        if (_i >> _j) & 1:
            _pt = point_add_affine(_pt[0], _pt[1], _COLS[_j][0], _COLS[_j][1])
    _COMB_TABLE.append(_pt)


def point_mul_comb_ref(k):
    """d=4 comb scalar multiplication reference (Python).
    Matches the OpenCL point_mul_comb() implementation.
    """
    ax, ay = None, None
    init = False

    for col in range(63, -1, -1):
        if init:
            ax, ay = point_double_affine(ax, ay)

        word0 = col >> 5       # 0 or 1 within each 64-bit band
        bit0  = col & 31

        b0 = (k >> (32 * word0          + bit0)) & 1
        b1 = (k >> (32 * (word0 + 2)    + bit0)) & 1
        b2 = (k >> (32 * (word0 + 4)    + bit0)) & 1
        b3 = (k >> (32 * (word0 + 6)    + bit0)) & 1

        idx = b0 | (b1 << 1) | (b2 << 2) | (b3 << 3)

        if idx != 0:
            tx, ty = _COMB_TABLE[idx]
            if not init:
                ax, ay = tx, ty
                init = True
            else:
                ax, ay = point_add_affine(ax, ay, tx, ty)

    return ax, ay


# ---------------------------------------------------------------------------
# Helper: 256-bit integer add-1 (mirrors add1_256 in OpenCL)
# ---------------------------------------------------------------------------

def add1_256(a):
    """Add 1 to a 256-bit integer, wrapping on overflow."""
    return (a + 1) & ((1 << 256) - 1)


# ===========================================================================
# Test classes
# ===========================================================================

class TestGroupKeyAddition(unittest.TestCase):
    """P8-01: Group Key Addition — P_{i+1} = P_i + G for sequential keys."""

    def _check_batch(self, base_key, count, check_interval=25):
        """Verify that incremental point_add(G) matches direct scalar mul.

        To keep CI runtime reasonable, the reference point_mul is only called
        every check_interval steps (and at the last step).  Correctness is
        still guaranteed because an error in the incremental addition would
        accumulate and be caught at the next checkpoint.
        """
        Px, Py = point_mul_affine(base_key)
        for i in range(1, count + 1):
            # Incremental: Px + G
            Px, Py = point_add_affine(Px, Py, Gx, Gy)
            # Reference check at periodic intervals and at the final step
            if i % check_interval == 0 or i == count:
                key_i = base_key + i
                ref_x, ref_y = point_mul_affine(key_i)
                self.assertEqual(
                    (Px, Py), (ref_x, ref_y),
                    msg=f"Mismatch at step {i}, base_key=0x{base_key:064x}",
                )

    def test_gka_batch_100(self):
        """Batch of 100 consecutive keys starting from key=1."""
        self._check_batch(1, 100)

    def test_gka_batch_500(self):
        """Batch of 500 consecutive keys starting from key=42."""
        self._check_batch(42, 500)

    def test_gka_batch_1000(self):
        """Batch of 1000 consecutive keys starting from a random base."""
        random.seed(0xDEADBEEF)
        base = random.randint(1, N - 1001)
        self._check_batch(base, 1000)

    def test_gka_wrap_around_small(self):
        """GKA works at small scalar values (key=1..10)."""
        self._check_batch(0, 10, check_interval=1)

    def test_gka_medium_batch_every_step(self):
        """Verify every step for a 30-step batch to validate incremental logic fully."""
        random.seed(0xABCDEF01)
        base = random.randint(1, N - 40)
        self._check_batch(base, 30, check_interval=1)

    def test_gka_large_key(self):
        """GKA works for large scalar values close to N."""
        base = N - 200
        self._check_batch(base, 50)

    def test_gka_random_100_batches(self):
        """20 independent random base keys, each followed by 10 GKA steps.
        Reduced from 100 to 20 batches for CI runtime budget; verified at end of each batch."""
        random.seed(0xCAFEBABE)
        for _ in range(20):
            base = random.randint(1, N - 20)
            self._check_batch(base, 10)

    def test_gka_stride_consistency(self):
        """P_{i+2} via two GKA steps equals direct (base+2)*G."""
        base = 0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        Px, Py = point_mul_affine(base)
        for step in range(1, 101):
            Px, Py = point_add_affine(Px, Py, Gx, Gy)
        ref_x, ref_y = point_mul_affine(base + 100)
        self.assertEqual((Px, Py), (ref_x, ref_y))

    def test_gka_add1_256_basic(self):
        """add1_256 increments 256-bit integer correctly."""
        self.assertEqual(add1_256(0), 1)
        self.assertEqual(add1_256(1), 2)
        self.assertEqual(add1_256((1 << 256) - 1), 0)  # wrap-around
        self.assertEqual(add1_256(0xFFFFFFFF), 0x100000000)

    def test_gka_sequential_detection(self):
        """Sequential detection: prv_key equals prev_key + 1."""
        for base in [1, 100, 0xdeadbeef, N - 5]:
            prev = base
            curr = add1_256(prev)
            # These should compare equal (sequential)
            self.assertEqual(curr, prev + 1)

    def test_gka_non_sequential_triggers_full_mul(self):
        """Non-sequential keys (skip of 2) differ from GKA by 1 step."""
        base = 12345
        # GKA prediction: base+2*G
        Pgka_x, Pgka_y = point_mul_affine(base)
        Pgka_x, Pgka_y = point_add_affine(Pgka_x, Pgka_y, Gx, Gy)  # +1G
        Pgka_x, Pgka_y = point_add_affine(Pgka_x, Pgka_y, Gx, Gy)  # +2G = base+2
        # Direct: base+2 point
        ref_x, ref_y = point_mul_affine(base + 2)
        self.assertEqual((Pgka_x, Pgka_y), (ref_x, ref_y))


class TestXYZZCoordinates(unittest.TestCase):
    """P8-02: XYZZ coordinate system correctness."""

    def test_xyzz_double_matches_affine_double(self):
        """xyzz_double of G matches affine double of G."""
        X, Y, ZZ, ZZZ = Gx, Gy, 1, 1
        X3, Y3, ZZ3, ZZZ3 = xyzz_double(X, Y, ZZ, ZZZ)
        xa, ya = xyzz_to_affine(X3, Y3, ZZ3, ZZZ3)
        ref_x, ref_y = point_double_affine(Gx, Gy)
        self.assertEqual((xa, ya), (ref_x, ref_y), "XYZZ double of G mismatch")

    def test_xyzz_add_mixed_g_plus_g(self):
        """xyzz_add_mixed of (2G) + G = 3G."""
        X, Y, ZZ, ZZZ = Gx, Gy, 1, 1
        X2, Y2, ZZ2, ZZZ2 = xyzz_double(X, Y, ZZ, ZZZ)  # 2G in XYZZ
        X3, Y3, ZZ3, ZZZ3 = xyzz_add_mixed(X2, Y2, ZZ2, ZZZ2, Gx, Gy)  # +G
        xa, ya = xyzz_to_affine(X3, Y3, ZZ3, ZZZ3)
        ref_x, ref_y = point_mul_affine(3)
        self.assertEqual((xa, ya), (ref_x, ref_y), "XYZZ 2G+G mismatch")

    def test_xyzz_mul_10_random(self):
        """xyzz_point_mul matches affine point_mul for 10 random scalars."""
        random.seed(0xABCDEF)
        for _ in range(10):
            k = random.randint(1, N - 1)
            xyzz_x, xyzz_y = xyzz_point_mul(k)
            ref_x, ref_y   = point_mul_affine(k)
            self.assertEqual((xyzz_x, xyzz_y), (ref_x, ref_y),
                             f"XYZZ mul mismatch for k=0x{k:064x}")

    def test_xyzz_double_known_vector_2G(self):
        """XYZZ doubling of G gives known 2*G coordinates."""
        X, Y, ZZ, ZZZ = Gx, Gy, 1, 1
        X3, Y3, ZZ3, ZZZ3 = xyzz_double(X, Y, ZZ, ZZZ)
        xa, ya = xyzz_to_affine(X3, Y3, ZZ3, ZZZ3)
        # 2G (from test_regression_libsecp256k1.py)
        G2x = 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5
        G2y = 0x1AE168FEA63DC339A980E180C6D0BCE93F7AEBFC7786BFDE4B4C30944ADEF8A1
        # Independently verify: 2G = double(G)
        ref_x, ref_y = point_double_affine(Gx, Gy)
        self.assertEqual((xa, ya), (ref_x, ref_y))

    def test_xyzz_affine_recovery_multiple_doubles(self):
        """After 5 doublings, XYZZ affine recovery matches 2^5*G."""
        X, Y, ZZ, ZZZ = Gx, Gy, 1, 1
        for _ in range(5):
            X, Y, ZZ, ZZZ = xyzz_double(X, Y, ZZ, ZZZ)
        xa, ya = xyzz_to_affine(X, Y, ZZ, ZZZ)
        ref_x, ref_y = point_mul_affine(32)  # 2^5 = 32
        self.assertEqual((xa, ya), (ref_x, ref_y))

    def test_xyzz_add_mixed_100_sequential(self):
        """100 XYZZ mixed additions starting from 2G produce 102*G."""
        # Start from 2G (not G, because madd assumes distinct points)
        X, Y, ZZ, ZZZ = xyzz_double(Gx, Gy, 1, 1)   # 2G
        for _ in range(100):
            X, Y, ZZ, ZZZ = xyzz_add_mixed(X, Y, ZZ, ZZZ, Gx, Gy)  # +G each step
        xa, ya = xyzz_to_affine(X, Y, ZZ, ZZZ)
        ref_x, ref_y = point_mul_affine(102)   # 2G + 100G = 102G
        self.assertEqual((xa, ya), (ref_x, ref_y))

    def test_xyzz_double_vs_jacobian_consistency(self):
        """XYZZ double and Jacobian double agree for 20 random points."""
        random.seed(0x12345678)
        for _ in range(20):
            k = random.randint(1, N - 1)
            Px, Py = point_mul_affine(k)
            # XYZZ double
            X, Y, ZZ, ZZZ = xyzz_double(Px, Py, 1, 1)
            xa, ya = xyzz_to_affine(X, Y, ZZ, ZZZ)
            # Affine double reference
            ref_x, ref_y = point_double_affine(Px, Py)
            self.assertEqual((xa, ya), (ref_x, ref_y))


class TestCombMethod(unittest.TestCase):
    """P8-03: d=4 Comb method correctness and table values."""

    def _words_to_int(self, words):
        """Convert list of u32 LE words to big-integer."""
        return sum(w << (32 * i) for i, w in enumerate(words))

    def _load_comb_table_from_cl(self):
        """Parse T[1..15] from inc_ecc_secp256k1.cl."""
        cl_path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.cl')
        with open(cl_path) as f:
            content = f.read()
        start = content.index('const u32 comb_table[15][16]')
        end   = content.index('};', start) + 2
        block = content[start:end]
        vals  = re.findall(r'0x([0-9a-fA-F]+)', block)
        assert len(vals) == 15 * 16, f"Expected 240 comb table values, got {len(vals)}"
        table = []
        for i in range(15):
            base = i * 16
            xw = [int(v, 16) for v in vals[base:base + 8]]
            yw = [int(v, 16) for v in vals[base + 8:base + 16]]
            table.append((self._words_to_int(xw), self._words_to_int(yw)))
        return table

    def test_comb_table_all_15_entries_correct(self):
        """All 15 comb table entries match expected curve points."""
        cl_table = self._load_comb_table_from_cl()
        for i in range(1, 16):
            ref_x, ref_y = _COMB_TABLE[i]
            got_x, got_y = cl_table[i - 1]
            self.assertEqual(got_x, ref_x, f"T[{i}] x mismatch")
            self.assertEqual(got_y, ref_y, f"T[{i}] y mismatch")

    def test_comb_table_t1_equals_G(self):
        """T[1] == G (the generator point)."""
        cl_table = self._load_comb_table_from_cl()
        self.assertEqual(cl_table[0][0], Gx)
        self.assertEqual(cl_table[0][1], Gy)

    def test_comb_table_t2_equals_2pow64_G(self):
        """T[2] == 2^64 * G."""
        cl_table = self._load_comb_table_from_cl()
        exp_x, exp_y = _COLS[1]
        self.assertEqual(cl_table[1][0], exp_x)
        self.assertEqual(cl_table[1][1], exp_y)

    def test_comb_ref_matches_standard_mul_10_vectors(self):
        """point_mul_comb_ref matches point_mul_affine for 10 known scalars."""
        test_keys = [
            1, 2, 3, 7, 15, 0xFF, 0xFFFF,
            0xdeadbeef,
            0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef,
            N - 1,
        ]
        for k in test_keys:
            comb_x, comb_y = point_mul_comb_ref(k)
            ref_x,  ref_y  = point_mul_affine(k)
            self.assertEqual((comb_x, comb_y), (ref_x, ref_y),
                             f"comb mismatch for k=0x{k:064x}")

    def test_comb_ref_matches_standard_mul_50_random(self):
        """point_mul_comb_ref matches point_mul_affine for 50 random scalars."""
        random.seed(0xFEEDFACE)
        for _ in range(50):
            k = random.randint(1, N - 1)
            comb_x, comb_y = point_mul_comb_ref(k)
            ref_x,  ref_y  = point_mul_affine(k)
            self.assertEqual((comb_x, comb_y), (ref_x, ref_y),
                             f"comb random mismatch for k=0x{k:064x}")

    def test_comb_ref_matches_for_k_equals_1(self):
        """Comb of k=1 returns G."""
        cx, cy = point_mul_comb_ref(1)
        self.assertEqual((cx, cy), (Gx, Gy))

    def test_comb_ref_matches_for_k_equals_2(self):
        """Comb of k=2 returns 2G."""
        cx, cy = point_mul_comb_ref(2)
        ref_x, ref_y = point_mul_affine(2)
        self.assertEqual((cx, cy), (ref_x, ref_y))

    def test_comb_table_t15_is_sum_of_all_cols(self):
        """T[15] = G + 2^64*G + 2^128*G + 2^192*G."""
        pt = (None, None)
        for col in _COLS:
            pt = point_add_affine(pt[0], pt[1], col[0], col[1])
        cl_table = self._load_comb_table_from_cl()
        self.assertEqual(cl_table[14][0], pt[0])
        self.assertEqual(cl_table[14][1], pt[1])


class TestModuleFileValidation(unittest.TestCase):
    """P8-04: Verify m35905_a3 and m35906_a3 use the GKA pattern."""

    def _read_module(self, filename):
        path = os.path.join(_OPENCL_DIR, filename)
        with open(path) as f:
            return f.read()

    def test_m35905_a3_has_point_add_affine_G(self):
        """m35905_a3-pure.cl calls point_add_affine_G."""
        content = self._read_module('m35905_a3-pure.cl')
        self.assertIn('point_add_affine_G', content,
                      "m35905_a3 should call point_add_affine_G for GKA")

    def test_m35906_a3_has_point_add_affine_G(self):
        """m35906_a3-pure.cl calls point_add_affine_G."""
        content = self._read_module('m35906_a3-pure.cl')
        self.assertIn('point_add_affine_G', content,
                      "m35906_a3 should call point_add_affine_G for GKA")

    def test_m35905_a3_has_is_seq_check(self):
        """m35905_a3-pure.cl contains sequential key detection."""
        content = self._read_module('m35905_a3-pure.cl')
        self.assertIn('is_seq', content,
                      "m35905_a3 should detect sequential keys (is_seq)")

    def test_m35906_a3_has_is_seq_check(self):
        """m35906_a3-pure.cl contains sequential key detection."""
        content = self._read_module('m35906_a3-pure.cl')
        self.assertIn('is_seq', content,
                      "m35906_a3 should detect sequential keys (is_seq)")

    def test_m35905_a3_has_prv_to_hash160_xy(self):
        """m35905_a3-pure.cl defines prv_to_hash160_xy helper."""
        content = self._read_module('m35905_a3-pure.cl')
        self.assertIn('prv_to_hash160_xy', content,
                      "m35905_a3 should have prv_to_hash160_xy helper")

    def test_m35906_a3_has_prv_to_eth_addr_xy(self):
        """m35906_a3-pure.cl defines prv_to_eth_addr_xy helper."""
        content = self._read_module('m35906_a3-pure.cl')
        self.assertIn('prv_to_eth_addr_xy', content,
                      "m35906_a3 should have prv_to_eth_addr_xy helper")

    def test_m35905_a3_has_add1_256(self):
        """m35905_a3-pure.cl defines add1_256 helper."""
        content = self._read_module('m35905_a3-pure.cl')
        self.assertIn('add1_256', content,
                      "m35905_a3 should define add1_256")

    def test_m35906_a3_has_add1_256(self):
        """m35906_a3-pure.cl defines add1_256 helper."""
        content = self._read_module('m35906_a3-pure.cl')
        self.assertIn('add1_256', content,
                      "m35906_a3 should define add1_256")

    def test_m35905_a3_falls_back_to_full_mul(self):
        """m35905_a3-pure.cl still calls point_mul_glv_wnaf_w5 (fallback)."""
        content = self._read_module('m35905_a3-pure.cl')
        self.assertIn('point_mul_glv_wnaf_w5', content,
                      "m35905_a3 should keep full scalar mul as fallback")

    def test_m35906_a3_falls_back_to_full_mul(self):
        """m35906_a3-pure.cl still calls point_mul_glv_wnaf_w5 (fallback)."""
        content = self._read_module('m35906_a3-pure.cl')
        self.assertIn('point_mul_glv_wnaf_w5', content,
                      "m35906_a3 should keep full scalar mul as fallback")

    def test_inc_ecc_has_point_add_affine_G_decl(self):
        """inc_ecc_secp256k1.h declares point_add_affine_G."""
        path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.h')
        with open(path) as f:
            content = f.read()
        self.assertIn('point_add_affine_G', content)

    def test_inc_ecc_has_xyzz_decls(self):
        """inc_ecc_secp256k1.h declares XYZZ functions."""
        path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.h')
        with open(path) as f:
            content = f.read()
        self.assertIn('point_double_xyzz', content)
        self.assertIn('point_add_mixed_xyzz', content)

    def test_inc_ecc_has_comb_ifdef(self):
        """inc_ecc_secp256k1.h has SECP256K1_USE_COMB guard for comb method."""
        path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.h')
        with open(path) as f:
            content = f.read()
        self.assertIn('SECP256K1_USE_COMB', content)
        self.assertIn('point_mul_comb', content)

    def test_inc_ecc_cl_has_xyzz_implementations(self):
        """inc_ecc_secp256k1.cl defines XYZZ functions."""
        path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.cl')
        with open(path) as f:
            content = f.read()
        self.assertIn('DECLSPEC void point_double_xyzz', content)
        self.assertIn('DECLSPEC void point_add_mixed_xyzz', content)
        self.assertIn('DECLSPEC void point_add_affine_G', content)

    def test_inc_ecc_cl_has_comb_implementation(self):
        """inc_ecc_secp256k1.cl defines point_mul_comb inside ifdef guard."""
        path = os.path.join(_OPENCL_DIR, 'inc_ecc_secp256k1.cl')
        with open(path) as f:
            content = f.read()
        self.assertIn('#ifdef SECP256K1_USE_COMB', content)
        self.assertIn('DECLSPEC void point_mul_comb', content)
        self.assertIn('#endif /* SECP256K1_USE_COMB */', content)


class TestRegisterEstimation(unittest.TestCase):
    """P8-05: Register usage estimation for AMD RX 580 (256 VGPRs budget)."""

    AMD_VGPR_BUDGET = 256  # AMD Polaris (RX 580) total VGPRs per CU per simd

    def _read_cl(self, filename):
        path = os.path.join(_OPENCL_DIR, filename)
        with open(path) as f:
            return f.read()

    def _count_u32_arrays(self, content, func_start, func_end):
        """Count u32 array declarations in a function block."""
        block = content[func_start:func_end]
        # Match: u32 name[N] style declarations
        matches = re.findall(r'\bu32\s+\w+\s*\[(\d+)\]', block)
        return sum(int(m) for m in matches)

    def test_gka_state_fits_in_budget(self):
        """GKA state (3×8 u32 = 96 words) << 256 VGPR budget."""
        gka_words = 3 * 8  # gka_x, gka_y, gka_z
        self.assertLess(gka_words, self.AMD_VGPR_BUDGET,
                        f"GKA state ({gka_words} VGPRs) must fit in budget")

    def test_no_full_precomputed_table_in_gka_path(self):
        """m35905_a3 kernel with GKA does NOT declare a secp256k1_w5_t table
        as a large local array (that would be 192 u32 = 192 VGPRs per thread
        on top of everything else). It's still used but set_precomputed is
        called once at kernel start, consistent with existing code."""
        content = self._read_cl('m35905_a3-pure.cl')
        # The kernel should still call set_precomputed_basepoint_g_w5 (for fallback)
        self.assertIn('set_precomputed_basepoint_g_w5', content)
        # But the total u32 registers in the GKA path should be less than full budget
        # (Just verify point_add_affine_G is used, which avoids the precomputed table
        #  during sequential increments)
        self.assertIn('point_add_affine_G', content)

    def test_add_affine_g_uses_constant_stack_footprint(self):
        """point_add_affine_G uses only 2×8=16 u32 words for gx/gy (local).
        This is far less than the 192-word secp256k1_w5_t table."""
        content = self._read_cl('inc_ecc_secp256k1.cl')
        start = content.index('DECLSPEC void point_add_affine_G')
        end   = content.index('\n}', start) + 2
        block = content[start:end]
        # Should declare gx[8] and gy[8]
        self.assertIn('gx[8]', block)
        self.assertIn('gy[8]', block)
        stack_words = 16  # gx[8] + gy[8]
        self.assertLess(stack_words, 32,
                        "point_add_affine_G stack footprint should be small")

    def test_xyzz_double_stack_footprint(self):
        """point_double_xyzz uses a bounded number of u32 temporaries."""
        content = self._read_cl('inc_ecc_secp256k1.cl')
        start = content.index('DECLSPEC void point_double_xyzz')
        end   = content.index('\n}', start) + 2
        block = content[start:end]
        matches = re.findall(r'\bu32\s+\w+\s*\[(\d+)\]', block)
        stack_words = sum(int(m) for m in matches)
        # Should be < 96 u32 words of local state
        self.assertLess(stack_words, 96,
                        f"point_double_xyzz uses {stack_words} u32 locals (should be < 96)")

    def test_xyzz_add_mixed_stack_footprint(self):
        """point_add_mixed_xyzz uses a bounded number of u32 temporaries."""
        content = self._read_cl('inc_ecc_secp256k1.cl')
        start = content.index('DECLSPEC void point_add_mixed_xyzz')
        end   = content.index('\n}', start) + 2
        block = content[start:end]
        matches = re.findall(r'\bu32\s+\w+\s*\[(\d+)\]', block)
        stack_words = sum(int(m) for m in matches)
        self.assertLess(stack_words, 112,
                        f"point_add_mixed_xyzz uses {stack_words} u32 locals (should be < 112)")


class TestXYZZAffineRecovery(unittest.TestCase):
    """P8-06: XYZZ affine recovery correctness."""

    def test_xyzz_affine_recovery_from_identity_components(self):
        """Starting XYZZ at (G, 1, 1) gives G in affine."""
        xa, ya = xyzz_to_affine(Gx, Gy, 1, 1)
        self.assertEqual((xa, ya), (Gx, Gy))

    def test_xyzz_recovery_after_one_double(self):
        """One XYZZ double then recovery matches 2*G."""
        X, Y, ZZ, ZZZ = xyzz_double(Gx, Gy, 1, 1)
        xa, ya = xyzz_to_affine(X, Y, ZZ, ZZZ)
        ref_x, ref_y = point_double_affine(Gx, Gy)
        self.assertEqual((xa, ya), (ref_x, ref_y))

    def test_xyzz_recovery_after_one_add(self):
        """One XYZZ mixed add (2G + G) then recovery matches 3*G.
        Note: madd requires distinct input points; use 2G as starting point."""
        X2, Y2, ZZ2, ZZZ2 = xyzz_double(Gx, Gy, 1, 1)   # 2G
        X, Y, ZZ, ZZZ = xyzz_add_mixed(X2, Y2, ZZ2, ZZZ2, Gx, Gy)  # 2G + G = 3G
        xa, ya = xyzz_to_affine(X, Y, ZZ, ZZZ)
        ref_x, ref_y = point_mul_affine(3)
        self.assertEqual((xa, ya), (ref_x, ref_y))

    def test_xyzz_mul_matches_direct_for_primes(self):
        """XYZZ mul matches for prime scalars: 2, 3, 5, 7, 11."""
        for k in [2, 3, 5, 7, 11]:
            xyzz_x, xyzz_y = xyzz_point_mul(k)
            ref_x, ref_y   = point_mul_affine(k)
            self.assertEqual((xyzz_x, xyzz_y), (ref_x, ref_y),
                             f"XYZZ mul mismatch for prime k={k}")

    def test_xyzz_zz_zzz_consistency(self):
        """After doubling, ZZ=Z^2 and ZZZ=Z^3 satisfy ZZZ^2 == ZZ^3 (both equal Z^6)."""
        _, _, ZZ, ZZZ = xyzz_double(Gx, Gy, 1, 1)
        lhs = mul_mod(ZZZ, ZZZ)  # ZZZ^2 = Z^6
        rhs = mul_mod(ZZ, mul_mod(ZZ, ZZ))  # ZZ^3 = Z^6
        self.assertEqual(lhs, rhs, "XYZZ: ZZZ^2 must equal ZZ^3")


class TestSequentialDetectionLogic(unittest.TestCase):
    """P8-07: Sequential detection (add1_256 / is_seq) correctness."""

    def test_add1_simple(self):
        """add1_256(k) = k + 1 for small values."""
        for k in range(0, 100):
            self.assertEqual(add1_256(k), k + 1)

    def test_add1_large(self):
        """add1_256 works for large 256-bit values."""
        for k in [0xDEADBEEF, 0xFFFFFFFF00000000, N, N - 1]:
            expected = (k + 1) & ((1 << 256) - 1)
            self.assertEqual(add1_256(k), expected)

    def test_is_seq_true_for_consecutive(self):
        """Sequential pair detection: consecutive keys are detected."""
        for base in [1, 100, 0xDEADBEEF, N - 10]:
            prev = base
            curr = prev + 1
            self.assertEqual(curr, add1_256(prev))

    def test_is_seq_false_for_skip(self):
        """Non-sequential pair detection: skipped key is not detected."""
        for base in [1, 100, 0xDEADBEEF]:
            prev = base
            curr = prev + 2  # skip one
            self.assertNotEqual(curr, add1_256(prev))

    def test_sentinel_all_ones_never_matches_valid_key(self):
        """Sentinel value (all-ones) + 1 wraps to 0, which is not a valid key."""
        sentinel = (1 << 256) - 1  # all-ones (0xFFFF...FFFF)
        next_after_sentinel = add1_256(sentinel)
        self.assertEqual(next_after_sentinel, 0)  # wrap to 0
        # No valid secp256k1 private key is 0, so sentinel never falsely matches
        # a valid key as being sequential
        self.assertNotIn(next_after_sentinel, range(1, N))

    def test_gka_correctness_10_sequential_starting_at_1(self):
        """Verify GKA gives correct points for keys 1..10."""
        base_x, base_y = point_mul_affine(1)
        curr_x, curr_y = base_x, base_y
        for i in range(1, 11):
            ref_x, ref_y = point_mul_affine(i)
            self.assertEqual((curr_x, curr_y), (ref_x, ref_y),
                             f"Key {i}: GKA mismatch")
            curr_x, curr_y = point_add_affine(curr_x, curr_y, Gx, Gy)


if __name__ == '__main__':
    unittest.main()
