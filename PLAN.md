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
- [ ] **B.1** Research WGSL `var<workgroup>` and `workgroupBarrier()`
  - Search for "WGSL workgroup storage stencil", "WebGPU shared memory compute shader example", "GPU stencil tile halo"
  - Specifically: how to load a 18×18 tile (16×16 workgroup + 2-cell halo) into shared memory
- [ ] **B.2** Implement shared memory tile in `generateWgsl()`
  - Load u_in tile into `var<workgroup>` at start of kernel
  - Barrier before computing laplacian from tile
  - Keep v data either in separate workgroup array or global
- [ ] **B.3** Benchmark vs baseline. Keep if median > 70M cells/sec.
- [ ] **B.4** Tune tile size: try 8×8, 16×16, 32×32 with appropriate halo

## 🔥 Phase C — f16 Storage (Expected +50-100%)
- [ ] **C.1** Research WebGPU `shader-f16` feature availability
  - Search: "WebGPU f16 compute shader", "WGSL enable f16", "wgpu f16 support"
  - Check if wgpu-native v29 supports `shader-f16` and `WGPUFeatureName_ShaderF16`
- [ ] **C.2** Query device for f16 feature in `gs_gpu_init()`
  - If supported, create f16 buffers (half the bytes)
- [ ] **C.3** Generate f16 shader variant in `generateWgsl()`
  - `enable f16;` at top
  - Storage buffers: `array<f16>` or `array<vec2<f16>>` for UV packing
  - Compute in f32, store back as f16
- [ ] **C.4** Benchmark. Keep if >100M cells/sec.

## 🔥 Phase D — Workgroup Size Sweep (Expected +10-30%)
- [ ] **D.1** Systematically test ALL workgroup sizes:
  - 2D: `8x8` | `16x16` | `32x4` | `16x8` | `8x16` | `32x8` | `64x2` | `32x32`
  - 1D: `64x1` | `128x1` | `256x1` | `512x1`
- [ ] **D.2** For each, run 3 benchmarks, take median, record in PERFORMANCE.md
- [ ] **D.3** Pick the fastest and commit with results table

## 🔥 Phase E — Temporal Blocking (Expected +20-50%)
- [ ] **E.1** Research temporal blocking for stencil loops on GPUs
  - Search: "temporal blocking GPU stencil", "time skewing stencil GPU", "K-step temporal blocking WebGPU"
- [ ] **E.2** Implement K=2 blocking in shader:
  - Load tile into workgroup memory
  - Compute step 1 using tile
  - Update tile in-place (double-buffer within shared mem)
  - Compute step 2
  - Write final result to global memory
  - Halves memory bandwidth for K=2
- [ ] **E.3** Try K=4 if K=2 works. Watch for shared memory limits (crash → revert).
- [ ] **E.4** Benchmark. Keep if >100M cells/sec.

## 🔥 Phase F — Command Buffer Batching (Expected +5-15%)
- [ ] **F.1** Research: each `wgpuQueueSubmit` has ~20-50μs overhead
  - Currently we do 500 submits (one per step). Try batching 8-16 steps per submit.
- [ ] **F.2** Modify `gs_gpu_step()` or add `gs_gpu_steps(N)`:
  - Record N compute dispatches into ONE command encoder
  - Submit once
  - Only poll once
- [ ] **F.3** Benchmark. Keep if any improvement.

## 🔥 Phase G — Subgroup Shuffle (Expected +10-20%)
- [ ] **G.1** Research WGSL `subgroupShuffle`, `subgroupShuffleDown`, `subgroupShuffleUp`
  - Requires `"subgroups"` WebGPU feature
  - Enables horizontal neighbor sharing without shared memory
- [ ] **G.2** Check if wgpu-native exposes subgroups
  - May need `WGPUFeatureName_Subgroups` query
- [ ] **G.3** Implement subgroup-based horizontal neighbor loading
- [ ] **G.4** Benchmark. Keep if improvement.

## 🔥 Phase H — Async Overlap / Remove Per-Step Poll (Expected +5-20%)
- [ ] **H.1** Current `gs_gpu_step()` calls `wgpuDevicePoll` every step
  - This blocks CPU until GPU finishes each step
  - For benchmarking, try recording ALL steps into one command buffer, submit once
  - Only poll at the very end before readback
- [ ] **H.2** This is mainly a benchmark harness change, but may expose race conditions
- [ ] **H.3** Benchmark. Compare fairly — if the hash still matches.

## Phase I — Adaptive Convergence (Expected +50-200% for maps)
- [ ] **I.1** Research: skip converged tiles where `|Δu| < epsilon`
- [ ] **I.2** Implement per-tile convergence tracking via second compute pass
- [ ] **I.3** Only relevant for long-running maps, not the 500-step benchmark

## Phase J — Final Combined Sweep
- [ ] **J.1** Combine best techniques from above phases
- [ ] **J.2** Run large-scale benchmark at 512² and 1024²
- [ ] **J.3** Document final results in PERFORMANCE.md and KNOLWEDGE.md
- [ ] **J.4** Write `OPTIMIZATION_COMPLETE` to `status.md`
