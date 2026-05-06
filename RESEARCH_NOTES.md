# Research Notes

Persistent research findings. The agent appends here after web research.

## WGSL Shared Memory Tile — TEMPLATE

When you research this topic, write:
```
### Date — Technique
- Source: <URL>
- Key finding: <1-2 sentences>
- Applicability: <yes/no and why>
```

## Baseline Architecture

- Pipeline: wgpu-native v29 (C API), not emscripten
- Shader: generated at runtime by `generateWgsl()` in `src/gpu/gpu.zig`
- Workgroup: `16x16 = 256` threads
- Grid: `width × height` global invocations, periodic boundaries via `select()`
- Buffers: 4 ping-pong (u0/u1, v0/v1) + 1 uniform (params) + 1 readback
- Step: write params uniform → begin compute pass → dispatch → submit → poll
- Readback: copy storage → MAP_READ buffer → map async → memcpy

## WGSL Quick Reference (for the agent)

Shared memory declaration:
```wgsl
var<workgroup> tile_u: array<f32, (TILE+2*HALO)*(TILE+2*HALO)>;
var<workgroup> tile_v: array<f32, (TILE+2*HALO)*(TILE+2*HALO)>;

@compute @workgroup_size(tile_x, tile_y)
fn main(@builtin(global_invocation_id) gid: vec3<u32>,
        @builtin(local_invocation_id) lid: vec3<u32>) {
    // Load global into shared
    tile_u[local_idx] = u_in[global_idx];
    workgroupBarrier();
    // Compute from tile
    // ...
}
```

f16 enable:
```wgsl
enable f16;
@group(0) @binding(0) var<storage, read> u_in: array<f16>;
// Cast: f32(u_in[idx]) for math, f16(result) for store
```

## Known Papers / References to Search

- Stock et al. "Kokkos Gray-Scott" — Kokkos CUDA, 4096² at 0.005s/step
- EBISU 2023 hexagonal tiling paper
- AN5D framework (auto-tuning stencil)
- PPoPP 2018 register optimization
- ShaderToy "Gray-Scott" examples (GLSL → WGSL)

## Known Issues

- Naga (wgpu shader compiler) rejects `ptr<storage>` as function parameter — laplacian must be inlined
- `wgpuInstanceWaitAny` panics in v29 as "not implemented" — use polling loop
- GPU f32 instruction ordering differs from CPU — hashes will NOT match
- `shader-f16` is optional in WebGPU — must query device features

## 2026-05-03 — WGSL Shared Memory Tiling for Stencil

- Source: Tour of WGSL (Google), François Guthmann blog, NVIDIA L2 locality post, Various WebGPU prefix sum examples
- Key finding: WGSL `var<workgroup>` declares zero-initialized workgroup-shared memory visible to all threads in a workgroup. Must use `workgroupBarrier()` for synchronization. For a 9-point stencil on a 16×16 workgroup, load an 18×18 tile (16 + 1-cell halo each side). Edge threads load halo: left-edge loads neighbor's right column, etc. Critical performance insight for Intel iGPUs: shared memory goes to SLM not registers when dynamically indexed — benefit may be modest (~10-30%) vs dedicated GPUs.
- Implementation approach: Declare arrays `tile_u: array<f32, 20*20>` and `tile_v: array<f32, 20*20>`, compute 1D local_idx = lid.y*(TILE_W+2) + lid.x, load main cell + edge threads load halo neighbors, barrier, then 9 reads from tile arrays instead of global buffers.

## 2026-05-03 — Phase N.1: Map-Bench End-to-End Benchmark

- Source: Gray-Scott with Rust tutorial (Vulkan), metal-by-example/metal-gray-scott, Codrops WebGPU reaction-diffusion article
- Key finding: All GPU Gray-Scott implementations show that end-to-end throughput (init + steps + readback) matters more than step-only throughput for real users. The Rust vulkano tutorial explicitly separates "update microbenchmark" from "full simulation throughput." A map-bench target should time the complete pipeline.
- Applicability: YES. Current bench_gpu.zig only times the stepping loop; realistic map generation needs init→seed→steps→readback→render timing. Use uniform params (GPU shader can't do non-uniform f/k yet). Multiple resolutions confirm compute-bound behavior persists.

## 2026-05-03 — Phase K: f16 Storage Full Experiment

- **Feature detection**: ShaderF16 IS available on RTX 4060 Vulkan/wgpu-native v29 (v29 IO polyfill fixed old StorageInputOutput16 blocker). Committed as `has_f16` flag in GpuState + `wgpuAdapterHasFeature()` call.
- **Implementation**: Full round-trip: enable f16 shader, array<f16> storage, f32()/f16() casts, Zig-side f32↔u16 packing/unpacking, half-size ping-pong buffers.
- **Hash**: Deterministic across runs: `d1acf26754798c4eeb65fb0b0665cf8e197609caafbed2389bdd2ee6adea6bab`
- **Throughput**: ~1.2–1.7B cells/sec at 256²/500 (cold start), vs f32 best of 2.35B. At thermally-degraded state: f16=828M, f32=759M (+9% advantage).
- **Root cause**: Compute-bound at all tested scales. Shared memory tiling makes global bandwidth savings invisible.
- **Verdict**: Reverted. Code complexity not justified by zero perf gain. Knowledge preserved for future larger-scale work.

## 2026-05-04 — Phase O: Shared Memory Bank Conflict Analysis

- Sources: apxml.com (shared memory banking), gpudemystified.com (padding fix)
- Key finding: Standard padding fix is stride → stride+1 (must be coprime with 32). For 8×8 workgroup with stride-10: gcd(10,32)=2 → 2-way conflicts on 6/32 threads per warp. striding to 11 (gcd=1) eliminates all conflicts theoretically, but measured impact <5% — below noise floor. striding to 16 (power-of-2 address calc) also tested — slightly worse.
- Verification: Hash `e16ed0e3...` matches across both variants. Per-thread bank mapping analyzed via manual GCD enumeration.
- Conclusion: At 8×8 workgroup scale, 2-way bank conflicts on only a fraction of warp threads are too mild to matter. Marked blocked. Revisit if temporal blocking or thread coarsening significantly changes workgroup shape.

## 2026-05-06 — Advanced Stencil Optimization Research (12 Topics)

### 1. Temporal Blocking / Time Tiling (Without Subgroups — Dual SMEM Buffers)

- **Sources**: Bonati et al. "Revisiting Temporal Blocking Stencil Optimizations" (ACM ICS 2023), arXiv:2305.07390; Stock & Grosser "Optimal Temporal Blocking for Stencil Computation"
- **Key finding**: Temporal blocking processes N consecutive time steps per global memory load by keeping intermediate results in fast memory (SMEM/registers). The core idea: load a larger tile with extra halo, compute step t, store intermediates in registers or second SMEM buffer, barrier, then compute step t+1 from those intermediates. Each fused step-pair saves ~1 complete global read/write cycle per cell. PiTCH tiling and wavefront diamond blocking are proven optimal forms. Recent work shows modern GPUs with large scratchpads + device-wide sync make this viable even without subgroups.
- **Applicability to our 2D 9-point stencil**: HIGH in theory. For a 2-step fusion: load (TX+4)×(TY+4) input tile (extra 2-cell halo for step 2 dependency), step 1 writes to dual SMEM arrays `tile_u_mid`/`tile_v_mid`, barrier, step 2 reads those for laplacian. Saves 50% of global reads. Cost: doubled SMEM usage (already 324 bytes/tile × 4 = 1296 → manageable), one extra barrier.
- **Expected gain**: 1.2–1.5× for 2-step, 1.5–1.8× for 3-step. But note: current bottleneck is SMEM *read* latency, not global bandwidth. Since temporal blocking replaces global reads with SMEM reads, it may not help if SMEM remains the limiter.
- **Difficulty**: High (Tier 3, 3-6 hours). Requires careful index math for expanded halo, dual-SMEM management, barrier discipline, and edge-case handling for non-multiple step counts.
- **Requires subgroups?** No. Pure SMEM variant works without subgroups. Project already has this marked as Phase 10 in NABLA_PLAN.md (currently BLOCKED due to complexity/payoff ratio).

### 2. Register-Level Output Tiling (Thread Coarsening — 2×1 or 2×2 Cells/Thread)

- **Sources**: ECE508 Illinois lecture slides (Lumetta), "Register Optimizations for Stencils on GPUs" (Inria HAL hal-01955542), "High-Performance Code Generation for Stencil Computations on GPU" (Pouchet et al.)
- **Key finding**: Thread coarsening makes each thread compute K cells sequentially, trading parallelism for reduced dispatch overhead, amortized index calculations, and register-level data reuse. For neighboring cells, shared SMEM data can be reused across multiple output computations within the same thread. The key insight: coarsened tiles stay in registers between computations, so a thread computing cell A then cell B can keep some laplacian intermediates live. Combined with register tiling (where computed output stays in registers until written), this gives both computational intensity gains and memory traffic reduction.
- **Applicability to our 2D 9-point stencil**: MEDIUM. Prior attempt (Phase 3.1, horizontal coarsening 2 cells/thread) caused -34% regression because cell B used global reads instead of SMEM. The RIGHT approach: compute both cells from the same SMEM tile WITHOUT additional global loads. For 2×1 (horizontal): thread processes (x,y) and (x+1,y). The second cell's neighbors overlap partially with first cell's, saving SMEM reads. For 2×2: processes a quad, sharing 12 neighbor reads among 4 cells instead of 32 reads if done separately (3.75× reuse factor). Risk: register pressure doubles (2× ≈ 20→45 registers still well under RTX 4060 limit of 255/thread).
- **Expected gain**: 1.15–1.35× for 2×1, potentially 1.3–1.5× for 2×2. Gains come from SMEM read reuse, not dispatch savings (command batching already eliminates that).
- **Difficulty**: Medium-High. Must rewrite tile loading to handle fractional halo, carefully manage register file without spills. Correct implementation must avoid any global reads in the coarsened path.
- **Requires subgroups?** No. Pure SMEM + register variant.

### 3. f16 Precision Throughout (Halving SMEM Traffic)

- **Sources**: GitHub gpuweb/gpuweb #2512 (FP16 WGSL extension proposal), NVIDIA CUDA best practices, project's own Phase K experiment
- **Key finding**: WGSL now supports f16 via `enable f16;` with `shader-f16` device feature. Modern GPUs have 2× f16 throughput for both ALU and SMEM (NVIDIA: f16 SMEM bandwidth = 128 bytes/cycle vs 64 bytes/cycle for f32 at Turing+, theoretically doubling effective SMEM bandwidth). On Vulkan, `shaderFloat16` has 39.6% support rate; on D3D12 requires SM6.2+. Built-in functions auto-overload for f16. However, project Phase K showed f16 storage gave 0% gain when bottleneck was compute (not bandwidth). Now that SMEM is confirmed bottleneck, the situation changes: f16 halves SMEM traffic per read (16 bits vs 32 bits), directly attacking the limiting factor.
- **Applicability to our 2D 9-point stencil**: HIGH — likely **best single optimization available**. Each laplacian reads 16 SMEM values (8 u + 8 v). At f32 = 512 bits. At f16 = 256 bits. On NVIDIA hardware, f16 SMEM has 2× throughput. Effective bandwidth gain should be ~1.7–1.9× assuming no new bottlenecks emerge. Reaction terms use fma which also runs at 2× rate in f16.
- **Expected gain**: 1.4–1.8× if SMEM bandwidth truly limits. Caveat: f16 range (max ~65504) adequate for Gray-Scott (values clamped to [0,1]; laplacian coefficients 0.05–0.2 won't overflow; dt*factors are small). Main risk: accumulation error over many steps may diverge visibly. Needs hash verification at 500+ steps.
- **Difficulty**: Low-Medium. Implementation straightforward: add `enable f16;` to shader, change array types to `f16`, casts go away since everything is f16-native. Storage side needs Zig-side f16↔f32 packing (already implemented in Phase K, just un-revert the packing code). Pipeline setup needs `shader-f16` feature request.
- **Requires subgroups?** No.

### 4. Pipeline Specialization Constants (@id() Override)

- **Sources**: WebGPU Fundamentals constants lesson, Toji.dev "Dynamic Shader Construction Best Practices", MDN GPUDevice.createComputePipeline(), Vulkan specialization constants docs
- **Key finding**: WGSL supports `override WIDTH: u32; @id(0) override HEIGHT: u32;` — pipeline-overridable constants set at `createComputePipeline` time via `constants: { 0: 256, "HEIGHT": 256 }`. Unlike module-scope `const` variables (which the compiler may treat as immediates anyway), pipeline overrides enable: (1) the driver/compiler to fold these into immediate operands at JIT time, eliminating uniform register usage; (2) dead-code elimination of branches gated on boolean overrides; (3) potential for the implementation to cache specialized pipeline variants. For compute shaders, constants are specified in the `compute:` stage descriptor.
- **Applicability to our 2D 9-point stencil**: LOW-MEDIUM benefit, VERY LOW cost. Currently WIDTH/HEIGHT are `const` values baked into the WGSL string via `bufPrint`. That's already optimal — they're compile-time constants visible to the compiler. Moving them to pipeline overrides would save no instructions (they're already immediates). The only theoretical benefit: reusing the same shader module for different resolutions without recompiling the WGSL string. But `bufPrint` takes <50μs, making this optimization unnecessary.
- **Expected gain**: ~0%. Already optimal. Could reduce shader-module cache churn if switching resolutions frequently, but that's not the use case (resolution is fixed per simulation).
- **Difficulty**: Trivial. Just change `const WIDTH` to `override WIDTH` and set via JS/WASM.
- **Requires subgroups?** No.

### 5. Wavefront / Warp-Level Neighbor Sharing Without Explicit Subgroup Ops

- **Sources**: NVIDIA "Using CUDA Warp-Level Primitives", Mojo GPU Puzzle #25, ROCm/HIP warp-level primitives documentation
- **Key finding**: On NVIDIA GPUs, a warp's 32 threads execute in lockstep. Two techniques exist WITHOUT subgroup intrinsics: (a) **Implicit warp-synchronous programming**: since threads within a warp proceed together, a value stored to SMEM by lane N and read by lane N+1 within the same instruction (no barrier needed within a warp) exploits the fact that all lanes execute the same instruction simultaneously. This is the pre-Volta "warp-synchronous" pattern. (b) **SMEM exchange patterns**: load neighbors' values from SMEM with offsets known at compile time (e.g., `tile[lid ± 1]`, `tile[lid ± stride]`). This doesn't need subgroups at all — it's just normal SMEM addressing. (c) **Explicit shuffle emulation via volatile SMEM**: on pre-Volta, storing to SMEM and reading back from neighbor lane without `__syncwarp()` worked because warps were strictly synchronous. Post-Volta (our RTX 4060 Ada Lovelace), threads within a warp can be independently scheduled, so implicit synchronization is UNSAFE and undefined behavior.
- **Applicability to our 2D 9-point stencil**: Technique (b) is what we already do — SMEM neighbor reads ARE warp-level sharing without subgroups. The 8 neighbor accesses are lane-relative (±1 col, ±stride row) within the same workgroup. This is maximally optimized already. Technique (a) is unsafe on RTX 4060 (independent thread scheduling). There is no "hidden" warp-level optimization beyond what our SMEM tiling already achieves.
- **Expected gain**: 0%. Current implementation is already optimal for non-subgroup warp sharing.
- **Difficulty**: N/A. Nothing to implement.
- **Requires subgroups?** No — that's the point. But the technique offers nothing beyond current SMEM tiling.

### 6. Multi-Pass Split Kernels (Laplacian Pass + Reaction Pass)

- **Source**: General GPU compute optimization principle, NVIDIA occupancy tuning guides
- **Key finding**: Splitting a register-heavy kernel into separate passes trades increased global memory traffic + barriers for reduced register pressure per pass, potentially increasing occupancy. In our case: Pass 1 computes Laplacian only (8 SMEM reads, ~12 registers for UV), writes intermediate `lap_u`,`lap_v`,`uvv` to global buffers. Pass 2 reads those 3 floats + reads params, computes reaction, writes final output. Total: +2 global writes +2 global reads per cell, saved: ~8 registers (reaction intermediates don't coexist with laplacian reads).
- **Applicability to our 2D 9-point stencil**: VERY LOW. Our register pressure is already comfortable (~22 regs/thread, far below 255 limit). Occupancy analysis shows 46 max concurrent WGs on 64K registers/SM — well above practical limits. The extra global memory traffic would more than offset any occupancy gains. This is an optimization for kernels with extreme register pressure (100+ regs/thread), not our lightweight stencil.
- **Expected gain**: Negative. Extra global traffic would hurt throughput.
- **Difficulty**: Medium. Requires intermediate buffer allocation, multi-pass encoding, careful barrier placement.
- **Requires subgroups?** No.

### 7. Async Compute Overlap (Separate Queues)

- **Sources**: NVIDIA "Advanced API Performance: Async Compute and Overlap" (Oct 2021), SitePoint "The WebGPU Concurrency Guide" (Feb 2026), GPUOpen "Leveraging Asynchronous Queues"
- **Key finding**: WebGPU provides three timeline concurrency model: Content (JS), Device (validation), Queue (GPU execution). `device.queue.submit()` can accept multiple command buffers in one call for independent workloads. Separate compute queues allow overlapping GPU work with copy operations. Key constraint: async workloads share the same GPU resources (SMs, caches, VRAM), so overlap only helps when the primary workload has low unit throughput (i.e., idle warp slots or unused datapaths). NVIDIA guidance: look for pairs where one workload has low SM occupancy AND low top-unit throughput. Avoid overlapping workloads that use the same resources (L1/L2 cache, VRAM bandwidth). For the browser context specifically: overlapping compute with readback (mapAsync) on separate timelines already happens naturally since mapAsync is async by design.
- **Applicability to our 2D 9-point stencil**: LOW for step computation itself (it's dense compute with near-100% SM utilization — no idle slots to fill). Potentially MODERATE for pipeline overlap: overlapped readback + next frame encoding could hide CPU-side overhead, but this is JS-tier optimization irrelevant to raw cell/sec throughput.
- **Expected gain**: 0% for step throughput. ~5-10% for end-to-end pipeline if JS overhead is significant.
- **Difficulty**: Medium (requires multi-queue management, fence synchronization).
- **Requires subgroups?** No.

### 8. Persistent Threads / Software-Managed Block Scheduling

- **Sources**: General GPU persistent threading literature (CUDA), NVIDIA Cooperative Groups documentation
- **Key finding**: Instead of launching N workgroups through the hardware scheduler, launch exactly (num_SMs × target_WGs_per_SM) workgroups that run forever in a loop, fetching work items from a global atomic counter. Advantages: eliminates kernel launch overhead (important for microsecond-scale dispatches), enables software-controlled work distribution. For stencils, each persistent block would: load its current tile region, process it, commit results, advance to next tile region via atomicAdd on a grid pointer. Requires device-wide synchronization (`workgroupBarrier` is only workgroup-scoped). On WebGPU, true device-wide sync is NOT available.
- **Applicability to our 2D 9-point stencil**: VERY LOW. Our dispatches are batch-submitted (500 steps in one submit), eliminating launch overhead already. Persistent threads require device-wide atomics (available in WebGPU storage buffers) but lack device-wide barriers (critical for correctness when overlapping tile regions). Without subgroups or device sync, this is impractical in WGSL/WebGPU.
- **Expected gain**: Negligible (launch overhead already batched away). Theoretical: +5% if dispatch overhead was measurable, which it isn't.
- **Difficulty**: Very High. Requires fundamental architecture rewrite, device-scope coordination mechanisms that don't exist in WebGPU.
- **Requires subgroups?** Not directly, but practically yes (needs cooperative groups for inter-workgroup communication).

### 9. Occupancy Tuning — Fewer Workgroups Per SM

- **Sources**: NVIDIA occupancy calculator methodology, general GPU occupancy vs. cache pressure tradeoffs
- **Key finding**: Contrary to conventional wisdom ("maximize occupancy"), fewer workgroups per SM can improve performance when kernels are cache-sensitive. With fewer concurrent workgroups: (1) more L1 cache per active workgroup (less eviction), (2) more registers per thread available, (3) reduced SMEM bank conflict pressure from concurrent access streams. The NVIDIA occupancy API reports theoretical occupancy, but real-world throughput often peaks at 25-50% theoretical occupancy for memory-bound kernels. For SMEM-tiled stency, the sweet spot is typically 4-8 WGs/SM.
- **Applicability to our 2D 9-point stencil**: MODERATE. Our current 16×4 workgroup (64 threads, ~22 regs/thread) = 1408 regs/WG. RTX 4060 Ada: 64K regs/SM, 100KB SMEM/SM. Can fit 65536/1408 ≈ 46 WGs by register count, but SMEM limits: 100KB/(324 bytes × 2 tiles) ≈ 154 WGs. Real limitation is warp-scheduler slots: Ada has 4 schedulers × maybe 8 warps/scheduler = 32 concurrent warps. At 64 threads/WG = 2 warps/WG, max 16 WGs/SM. We currently dispatch `ceil(W/16)×ceil(H/4)` workgroups — e.g., for 1024²: 64×256=16384 total WGs across 24 SMs = 682 WGs/SM. This massively exceeds physical capacity. Lower dispatch counts (by using larger workgroups like 16×8=128 threads = 4 warps/WG → max 8 WGs/SM) could reduce scheduler contention while maintaining enough work to hide latency. But Phase 7 sweep already tested shapes: 16×8 wins at 128² and 512², 32×2 wins at 256². The right "occupancy" is shape-dependent.
- **Expected gain**: Already explored via shape sweep (+10-39% depending on resolution). Further deliberate occupancy throttling unlikely to beat best shape.
- **Difficulty**: Low (just changes dispatch geometry). Already semi-implemented via shape options.
- **Requires subgroups?** No.

### 10. Browser-Side WASM Integration Improvements

- **Sources**: SitePoint WebGPU concurrency guide, project's own wasm_shader.zig architecture, Toji.dev WebGPU best practices
- **Key finding**: WASM integration bottlenecks in browser WebGPU are: (1) buffer creation/destruction per frame (should pre-allocate and reuse), (2) pipeline recreation on resolution change (cache shader modules, reuse pipelines when possible), (3) bind group recreation (pre-build layout-compatible groups), (4) JS→WASM→WGSL string passing overhead (keep WGSL in WASM linear memory, pass only pointer+length to JS), (5) GPU timing via timestamp queries for profiling. The project's `wasm_shader.zig` already exports compact metadata (gs_wasm_init returns all binding info in one struct), and WGSL is returned as {ptr,len} avoiding copy-out.
- **Applicability to our 2D 9-point stencil**: MODERATE for browser deployment, ZERO for native (this is purely integration-layer optimization). Key improvements: warm-up dispatches to force JIT compilation before benchmarking, double-buffered staging buffers for pipelined readback, timestamp query integration for browser-side profiling, WebGPU-to-Canvas direct rendering to skip readback entirely for visualization mode.
- **Expected gain**: 0% for native throughput. 1.3–2× for perceived responsiveness in browser (overlapping render+compute, avoiding pipeline stalls).
- **Difficulty**: Low-Medium. JavaScript-side changes, not Zig shader changes. Existing architecture already sound.
- **Requires subgroups?** No.

### 11. Hexagonal Tile Shapes for Non-Rectangular Stencils

- **Sources**: General stencil optimization literature (hexagonal/parallelogram tiling), EBISU 2023 hexagonal tiling paper (mentioned in prior research notes)
- **Key finding**: For stencils with specific neighbor dependencies, tilings shaped as hexagons or parallelograms can reduce redundant halo loading compared to rectangular tilings. The advantage comes from minimizing the boundary-to-interior ratio. For a 9-point 2D stencil, the halo is a uniform 1-cell border on all sides, so the optimal shape is determined by the aspect ratio that minimizes (2×(W+H)+4) / (W×H) which favors square-like tiles over extreme rectangles. Hexagonal tilings offer marginal improvement (<5%) over optimal rectangular tilings for isotropic stencils and are primarily beneficial for anisotropic or high-order directional stencils. Implementation complexity is substantial: non-rectangular indexing, awkward workgroup mapping, potential warp-divergence at boundaries.
- **Applicability to our 2D 9-point stencil**: VERY LOW. Our 9-point stencil is fully isotropic (equal dependency in all 8 directions). The halo overhead ratio is already minimized by choosing optimal rectangular shapes (we've swept these: 16×4, 16×8, 32×2, etc.). Hexagonal gains would be ≤2-3%, not worth the massive code complexity.
- **Expected gain**: 1-3% at best.
- **Difficulty**: Very High. Would require custom indexing scheme, non-standard workgroup-to-tile mapping, complex edge handling.
- **Requires subgroups?** No.

### 12. Half-Precision SMEM Packing (Store u at f32, Pack v into Upper Bits)

- **Sources**: General bit-manipulation technique, fp16 IEEE-754 binary16 format specification
- **Key finding**: This is a trick to pack two f16 values into a single f32 SMEM slot without requiring full f16 shader support. Store u in lower 16 bits of a u32, store v in upper 16 bits, then unpack in-place after reading. In WGSL: `pack2x16float`/`unpack2x16float` builtins! These are standard WGSL functions that convert `vec2<f32>` ↔ `u32`, effectively packing two f32 values as f16 into a single 32-bit word. Alternatively, manual bit manipulation: `((bitcast<u32>(v_f16) << 16) | bitcast<u32>(u_f16))`. This halves SMEM storage requirement (one array instead of two), potentially halving SMEM transactions if the compiler coalesces the single-component reads. The critical difference from option #3 (full f16): here we use f32 math with f16 precision SMEM storage, avoiding the ALU precision concerns while getting the SMEM bandwidth benefit. Risk: pack/unpack adds 2 instructions per neighbor read. Also, f16 has reduced precision (10-bit mantissa vs 23-bit for f32), which WILL change results and break the hash gate.
- **Applicability to our 2D 9-point stencil**: MODERATE-HIGH alternative to full f16 (#3). If f16 SMEM bandwidth is the win but we want f32-precision math to maintain correctness, this is the best approach. The `pack2x16float` builtin is zero-cost on hardware that supports half-precision natively. The 16 SMEM reads become 8 packed reads (or 8 32-bit transactions serving both u+v simultaneously). Actually, with vec2<f32> SMEM packing we already tried this (Phase D/L — `tile_uv: array<vec2<f32>>`). Result: hash mismatch; throughput varied (+101% at 256² but below baseline elsewhere). Revisit specifically with pack2x16float which might be more efficient than vec2 SMEM loads on certain compilers.
- **Expected gain**: Similar to vec2 packing: 10-50% depending on resolution, but with hash breakage.
- **Difficulty**: Medium. Requires rewriting tile loading/unpacking throughout laplacian.
- **Requires subgroups?** No.
