# Gray-Scott GPU Optimization Task

Optimize a Zig+WGSL Gray-Scott engine for maximum GCell/s throughput.
Target: browser (WASM + WebGPU compute). Reference: CPU (simulation.zig).

## How The Loop Works (What You Should Know)

You are invoked PER ITERATION with a FRESH context. Don't try to remember
previous iterations — read files instead:

- **KNOWLEDGE.md**: what's been tried, what failed, what worked. READ THIS FIRST.
- **progress.csv**: iteration, cells/sec, outcome, phase for every attempt.
- **cost.csv**: timestamps and durations of each run.
- **git log**: commits tagged "perf:" = accepted, "research:" = investigation.
- **.ralph/state**: loop resume data (best result, current phase, stagnation count).

The loop automatically:
- Runs tests before benchmarking (fail → skip iteration)
- Runs 3 benchmark samples and takes MEDIAN (filters noise)
- Checks SHA256 hash against reference (mismatch → auto-revert)
- Validates at 128² and 512² after accepting improvements at 256²
- Rejects speedups below 1.5% as statistical noise
- Detects stagnation: 5 iterations no improvement → GUIDANCE injected into prompt
  10 iterations → FORCED random phase switch
  15 iterations → PAUSES with HUMAN_INTERVENTION_REQUIRED flag
- Survives crashes/power loss: resumes from exact iteration number on restart

Your WORKING FILES (can modify):
  src/gpu/gpu.zig          (WebGPU compute bridge — includes runtime WGSL generation)
  src/gpu/webgpu.zig       (C bindings wrapper, only if API changes needed)
  build.zig                (for compilation/linking changes)
  BENCHMARK/bench_gpu.zig  (benchmark harness)

NOTE: The WGSL shader is generated at RUNTIME inside gpu.zig's `generateWgsl()`.
Modifying src/gpu/gray_scott.wgsl does NOT affect the native benchmark.
To change the shader, edit the `generateWgsl()` function in src/gpu/gpu.zig.

NEVER MODIFY:
  src/simulation.zig, src/grid.zig, src/map.zig, src/main.zig, src/wasm.zig
  BENCHMARK/reference_hashes.txt, ralph-loop.sh, RALPH.md, KNOWLEDGE.md
  test/, .github/

## Performance Metric
Primary: cells_per_second (median of 3 runs) at 256²/500 steps
Measure:  zig build bench-gpu -Doptimize=ReleaseFast
Log:      progress.csv

Baselines (measured on current hardware):
  CPU:      ~500M cells/sec (single-threaded, ReleaseFast)
  GPU naive: ~96M cells/sec (Intel integrated, wgpu-native/Vulkan)
Target:   >500M cells/sec on this GPU (5× naive via f16 + tiling)
  For dedicated GPUs (RTX class): aim for 5-30 GCell/s

## Correctness Gate
SHA256 of final U array after 500 steps at 256² MUST match the GPU-specific reference:
  e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43
(Stored in BENCHMARK/reference_hashes.txt line starting with "gpu_256_")

NOTE: GPU does NOT match CPU hash due to parallel f32 instruction ordering.
The GPU has its own reference hash. Do NOT try to make GPU match CPU.
Hash mismatch triggers AUTOMATIC REVERT with no appeal.

## Research Protocol
Before implementing any optimization, do ONE research iteration:
  1. Web search for the technique + "WGSL" or "stencil" or "GPU"
  2. Study 2-3 reference implementations (ShaderToy, GitHub, papers)
  3. Write findings to RESEARCH_NOTES.md
  4. Commit as "research: <topic>"

Reference sources:
  - markstock/grayscott (Kokkos CUDA: 4096^2 at 0.005s/step on 3070Ti)
  - ShaderToy tag "grayscott" (dozens of GLSL implementations)
  - piellardj/reaction-diffusion-webgl (WebGL ping-pong, RG16F textures)
  - grayscott-with-rust-grasland pages (Vulkan walkthrough — especially
    their documentation that single-dispatch-per-submit is bottleneck #1)
  - groups.csail.mit.edu/mac/projects/amorphous/GrayScott/
  - Papers: EBISU 2023, Hexagonal Tiling, AN5D framework,
    IPDPS 2013 auto-tuning, PPoPP 2018 register optimization

## Phases With AUTO-TUNING Parameters

For these phases, you must EXPLORE the parameter space systematically
within a SINGLE iteration span (5-10 attempts, keep best):

### Phase C-TUNE: Workgroup Size
Try EVERY shape from this grid, benchmark each, keep the fastest:
  8x8 | 16x16 | 32x4 | 16x8 | 8x16 | 32x8 | 64x4 | 16x32
Then try 1D shapes: 64x1 | 128x1 | 256x1
Record: which shape gave best performance, why you think so.

### Phase D-TUNE: Temporal Blocking Depth
For workgroup size W that won Phase C-TUNE, try K values:
  K=1 (baseline), K=2, K=4, K=8, K=16
Watch for: shared memory exhaustion at high K (crash → auto-revert).
Record optimal K and memory usage per step.

### Phase D-TUNE2: Tile/Halo Ratio
With optimal K fixed, vary tile vs halo size:
  Tile=8 + halo=2 (12x12 shmem)  → 64% useful
  Tile=16 + halo=2 (20x20 shmem) → 80% useful
  Tile=32 + halo=2 (36x36 shmem) → 89% useful
More useful fraction = better but more shmem pressure.

### Phase G-TUNE: Occupancy Level
Test workgroup counts per dispatch:
  Full occupancy:  workgroups fill all SMs
  Half occupancy:  dispatch half as many workgroups × 2 dispatches
  Low occupancy:   <25% SM utilization (EBISU paper recommends this!)
Bandwidth-bound kernels often perform BETTER at lower occupancy because
less cache contention. Test explicitly.

### Phase A/B/C/D-TUNE: Combined Parameter Sweep
Once individual parameters are tuned, sweep COMBINATIONS:
  Optimal K × optimal workgroup × f16 vs f32
Run one long experiment testing all promising combos.

## Fixed Technique Phases (No Parameters To Tune)

### Phase A: Baseline GPU Kernel ✅ COMPLETE
Phase A is DONE. The compute pipeline uses wgpu-native (not emscripten)
and generates WGSL at runtime via `generateWgsl()` in src/gpu/gpu.zig.
The GPU reference hash is already captured. Do NOT revisit Phase A.
Focus on optimizations starting from Phase B.

### Phase B: f16 Storage Format (expected: +100%)
Store array<f16> instead of array<f32>. Concentrations ∈ [0,1] —
11-bit mantissa sufficient for 10^-4 accuracy.
Halve buffer byte sizes. Convert to f32 for Laplacian only.
Requires "shader-f16" WebGPU feature.

### Phase E: Hexagonal Tile Shape (expected: +20-40%)
Replace rectangular temporal tiles with hexagonal ones.
Eliminates warp divergence at tile boundaries.
Particularly important when pushing beyond K=4 depth.

### Phase F: Subgroup Shuffle Neighbor Sharing (expected: +10-20%)
subgroupShuffleDown(val, 1) // horizontal left neighbor
subgroupShuffleUp(val, 1)   // horizontal right neighbor
Frees ~20% shared memory. Requires subgroups feature (Chrome 125+).

### Phase H: Shared Memory Bank Padding (expected: +5-15%)
Pad each row of shmem by 1 element to avoid 32-bank conflicts:
  Instead of shmem[y * width + x]
  Use shmem[y * (width+1) + x]
Check if it matters for YOUR specific access pattern — profile before keeping.

### Phase I: Split Laplacian/Reaction Kernels (expected: ±10%)
BENCHMARK BOTH fused and split. Keep whichever wins.
Pass 1: compute lap_u, lap_v only (store two float arrays)
Pass 2: apply reaction using precomputed laplacians
Counterintuitive: doubles bandwidth BUT reduces register pressure,
potentially enabling higher occupancy. Published PPoPP 2018 results
show up to 10% win for split on register-pressured stencils.

### Phase J: Interleaved U+V Computation (expected: +5-10%)
Compute u derivative and v derivative together while neighbor loads
are fresh in registers. Reduces live register count.

### Phase K: Descriptor Set Deduplication (expected: +5-15%)
Single bind group layout. Bind once per frame. Swap buffer entries
rather than creating new bind groups each step.
Bake params as specialization constants (override declarations).

### Phase L: Multi-Dispatch Batching (expected: +10-20%)
Submit 8-32 dispatches in one command buffer. Amortizes queue submission
overhead. Particularly impactful for short simulations.

### Phase M: Async Compute Overlap (advanced, varies)
If supported: overlap compute pass with render pass on separate queue.
Device-dependent. Profile before committing. May be zero gain.

### Phase N: Launch Bounds / Occupancy Hints (expected: +5-20%)
Tell compiler workgroup size explicitly so it optimizes register allocation.
Can eliminate spills entirely. AMD GPUOpen docs: single-line change recovered
40% performance in their Laplacian benchmark.

### Phase O: Adaptive Convergence (map-specific, expected: +100-500%)
Track per-tile max(|Δu|). Skip converged tiles for remaining steps.
60-80% of map cells converge early in homogeneous steady-state regions.

## Workflow Per Iteration

RESEARCH:
  1. Pick technique from list above
  2. Search web, study references
  3. Write findings → RESEARCH_NOTES.md
  4. Commit: "research: <technique>"

IMPLEMENT:
  1. Read KNOWLEDGE.md + progress.csv + git log
  2. Pick ONE technique (or parameter point for tuning phase)
  3. Implement in minimal file edits
  4. Commit: "perf: <technique>" (or "tune: <parameter>=<value>")
  5. Exit — loop handles test/benchmark/hash/scale validation automatically

TUNING SWEEP (within one session, 5-10 iterations):
  1. Declare sweep: "I'm now exploring workgroup sizes. Trying 5 variants."
  2. Try variant 1 → commit → let loop benchmark → read result
  3. Try variant 2 → commit → let loop benchmark → etc.
  4. After all variants tested: pick fastest, write analysis to KNOWLEDGE.md
  5. Commit final choice: "perf: optimal workgroup = 16x8 (+12% over baseline)"

## Completion Signal
When ALL phases attempted AND further exploration produces no improvement,
write the literal text "OPTIMIZATION_COMPLETE" to status.md and exit.