#!/usr/bin/env python3
"""
Window-NAF autotuning for secp256k1 scalar multiplication.

Implements:
  - Pure-Python w-NAF scalar-to-NAF conversion (any window size w)
  - Operation count model: point additions + doublings for w=4..16
  - GPU performance model: estimated relative throughput
  - Autotune: selects optimal window size for a given GPU architecture

References:
  - libsecp256k1 src/ecmult_impl.h (windowed NAF, Weilert's technique)
  - KeyHunt src/nafmul.c (NAF scalar multiplication)
  - Hankerson, Menezes, Vanstone "Guide to ECC" §3.3 (w-NAF)
"""

import random


def convert_to_wnaf(k: int, w: int) -> list:
    """
    Convert integer k to window-NAF representation with window size w.

    Returns a list of signed digits d_i such that:
        k = sum(d_i * 2^i for i in range(len(result)))

    Properties of w-NAF:
      - All nonzero digits are odd and satisfy |d_i| < 2^(w-1)
      - No two consecutive digits are nonzero (sparsity property)
      - Length is at most bit_length(k) + 1

    Args:
        k: Non-negative integer scalar.
        w: Window size (integer >= 2).

    Returns:
        List of signed integers (digits), least-significant first.
    """
    if w < 2:
        raise ValueError(f"Window size w must be >= 2, got {w}")
    if k < 0:
        raise ValueError(f"Scalar k must be non-negative, got {k}")

    half  = 1 << (w - 1)   # 2^(w-1)
    two_w = 1 << w          # 2^w
    mask  = two_w - 1       # 2^w - 1

    naf = []
    n = k

    while n > 0:
        if n & 1:
            # n is odd: extract a window digit
            mods = n & mask        # n mod 2^w  (always in [1, 2^w - 1] since n is odd)
            if mods >= half:
                digit = mods - two_w  # negative digit, in range [-(2^(w-1)-1), -1]
            else:
                digit = mods          # positive digit, in range [1, 2^(w-1)-1]
            n -= digit
            naf.append(digit)
        else:
            naf.append(0)
        n >>= 1

    return naf


def count_operations(k: int, w: int) -> dict:
    """
    Count point operations for scalar multiplication of k using w-NAF.

    Returns:
        dict with keys:
          'adds'      - number of point additions in the main loop
          'doubles'   - number of point doublings
          'precompute'- number of precomputation additions (2^(w-2) - 1)
    """
    naf = convert_to_wnaf(k, w)

    # Doublings: one per bit position from the highest set position down to 0
    if not naf:
        return {'adds': 0, 'doubles': 0, 'precompute': 0}

    # Find highest nonzero position
    highest = len(naf) - 1
    while highest > 0 and naf[highest] == 0:
        highest -= 1

    doubles = highest  # one double per step (excluding the initialization step)
    adds    = sum(1 for d in naf if d != 0) - 1  # -1 for initialization (no add needed)
    if adds < 0:
        adds = 0

    # Precomputation: build table of odd multiples {1G, 3G, 5G, ..., (2^(w-1)-1)G}
    # Costs: 1 doubling to get 2G, then (2^(w-2) - 1) additions to get each odd multiple.
    table_size  = 1 << (w - 2)   # number of odd multiples: 2^(w-2)
    precompute  = max(0, table_size - 1)  # additions for the extra points

    return {
        'adds':       adds,
        'doubles':    doubles,
        'precompute': precompute,
    }


def estimate_ops_random(w: int, n_bits: int = 256, n_samples: int = 500) -> dict:
    """
    Estimate average operation counts over random n_bits-bit scalars.

    Args:
        w:         Window size.
        n_bits:    Bit length of scalars to sample.
        n_samples: Number of random scalars to average over.

    Returns:
        dict with averaged 'adds', 'doubles', 'precompute', and 'total_adds'
        (adds + precompute).
    """
    total_adds       = 0
    total_doubles    = 0
    total_precompute = 0

    for _ in range(n_samples):
        k = random.getrandbits(n_bits)
        if k == 0:
            k = 1
        ops = count_operations(k, w)
        total_adds       += ops['adds']
        total_doubles    += ops['doubles']
        total_precompute += ops['precompute']

    return {
        'adds':        total_adds       / n_samples,
        'doubles':     total_doubles    / n_samples,
        'precompute':  total_precompute / n_samples,
        'total_adds':  (total_adds + total_precompute) / n_samples,
    }


def gpu_cost_model(
    w: int,
    cost_add: float       = 1.0,
    cost_double: float    = 0.8,
    cost_precompute: float = 0.5,
    n_bits: int           = 256,
) -> float:
    """
    Estimate total GPU cost for scalar multiplication with window size w.

    Models the relative clock cycle cost by weighting each operation type:
      - cost_add:        relative cost of a point addition in the main loop
      - cost_double:     relative cost of a point doubling
      - cost_precompute: amortized cost of precomputing additional table points
                         (lower than main-loop additions due to amortization)

    Uses the analytical formula for expected NAF density:
      expected nonzero digits ≈ n_bits / (w + 1)

    Args:
        w:               Window size (integer >= 2).
        cost_add:        Relative cost per point addition.
        cost_double:     Relative cost per point doubling.
        cost_precompute: Amortized relative cost per precomputed point.
        n_bits:          Bit length of scalars.

    Returns:
        float: Estimated total relative cost.
    """
    # Expected number of nonzero NAF digits (analytical estimate)
    expected_adds = n_bits / (w + 1)

    # Doublings: always n_bits for a full n_bits-bit scalar
    doubles = float(n_bits)

    # Precomputed table size: 2^(w-2) points; cost to build extras
    table_size  = 1 << (w - 2)
    precomp_ops = float(max(0, table_size - 1))

    total = (expected_adds * cost_add
             + doubles     * cost_double
             + precomp_ops * cost_precompute)

    return total


def autotune(
    cost_add: float        = 1.0,
    cost_double: float     = 0.8,
    cost_precompute: float = 0.5,
    n_bits: int            = 256,
    w_range: tuple         = (4, 16),
) -> dict:
    """
    Find the optimal window size for the given GPU cost parameters.

    Iterates over w in w_range (inclusive) and selects the w with minimum
    estimated cost. Also reports speedup relative to w=4.

    Args:
        cost_add:        Relative cost per point addition.
        cost_double:     Relative cost per point doubling.
        cost_precompute: Amortized relative cost per precomputed point.
        n_bits:          Bit length of scalars.
        w_range:         (min_w, max_w) inclusive range to search.

    Returns:
        dict with:
          'best_w':        optimal window size
          'results':       {w: cost} for all w in range
          'speedup_vs_w4': speedup of best_w relative to w=4
    """
    w_min, w_max = w_range
    results = {}

    for w in range(w_min, w_max + 1):
        results[w] = gpu_cost_model(
            w,
            cost_add=cost_add,
            cost_double=cost_double,
            cost_precompute=cost_precompute,
            n_bits=n_bits,
        )

    best_w   = min(results, key=results.__getitem__)
    cost_w4  = results.get(4, gpu_cost_model(4, cost_add, cost_double, cost_precompute, n_bits))
    speedup  = cost_w4 / results[best_w] if results[best_w] > 0 else 1.0

    return {
        'best_w':        best_w,
        'results':       results,
        'speedup_vs_w4': speedup,
    }


def print_benchmark_table(results: dict) -> None:
    """
    Print a formatted table of window size vs cost vs speedup.

    Args:
        results: dict returned by autotune().
    """
    best_w    = results['best_w']
    w_results = results['results']
    speedup   = results['speedup_vs_w4']
    cost_w4   = w_results.get(4)

    print(f"{'w':>4}  {'Cost':>10}  {'Speedup vs w=4':>16}  {'Note'}")
    print("-" * 50)

    for w in sorted(w_results):
        cost   = w_results[w]
        rel    = cost_w4 / cost if cost > 0 else 1.0
        marker = " ← best" if w == best_w else ""
        print(f"{w:>4}  {cost:>10.2f}  {rel:>16.4f}x{marker}")

    print("-" * 50)
    print(f"Best window: w={best_w}, speedup vs w=4: {speedup:.4f}x")


if __name__ == "__main__":
    print("=== w-NAF GPU Autotune for secp256k1 ===\n")

    # Default GPU cost model (balanced add/double)
    r = autotune()
    print("Default cost model (add=1.0, double=0.8, precompute=0.5):")
    print_benchmark_table(r)
    print()

    # Higher add cost (add-heavy GPU, e.g., older architectures)
    r2 = autotune(cost_add=1.5, cost_double=0.8, cost_precompute=0.4)
    print("Add-heavy cost model (add=1.5, double=0.8, precompute=0.4):")
    print_benchmark_table(r2)
