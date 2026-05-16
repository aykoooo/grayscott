# grayscott

High-performance Gray-Scott reaction-diffusion simulation engine written in Zig, targeting both native (wgpu-native/Vulkan) and browser (WebGPU/WASM).

Computes Pearson parameter maps and single-simulation patterns using a 9-point Laplacian stencil matching Karl Sims' authoritative specification.

## Performance

| Platform | Throughput | Notes |
|---|---|---|
| Chrome WebGPU | **5.2B cells/sec** | 256²/500 steps, 32×2 tiling + FMA |
| Native (wgpu-native) | **2.35B cells/sec** | RTX 4060 Laptop, 40W VBIOS power cap |
| Firefox WebGL | **2.5B cells/sec** | WebGL fallback (WebGPU blocked by Naga perf) |
| CPU (ReleaseFast) | ~500M cells/sec | Single-threaded Zig |

GPU pipeline: shared memory tiling + command buffer batching (all dispatches in one submit) + FMA laplacian + dynamic workgroup selection. Roofline analysis confirms bandwidth-bound at AI=1.56 FLOPs/byte, with 17.7% of theoretical ceiling reached.

## Quick Start

```bash
zig build cli -Doptimize=ReleaseFast
./zig-out/bin/grayscott-cli map    # generate parameter map (defaults)
./zig-out/bin/grayscott-cli sim    # run single simulation (coral params)
```

Requires **Zig 0.15**.

## CLI Usage

### Generate a Parameter Map

```
grayscott-cli map [w] [h] [iterations] [f_min f_max k_min k_max] [output]
```

| Arg | Default | Description |
|-----|---------|-------------|
| `w` | 1024 | Output width (pixels) |
| `h` | 1024 | Output height (pixels) |
| `iterations` | 50000 | Simulation steps |
| `f_min` | 0.01 | Minimum feed rate |
| `f_max` | 0.10 | Maximum feed rate |
| `k_min` | 0.045 | Minimum kill rate |
| `k_max` | 0.07 | Maximum kill rate |
| `output` | map.pgm | Output file (PGM format) |

Feed varies with Y (rows, bottom-to-top). Kill varies with X (cols, left-to-right).

Examples:
```bash
# Full crescent (Karl Sims defaults)
grayscott-cli map 1024 1024 50000 map.pgm

# Zoom into coral region
grayscott-cli map 512 512 20000 0.05 0.06 0.058 0.064 coral_region.pgm

# Quick preview
grayscott-cli map 256 256 5000
```

### Run a Single Simulation

```
grayscott-cli sim [w] [h] [iterations] [output]
```

| Arg | Default | Description |
|-----|---------|-------------|
| `w` | 256 | Grid width |
| `h` | 256 | Grid height |
| `iterations` | 1000 | Simulation steps |
| `output` | sim.pgm | Output file |

Uses coral parameters (f=0.0545, k=0.0620, Da=1.0, Db=0.5).

## Building

```bash
# Build both CLI and WASM
zig build -Doptimize=ReleaseFast

# Build only CLI
zig build cli -Doptimize=ReleaseFast

# Build CPU WASM module (browser)
zig build wasm -Doptimize=ReleaseFast

# Build WASM shader module (WGSL generation + engine selector)
zig build wasm-shader -Doptimize=ReleaseFast

# Run tests
zig build test

# Run CPU benchmarks
zig build bench
```

### GPU Benchmarks (requires wgpu-native DLLs in vendor/)

```bash
zig build bench-gpu          # 256²/500 steps
zig build bench-gpu-512      # 512²/500
zig build bench-gpu-1024     # 1024²/100
zig build bench-gpu-f16      # f16 variant (256²)
zig build bench-map-pearson  # GPU Pearson map generation
zig build bench-all          # All variants sweep (same-process)
```

## WASM API (Browser)

### CPU Module (`grayscott.wasm`)

```javascript
const wasm = await WebAssembly.instantiateStreaming(fetch('grayscott.wasm'));
const { exports: w } = wasm.instance;

w.gs_init(256, 256);                              // allocate grid
w.gs_set_params(0.0545, 0.062, 1.0, 0.5, 1.0);   // set feed, kill, da, db, dt
w.gs_stepN(100);                                   // run 100 steps

const size = 256 * 256;
const u = new Float32Array(size);
const v = new Float32Array(size);
w.gs_get_state(u, v, size);

w.gs_destroy();
```

### GPU Shader Module (`gray_scott_shader.wasm`)

Exports WGSL shader generators, seed generation, dynamic engine selection, and tile sizing:

```javascript
const wasmModule = await WebAssembly.instantiateStreaming(fetch('gray_scott_shader.wasm'), { env: {} });
const { exports: wasm } = wasmModule.instance;

const info = wasm.gs_wasm_init(width, height);
// info = { tile_x, tile_y, workgroup_x, workgroup_y, dispatch_x, dispatch_y, buffer_size }

const shaderResult = wasm.gs_wasm_build_periodic(width, height, info.tile_x, info.tile_y);
const wgslSource = readString(shaderResult.ptr, shaderResult.len);

// Create WebGPU pipeline with wgslSource, dispatch info from gs_wasm_init
```

Full integration API documented in KNOWLEDGE.md. Available variants: standard (tiled+FMA), coarse SMEM (±23%, opt-in, hash differs), f16 (WASM export only), vec2 SMEM, subgroups (browser-only), subgroup-shuffle (browser-only), Pearson (Neumann boundaries + spatial f/k).

## Browser Benchmarks

Two harnesses in `BENCHMARK/`:

- **`bench.html`** — WebGL vs WebGPU head-to-head comparison
- **`index.html`** — Multi-run GPU benchmark with median statistics and hash verification

Serve with `npx serve BENCHMARK/` (WebGPU requires secure context / localhost). Copy `zig-out/bin/gray_scott_shader.wasm` next to the HTML before serving.

Key findings: Chrome 5.2B cells/sec, Firefox WebGL 2.5B (WebGPU blocked — Naga emits slow SPIR-V for SMEM-tiled compute shaders, ~110M cells/sec). Hash divergence between Tint (Chrome) and Naga (native) is deterministic — each has its own sacred hash.

## Correctness

SHA256 hash of the final U array after 500 steps at 256²:

| Implementation | Hash |
|---|---|
| CPU (sacred) | `9760dfcd...` |
| GPU native (Naga/Vulkan) | `e16ed0e3...` |
| GPU browser (Chrome/Tint) | `8a39d2ab...` |

GPU and CPU hashes differ due to parallel f32 instruction ordering. Each GPU compiler (Naga, Tint) produces its own deterministic hash. See `BENCHMARK/reference_hashes.txt`.

## Output Format

PGM P5 binary grayscale. The **v channel** (chemical B concentration) is used as pixel intensity:
- V = 0 → black (no inhibitor present)
- V = 1 → white (inhibitor saturated)

Open with GIMP, ImageJ, IrfanView, or any tool supporting PGM format.

## Algorithm

| Component | Value |
|-----------|-------|
| Laplacian stencil | 9-point: cardinal 0.2, diagonal 0.05, center -1.0 |
| Diffusion rates | Da = 1.0, Db = 0.5 |
| Time step | dt = 1.0 |
| Boundaries (sim) | Periodic (toroidal wrap) |
| Boundaries (map) | Neumann (zero-flux at edges) |
| Initial state | A = 1.0, B = 0.0 everywhere |
| Seed | Small squares of A=0.5, B=1.0 |

Matches Karl Sims' specification ([karlsims.com/rd.html](https://karlsims.com/rd.html)).

## Parameter Map Structure

```
                kill →
          0.045 ─────────── 0.07
    0.10  │   solid B    | worms    │
      ↑   │              |          │
      f   │   chaos      | spots    │
          │              |          │
    0.01  │   dead       | dead     │
          └─────────────────────────┘
```

Active crescent region between ~f=0.015-0.090 and ~k=0.046-0.065.

## Project Structure

```
src/
  main.zig           — CLI entry point (map + sim commands)
  grid.zig            — GrayScottGrid (SoA f32 layout)
  simulation.zig      — stepDeterministic + stepNeumann (sacred, never modified)
  params.zig          — SimParams type
  map.zig             — Pearson parameter map generator
  wasm.zig            — CPU WASM exports (browser)
  wasm_shader.zig     — GPU WASM exports: WGSL generation, engine selector, seed gen
  wgsl_gen.zig        — 7 WGSL variant generators (8KB buffer)
  gpu/
    gpu.zig           — Native WebGPU pipeline (~800 lines, runtime WGSL generation)
    webgpu.zig        — C import wrapper for webgpu/wgpu.h
    gray_scott.wgsl   — Naive reference shader (not used in benchmarks)

test/
  test_sim.zig        — 6 unit tests: grid, seed, swap, determinism, bounds, patterns
  bench_sim.zig       — CPU performance benchmarks

BENCHMARK/
  bench_gpu.zig       — GPU benchmark harness (supports --tile, --f16 flags)
  bench_map.zig       — End-to-end pipeline benchmark
  bench_map_cpu.zig   — CPU pipeline benchmark (GPU comparison baseline)
  bench_map_pearson.zig — GPU Pearson map generator (PGM output)
  bench.html          — WebGL vs WebGPU browser comparison
  index.html          — Multi-run browser benchmark harness
  reference_hashes.txt — Sacred correctness hashes

build.zig             — ~25 build targets (CLI, WASM, GPU, verification, map)
PLAN.md               — Original optimization plan (Phase A-S)
NABLA_PLAN.md         — Current optimization plan (Phase 0-21)
OPTIMIZATION_PLAN.md  — v2 plan (May 2025)
KNOWLEDGE.md          — Accumulated learning (31 iterations)
PERFORMANCE.md        — Benchmark history
RESEARCH_NOTES.md     — Web research citations
```

## Optimization Status

21 GPU optimization phases completed. **Working**: shared memory tiling, command buffer batching, FMA laplacian, dynamic workgroup selection, pipeline override constants, Pearson map GPU generation. **Blocked**: Naga subgroups (tracking issue #5555), f16 (-11% regression), temporal blocking (complexity), coarse SMEM (hash mismatch, opt-in only). **Undone**: Pearson browser integration (Phase 17).

See NABLA_PLAN.md for full phase-by-phase detail.

## References

- Karl Sims: [Reaction-Diffusion Tutorial](https://karlsims.com/rd.html)
- Robert Munafo: [Xmorphia](https://mrob.com/pub/comp/xmorphia/)
- Pearson (1993): Complex Patterns in a Simple System, *Science* 261:189-192

## License

MIT
