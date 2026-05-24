#!/usr/bin/env bash
#
# helm-goldens-check — regenerate goldens for a chart and fail on any diff
# against committed snapshots.
#
#   CHART_PATH=./deployments \
#   GOLDENS_PATH=./deployments/golden \
#   ./check.sh
#
# Layer 1 (within-path):
#   - EKS-Helm path: delegated to `helm unittest <chart-path>` when
#     `<chart-path>/tests/` exists. helm-unittest snapshots live in
#     `<chart-path>/tests/__snapshot__/` and are diffed automatically by the
#     plugin; the snapshot files MUST be committed.
#   - SetupPkg + Helm-EC2 paths: delegated to `<goldens-path>/regenerate.sh`
#     if present. The script must regenerate the per-path .env goldens in
#     place; this action then re-runs `git diff` against `<goldens-path>` and
#     fails on any change.
#
# Layer 2 (cross-path baseline):
#   - Delegated to `<goldens-path>/regenerate-cross-path-baseline.sh` if
#     present. Script must rewrite `<goldens-path>/cross-path-baseline.txt`
#     in place; this action then re-runs `git diff` and fails on any change.
#
# Charts that have not yet committed a regenerate hook can opt out via the
# action's `skip-cross-path` input. Charts with no `tests/` dir yet can opt
# out of helm-unittest via `skip-layer1`.
#
set -euo pipefail

CHART_PATH="${CHART_PATH:-./deployments}"
GOLDENS_PATH="${GOLDENS_PATH:-./deployments/golden}"
SKIP_LAYER1="${SKIP_LAYER1:-false}"
SKIP_CROSS_PATH="${SKIP_CROSS_PATH:-false}"

FAILED=0

fail() {
    FAILED=1
    echo "::error::$1" >&2
}

info() {
    echo "::group::$1"
}

end() {
    echo "::endgroup::"
}

if [[ ! -d "$CHART_PATH" ]]; then
    fail "Chart directory not found: $CHART_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Layer 1 — EKS-Helm path via helm-unittest
# ---------------------------------------------------------------------------
info "Layer 1: helm-unittest (EKS-Helm path)"

if [[ "$SKIP_LAYER1" == "true" ]]; then
    echo "skip-layer1=true → skipping helm-unittest run"
elif [[ ! -d "$CHART_PATH/tests" ]]; then
    fail "$CHART_PATH/tests/ not found — chart must commit helm-unittest tests for Layer 1, or set skip-layer1: true on the action input."
else
    if ! helm unittest "$CHART_PATH"; then
        fail "helm unittest reported a snapshot diff or test failure for $CHART_PATH"
    fi
fi

end

# ---------------------------------------------------------------------------
# Layer 1 — SetupPkg + Helm-EC2 paths via per-chart regenerate hook
# ---------------------------------------------------------------------------
info "Layer 1: per-chart regenerate hook (SetupPkg + Helm-EC2 paths)"

REGENERATE_HOOK="$GOLDENS_PATH/regenerate.sh"
if [[ -x "$REGENERATE_HOOK" ]]; then
    echo "Running $REGENERATE_HOOK"
    if ! bash "$REGENERATE_HOOK"; then
        fail "$REGENERATE_HOOK exited non-zero — regeneration failed before diff"
    else
        # Anything inside <goldens-path> that's now modified means a regression.
        if ! git diff --quiet -- "$GOLDENS_PATH"; then
            fail "Goldens drift in $GOLDENS_PATH after regenerate. Diff:"
            git --no-pager diff --stat -- "$GOLDENS_PATH" >&2 || true
            git --no-pager diff -- "$GOLDENS_PATH" >&2 || true
        else
            echo "No diff against committed goldens in $GOLDENS_PATH"
        fi
    fi
else
    echo "$REGENERATE_HOOK not present — skipping per-chart Layer 1 regenerate."
    echo "(Charts adopting the convention should commit this hook per runbook Step 7.)"
fi

end

# ---------------------------------------------------------------------------
# Layer 2 — cross-path baseline
# ---------------------------------------------------------------------------
info "Layer 2: cross-path baseline diff"

if [[ "$SKIP_CROSS_PATH" == "true" ]]; then
    echo "skip-cross-path=true → skipping cross-path baseline diff"
else
    BASELINE_HOOK="$GOLDENS_PATH/regenerate-cross-path-baseline.sh"
    BASELINE_FILE="$GOLDENS_PATH/cross-path-baseline.txt"
    if [[ ! -f "$BASELINE_FILE" ]]; then
        fail "$BASELINE_FILE not found — chart must commit a cross-path baseline (runbook Step 2), or set skip-cross-path: true."
    elif [[ -x "$BASELINE_HOOK" ]]; then
        echo "Running $BASELINE_HOOK"
        if ! bash "$BASELINE_HOOK"; then
            fail "$BASELINE_HOOK exited non-zero — baseline regeneration failed before diff"
        elif ! git diff --quiet -- "$BASELINE_FILE"; then
            fail "Cross-path baseline drift detected. Diff:"
            git --no-pager diff -- "$BASELINE_FILE" >&2 || true
        else
            echo "Cross-path baseline unchanged."
        fi
    else
        echo "$BASELINE_HOOK not present — verifying committed baseline file only (no fresh regeneration)."
    fi
fi

end

if [[ "$FAILED" -ne 0 ]]; then
    echo "::error::helm-goldens-check: one or more checks failed. See annotations above." >&2
    exit 1
fi

echo "helm-goldens-check: all checks passed for $CHART_PATH"
