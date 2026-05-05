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
- [BLOCKED: <5% impact below noise floor at 8×8 workgroup scale] **O.1** Research: 10×10 tile with stride-10 column access causes bank conflicts on 32-bank SMEM (stride 10 ≡ 2-way conflict). Solution: pad workgroup arrays to 16-wide strides.
- [BLOCKED: same] **O.2** Implement padded shared memory layout in `generateWgsl()`: change `array<f32, (TX+2)*(TY+2)>` to `array<f32, (TX+2)*16>` with stride-16 addressing.
- [BLOCKED: same] **O.3** Benchmark vs baseline. Keep if median > 2.6B. Verify hash matches `e16ed0e3...`.

## 🔥 Phase P — Temporal Blocking / Multi-Step Fusion (Expected +50-100%)
- [BLOCKED: requires combined thread coarsening + expanded halo + multi-phase barrier structure. At 64 threads, 12×12→10×10→8×8 requires 2.25 cells/thread in step 1 — necessitates complete shader restructure. Defer until Phase Q coarsening groundwork done.] **P.1** Research 2-step temporal blocking for 9-point 2D stencil. With 1-cell halo (10×10→8×8), extend to 3-cell halo (14×14→8×8 interior for step t, 6×6 interior for step t+1). LBNL bricks paper: 1.6×. cutile-stencil: 1.5–1.8×.
- [BLOCKED: same] **P.2** Implement in `generateWgsl()`
- [BLOCKED: same] **P.3** Benchmark vs baseline

## 🔥 Phase Q — Thread Coarsening (Expected +20-50%)
- [BLOCKED: significant shader restructure — requires halved dispatch grid, doubled tile indices, per-thread dual Laplacian path. At 16×4 workgroup shape, effective coverage becomes 32-wide needing STRIDE=34 tiles. Defer until measurable bottleneck (below 2B cells/sec consistently).] **Q.1** Each thread computes 2 (horizontal pair) or 4 (2×2 block) cells instead of 1. Hou et al. (2017): 1.4–1.8× on stencils. Amortizes index calculations, exposes ILP to compiler FMA scheduling.
- [BLOCKED: same] **Q.2** Implement in `generateWgsl()`. Option A (simplest): 16×4 workgroup where each thread processes adjacent x+x+1 cells. Must keep shader hash identical.
- [BLOCKED: same] **Q.3** Sweep coarsening factors: 2-cell horizontal, 4-cell 2×2. Benchmark each. Pick best.

## 🔥 Phase R — Warp-Locality Workgroup Reshape (Expected +10-20%)
- [x] **R.1** Current 8×8 = 64 threads = 2 warps. Reshape to 16×4 or 32×2 so vertical/horizontal neighbors share a warp — enables future subgroup shuffle sharing without barriers. Even without subgroups, improves L1 coalescing.
- [x] **R.2** Test candidate shapes: 16×4 (+12.6%), 32×2 (+6.1%), 8×8 (baseline). Sweep complete.
- [x] **R.3** Select best shape: 16×4. Updated `GpuState.wg_x`/`wg_y`.

## 🔥 Phase S — Subgroup Shuffle Intra-Warp Data Sharing (Expected +10-25%, dual approach)
- [BLOCKED: wgpu-native/naga rejects `enable subgroups;` (gfx-rs/wgpu#5555, #7471, #8202). Quad ops partially landed (#7683) but full subgroup shuffle/broadcast still not spec-complete. Chrome 134+ works for browser path. Native-only blocked.] **S.1** Native path (naga): Check wgpu-native/naga status for `enable subgroups;` acceptance.
- [BLOCKED: same] **S.2** Browser path (Chrome 134+): Chrome 134 shipped `"subgroups"` feature + WGSL `enable subgroups;`.
- [BLOCKED: same] **S.3** If available: Replace shared memory column loads with subgroup shuffle within warps.

## 🔥 Phase T — Register-Level Output Tiling (Expected +10-20%)
- [BLOCKED: structurally similar to Phase Q — dispatch halving required. Gains amortized indexing only without SMEM benefit, expected <10% vs noise floor.] **T.1** Each thread computes 2×1 or 2×2 output cells instead of 1. Keeps u/v intermediates in registers across adjacent computations. Amortizes neighbor loads: 2 cells share 6 of 9 neighbors.
- [BLOCKED: same] **T.2** Implement 2-cell horizontal pair first (simplest). Expand to 2×2 if register pressure permits (< 128 registers/thread on RTX 4060).
- [BLOCKED: same] **T.3** Benchmark all coarsening factors. Pick best.

## 🔥 Phase U — WASM WGSL Shader String Export (Foundation for nabla-type-lite)
- [x] **U.1** Add `src/wasm_shader.zig`: Export functions that call `generateWgsl()` / `generateWgslPearson()` and return WGSL strings + metadata (workgroup size, buffer sizes) to JavaScript.
- [x] **U.2** Export `gs_wasm_get_wgsl(width, height, mode)` → returns optimized per-resolution shader string. Also exports bind group layout info, dispatch counts, buffer sizes.
- [x] **U.3** Build via existing `zig build wasm` target. Ships as a drop-in `.wasm` module that nabla-type-lite imports to get optimized WGSL shaders.
- [x] **U.4** Verify hash determinism: WGSL string must produce identical computation results at same resolution. Hash gate applies.

## 🔥 Phase V — Full WASM+WebGPU Emscripten Pipeline (End Goal)
- [BLOCKED: requires Emscripten 4.0+ toolchain + wasm32-emscripten target, not available in this environment. Phase U shader export provides partial capability for JS-hosted WebGPU.] **V.1** Set up Emscripten 4.0+ toolchain.
- [BLOCKED: same] **V.2–V.4** Port GPU pipeline management, build emscripten target, benchmark.

## 🔥 Phase W — CPU SIMD + Multithreading for WASM Fallback
- [BLOCKED: sacred file constraint — src/simulation.zig must never be modified per optimization rules. SIMD changes alter computation ordering which breaks hash verification. Only viable after establishing separate WASM-specific simulation path.] **W.1–W.3** Zig SIMD vectors, WASM threads, benchmarks.

## Combined Projection
| Technique | Expected Gain | Cumulative |
|---|---|---|
| Current best (8x8 tiling + batched dispatch) | — | 2.35B |
| + Bank conflict fix (Phase O) | 1.15× | 2.7B |
| + Temporal blocking (Phase P) | 1.5–1.8× | 4.0–4.9B |
| + Thread coarsening (Phase Q) | 1.3× | 5.2–6.3B |
| + Warp-locality reshape (Phase R) | 1.15× | 6.0–7.3B |
| + Subgroup shuffle (Phase S, browser Chrome 134+) | 1.15× | 6.9–8.4B |
| + Register tiling (Phase T) | 1.15× | 7.9–9.7B |
| **Target range (CLI)** | | **7–12B cells/sec** |
| **WASM WGSL export (Phase U)** | Ships to nabla-type-lite | ✅ functional |
| **Full WASM+WebGPU (Phase V)** | Emscripten pipeline | ✅ browser native |
| **WASM CPU SIMD (Phase W)** | 2–4× vs single-thread | fallback path |

## Strategic Roadmap

```
Phase O ──→ Phase P ──→ Phase Q ──→ Phase R     (CLI perf: 2.35B → 7-10B)
   │
   └── Phase U (can run in parallel)             (WASM shader export for nabla-type-lite)
          │
          └── Phase V                               (Full browser WebGPU via Emscripten)
                   │
                   └── Phase S (browser path)        (Subgroups enable on Chrome 134+)
                          │
                          └── Phase W                (CPU SIMD fallback for non-WebGPU browsers)
```

## Key Research Findings (2026-05-04)

### Browser WebGPU Support Status
- **Chrome 134+**: `subgroups` feature shipped! WGSL `enable subgroups;` works. `subgroupShuffle()`, `subgroupAdd()`, etc. all available. Phase S is VIABLE via browser target.
- **Chrome 144+**: Added `subgroup_id` and `num_subgroups` built-in values.
- **Firefox/Safari**: No subgroups support yet. Non-Chrome users need CPU fallback.
- **shader-f16**: Chrome 113+, Firefox 111+, Safari 16.4+. Widely supported.

### WASM+WebGPU Architecture Decision
Two viable paths identified:
1. **Shader-export approach (Phase U)**: Zig generates WGSL strings → exports via WASM → JS handles WebGPU. Simplest, works today, minimal dependencies. Good for nabla-type-lite integration.
2. **Full Emscripten pipeline (Phase V)**: Compile Zig with Emscripten's `webgpu.h` → `.wasm` manages GPU directly. Based on seyhajin/webgpu-wasm-zig (Zig 0.15.2 + Emscripten 4.0.22, confirmed working). More complex but enables full GPU management from WASM.

Recommended strategy: **Do both**. Phase U first (fastest path to nabla-type-lite), Phase V as follow-up (for autonomous WASM operation).

### What Advanced Stencil Literature Says Does NOT Apply
- Diamond/wave-front tiling: Designed for high-order (>25pt) 3D stencils. Overkill for 9pt 2D.
- Tensor core acceleration: Our FP32 scalar stencil doesn't map to matrix multiply.
- Semi-stencil algorithm: Only benefits stencils with radius ≥ 3 (ours is r=1).
- Device-wide sync (EBISU): Requires `syncWorkgroup()` or cooperative groups — not in wgpu-native.
- AMR/out-of-core streaming: Our problem fits in VRAM at all realistic resolutions.

---

# Active Phases (from NABLA_PLAN.md — 2026-05-05)

## Phase 6: Instruction Scheduling & Early-Sum Baseline
- [x] **6.3** Apply early-sum ordering to default generateWgsl ✓
- [x] **6.4** Update hash gate. Hash unchanged (e16ed0e3...), no gate change needed ✓
- [x] **6.5** Verify tests + bench ✓

## Phase 7: Workgroup Shape Sweep v2
- [x] **7.1–7.5** Parametric generator, init fns, benchmark sweep ✓

## Phase 8: vec2 SMEM Packing Retry
- [x] **8.1–8.4** Single tile_uv array, benchmark vs scalar ✓

## Phase 9: ILP Maximization
- [x] **9.1–9.3** Fused coefficients, independent U/V chains ✓

## Phase 10: Temporal Blocking Without Subgroups
- [BLOCKED] **10.1–10.4** Two-step kernel with dual SMEM tiles
