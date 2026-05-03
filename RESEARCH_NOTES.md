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
