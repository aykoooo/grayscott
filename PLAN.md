# Gray-Scott GPU Optimization Plan

Optimize the WebGPU compute shader for the Gray-Scott reaction-diffusion engine.

## Constraints
- Correctness is sacred: final hash must match `gpu_256_e16ed0e3c29cc50b...`
- CPU tests (src/simulation.zig, src/grid.zig) must NEVER break
- Only modify: src/gpu/gpu.zig, build.zig, BENCHMARK/bench_gpu.zig

## Baseline
- GPU naive: ~58M cells/sec (Intel integrated, wgpu-native/Vulkan)
- CPU ref: ~500M cells/sec
- Target: >100M cells/sec on this GPU via shared memory + f16

## Backlog

- [ ] **1.1** Research shared memory tiling in WGSL
- [ ] **1.2** Implement shared memory tile (16x16 workgroup + halo)
- [ ] **1.3** Benchmark shared memory vs baseline, keep if >10% faster
- [ ] **2.1** Research f16 storage in WebGPU
- [ ] **2.2** Implement f16 storage format (shader-f16 feature)
- [ ] **2.3** Benchmark f16 vs f32, keep if >10% faster
- [ ] **3.1** Research temporal blocking for stencil loops
- [ ] **3.2** Implement K=2 temporal blocking in compute shader
- [ ] **3.3** Benchmark temporal blocking, keep if >10% faster
- [ ] **4.1** Tune workgroup size (sweep 8x8 to 32x32)
- [ ] **4.2** Document optimal workgroup size and why
- [ ] **5.1** Research subgroup shuffle for neighbor sharing
- [ ] **5.2** Implement subgroupShuffle neighbors if supported
- [ ] **5.3** Benchmark subgroup approach
- [ ] **6.1** Batch multiple dispatches into one command buffer
- [ ] **6.2** Benchmark batching overhead reduction
- [ ] **7.1** Remove per-step wgpuDevicePoll (async submit)
- [ ] **7.2** Benchmark async overlap approach
- [ ] **8.1** Final combined sweep: best workgroup × f16 × tile size
- [ ] **8.2** Document all findings and final performance
- [ ] **9.1** Report final cells/sec and commit as final result
