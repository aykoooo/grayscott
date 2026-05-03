# GPU Optimization Results

Persistent benchmark tracker. This file survives crashes and restarts.

## Baseline (restored wgpu-native v29)

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | Naive GPU (9-point stencil, global mem) | 90,247,944 | — | ✅ Baseline |

## Reference
- GPU hash (256²/500 steps): `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- CPU hash: `9760dfcdb5f49c3bd738ab33afee8be84e56aa31fd2f389cde25faaaeb19bb95`
- Target: >100M cells/sec (2× naive on this Intel iGPU)

Current best: **2,346,051,133 cells/sec** (8×8 tiling + command buffer batching, +2,500% over baseline)

## Results Log

<!-- Agent appends new entries here after each task -->

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | Shared memory tiling (16×16 tile, 18×18 load) | 152,854,072 | +69.4% | ✅ Kept |
| 2026-05-03 | Shared memory tiling (8×8 workgroup, 10×10 tile) | 167,680,984 | +85.8% | ✅ Best (tiling) |
| 2026-05-03 | + Command buffer batching (500 dispatches in 1 submit) | 2,346,051,133 | +2,500% | ✅ Current Best |

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
| 2026-05-03 | f16 storage (K.2) | N/A | N/A | ❌ Reverted — precision drift, hash mismatch |
| 2026-05-03 | vec2<f32> UV packing (L.1) | 1,463,870,088 | -38% | ❌ Reverted — slower |

## Phase M: Multi-resolution Benchmarks
| Resolution | Steps | Cells/sec | Notes |
|---|---|---|---|
| 256² | 500 | ~2.4B | Timer noise (~14ms), compute-bound |
| 512² | 500 | ~2.55B | Stable, compute-bound |
| 1024² | 100 | ~2.38B | Stable, compute-bound |

**Finding**: Throughput constant across scales → **compute-bound**, not bandwidth-limited.
