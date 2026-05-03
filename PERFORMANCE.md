# GPU Optimization Results

Persistent benchmark tracker. This file survives crashes and restarts.

## Baseline (restored wgpu-native v29)

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2026-05-03 | Naive GPU (9-point stencil, global mem) | 90,247,944 | — | ✅ Baseline |

## Reference
- GPU hash (256²/500 steps): `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- GPU f16 hash (256²/500 steps): `d1acf26754798c4eeb65fb0b0665cf8e197609caafbed2389bdd2ee6adea6bab`
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
| 2026-05-03 | f16 storage (K.2 — fully implemented, verified deterministic) | ~1.2B–1.7B | ~0% | ❌ Reverted — no bandwidth bottleneck. f32→f16 conversions add ALU overhead, memory savings invisible at compute-bound scale. Separate hash: `d1acf267...ab` |
| 2026-05-03 | vec2<f32> UV packing (L.1) | 1,463,870,088 | -38% | ❌ Reverted — slower |

## Phase M: Multi-resolution Benchmarks
| Resolution | Steps | Cells/sec | Notes |
|---|---|---|---|
| 256² | 500 | ~2.4B | Timer noise (~14ms), compute-bound |
| 512² | 500 | ~2.55B | Stable, compute-bound |
| 1024² | 100 | ~2.38B | Stable, compute-bound |

**Finding**: Throughput constant across scales → **compute-bound**, not bandwidth-limited.

## Phase N.1: Map-Bench — End-to-End Pipeline Benchmark

| Resolution | Steps | Step cells/sec | Pipeline cells/sec | Init ms | Step ms | Readback ms |
|---|---|---|---|---|---|---|
| 256² | 5000 | ~2.70B | ~230M | 1302 | 122 | 1.1 |
| 512² | 5000 | ~4.09B | ~838M | 1243 | 320 | 0.7 |
| 1024² | 1000 | ~4.20B | ~1.21B | 613 | 250 | 1.9 |

**Hashes** (end-to-end pipeline, uniform f/k, periodic boundaries):
- 256²/5000 steps: `df07ec44f702a7e63df3aa2ad24567d820dbfed3df20d435312cdaa66f455380`
- 512²/5000 steps: `b845273374ce78941247a631e0304bf0fb480dcc8b712dc304e8cc07b105dab9`
- 1024²/1000 steps: `40b0266b58271864e5c6d5eed6b8dd2747a0767cbdb7f8e90f431f32021c4abc`

**Key findings**:
- Init is dominant cost at small resolutions (91% of total at 256²), amortizes at larger grids (71% at 1024²)
- Step-only throughput ~matches existing bench-gpu results (2.7–4.2B cells/sec)
- Readback cost is negligible (<2ms at all scales)
- **Build step**: `zig build bench-map` (default 256²/5000), `bench-map-512`, `bench-map-1024`
