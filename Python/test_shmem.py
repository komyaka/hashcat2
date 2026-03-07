"""
test_shmem.py — Unit tests for SHMEM/LDS memory optimization (Task 5).

These tests verify the Python-side simulation of the cooperative shared-memory
table initialization and lookup logic used in the OpenCL SHMEM variants:
  - set_precomputed_basepoint_g_lm  (w=4, 96 words)
  - point_mul_xy_lm                 (w=4, LOCAL_AS table)
  - set_precomputed_basepoint_g_w5_lm (w=5, 192 words)
  - point_mul_wnaf_w5_lm            (w=5, LOCAL_AS table)

All constants are cross-checked against the #define values in
OpenCL/inc_ecc_secp256k1.h.
"""

import re
import os
import unittest

# ---------------------------------------------------------------------------
# Helper: parse precomputed constant table from the OpenCL header
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_HEADER_PATH = os.path.join(_REPO_ROOT, "OpenCL", "inc_ecc_secp256k1.h")


def _load_precomputed_constants():
    """Parse SECP256K1_G_PRE_COMPUTED_NN defines from inc_ecc_secp256k1.h."""
    pattern = re.compile(
        r"#define\s+SECP256K1_G_PRE_COMPUTED_(\d+)\s+(0x[0-9a-fA-F]+)"
    )
    constants = {}
    with open(_HEADER_PATH) as fh:
        for line in fh:
            m = pattern.match(line.strip())
            if m:
                idx = int(m.group(1))
                val = int(m.group(2), 16)
                constants[idx] = val
    return constants


# Load once at module level for all tests to share
PRECOMPUTED = _load_precomputed_constants()

# Sizes declared in inc_ecc_secp256k1.h (after Task 5 patch)
SECP256K1_SHMEM_SIZE = 96
SECP256K1_W5_SHMEM_SIZE = 192


# ---------------------------------------------------------------------------
# Python simulation of cooperative SHMEM init and lookup
# ---------------------------------------------------------------------------

def simulate_set_precomputed_basepoint_g_lm(lsz: int) -> list:
    """
    Simulate set_precomputed_basepoint_g_lm() for a workgroup of *lsz* threads.
    Returns the resulting lm_xy table (96 u32 words).
    """
    lm_xy = [0] * SECP256K1_SHMEM_SIZE
    for lid in range(lsz):
        i = lid
        while i < SECP256K1_SHMEM_SIZE:
            lm_xy[i] = PRECOMPUTED[i]
            i += lsz
    # SYNC_THREADS() is a no-op in Python simulation
    return lm_xy


def simulate_set_precomputed_basepoint_g_w5_lm(lsz: int) -> list:
    """
    Simulate set_precomputed_basepoint_g_w5_lm() for a workgroup of *lsz* threads.
    Returns the resulting lm_xy table (192 u32 words).
    """
    lm_xy = [0] * SECP256K1_W5_SHMEM_SIZE
    for lid in range(lsz):
        i = lid
        while i < SECP256K1_W5_SHMEM_SIZE:
            lm_xy[i] = PRECOMPUTED[i]
            i += lsz
    return lm_xy


def table_lookup_xpos(multiplier: int) -> int:
    """Return the x-coordinate base index for an odd multiplier digit."""
    odd = multiplier & 1
    return ((multiplier - 1 + odd) >> 1) * 24


def table_lookup_ypos(xp: int, odd: int) -> int:
    """Return the y-coordinate base index given x-pos and odd flag."""
    return (xp + 8) if odd else (xp + 16)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestShmemConstants(unittest.TestCase):
    """Verify constant table structure and sizes."""

    def test_total_constant_count(self):
        """Header must define exactly 192 SECP256K1_G_PRE_COMPUTED_NN constants."""
        self.assertEqual(len(PRECOMPUTED), 192)

    def test_constant_indices_contiguous(self):
        """Constant indices must be contiguous from 0 to 191."""
        self.assertEqual(set(PRECOMPUTED.keys()), set(range(192)))

    def test_shmem_size_value(self):
        """SECP256K1_SHMEM_SIZE must equal 96."""
        self.assertEqual(SECP256K1_SHMEM_SIZE, 96)

    def test_w5_shmem_size_value(self):
        """SECP256K1_W5_SHMEM_SIZE must equal 192."""
        self.assertEqual(SECP256K1_W5_SHMEM_SIZE, 192)

    def test_shmem_size_is_subset_of_w5(self):
        """w=4 SHMEM table is the first 96 words of the w=5 table."""
        self.assertLess(SECP256K1_SHMEM_SIZE, SECP256K1_W5_SHMEM_SIZE)
        self.assertEqual(SECP256K1_SHMEM_SIZE * 2, SECP256K1_W5_SHMEM_SIZE)

    def test_all_constants_are_u32(self):
        """Every constant must fit in a 32-bit unsigned integer."""
        for idx, val in PRECOMPUTED.items():
            self.assertGreaterEqual(val, 0, f"PRECOMPUTED[{idx}] negative")
            self.assertLessEqual(val, 0xFFFFFFFF, f"PRECOMPUTED[{idx}] > U32_MAX")

    def test_first_constant_is_g_x_lsword(self):
        """PRECOMPUTED[0] = 0x16f81798 (LSW of secp256k1 generator x-coord)."""
        self.assertEqual(PRECOMPUTED[0], 0x16F81798)

    def test_eighth_constant_is_g_x_msword(self):
        """PRECOMPUTED[7] = 0x79be667e (MSW of secp256k1 generator x-coord)."""
        self.assertEqual(PRECOMPUTED[7], 0x79BE667E)

    def test_ninth_constant_is_g_y_lsword(self):
        """PRECOMPUTED[8] = 0xfb10d4b8 (LSW of secp256k1 generator y-coord)."""
        self.assertEqual(PRECOMPUTED[8], 0xFB10D4B8)

    def test_sixteenth_constant_is_g_y_msword(self):
        """PRECOMPUTED[15] = 0x483ada77 (MSW of secp256k1 generator y-coord)."""
        self.assertEqual(PRECOMPUTED[15], 0x483ADA77)


class TestShmemW4Init(unittest.TestCase):
    """Verify cooperative initialization of the w=4 SHMEM table."""

    def _check_table(self, table):
        """Assert table matches PRECOMPUTED[0..95]."""
        self.assertEqual(len(table), SECP256K1_SHMEM_SIZE)
        for i in range(SECP256K1_SHMEM_SIZE):
            self.assertEqual(
                table[i], PRECOMPUTED[i],
                f"lm_xy[{i}] = {hex(table[i])} != PRECOMPUTED[{i}] = {hex(PRECOMPUTED[i])}"
            )

    def test_init_single_thread(self):
        """lsz=1: single thread fills entire 96-word table."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=1)
        self._check_table(table)

    def test_init_lsz_32(self):
        """lsz=32: 32 threads fill 96 words (3 words each)."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=32)
        self._check_table(table)

    def test_init_lsz_64(self):
        """lsz=64: 64 threads fill 96 words (2 or 1 word each)."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=64)
        self._check_table(table)

    def test_init_lsz_96(self):
        """lsz=96: each thread fills exactly one word."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=96)
        self._check_table(table)

    def test_init_lsz_128(self):
        """lsz=128: first 96 threads fill one word each; last 32 are idle."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=128)
        self._check_table(table)

    def test_init_lsz_256(self):
        """lsz=256: only threads 0..95 write; remaining threads are idle."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=256)
        self._check_table(table)

    def test_init_different_lsz_produce_same_table(self):
        """Different workgroup sizes must produce identical tables."""
        t1 = simulate_set_precomputed_basepoint_g_lm(lsz=1)
        t32 = simulate_set_precomputed_basepoint_g_lm(lsz=32)
        t64 = simulate_set_precomputed_basepoint_g_lm(lsz=64)
        self.assertEqual(t1, t32)
        self.assertEqual(t1, t64)


class TestShmemW5Init(unittest.TestCase):
    """Verify cooperative initialization of the w=5 SHMEM table (192 words)."""

    def _check_table(self, table):
        self.assertEqual(len(table), SECP256K1_W5_SHMEM_SIZE)
        for i in range(SECP256K1_W5_SHMEM_SIZE):
            self.assertEqual(
                table[i], PRECOMPUTED[i],
                f"lm_xy[{i}] = {hex(table[i])} != PRECOMPUTED[{i}] = {hex(PRECOMPUTED[i])}"
            )

    def test_init_single_thread(self):
        """lsz=1: single thread fills entire 192-word table."""
        table = simulate_set_precomputed_basepoint_g_w5_lm(lsz=1)
        self._check_table(table)

    def test_init_lsz_64(self):
        """lsz=64: 64 threads fill 192 words."""
        table = simulate_set_precomputed_basepoint_g_w5_lm(lsz=64)
        self._check_table(table)

    def test_init_lsz_192(self):
        """lsz=192: each thread fills exactly one word."""
        table = simulate_set_precomputed_basepoint_g_w5_lm(lsz=192)
        self._check_table(table)

    def test_w5_table_starts_with_w4_table(self):
        """First 96 words of the w=5 table must equal the w=4 table."""
        t4 = simulate_set_precomputed_basepoint_g_lm(lsz=32)
        t5 = simulate_set_precomputed_basepoint_g_w5_lm(lsz=32)
        self.assertEqual(t4, t5[:SECP256K1_SHMEM_SIZE])

    def test_w5_last_entry(self):
        """Last word of the w=5 table = PRECOMPUTED[191]."""
        table = simulate_set_precomputed_basepoint_g_w5_lm(lsz=1)
        self.assertEqual(table[191], PRECOMPUTED[191])
        self.assertEqual(table[191], 0xA7E1D78D)


class TestTableLookupFormula(unittest.TestCase):
    """Verify the x/y-position lookup formula used in point_mul_xy_lm."""

    def test_multiplier_1_xpos(self):
        """Multiplier=1 (odd=1): x_pos = ((1-1+1)>>1)*24 = 0."""
        self.assertEqual(table_lookup_xpos(1), 0)

    def test_multiplier_1_ypos(self):
        """Multiplier=1 (odd=1): y_pos = x_pos + 8 = 8."""
        xp = table_lookup_xpos(1)
        self.assertEqual(table_lookup_ypos(xp, 1), 8)

    def test_multiplier_3_xpos(self):
        """Multiplier=3 (odd=1): x_pos = ((3-1+1)>>1)*24 = 1*24 = 24."""
        self.assertEqual(table_lookup_xpos(3), 24)

    def test_multiplier_3_ypos_odd(self):
        """Multiplier=3 (odd=1): y_pos = 24 + 8 = 32."""
        xp = table_lookup_xpos(3)
        self.assertEqual(table_lookup_ypos(xp, 1), 32)

    def test_multiplier_2_even_treated_as_1(self):
        """Even multipliers set odd=0; x_pos = ((2-1+0)>>1)*24 = 0."""
        # Even multiplier: odd = 2 & 1 = 0
        m = 2
        odd = m & 1  # 0
        xp = ((m - 1 + odd) >> 1) * 24  # ((1)>>1)*24 = 0
        self.assertEqual(xp, 0)

    def test_multiplier_4_xpos(self):
        """Multiplier=4 (odd=0): x_pos = ((4-1+0)>>1)*24 = 1*24 = 24."""
        m = 4
        odd = m & 1
        xp = ((m - 1 + odd) >> 1) * 24
        self.assertEqual(xp, 24)

    def test_multiplier_15_xpos(self):
        """Multiplier=15 (odd=1): x_pos = ((15-1+1)>>1)*24 = 7*24 = 168."""
        self.assertEqual(table_lookup_xpos(15), 168)

    def test_multiplier_15_within_shmem_bounds(self):
        """x_pos for multiplier=15 must fit within the 192-word w=5 table."""
        # Multiplier=15 is the max for w=5 (odd multiples 1..15); verify it fits in 192.
        xp = table_lookup_xpos(15)   # = 7 * 24 = 168
        yp = table_lookup_ypos(xp, 1)  # = 176
        self.assertLessEqual(yp + 8, SECP256K1_W5_SHMEM_SIZE)

    def test_all_odd_multipliers_within_w4_bounds(self):
        """All valid w=4 odd multipliers (1,3,5,7) must produce in-bounds accesses."""
        # w=4 precomputes 4 odd multiples: 1G,3G,5G,7G → 4*24=96 words
        for m in range(1, 8, 2):  # 1, 3, 5, 7
            xp = table_lookup_xpos(m)
            yp_odd = table_lookup_ypos(xp, 1)
            yp_even = table_lookup_ypos(xp, 0)
            self.assertLessEqual(xp + 8, SECP256K1_SHMEM_SIZE,
                                 f"x out of bounds for m={m}")
            self.assertLessEqual(yp_odd + 8, SECP256K1_SHMEM_SIZE,
                                 f"y(odd) out of bounds for m={m}")
            self.assertLessEqual(yp_even + 8, SECP256K1_SHMEM_SIZE,
                                 f"y(even) out of bounds for m={m}")

    def test_all_w5_multipliers_within_w5_bounds(self):
        """All valid w=5 odd multipliers (1,3,...,15) must stay in 192-word table."""
        # w=5 precomputes 8 odd multiples: 1G,3G,...,15G → 8*24=192 words
        for m in range(1, 16, 2):  # 1, 3, 5, 7, 9, 11, 13, 15
            xp = ((m - 1 + 1) >> 1) * 24  # odd=1 always for odd m
            yp = xp + 8
            self.assertLessEqual(xp + 8, SECP256K1_W5_SHMEM_SIZE,
                                 f"x out of bounds for m={m}")
            self.assertLessEqual(yp + 8, SECP256K1_W5_SHMEM_SIZE,
                                 f"y out of bounds for m={m}")

    def test_lookup_from_w4_table(self):
        """Verify table lookup for 1G x-coordinate using the initialized table."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=32)
        xp = table_lookup_xpos(1)   # = 0
        # x1G[0..7] = PRECOMPUTED[0..7]
        x_words = [table[xp + j] for j in range(8)]
        expected = [PRECOMPUTED[j] for j in range(8)]
        self.assertEqual(x_words, expected)

    def test_lookup_3g_x_from_w4_table(self):
        """Verify 3G x-coordinate lookup from the w=4 table."""
        table = simulate_set_precomputed_basepoint_g_lm(lsz=32)
        xp = table_lookup_xpos(3)   # = 24
        x_words = [table[xp + j] for j in range(8)]
        expected = [PRECOMPUTED[24 + j] for j in range(8)]
        self.assertEqual(x_words, expected)

    def test_lookup_1g_y_from_w5_table(self):
        """Verify 1G y-coordinate lookup from the w=5 table (odd)."""
        table = simulate_set_precomputed_basepoint_g_w5_lm(lsz=64)
        xp = table_lookup_xpos(1)     # = 0
        yp = table_lookup_ypos(xp, 1) # = 8
        y_words = [table[yp + j] for j in range(8)]
        expected = [PRECOMPUTED[8 + j] for j in range(8)]
        self.assertEqual(y_words, expected)


class TestShmemHeaderParsing(unittest.TestCase):
    """Verify that the header file has been correctly patched with Task 5 macros."""

    def test_header_defines_secp256k1_use_shmem(self):
        """inc_ecc_secp256k1.h must define SECP256K1_USE_SHMEM."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("SECP256K1_USE_SHMEM", content)

    def test_header_defines_shmem_size(self):
        """inc_ecc_secp256k1.h must define SECP256K1_SHMEM_SIZE as 96."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("#define SECP256K1_SHMEM_SIZE", content)
        m = re.search(r"#define SECP256K1_SHMEM_SIZE\s+(\d+)", content)
        self.assertIsNotNone(m)
        self.assertEqual(int(m.group(1)), 96)

    def test_header_defines_w5_shmem_size(self):
        """inc_ecc_secp256k1.h must define SECP256K1_W5_SHMEM_SIZE as 192."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("#define SECP256K1_W5_SHMEM_SIZE", content)
        m = re.search(r"#define SECP256K1_W5_SHMEM_SIZE\s+(\d+)", content)
        self.assertIsNotNone(m)
        self.assertEqual(int(m.group(1)), 192)

    def test_header_declares_set_lm_function(self):
        """Header must declare set_precomputed_basepoint_g_lm."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("set_precomputed_basepoint_g_lm", content)

    def test_header_declares_point_mul_xy_lm(self):
        """Header must declare point_mul_xy_lm."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("point_mul_xy_lm", content)

    def test_header_declares_set_w5_lm_function(self):
        """Header must declare set_precomputed_basepoint_g_w5_lm."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("set_precomputed_basepoint_g_w5_lm", content)

    def test_header_declares_point_mul_wnaf_w5_lm(self):
        """Header must declare point_mul_wnaf_w5_lm."""
        with open(_HEADER_PATH) as fh:
            content = fh.read()
        self.assertIn("point_mul_wnaf_w5_lm", content)


class TestModuleFilesUseShmem(unittest.TestCase):
    """Verify that m35910_* module files use the SHMEM path."""

    _MODULES = [
        "OpenCL/m35910_a0-pure.cl",
        "OpenCL/m35910_a1-pure.cl",
        "OpenCL/m35910_a3-pure.cl",
    ]

    def _read(self, rel_path):
        path = os.path.join(_REPO_ROOT, rel_path)
        with open(path) as fh:
            return fh.read()

    def test_a0_uses_point_mul_xy_lm(self):
        content = self._read("OpenCL/m35910_a0-pure.cl")
        self.assertIn("point_mul_xy_lm", content)

    def test_a0_no_private_preG(self):
        """a0 must not declare the old private preG table."""
        content = self._read("OpenCL/m35910_a0-pure.cl")
        self.assertNotIn("secp256k1_t preG", content)

    def test_a1_uses_point_mul_xy_lm(self):
        content = self._read("OpenCL/m35910_a1-pure.cl")
        self.assertIn("point_mul_xy_lm", content)

    def test_a1_no_private_preG(self):
        content = self._read("OpenCL/m35910_a1-pure.cl")
        self.assertNotIn("secp256k1_t preG", content)

    def test_a3_uses_point_mul_xy_lm(self):
        content = self._read("OpenCL/m35910_a3-pure.cl")
        self.assertIn("point_mul_xy_lm", content)

    def test_a3_no_private_preG(self):
        content = self._read("OpenCL/m35910_a3-pure.cl")
        self.assertNotIn("secp256k1_t preG", content)

    def test_all_modules_declare_shmem_array(self):
        """Each module must declare LOCAL_VK u32 s_secp256k1_xy."""
        for rel in self._MODULES:
            with self.subTest(module=rel):
                content = self._read(rel)
                self.assertIn("LOCAL_VK u32 s_secp256k1_xy", content)

    def test_all_modules_call_set_lm(self):
        """Each module must call set_precomputed_basepoint_g_lm."""
        for rel in self._MODULES:
            with self.subTest(module=rel):
                content = self._read(rel)
                self.assertIn("set_precomputed_basepoint_g_lm", content)

    def test_all_modules_use_shmem_size_constant(self):
        """Each module must reference SECP256K1_SHMEM_SIZE."""
        for rel in self._MODULES:
            with self.subTest(module=rel):
                content = self._read(rel)
                self.assertIn("SECP256K1_SHMEM_SIZE", content)


class TestClFileHasShmemFunctions(unittest.TestCase):
    """Verify that inc_ecc_secp256k1.cl has been patched with 4 new functions."""

    _CL_PATH = os.path.join(_REPO_ROOT, "OpenCL", "inc_ecc_secp256k1.cl")

    def _read(self):
        with open(self._CL_PATH) as fh:
            return fh.read()

    def test_cl_defines_set_lm(self):
        self.assertIn("set_precomputed_basepoint_g_lm", self._read())

    def test_cl_defines_point_mul_xy_lm(self):
        self.assertIn("point_mul_xy_lm", self._read())

    def test_cl_defines_set_w5_lm(self):
        self.assertIn("set_precomputed_basepoint_g_w5_lm", self._read())

    def test_cl_defines_point_mul_wnaf_w5_lm(self):
        self.assertIn("point_mul_wnaf_w5_lm", self._read())

    def test_cl_uses_sync_threads(self):
        """SHMEM init functions must call SYNC_THREADS()."""
        content = self._read()
        self.assertIn("SYNC_THREADS", content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
