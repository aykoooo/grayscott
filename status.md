# Current Status — May 2026

Gray-Scott GPU optimization pipeline is **mature but has remaining work**.

## Performance Summary

| Platform | Throughput | Hash |
|---|---|---|
| Chrome WebGPU | 5.2B cells/sec | `8a39d2ab...` |
| Native (wgpu-native) | 2.35B cells/sec | `e16ed0e3...` (sacred) |
| Firefox WebGL | 2.5B cells/sec | `f8598285...` |
| CPU (ReleaseFast) | ~500M cells/sec | `9760dfcd...` |

Native performance is bottlenecked by 40W VBIOS power cap on RTX 4060 Laptop GPU. Browser WebGPU runs ~3x faster than native on identical hardware.

## Completed

- Shared memory tiling (auto-selected per resolution)
- Command buffer batching (all dispatches in one submit) — single largest win (+1,300%)
- FMA laplacian with early-sum instruction scheduling (+10-17%)
- Dynamic workgroup selection across native + WASM paths
- Pipeline override constants for WIDTH/HEIGHT
- GPU Pearson map generation (up to 4096²)
- Hash-based correctness verification at all resolutions
- Chrome WebGPU browser benchmark with multi-run median statistics
- WebGL vs WebGPU cross-browser characterization (Chrome, Firefox)
- 16x16 SMEM diagnostic, 5-point stencil evaluation, ILP reordering test, subgroup shuffle browser variant

## Remaining Work

| Task | Status |
|---|---|
| Pearson Map Browser Integration (Phase 17) | Undone — docs + browser test + benchmark |
| Coarse SMEM auto-selector (Phase 14.5) | BLOCKED — hash mismatch (`61720aab...` vs sacred) |
| Temporal blocking without subgroups (Phase 15) | Undone — Tier 3 complexity |

## Blocked (Naga/Compiler)

- Subgroups native path — Naga tracking issue #5555 still open
- f16 pipeline — two independent attempts confirm -11% regression
- Coarse+subgroups, temporal blocking with subgroups — depend on Naga subgroups fix

## Documentation

- README.md — updated May 2026 with GPU/browser content
- NABLA_PLAN.md — canonical phase tracking (Phases 0-21)
- KNOWLEDGE.md — 31 iterations of accumulated findings
- PERFORMANCE.md — full benchmark history
