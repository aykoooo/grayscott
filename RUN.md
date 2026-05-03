# How to Run the OCLoop GPU Optimizer

## Prerequisites

- **Windows** with Git Bash / MINGW64
- **Zig** 0.15+ (`zig --version`)
- **opencode** CLI installed (`opencode --version`)
- **ocloop** installed (`ocloop --version`) — `npm install -g ocloop` or `bun add -g ocloop`
- **wgpu-native** binaries in `vendor/wgpu-native/` (`.gitignore`d, manually extracted)
- **git** configured with your user name and email

## Quick Start

```bash
# 1. Open a terminal (Git Bash, MINGW64)
# 2. cd to the project
cd ~/grayscott

# 3. Quick sanity checks
zig build bench-gpu    # should output JSON with cells_per_second
zig build test         # should pass silently

# 4. Start the loop
./run-ocloop.sh
```

That's it. The loop runs autonomously.

## What Happens

### Iteration 1 (Task B.1 — Research shared memory tiling)

1. **OCLoop** spawns `opencode run -m litellm/kimi-k2.6 .loop-prompt.md`
2. **Agent** reads `.loop-prompt.md` → learns workflow + tools
3. **Agent** reads `PLAN.md` → sees task B.1 is first unchecked
4. **Agent** uses **web search** to find "WGSL shared memory compute shader"
5. **Agent** reads 2-3 sources, writes findings to `RESEARCH_NOTES.md`
6. **Agent** outputs `<promise>DONE</promise>`
7. **OCLoop** marks task `[x]`, moves to B.2

### Iteration 2 (Task B.2 — Implement shared memory tiling)

1. **Agent** reads current `src/gpu/gpu.zig`
2. **Agent** edits `generateWgsl()` to add `var<workgroup> tile_u`
3. **Agent** runs `zig build` → catches compile errors, fixes them
4. **Agent** runs `zig build test` → ✅ passes
5. **Agent** runs `zig build bench-gpu` 3×:
   ```
   {"cells_per_second":75390211,"hash":"e16ed0e3c29cc50b..."}
   {"cells_per_second":74829104,"hash":"e16ed0e3c29cc50b..."}
   {"cells_per_second":76123455,"hash":"e16ed0e3c29cc50b..."}
   ```
6. **Agent** verifies hash matches ✅
7. **Agent** compares median (75.3M) to baseline (58.5M) → +28.7% ✅
8. **Agent** records to `PERFORMANCE.md`, commits:
   ```bash
   git add -A
   git commit -m "perf(gpu): shared memory tile 16x16 (+28.7% to 75.3M cells/sec)"
   ```
9. **Agent** appends to `KNOWLEDGE.md`:
   ```
   ### Shared memory tile 16x16
   +28.7% from 58M to 75M. Requires workgroupBarrier() after loads.
   Key: load global → workgroupBarrier → compute → write global.
   ```
10. **Agent** marks task `[x]` in `PLAN.md`
11. **Agent** outputs `<promise>DONE</promise>`
12. **OCLoop** advances to B.3

## Monitoring Progress

In a **second terminal**:

```bash
# Watch the loop state
tail -f .loop.log          # ocloop verbose log (if --verbose)

tail -f PERFORMANCE.md     # latest benchmark results
tail -f RESEARCH_NOTES.md  # research findings
tail -f PLAN.md            # task progress

# Watch git history
git log --oneline --graph --all

# Check current task
grep "^- \[ \]" PLAN.md | head -1
```

## Interrupting

| What you want | How |
|---|---|
| **Pause temporarily** | Press `Q` in ocloop TUI, or `Ctrl+C` |
| **Resume after pause** | Run `./run-ocloop.sh` again — ocloop will continue from the next unchecked task |
| **Stop forever** | `Ctrl+C` twice, or close the terminal |
| **Kill a stuck agent** | `Ctrl+C` in the terminal running `./run-ocloop.sh` |

## Recovery Scenarios

### Scenario 1: Model provider is down
```bash
# Auto-fallback happens automatically in ./run-ocloop.sh:
# kimi-k2.6 → deepseek-v3.2-thinking → gemma4
# If all fail, the script prints troubleshooting steps.
```

### Scenario 2: Agent deleted vendor/ directory
```bash
# WGPU benchmark fails with "wgpu_native.dll not found"
# Fix:
git reset --hard HEAD    # restore to last working commit
# Re-extract vendor if needed:
# unzip wgpu-windows-x86_64-release.zip -d vendor/
```

### Scenario 3: Agent committed bad code
```bash
# If benchmark crashes or hash is wrong:
git log --oneline -5    # find last good commit
git reset --hard <hash> # revert to it
```

### Scenario 4: LOOP got stuck on one task forever
```bash
# Manually mark it blocked in PLAN.md:
sed -i 's/\[ \] \*\*B.2\*\*/[BLOCKED: shared mem crashes device] **B.2**/' PLAN.md
git add PLAN.md && git commit -m "chore: mark B.2 blocked"
# Restart ocloop — it will skip blocked tasks
./run-ocloop.sh
```

## Using Specific Models

```bash
# Best coding model (default)
./run-ocloop.sh

# Force reasoning model
./run-ocloop.sh -m litellm/deepseek-v3.2-thinking

# Fast/cheap model for simple tasks
./run-ocloop.sh -m litellm/gemma4

# Debug with verbose output
./run-ocloop.sh --verbose
```

## Full Command Reference

| Command | Description |
|---|---|
| `zig build` | Build everything |
| `zig build test` | Run CPU correctness tests |
| `zig build bench-gpu` | Run GPU benchmark (prints JSON) |
| `zig build verify` | CPU reference benchmark |
| `zig build verify-128` | Scale check at 128² |
| `zig build verify-512` | Scale check at 512² |
| `./run-ocloop.sh` | Start the autonomous loop |
| `./run-ocloop.sh -m MODEL` | Start with specific model |
| `./run-ocloop.sh --verbose` | Verbose logging |
| `ocloop -r -m MODEL` | Start ocloop directly |
| `ocloop --help` | OCLoop help |

## Expected Duration

| Task Type | Time |
|---|---|
| Research task (web search, reading) | 10-20 min |
| Implementation task (edit, build, test) | 15-40 min |
| Benchmark sweep (test 5-8 variants) | 20-30 min |
| Revert + retry cycle | 5-10 min |
| **Full plan (all tasks)** | **4-12 hours** |

## Important Files

| File | Purpose |
|---|---|
| `PLAN.md` | Task list — the agent reads this to know what to do |
| `.loop-prompt.md` | Instructions injected every session — workflow + tools |
| `PERFORMANCE.md` | Benchmark results — human checks this for progress |
| `KNOWLEDGE.md` | Accumulated learnings — persists across sessions |
| `RESEARCH_NOTES.md` | Web research summaries |
| `run-ocloop.sh` | Wrapper with model fallback |
| `src/gpu/gpu.zig` | **Main file to optimize** — shader + WebGPU bridge |
| `BENCHMARK/bench_gpu.zig` | Benchmark harness |
| `BENCHMARK/reference_hashes.txt` | Sacred correctness reference |
| `build.zig` | Compilation settings |
| `.gitignore` | Ignores `.loop.log`, build artifacts, vendor/ |

## When It's Done

The loop stops when either:
1. All tasks in `PLAN.md` are `[x]` — ocloop detects all done
2. The agent writes `<plan-complete>` or `<promise>DONE</promise>` with no more tasks
3. You press `Q` or `Ctrl+C`

After completion, check:
```bash
git log --oneline --graph  # see all accepted optimizations
cat PERFORMANCE.md          # see performance history
cat KNOWLEDGE.md            # see what worked
```
