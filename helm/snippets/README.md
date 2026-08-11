# Helm snippets — Go memory limits (GOMEMLIMIT)

Platform standard for aligning the Go runtime with Kubernetes cgroup memory limits ([PLAT-5173](https://revolutionparts.atlassian.net/browse/PLAT-5173)).

## When to use

Any **Go service** deployed to EKS with `resources.limits.memory` on the application container. Go auto-detects cgroup CPU limits but **not** memory; without `GOMEMLIMIT`, the kernel may OOM-kill the process instead of the GC throttling heap growth.

**In scope (active services):** `products-api`, `shipments-api`.

**Out of scope:** Deprecated APIs planned for archival (`prices-api`, `suppliers-api`). Argo WorkflowTemplates in `encodium/workflows` use a separate chart — track as a follow-up under [PLAT-5128](https://revolutionparts.atlassian.net/browse/PLAT-5128).

## Install

### 1. `deployments/templates/_helpers.tpl`

Copy the `app.goMemoryLimit` define from [go-gomemlimit.tpl](./go-gomemlimit.tpl) into your chart's `_helpers.tpl`.

### 2. `deployments/values.yaml`

Add (or merge) under top-level chart-control keys:

```yaml
go:
  memoryLimitRatio: 0.85
resources:
  limits:
    memory: "256Mi"   # single source of truth for cgroup + derived GOMEMLIMIT
```

`memoryLimitRatio` defaults to `0.85` (85% of limit). Epic guidance is 80–90%; leave ~10–20% headroom for non-heap memory (DB/Redis client buffers, stacks, OpenTelemetry).

### 3. `deployments/templates/deployment.yaml`

On the **go** application container `env` block:

```yaml
            - name: GOMEMLIMIT
              value: {{ include "app.goMemoryLimit" . | quote }}
```

## Verification

```bash
# Happy path — expect derived value (e.g. 256Mi limit → 217MiB)
helm template <release> deployments/ -f deployments/values.yaml --set image.tag=test | rg -A1 'name: GOMEMLIMIT'

# Custom limit — 512Mi → 435MiB
helm template <release> deployments/ -f deployments/values.yaml \
  --set image.tag=test --set resources.limits.memory=512Mi | rg -A1 'name: GOMEMLIMIT'

# Negative — must fail render
helm template <release> deployments/ -f deployments/values.yaml \
  --set image.tag=test --set resources.limits.memory=null
```

Post-deploy:

```bash
kubectl exec -n api deploy/<service> -- printenv GOMEMLIMIT
```

Datadog (48h soak): `source:oom_kill service:<service-name>`

## Constraints

- `resources.limits.memory` **must** use a `Mi` suffix. `Gi` limits are not supported by this helper; extend locally if needed.
- Do not hardcode `GOMEMLIMIT` — derive from the container limit so limit changes stay in sync.
- `GOMEMLIMIT` aligns runtime GC with the cgroup ceiling; it does **not** replace right-sizing `resources.requests` from Datadog RSS baselines.

## Reference implementations

- [encodium/products-api](https://github.com/encodium/products-api) — [PLAT-5155](https://revolutionparts.atlassian.net/browse/PLAT-5155)
- [encodium/shipments-api](https://github.com/encodium/shipments-api) — [PLAT-5164](https://revolutionparts.atlassian.net/browse/PLAT-5164)

Platform doc: dotfiles `docs/kubernetes/go-memory-limits.md` (served via rp-context).
