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
- f16: skipped due to known Vulkan/NVIDIA driver issues with StorageInputOutput16
- Temporal blocking: too complex for small 8×8 tiles, ROI unclear after batching win

## Phase completion status:
A: ✅  B: ✅  C: ⊘ (skipped)  D: ✅  E: ⊘ (evaluated)  F: ✅
G: ⊘  H: ⊘ (superseded by F)  I: ⊘  J: ✅

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
