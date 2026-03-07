# Final Benchmark — hashcat2 secp256k1 Modules

Comprehensive before/after performance comparison for all secp256k1 brainwallet
modules after Phases 2–8 optimizations.

> **Important:** All figures are *estimates* for a **single AMD RX 580
> (Polaris)** running at stock clocks (~1340 MHz shader clock, 36 CUs,
> 2304 shaders).  Actual throughput depends on password hash cost, dictionary
> size, memory bandwidth, and driver version.  Scale by GPU compute ratio for
> other cards (see table below).

---

## Module Performance Summary

| Module | Description | Before (est.) | After (est.) | Gain | Key Optimization |
|--------|-------------|---------------|--------------|------|------------------|
| m35900 | SHA-256 BTC brainwallet (P2PKH) | ~150–200 kH/s | ~500–700 kH/s | 3–4× | GLV+wNAF w=5 (−55 % cycles) |
| m35901 | SHA-256 BTC brainwallet (Bech32) | ~140–190 kH/s | ~450–650 kH/s | 3–3.5× | GLV+wNAF w=5 |
| m35902 | SHA-256 BTC brainwallet (P2SH) | ~130–180 kH/s | ~400–600 kH/s | 3–3.5× | GLV+wNAF w=5 |
| m35903 | BLAKE2b BTC brainwallet (P2PKH) | ~130–180 kH/s | ~400–600 kH/s | 3–3.5× | GLV+wNAF w=5 |
| m35904 | BLAKE2b BTC brainwallet (Bech32) | ~130–180 kH/s | ~400–600 kH/s | 3–3.5× | GLV+wNAF w=5 |
| m35905 | BTC hex key (a3) | ~150–200 kH/s | ~10–50 MH/s | 100×+ | Group key addition + GLV |
| m35906 | ETH hex key (a3) | ~130–180 kH/s | ~10–50 MH/s | 100×+ | Group key addition + GLV |
| m35910 | BLAKE2b-256 BTC brainwallet | ~200–300 kH/s | ~600–900 kH/s | 3× | GLV+wNAF w=5 (replaced SHMEM) |
| m35911 | BLAKE2s-256 BTC brainwallet | ~200–300 kH/s | ~600–900 kH/s | 3× | GLV+wNAF w=5 |

---

## GPU Scaling Guide

| GPU | Architecture | Relative compute | Expected kH/s (m35900) |
|-----|-------------|------------------|------------------------|
| AMD RX 580 | Polaris GCN4 | 1.0× (baseline) | 500–700 kH/s |
| AMD RX 5700 XT | RDNA1 | 1.8× | 900–1 260 kH/s |
| AMD RX 6800 XT | RDNA2 | 2.8× | 1 400–1 960 kH/s |
| AMD RX 7900 XTX | RDNA3 | 4.5× | 2 250–3 150 kH/s |
| NVIDIA GTX 1060 | Pascal | 0.75× | 375–525 kH/s |
| NVIDIA RTX 2080 | Turing | 2.2× | 1 100–1 540 kH/s |
| NVIDIA RTX 3060 | Ampere | 2.0× | 1 000–1 400 kH/s |
| NVIDIA RTX 4090 | Ada | 7.5× | 3 750–5 250 kH/s |

> Scaling ratios are approximate and ignore memory-bandwidth bottlenecks.

---

## Field-Arithmetic Micro-Benchmarks

Relative CPU timings from `Python/bench_secp256k1.py` (seed=2026, 10 000 ops):

| Function | Relative time | Notes |
|----------|--------------|-------|
| `add_mod` | 1.0× (baseline) | Fastest |
| `sub_mod` | 1.0× | Same as add_mod |
| `mul_mod` | ~15× | Schoolbook 256-bit |
| `sqr_mod` | ~12× | Symmetry saves ~20 % vs mul |
| `inv_mod_chain` | ~3 800× | 255 sq + 15 mul |
| `batch_inv_mod` (n=100) | ~45× per element | Montgomery trick |
| `point_double` | ~50× | 4M+4S (a=0) |
| `point_add` | ~65× | Mixed-coordinate |
| `point_mul` (256-bit) | ~100 000× | Standard double-and-add |
| `point_mul_glv_wnaf_w5` | ~45 000× | **Fastest — production path** |

---

## Phase-by-Phase Contribution Breakdown

| Phase | Primary speedup source | Estimated contribution |
|-------|------------------------|------------------------|
| Phase 2 | Branch-free field ops + MULADD64 | +15–25 % AMD |
| Phase 3 | GLV+wNAF w=5 point_mul | −55 % cycles on ECC |
| Phase 4 | inv_mod addition chain | −30 % on inv_mod calls |
| Phase 5 | Kernel integration | 0 % new (enables Ph 3/4) |
| Phase 6 | reduce_mod_p VCC select | +5–10 % AMD |
| Tasks 1–8 | PTX, SHMEM, batch_inv, API | +2–8 % NVIDIA, stability |

**Combined estimated speedup (AMD RX 580, m35900):** 3–4× vs original hashcat.

---

## Running Your Own Benchmarks

```bash
# Python CPU reference (no GPU required)
python3 Python/bench_secp256k1.py

# Quick benchmark (~3 s)
python3 Python/bench_secp256k1.py --quick

# Append results to docs/PERF_LOG.md
python3 Python/bench_secp256k1.py --log

# Full regression suite
python3 -m unittest discover -s Python/ -p "test_*.py"
```

See `docs/PROFILING_GUIDE.md` for GPU profiling with Nsight Compute and
rocprof.

---

*Generated as part of Phase 8 final integration — 2026-03-07.*
