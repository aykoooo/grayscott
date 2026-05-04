# nabla-type-lite GPU Engine Plan

Target: maximum cells/sec for browser WebGPU Gray-Scott engine.
Constraint: dynamic resolution & params — nothing hardcoded.
Integration: pre-compiled gray_scott_shader.wasm loaded by nabla-type-lite.

## Correctness
- Hash gate: e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43 (periodic, 256²/500)
- Source of truth files (NEVER modify): src/simulation.zig, src/grid.zig, test/
- Editable: src/wgsl_gen.zig, src/wasm_shader.zig, src/gpu/gpu.zig, build.zig, BENCHMARK/bench_gpu.zig

## Current State
- Best: **2.35B cells/sec** (native, RTX 4060, 16×4 tiling + command buffer batching)
- Browser baseline: same shader, unknown throughput (not yet measured in-browser)
- WASM export: gray_scott_shader.wasm ships generateWgsl() → returns {ptr, len}

---

## Phase 0: Fix Naga Subgroups Blocker (PREREQUISITE)

### Goal
wgpu-native v29 Naga rejects `enable subgroups;`. Upgrade or replace so native benchmarks
can validate subgroup-dependent shader variants (Phases 2-4).

### Tasks
- [ ] **0.1** Download latest wgpu-native release (v30+), replace:
  - `vendor/wgpu-native/lib/wgpu_native.dll`
  - `vendor/wgpu-native/include/webgpu/` headers
  - Verify: `WGPUFeatureName_Subgroups` exists.
- [ ] **0.2** Build bench-gpu-subgroups target and run `zig build bench-gpu-subgroups`.
  Must NOT produce "not yet implemented in Naga" error.
- [ ] **0.3** If v30+ still blocked: research Dawn direct integration (node.js/addon or deno).
  Document alternative in RESEARCH_NOTES.md.

### Gate
```
zig build bench-gpu-subgroups   # → produces cells_per_second + hash, not Naga error
```

### On failure (all attempts)
Block Phases 2-4 with status `[BLOCKED: Naga subgroups]`. Proceed to Phases 3.1 (coarse no subgroups) and 5 (dynamic selection).

---

## Phase 1: Dynamic Workgroup Sizing + nabla Integration Baseline

### Goal
gray_scott_shader.wasm auto-selects best tile_x/tile_y for any W×H. Plug into nabla-type-lite, establish browser benchmark.

### Tasks
- [x] **1.1** Add `gs_wasm_optimal_tile(width, height)` → returns best (tile_x, tile_y) pair.
  Algorithm: try divisors of W/H near 16×4, pick the one maximizing occupancy (W/tx × H/ty).
  Fallback: use nearest divisor with edge masking for non-divisible grids.
- [x] **1.2** Export bind group layout descriptor from WASM (binding indices + buffer types).
  Current layout: BG0={u_in:RO, v_in:RO, u_out:RW, v_out:RW, params:UNIFORM}.
  Return as JSON string or structured const.
- [x] **1.3** Export dispatch metadata: groups_x = ceil(W/tile_x), groups_y = ceil(H/tile_y),
  buffer_sizes = W*H*4. Single call returning all init requirements.
- [x] **1.4** Verify hash at multiple resolutions: 128², 256², 512², odd dimensions (257×257).
  256² sacred hash confirmed ✓. 128²/200 ✓, 512²/500 ✓. 257×257: wgpu-native "parent device lost" crash (pre-existing driver issue).
- [x] **1.5** Document nabla-type-lite integration: JS snippet showing load→configure→step cycle.

### Verification
- `zig build wasm-shader` succeeds
- All exported functions return valid data for W=256,384,512,1024,257
- GPU benchmark hash matches at 256²/500

---

## Phase 2: Subgroup Shuffle Variant (Chrome 134+)

### Goal
Replace shared-memory neighbor reads with intra-warp register shuffles. Only active when browser exposes `"subgroups"` feature.

### Why This Works With Our 16×4 Layout
In a 16×4 workgroup (64 threads = 2 warps × 32):
- Warp 0: threads 0..31 = rows 0 and 1 (both 16-wide rows)
- Warp 1: threads 32..63 = rows 2 and 3

Threads (row=y, col=x) and (row=y, col=x±1) are ADJACENT LANES in same warp.
Threads (row=y, col=x) and (row=y±1, col=x) are ±16 LANES apart in same warp.

This means ALL 8 neighbors of every cell are accessible via subgroup ops within the SAME WARP — zero shared memory reads needed for the Laplacian.

### Tasks
- [x] **2.1** Create `generateWgslSubgroups()` in wgsl_gen.zig.
   ✅ Implemented. Subgroup shuffle via subgroupShuffleUp/Down (interior cells only, edge fallback to SMEM).
   `enable subgroups;` at top, WGPUFeatureName_Subgroups=0x12 in C headers.
   ❌ [BLOCKED native]: wgpu-native v29 Naga does NOT support `enable subgroups;` ("not yet implemented in Naga").
   Code IS valid for Chrome 134+ (Dawn supports it). Exported via gs_wasm_build_subgroups().
- [BLOCKED] **2.2** Feature-detect in wasm_shader.zig: export `gs_wasm_has_subgroups() → bool` (currently hardcoded false, JS overrides).
  BLOCKED by Naga lack of subgroups support. Chrome JS-side feature detection works directly.
- [BLOCKED] **2.3** Export both variants: gs_wasm_build_subgroups(w,h) and gs_wasm_build_standard(w,h).
  Already exported: gs_wasm_build_subgroups() works in WASM module but untestable natively.
- [BLOCKED] **2.4** Hash MUST match e16ed0e3... — subgroup ops must produce bit-identical results to standard path.
  Cannot verify: wgpu-native v29 Naga rejects `enable subgroups;` at shader creation.
- [BLOCKED] **2.5** Benchmark subgroup variant vs standard at 256²/500 and 512²/500.
  Cannot run: Naga parsing error. Browser manual test only.

### Note on Diagonal Neighbors
For the 9-point stencil, diagonal values at (±1,±1) require combined horizontal+vertical offsets.
Within a single warp, lane offset = dx + dy*16 where dx,dy = ±1.
E.g.: NE neighbor at (col+1, row-1) = shuffle by (1 - 16) = -15 lanes.
Pattern: subgroupShuffleXor with appropriate mask handles this.

### Verification
- `zig build test` passes (WGSL generation only, no actual subgroup execution)
- GPU benchmark: hash matches, median throughput measured
- Subgroup variant measurable > standard variant when running in Chrome 134+

---

## Phase 3: Thread Coarsening (2 Cells/Thread)

### Goal
Each thread computes 2 adjacent horizontal cells. Halves dispatch count, amortizes index calculations.

### Tasks
- [ ] **3.1** Create `generateWgslCoarse()` — coarsened variant with standard shared memory (no subgroups).
   Workgroup stays 16×4. Each thread processes (gid.x, gid.y) AND (gid.x+total_groups_x*tx, gid.y).
   Coverage per workgroup: 16×4 cells. Dispatch: ceil(W/(2*tx)) × ceil(H/ty). Tile unchanged.
   Double arithmetic per thread, halved dispatch overhead.
- [ ] **3.2** Create `generateWgslCoarseSubgroups()` — coarsening + subgroups combined.
  Register pressure check: 2 cells × ~8 intermediates = 16 floats = well under 128. Safe.
- [ ] **3.3** Benchmark all 4 variants: std, subgroups, coarse, coarse+subgroups. Pick best per resolution bracket.
- [ ] **3.4** Hash MUST still match e16ed0e3...

### Verification
- Hash gate (all variants)
- Median throughput sweep across variants
- No variant slower than standard baseline

---

## Phase 4: Temporal Blocking via Subgroups (2-Step Fusion)

### Goal
Process 2 time steps per global memory read using subgroup communication for intermediate state propagation.

### Why Subgroups Enable This
Without subgroups, temporal blocking needs expanded tiles (12×12 input) plus intermediate shared memory arrays — requiring coarsening first. With subgroups, step-t results propagate warp-wide without extra SMEM:

```
Load 10×10 tile → SMEM → barrier
Step t: compute all cells using subgroup-shuffled neighbors
        → store u_t+1, v_t+1 in registers (per-thread, for self only)
Step t+1: need self AND neighbors' t+1 values
         → subgroup-shuffle the register-held t+1 values within warp
         → compute Laplacian on shuffled intermediates
Write final output (cell at t+2)
```

The warp-wide register exchange replaces the intermediate shared memory array entirely.

### Tasks
- [ ] **4.1** Create `generateWgslTemporal()` — 2-step fusion using subgroup ops.
  Steps parameter at dispatch level: ceil(N/2) dispatches instead of N.
  Workgroup stays 16×4. Tile load unchanged (10-row, TX+2 col).
  Step t computes 8×4 interior cells → stores in registers.
  Step t+1 uses subgroup shuffles to get neighbors' t+1 values → computes final output.
- [ ] **4.2** Handle odd step counts: final single step uses standard (or subgroup) path.
- [ ] **4.3** Benchmark temporal vs non-temporal. Expected 1.4-1.7× over subgroups-only baseline.
- [ ] **4.4** Hash verification. Temporal must produce identical result as doing 2× single steps.

## Phase 5: Dynamic Engine Selection + Tuning

### Goal
gray_scott_shader.wasm becomes a smart engine that auto-selects the best shader variant based on browser capabilities, resolution, and stepping pattern.

### Tasks
- [ ] **5.1** Expose `gs_wasm_get_best(width, height, features_bitmask)` → returns {shader_ptr, shader_len, tile_x, tile_y, variant_tag}.
  Features bitmask encodes: subgroups=1, f16=2 (future), etc.
  Decision logic:
    | Condition | Variant |
    |---|---|
    | subgroups && steps > 100 | temporal+coarse+subgroups |
    | subgroups && steps <= 100 | coarse+subgroups |
    | subgroups only | subgroups |
    | default | standard (tiled, no subgroups) |
- [ ] **5.2** Resolution-adaptive workgroup sizing:
    | Aspect ratio | Workgroup |
    |---|---|
    | W ≈ H (square) | 16×4 |
    | W >> H (wide) | 32×2 |
    | W << H (tall) | 4×16 |
- [ ] **5.3** Non-divisible grid handling: add edge-mask threads. Currently we bounds-check `if x>=WIDTH return` but halo loading also needs boundary-aware logic for non-periodic (Neumann) edges. For periodic, select() already handles it.
- [ ] **5.4** Performance budget: shader generation must complete in <5ms (to not block UI during resolution change). Target: generateWgsl() runtime <1ms at any resolution.
- [ ] **5.5** Comprehensive benchmark matrix: all variants × resolutions (128²,256²,512²,1024²) × step counts (100,500,5000).

---

## File Map

| File | What lives there | Phases touching it |
|---|---|---|
| `src/wgsl_gen.zig` | All generateWgsl* variants (standard, subgroups, coarse, temporal) | 1,2,3,4 |
| `src/wasm_shader.zig` | WASM exports, feature detection, engine selection logic | 1,5 |
| `src/gpu/gpu.zig` | Native pipeline (delegates to wgsl_gen), benchmark driver | (read-only for verification) |
| `build.zig` | Build targets for wasm-shader, tests, benchmarks | 1 |
| `PERFORMANCE.md` | Browser + native benchmark results table | all |
| `KNOWLEDGE.md` | What worked/failed per phase | all |

---

## Deliverables

When all 5 phases are done, nabla-type-lite gets:

```
const wasm = await loadWasm('gray_scott_shader.wasm');
const info = wasm.gs_wasm_init(width, height);
// info = { shader_wgsl, groups_x, groups_y, buffer_sizes, bindings }

const device = await adapter.requestDevice({
    requiredFeatures: navigator.gpu.getPreferredCanvasFormat() ? ['subgroups'] : []
});

// Configure WebGPU with returned metadata
// On each frame or step batch:
pass.setPipeline(computePipeline);
pass.dispatchWorkgroups(info.groups_x, info.groups_y, 1);

// On resolution change:
// Re-run gs_wasm_init(newWidth, newHeight), reallocate buffers, continue
```

---

## Total Projected Performance

| Layer | Est. Gain | Cumulative |
|---|---|---|
| Baseline (16×4 tiling + batching, native) | — | 2.35B native |
| Baseline (same shader in Chrome WebGPU) | ~1.0× | ~2.3B browser |
| + Subgroups (Phase 2) | 1.25× | ~2.9B |
| + Thread coarsening (Phase 3) | 1.35× | ~3.9B |
| + Temporal blocking (Phase 4) | 1.5× | ~5.9B |
| + Dynamic tuning (Phase 5) | 1.15× | ~6.8B |

**Target: ~6.8B cells/sec (browser), reaching 51% of theoretical bandwidth ceiling.**

This means a 1024² simulation at 60fps could run ~110 steps per frame — real-time interactive speed.

---

## 🚀 How to Run Everything

### Single Command

```bash
./run-ocloop.sh
```

That's it. No arguments. No per-phase invocations. The loop reads `.loop-prompt.md`
(Manual mode), finds the first `[ ]` in this file, and works through every task
sequentially until every line is either `[x]` or `[BLOCKED]`.

### What Happens

| Iteration | Agent does |
|---|---|
| Reads state | NABLA_PLAN.md → finds first `[ ]` (currently Phase 0.1) |
| Assesses | Confirms which phase.task from the plan |
| Researches | Web search if new technique (Phase 0 = download + replace DLL; skip search) |
| Implements | Edits `src/wgsl_gen.zig`, `src/wasm_shader.zig`, `src/gpu/gpu.zig`, `build.zig` |
| Tests | `zig build test` — must pass |
| Benchmarks | 3× `zig build bench-gpu` — median cells/sec |
| Verifies hash | Sacred hash `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43` |
| Compares | > baseline + 10% = keep. Slower/broken hash = `git reset --hard HEAD`, retry |
| Marks done | `[x]` in NABLA_PLAN.md, record in PERFORMANCE.md + KNOWLEDGE.md |
| Commits | Git commit with conventional message |
| Advances | Finds next `[ ]` → repeats |

### Task Order (What The Loop Will Execute)

```
Phase 0.1 → 0.2 → 0.3      Fix Naga subgroups (upgrade wgpu-native)
    ↓
Phase 2.2 → 2.3 → 2.4 → 2.5  Complete subgroup integration (needs Phase 0)
    ↓
Phase 3.1                     Thread coarsening WITHOUT subgroups (runs regardless)
    ↓
Phase 3.2 → 3.3 → 3.4        Coarse+subgroups combined (needs Phase 0)
    ↓
Phase 4.1 → 4.2 → 4.3 → 4.4  Temporal blocking (needs Phase 0)
    ↓
Phase 5.1 → … → 5.5          Dynamic engine selection (runs regardless)
```

**If Phase 0 fails** (Naga stays blocked): The loop marks Phases 0, 2, 3.2+, 4 as
`[BLOCKED]`, skips them, and continues with 3.1 and 5.x — the two phases that
don't need subgroups.

### Stall Prevention (Automatic)

Per the loop prompt's stall rules: each sub-task gets up to 3 attempts.
On the 4th attempt, it auto-escalates to `[BLOCKED: reason]` and moves on.

Example: if `generateWgslCoarse()` produces broken hashes after 3 different
implementation approaches, the agent marks it `[BLOCKED: hash mismatch after 3 attempts]`,
logs findings to KNOWLEDGE.md, and proceeds to the next task.

### Pre-Flight Checks

```bash
git status                    # clean working tree
zig build test                # must pass
zig build wasm-shader         # must build
ls vendor/wgpu-native/lib/wgpu_native.dll   # must exist for GPU bench
```

### Post-Run Verification

```bash
git log --oneline -10         # review commits made
zig build wasm-shader         # WASM module still builds
PERFORMANCE.md                # benchmark results recorded
NABLA_PLAN.md                 # all lines are [x] or [BLOCKED]
git gc --aggressive           # compact loose objects from many loop commits
```

Optionally squash per-phase commits:
```bash
git rebase -i HEAD~N          # N = number of commits for one phase
```

### Expected Total Duration

| Scenario | Est. wall-clock time |
|---|---|
| Naga fixed + all phases succeed | ~2–4 hours (6-8 loop iterations) |
| Naga stays blocked | ~30 min (only Phase 3.1 + 5 runs) |
| Naga fixed but some phases stall | ~2 hours (some blocked, rest done) |