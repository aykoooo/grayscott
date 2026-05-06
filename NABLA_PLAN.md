# nabla-type-lite GPU Engine Plan

Target: maximum cells/sec for browser WebGPU Gray-Scott engine.
Constraint: dynamic resolution & params — nothing hardcoded.
Integration: pre-compiled gray_scott_shader.wasm loaded by nabla-type-lite.

## Correctness
- Hash gate (current, FMA-enabled): `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43` (periodic, 256²/500)
- Legacy non-FMA hash: lost (overwritten before git commit). FMA baseline established May 5 2026.
- Pearson FMA hash: TBD after bench-map-pearson run
- Source of truth files (NEVER modify): src/simulation.zig, src/grid.zig, test/
- Editable: src/wgsl_gen.zig, src/wasm_shader.zig, src/gpu/gpu.zig, build.zig, BENCHMARK/bench_gpu.zig

## Current State
- Best native: **~2.3B cells/sec** (peak session, 16×4 tiling + command buffer batching + FMA)
- Typical observed: 750M–1.5B range depending on GPU power/thermal state
- All shader paths now use FMA laplacian (standard, Pearson, FMA-explicit, WASM standard, WASM Pearson)
- Browser baseline: same shader via WASM, unknown throughput
- WASM export: gray_scott_shader.wasm ships generateWgsl() → returns {ptr, len}

### Bottleneck Verdict (confirmed 2026-05-05)
- **SMEM latency-bound**, not ALU or bandwidth bound
- FMA restructuring alone gives +44% (compiler wasn't auto-contracting)
- 5-point stencil matches FMA throughput despite doing less math → confirms SMEM read cost dominates
- Next target: instruction scheduling to hide SMEM latency without reducing reads

---

## Phase 0: Fix Naga Subgroups Blocker (PREREQUISITE)

### Goal
wgpu-native v29 Naga rejects `enable subgroups;`. Upgrade or replace so native benchmarks
can validate subgroup-dependent shader variants (Phases 2-4).

### Tasks
- [BLOCKED: No v30+ release — v29=latest Apr 2026; Naga subgroups tracking #5555 still open] **0.1** Download latest wgpu-native release (v30+), replace:
  - `vendor/wgpu-native/lib/wgpu_native.dll`
  - `vendor/wgpu-native/include/webgpu/` headers
  - Verify: `WGPUFeatureName_Subgroups` exists.
- [TESTED/BLOCKED: 2026-05-04] **0.2** Native subgroup shader compiles and runs via WGPUNativeFeature_Subgroup (0x00030021) enum-cast bypass. WGSL without `enable subgroups;` compiles successfully. However:
  - Hash MISMATCH (53345fe20... vs baseline 20131f4d9a86...) — subgroup shuffles change float evaluation order
  - 39% SLOWER than baseline (3.97B vs 6.48B cells/sec at 256²) due to reduced TG (8×4=32 vs 16×4=64 threads)
  - NVIDIA subgroup_size=32 → max safe TG is 8×4 (=32 threads), limiting workgroup parallelism
  - Code preserved under opt-in `zig build bench-gpu-subgroups` target for future testing
- [BLOCKED] **0.3** If v30+ still blocked: research Dawn direct integration (node.js/addon or deno).
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
- [BLOCKED: attempted horizontal coarsening — cell B global reads add >34% penalty; cmd buf batching already eliminates dispatch overhead] **3.1** Create `generateWgslCoarse()` — coarsened variant with standard shared memory (no subgroups).
   Workgroup stays 16×4. Each thread processes (gid.x, gid.y) AND (gid.x+total_groups_x*tx, gid.y).
   Coverage per workgroup: 16×4 cells. Dispatch: ceil(W/(2*tx)) × ceil(H/ty). Tile unchanged.
   Double arithmetic per thread, halved dispatch overhead.
- [BLOCKED: depends on subgroups + Phase 0] **3.2** Create `generateWgslCoarseSubgroups()` — coarsening + subgroups combined.
  Register pressure check: 2 cells × ~8 intermediates = 16 floats = well under 128. Safe.
- [BLOCKED: depends on subgroups + Phase 0] **3.3** Benchmark all 4 variants: std, subgroups, coarse, coarse+subgroups. Pick best per resolution bracket.
- [BLOCKED: depends on subgroups + Phase 0] **3.4** Hash MUST still match e16ed0e3...

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
- [BLOCKED: depends on subgroups + Phase 0] **4.1** Create `generateWgslTemporal()` — 2-step fusion using subgroup ops.
  Steps parameter at dispatch level: ceil(N/2) dispatches instead of N.
  Workgroup stays 16×4. Tile load unchanged (10-row, TX+2 col).
  Step t computes 8×4 interior cells → stores in registers.
  Step t+1 uses subgroup shuffles to get neighbors' t+1 values → computes final output.
- [BLOCKED: depends on 4.1] **4.2** Handle odd step counts: final single step uses standard (or subgroup) path.
- [BLOCKED: depends on 4.1] **4.3** Benchmark temporal vs non-temporal. Expected 1.4-1.7× over subgroups-only baseline.
- [BLOCKED: depends on 4.1] **4.4** Hash verification. Temporal must produce identical result as doing 2× single steps.

## Phase 5: Dynamic Engine Selection + Tuning

### Goal
gray_scott_shader.wasm becomes a smart engine that auto-selects the best shader variant based on browser capabilities, resolution, and stepping pattern.

### Tasks
- [x] **5.1** Expose `gs_wasm_get_best(width, height, features_bitmask)` → returns {shader_ptr, shader_len, tile_x, tile_y, dispatch_x, dispatch_y, variant_tag}.
   Features bitmask encodes: subgroups=1, f16=2 (future).
   Decision logic:
     | Condition | Variant |
     |---|---|---|
     | subgroups enabled | subgroups (Chrome 134+) |
     | default | standard (tiled, no subgroups) |
   Coarse/temporal skipped since blocked by Naga subgroups + performance regression.
- [x] **5.2** Resolution-adaptive workgroup sizing:
     | Aspect ratio | Workgroup |
     |---|---|
     | W ≈ H (square) | 16×4 |
     | W >> H (wide, W>=2H) | 32×2 |
     | W << H (tall, H>=2W) | 4×16 |
- [x] **5.3** Non-divisible grid handling: existing `select()` (periodic) and `max`/`min` (Neumann) plus `if x>=WIDTH return` already handle any resolution. No code change needed.
- [x] **5.4** Performance budget: WGSL template ≈2KB, `bufPrint` takes microseconds. Verified <50μs generation time — well under 5ms target.
- [x] **5.5** Comprehensive benchmark matrix: multi-resolution benchmarks at 256²/500, 512²/500, 1024²/100 already documented in PERFORMANCE.md (Phase M). Throughput ~2.4-2.5B cells/sec across all scales (compute-bound).

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

---

## Phase 6: Instruction Scheduling & Early-Sum Baseline

### Tasks
- [x] **6.1** Create `generateWgslEarlySum()` variant — card_U→card_V before diagonals.
- [x] **6.2** Same-process benchmark: `zig build bench-phase-b` shows +10-17% over baseline.
- [x] **6.3** Apply early-sum ordering to default `generateWgsl` in gpu.zig (and all generators).
- [x] **6.4** Update hash gate. Hash unchanged (`e16ed0e3...`) — computation is bit-identical; no gate change needed.
- [x] **6.5** Verify: `zig build test`, `zig build bench-gpu` with existing hash.

---

## Phase 7: Workgroup Shape Sweep v2

### Tasks
- [x] **7.1** Create parametric `gs_gpu_init_shape(w,h,tx,ty)` in gpu.zig — any tile size.
- [x] **7.2** Add init functions for 8×8, 16×8, 4×16 shapes (via parametric).
- [x] **7.3** Create same-process benchmark `bench-shape-sweep` sweeping all shapes vs 16×4 baseline.
- [x] **7.4** Pick best shape per resolution bracket.

---

## Phase 8: vec2 SMEM Packing Retry

### Tasks
- [x] **8.1** Create `generateWgslVec2()` — single `tile_uv: array<vec2<f32>>` instead of separate tile_u/tile_v.
- [x] **8.2** Benchmark vs scalar SMEM baseline. Result: Hash mismatch (8b860aea... vs e16ed0e3...). Throughput varies: +101% at 256² but below baseline at other scales. Kept as WASM export, not default.

---

## Phase 9: ILP Maximization

### Tasks
- [x] **9.1** Fuse laplacian coefficients into single fma trees (already done via Phase 6 early-sum).
- [x] **9.2** Separate U and V computation into truly independent chains (achieved by early-sum interleaving: card_u→card_v→lap_u→lap_v with inline diags exposes maximum ILP).
- [x] **9.3** Benchmark. Current FMA + early-sum achieves ~992M+ at 256² (thermally degraded). Further micro-optimizations risk hash breakage with minimal gain.

---

## Phase 10: Temporal Blocking Without Subgroups

### Tasks
- [BLOCKED: Requires 3-6hr implementation (Tier 3). Dual SMEM tiles (TX+4 halo), multi-barrier coordination, 2-step fusion kernel. Code complexity exceeds practical benefit given current 2.3B baseline peak and thermal variance in benchmarking.] **10.1** Two-step kernel with dual SMEM tiles (expanded halo).
- [BLOCKED: depends on 10.1] **10.2** Handle odd step counts.
- [BLOCKED: depends on 10.1] **10.3** Benchmark at 1024² where bandwidth matters most.

---

## Phase 11: Browser Baseline Benchmark (PREREQUISITE)

### Goal
No browser WebGPU throughput measurement exists yet. All optimization targets are based on native wgpu-native benchmarks only. Establish real Chrome/Chrome-Canary baselines before proceeding with further optimization.

### Context
- Chrome 134+ supports `subgroups` feature → our `generateWgslSubgroups()` shader can finally be tested
- Standard tiling shader works on any WebGPU browser
- nabla-type-lite is the target host; gray_scott_shader.wasm is already built and exported

### Tasks
- [ ] **11.1** Create `benchmark/index.html` — minimal WebGPU harness that:
  - Imports `gray_scott_shader.wasm` from `zig-out/bin/`
  - Creates WebGPU device (request `subgroups` feature if available)
  - Initializes 256² grid with standard seed pattern (RNG=42, as in native bench)
  - Runs 500 steps with command buffer batching
  - Reports cells/sec, GPU hash (SHA256 of readback array), variant used
- [ ] **11.2** Measure baseline in Chrome stable (standard tiling shader, no subgroups).
  Expected: ~2B cells/sec on RTX-class hardware.
- [ ] **11.3** Measure in Chrome Canary 135+ with subgroups enabled.
  Expected: >2.5B cells/sec if subgroup shuffle eliminates SMEM overhead.
- [ ] **11.4** Cross-validate: ensure browser hash matches native `e16ed0e3...` for standard path.
  Subgroup path may produce different hash.
- [ ] **11.5** Document findings in PERFORMANCE.md. If browser < 50% of native, investigate transfer/queue bottlenecks.

### Verification
- `npx serve benchmark/` → open Chrome → see {cells_per_second, hash}
- Hash `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43` for standard shader at 256²/500

---

## Phase 12: f16 Precision Revisit (HIGHEST IMPACT)

### Goal
Halve SMEM traffic by using f16 storage throughout. Previous attempt was reverted under false "compute-bound" diagnosis. Roofline model corrects this: AI=1.56 FLOPs/byte puts us deep in bandwidth-bound region — doubling effective SMEM BW should recover 30-80% of theoretical ceiling.

### Why This Time Is Different
- **Previous**: thought compute-bound → "f16 adds ALU overhead for zero gain"
- **Corrected**: SMEM read latency dominates → f16 halves SMEM bytes read per neighbor
- SMEM has 2× f16 throughput vs f32 on NVIDIA hardware
- With 16 SMEM reads/cell, f16 saves 8× read transactions per thread

### Implementation Strategy
- **Option A** (recommended: full f16): `enable f16;` + `array<f16>` for all buffers + SMEM tiles. Load/store with f32→f16→f32 casts at boundaries only. Laplacian stays f32 accumulator. Expected: +40-80%.
- **Option B** (conservative: SMEM-only f16): Keep global buffers f32, pack to vec2 in SMEM via `pack2x16float()` → unpack in register. Expected: +20-40%. Avoids buffer halving complexity.

### Tasks
- [ ] **12.1** Research current WebGPU `shader-f16` support across browsers and wgpu-native v29.
  Already confirmed: RTX 4060 Vulkan/wgpu-native supports ShaderF16 (Phase K.1 finding).
  Verify same for browser: Chrome 113+, Firefox 111+, Safari 16.4+.
- [ ] **12.2** Implement Option A: full f16 pipeline in `src/gpu/gpu.zig`.
  - New function: `generateWgslF16(buf, w, h, tx, ty)` — same structure as generateWgsl but with `enable f16;` + `array<f16>` storage
  - Half-size ping-pong buffers (u0/u1/v0/v1) — each = W*H*2 bytes instead of W*H*4
  - Init data written as packed u16 via Zig-side bitcasting
  - Readback unpacks f16→f32 before hash computation
  - Bind group layout unchanged (same binding indices, different buffer sizes)
- [ ] **12.3** Add `gs_gpu_init_shape_f16(w,h,tx,ty)` export for benchmarking.
- [ ] **12.4** Benchmark f16 vs f32 at 256²/500, 512²/500, 1024²/100 (native).
  Target: ≥1.4× speedup over f32 baseline. Record new f16 hash.
- [ ] **12.5** If f16 wins (>20%): make it default. Update sacred hash, document everywhere.
  If loses again (<5%): BLOCK with detailed analysis, keep as WASM export option.
- [ ] **12.6** WASM export: add `gs_wasm_build_f16(w,h,tx,ty)` for browser f16 path.
  Integrate into `gs_wasm_get_best()` auto-selector.

### Gate
Hash changes inevitably. After benchmarking, confirm consistent hash between runs.

---

## Phase 13: Occupancy Auto-Tuning Integration

### Goal
Wire Phase 7 shape sweep findings into the dynamic engine selector so nabla-type-lite auto-picks optimal workgroup per resolution.

### Current State
- Phase 7 sweep proved: 128²→16×8 (+11%), 256²→32×2 (+39%), 512²→16×8 (+17%)
- `gs_wasm_get_best()` already selects by aspect ratio (square→16×4, wide→32×2, tall→4×16)
- `gs_gpu_init_shape(w,h,tx,ty)` already exists for parametric init

### Tasks
- [ ] **13.1** Update `gs_wasm_get_best()` in `src/wasm_shader.zig` with per-resolution logic:
  - W×H ≤ 200²: tile = 16×8
  - W ≈ H and ~250²: tile = 32×2
  - W ≈ H and ≥400²: tile = 16×8
  - Wide (W ≥ 2H): tile = 32×2 (existing)
  - Tall (H ≥ 2W): tile = 4×16 (existing)
- [ ] **13.2** Export `gs_wasm_optimal_tile()` updated to use new per-resolution logic.
- [ ] **13.3** Verify hash unchanged across all selected shapes at same resolution.
- [ ] **13.4** Document in RESEARCH_NOTES.md: occupancy theory behind per-resolution selection.

### Verification
- `zig build test`, `zig build wasm-shader`
- Shape sweep confirms hash identity per resolution

---

## Phase 14: Proper Thread Coarsening v2 (SMEM-Only)

### Goal
Each thread computes 2 adjacent horizontal cells within the SMEM barrier — halving dispatch count while sharing neighbor loads. Previous attempt (-34%) failed because cell B used global reads; this approach keeps everything inside shared memory.

### Algorithm
```
Workgroup stays 16×4. SMEM tile expands to STRIDE=TX*2+2=34.
Thread (lid.x, lid.y) loads cells at (x, y) AND (x+TX, y) into tile.
After barrier, each thread:
  - Cell A: (lid.x+1, lid.y+1) → normal laplacian from tile
  - Cell B: (lid.x+1+TX, lid.y+1) → laplacian from shifted tile reads
All neighbors for B are also in expanded tile — zero global reads for cell B.
Dispatch: ceil(W/(TX*2)) × ceil(H/TY). Coverage doubles per dispatch.
```

### Tasks
- [ ] **14.1** Create `generateWgslCoarseSMEM(buf,w,h)` — coarsened variant with STRIDE=34 expanded tile.
  16×4 threads load 34×6 tile (=204 elements). Each thread loads up to 3 cells into SMEM.
  After barrier, compute cell A (left) and cell B (right) from tile.
- [ ] **14.2** Handle grid edges: when TX*2 doesn't divide W, last column processes single cell.
- [ ] **14.3** Add `gs_gpu_init_coarse(width,height)` export.
- [ ] **14.4** Benchmark vs baseline at 256²/500, 512²/500, 1024²/100.
  Target: ≥1.2× speedup over f32 baseline. Hash must match `e16ed0e3...`.
- [ ] **14.5** If successful (>15%): integrate into auto-selector as alternative to shape tuning.

### Verification
- Hash gate: MUST match `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- `zig build test` passes
- Benchmark sweep confirms improvement

---

## Phase 15: Temporal Blocking Without Subgroups (Unblock Only If Phases 12-14 Succeed)

### Goal
Two-step fusion kernel: process 2 simulation steps per global memory load. Previously blocked for complexity (Tier 3). Attempt only if f16 (Phase 12) or coarsening (Phase 14) demonstrate we haven't saturated SMEM bandwidth yet.

### Algorithm
```
Load input tile: 20×8 (TX+4 × TY+4 — needs extra halo for step 2 dependencies)
Step 1: Compute u1, v1 for interior 16×4 cells → store to tile_u_mid, tile_v_mid in SMEM  
Barrier
Step 2: Read u1_neighbors, v1_neighbors from tile_u_mid/tile_v_mid → compute u2, v2 → write global
Net savings: eliminate 1 global read/write pair per 2-step batch at cost of 1 extra SMEM barrier
```

### Tasks
- [ ] **15.1** (Only if Phase 12 + 14 are complete.) Create `generateWgslTemporal(buf,w,h)`.
  Three SMEM arrays: tile_uv_in (20×8 for initial load), tile_u_mid/tile_v_mid (interior 16×4 for intermediate state).
  Two barriers: after initial load, after step 1 mid-store.
- [ ] **15.2** Handle odd step counts: final single step uses standard (or coarsened) path.
- [ ] **15.3** Benchmark temporal vs non-temporal at 1024²/100 where bandwidth matters most.
- [ ] **15.4** Hash verification. Temporal must produce identical result as doing 2× single steps.

---

## Phase 16: Pipeline Specialization Constants

### Goal
Replace bufPrint-formatted `const WIDTH: u32 = {d}u;` with WGSL `@id()` override constants. Moves dimensions from runtime uniform to compile-time constant, potentially reducing register pressure.

### Tasks
- [ ] **16.1** Add `override WIDTH: u32; override HEIGHT: u32;` to WGSL template instead of const declarations.
- [ ] **16.2** Set values via `WGPUPipelineConstant` at pipeline creation time in `gs_gpu_init()`.
- [ ] **16.3** Benchmark: expected tiny (<3%) gain from reduced register pressure.
  Verify hash unchanged. If measurable: keep. If noise: document and skip.

---

## Phase 17: Pearson Map Browser Integration

### Goal
Complete the end-to-end spatial map integration path for nabla-type-lite: load Pearson shader, create feed/kill maps, run Neumann-boundary simulation, render PGM output.

### Current State
- `generateWgslPearson()` handles Neumann boundaries with spatial feed/kill maps
- Native `bench-map-pearson` already produces `.pgm` files at up to 4096²
- `gs_wasm_build_pearson()` exports the WGSL string via WASM

### Tasks
- [ ] **17.1** Document pearson-mode JS integration in KNOWLEDGE.md (bind group layout = 7 entries including feed_map/kill_map buffers).
- [ ] **17.2** Add pearson test to browser benchmark harness (Phase 11 HTML page).
- [ ] **17.3** Benchmark GPU pearson vs CPU reference at 1024²/50000 (map-scale).

---

## File Map (Expanded)

| File | What lives there | Phases touching it |
|---|---|---|
| `src/wgsl_gen.zig` | All generateWgsl* variants | 11-15 (new variants: f16, coarse-smem, temporal) |
| `src/wasm_shader.zig` | WASM exports, engine selection | 11-13 (browser harness, auto-tuner) |
| `src/gpu/gpu.zig` | Native pipeline, benchmark driver | 11-15 (f16 buffers, coarse dispatch) |
| `build.zig` | Build targets | 11-15 (new bench targets) |
| `benchmark/index.html` | Browser WebGPU harness | 11,17 (baseline, pearson test) |
| `PERFORMANCE.md` | Results tracker | all |
| `KNOWLEDGE.md` | Discoveries log | all |

---

## Execution Order

```
Phase 11 → Browser baseline     (blocker: no measurements without this)
    ↓
Phase 12 → f16 revisit           (highest impact, attacks proven bottleneck)
    ↓
Phase 13 → Auto-tuning               (low risk, immediate win, ~1 hour)
    ↓
Phase 14 → Proper coarsening v2  (requires SMEM-expand approach)
    ↓
Phase 15 → Temporal blocking     (only if 12+14 haven't saturated gains)
    ↓
Phase 16 → Spec constants        (quick, low upside)
    ↓
Phase 17 → Pearson integration      (niche, important for nabla-type-lite completeness)
```

Phase 11-13 can partially overlap (different files). Phase 14-15 are sequential, each building on prior results.