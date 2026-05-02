# grayscott

High-performance Gray-Scott reaction-diffusion simulation engine written in Zig.

Computes Pearson parameter maps and single-simulation patterns using a 9-point Laplacian stencil matching Karl Sims' authoritative specification.

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

Feed varies with Y (rows, bottom→top). Kill varies with X (cols, left→right).

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

# Build only WASM module (for browser)
zig build wasm -Doptimize=ReleaseFast

# Run tests
zig build test

# Run benchmarks
zig build bench
```

## WASM API (Browser)

Use the WASM module as a deterministic compute backend:

```javascript
const wasm = await WebAssembly.instantiateStreaming(fetch('grayscott.wasm'));
const { exports: w } = wasm.instance;

w.gs_init(256, 256);                              // allocate grid
w.gs_set_params(0.0545, 0.062, 1.0, 0.5, 1.0);   // set feed, kill, da, db, dt
w.gs_stepN(100);                                   // run 100 steps

// Read state into JS arrays
const size = 256 * 256;
const u = new Float32Array(size);
const v = new Float32Array(size);
w.gs_get_state(u, v, size);

w.gs_destroy();  // free memory
```

## Output Format

PGM P5 binary grayscale. The **v channel** (chemical B concentration) is used as pixel intensity:
- V = 0 → black (no inhibitor present)
- V = 1 → white (inhibitor saturated)

Open with GIMP, ImageJ, IrfanView, or any tool supporting PGM format.

## Algorithm

Implements the Gray-Scott model with explicit forward Euler integration:

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
├── main.zig          CLI entry point (map + sim commands)
├── grid.zig          GrayScottGrid struct (SoA layout)
├── simulation.zig    Core step functions (periodic + Neumann boundaries)
├── map.zig           Pearson parameter map generator
├── wasm.zig          WASM exports for browser integration
└── params.zig        SimParams type definition

test/
├── test_sim.zig      Unit tests (init, fill, seed, determinism, bounds)
└── bench_sim.zig     Performance benchmarks
```

## References

- Karl Sims: [Reaction-Diffusion Tutorial](https://karlsims.com/rd.html)
- Robert Munafo: [Xmorphia](https://mrob.com/pub/comp/xmorphia/)
- Pearson (1993): Complex Patterns in a Simple System, *Science* 261:189-192

## License

MIT
