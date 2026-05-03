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
- [ ] **B.4** Tune tile size: try 8×8, 16×16, 32×32 with appropriate halo

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
- [ ] **J.4** Write `OPTIMIZATION_COMPLETE` to `status.md`

## Summary
| Technique | Cells/sec | vs Baseline |
|---|---|---|
| Naive GPU (global mem, 16×16, per-step submit) | 90,247,944 | — |
| + Shared memory tiling (8×8 tile) | 167,680,984 | +86% |
| + Command buffer batching (1 commit/500 steps) | 2,346,051,133 | +2,500% |

Target achieved: 23× over original >100M goal at 256².
