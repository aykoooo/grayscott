# How to Run the GPU Optimizer Loop

## Prerequisites

- **Windows** (PowerShell) / **Linux** (bash) / **Mac**
- **Zig** 0.15+ (`zig --version`)
- **opencode** CLI installed (`opencode --version`)
- **git** configured with your user name and email
- **wgpu-native** binaries in `vendor/wgpu-native/` (`.gitignore`d, manually extracted)

## Quick Start

### Windows (PowerShell)
```powershell
cd ~\grayscott
.\run-loop.ps1
```

### Linux / Mac (Git Bash / WSL)
```bash
cd ~/grayscott
./run-ocloop.sh
```

### Manual (any platform, no runner needed)
```bash
opencode run -m litellm/kimi-k2.6 .loop-prompt.md
```
The agent will self-manage tasks from PLAN.md until all done or blocked.

---

## What Happens

Each session, the agent (.loop-prompt.md):

1. **Rapid-start**: Reads PLAN.md, PERFORMANCE.md, KNOWLEDGE.md — identifies the first unchecked task
2. **Researches** (for technique tasks): Web searches, reads articles, writes findings to RESEARCH_NOTES.md
3. **Implements**: Edits src/gpu/gpu.zig, runs zig build, fixes compile errors
4. **Tests**: `zig build test` — must pass
5. **Benchmarks**: Runs 3 times, takes median cells_per_second, verifies hash
6. **Decides**: Keeps if faster, reverts if slower, escalates after 3 failed attempts
7. **Records**: Updates PERFORMANCE.md, KNOWLEDGE.md, commits, marks PLAN.md
8. **Advances**: Moves to next `[ ]` task automatically

## Anti-Stall Protection

- Task fails 3+ times → marked `[BLOCKED]` in PLAN.md, agent moves on
- NEVER infinite-loops on one task
- Blocked tasks documented in KNOWLEDGE.md for later review

## Monitoring Progress

```powershell
# Check remaining tasks
Select-String -Path "PLAN.md" -Pattern '^- \[ \]'

# View latest benchmark results
Get-Content PERFORMANCE.md | Select-Object -Last 20

# Recent commits
git log --oneline -10

# Full loop log (if using ocloop)
cat .loop.log
```

---

## Interrupting

| Action | Effect |
|---|---|
| Press `Ctrl+C` | Stop current agent (commits already made are safe) |
| Restart | Agent picks up from next unchecked task — no progress lost |

---

## Recovery Scenarios

### Agent deleted vendor/ directory
```bash
git reset --hard HEAD    # restore to last working commit
# Re-extract wgpu-native release ZIP if needed
```

### Agent committed bad code (wrong hash, broken benchmark)
```bash
git log --oneline -5              # find last good commit
git reset --hard <good-hash>      # revert to it
```

### Agent stuck on same task repeatedly
```bash
# Manually block it:
(Get-Content PLAN.md) -replace '\[ \] N.X', '[BLOCKED: reason] N.X' | Set-Content PLAN.md
git add PLAN.md && git commit -m "chore: manually block N.X"
# Restart loop — it skips blocked tasks
```

---

## Build Commands Reference

| Command | Description |
|---|---|
| `zig build` | Build everything |
| `zig build test` | Run CPU correctness tests |
| `zig build bench-gpu` | GPU benchmark (256²/500 steps, prints JSON) |
| `zig build bench-gpu-512` | GPU at 512²/500 |
| `zig build bench-gpu-1024` | GPU at 1024²/100 |
| `zig build bench-map` | End-to-end pipeline (256²/5000 steps) |
| `zig build bench-map-512` | Map-bench at 512²/5000 |
| `zig build bench-map-1024` | Map-bench at 1024²/1000 |
| `zig build verify` | CPU reference benchmark |
| `zig build verify-128` | Scale check at 128² |
| `zig build verify-512` | Scale check at 512² |

---

## Files Overview

| File | Purpose |
|---|---|
| `.loop-prompt.md` | Agent brain — injected every session. Self-managing workflow + tools. |
| `PLAN.md` | Task checklist. Agent reads to identify work, marks [x] when done. |
| `PERFORMANCE.md` | Benchmark results with dates, techniques, status. |
| `KNOWLEDGE.md` | Accumulated learning — what worked, what failed, why. |
| `RESEARCH_NOTES.md` | Web research summaries with source URLs. |
| `run-ocloop.sh` | Loop runner for bash/Linux. |
| `run-loop.ps1` | Loop runner for PowerShell/Windows. |
| `src/gpu/gpu.zig` | **Main optimization target** — shader + WebGPU bridge |
| `BENCHMARK/bench_gpu.zig` | GPU benchmark harness |
| `BENCHMARK/bench_map.zig` | End-to-end map benchmark |
| `BENCHMARK/reference_hashes.txt` | Sacred correctness reference — never modify |

---

## Expected Duration

| Phase | Time |
|---|---|
| Research task (web search + reading 2-3 articles) | 5-10 min |
| Implementation + test + benchmark | 5-20 min |
| Parameter sweep (test 5+ variants) | 15-30 min |
| Full remaining work (N.2 + N.3) | ~30-90 min |