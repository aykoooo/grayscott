# Gray-Scott GPU Optimization Plan v2

Status: 2026-05-05 | Baseline: ~1.07B cells/sec (FMA) | Target: >2B cells/sec

## Bottleneck Verdict (confirmed)

**SMEM read latency is the dominant bottleneck.** Proof:
- 5-point stencil (+50%) == FMA 9-point (+44%) in same session → removing SMEM reads directly trades for throughput 1:1
- FMA (+44%) proves compiler wasn't fusing multiply-add → each `a*b+c` cost double rounding before
- All prior failures explained: coarsening (global reads), vec2-global-packing, f16 storage — none touched the actual bottleneck

Implication: **Every SMEM read saved is ~6% throughput gain** (16 reads/cell baseline, 8 reads = 50% gain).

---

## Phase A: Baseline Cleanup (Tier 1 — 25 min)

### A.1 Force FMA into default path
**Problem:** `generateWgsl` in gpu.zig line 211 shows FMA text but `zig build bench-gpu` still reports hash `e16ed0e3...` (non-FMA).
**Action:** Wipe cache, rebuild, verify hash changes to `61720aab...`. If not, diff the compiled WGSL string.
**Benefit:** +44% on all default benchmarks.
**Command:** `rm -r -fo .zig-cache zig-out && zig build bench-gpu`

### A.2 Apply FMA to generateWgslPearson (gpu.zig lines 306-327)
**Problem:** Pearson laplacian uses old `0.2*(a+b+c+d) + 0.05*(e+f+g+h) - u_c` pattern.
**Action:** Replace with `fma(diag, 0.05, fma(card, 0.2, -u_c))` — identical to standard path.
**Benefit:** +44% on Pearson map generation.
**Hash gate:** Will change (algorithmically identical, FP rounding differs).

### A.3 Update NABLA_PLAN.md hash gates
Replace `e16ed0e3...` with `61720aab...` as new sacred hash. Old hash becomes legacy.

---

## Phase B: Instruction Scheduling (Tier 1 — 75 min)

### B.1 Interleave U and V SMEM reads
**Theory:** SMEM latency is ~30 cycles. Back-to-back reads from same array serialize on bank conflicts; alternating between tile_u and tile_v gives the memory subsystem independent address streams to prefetch.
**Action:** Create `generateWgslInterleaved` variant:
```wgsl
// Instead of: all U reads, then all V reads
// Switch to:
let u_l = tile_u[...]; let v_l = tile_v[...];
let u_r = tile_u[...]; let v_r = tile_v[...];
let u_t = tile_u[...]; let v_t = tile_v[...];
let u_b = tile_u[...]; let v_b = tile_v[...];
let card_u = u_l + u_r + u_t + u_b;
let card_v = v_l + v_r + v_t + v_b;
// ... diagonal reads here ...
let lap_u = fma(diag_u, 0.05, fma(card_u, 0.2, -u_c));
```
**Measurement:** Same-session baseline vs interleaved at 256²/500.
**Build target:** `bench-gpu-interleaved`

### B.2 Early partial-sum accumulation
**Theory:** Move computation as close to reads as possible. The compiler can schedule ALU ops in the shadow of pending SMEM loads.
**Action:** Compute `card_u` immediately after the 4 cardinal reads, before loading diagonals. This gives ~20 cycles of ALU work to overlap with diagonal SMEM fetches.
**Combine with B.1** — interleave reads AND accumulate early.

---

## Phase C: Workgroup Shape Tuning (Tier 1 — 45 min)

### C.1 Benchmark grid at multiple shapes
Run same-session comparison of all viable workgroup shapes. Key metric: halo-to-interior cell ratio.

| Shape | Threads | Halo load | Interior | Ratio | Predicted |
|---|---|---|---|---|---|
| 16×4 (current) | 64 | 18×6=108 loads | 64 cells | 1.69 | best so far |
| 8×8 | 64 | 10×10=100 loads | 64 cells | 1.56 | ↓ less halo overhead |
| 4×16 | 64 | 6×18=108 loads | 64 cells | 1.69 | same ratio as 16×4 |
| 32×2 | 64 | 34×4=136 loads | 64 cells | 2.12 | ↑ more halo overhead |
| 8×4 | 32 | 10×6=60 loads | 32 cells | 1.88 | more occupancy |
| 16×8 | 128 | 18×10=180 loads | 128 cells | 1.41 | best ratio? |
| 64×1 | 64 | 66×3=198 loads | 64 cells | 3.09 | terrible ratio |

**Note:** 16×8 requires 180 float SMEM tile → 720 bytes. Well within limit. But occupancy drops with larger WGs.

**Build targets:** `bench-gpu-shape-8x8`, `bench-gpu-shape-16x8`, `bench-gpu-shape-4x16`

### C.2 Per-resolution optimal shape
Smaller resolutions may favor different shapes (more occupancy > fewer halo reads). Bench at 128², 256², 512², 1024².

---

## Phase D: vec2 SMEM Packing Retry (Tier 2 — 60 min)

### D.1 SMEM-only vec2 packing
**What failed before:** `tile_uv: array<vec2<f32>>` for GLOBAL reads = f32→vec2 conversion overhead outweighed bandwidth savings.
**What to try now:** Keep global reads as scalar f32, pack only the shared memory tile as vec2:
```wgsl
var<workgroup> tile_uv: array<vec2<f32>, 108>;
// Load:
tile_uv[ti] = vec2(u_in[idx], v_in[idx]);
// Read neighbors:
let nbr = tile_uv[addr];
let u_nbr = nbr.x;  // free swizzle, no extra SMEM transaction
let v_nbr = nbr.y;
```
**Theory:** Reading one `vec2<f32>` from SMEM may use a single 64-bit transaction instead of two 32-bit ones, halving effective SMEM load count. The previous failure was about the *global* load overhead, not the SMEM benefit.

**Risk:** Bank conflicts may change with wider access stride. Needs benchmark verification.

**Build target:** `bench-gpu-vec2smem`

---

## Phase E: ILP Maximization (Tier 2 — 90 min)

### E.1 Full manual unroll of laplacian
Write the laplacian as explicit operations without intermediate let-bindings, maximizing the compiler's ability to find independent instructions:
```wgsl
let lap_u = fma(
    tile_u[(lid.y)*STRIDE+(lid.x+2u)] + tile_u[(lid.y)*STRIDE+(lid.x)] + 
    tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x)],
    0.05,
    fma(
        tile_u[(lid.y+1u)*STRIDE+(lid.x)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)] +
        tile_u[(lid.y)*STRIDE+(lid.x+1u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)],
        0.2,
        -tile_u[ti]
    )
);
```
This already exists at gpu.zig line 211. Verify current code matches this pattern exactly.

### E.2 Separate U/V computation paths
Compute U laplacian in full, compute reaction term with U while loading V neighbors:
```wgsl
// 1. Load U neighbors, compute lap_u
// 2. Start U reaction math (u_c * v_c * v_c needs v_c which is already in register)
// 3. While those ALU ops execute, load V neighbors
// 4. Compute lap_v
// 5. Combine
```

---

## Phase F: Temporal Blocking (no subgroups) (Tier 3 — 3-6 hours)

### F.1 Two-step fusion via expanded tile + register arrays
Without subgroups, temporal blocking requires:
1. Load (tile+4) × (tile+4) input tile (instead of tile+2) to provide halo for step 2
2. Store step-1 results in per-thread register arrays (8 floats: u0,u1,u2,u3,v0,v1,v2,v3)
3. Barrier after step 1 (all threads have t+1 values in registers)
4. For step 2, read neighborhood from adjacent threads' registered values
   
But WITHOUT subgroups, adjacent threads can't share registers. Alternative:
- Step 1 writes to a second SMEM array (tile_u_t1, tile_v_t1)
- Step 2 reads from this second SMEM array with regular indexing
- Net: saves 1 global read/write at cost of +1 SMEM read/write per cell
- Since SMEM >> global mem speed, this could be net positive

**Algorithm:**
```
// Input tile: (TX+4)×(TY+4) — need extra halo for step 2's dependencies
Load tile_u[tx+4][ty+4], tile_v[tx+4][ty+4] from global → SMEM
Barrier
Step 1: Compute u1, v1 for interior TX×TY cells → store to tile_u_mid/tile_v_mid SMEM
Barrier
Step 2: Load u1_neighbors from tile_u_mid SMEM → compute u2, v2 → write global
```

**Cost model:**
- Normal: load 18×6 global + 16×4 SMEM reads + write 16×4 global
- 2-step temporal: load 20×8 global + 16×4 SMEM (step1) + 18×6 SMEM (step2) + write 16×4 global
- Savings: 1 global read eliminated per step pair
- Cost: extra SMEM capacity (second tile array), extra barrier

**Only worth pursuing if global → SMEM bandwidth is the real limiter.** Currently we think SMEM read latency dominates, making this less promising than direct SMEM-reduction techniques.

---

## Phase G: Advanced Options (Tier 3 — research required)

### G.1 Pipeline constant specialization
WGSL supports `@id()` override constants. Setting WIDTH/HEIGHT as specialization constants instead of module-scope variables:
```wgsl
override WIDTH: u32;
override HEIGHT: u32;
```
This moves width/height from uniform register to immediate constant, reducing register pressure and potentially enabling better instruction scheduling. WebGPU support: `requiredFeatures: ['pipeline-statistics-query']` or via `wgpuComputePassEncoderSetPipeline`.

### G.2 Cooperative matrix multiply (tensor cores)
RTX 4060 has tensor cores. Gray-Scott laplacian is a 3×3 stencil convolution — structurally a matrix multiply. Could use `subgroupMatrixMultiplyAccumulate` if available in WGSL subgroup extension. **Extremely speculative**, likely blocked on WGSL maturity.

### G.3 F16 throughout (revisit)
Previously: f16 storage gave 0% improvement (compute-bound). But with SMEM as proven bottleneck, f16 halves SMEM traffic. Each read is 16 bits instead of 32. On NVIDIA hardware, f16 SMEM has 2× throughput of f32. Worth revisiting with FMA baseline.

### G.4 Prefetch hint instructions
WGSL doesn't have explicit prefetch. But some GPUs detect linear access patterns and auto-prefetch. Structuring global→SMEM loads as contiguous loops helps the hardware prefetcher.

---

## Execution Order

```
A.1 → A.2 → A.3    (25 min)  FIX BASELINE — make FMA default everywhere
  ↓
Verify: tests pass + new hash gate established
  ↓
B.1 → B.2           (75 min)  INSTRUCTION SCHEDULING — interleave + early sum
  ↓
Benchmark: same-session A/B test vs FMA baseline
  ↓
C.1 → C.2           (45 min)  WORKGROUP SHAPE SWEEP
  ↓
Pick best shape, apply to baseline
  ↓
D.1                  (60 min)  VEC2 SMEM PACKING — if still memory-bound
  ↓
E.1 → E.2            (90 min)  ILP MAXIMIZATION — squeeze scheduler
  ↓
Reassess: are we still SMEM bound? If yes →
  ↓
F.1 + G.3            (long)    TEMPORAL BLOCKING + F16 REVISIT
```

### At each checkpoint:
- `zig build test` → must pass
- Same-session baseline vs variant → pick winner
- Document in PERFORMANCE.md
- Mark NABLA_PLAN.md task as [x] or [BLOCKED]

---

## Current Register Pressure Estimate

Per thread (16×4 WG, 9-point stencil):
- Global IDs: lid.x, lid.y, x, y (4 registers)
- Edge flags: x_l, x_r, y_t, y_b (4 registers)
- Tile indices: ti, hi, ci etc (at most 3 live at once)
- Laplacian: u_c, v_c, + 8 neighbor values (max 10 floats → 10 registers)
- Reaction: uvv, u_next, v_next (3 registers)
- Scratch: out_idx (1 register)

Total: ~22 registers. RTX 4060 has 64K registers/SM. With 64 threads/WG, register usage = 22×64 = 1408 regs/WG. Max concurrent WGs = 65536/1408 ≈ 46 WGs → well above max WGs/SM (24). So register pressure is NOT limiting occupancy.

This confirms: **the bottleneck is purely SMEM read latency.** Every optimization should target reducing or hiding SMEM reads.

---

## Quick Wins (today):

1. Force FMA default: `rm -rfo .zig-cache zig-out && zig build bench-gpu` → new hash expected
2. FMA Pearson: edit `generateWgslPearson` lines 314-327 → replace with fma pattern
3. Interleaved reads: create `generateWgslInterleaved` variant → quick benchmark
4. WG shape: add 8×8 and 16×8 build targets → sweep

Estimated total for all 4: ~2 hours, projected cumulative gain: +55-70% over original non-FMA baseline (~1.2-1.3B cells/sec).