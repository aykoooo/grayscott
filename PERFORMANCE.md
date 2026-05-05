# GPU Optimization Results

Persistent benchmark tracker. This file survives crashes and restarts.

## Phase A: FMA Baseline Cleanup (2026-05-05)

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-05 | FMA laplacian applied to all generators (standard, Pearson, WASM) | ~850M–2.3B (session-dependent) | +44% (confirmed via same-session FMA vs non-FMA test) | ✅ Kept — FMA is now baseline |
| 2026-05-05 | Hash gate updated — `e16ed0e3...` = FMA hash, legacy non-FMA hash lost | — | — | ✅ Documented |

**Discovery:** Wgpu-native v29 compiles WGSL `fma()` calls. Session variance extreme (753M–2,302M). Same-process comparisons only.

## Phase B: Instruction Scheduling (2026-05-05)

Same-process benchmark at 256²/500 on RTX 4060.

| Variant | Cells/sec | Delta vs Baseline | Hash |
|---|---|---|---|
| **Baseline** (FMA, card_U→diag_U→card_V→diag_V order) | 1,691M | — | `e16ed0e3...` |
| **Interleaved** (`var` accumulators, strict U/V alternation) | 1,528M | **-9.6%** | `61720aab...` |
| **Early-sum** (card_U→card_V first, then inline diagonals with fma) | 1,857M | **+9.8%** | `61720aab...` |

Second verification run (higher GPU power state):
| **Baseline** | 2,209M | — |
| **Early-sum** | 2,579M | **+16.7%** |

### Key Findings

**1. `var` accumulator overhead kills interleaving.** Explicit `var ca += ...` pattern adds instruction overhead that outweighs any SMEM pipelining benefit. Stick to `let` single-expression accumulations.

**2. Reordering card_U→card_V before diagonals helps.** Computing both cardinal sums back-to-back interleaves tile_u/tile_v SMEM reads without mutable state. The compiler can schedule these independent accesses in parallel.

**3. Inline diagonal sums change FP evaluation order.** Early-sum computes diags inside `fma()` args instead of pre-computing into `let` variables. This changes hash from `e16ed0e3...` to `61720aab...`.

### Path forward

- Apply early-sum ordering to default `generateWgsl` (make it permanent)
- Test workgroup shape sweep with early-sum scheduling (Phase C)
- vec2 SMEM packing may compound with interleaving (Phase D)

## Baseline (restored wgpu-native v29)

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | Naive GPU (9-point stencil, global mem) | 90,247,944 | — | ✅ Baseline |

## Phase 3.1: Thread Coarsening Attempt
| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-04 | Horizontal coarsening (2 cells/thread, cell B via global reads) | ~1.07B median | -34% vs standard (~1.62B) | ❌ Reverted — global reads penalty outweighs dispatch savings |

## Reference
- GPU hash (256²/500 steps): `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- GPU f16 hash (256²/500 steps): `d1acf26754798c4eeb65fb0b0665cf8e197609caafbed2389bdd2ee6adea6bab`
- CPU hash: `9760dfcdb5f49c3bd738ab33afee8be84e56aa31fd2f389cde25faaaeb19bb95`
- Target: >100M cells/sec (2× naive on this Intel iGPU)

Current best: **2,346,051,133 cells/sec** (8×8 tiling + command buffer batching, +2,500% over baseline)
Recent best: **~681M cells/sec** (16×4 workgroup reshape, consistent on 2026-05-04 session)

## Results Log

<!-- Agent appends new entries here after each task -->

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | Shared memory tiling (16×16 tile, 18×18 load) | 152,854,072 | +69.4% | ✅ Kept |
| 2026-05-03 | Shared memory tiling (8×8 workgroup, 10×10 tile) | 167,680,984 | +85.8% | ✅ Best (tiling) |
| 2026-05-03 | + Command buffer batching (500 dispatches in 1 submit) | 2,346,051,133 | +2,500% | ✅ Current Best |

## Phase O Results: Shared Memory Bank Conflict Fix
| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-04 | Stride-11 padding (gcd=1, zero-bank-conflict theory) | ~580M | ~0% | ❌ Reverted — no measurable improvement |
| 2026-05-04 | Stride-16 padding (power-of-2 address calc) | ~547M | ~0% | ❌ Reverted — no measurable improvement |

## Phase R: Workgroup Reshape Sweep
| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-04 | Workgroup reshape 8×8 → 16×4 | ~681M | +12.6% | ✅ Kept — best |
| 2026-05-04 | Workgroup reshape 32×2 | ~642M | +6.1% | Slower than 16×4 |

### Workgroup Size Sweep
| Size | Cells/sec | Result |
|---|---|---|
| 8×8 | 167,680,984 | ✅ Selected |
| 16×16 | 152,854,072 | Slower |
| 32×4 | 110,228,533 | Slower |
| 16×8 | 121,756,371 | Slower |
| 64×2 | 132,468,964 | Slower |
| 32×32 | — | Failed

## Phase K–L Results
| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | f16 feature detection (K.1 — YES on RTX 4060 Vulkan/v29) | — | — | ✅ Committed |
| 2026-05-03 | f16 storage (K.2 — fully implemented, verified deterministic) | ~1.2B–1.7B | ~0% | ❌ Reverted — no bandwidth bottleneck. f32→f16 conversions add ALU overhead, memory savings invisible at compute-bound scale. Separate hash: `d1acf267...ab` |
| 2026-05-03 | vec2<f32> UV packing (L.1) | 1,463,870,088 | -38% | ❌ Reverted — slower |

## Phase M: Multi-resolution Benchmarks
| Resolution | Steps | Cells/sec | Notes |
|---|---|---|---|
| 256² | 500 | ~2.4B | Timer noise (~14ms), compute-bound |
| 512² | 500 | ~2.55B | Stable, compute-bound |
| 1024² | 100 | ~2.38B | Stable, compute-bound |

**Finding**: Throughput constant across scales → **compute-bound**, not bandwidth-limited.

## Phase N.3: GPU vs CPU Map-Bench Comparison

Uniform f=0.0545/k=0.062, periodic boundaries, same seed pattern (RNG=42).

### Pipeline Throughput (init + steps + readback)

| Resolution | Steps | GPU pipeline cells/sec | CPU pipeline cells/sec | Speedup | Winner |
|---|---|---|---|---|---|
| 256² | 5000 | ~230M | ~922M | 0.25× | CPU (GPU init ~1.3s dominates) |
| 512² | 5000 | ~838M | ~323M | 2.6× | GPU |
| 1024² | 1000 | ~1,210M | ~297M | 4.1× | GPU |

### Step-Only Throughput

| Resolution | GPU step cells/sec | CPU step cells/sec | Speedup |
|---|---|---|---|
| 256² | ~2,700M | ~922M | 2.9× |
| 512² | ~4,090M | ~323M | 12.7× |
| 1024² | ~4,200M | ~299M | 14.0× |

### CPU Hashes (periodic, uniform f/k)
- 256²/500: `9760dfcdb5f49c3bd738ab33afee8be84e56aa31fd2f389cde25faaaeb19bb95`
- 256²/5000: `bdee302bbec5237a232c58019c3550395ddcc8f4d909a6a4df32e972dadd8865`
- 512²/500: `1db5da6286057b4cd653d8f8e952b5009682b30c70d36ee7e2af9125ae884d5a`
- 512²/5000: `1c978c1f00dab1716a60ad53370e2c34f529f4bf6c283c7cb62601726abc493d`
- 1024²/100: `54ebacb5b6c159510f013fa6baa6e7f07132b98d56490366c1289a2a75d737fa`

**Verdict**: GPU step-only throughput dominates CPU at all scales (3–14×). Pipeline (total time) favors GPU at 512²+; at 256² the wgpu-native driver/instance init (~1.3s) overshadows computation. For multi-step simulation maps, GPU provides dramatic advantage.
