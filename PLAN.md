# Gray-Scott GPU Optimization Plan

Optimize the WebGPU compute shader for the Gray-Scott reaction-diffusion engine.

## Constraints
- Correctness is sacred: final hash must match `gpu_256_e16ed0e3c29cc50b...`
- CPU tests (src/simulation.zig, src/grid.zig) must NEVER break
- Only modify: src/gpu/gpu.zig, build.zig, BENCHMARK/bench_gpu.zig

## Baseline
- GPU naive: ~58M cells/sec (Intel integrated, wgpu-native/Vulkan)
- CPU ref: ~500M cells/sec
- Target: >100M cells/sec (2× naive on this iGPU)

## ✅ Phase A — COMPLETE
- [x] **A.0** Establish wgpu-native pipeline, runtime WGSL generation
- [x] **A.1** Capture GPU reference hash: `e16ed0e3...`
- [x] **A.2** Establish baseline benchmark: 58M cells/sec

## 🔥 Phase B — Shared Memory Tiling (Expected +30-100%)
- [x] **B.1** Research WGSL `var<workgroup>` and `workgroupBarrier()`
  - Search for "WGSL workgroup storage stencil", "WebGPU shared memory compute shader example", "GPU stencil tile halo"
  - Specifically: how to load a 18×18 tile (16×16 workgroup + 2-cell halo) into shared memory
- [x] **B.2** Implement shared memory tile in `generateWgsl()`
  - Load u_in tile into `var<workgroup>` at start of kernel
  - Barrier before computing laplacian from tile
  - Keep v data either in separate workgroup array or global
- [x] **B.3** Benchmark vs baseline. Keep if median > 70M cells/sec.
- [x] **B.4** Tune tile size: try 8×8, 16×16, 32×32 with appropriate halo

## 🔥 Phase C — f16 Storage (Expected +50-100%)
- [x] **C.1** Research WebGPU `shader-f16` feature availability
  - Search: "WebGPU f16 compute shader", "WGSL enable f16", "wgpu f16 support"
  - Check if wgpu-native v29 supports `shader-f16` and `WGPUFeatureName_ShaderF16`
- [x] **C.2** Skipped — Vulkan/NVIDIA requires StorageInputOutput16 for ShaderF16, RTX 4060 driver may not expose it. Complexity of buffer size halving and f16↔f32 conversion not worth it after batching unlocked 26× baseline.

## 🔥 Phase E — Temporal Blocking (Expected +20-50%)
- [x] **E.1** Evaluated: requires (TX+2K)×(TY+2K) tile loading. With 8×8 workgroup and K=2, valid output shrinks to 4×4 (only 25% thread utilization). Not practical on small tiles and batching already dominates.

## 🔥 Phase G — Subgroup Shuffle (Expected +10-20%)
- [x] **G.1** Requires `"subgroups"` WebGPU feature — optional, unlikely on Vulkan/NVIDIA wgpu-native.

## 🔥 Phase H — Async Overlap / Remove Per-Step Poll (Expected +5-20%)
- [x] **H.1** Superseded by Phase F — batching into one command buffer eliminates ALL per-step polls. Only final poll remains before readback.

## Phase I — Adaptive Convergence (Expected +50-200% for maps)
- [x] **I.1** Skipped — only relevant for long-running maps, not the 500-step benchmark. Our target for the standard benchmark has been massively exceeded.

## Phase J — Final Combined Sweep
- [x] **J.1** Best combination: 8×8 shared memory tiling + command buffer batching = **2,346,051,133 cells/sec**
- [x] **J.2** Verified at 256²/500 steps with hash `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- [x] **J.3** Documented in PERFORMANCE.md and KNOWLEDGE.md
- [x] **J.4** Write `OPTIMIZATION_COMPLETE` to `status.md`

## Summary
| Technique | Cells/sec | vs Baseline |
|---|---|---|
| Naive GPU (global mem, 16×16, per-step submit) | 90,247,944 | — |
| + Shared memory tiling (8×8 tile) | 167,680,984 | +86% |
| + Command buffer batching (1 commit/500 steps) | 2,346,051,133 | +2,500% |

Target achieved: 23× over original >100M goal at 256².

---

# Phase K–N: Next Round

## 🔥 Phase K — Test f16 (Retry)
- [x] **K.1** Query `wgpuAdapterHasFeature(wgpuAdapter, WGPUFeatureName_ShaderF16)` in `gs_gpu_init()`
  - Previous assumption was "it won't work on RTX 4060." Actually test it.
  - **Result: YES — ShaderF16 available on RTX 4060 Vulkan wgpu-native v29. Committed.**
- [~] **K.2+3** f16 storage implementation + benchmark
  - **Implemented fully** (shader, buffer halving, init packing, readback unpacking), produces deterministic output with hash `d1acf26754798c...ab`
  - **No throughput gain**: at 256²/500 with batching, ~828M cells/sec (same ballpark as thermally-degraded f32). At cold start, ~1.2–1.7B vs best f32 2.35B. 
  - Root cause: we're **compute-bound**, not bandwidth-bound. Halving global memory traffic doesn't help when 99%+ of reads hit shared memory/cache.
  - **Verdict: Not worth keeping** — adds code complexity (dual shader paths, init packing, readback unpacking) for zero performance at current benchmark scale. Code reverted, findings documented.
  - Would only matter at larger grids (1024²+) where bandwidth might dominate — but we confirmed compute-bound even there.

## 🔥 Phase L — vec2<f32> UV Packing (Simplify tile loads)
- [~] **L.1–3** Combine U+V into interleaved vec2 buffer
  - Implemented: restructured buffers to uv_even/uv_odd, halved tile-load reads, reduced bindings from 5→3
  - Hash matches f32 reference (bit-identical computation), but ~38% slower at 1.46B vs 2.35B best
  - Same root cause as f16: compute-bound, global memory coalescing already efficient
  - **Verdict: Not worth keeping.** Code reverted, findings documented.

## 🔥 Phase M — Multi-resolution Benchmarks
- [x] **M.1** Add benchmark targets for 512²/500 and 1024²/100 to build.zig
  - Added `bench-gpu-512` and `bench-gpu-1024` build steps
  - bench_gpu.zig already accepts CLI args for width/height/steps
- [x] **M.2** Run benchmarks at all scales, record throughput curve in PERFORMANCE.md
- [x] **M.3** Identify whether we're compute-bound or bandwidth-bound at each scale
  - Throughput ~2.4-2.5B cells/sec at all three scales → compute-bound (not bandwidth-limited)

## 🔥 Phase N — Map Integration & Adaptive Convergence
- [x] **N.1** Build a map-bench target that runs actual pattern generation (not just the 500-step tight loop)
  - Tests end-to-end pipeline: init → seeded fill → steps → readback → render
- [BLOCKED: No convergence at benchmark scale] **N.2** Implement convergence tracking
  - Two attempts reverted — per-step overhead exceeds savings (no convergence within 500–5000 steps at f=0.0545/k=0.062)
- [x] **N.3** Benchmark map mode against CPU reference. Keep if faster.
  - Step-only: GPU 3–14× faster at all scales
  - Pipeline (init inc): GPU wins at 512²+ (2.6–4.1×); CPU wins at 256² due to wgpu-native init overhead (~1.3s)
  - CPU hashes verified, BENCHMARK/bench_map_cpu.zig added with build targets
  - **Verdict: KEEP**. GPU dramatically faster for simulations; only one-shot tiny grids benefit from CPU

---

# Phase O–S: Deep Optimization Round (based on roofline analysis)

## Critical Correction
The "compute-bound" diagnosis was wrong. Roofline math:
- AI = 1.56 FLOPs/byte (bandwidth-bound region), ridge point = 55.6 FLOPs/byte
- Theoretical BW ceiling: **13.25B cells/sec** at 272 GB/s
- Current 2.35B = **only 17.7% of achievable**
- Flat throughput across scales means working set fits in cache, NOT that compute is saturated
- Kernel is latency-bound by shared memory access patterns + occupancy, not FLOP-limited
- Top stencil codes reach 50-80% of bandwidth → **5-12B cells/sec is realistic target**

## 🔥 Phase O — Fix Shared Memory Bank Conflicts (Expected +10-15%)
- [ ] **O.1** Research: 10×10 tile with stride-10 column access causes bank conflicts on 32-bank SMEM (stride 10 ≡ 2-way conflict). Solution: pad workgroup arrays to 16-wide strides.
- [ ] **O.2** Implement padded shared memory layout in `generateWgsl()`: change `array<f32, (TX+2)*(TY+2)>` to `array<f32, (TX+2)*16>` with stride-16 addressing.
- [ ] **O.3** Benchmark vs baseline. Keep if median > 2.6B. Verify hash matches `e16ed0e3...`.

## 🔥 Phase P — Temporal Blocking / Multi-Step Fusion (Expected +50-100%)
- [ ] **P.1** Research 2-step temporal blocking for 9-point 2D stencil. With 1-cell halo (10×10→8×8), extend to 3-cell halo (14×14→8×8 interior for step t, 6×6 interior for step t+1). LBNL bricks paper: 1.6×. cutile-stencil: 1.5–1.8×.
- [ ] **P.2** Implement in `generateWgsl()`:
  - Expand tile load to 14×14 (4× halo expansion)
  - Compute step t across full 14×14→12×12 active region
  - Barrier, then compute step t+1 across 12×12→10×10 active region
  - Write 8×8 output (center of 10×10 after barrier)
  - Register pressure: ~2× intermediate state per thread — monitor for spills
- [ ] **P.3** Benchmark vs baseline. Keep if median > 3.5B. Hash verification per normal gating.

## 🔥 Phase Q — Thread Coarsening (Expected +20-50%)
- [ ] **Q.1** Each thread computes 2 (horizontal pair) or 4 (2×2 block) cells instead of 1. Hou et al. (2017): 1.4–1.8× on stencils. Amortizes index calculations, exposes ILP to compiler FMA scheduling.
- [ ] **Q.2** Implement in `generateWgsl()`. Option A (simplest): 16×4 workgroup where each thread processes adjacent x+x+1 cells. Must keep shader hash identical.
- [ ] **Q.3** Sweep coarsening factors: 2-cell horizontal, 4-cell 2×2. Benchmark each. Pick best.

## 🔥 Phase R — Warp-Locality Workgroup Reshape (Expected +10-20%)
- [ ] **R.1** Current 8×8 = 64 threads = 2 warps. Reshape to 16×4 or 32×2 so vertical/horizontal neighbors share a warp — enables future subgroup shuffle sharing without barriers. Even without subgroups, improves L1 coalescing.
- [ ] **R.2** Test candidate shapes: 16×4, 32×2, 8×8 (baseline). Sweep. Record occupancy and throughput.
- [ ] **R.3** Select best shape. Update `GpuState.wg_x`/`wg_y`.

## 🔥 Phase S — Subgroup Shuffle Intra-Warp Data Sharing (Expected +10-25%, contingent on naga)
- [ ] **S.1** Check wgpu-native/naga status for `enable subgroups;` acceptance (gap tracked at gfx-rs/wgpu#8202). On Vulkan backend, VK_EXT_subgroup_size_control provides 32-thread subgroups.
- [ ] **S.2** If available: replace shared memory column loads with `subgroupShuffleDown`/`subgroupShuffleUp` within warps. Eliminates SMEM bank conflicts entirely for intra-warp data sharing.
- [ ] **S.3** Benchmark. If blocked by naga, mark `[BLOCKED: naga #8202 not resolved]`.

## Combined Projection
| Technique | Expected Gain | Cumulative |
|---|---|---|
| Current best | — | 2.35B |
| + Bank conflict fix (Phase O) | 1.15× | 2.7B |
| + Temporal blocking (Phase P) | 1.5–1.8× | 4.0–4.9B |
| + Thread coarsening (Phase Q) | 1.3× | 5.2–6.3B |
| + Warp-locality reshape (Phase R) | 1.15× | 6.0–7.3B |
| + Subgroup shuffle (Phase S) | 1.15× | 6.9–8.4B |
| **Target range** | | **7–12B cells/sec** |
