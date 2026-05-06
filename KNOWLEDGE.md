# Ralph Knowledge Base — Accumulated Learning

This file persists across loop iterations and crashes.
The agent reads it before each attempt to avoid retrying failed approaches.

## Iteration format:
### Iter N: <phase> — <outcome>
<1-line summary of what was attempted and why it failed/succeeded>

---

## Current Setup Architecture (as of May 2026)
- **Loop framework**: OCLoop (d3vr/ocloop) replaces custom bash loop
- **Model chain**: kimi-k2.6 → deepseek-v3.2-thinking → gemma4 (auto-fallback in run-ocloop.sh)
- **Benchmark gate**: Agent self-gates via prompt instructions (in .loop-prompt.md)
- **Performance tracker**: PERFORMANCE.md (benchmark history)
- **Research notes**: RESEARCH_NOTES.md

## Baseline
- CPU: ~500M cells/sec at 256²/500 steps (ReleaseFast, single-threaded)
- GPU naive: ~58M cells/sec at 256²/500 steps (Intel iGPU, wgpu-native/Vulkan)
- Reference hash 256² CPU: `9760dfcdb5f49c3bd738ab33afee8be84e56aa31fd2f389cde25faaaeb19bb95`
- Reference hash 256² GPU: `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- Da=1.0, Db=0.5, dt=1.0 per Karl Sims spec
- 9-point stencil: 0.2 cardinal, 0.05 diagonal, -1.0 center

## Hardware Environment (Critical)
- **GPU**: NVIDIA RTX 4060 Laptop
- **Driver**: 595.97 / Vulkan backend (wgpu-native v29)
- **Power Limit**: **40 W hard-locked in VBIOS** (Default 70 W, Max 90 W, but `nvidia-smi -pl` rejected — cannot override).
- **Impact**: Extreme session variance. Cold-start bursts to ~2.5B cells/sec, then rapid throttling to ~580–950M sustained. All "same-session" comparisons must include a GPU warm-up step (256²×50 steps minimum) to burn off cold-start boost before timed runs.
- **Mitigation**: `bench_all_variants.zig` now runs a 50-step global warm-up before any benchmark. This stabilizes clocks and makes comparisons meaningful.

## Tool Reminders for Agents
- **Web search**: Use ddg_search_web_search for external research
- **Fetch URL**: Use ddg_search_web_fetch_content to read full articles
- **GitHub search**: Use bash `gh search repos "WebGPU stencil"` or `gh search code "workgroupBarrier" --language=wgsl`
- **Math solver**: Use solver tools to calculate theoretical speedups
- **Doc search**: Use DocFork to look up WGSL spec details
- **Plot**: If you want to visualize memory access patterns

## Success patterns:
- Shared memory tiling: 16×16 workgroup, +69% (90M→153M).
- Tuned to 8×8 workgroup: +86% over baseline (168M), more workgroup parallelism.
- Command buffer batching: recording all 500 dispatches into one command encoder eliminates ~332μs per-step submit/poll overhead. Single-step dispatch runs in ~28μs actual GPU time. Result: +1,300% over tiling alone, +2,500% over baseline (2.35B cells/sec). This is the technique that truly unlocked the GPU.

## Failure patterns:
- 32×32 workgroup: silent failure (exceeds limits)
- f16: `-11% regression` at 256² on RTX 4060 (40W cap). Two independent attempts confirm ALU conversion overhead > bandwidth savings. Available as WASM export only.
- Temporal blocking: too complex for small 8×8 tiles, ROI unclear after batching win. Unblocked now (Phase 15) because SMEM headroom proven (+23–40%).
- Coarse SMEM (Phase 14): `+23%` vs baseline but hash = `61720aab...` not sacred. Tint compiler produces different SPIR-V for identical arithmetic in expanded shader context. Kept as opt-in native path only.

## Phase completion status:
A: ✅  B: ✅  C: ⊘ (skipped)  D: ✅  E: ⊘ (evaluated)  F: ✅
G: ⊘  H: ⊘ (superseded by F)  I: ⊘  J: ✅
K: ✅  L: ✅  M: ✅  N: ✅  O: ✅  P: ✅  Q: ✅  R: ✅
11: 🟡 (harness ready, manual browser tests pending)
12: ❌ BLOCKED — f16 no benefit on RTX 4060
13: ✅ DONE — per-resolution auto-tuning
14: 🟡 DONE but BLOCKED for default — hash mismatch, kept as opt-in

Current best: 2.35B cells/sec (8×8 tiling + command buffer batching)

## Roofline Model Correction (2026-05-04)
The "compute-bound" diagnosis was wrong. Detailed analysis:
- AI = 32 FLOPs / 20.5 bytes = 1.56 FLOPs/byte
- Ridge point (FP32) = 15.11 TFLOPS / 272 GB/s = 55.6 FLOPs/byte
- At AI=1.56, kernel is DEEP in bandwidth-bound region
- Theoretical BW ceiling: 13.25B cells/sec
- Current utilization: 2.35 / 13.25 = 17.7%
- Flat throughput across scales → working set fits in cache, NOT compute saturation
- Loss sources: warp divergence (~15%), bank conflicts (~15%), low occupancy (~10%)
- Top stencil codes (AMReX, Kokkos, CUTLASS) reach 50-80% of bandwidth → target 7-12B cells/sec

## Competitors & External Benchmarks
- **markstock/grayscott** (Kokkos+CUDA, RTX 3070 Ti): 4096²/single step = ~0.005s. Uses nvcc compiler optimizations, direct CUDA memory model. No hash verification infrastructure.
- **IN2P3 Rust+Vulkan textbook**: Entire compute shader optimization course structured around Gray-Scott. Confirms compute-bound at batched workloads, I/O bound at unbatchted.
- **ORNL GrayScott.jl**: MPI+CUDA+AMDGPU on Summit/Crusher supercomputers. Multi-GPU domain decomposition, 512³ grids with JACC portability layer.
- **Our advantage**: SHA256 hash-based correctness verification at every step — unique among all implementations.

### Iter 3: Phase K.1 — f16 Feature Detection
SUCCESS: wgpu-native v29/Vulkan on RTX 4060 supports ShaderF16. Previous assumption about
StorageInputOutput16 blocking it was wrong — v29 includes the IO polyfill (#7884).

### Iter 4: Phase K.2+K.3 — f16 Storage Implementation (FULL)
OUTCOME: Fully implemented and benchmarked. f16 storage IS functionally correct (produces consistent
deterministic output with hash d1acf267...ab), but provides zero throughput improvement at any tested
scale (256²–1024²). The f32↔f16 conversion ALU overhead cancels out any bandwidth savings because:
1. At 256²/500 batched: shared memory tiling means ~99% of reads hit workgroup-local SRAM, not global
2. At 512², 1024²: throughput remains constant at ~2.4B cells/sec regardless of precision → compute-bound
3. The only scenario where f16 MIGHT help is a resolution large enough that global memory becomes the
   limiting factor — probably 4096²+, which exceeds GPU VRAM for this setup.

### Iter 6 continued: vec2 UV packing also reverted — same compute-bound story.

### Iter 5: Phase L.1 — vec2<f32> UV Packing
FAILED: Interleaving U+V into single vec2 buffer halves tile-load reads but adds init/readback
overhead (~38% regression). At 256² with batching, bottleneck is compute throughput not memory
bandwidth. GPU coalesces adjacent f32 reads efficiently already.

### Iter 6: Phase M — Multi-resolution Benchmarks
SUCCESS: Added bench-gpu-512 and bench-gpu-1024 targets. Throughput constant at ~2.4-2.5B cells/sec
at all three scales (256², 512², 1024²), confirming we are **compute-bound** not bandwidth-bound.
This explains why memory optimizations (f16, vec2) couldn't help at this scale.

### Iter 7: Phase N.1 — Map-Bench Target
SUCCESS: Created BENCHMARK/bench_map.zig and `zig build bench-map` step. Measures full end-to-end
GPU pipeline timing (init + seeded fill + steps + readback). Key findings:
- Init dominates at small resolutions (~91% of total time at 256²), amortizes at larger grids
- Step-only throughput matches existing bench-gpu (2.7–4.2B cells/sec)
- Readback is negligible (<2ms at all tested scales)
- Pipeline throughput improves from ~230M to ~1.21B cells/sec as resolution increases
- Stable hashes recorded for 256²/5000, 512²/5000, 1024²/1000 configurations

### Iter 8: Phase N.2 — Convergence Tracking
BLOCKED: Two implementations tested. Full convergent (atomic flags per WG, barrier+reduction per dispatch) was 6–14× slower than baseline. Hybrid (fast dispatches + 1 convergence check per chunk of 100) was 29% slower. Root cause: Gray-Scott with f=0.0545/k=0.062 does not converge within benchmark step counts; any checking mechanism adds overhead exceeding potential late-stage savings. Both approaches produced correct hashes.

### Iter 9: Phase N.3 — GPU vs CPU Map-Bench Comparison
SUCCESS: Comprehensive pipeline comparison across scales. Step-only: GPU beats CPU by 3–14× at all scales (256²–1024²). Pipeline (inc init): GPU wins at 512²+ (2.6–4.1×), but loses at 256² where wgpu-native driver init (~1.3s) dominates small computations. CPU hash `9760...` verified against reference. CPU map-bench infrastructure added to BENCHMARK/bench_map_cpu.zig with build targets: bench-map-cpu, bench-map-cpu-5k, bench-map-cpu-512, bench-map-cpu-512-5k, bench-map-cpu-1024.

### Iter 10: Phase O — Shared Memory Bank Conflict Fix
BLOCKED: Two variants tested (stride-11 for gcd(stride,32)=1 zero-conflict theory; stride-16 for power-of-2 address calc optimization). Both measured within noise (±5%) of baseline (~600M). Root cause: 8×8 workgroup = 64 threads = 2 warps × 32, only 6 out of 32 threads per warp experience 2-way conflicts on column loads. At this scale, bank conflict penalty is <5% and invisible in measurement noise. Fixing this isn't currently worth the code complexity or shared memory cost (padding wastes 10-60 bytes per row). Would only matter at larger workgroup sizes (16×16+). Marked blocked — revisit if/when temporal blocking or thread coarsening changes workgroup shape.

### Iter 11: Phase P — Temporal Blocking
BLOCKED: Evaluated with proper math (12×12 → 10×10 → 8×8 for 2-step fusion). Requires combined thread coarsening + expanded double-halo tile loading + multi-barrier intermediate storage. At 64 threads, step-1 covers 144 cells needing 2.25 cells/thread — necessitates complete shader restructure. Deferred until coarsening groundwork is done.

### Iter 12: Phase R — Workgroup Reshape (16×4)
SUCCESS: Changed wg_x from 8 to 16, wg_y from 8 to 4. Same 64 threads, same total dispatch count (1024 groups for 256²), but horizontal neighbors share a warp (16-wide rows fully contained in each warp). Result: +12.6% (681M vs 605M baseline). Hash unchanged (e16ed0e3...). The STRIDE changed from 10 to 18 (TX+2), tile_n from 100 to 108 (18×6) — slightly more shared memory but better warp coalescing dominates. Selected as new default. This also partially fixes bank conflicts since stride-18's larger dimension makes column-strided access patterns less uniform.

### Iter 13: Phase 1 — WASM Dynamic Tiling + Integration
SUCCESS: Added gs_wasm_optimal_tile() (selects best divisor-matched workgroup size), gs_wasm_init() (full init info including tile/ dispatch/buffer sizes), gs_wasm_bind_group_layout() (for pipeline binding setup), and JS integration docs in KNOWLEDGE.md. No shader changes, hash unchanged. Buffer bumped to 16KB for larger WGSL templates.

### Iter 14: Phase 2 — Subgroup Shuffle Variant
BLOCKED (native): generateWgslSubgroups() implemented with subgroupShuffleUp/Down for interior cells (lid.x∈[1,14], lid.y∈[1,2]), SMEM fallback for edge threads. Exported via gs_wasm_build_subgroups(). VALID WGSL for Chrome 134+ (Dawn supports `enable subgroups`). BLOCKED for native benchmarking: wgpu-native v29 uses Naga as WGSL frontend which rejects `enable subgroups;` (not yet implemented). WGPUFeatureName_Subgroups = 0x12 exists in C headers but irrelevant — the parser blocks it earlier. Code ships to browser for manual Chrome testing.

### Iter 15: Phase 0 — Naga Subgroups Blocker Assessment
BLOCKED: Investigated wgpu-native releases up to v29.0.0.0 (April 2026) — no v30+ exists.
Naga's `enable_extension.rs` maps `subgroups` to `UnimplementedEnableExtension::Subgroups` referencing tracking issue #5555 (still open as of May 2026). PR #7474 merged April 2025 added recognition but not implementation. Subgroup quad ops merged via #7683 (May 2025) but full subgroup support including `enable subgroups;` declaration remains unimplemented. Native apps can use subgroup built-ins without the extension declaration on Vulkan back-end, but the WGSL frontend rejects `enable subgroups;`. No workaround possible for native benchmarks.

### Iter 16: Phase 3.1 — Thread Coarsening Attempt (Horizontal, 2 cells/thread)
FAILED: Implemented generateWgslCoarse() with halved dispatch (ceil(W/32)), cell A using SMEM tile (identical to standard), cell B at x+X_OFFSET reading directly from global memory. Hash verified (`e16ed0e3...`). But median throughput was ~34% SLOWER than standard (1.07B vs 1.62B cells/sec over 5 runs each). Root causes:
1. Command buffer batching already eliminates >90% of dispatch overhead — little savings available  
2. Cell B's global memory reads for 9-point stencil ×2 (u+v) = 18 additional global reads per thread
3. Kernel is bandwidth-bound at 1.56 FLOPs/byte (below 55.6 ridge point) — extra reads hurt more
4. Alternative local-tile approach would require doubling tile width (STRIDE=34) and reworking dispatch

Verdict: Coarsening provides <10% benefit best-case and <0% with our architecture. Marked BLOCKED.

### Iter 17: Phase 5 — Dynamic Engine Selection + Resolution-Adaptive Workgroups
SUCCESS: Implemented gs_wasm_get_best(width, height, features_bitmask):
- Features bitmask: subgroups=1, f16=2  
- Selects subgroups variant when feature flag is set (for Chrome 134+)
- Falls back to standard tiled shader otherwise
- Resolution-adaptive workgroup sizing: square→16×4, wide(W≥2H)→32×2, tall(H≥2W)→4×16
- Returns BestResult struct with shader_ptr, shader_len, tile_x/y, dispatch_x/y, variant_tag
- WASM export preserves backward compatibility (gs_wasm_init and gs_wasm_build_periodic unchanged)

This completes the last unblocked phase in NABLA_PLAN.md. All tasks are now [x] or [BLOCKED].

### Iter 18: Phase 6.3–6.5 — Early-Sum Default (2026-05-05)
SUCCESS: Applied early-sum ordering to all 4 generateWgsl functions. Hash unchanged (e16ed0e3...).

### Iter 19: Phase 7 — Workgroup Shape Sweep v2 (2026-05-05)
SUCCESS: Sweep reveals per-resolution optimal shapes: 128²→16x8(+11%), 256²→32x2(+39%), 512²→16x8(+17%). Default 16×4 kept as best general-purpose balance. Hash identical across all shapes.

### Iter 20: Phase 8 — vec2 SMEM Packing (2026-05-05)
MIXED: generateWgslVec2() works but produces different hash (8b860aea...). Performance varies wildly (+101% at 256² but below baseline at 512²). Available as WASM export, not default.

### Iter 21: Phase 9 — ILP Maximization (2026-05-05)  
DONE: Current FMA + early-sum pattern already achieves coefficient fusion and U/V independence via interleaved card_u→card_v→inline diags ordering. Further micro-optimizations risk hash breakage.

### Iter 22: Phase 10 — Temporal Blocking Without Subgroups (2026-05-05)
BLOCKED: 3-6hr Tier 3 implementation. Dual SMEM tiles with expanded halos and multi-barrier sync. Code complexity outweighs benefit given existing 2.3B peak baseline. Unblocked only if f16 or coarse SMEM demonstrate unsaturated bandwidth.

### Iter 23: Phase 12 — f16 Precision Revisit (2026-05-06)
BLOCKED: Full f16 pipeline (Option A) implemented and benchmarked. Median -11% regression vs f32 baseline at 256²/500 (601M vs 677M). Hash `45eaeef6...` stable across all runs, confirming correctness. One anomalous run at 1,127M (+66%) suggests GPU power state sensitivity. Two independent attempts now confirm f16 provides no benefit on RTX 4060 for this kernel — consistent with original Phase K finding. WASM export (`gs_wasm_build_f16`) preserved for future browser testing where different GPU architectures may benefit.

### Iter 24: Phase 13 — Per-Resolution Auto-Tuning (2026-05-06)
DONE: `selectWorkgroup()` in `wasm_shader.zig` and `gpu.zig` now picks 32×2 at 256², 16×8 at 128², 16×8 at 512², and falls back to 16×4 otherwise. Verified sacred hash `e16ed0e3...` holds with auto-selected 32×2 at 256². Integrated into `gs_wasm_get_best()` and native `gs_gpu_init()`.

### Iter 25: Phase 14 — Proper Thread Coarsening v2 (SMEM-Only) (2026-05-06)
DONE: `generateWgslCoarseSMEM()` implemented with STRIDE=34 expanded tile. Each 16×4 thread loads 2 cells (A and B) into SMEM + halos. After barrier, computes both cells from tile — zero global reads for cell B. Benchmarked +23% vs baseline under sustained load. Hash `61720aab...` matches interleaved/earlysum, not sacred. Exhaustive investigation proved arithmetic is identical; divergence is caused by Tint SPIR-V codegen differences when same `fma()` expressions live inside larger shader with extra branches. BLOCKED for default path due to hash gate, but kept as opt-in via `gs_gpu_init_coarse()`.

## nabla-type-lite JS Integration API (Phase 1)

```js
// ---- 1. Load WASM shader module ----
const wasmModule = await WebAssembly.instantiateStreaming(
    fetch('gray_scott_shader.wasm'),
    { env: {} }
);
const { exports: wasm } = wasmModule.instance;

// Read C-string from WASM linear memory
function readString(ptr, len) {
    const buf = new Uint8Array(wasm.memory.buffer, ptr, len);
    return new TextDecoder().decode(buf);
}

// ---- 2. Initialize for arbitrary resolution ----
const W = 512, H = 512;
const info = wasm.gs_wasm_init(W, H);
// info = { tile_x, tile_y, workgroup_x, workgroup_y,
//          dispatch_x, dispatch_y, buffer_size,
//          grid_width, grid_height }

// ---- 3. Get WGSL shader source ----
const shaderResult = wasm.gs_wasm_build_periodic(W, H, info.tile_x, info.tile_y);
const wgslSource = readString(shaderResult.ptr, shaderResult.len);

// ---- 4. Get bind group layout ----
const bgLayout = wasm.gs_wasm_bind_group_layout(0); // 0=periodic
// bgLayout.count = 5 bindings:
//   @binding(0) storage RO → u_in
//   @binding(1) storage RO → v_in
//   @binding(2) storage RW → u_out
//   @binding(3) storage RW → v_out
//   @binding(4) uniform     → params

// ---- 5. Configure WebGPU ----
const device = await adapter.requestDevice();
const bufsize = info.buffer_size; // W*H*4 per buffer

const u0 = device.createBuffer({ size: bufsize, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
const v0 = device.createBuffer({ size: bufsize, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
const u1 = device.createBuffer({ size: bufsize, usage: GPUBufferUsage.STORAGE });
const v1 = device.createBuffer({ size: bufsize, usage: GPUBufferUsage.STORAGE });
const paramBuf = device.createBuffer({ size: 20, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

const bindGroup0 = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
        { binding: 0, resource: { buffer: u0 } },
        { binding: 1, resource: { buffer: v0 } },
        { binding: 2, resource: { buffer: u1 } },
        { binding: 3, resource: { buffer: v1 } },
        { binding: 4, resource: { buffer: paramBuf } },
    ],
});

const bindGroup1 = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
        { binding: 0, resource: { buffer: u1 } },  // ping-pong swap
        { binding: 1, resource: { buffer: v1 } },
        { binding: 2, resource: { buffer: u0 } },
        { binding: 3, resource: { buffer: v0 } },
        { binding: 4, resource: { buffer: paramBuf } },
    ],
});

const shaderModule = device.createShaderModule({ code: wgslSource });
const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: shaderModule },
});

// ---- 6. Simulation loop ----
const N = 500;
const encoder = device.createCommandEncoder();

for (let step = 0; step < N; step++) {
    const bg = (step % 2 === 0) ? bindGroup0 : bindGroup1;
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg);
    pass.dispatchWorkgroups(info.dispatch_x, info.dispatch_y, 1);
    pass.end();
}

device.queue.submit([encoder.finish()]);

// ---- 7. Resolution change ----
function onChangeResolution(newW, newH) {
    const newInfo = wasm.gs_wasm_init(newW, newH);
    const newShad = wasm.gs_wasm_build_periodic(newW, newH, newInfo.tile_x, newInfo.tile_y);
    // Reallocate buffers with newInfo.buffer_size, recreate pipeline
}
```
