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
