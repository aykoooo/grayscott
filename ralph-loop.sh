#!/bin/bash
# ============================================================================
# ralph-loop.sh v3 — Ralph Wiggum Autonomous Optimizer for OpenCode
#
# Works with YOUR e-infra models via opencode. No Claude API key needed.
# Spawns fresh `opencode run` per iteration. Handles hangs via timeout.
# Keeps our custom benchmark-gated optimization logic.
#
# Known opencode limitations handled:
#   — Exit code always 0 (use git diff + timeout instead)
#   — Risk of process hanging (enforced timeout kills stuck processes)
#   — Tool calls blocked by session presets (--agent agentic bypasses)
#
# Usage:
#   Fresh start:   chmod +x ralph-loop.sh && ./ralph-loop.sh [max_iter]
#   Resume:        ./ralph-loop.sh (auto-detects .ralph/state)
#   Interactive:   install plugin first, then: /ralph-loop "prompt"
# ============================================================================

set -euo pipefail

MAX_ITER=${1:-100}
OPENCODE_AGENT="${RALPH_AGENT:-agentic}"   # agentic=kimi-k2.6, coding=qwen3.5-122b, reasoning=deepseek-v3.2
TIMEOUT_MINUTES=10                          # kill stuck opencode processes
REF_HASH=$(grep '^gpu_256_' BENCHMARK/reference_hashes.txt 2>/dev/null | cut -d'_' -f3 || echo "")
ENSEMBLE_N=3
STAGNATION_WARN=5
STAGNATION_REROUTE=10
STAGNATION_STUCK=15
MIN_SPEEDUP_PCT=1.5

mkdir -p logs .ralph

# ── State persistence ────────────────────────────────────────────────────────
STATE_FILE=".ralph/state"
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    echo "=== RESUMING from iteration $((RALPH_I + 1)) ==="
    echo "   Current phase: $CURRENT_PHASE, Best: $BEST_CELLS cells/sec"
else
    RALPH_I=0; BEST_CELLS=0; BEST_COMMIT=""; STAGNATION_COUNTER=0
    CURRENT_PHASE="A"
    LAST_KNOWN_GOOD_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
fi

save_state() {
    cat > "$STATE_FILE" <<EOF
RALPH_I=$RALPH_I
BEST_CELLS=$BEST_CELLS
STAGNATION_COUNTER=$STAGNATION_COUNTER
CURRENT_PHASE=$CURRENT_PHASE
LAST_KNOWN_GOOD_COMMIT=$LAST_KNOWN_GOOD_COMMIT
EOF
}

benchmark_run() { zig build bench-gpu 2>&1 | grep -oP '\{.*\}' | head -1 || echo ""; }
extract_field() { echo "$1" | grep -oP "\"${2}\":(\d+|\"[^\"]+\")" | grep -oP '(?<=:)(\d+|\"[^\"]+\")' | tr -d '"'; }
median() { printf "%s\n" "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }

touch progress.csv KNOWLEDGE.md cost.csv

echo "=== Ralph Wiggum Optimizer v3 (OpenCode) ==="
echo "Agent:    $OPENCODE_AGENT (opencode run --agent)"
echo "Ref hash: ${REF_HASH:0:16}..."
echo "Timeout:  ${TIMEOUT_MINUTES}m per iteration"
echo "Ensemble: $ENSEMBLE_N runs (median wins)"
echo ""

# ── Main Loop ────────────────────────────────────────────────────────────────

while [ $RALPH_I -lt $MAX_ITER ]; do
    RALPH_I=$((RALPH_I + 1))
    echo "━━━ Iteration $RALPH_I / $MAX_ITER [$CURRENT_PHASE/$STAGNATION_COUNTER stale] ━━━"
    save_state

    # ── Assemble prompt ──────────────────────────────────────────────────────
    GUIDANCE=""
    if [ $STAGNATION_COUNTER -ge $STAGNATION_WARN ] && [ $STAGNATION_COUNTER -lt $STAGNATION_REROUTE ]; then
        GUIDANCE="WARNING: $STAGNATION_COUNTER iterations without improvement. Try RADICALLY DIFFERENT approach."
        echo "stagnation:warn,$(date),$STAGNATION_COUNTER,$CURRENT_PHASE" >> progress.csv
    elif [ $STAGNATION_COUNTER -ge $STAGNATION_REROUTE ] && [ $STAGNATION_COUNTER -lt $STAGNATION_STUCK ]; then
        PHASES=(A B C D E F G H I J K L M N O)
        CURRENT_PHASE=${PHASES[$((RANDOM % ${#PHASES[@]}))]}
        GUIDANCE="FORCED PHASE SWITCH to $CURRENT_PHASE. Previous approach stalled."
        echo "stagnation:reroute,$(date),$STAGNATION_COUNTER,$CURRENT_PHASE" >> progress.csv
    elif [ $STAGNATION_COUNTER -ge $STAGNATION_STUCK ]; then
        echo "HUMAN_INTERVENTION_REQUIRED" > status.md
        save_state
        echo "═══ STUCK after $STAGNATION_COUNTER failures ═══"
        exit 2
    fi

    PROMPT_FILE="logs/prompt_${RALPH_I}.md"
    cat > "$PROMPT_FILE" <<PROMPT_EOF
$(cat RALPH.md)

$GUIDANCE

## Current State
Best: $BEST_CELLS cells/sec | Phase: $CURRENT_PHASE | Stagnation: $STAGNATION_COUNTER

## Knowledge Base
$(tail -30 KNOWLEDGE.md 2>/dev/null || echo "No prior knowledge")

## Recent Results
$(tail -15 progress.csv 2>/dev/null || echo "No prior results")

Make ONE atomic change. Edit minimal files. Commit as "perf:" or "research:".
Do NOT output long explanations at end — just commit your change and stop.
PROMPT_EOF

    # ── Run opencode in headless mode with timeout ───────────────────────────
    echo "  ▶ Running opencode (timeout ${TIMEOUT_MINUTES}m)..."
    AGENT_START=$(date +%s)

    # Capture the prompt into a temp file then pipe it
    OPENCODE_OUTPUT=$(timeout "${TIMEOUT_MINUTES}m" opencode run \
        --agent "$OPENCODE_AGENT" \
        --dangerously-skip-permissions \
        --format json \
        "$(cat "$PROMPT_FILE")" \
        2>&1 || echo "OPENCODE_TIMEOUT")

    AGENT_END=$(date +%s)
    AGENT_DURATION=$((AGENT_END - AGENT_START))

    echo "$OPENCODE_OUTPUT" > "logs/iter_${RALPH_I}_openoutput.log"

    # Check for timeout
    if echo "$OPENCODE_OUTPUT" | grep -q "OPENCODE_TIMEOUT"; then
        echo "  ⚠ TIMEOUT after ${TIMEOUT_MINUTES}m — reverting to last known good state"
        git reset --hard "$LAST_KNOWN_GOOD_COMMIT" > /dev/null 2>&1 || true
        echo "$RALPH_I,$(date),REVERT,timeout,$CURRENT_PHASE" >> progress.csv
        STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
        save_state
        continue
    fi

    echo "${RALPH_I},$(date),${CURRENT_PHASE},done,${AGENT_DURATION}s" >> cost.csv

    # ── Did the agent actually CHANGE anything on disk? ──────────────────────
    if git diff --quiet 2>/dev/null && ! git diff --cached --quiet 2>/dev/null; then
        : # staged changes exist, that's fine
    elif git diff --quiet 2>/dev/null; then
        echo "  ⚠ Warning: agent produced NO file changes"
        # Don't fail — could be a research-only iteration
    fi

    git add -A > /dev/null 2>&1 || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "ralph: iter $RALPH_I (phase $CURRENT_PHASE)" > /dev/null 2>&1 || true
    fi

    # ── Tests must pass ─────────────────────────────────────────────────────
    echo "  ▶ Tests..."
    if ! zig build test > "logs/iter_${RALPH_I}_test.log" 2>&1; then
        echo "  ❌ TESTS FAILED"
        echo "$RALPH_I,$(date),FAIL,tests,$CURRENT_PHASE" >> progress.csv
        git reset --hard HEAD~1 > /dev/null 2>&1 || true
        STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
        save_state
        continue
    fi
    echo "     ✓"

    # ── Ensemble benchmark ──────────────────────────────────────────────────
    echo "  ▶ Benchmark (×$ENSEMBLE_N)..."
    CELLS_SAMPLES=()
    HASH_OK=true
    FIRST_HASH=""
    for run in $(seq 1 $ENSEMBLE_N); do
        JSON=$(benchmark_run)
        if [ -z "$JSON" ]; then HASH_OK=false; break; fi
        CS=$(extract_field "$JSON" "cells_per_second")
        HA=$(extract_field "$JSON" "hash")
        if [ "$run" -eq 1 ]; then FIRST_HASH="$HA"
        elif [ "$HA" != "$FIRST_HASH" ]; then HASH_OK=false; break; fi
        CELLS_SAMPLES+=("$CS")
        echo -n "."
    done
    echo ""

    if [ "$HASH_OK" = false ]; then
        echo "  ❌ BENCHMARK INCONSISTENT — revert"
        git reset --hard HEAD~1 > /dev/null 2>&1 || true
        STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
        save_state
        continue
    fi

    MEDIAN_CELLS=$(median "${CELLS_SAMPLES[@]}")

    # ── Hash correctness check ──────────────────────────────────────────────
    if [ -n "$REF_HASH" ] && [ "$FIRST_HASH" != "$REF_HASH" ]; then
        echo "  ❌ HASH MISMATCH — revert"
        echo "$RALPH_I,$(date),REVERT,hash,$CURRENT_PHASE" >> progress.csv
        echo "### Iter $RALPH_I: HASH MISMATCH — wrong computation" >> KNOWLEDGE.md
        git reset --hard HEAD~1 > /dev/null 2>&1 || true
        STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
        save_state
        continue
    fi
    echo "     ✓ Hash matches"

    # ── Speed check ──────────────────────────────────────────────────────────
    if [ "$MEDIAN_CELLS" -gt "$BEST_CELLS" ] || [ "$BEST_CELLS" -eq 0 ]; then
        IMPROVEMENT=""
        if [ "$BEST_CELLS" -ne 0 ]; then
            PCT=$(awk "BEGIN {printf \"%.1f\", ($MEDIAN_CELLS - $BEST_CELLS) * 100 / $BEST_CELLS}")
            IS_BELOW=$(awk "BEGIN {print ($PCT < $MIN_SPEEDUP_PCT) ? 1 : 0}")
            if [ "$IS_BELOW" -eq 1 ]; then
                echo "  ⚠ Within noise floor (+${PCT}%) — revert"
                echo "$RALPH_I,$(date),REVERT,noise_floor,$CURRENT_PHASE" >> progress.csv
                git reset --hard HEAD~1 > /dev/null 2>&1 || true
                STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
                save_state
                continue
            fi
            IMPROVEMENT=" (+${PCT}%)"
        fi
        echo "  ✅ FASTER: ${MEDIAN_CELLS}${IMPROVEMENT}"
        BEST_CELLS=$MEDIAN_CELLS
        BEST_COMMIT=$(git rev-parse HEAD)
        LAST_KNOWN_GOOD_COMMIT=$BEST_COMMIT
        STAGNATION_COUNTER=0
        echo "$RALPH_I,$(date),KEPT,$MEDIAN_CELLS,$CURRENT_PHASE${IMPROVEMENT}" >> progress.csv
        echo "### Iter $RALPH_I: KEPT at $MEDIAN_CELLS cs${IMPROVEMENT}" >> KNOWLEDGE.md
    else
        echo "  ⚠ Slower/same — revert"
        git reset --hard HEAD~1 > /dev/null 2>&1 || true
        STAGNATION_COUNTER=$((STAGNATION_COUNTER + 1))
    fi

    if [ -f status.md ] && grep -q "OPTIMIZATION_COMPLETE" status.md; then
        echo "═══ OPTIMIZATION COMPLETE ═══"
        echo "Best: $BEST_CELLS cells/sec"
        save_state; exit 0
    fi

    save_state
    sleep 1
done

echo "═══ Max iterations reached ═══"
echo "Best: $BEST_CELLS cells/sec"