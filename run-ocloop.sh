#!/bin/bash
# ============================================================================
# run-ocloop.sh — Model-fallback wrapper for OCLoop
#
# Tries models in priority order. If one fails (provider error, timeout),
# automatically tries the next.
#
# Usage:
#   ./run-ocloop.sh                  # Start with best model (kimi-k2.6)
#   ./run-ocloop.sh --verbose        # Verbose ocloop logging
#   ./run-ocloop.sh -m litellm/gemma4  # Use a specific model
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")" || exit 1

# Verify prerequisites
check_cmd() { command -v "$1" > /dev/null 2>&1 || { echo "FATAL: $1 not found in PATH"; exit 1; }; }
check_cmd ocloop
check_cmd zig
check_cmd git

# Model priority: best coding → reasoning → fast fallback
DEFAULT_MODELS=(
    "litellm/kimi-k2.6"
    "litellm/deepseek-v3.2-thinking"
    "litellm/gemma4"
)

MODELS=("${DEFAULT_MODELS[@]}")
OCLOOP_ARGS=()

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--model)
            shift
            MODELS=("$1")
            shift
            ;;
        --verbose|-v)
            OCLOOP_ARGS+=("--verbose")
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-m MODEL] [--verbose]"
            echo ""
            echo "Options:"
            echo "  -m MODEL      Use specific model (default: tries best models in order)"
            echo "  --verbose     Enable verbose ocloop logging"
            echo ""
            echo "Examples:"
            echo "  $0                          # Auto-select best available model"
            echo "  $0 -m litellm/gemma4         # Force lightweight model"
            echo "  $0 --verbose                 # Verbose mode with best model"
            exit 0
            ;;
        *)
            OCLOOP_ARGS+=("$1")
            shift
            ;;
    esac
done

# Verify the repo is in a working state
if [ ! -f "PLAN.md" ]; then
    echo "FATAL: PLAN.md not found. Are you in the right directory?"
    exit 1
fi

if [ ! -f "vendor/wgpu-native/lib/wgpu_native.dll" ]; then
    echo "WARNING: wgpu_native.dll not found at vendor/wgpu-native/lib/"
    echo "         The GPU benchmark will fail. Re-extract the wgpu-native release."
fi

# Quick sanity check
if ! zig build test > /dev/null 2>&1; then
    echo "WARNING: zig build test failed. Fix tests before starting the loop."
fi

for model in "${MODELS[@]}"; do
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║  Starting OCLoop                                                        ║"
    echo "║  Model: $model"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Test the model with a quick ping first
    echo "  Pinging model $model..."
    if ! opencode run -m "$model" "Say hello" > /dev/null 2>&1; then
        echo "  ⚠️  Model $model unavailable (provider timeout or error). Skipping."
        continue
    fi
    echo "  ✅ Model $model is responsive."

    # Start ocloop
    echo "  Starting ocloop..."
    if ocloop -r -m "$model" "${OCLOOP_ARGS[@]}"; then
        echo ""
        echo "✅ OCLoop completed successfully."
        exit 0
    fi

    echo ""
    echo "⚠️  OCLoop failed or was interrupted with $model"
    echo "   Checking for partial progress..."

    # Show if any commits were made
    COMMITS=$(git log --oneline -3 2>/dev/null || echo "")
    if [ -n "$COMMITS" ]; then
        echo "   Recent commits:"
        echo "$COMMITS" | sed 's/^/      /'
    fi

    echo "   Trying fallback model..."
done

echo ""
echo "❌ All models exhausted."
echo ""
echo "Troubleshooting:"
echo "  1. Check e-infra endpoint status: curl https://llm.ai.e-infra.cz/v1/models"
echo "  2. Verify your opencode config: cat ~/.config/opencode/opencode.json"
echo "  3. Check network connectivity: ping llm.ai.e-infra.cz"
echo "  4. Try a specific model: $0 -m litellm/gemma4"
exit 1
