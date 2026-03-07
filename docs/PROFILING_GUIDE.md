# GPU Profiling Guide — secp256k1 Kernel Optimisation

This guide explains how to capture occupancy, latency, and stall metrics for
the secp256k1 OpenCL kernels using the standard GPU vendor profiling tools.

---

## 1. NVIDIA — Nsight Compute (ncu)

### Prerequisites

- CUDA Toolkit ≥ 11.x (ships `ncu`)
- Driver ≥ R450
- hashcat built with NVIDIA OpenCL runtime

### Quick start

```bash
# Profile a single hashcat run (module 35910, brainwallet benchmark)
ncu --target-processes all \
    --metrics sm__throughput.avg.pct_of_peak_sustained_elapsed,\
l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum,\
smsp__sass_average_branch_targets_threads_uniform.pct,\
smsp__warp_issue_stalled_wait_dep_per_warp_active.pct,\
smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct,\
smsp__occupancy_pct \
    --launch-count 1 \
    --section SpeedOfLight \
    --section Occupancy \
    --section MemoryWorkloadAnalysis \
    --section WarpStateStatistics \
    -o secp256k1_profile.ncu-rep \
    ./hashcat -a 0 -m 35910 example0.hash example.dict --opencl-device-types 1 -n 1 -w 3
```

### Metrics of interest

| Metric | CLI flag | Target |
|--------|----------|--------|
| Achieved occupancy | `smsp__occupancy_pct` | ≥ 50 % |
| SM throughput | `sm__throughput.avg.pct_of_peak_sustained_elapsed` | ≥ 60 % |
| Dep stall cycles | `smsp__warp_issue_stalled_wait_dep_per_warp_active.pct` | < 30 % |
| MIO stall cycles | `smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct` | < 20 % |
| Global load sectors | `l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum` | minimise |

### Viewing results

```bash
# Open interactive report
ncu-ui secp256k1_profile.ncu-rep

# Export CSV summary
ncu --import secp256k1_profile.ncu-rep --csv > perf_nvidia.csv
```

### Per-function profiling (kernel filter)

```bash
# Only profile the secp256k1 scalar-multiply kernel
ncu --kernel-name "m35910_a0" \
    --metrics smsp__occupancy_pct,smsp__warp_issue_stalled_wait_dep_per_warp_active.pct \
    ./hashcat -a 0 -m 35910 example0.hash example.dict --opencl-device-types 1
```

### PTX-level latency (for mul_mod_ptx tuning)

```bash
# Roofline + instruction-level analysis
ncu --section InstructionStats \
    --section LaunchStats \
    --section SourceCounters \
    --kernel-name "m35910_a0" \
    ./hashcat -a 0 -m 35910 example0.hash example.dict
```

---

## 2. AMD — rocprof

### Prerequisites

- ROCm ≥ 5.0 (`rocprof` command)
- hashcat built with ROCm OpenCL or HIP runtime

### Quick start

```bash
# Collect hardware performance counters
rocprof --stats \
        --hsa-trace \
        -i rocprof_counters.txt \
        -o perf_amd.csv \
        ./hashcat -a 0 -m 35910 example0.hash example.dict --opencl-device-types 1
```

### Counter file (`rocprof_counters.txt`)

```
# Occupancy and throughput
pmc : Wavefronts VALUInsts VFetchInsts VMEMInsts SALUInsts SFetchInsts
pmc : TCC_HIT[0] TCC_MISS[0]
pmc : VALUUtilization VALUBusy SALUBusy
pmc : L2CacheHit MemUnitBusy
```

Save as `rocprof_counters.txt` and pass with `-i`.

### Key AMD metrics

| Metric | Counter | Target |
|--------|---------|--------|
| Wave occupancy | `Wavefronts` | maximise |
| VALU utilisation | `VALUUtilization` | ≥ 60 % |
| Cache hit rate | `L2CacheHit` | ≥ 80 % |
| Memory busy | `MemUnitBusy` | < 40 % |

### Viewing results

```bash
# CSV output from rocprof contains per-kernel rows
# Import into spreadsheet or parse with Python:
python3 -c "
import csv
with open('perf_amd.csv') as f:
    for row in csv.DictReader(f):
        print(row.get('KernelName'), row.get('VALUUtilization'), row.get('Wavefronts'))
"
```

---

## 3. Benchmark targets by function

| Function | File | NVIDIA target (occupancy) | AMD target (VALUUtil) | Notes |
|----------|------|--------------------------|----------------------|-------|
| `mul_mod` | `inc_ecc_secp256k1.cl` | ≥ 50 % | ≥ 60 % | PTX path on NV |
| `mul_mod_ptx` | `inc_ecc_secp256k1.cl` | ≥ 50 % | N/A | NVIDIA only |
| `sqr_mod` | `inc_ecc_secp256k1.cl` | ≥ 50 % | ≥ 60 % | |
| `inv_mod` | `inc_ecc_secp256k1.cl` | ≥ 40 % | ≥ 50 % | Fermat chain |
| `batch_inv_mod` | `inc_ecc_secp256k1.cl` | ≥ 40 % | ≥ 50 % | n=3 for precomp |
| `point_double` | `inc_ecc_secp256k1.cl` | ≥ 40 % | ≥ 50 % | a=0 path |
| `point_mul_xy` | `inc_ecc_secp256k1.cl` | ≥ 30 % | ≥ 40 % | w=4 standard |
| `point_mul_glv_xy` | `inc_ecc_secp256k1.cl` | ≥ 35 % | ≥ 45 % | GLV path |
| `point_mul_wnaf_w5` | `inc_ecc_secp256k1.cl` | ≥ 35 % | ≥ 45 % | wNAF w=5 |
| `point_mul_xy_lm` | `inc_ecc_secp256k1.cl` | ≥ 50 % | ≥ 60 % | SHMEM path |
| `point_mul_wnaf_w5_lm` | `inc_ecc_secp256k1.cl` | ≥ 50 % | ≥ 60 % | SHMEM+wNAF |

---

## 4. Python CPU reference benchmarks

No GPU required.  Use these for algorithmic validation and relative comparisons:

```bash
# All benchmarks (full iteration counts, ~30 s)
python3 Python/bench_secp256k1.py

# Quick smoke test (~3 s)
python3 Python/bench_secp256k1.py --quick

# Append result to docs/PERF_LOG.md
python3 Python/bench_secp256k1.py --log
```

Functions benchmarked: `mul_mod`, `sqr_mod`, `add_mod`, `sub_mod`, `inv_mod`,
`batch_inv_mod`, `point_double`, `point_add`, `point_mul` (standard / GLV / wNAF w=5).

---

## 5. Regression tests (libsecp256k1 vectors)

Verify that all optimised paths produce identical results to the reference:

```bash
# 31 tests against libsecp256k1 known vectors + cross-implementation consistency
python3 -m unittest Python/test_regression_libsecp256k1.py -v

# Full test suite (238 tests)
python3 -m unittest discover -s Python -p "test_*.py"
```

Test coverage:
- `TestFieldArithmetic` — mul_mod, sqr_mod, add_mod, sub_mod, inv_mod against libsecp256k1 vectors
- `TestBatchInvMod` — batch_inv_mod Montgomery trick correctness
- `TestPointArithmetic` — 1G..7G, n*G=∞, point negation against SEC 2 / libsecp256k1
- `TestGLVRegression` — GLV vs standard for known + 30 random scalars
- `TestWNAFRegression` — wNAF w=5 vs standard for known + 30 random scalars
- `TestCrossImplementationConsistency` — all three modes agree for 50 random scalars

---

## 6. Hashrate comparison methodology

To compare hashrate against KeyHunt / ice_poseidon2:

1. Run hashcat with module 35910 on a fixed dictionary:
   ```bash
   ./hashcat -a 0 -m 35910 test.hash wordlist.txt --status --status-timer 5
   ```
2. Record `H/s` from the status line.
3. Run KeyHunt:
   ```bash
   ./keyhunt -m bsgs -f hash160.bin -n 1000000 -t 4
   ```
4. Compare throughput in MH/s or kH/s per GPU.

Key metrics to record in `docs/PERF_LOG.md`:
- hashcat H/s before and after each optimisation commit
- Function-level speedups from Python bench (as relative proxy)
- Occupancy and stall metrics from Nsight Compute / rocprof

---

## 7. References

- NVIDIA Nsight Compute: https://docs.nvidia.com/nsight-compute/
- AMD rocprof: https://rocmdocs.amd.com/en/latest/ROCm_Tools/rocprof.html
- libsecp256k1: https://github.com/bitcoin-core/secp256k1
- CudaBrainSecp: https://github.com/XopMC/CudaBrainSecp
- ice_poseidon2/secp256k1_cuda: https://github.com/ice-posesidon2/secp256k1_cuda
- micro-ecc: https://github.com/kmackay/micro-ecc
- KeyHunt: https://github.com/KeyHunt/keyhunt
- Gist PTX macros: https://gist.github.com/lawliet89/9677319
