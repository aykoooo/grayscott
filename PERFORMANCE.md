# GPU Optimization Results

Persistent benchmark tracker. This file survives crashes and restarts.

## Baseline

| Date | Technique | Cells/sec | Improvement | Status |
|---|---|---|---|---|
| 2025-05-03 | Naive GPU (9-point stencil, global mem) | 58,537,062 | — | ✅ Baseline |

## Reference
- GPU hash (256²/500 steps): `e16ed0e3c29cc50b5fa2b42791f31ab00b39d488e971b5d3c6017970ed037a43`
- CPU hash: `9760dfcdb5f49c3bd738ab33afee8be84e56aa31fd2f389cde25faaaeb19bb95`
- Target: >100M cells/sec (2× naive on this Intel iGPU)

## Results Log

<!-- Agent appends new entries here after each task -->
