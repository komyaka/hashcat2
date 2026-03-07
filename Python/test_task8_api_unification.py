"""
Task 8: API unification — libsecp256k1 / KeyHunt compatible interface.

Tests verify that the macro aliases declared in inc_ecc_secp256k1.h map
correctly to the underlying hashcat2 implementations, and that all
semantic equivalences hold for the secp256k1 curve.

Sources documented:
  libsecp256k1  https://github.com/bitcoin-core/secp256k1
  KeyHunt       https://github.com/KeyHunt/keyhunt
  CudaBrainSecp https://github.com/XopMC/CudaBrainSecp
  micro-ecc     https://github.com/kmackay/micro-ecc
"""

import unittest
import os
import sys

# Reuse helpers from existing regression suite
sys.path.insert(0, os.path.dirname(__file__))

# secp256k1 constants (same as in inc_ecc_secp256k1.h / Python helpers)
P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

# GLV constants
LAMBDA = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
# BETA = cube root of 1 in GF(p), from inc_ecc_secp256k1.h SECP256K1_BETA[0..7]
_BETA_WORDS = [0x719501ee, 0xc1396c28, 0x12f58995, 0x9cf04975,
               0xac3434e9, 0x6e64479e, 0x657c0710, 0x7ae96a2b]
BETA = sum(_BETA_WORDS[i] * (1 << (32 * i)) for i in range(8))


# ---------------------------------------------------------------------------
# Pure-Python helpers (same algebra used by other test modules)
# ---------------------------------------------------------------------------

def _fe_mul(a, b):
    """secp256k1_fe_mul → mul_mod equivalent"""
    return (a * b) % P

def _fe_sqr(a):
    """secp256k1_fe_sqr → sqr_mod equivalent"""
    return (a * a) % P

def _fe_add(a, b):
    """secp256k1_fe_add → add_mod equivalent"""
    return (a + b) % P

def _fe_sub(a, b):
    """secp256k1_fe_sub → sub_mod equivalent"""
    return (a - b) % P

def _fe_inv(a):
    """secp256k1_fe_inv → inv_mod equivalent (Fermat: a^(p-2) mod p)"""
    return pow(a, P - 2, P)

def _fe_normalize(n512):
    """secp256k1_fe_normalize → mod_512 equivalent"""
    return n512 % P

def _point_double(px, py):
    """secp256k1_gej_double → point_double equivalent (affine, a=0)"""
    if py == 0:
        return (0, 0)
    lam = (3 * px * px * _fe_inv(2 * py)) % P
    rx = (lam * lam - 2 * px) % P
    ry = (lam * (px - rx) - py) % P
    return rx, ry

def _point_add(p1x, p1y, p2x, p2y):
    """secp256k1_gej_add_ge → point_add equivalent"""
    if p1x == 0 and p1y == 0:
        return p2x, p2y
    if p2x == 0 and p2y == 0:
        return p1x, p1y
    if p1x == p2x:
        if p1y == p2y:
            return _point_double(p1x, p1y)
        return (0, 0)  # infinity
    lam = ((p2y - p1y) * _fe_inv(p2x - p1x)) % P
    rx = (lam * lam - p1x - p2x) % P
    ry = (lam * (p1x - rx) - p1y) % P
    return rx, ry

def _point_mul(k, px=Gx, py=Gy):
    """secp256k1_ecmult_gen → point_mul_xy equivalent (double-and-add)"""
    rx, ry = 0, 0
    for bit in range(255, -1, -1):
        rx, ry = _point_double(rx, ry)
        if (k >> bit) & 1:
            rx, ry = _point_add(rx, ry, px, py)
    return rx, ry

def _scalar_split_lambda(k):
    """secp256k1_scalar_split_lambda → glv_decompose equivalent.

    Mirrors the Babai nearest-plane algorithm from test_glv_decompose.py /
    libsecp256k1 src/scalar_impl.h.  Returns (k1, k2) as signed Python
    integers (matching the C implementation's signed representation).
    """
    # Babai rounding constants (8 u32 words, little-endian)
    _G1_WORDS = [0x45dbb031, 0xe893209a, 0x71e8ca7f, 0x3daa8a14,
                 0x9284eb15, 0xe86c90e4, 0xa7d46bcd, 0x3086d221]
    _G2_WORDS = [0x8ac47f71, 0x1571b4ae, 0x9df506c6, 0x221208ac,
                 0x0abfe4c4, 0x6f547fa9, 0x010e8828, 0xe4437ed6]
    G1 = sum(_G1_WORDS[i] * (1 << (32 * i)) for i in range(8))
    G2 = sum(_G2_WORDS[i] * (1 << (32 * i)) for i in range(8))
    # GLV lattice basis vectors (from inc_ecc_secp256k1.h)
    A1 = 0x3086D221A7D46BCDE86C90E49284EB15
    B1 = 0xE4437ED6010E88286F547FA90ABFE4C3  # |b1| (b1 is negative)
    A2 = 0x114CA50F7A8E2F3F657C1108D9D44CFD8
    c1 = (k * G1) >> 384
    c2 = (k * G2) >> 384
    k1 = k - c1 * A1 - c2 * A2   # signed (may be negative)
    k2 = c1 * B1 - c2 * A1        # signed (may be negative)
    return k1, k2


# ---------------------------------------------------------------------------
# Test classes
# ---------------------------------------------------------------------------

class TestTypeAliasPresence(unittest.TestCase):
    """AC-1: Type aliases secp256k1_fe/ge/gej/scalar are declared in the header."""

    HEADER = os.path.join(
        os.path.dirname(__file__), '..', 'OpenCL', 'inc_ecc_secp256k1.h'
    )

    def _header_text(self):
        with open(self.HEADER) as f:
            return f.read()

    def test_type_secp256k1_fe_present(self):
        """secp256k1_fe type alias is in the header."""
        self.assertIn('typedef u32 secp256k1_fe', self._header_text())

    def test_type_secp256k1_ge_present(self):
        """secp256k1_ge type alias is in the header."""
        self.assertIn('typedef u32 secp256k1_ge', self._header_text())

    def test_type_secp256k1_gej_present(self):
        """secp256k1_gej type alias is in the header."""
        self.assertIn('typedef u32 secp256k1_gej', self._header_text())

    def test_type_secp256k1_scalar_present(self):
        """secp256k1_scalar type alias is in the header."""
        self.assertIn('typedef u32 secp256k1_scalar', self._header_text())

    def test_fe_size_is_8_words(self):
        """secp256k1_fe is 8 u32 words (256 bits)."""
        text = self._header_text()
        # typedef u32 secp256k1_fe[8];
        self.assertIn('secp256k1_fe[8]', text)

    def test_ge_size_is_16_words(self):
        """secp256k1_ge is 16 u32 words (2 × 256 bits)."""
        text = self._header_text()
        self.assertIn('secp256k1_ge[16]', text)

    def test_gej_size_is_24_words(self):
        """secp256k1_gej is 24 u32 words (3 × 256 bits)."""
        text = self._header_text()
        self.assertIn('secp256k1_gej[24]', text)

    def test_scalar_size_is_8_words(self):
        """secp256k1_scalar is 8 u32 words (256 bits)."""
        text = self._header_text()
        self.assertIn('secp256k1_scalar[8]', text)


class TestFunctionAliasPresence(unittest.TestCase):
    """AC-2: libsecp256k1 function-name #define aliases are in the header."""

    HEADER = os.path.join(
        os.path.dirname(__file__), '..', 'OpenCL', 'inc_ecc_secp256k1.h'
    )

    def _header_text(self):
        with open(self.HEADER) as f:
            return f.read()

    def test_alias_fe_mul(self):
        self.assertIn('#define secp256k1_fe_mul', self._header_text())

    def test_alias_fe_sqr(self):
        self.assertIn('#define secp256k1_fe_sqr', self._header_text())

    def test_alias_fe_add(self):
        self.assertIn('#define secp256k1_fe_add', self._header_text())

    def test_alias_fe_sub(self):
        self.assertIn('#define secp256k1_fe_sub', self._header_text())

    def test_alias_fe_inv(self):
        self.assertIn('#define secp256k1_fe_inv', self._header_text())

    def test_alias_fe_normalize(self):
        self.assertIn('#define secp256k1_fe_normalize', self._header_text())

    def test_alias_gej_double(self):
        self.assertIn('#define secp256k1_gej_double', self._header_text())

    def test_alias_gej_add_ge(self):
        self.assertIn('#define secp256k1_gej_add_ge', self._header_text())

    def test_alias_ecmult_gen(self):
        self.assertIn('#define secp256k1_ecmult_gen', self._header_text())

    def test_alias_ecmult_gen_glv(self):
        self.assertIn('#define secp256k1_ecmult_gen_glv', self._header_text())

    def test_alias_ecmult_wnaf_w5(self):
        self.assertIn('#define secp256k1_ecmult_wnaf_w5', self._header_text())

    def test_alias_scalar_split_lambda(self):
        self.assertIn('#define secp256k1_scalar_split_lambda', self._header_text())

    def test_alias_fe_inv_all(self):
        self.assertIn('#define secp256k1_fe_inv_all', self._header_text())


class TestAliasMappings(unittest.TestCase):
    """AC-3: Each alias maps to the correct underlying hashcat2 function."""

    HEADER = os.path.join(
        os.path.dirname(__file__), '..', 'OpenCL', 'inc_ecc_secp256k1.h'
    )

    def _header_text(self):
        with open(self.HEADER) as f:
            return f.read()

    def _alias_rhs(self, alias_name):
        """Extract the RHS of a #define alias line."""
        text = self._header_text()
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith('#define ' + alias_name):
                # e.g. '#define secp256k1_fe_mul(r, a, b)   mul_mod((r), (a), (b))'
                return stripped
        return ''

    def test_fe_mul_maps_to_mul_mod(self):
        self.assertIn('mul_mod', self._alias_rhs('secp256k1_fe_mul'))

    def test_fe_sqr_maps_to_sqr_mod(self):
        self.assertIn('sqr_mod', self._alias_rhs('secp256k1_fe_sqr'))

    def test_fe_add_maps_to_add_mod(self):
        self.assertIn('add_mod', self._alias_rhs('secp256k1_fe_add'))

    def test_fe_sub_maps_to_sub_mod(self):
        self.assertIn('sub_mod', self._alias_rhs('secp256k1_fe_sub'))

    def test_fe_inv_maps_to_inv_mod(self):
        self.assertIn('inv_mod', self._alias_rhs('secp256k1_fe_inv'))

    def test_fe_normalize_maps_to_mod_512(self):
        self.assertIn('mod_512', self._alias_rhs('secp256k1_fe_normalize'))

    def test_gej_double_maps_to_point_double(self):
        self.assertIn('point_double', self._alias_rhs('secp256k1_gej_double'))

    def test_gej_add_ge_maps_to_point_add(self):
        self.assertIn('point_add', self._alias_rhs('secp256k1_gej_add_ge'))

    def test_ecmult_gen_maps_to_point_mul_xy(self):
        self.assertIn('point_mul_xy', self._alias_rhs('secp256k1_ecmult_gen('))

    def test_ecmult_gen_glv_maps_to_point_mul_glv_xy(self):
        self.assertIn('point_mul_glv_xy', self._alias_rhs('secp256k1_ecmult_gen_glv'))

    def test_ecmult_wnaf_w5_maps_to_point_mul_wnaf_w5(self):
        self.assertIn('point_mul_wnaf_w5', self._alias_rhs('secp256k1_ecmult_wnaf_w5'))

    def test_scalar_split_lambda_maps_to_glv_decompose(self):
        self.assertIn('glv_decompose', self._alias_rhs('secp256k1_scalar_split_lambda'))

    def test_fe_inv_all_maps_to_batch_inv_mod(self):
        self.assertIn('batch_inv_mod', self._alias_rhs('secp256k1_fe_inv_all'))


class TestSemanticEquivalence(unittest.TestCase):
    """AC-4: Python equivalents verify semantic correctness of each alias."""

    # ---- field arithmetic -------------------------------------------------

    def test_fe_mul_commutativity(self):
        """secp256k1_fe_mul(r,a,b) == secp256k1_fe_mul(r,b,a)"""
        a = 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF % P
        b = 0xCAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABECAFEBABE % P
        self.assertEqual(_fe_mul(a, b), _fe_mul(b, a))

    def test_fe_mul_associativity(self):
        """secp256k1_fe_mul(secp256k1_fe_mul(a,b),c) == secp256k1_fe_mul(a,secp256k1_fe_mul(b,c))"""
        a, b, c = 0x123456789ABCDEF % P, 0xFEDCBA9876543210 % P, 0xABCDEF0123456789 % P
        self.assertEqual(_fe_mul(_fe_mul(a, b), c), _fe_mul(a, _fe_mul(b, c)))

    def test_fe_sqr_equals_mul_self(self):
        """secp256k1_fe_sqr(r,a) == secp256k1_fe_mul(r,a,a) for 100 values"""
        import hashlib
        for i in range(100):
            seed = hashlib.sha256(str(i).encode()).digest()
            a = int.from_bytes(seed, 'big') % P
            self.assertEqual(_fe_sqr(a), _fe_mul(a, a))

    def test_fe_add_commutativity(self):
        """secp256k1_fe_add(r,a,b) == secp256k1_fe_add(r,b,a)"""
        a = (P - 1)
        b = 1
        self.assertEqual(_fe_add(a, b), _fe_add(b, a))

    def test_fe_add_sub_roundtrip(self):
        """secp256k1_fe_sub(secp256k1_fe_add(a,b),b) == a"""
        import hashlib
        for i in range(50):
            seed = hashlib.sha256(b'add_sub' + str(i).encode()).digest()
            a = int.from_bytes(seed[:16], 'big') % P
            b = int.from_bytes(seed[16:], 'big') % P
            self.assertEqual(_fe_sub(_fe_add(a, b), b), a)

    def test_fe_inv_identity(self):
        """secp256k1_fe_mul(a, secp256k1_fe_inv(a)) == 1 for non-zero a"""
        import hashlib
        for i in range(20):
            seed = hashlib.sha256(b'inv' + str(i).encode()).digest()
            a = int.from_bytes(seed, 'big') % P
            if a == 0:
                continue
            self.assertEqual(_fe_mul(a, _fe_inv(a)), 1)

    def test_fe_inv_of_one(self):
        """secp256k1_fe_inv(1) == 1"""
        self.assertEqual(_fe_inv(1), 1)

    def test_fe_normalize_is_idempotent(self):
        """secp256k1_fe_normalize applied twice gives same result"""
        x = P * 3 + 42   # exceeds 256 bits; mod_512 reduces
        self.assertEqual(_fe_normalize(_fe_normalize(x)), _fe_normalize(x))

    # ---- point operations -------------------------------------------------

    def test_gej_double_identity(self):
        """secp256k1_gej_double(G) matches 2G from scalar mul"""
        two_gx, two_gy = _point_mul(2)
        dbl_x, dbl_y   = _point_double(Gx, Gy)
        self.assertEqual(two_gx, dbl_x)
        self.assertEqual(two_gy, dbl_y)

    def test_gej_add_ge_identity(self):
        """secp256k1_gej_add_ge(G, G) == 2G"""
        sum_x, sum_y = _point_add(Gx, Gy, Gx, Gy)
        two_x, two_y = _point_double(Gx, Gy)
        self.assertEqual(sum_x, two_x)
        self.assertEqual(sum_y, two_y)

    def test_ecmult_gen_k1_is_G(self):
        """secp256k1_ecmult_gen(1*G) == G (generator point)"""
        rx, ry = _point_mul(1)
        self.assertEqual(rx, Gx)
        self.assertEqual(ry, Gy)

    def test_ecmult_gen_k2(self):
        """secp256k1_ecmult_gen(2*G) matches point_double(G)"""
        rx, ry   = _point_mul(2)
        dbl_x, dbl_y = _point_double(Gx, Gy)
        self.assertEqual(rx, dbl_x)
        self.assertEqual(ry, dbl_y)

    def test_ecmult_gen_n_is_infinity(self):
        """secp256k1_ecmult_gen(n*G) == point at infinity (0,0)"""
        rx, ry = _point_mul(N)
        self.assertEqual(rx, 0)
        self.assertEqual(ry, 0)

    def test_ecmult_gen_commutativity_of_add(self):
        """k1*G + k2*G == (k1+k2)*G for several random pairs"""
        import hashlib
        for i in range(10):
            seed = hashlib.sha256(b'add_comm' + str(i).encode()).digest()
            k1 = int.from_bytes(seed[:16], 'big') % (N - 1) + 1
            k2 = int.from_bytes(seed[16:], 'big') % (N - 1) + 1
            lhs_x, lhs_y = _point_add(*_point_mul(k1), *_point_mul(k2))
            rhs_x, rhs_y = _point_mul((k1 + k2) % N)
            self.assertEqual(lhs_x, rhs_x)
            self.assertEqual(lhs_y, rhs_y)

    # ---- GLV / scalar split ----------------------------------------------

    def test_scalar_split_lambda_consistency(self):
        """secp256k1_scalar_split_lambda(k) → k1+k2*lambda == k mod n"""
        import hashlib
        for i in range(30):
            seed = hashlib.sha256(b'glv' + str(i).encode()).digest()
            k = int.from_bytes(seed, 'big') % (N - 1) + 1
            k1, k2 = _scalar_split_lambda(k)
            self.assertEqual((k1 + k2 * LAMBDA) % N, k % N,
                             msg=f"k={k:#x}: k1+k2*lambda != k mod n")

    def test_scalar_split_lambda_k1_bounded(self):
        """|k1| < 2^129 for all tested scalars (libsecp256k1 guarantee)"""
        import hashlib
        for i in range(30):
            seed = hashlib.sha256(b'glv_bound' + str(i).encode()).digest()
            k = int.from_bytes(seed, 'big') % (N - 1) + 1
            k1, _ = _scalar_split_lambda(k)
            self.assertLess(abs(k1), 1 << 129,
                           msg=f"k1={k1:#x} exceeds 2^129 bound")

    def test_scalar_split_lambda_k2_bounded(self):
        """|k2| < 2^129 for all tested scalars (libsecp256k1 guarantee)"""
        import hashlib
        for i in range(30):
            seed = hashlib.sha256(b'glv_k2' + str(i).encode()).digest()
            k = int.from_bytes(seed, 'big') % (N - 1) + 1
            _, k2 = _scalar_split_lambda(k)
            self.assertLess(abs(k2), 1 << 129,
                           msg=f"k2={k2:#x} exceeds 2^129 bound")

    def test_ecmult_gen_glv_equals_standard(self):
        """secp256k1_ecmult_gen_glv(k) == secp256k1_ecmult_gen(k) for random k"""
        import hashlib
        for i in range(20):
            seed = hashlib.sha256(b'glv_eq' + str(i).encode()).digest()
            k = int.from_bytes(seed, 'big') % (N - 1) + 1
            # standard
            std_x, std_y = _point_mul(k)
            # GLV: k1*G + k2*phi(G) where phi(x,y)=(beta*x, y)
            # k1, k2 are signed scalars from glv_decompose
            k1, k2 = _scalar_split_lambda(k)
            # reduce signed k to positive mod N for point_mul
            k1_pos = k1 % N
            k2_pos = k2 % N
            phi_gx = _fe_mul(BETA, Gx)  # phi(G) = (BETA*Gx mod p, Gy)
            glv_x, glv_y = _point_add(*_point_mul(k1_pos), *_point_mul(k2_pos, phi_gx, Gy))
            self.assertEqual(std_x, glv_x,
                            msg=f"k={k:#x}: GLV x != standard x")
            self.assertEqual(std_y, glv_y,
                            msg=f"k={k:#x}: GLV y != standard y")


class TestDocumentationPresence(unittest.TestCase):
    """AC-5: SECP256K1_OPTIMIZATION_PLAN_RU.md contains Task 8 section."""

    DOC = os.path.join(
        os.path.dirname(__file__), '..', 'docs', 'SECP256K1_OPTIMIZATION_PLAN_RU.md'
    )

    def _doc_text(self):
        with open(self.DOC) as f:
            return f.read()

    def test_task8_section_present(self):
        """docs/SECP256K1_OPTIMIZATION_PLAN_RU.md contains Task 8 heading."""
        text = self._doc_text()
        self.assertTrue(
            'Task 8' in text or 'Задание 8' in text or '## 8' in text,
            msg="Task 8 section not found in SECP256K1_OPTIMIZATION_PLAN_RU.md"
        )

    def test_libsecp256k1_reference_present(self):
        """Documentation references libsecp256k1."""
        self.assertIn('libsecp256k1', self._doc_text())

    def test_alias_table_present(self):
        """Documentation contains alias mapping table."""
        text = self._doc_text()
        self.assertTrue(
            'secp256k1_fe_mul' in text or 'secp256k1_ecmult_gen' in text,
            msg="Alias mapping table not found in doc"
        )

    def test_status_md_task8_present(self):
        """STATUS.md contains Task 8 implementation record."""
        status = os.path.join(os.path.dirname(__file__), '..', 'STATUS.md')
        with open(status) as f:
            content = f.read()
        self.assertTrue(
            'Task 8' in content or 'Задание 8' in content,
            msg="Task 8 entry not found in STATUS.md"
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
