# Ralph Knowledge Base — Accumulated Learning

This file persists across loop iterations and crashes.
The agent reads it before each attempt to avoid retrying failed approaches.

## Iteration format:
### Iter N: <phase> — <outcome>
<1-line summary of what was attempted and why it failed/succeeded>

---

## Seed knowledge (pre-loop):
- Baseline CPU: ~500M cells/sec at 256²/500 steps (ReleaseFast, single-threaded)
- Reference hash 256²: 9760dfcdb5f4...
- Da=1.0, Db=0.5, dt=1.0 per Karl Sims spec
- 9-point stencil: 0.2 cardinal, 0.05 diagonal, -1.0 center
- WebGPU compute shader path requires emscripten SDK installed
- Zig WASM module exports are in src/gpu/gpu.zig (scaffolded)
- WGSL baseline shader in src/gpu/gray_scott.wgsl (matches CPU exactly)

## Success patterns:
- None yet — this file will be populated by loop iterations

## Failure patterns:
- None yet

## Phase completion status:
A: ✅ GPU WebGPU compute pipeline working natively via wgpu-native
   - Naive WGSL shader generates correct results (not bit-identical to CPU due to GPU eval order, but mathematically equivalent)
   - GPU reference hash: e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43
   - Benchmark target: `zig build bench-gpu`
   - Ralph loop uses `bench-gpu` target and validates against gpu_256_ reference
   - IMPORTANT: Shader is generated at RUNTIME inside `generateWgsl()` in `src/gpu/gpu.zig`.
     Do NOT modify `src/gpu/gray_scott.wgsl` — it is NOT used by the native benchmark.
     To change the shader, edit the `generateWgsl()` function.
B: □  C: □  D: □  E: □  F: □  G: □  H: □
I: □  J: □  K: □  L: □  M: □  N: □  O: □