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
- Shared memory tiling: 16×16 workgroup loading 18×18 tile into `var<workgroup>`. Resulted in +69% improvement (90M→153M).
- Workgroup size tuned to 8×8: smaller tiles mean more workgroup-level parallelism (1024 groups vs 256 for 256²). 8×8 gives 167.7M cells/sec (+86% over baseline, +10% over 16×16).

## Failure patterns:
- 32×32 workgroup: silent failure (likely exceeds implementation limits)
- f16 storage: skipped due to known Vulkan/NVIDIA driver issue with StorageInputOutput16 requirement in wgpu

## Phase completion status:
A: ✅ GPU WebGPU compute pipeline working natively via wgpu-native
B: 🔥 Partially — B.1-B.3 done (shared memory tiling, 153M cells/sec), B.4 pending
