#!/usr/bin/env python3
"""
secp256k1 CPU-reference benchmarks for Task 6 — Profiling & Benchmarking.

Measures the pure-Python reference implementations of the same algorithms that
are compiled into the OpenCL/CUDA kernels.  The numbers produced here serve as
a *relative* baseline:
  • The ratios between modes (GLV vs standard, batch vs single inv) are stable
    and meaningful even on CPU.
  • For absolute GPU throughput, see docs/PROFILING_GUIDE.md (Nsight Compute /
    rocprof instructions).

Functions benchmarked
─────────────────────
  mul_mod          — modular multiplication mod p  (baseline field op)
  sqr_mod          — modular squaring mod p
  add_mod          — modular addition mod p
  sub_mod          — modular subtraction mod p
  inv_mod          — single Fermat inversion (Fermat little-theorem)
  batch_inv_mod    — Montgomery batch inversion (n inv + 3(n-1) mul)
  point_double     — affine point doubling
  point_add        — affine point addition
  point_mul        — standard double-and-add scalar multiplication
  point_mul_glv    — GLV two-scalar interleaved multiplication
  point_mul_wnaf   — w=5 wNAF scalar multiplication

Modes compared
──────────────
  • standard        — naïve double-and-add
  • GLV             — GLV endomorphism decomposition + interleaved
  • wNAF w=5        — windowed non-adjacent-form (precomputed 9G..15G)

Usage
─────
  python3 Python/bench_secp256k1.py              # all benchmarks
  python3 Python/bench_secp256k1.py --quick      # reduced iterations
  python3 Python/bench_secp256k1.py --log        # append result to docs/PERF_LOG.md

References
──────────
  libsecp256k1 src/ecmult_impl.h, src/field_impl.h
  micro-ecc uECC.c (schoolbook multiply)
  CudaBrainSecp ptx_macros.cu (carry-chain reference)
  KeyHunt src/ec.cpp (point_mul comparison baseline)
  ice_poseidon2/secp256k1_cuda (batch inversion)
"""

import argparse
import datetime
import os
import random
import sys
import time

# ---------------------------------------------------------------------------
# secp256k1 curve constants
# ---------------------------------------------------------------------------

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

# GLV constants
LAMBDA = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
BETA   = 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE

# a1, b1, a2 lattice basis vectors (Babai rounding)
_A1 = 0x3086D221A7D46BCDE86C90E49284EB15
_B1 = 0xE4437ED6010E88286F547FA90ABFE4C3   # absolute value of b1 (b1 < 0 in the lattice)
_A2 = 0x114CA50F7A8E2F3F657C1108D9D44CFD8  # 129-bit

# Babai rounding multipliers
_G1_WORDS = [0x45dbb031, 0xe893209a, 0x71e8ca7f, 0x3daa8a14,
             0x9284eb15, 0xe86c90e4, 0xa7d46bcd, 0x3086d221]
_G2_WORDS = [0x8ac47f71, 0x1571b4ae, 0x9df506c6, 0x221208ac,
             0x0abfe4c4, 0x6f547fa9, 0x010e8828, 0xe4437ed6]
_G1 = sum(_G1_WORDS[i] * (1 << (32 * i)) for i in range(8))
_G2 = sum(_G2_WORDS[i] * (1 << (32 * i)) for i in range(8))

# w=5 precomputed table: 9G, 11G, 13G, 15G (odd multiples of G up to 2^w-1)
# These are the same constants stored in inc_ecc_secp256k1.h
_W5_TABLE_SCALARS = [1, 3, 5, 7, 9, 11, 13, 15]

# ---------------------------------------------------------------------------
# Pure-Python reference implementations (mirrors OpenCL kernel logic)
# ---------------------------------------------------------------------------


def mul_mod(a: int, b: int) -> int:
    """Field multiplication mod p."""
    return (a * b) % P


def sqr_mod(a: int) -> int:
    """Field squaring mod p (== mul_mod(a, a))."""
    return (a * a) % P


def add_mod(a: int, b: int) -> int:
    """Field addition mod p."""
    r = a + b
    return r - P if r >= P else r


def sub_mod(a: int, b: int) -> int:
    """Field subtraction mod p."""
    r = a - b
    return r + P if r < 0 else r


def inv_mod(a: int) -> int:
    """Modular inverse via Fermat's little theorem: a^(p-2) mod p."""
    return pow(a, P - 2, P)


def batch_inv_mod(arr):
    """
    Montgomery's trick batch inversion.
    Returns [inv_mod(x) for x in arr] using 1 inversion + 3(n-1) multiplications.
    """
    n = len(arr)
    if n == 0:
        return []
    prefix = [0] * n
    prefix[0] = arr[0]
    for i in range(1, n):
        prefix[i] = mul_mod(prefix[i - 1], arr[i])
    inv_prod = inv_mod(prefix[n - 1])
    result = [0] * n
    for i in range(n - 1, 0, -1):
        result[i] = mul_mod(inv_prod, prefix[i - 1])
        inv_prod = mul_mod(inv_prod, arr[i])
    result[0] = inv_prod
    return result


def _modinv_ext(a: int, m: int) -> int:
    g, x, _ = _ext_gcd(a % m, m)
    if g != 1:
        raise ValueError("no inverse")
    return x % m


def _ext_gcd(a, b):
    if a == 0:
        return b, 0, 1
    g, x, y = _ext_gcd(b % a, a)
    return g, y - (b // a) * x, x


def point_double(Px: int, Py: int):
    """Affine secp256k1 point doubling (a=0)."""
    if Px is None:
        return None, None
    lam = mul_mod(3, sqr_mod(Px))
    lam = mul_mod(lam, inv_mod(mul_mod(2, Py)))
    Rx = sub_mod(sqr_mod(lam), add_mod(Px, Px))
    Ry = sub_mod(mul_mod(lam, sub_mod(Px, Rx)), Py)
    return Rx, Ry


def point_add(P1x, P1y, P2x, P2y):
    """Affine secp256k1 point addition."""
    if P1x is None:
        return P2x, P2y
    if P2x is None:
        return P1x, P1y
    if P1x == P2x:
        if P1y == P2y:
            return point_double(P1x, P1y)
        return None, None
    lam = mul_mod(sub_mod(P2y, P1y), inv_mod(sub_mod(P2x, P1x)))
    Rx = sub_mod(sub_mod(sqr_mod(lam), P1x), P2x)
    Ry = sub_mod(mul_mod(lam, sub_mod(P1x, Rx)), P1y)
    return Rx, Ry


def point_mul(k: int, Px: int = Gx, Py: int = Gy):
    """Standard left-to-right double-and-add scalar multiplication."""
    Rx, Ry = None, None
    for bit in bin(k)[2:]:
        if Rx is not None:
            Rx, Ry = point_double(Rx, Ry)
        if bit == "1":
            Rx, Ry = point_add(Rx, Ry, Px, Py)
    return Rx, Ry


def _glv_decompose(k: int):
    """
    GLV scalar decomposition using Babai rounding.
    Matches libsecp256k1 secp256k1_scalar_split_lambda / OpenCL glv_decompose.
    Returns signed integers (k1, k2) such that k ≡ k1 + k2 * lambda (mod n).
    """
    c1 = (k * _G1) >> 384
    c2 = (k * _G2) >> 384
    k1 = k - c1 * _A1 - c2 * _A2
    k2 = c1 * _B1 - c2 * _A1
    return k1, k2


def point_mul_glv(k: int):
    """
    GLV scalar multiplication: k*G using endomorphism phi(P)=(beta*x, y).
    Splits k = k1 + k2*lambda and computes k1*G + k2*phi(G) interleaved.
    Handles signed k1, k2 via point negation.
    """
    k1, k2 = _glv_decompose(k)
    # phi(G) = (beta * Gx mod p, Gy)
    phiGx = mul_mod(BETA, Gx)
    phiGy = Gy
    # Handle signs: negate y if scalar is negative
    k1_neg = k1 < 0
    k2_neg = k2 < 0
    k1_abs = abs(k1)
    k2_abs = abs(k2)
    G_y  = P - Gy    if k1_neg else Gy
    PG_y = P - phiGy if k2_neg else phiGy
    # Simultaneous double-and-add (interleaved binary method)
    Rx, Ry = None, None
    length = max(k1_abs.bit_length(), k2_abs.bit_length())
    for i in range(length - 1, -1, -1):
        if Rx is not None:
            Rx, Ry = point_double(Rx, Ry)
        if (k1_abs >> i) & 1:
            Rx, Ry = point_add(Rx, Ry, Gx, G_y)
        if (k2_abs >> i) & 1:
            Rx, Ry = point_add(Rx, Ry, phiGx, PG_y)
    return Rx, Ry


def _build_wnaf_table():
    """Build w=5 precomputed table: G, 3G, 5G, 7G, 9G, 11G, 13G, 15G."""
    table = [(Gx, Gy)]
    G2x, G2y = point_double(Gx, Gy)
    for _ in range(7):
        px, py = table[-1]
        nx, ny = point_add(px, py, G2x, G2y)
        table.append((nx, ny))
    return table


_W5_TABLE = None


def _get_w5_table():
    global _W5_TABLE
    if _W5_TABLE is None:
        _W5_TABLE = _build_wnaf_table()
    return _W5_TABLE


def _convert_to_wnaf(k: int, w: int) -> list:
    """w-NAF representation (least-significant digit first)."""
    half = 1 << (w - 1)
    two_w = 1 << w
    mask = two_w - 1
    naf = []
    n = k
    while n > 0:
        if n & 1:
            mods = n & mask
            digit = mods - two_w if mods >= half else mods
            n -= digit
            naf.append(digit)
        else:
            naf.append(0)
        n >>= 1
    return naf


def point_mul_wnaf_w5(k: int):
    """w=5 wNAF scalar multiplication using precomputed 1G..15G table."""
    table = _get_w5_table()   # indices: table[0]=1G, table[1]=3G, ..., table[7]=15G
    naf = _convert_to_wnaf(k, 5)
    Rx, Ry = None, None
    for d in reversed(naf):
        if Rx is not None:
            Rx, Ry = point_double(Rx, Ry)
        if d > 0:
            idx = (d - 1) // 2
            Rx, Ry = point_add(Rx, Ry, table[idx][0], table[idx][1])
        elif d < 0:
            idx = (-d - 1) // 2
            Rx, Ry = point_add(Rx, Ry, table[idx][0], P - table[idx][1])
    return Rx, Ry


# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

def _timeit(fn, n_iter: int):
    """Return (result_of_last_call, total_seconds, ns_per_op)."""
    start = time.perf_counter()
    res = None
    for _ in range(n_iter):
        res = fn()
    elapsed = time.perf_counter() - start
    return res, elapsed, elapsed / n_iter * 1e9


# ---------------------------------------------------------------------------
# Benchmark suites
# ---------------------------------------------------------------------------

def bench_field_ops(n_iter: int = 50_000):
    """Benchmark primitive field operations."""
    a = 0xDEADBEEFCAFEBABE1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF
    b = 0xCAFEBABEDEADBEEF0011223344556677889900AABBCCDDEEFF00112233445566
    a %= P
    b %= P

    results = {}
    ops = {
        "mul_mod":    lambda: mul_mod(a, b),
        "sqr_mod":    lambda: sqr_mod(a),
        "add_mod":    lambda: add_mod(a, b),
        "sub_mod":    lambda: sub_mod(a, b),
        "inv_mod":    lambda: inv_mod(a),
    }
    for name, fn in ops.items():
        n = max(1, n_iter // (1000 if "inv" in name else 1))
        _, elapsed, ns_op = _timeit(fn, n)
        results[name] = {"ns_per_op": ns_op, "iterations": n, "total_s": elapsed}
    return results


def bench_batch_inv(sizes=(1, 4, 8, 16, 32, 64), n_iter: int = 200):
    """Benchmark batch_inv_mod for various batch sizes."""
    rng = random.Random(42)
    results = {}
    for sz in sizes:
        arr = [rng.randrange(1, P) for _ in range(sz)]
        _, elapsed, ns_op = _timeit(lambda a=arr: batch_inv_mod(a), n_iter)
        results[f"batch_inv[{sz:3d}]"] = {
            "ns_per_op": ns_op,
            "ns_per_element": ns_op / sz,
            "batch_size": sz,
            "iterations": n_iter,
        }
    return results


def bench_point_mul(n_iter: int = 20):
    """Benchmark the three point_mul modes against each other."""
    rng = random.Random(7)
    scalars = [rng.randrange(1, N) for _ in range(n_iter)]

    modes = {
        "point_mul (standard)": lambda k: point_mul(k),
        "point_mul_glv (GLV)":  lambda k: point_mul_glv(k),
        "point_mul_wnaf_w5":    lambda k: point_mul_wnaf_w5(k),
    }
    results = {}
    for name, fn in modes.items():
        start = time.perf_counter()
        out = [fn(k) for k in scalars]
        elapsed = time.perf_counter() - start
        ns_op = elapsed / n_iter * 1e9
        results[name] = {"ns_per_op": ns_op, "iterations": n_iter, "total_s": elapsed}
        _ = out  # suppress unused warning
    return results


def bench_point_double_add(n_iter: int = 100_000):
    """Benchmark raw point_double and point_add."""
    results = {}
    _, elapsed, ns_op = _timeit(lambda: point_double(Gx, Gy), n_iter)
    results["point_double"] = {"ns_per_op": ns_op, "iterations": n_iter}
    G2x, G2y = point_double(Gx, Gy)
    _, elapsed, ns_op = _timeit(lambda: point_add(Gx, Gy, G2x, G2y), n_iter)
    results["point_add"] = {"ns_per_op": ns_op, "iterations": n_iter}
    return results


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def _fmt_ns(ns: float) -> str:
    if ns >= 1e9:
        return f"{ns/1e9:.3f} s"
    if ns >= 1e6:
        return f"{ns/1e6:.3f} ms"
    if ns >= 1e3:
        return f"{ns/1e3:.3f} µs"
    return f"{ns:.1f} ns"


def print_results(field: dict, batch: dict, point_ops: dict, mul_modes: dict):
    """Pretty-print all benchmark results."""
    sep = "-" * 62

    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print("\n" + "=" * 62)
    print("  secp256k1 Python Reference Benchmarks")
    print(f"  {ts}")
    print("=" * 62)

    print(f"\n{'Field operations':}")
    print(sep)
    print(f"  {'Function':<22}  {'ns/op':>12}  {'iters':>8}")
    print(sep)
    for name, v in field.items():
        print(f"  {name:<22}  {_fmt_ns(v['ns_per_op']):>12}  {v['iterations']:>8,}")

    print(f"\n{'Point operations':}")
    print(sep)
    print(f"  {'Function':<22}  {'ns/op':>12}  {'iters':>8}")
    print(sep)
    for name, v in point_ops.items():
        print(f"  {name:<22}  {_fmt_ns(v['ns_per_op']):>12}  {v['iterations']:>8,}")

    print(f"\n{'Scalar multiplication modes':}")
    print(sep)
    baseline_ns = list(mul_modes.values())[0]["ns_per_op"]
    print(f"  {'Mode':<30}  {'ns/op':>12}  {'speedup':>8}")
    print(sep)
    for name, v in mul_modes.items():
        sp = baseline_ns / v["ns_per_op"]
        print(f"  {name:<30}  {_fmt_ns(v['ns_per_op']):>12}  {sp:>7.3f}x")

    print(f"\n{'Batch modular inversion':}")
    print(sep)
    print(f"  {'Batch size':<14}  {'ns/call':>12}  {'ns/element':>12}")
    print(sep)
    for name, v in batch.items():
        print(f"  {v['batch_size']:<14}  {_fmt_ns(v['ns_per_op']):>12}  "
              f"{_fmt_ns(v['ns_per_element']):>12}")

    print()


def _perf_log_entry(field: dict, batch: dict, point_ops: dict, mul_modes: dict) -> str:
    """Format a Markdown table row for docs/PERF_LOG.md."""
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    mul_std = mul_modes["point_mul (standard)"]["ns_per_op"]
    mul_glv = mul_modes["point_mul_glv (GLV)"]["ns_per_op"]
    mul_w5  = mul_modes["point_mul_wnaf_w5"]["ns_per_op"]
    mm      = field["mul_mod"]["ns_per_op"]
    bi64    = batch.get("batch_inv[ 64]", {}).get("ns_per_op", float("nan"))
    glv_sp  = mul_std / mul_glv if mul_glv else float("nan")
    w5_sp   = mul_std / mul_w5  if mul_w5  else float("nan")

    return (
        f"| {ts} | {_fmt_ns(mm)} | {_fmt_ns(mul_std)} | "
        f"{_fmt_ns(mul_glv)} ({glv_sp:.3f}x) | "
        f"{_fmt_ns(mul_w5)} ({w5_sp:.3f}x) | "
        f"{_fmt_ns(bi64)} | "
        f"CPU Python reference |\n"
    )


def append_perf_log(entry: str, log_path: str):
    """Append a bench result row to docs/PERF_LOG.md."""
    with open(log_path, "a") as fh:
        fh.write(entry)
    print(f"  [perf-log] appended to {log_path}")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="secp256k1 Python reference benchmarks")
    parser.add_argument("--quick", action="store_true",
                        help="Use reduced iteration counts for a fast smoke test")
    parser.add_argument("--log", action="store_true",
                        help="Append result row to docs/PERF_LOG.md")
    args = parser.parse_args()

    scale = 10 if args.quick else 1

    field    = bench_field_ops(n_iter=max(1, 50_000 // scale))
    point_ops = bench_point_double_add(n_iter=max(1, 100_000 // scale))
    mul_modes = bench_point_mul(n_iter=max(1, 20 // scale))
    batch    = bench_batch_inv(n_iter=max(1, 200 // scale))

    print_results(field, batch, point_ops, mul_modes)

    if args.log:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        log_path = os.path.join(repo_root, "docs", "PERF_LOG.md")
        if os.path.exists(log_path):
            entry = _perf_log_entry(field, batch, point_ops, mul_modes)
            append_perf_log(entry, log_path)
        else:
            print(f"  [perf-log] {log_path} not found — run without --log first")

    return 0


if __name__ == "__main__":
    sys.exit(main())
