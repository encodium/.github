#!/usr/bin/env bash
#
# helm-chart-lint — file-name + namespace + template-name linter for the
# org-wide Helm chart convention. Invoked by the helm-chart-lint composite
# action; can also be run locally:
#
#   CHART_PATH=./deployments \
#   RESERVED_KEYS="app budget daemons envConfigMap image ingress ..." \
#   ./lint.sh
#
# Exits non-zero on the first failed rule. Each rule prints its findings to
# stderr with file:line context where applicable.
#
set -euo pipefail

CHART_PATH="${CHART_PATH:-./deployments}"
RESERVED_KEYS="${RESERVED_KEYS:-app budget daemons envConfigMap image imagePullSecrets ingress keda replicas resources serviceAccount serviceAccountName vault}"

# `app` is always implicitly reserved (Rule 5 requires it; the action.yml input
# documents the per-chart list as "in addition to `app`"). Prepend defensively
# so a caller that overrides reserved-chart-control-keys without restating
# `app` does not produce a self-contradicting Rule 5 / Rule 6 failure.
RESERVED_KEYS="app ${RESERVED_KEYS}"

# Convention values-file regex (mirrors guideline §3.1):
#   values.yaml | values-{local,stg,qa,prod,dev-ec2,qa-ec2,prod-ec2}.yaml
#   plus Chart.yaml and the optional values.schema.json.
# Playground overlays (values-pg-*.yaml) are NOT permitted inside the chart dir
# itself — they live alongside playground instances, not in the chart.
VALUES_NAME_RE='^(values\.yaml|values-(local|stg|qa|prod|dev-ec2|qa-ec2|prod-ec2)\.yaml|Chart\.yaml|values\.schema\.json)$'

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

if [[ ! -f "$CHART_PATH/Chart.yaml" ]]; then
    fail "Chart.yaml missing under $CHART_PATH"
    exit 1
fi

if [[ ! -f "$CHART_PATH/values.yaml" ]]; then
    fail "values.yaml missing under $CHART_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Rule 1 — Values file names match the convention
# ---------------------------------------------------------------------------
info "Rule 1: values file names"

# Only direct children of $CHART_PATH; subdirs (templates/, golden/, etc.) and
# files inside them are out of scope for the values-file naming rule.
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    # Skip dotfiles (.helmignore etc.) and README / LICENSE / NOTES.
    case "$base" in
        .*) continue ;;
        README*|LICENSE*|NOTES*|OWNERS*|*.md|*.tgz) continue ;;
    esac
    # Anything not a *.yaml at the chart root is ignored.
    case "$base" in
        *.yaml|*.json) ;;
        *) continue ;;
    esac
    if ! [[ "$base" =~ $VALUES_NAME_RE ]]; then
        fail "Disallowed values file name: $CHART_PATH/$base (does not match $VALUES_NAME_RE)"
    fi
done < <(find "$CHART_PATH" -maxdepth 1 -type f -print0)

end

# ---------------------------------------------------------------------------
# Rule 2 — helm template ./deployments (no -f, no --set) renders cleanly
# ---------------------------------------------------------------------------
info "Rule 2: values.yaml renders cleanly with no overrides"

if ! helm template "$CHART_PATH" >/dev/null 2>/tmp/helm-render.err; then
    fail "helm template $CHART_PATH FAILED with no overrides — values.yaml must render cleanly."
    sed 's/^/    /' /tmp/helm-render.err >&2
fi

end

# ---------------------------------------------------------------------------
# Rule 3 — Template filenames: no env-file.yaml; require env-configmap.yaml
#          shape for the env-file ConfigMap. Other templates' kinds must
#          match their filename slug.
# ---------------------------------------------------------------------------
info "Rule 3: template filenames"

if [[ -d "$CHART_PATH/templates" ]]; then
    if [[ -f "$CHART_PATH/templates/env-file.yaml" ]]; then
        fail "templates/env-file.yaml must be renamed to templates/env-configmap.yaml (per convention §2 / template-naming rule)"
    fi
fi

end

# ---------------------------------------------------------------------------
# Rule 4 — No top-level `topo:` key in any values file
# ---------------------------------------------------------------------------
info "Rule 4: forbidden .topo namespace"

while IFS= read -r -d '' f; do
    # `yq e '.topo' file` returns "null" if the key is absent. Any other value
    # (including `{}`) means the key is present.
    val="$(yq e '.topo // "__ABSENT__"' "$f" 2>/dev/null || echo "__ABSENT__")"
    if [[ "$val" != "__ABSENT__" ]]; then
        line="$(grep -nE '^topo:' "$f" | head -n1 | cut -d: -f1 || true)"
        fail "$f${line:+:$line}: top-level \`topo:\` key is forbidden — collapse into \`.Values.app\`."
    fi
done < <(find "$CHART_PATH" -maxdepth 1 -type f -name 'values*.yaml' -print0)

end

# ---------------------------------------------------------------------------
# Rule 5 — Mandatory `.app` namespace in values.yaml
# ---------------------------------------------------------------------------
info "Rule 5: mandatory .app namespace"

app_type="$(yq e '.app | tag' "$CHART_PATH/values.yaml" 2>/dev/null || echo '!!null')"
if [[ "$app_type" == "!!null" ]]; then
    fail "$CHART_PATH/values.yaml: \`app:\` namespace is missing. Charts with no app config must declare \`app: {}\` explicitly."
elif [[ "$app_type" != "!!map" ]]; then
    fail "$CHART_PATH/values.yaml: \`app:\` must be a map (got $app_type)."
fi

end

# ---------------------------------------------------------------------------
# Rule 6 — No top-level non-reserved namespaces in any values file
# ---------------------------------------------------------------------------
info "Rule 6: top-level keys are reserved chart-control keys"

# Normalize reserved list to a newline-separated set for grep -Fxqf.
# `|| true` keeps the pipeline alive under `pipefail` when no lines survive
# the filter (e.g. caller passed an empty RESERVED_KEYS) — Rule 6 then fires
# loudly on every top-level key instead of the script dying silently.
RESERVED_FILE="$(mktemp)"
echo "$RESERVED_KEYS" | tr -s '[:space:]' '\n' | { grep -v '^$' || true; } | sort -u > "$RESERVED_FILE"

while IFS= read -r -d '' f; do
    # Top-level keys only. yq returns one key per line.
    keys="$(yq e 'keys | .[]' "$f" 2>/dev/null || true)"
    if [[ -z "$keys" ]]; then
        continue
    fi
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        if ! grep -Fxq "$k" "$RESERVED_FILE"; then
            line="$(grep -nE "^${k}:" "$f" | head -n1 | cut -d: -f1 || true)"
            fail "$f${line:+:$line}: top-level key \`${k}:\` is not in the reserved chart-control set. Move env-producing keys under \`.app\` or extend reserved-chart-control-keys."
        fi
    done <<< "$keys"
done < <(find "$CHART_PATH" -maxdepth 1 -type f -name 'values*.yaml' -print0)

rm -f "$RESERVED_FILE"

end

# ---------------------------------------------------------------------------
# Rule 7 — No `if .Values.<unapproved-key>` render gates in templates
# ---------------------------------------------------------------------------
info "Rule 7: render gates use approved chart-control keys"

if [[ -d "$CHART_PATH/templates" ]]; then
    # Scan every templates/*.yaml (and .tpl) for `if .Values.X` or `with .Values.X`
    # where X is the first dotted segment.
    RESERVED_LIST="$(mktemp)"
    echo "$RESERVED_KEYS" | tr -s '[:space:]' '\n' | { grep -v '^$' || true; } > "$RESERVED_LIST"

    # Match `{{ if .Values.X }}`, `{{ with .Values.X }}`, `{{ else if .Values.X }}`,
    # and `{{ else with .Values.X }}` — all four are render-gate forms whose root
    # key must be in the reserved chart-control set. `else` alone (no following
    # if/with) has no condition and is intentionally not matched.
    DIRECTIVE_RE='(else[[:space:]]+)?(if|with)[[:space:]]+(\(?[[:space:]]*not[[:space:]]+)?\.Values\.'
    LINE_RE="\\{\\{-?[[:space:]]*${DIRECTIVE_RE}"

    while IFS= read -r -d '' tmpl; do
        # grep returns lines like LINE:CONTENT (single file, no filename prefix).
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            line="${hit%%:*}"
            content="${hit#*:}"
            # Extract just the matched root key — the first dotted segment after
            # `.Values.` in the directive.
            root="$(echo "$content" | grep -oE "${DIRECTIVE_RE}[A-Za-z_][A-Za-z0-9_]*" \
                | head -n1 \
                | grep -oE '\.Values\.[A-Za-z_][A-Za-z0-9_]*' \
                | sed 's/^\.Values\.//')"
            if [[ -z "$root" ]]; then
                continue
            fi
            if ! grep -Fxq "$root" "$RESERVED_LIST"; then
                fail "${tmpl}:${line}: render gate \`.Values.${root}\` is not an approved chart-control key. Use a per-resource \`.<resource>.enabled\` flag (e.g. \`.envConfigMap.enabled\`)."
            fi
        done < <(grep -nE "$LINE_RE" "$tmpl" || true)
    done < <(find "$CHART_PATH/templates" -type f \( -name '*.yaml' -o -name '*.tpl' \) -print0)

    rm -f "$RESERVED_LIST"
fi

end

if [[ "$FAILED" -ne 0 ]]; then
    echo "::error::helm-chart-lint: one or more rules failed. See annotations above." >&2
    exit 1
fi

echo "helm-chart-lint: all rules passed for $CHART_PATH"
