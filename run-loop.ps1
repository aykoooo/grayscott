# ============================================================================
# run-loop.ps1 — Cross-platform GPU Optimization Loop Runner
#
# Wraps opencode with model fallback. Works on Windows/Linux/Mac via pwsh.
# The agent (via .loop-prompt.md) self-manages task advancement within sessions.
#
# Usage:
#   .\run-loop.ps1                  # Start with best model (kimi-k2.6)
#   .\run-loop.ps1 -Model litellm/gemma4  # Use specific model
#   .\run-loop.ps1 -Verbose         # Verbose output
#   .\run-loop.ps1 -Help            # Show help
# ============================================================================

param(
    [string]$Model = "",
    [switch]$Verbose,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host @"
Usage: ./run-loop.ps1 [-Model MODEL] [-Verbose] [-Help]

Options:
  -Model MODEL     Use specific model (default: tries best models in order)
  -Verbose         Enable verbose logging
  -Help            Show this help

Default model chain: kimi-k2.6 → deepseek-v3.2-thinking → gemma4

Examples:
  ./run-loop.ps1                          # Auto-select best available model
  ./run-loop.ps1 -Model litellm/gemma4    # Force lightweight model
  ./run-loop.ps1 -Verbose                 # Verbose mode

How it works:
  1. Verifies zig, git, opencode are available
  2. Tries models in priority order
  3. Runs: opencode run -m MODEL .loop-prompt.md
  4. Agent self-manages tasks from PLAN.md until all done or blocked
"@
    exit 0
}

# Colors
function Write-Info  { Write-Host "ℹ $args" -ForegroundColor Cyan }
function Write-Success { Write-Host "✅ $args" -ForegroundColor Green }
function Write-Warning { Write-Host "⚠️  $args" -ForegroundColor Yellow }
function Write-Error   { Write-Host "❌ $args" -ForegroundColor Red }

# Prerequisites check
function Test-Command { return (Get-Command $args[0] -ErrorAction SilentlyContinue) -ne $null }

$prereqs = @("zig", "git", "opencode")
foreach ($cmd in $prereqs) {
    if (-not (Test-Command $cmd)) {
        Write-Error "$cmd not found in PATH"
        exit 1
    }
}

Set-Location (Split-Path $PSCommandPath -Parent)

# Verify repo state
if (-not (Test-Path "PLAN.md")) {
    Write-Error "PLAN.md not found. Are you in the right directory?"
    exit 1
}

if (-not (Test-Path "vendor/wgpu-native/lib/wgpu_native.dll")) {
    Write-Warning "wgpu_native.dll not found at vendor/wgpu-native/lib/"
    Write-Warning "GPU benchmarks will fail. Re-extract the wgpu-native release."
}

# Quick sanity check
try {
    zig build test 2>&1 | Out-Null
    Write-Success "Tests pass"
} catch {
    Write-Warning "zig build test failed. Fix tests before starting the loop."
}

# Model fallback chain
$models = if ($Model) {
    @($Model)
} else {
    @(
        "litellm/kimi-k2.6",
        "litellm/deepseek-v3.2-thinking",
        "litellm/gemma4"
    )
}

Write-Info "Loop prompt: .loop-prompt.md"
Write-Info "Plan file: PLAN.md"
Write-Info "Remaining tasks:"
$remaining = Select-String -Path "PLAN.md" -Pattern '^- \[ \]' | ForEach-Object { $_.Line }
if ($remaining) {
    $remaining | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
    Write-Info "Total: $($remaining.Count) task(s)"
} else {
    Write-Success "All tasks complete!"
}

Write-Host ""

foreach ($model in $models) {
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  Starting session with: $model" -ForegroundColor Magenta
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""

    # Ping test
    Write-Info "Pinging model $model..."
    try {
        $pingResult = opencode run -m $model "Say hello" 2>&1
        Write-Success "Model $model is responsive"
    } catch {
        Write-Warning "Model $model unavailable. Trying next..."
        continue
    }

    # Run the agent
    Write-Info "Starting agent session..."
    try {
        $ocArgs = @("run", "-m", $model)
        if ($Verbose) { $ocArgs += "--verbose" }
        $ocArgs += ".loop-prompt.md"

        opencode $ocArgs
        Write-Success "Session completed successfully"

        # Check remaining tasks
        $remaining = Select-String -Path "PLAN.md" -Pattern '^- \[ \]' | Measure-Object | Select-Object -ExpandProperty Count
        if ($remaining -eq 0) {
            Write-Success "ALL TASKS COMPLETE!"
        } else {
            Write-Info "$remaining task(s) remaining. Restart loop to continue."
        }
        exit 0
    } catch {
        Write-Warning "Session interrupted or failed with $model"

        # Show recent progress
        Write-Info "Recent commits:"
        git log --oneline -5 2>$null | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }

        Write-Info "Trying fallback model..."
    }
}

Write-Error "All models exhausted."
Write-Host ""
Write-Host "Troubleshooting:" -ForegroundColor Yellow
Write-Host "  1. Check e-infra endpoint: curl https://llm.ai.e-infra.cz/v1/models"
Write-Host "  2. Verify opencode config: cat ~/.config/opencode/opencode.json"
Write-Host "  3. Try a specific model: ./run-loop.ps1 -Model litellm/gemma4"
exit 1