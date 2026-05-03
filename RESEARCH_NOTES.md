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

## 2026-05-03 — Phase K: f16 Storage Full Experiment

- **Feature detection**: ShaderF16 IS available on RTX 4060 Vulkan/wgpu-native v29 (v29 IO polyfill fixed old StorageInputOutput16 blocker). Committed as `has_f16` flag in GpuState + `wgpuAdapterHasFeature()` call.
- **Implementation**: Full round-trip: enable f16 shader, array<f16> storage, f32()/f16() casts, Zig-side f32↔u16 packing/unpacking, half-size ping-pong buffers.
- **Hash**: Deterministic across runs: `d1acf26754798c4eeb65fb0b0665cf8e197609caafbed2389bdd2ee6adea6bab`
- **Throughput**: ~1.2–1.7B cells/sec at 256²/500 (cold start), vs f32 best of 2.35B. At thermally-degraded state: f16=828M, f32=759M (+9% advantage).
- **Root cause**: Compute-bound at all tested scales. Shared memory tiling makes global bandwidth savings invisible.
- **Verdict**: Reverted. Code complexity not justified by zero perf gain. Knowledge preserved for future larger-scale work.
