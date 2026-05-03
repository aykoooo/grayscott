#!/bin/bash
# ============================================================================
# run-ocloop.sh — Model-fallback wrapper for OCLoop
#
# Tries models in order. If one fails (provider error, timeout),
# automatically tries the next.
#
# Usage:
#   ./run-ocloop.sh              # Start with best model
#   ./run-ocloop.sh --verbose    # Verbose ocloop logging
#   ./run-ocloop.sh -m custom    # Override model chain
# ============================================================================

set -euo pipefail

MODELS=(
    "litellm/kimi-k2.6"
    "litellm/deepseek-v3.2-thinking"
    "litellm/gemma4"
)

# Check for custom model override
if [ "$#" -ge 2 ] && [ "$1" = "-m" ]; then
    MODELS=("$2")
    shift 2
fi

for model in "${MODELS[@]}"; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Starting OCLoop with model: $model"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ocloop -r -m "$model" "$@"; then
        echo ""
        echo "✅ OCLoop completed with $model"
        exit 0
    fi

    echo ""
    echo "⚠️  OCLoop failed or was interrupted with $model"
    echo "   Trying fallback model..."
done

echo ""
echo "❌ All models exhausted. OCLoop could not start or complete."
echo "   Check your network / e-infra endpoint availability."
exit 1
