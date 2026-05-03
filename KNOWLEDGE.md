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
- None yet — this file will be populated by loop iterations

## Failure patterns:
- None yet

## Phase completion status:
A: ✅ GPU WebGPU compute pipeline working natively via wgpu-native
   - Naive WGSL shader generates correct results (not bit-identical to CPU due to GPU eval order, but mathematically equivalent)
   - GPU reference hash: e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43
   - Benchmark target: `zig build bench-gpu`
   - IMPORTANT: Shader is generated at RUNTIME inside `generateWgsl()` in `src/gpu/gpu.zig`.
     Do NOT modify `src/gpu/gray_scott.wgsl` — it is NOT used by the native benchmark.
     To change the shader, edit the `generateWgsl()` function.
B: □  C: □  D: □  E: □  F: □  G: □  H: □
I: □  J: □  K: □  L: □  M: □  N: □  O: □
