{{/*
  Canonical GOMEMLIMIT helper for Go services on Kubernetes (PLAT-5173).

  Copy this block into deployments/templates/_helpers.tpl in Go API repos.
  See helm/snippets/README.md for values.yaml, deployment.yaml, and verification steps.

  Derives GOMEMLIMIT from resources.limits.memory and go.memoryLimitRatio (default 0.85).
  resources.limits.memory must use a Mi suffix (e.g. 256Mi, 3000Mi).
*/}}
{{- define "app.goMemoryLimit" -}}
{{- $memoryLimit := required "resources.limits.memory must be set" .Values.resources.limits.memory | toString -}}
{{- $ratio := .Values.go.memoryLimitRatio | default 0.85 | float64 -}}
{{- if not (hasSuffix "Mi" $memoryLimit) -}}
{{- fail (printf "resources.limits.memory must use Mi suffix for GOMEMLIMIT calculation, got %q" $memoryLimit) -}}
{{- end -}}
{{- $memoryMi := trimSuffix "Mi" $memoryLimit | int -}}
{{- printf "%dMiB" (int (mulf $ratio (float64 $memoryMi))) -}}
{{- end -}}
