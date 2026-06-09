# Unify PHP Build Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the copy-pasted per-repo `Build.yaml` across 9 PHP services with two shared reusable orchestrators in `encodium/.github`, so fleet-wide build changes happen in one place.

**Architecture:** Two reusable workflows — `build-php-v1.yaml` (matrix over the generic `php-build-push.yaml`, one call per image) and `build-php-laravel.yaml` (wraps `php-laravel-build-push.yaml`, artisan-cached). Both implement the spine `calculate-tag → build → tag-and-release` and expose a `tag` output. The deploy job stays in each repo's thin caller, because a reusable workflow cannot reference the caller's local `./.github/workflows/...` deploy file.

**Tech Stack:** GitHub Actions reusable workflows (`workflow_call`), `docker/build-push-action`, `mathieudutour/github-tag-action`, `ncipollo/release-action`, `ghcr.io`.

**Spec:** `docs/superpowers/specs/2026-06-08-unify-php-build-workflows-design.md`
**Tickets:** DEVEX-1630 (this plan); DEVEX-1629 (Phase 0 gate, separate, lands first).

---

## How "tests" work here

There is no unit-test harness for workflows. Each change is verified by:
1. **Static lint** — the repo's `action-lint.yml` / `actionlint` catches schema errors.
2. **Real run** — trigger via `gh workflow run` and inspect the result with `gh run view`.
3. **Tag-fidelity diff** — after a build run, list the pushed image tags and confirm they
   **exactly match** the baseline tags the old `Build.yaml` produced.

Reusable workflows are referenced by git ref. During development, callers reference the
orchestrator on the feature branch (`@DEVEX-1630-unify-php-build-workflows`); after the
shared-workflow PR merges to `main`, callers are flipped to `@main`.

**Baseline capture (do once, before any change):** for each repo, record the current image
tags so you can diff later.

```bash
for r in rp_api internal_api catalog_api license_api radmin webstore returns-api accounts-api vin_decoder_service; do
  echo "== $r =="; gh api "repos/encodium/$r/packages/container/$r/versions" --jq '.[0:3][].metadata.container.tags' 2>/dev/null
done
```

---

## File Structure

**`encodium/.github` (shared, merged first):**
- Modify: `.github/workflows/php-build-push.yaml` — add `image_name`, `extra_tag`, `cache_type` inputs; bump action versions.
- Create: `.github/workflows/build-php-v1.yaml` — v1 orchestrator.
- Create: `.github/workflows/build-php-laravel.yaml` — Laravel orchestrator.

**Per service repo (one PR each):**
- Modify: `.github/workflows/Build.yaml` (or `build.yaml`) — collapse to thin caller + preserved deploy job.

---

## Phase 0 — Integration deploy gate (DEVEX-1629, ships first)

> Tracked under DEVEX-1629. Included here because it is the prerequisite and the gated job
> is what survives into the Phase 1 thin caller. If DEVEX-1629 is already merged, skip.

Affected (integration-deploying repos): rp_api, catalog_api, internal_api, license_api,
returns-api, accounts-api, webstore. (radmin, vin_decoder_service deploy to staging — not
gated here.)

### Task 0.1: Gate each integration-deploy job

**Files:** Modify `.github/workflows/Build.yaml` (lowercase `build.yaml` for accounts-api) in each of the 7 repos.

- [ ] **Step 1: Add the trigger gate.** In each repo's `integration-deploy` job, add the
  `if:` line directly under the job key:

```yaml
  integration-deploy:
    if: ${{ github.event_name == 'push' }}
    # ...rest unchanged...
```

- [ ] **Step 2: Lint.** Run `actionlint .github/workflows/Build.yaml` (no errors).

- [ ] **Step 3: Verify dispatch skips deploy.** Trigger a build via dispatch and confirm the
  deploy job is skipped:

```bash
gh workflow run "Build.yaml" --repo encodium/<repo> --ref main
# wait, then:
gh run view <run-id> --repo encodium/<repo> --json jobs --jq '.jobs[] | {name,conclusion}'
# Expected: integration-deploy → "skipped"
```

- [ ] **Step 4: Commit (per repo, on a branch, PR per CLAUDE.md).**

```bash
git commit -am "fix: gate integration deploy to push events (DEVEX-1629)"
```

---

## Phase 1A — Shared workflow foundation (`encodium/.github`)

Work on branch `DEVEX-1630-unify-php-build-workflows`.

### Task 1: Find existing consumers of `php-build-push.yaml`

**Files:** none (investigation).

- [ ] **Step 1: Grep the org for callers** so the modernization stays backward-compatible.

```bash
gh search code --owner encodium "php-build-push.yaml@" 2>/dev/null
```

Expected: note every caller. The changes in Task 2 are additive (new optional inputs with
defaults) + version bumps, so existing callers keep working. `cache_type` defaults to the
**current** value (`registry`) to avoid changing their behavior; only our new orchestrator
passes `gha`.

### Task 2: Modernize `php-build-push.yaml`

**Files:** Modify `.github/workflows/php-build-push.yaml`.

- [ ] **Step 1: Add inputs.** Under `on.workflow_call.inputs`, add (all optional; `image_name`
  defaults to empty and is resolved to `github.repository` inside the job, since
  expressions are not allowed in input defaults):

```yaml
      image_name:
        description: "Image repo path override for separate images, e.g. <repo>-profiler. Empty = github.repository."
        required: false
        type: string
        default: ""
      extra_tag:
        description: "Optional companion tag to also push (e.g. latest, nginx-latest)."
        required: false
        type: string
        default: ""
      cache_type:
        description: "Buildx cache backend: gha or registry."
        required: false
        type: string
        default: "registry"
```

- [ ] **Step 2: Replace the build job env + build step.** Resolve `image_name`, build a tags
  list including the optional `extra_tag`, choose the cache backend. Replace the
  `Docker Build and Push App` step and its surrounding `setup-buildx`/`login` with:

```yaml
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.gh_token }}
      - name: Resolve image name and tags
        id: meta
        env:
          IMAGE_NAME_INPUT: ${{ inputs.image_name }}
          DEFAULT_IMAGE: ghcr.io/${{ github.repository }}
          TAG: ${{ inputs.tag }}
          EXTRA: ${{ inputs.extra_tag }}
        run: |
          name="$IMAGE_NAME_INPUT"; [ -z "$name" ] && name="${{ github.repository }}"
          ref="ghcr.io/${name}"
          tags="${ref}:${TAG}"
          [ -n "$EXTRA" ] && tags="${tags},${ref}:${EXTRA}"
          echo "tags=${tags}" >> "$GITHUB_OUTPUT"
      - name: Docker Build and Push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ inputs.dockerfile }}
          push: true
          platforms: linux/amd64
          target: ${{ inputs.build_target }}
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: ${{ inputs.cache_type == 'gha' && 'type=gha' || format('type=registry,ref=ghcr.io/{0}:buildcache', github.repository) }}
          cache-to: ${{ inputs.cache_type == 'gha' && 'type=gha,mode=max' || format('type=registry,ref=ghcr.io/{0}:buildcache,mode=max', github.repository) }}
```

> `build_target` may be empty (proxy/nginx images have no named stage). `build-push-action`
> treats an empty `target:` as unset — validated on the license_api pilot (Task 5).

- [ ] **Step 3: Lint.** `actionlint .github/workflows/php-build-push.yaml` → no errors.

- [ ] **Step 4: Commit.**

```bash
git add .github/workflows/php-build-push.yaml
git commit -m "feat: add image_name/extra_tag/cache_type inputs to php-build-push, modernize actions"
```

### Task 3: Create `build-php-v1.yaml`

**Files:** Create `.github/workflows/build-php-v1.yaml`.

- [ ] **Step 1: Write the orchestrator.**

```yaml
name: Build PHP (v1)
on:
  workflow_call:
    inputs:
      images:
        description: 'JSON array of {image_name?, dockerfile, target?, tag_prefix, extra_tag}'
        required: true
        type: string
      php_version:
        required: false
        type: string
        default: "8.3"
      release_branches:
        required: false
        type: string
        default: "stage,hotfix,rc"
      cache_type:
        required: false
        type: string
        default: "gha"
    secrets:
      packagist_username: { required: true }
      packagist_password: { required: true }
      gh_token: { required: true }
    outputs:
      tag:
        description: "The released tag"
        value: ${{ jobs.tag-and-release.outputs.tag }}

jobs:
  calculate-tag:
    name: Calculate Build Tag
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.dry_tag_version.outputs.new_tag }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - id: dry_tag_version
        uses: mathieudutour/github-tag-action@v6.1
        with:
          github_token: ${{ secrets.gh_token }}
          release_branches: ${{ inputs.release_branches }}
          fetch_all_tags: true
          dry_run: true

  build:
    name: Build ${{ matrix.image.tag_prefix }}image
    needs: [calculate-tag]
    strategy:
      matrix:
        image: ${{ fromJSON(inputs.images) }}
    uses: ./.github/workflows/php-build-push.yaml   # local path: nested call resolves at the orchestrator's own ref
    with:
      php_version: ${{ inputs.php_version }}
      image_name: ${{ matrix.image.image_name }}
      dockerfile: ${{ matrix.image.dockerfile }}
      build_target: ${{ matrix.image.target }}
      tag: ${{ matrix.image.tag_prefix }}${{ needs.calculate-tag.outputs.tag }}
      extra_tag: ${{ matrix.image.extra_tag }}
      cache_type: ${{ inputs.cache_type }}
    secrets:
      packagist_username: ${{ secrets.packagist_username }}
      packagist_password: ${{ secrets.packagist_password }}
      gh_token: ${{ secrets.gh_token }}

  tag-and-release:
    name: Github Tag and Release
    needs: [build]
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.tag_version.outputs.new_tag }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - id: tag_version
        uses: mathieudutour/github-tag-action@v6.1
        with:
          github_token: ${{ secrets.gh_token }}
          release_branches: ${{ inputs.release_branches }}
          fetch_all_tags: true
      - uses: ncipollo/release-action@v1
        with:
          tag: ${{ steps.tag_version.outputs.new_tag }}
          name: Prerelease ${{ steps.tag_version.outputs.new_tag }}
          body: ${{ steps.tag_version.outputs.changelog }}
          prerelease: true
```

> The matrix `image_name` is empty for app/nginx/apache (php-build-push falls back to
> `github.repository`) and `<repo>-profiler` for the profiler image. `target` is empty for
> nginx/apache.

- [ ] **Step 2: Lint.** `actionlint .github/workflows/build-php-v1.yaml` → no errors.

- [ ] **Step 3: Commit.**

```bash
git add .github/workflows/build-php-v1.yaml
git commit -m "feat: add build-php-v1 reusable orchestrator"
```

### Task 4: Create `build-php-laravel.yaml`

**Files:** Create `.github/workflows/build-php-laravel.yaml`.

- [ ] **Step 1: Write the orchestrator** (wraps the existing Laravel build helper).

```yaml
name: Build PHP (Laravel)
on:
  workflow_call:
    inputs:
      php_version:
        required: false
        type: string
        default: "8.3"
      php_extensions:
        required: false
        type: string
        default: "bcmath intl gd"
      build_cli_image:
        required: false
        type: boolean
        default: false
      dockerfile_app_path:
        required: false
        type: string
        default: "./build/Dockerfile-app"
      dockerfile_webserver_path:
        required: false
        type: string
        default: "./build/Dockerfile-nginx"
      dockerfile_cli_path:
        required: false
        type: string
        default: "./build/Dockerfile-cli"
      release_branches:
        required: false
        type: string
        default: "stage,hotfix,rc"
    secrets:
      packagist_username: { required: true }
      packagist_password: { required: true }
      gh_token: { required: true }
    outputs:
      tag:
        value: ${{ jobs.tag-and-release.outputs.tag }}

jobs:
  calculate-tag:
    name: Calculate Build Tag
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.dry_tag_version.outputs.new_tag }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - id: dry_tag_version
        uses: mathieudutour/github-tag-action@v6.1
        with:
          github_token: ${{ secrets.gh_token }}
          release_branches: ${{ inputs.release_branches }}
          fetch_all_tags: true
          dry_run: true

  build:
    needs: [calculate-tag]
    uses: ./.github/workflows/php-laravel-build-push.yaml   # local path: nested call resolves at the orchestrator's own ref
    with:
      php_version: ${{ inputs.php_version }}
      php_extensions: ${{ inputs.php_extensions }}
      build_app_image: true
      build_webserver_image: true
      build_cli_image: ${{ inputs.build_cli_image }}
      dockerfile_app_path: ${{ inputs.dockerfile_app_path }}
      dockerfile_webserver_path: ${{ inputs.dockerfile_webserver_path }}
      dockerfile_cli_path: ${{ inputs.dockerfile_cli_path }}
      new_tag: ${{ needs.calculate-tag.outputs.tag }}
    secrets:
      packagist_username: ${{ secrets.packagist_username }}
      packagist_password: ${{ secrets.packagist_password }}
      gh_token: ${{ secrets.gh_token }}

  tag-and-release:
    name: Github Tag and Release
    needs: [build]
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.tag_version.outputs.new_tag }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - id: tag_version
        uses: mathieudutour/github-tag-action@v6.1
        with:
          github_token: ${{ secrets.gh_token }}
          release_branches: ${{ inputs.release_branches }}
          fetch_all_tags: true
      - uses: ncipollo/release-action@v1
        with:
          tag: ${{ steps.tag_version.outputs.new_tag }}
          name: Prerelease ${{ steps.tag_version.outputs.new_tag }}
          body: ${{ steps.tag_version.outputs.changelog }}
          prerelease: true
```

> The Laravel helper publishes the webserver image as `webserver-<tag>`. returns-api and
> vin_decoder_service currently publish `nginx-<tag>`; their deploy/helm values are updated
> to consume `webserver-` in Tasks 6 and 11 (per spec decision to standardize).

- [ ] **Step 2: Lint.** `actionlint .github/workflows/build-php-laravel.yaml` → no errors.

- [ ] **Step 3: Commit, push the branch, open the shared-workflow PR.**

```bash
git add .github/workflows/build-php-laravel.yaml
git commit -m "feat: add build-php-laravel reusable orchestrator"
git push -u origin DEVEX-1630-unify-php-build-workflows
gh pr create --repo encodium/.github --draft --base main \
  --title "DEVEX-1630: shared PHP build orchestrators" \
  --body "Adds build-php-v1 + build-php-laravel and modernizes php-build-push. See docs/superpowers/specs/2026-06-08-unify-php-build-workflows-design.md"
```

---

## Phase 1B — Pilots (validate before fan-out)

Pilots reference the orchestrator on the **feature branch** until the foundation PR merges.

### Task 5: Pilot v1 — license_api

**Files:** Modify `license_api/.github/workflows/Build.yaml`.

- [ ] **Step 1: Replace the whole file with the thin caller.** (license_api builds app + nginx, no profiler.)

```yaml
name: Build
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-v1.yaml@DEVEX-1630-unify-php-build-workflows
    with:
      images: >-
        [
          {"image_name":"","dockerfile":"./build/app/Dockerfile","target":"app","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"","dockerfile":"./build/nginx/Dockerfile","target":"","tag_prefix":"nginx-","extra_tag":"nginx-latest"}
        ]
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  integration-deploy:
    name: Deploy to Integration
    if: ${{ github.event_name == 'push' }}
    needs: [build]
    uses: ./.github/workflows/Integration EKS Deploy.yaml
    with:
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```

- [ ] **Step 2: Lint.** `actionlint .github/workflows/Build.yaml` → no errors.

- [ ] **Step 3: Trigger a dispatch build and verify.**

```bash
gh workflow run "Build.yaml" --repo encodium/license_api --ref <pilot-branch>
gh run view <run-id> --repo encodium/license_api --json jobs --jq '.jobs[] | {name,conclusion}'
```
Expected: `calculate-tag`, both `build` matrix legs, `tag-and-release` succeed;
`integration-deploy` **skipped** (dispatch).

- [ ] **Step 4: Tag-fidelity diff.** Confirm the new package versions carry exactly
  `:<tag>`, `:latest`, `:nginx-<tag>`, `:nginx-latest` — identical shape to the baseline
  captured earlier. **This validates the empty-`target` nginx build.**

```bash
gh api repos/encodium/license_api/packages/container/license_api/versions --jq '.[0].metadata.container.tags'
```

- [ ] **Step 5: Commit on a branch, open draft PR.**

```bash
git commit -am "DEVEX-1630: migrate Build.yaml to shared build-php-v1 orchestrator"
```

### Task 6: Pilot Laravel — returns-api

**Files:** Modify `returns-api/.github/workflows/Build.yaml`; update returns-api deploy/helm
values for the `nginx-` → `webserver-` proxy tag.

- [ ] **Step 1: Find the proxy image reference in deploy/helm values.**

```bash
grep -rn "nginx-" returns-api/deployments/ returns-api/.github/workflows/ || true
```
Note every place the proxy tag prefix is consumed.

- [ ] **Step 2: Replace Build.yaml with the thin caller.**

```yaml
name: Build
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-laravel.yaml@DEVEX-1630-unify-php-build-workflows
    with:
      dockerfile_app_path: ./build/Dockerfile-app
      dockerfile_webserver_path: ./build/Dockerfile-nginx
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  integration-deploy:
    if: ${{ github.event_name == 'push' }}
    needs: [build]
    uses: ./.github/workflows/Integration EKS Deploy.yaml
    with:
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```

- [ ] **Step 3: Update proxy tag consumers** found in Step 1 from `nginx-` to `webserver-`.

- [ ] **Step 4: Lint.** `actionlint .github/workflows/Build.yaml` → no errors.

- [ ] **Step 5: Trigger build, verify jobs + tags.** Same commands as Task 5 Steps 3-4, but
  expect proxy tag `webserver-<tag>` (not `nginx-`), and confirm the **artisan cache steps
  ran** in the build helper logs without error:

```bash
gh run view <run-id> --repo encodium/returns-api --log | grep -i "artisan"
```

- [ ] **Step 6: Boot-check the app image** (artisan caching is new for returns-api) — pull
  the new app image in the dev sandbox and confirm it starts and serves a health route.

- [ ] **Step 7: Commit on a branch, open draft PR.**

```bash
git commit -am "DEVEX-1630: migrate Build.yaml to shared build-php-laravel orchestrator"
```

### Task 7: Merge foundation, flip pilots to `@main`

- [ ] **Step 1:** Mark the `encodium/.github` PR ready and merge it.
- [ ] **Step 2:** In both pilot Build.yaml files, change
  `@DEVEX-1630-unify-php-build-workflows` → `@main`. Commit.
- [ ] **Step 3:** Re-run a dispatch build on each pilot to confirm `@main` resolves and
  produces identical tags. Merge both pilot PRs.

---

## Phase 1C — Fan-out (one PR per repo, all reference `@main`)

For every repo: replace `Build.yaml` with a thin caller mirroring the matching pilot, using
the repo's exact `images` array (v1) and preserving its existing deploy job verbatim except
`needs:` → `[build]` and (integration repos) the `if: github.event_name == 'push'` gate.
Verify each with the Task 5 Step 3-4 commands (tag-fidelity diff against baseline).

### Task 8: catalog_api (v1, integration)

**Files:** Modify `catalog_api/.github/workflows/Build.yaml`.
- [ ] **Step 1:** Replace the file with the thin caller (app + nginx):

```yaml
name: Build
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-v1.yaml@main
    with:
      images: >-
        [
          {"image_name":"","dockerfile":"./build/app/Dockerfile","target":"app","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"","dockerfile":"./build/nginx/Dockerfile","target":"","tag_prefix":"nginx-","extra_tag":"nginx-latest"}
        ]
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  integration-deploy:
    name: Deploy to Integration
    if: ${{ github.event_name == 'push' }}
    needs: [build]
    uses: ./.github/workflows/Integration EKS Deploy.yaml
    with:
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```
- [ ] **Step 2:** Lint, trigger, tag-diff (expect `:<tag>`, `:latest`, `:nginx-<tag>`, `:nginx-latest`).
- [ ] **Step 3:** Commit on branch, draft PR.

### Task 9: rp_api (v1, integration, **profiler**)

**Files:** Modify `rp_api/.github/workflows/Build.yaml`.
- [ ] **Step 1:** Thin caller with the 3-image array:

```yaml
      images: >-
        [
          {"image_name":"","dockerfile":"./build/app/Dockerfile","target":"app","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"rp_api-profiler","dockerfile":"./build/app/Dockerfile","target":"app-profiler","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"","dockerfile":"./build/nginx/Dockerfile","target":"","tag_prefix":"nginx-","extra_tag":"nginx-latest"}
        ]
```
  Keep rp_api's gated `integration-deploy` (`needs: [build]`).
- [ ] **Step 2:** Lint, trigger, tag-diff. **Confirm `ghcr.io/encodium/rp_api-profiler:<tag>`
  and `:latest` are pushed** (separate image), plus app + nginx tags.
- [ ] **Step 3:** Commit on branch, draft PR.

### Task 10: internal_api (v1, integration, **profiler**)

**Files:** Modify `internal_api/.github/workflows/Build.yaml`.
- [ ] **Step 1:** Replace the file with the thin caller (app + profiler + nginx). Note the
  **hyphenated** deploy filename for this repo:

```yaml
name: Build
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-v1.yaml@main
    with:
      images: >-
        [
          {"image_name":"","dockerfile":"./build/app/Dockerfile","target":"app","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"internal_api-profiler","dockerfile":"./build/app/Dockerfile","target":"app-profiler","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"","dockerfile":"./build/nginx/Dockerfile","target":"","tag_prefix":"nginx-","extra_tag":"nginx-latest"}
        ]
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  integration-deploy:
    name: Deploy to Integration
    if: ${{ github.event_name == 'push' }}
    needs: [build]
    uses: ./.github/workflows/Integration-EKS-Deploy.yaml
    with:
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```
- [ ] **Step 2:** Lint, trigger, tag-diff (app + `internal_api-profiler` + nginx).
- [ ] **Step 3:** Commit on branch, draft PR.

### Task 11: radmin (v1, **staging**)

**Files:** Modify `radmin/.github/workflows/Build.yaml`.
- [ ] **Step 1:** Thin caller with `images` = app + nginx. **No gate.** Preserve radmin's
  existing staging deploy verbatim, only changing `needs:`:

```yaml
  stage-eks-deploy:
    uses: encodium/radmin/.github/workflows/deploy-eks.yaml@main
    needs: [build]
    with:
      environment: stg
      image_tag: ${{ needs.build.outputs.tag }}
      values-file: ./deployments/stg-eks-values.yaml
    secrets:
      kubeconfig: ${{ secrets.RP_STG_EKS_KUBECONFIG }}
      k8s_aws_access_id: ${{ secrets.RP_STG_EKS_ACCESS_KEY }}
      k8s_aws_access_secret: ${{ secrets.RP_STG_EKS_SECRET_KEY }}
      slack_webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
      jellyfish_api_token: ${{ secrets.JELLYFISH_API_TOKEN }}
```
- [ ] **Step 2:** Lint, trigger, tag-diff (app + nginx).
- [ ] **Step 3:** Commit on branch, draft PR.

### Task 12: accounts-api (Laravel, integration)

**Files:** Modify `accounts-api/.github/workflows/build.yaml` (lowercase).

- [ ] **Step 1: Capture the jobs to preserve.** accounts-api has extra jobs (OpenAPI
  `generate_client` dispatch, release artifact) not in the shared spine. Record them
  verbatim before editing:

```bash
gh api repos/encodium/accounts-api/contents/.github/workflows/build.yaml --jq '.content' | base64 -d > /tmp/accounts-build.yaml
```
  Note the exact `generate_client` job(s), their `if: steps.spec_changed.outputs.any_changed == 'true'` guards, and the `./deployments/files/openapi.yaml` artifact wiring.

- [ ] **Step 2: Replace the build/tag/release jobs with the shared caller**, keeping the
  preserved jobs. The build block:

```yaml
name: Build
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-laravel.yaml@main
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  integration-deploy:
    if: ${{ github.event_name == 'push' }}
    needs: [build]
    uses: ./.github/workflows/Integration EKS Deploy.yaml
    with:
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```
  Then re-attach the preserved `generate_client` job(s) from Step 1, repointing any
  `needs:`/tag reference to `needs.build.outputs.tag`. accounts-api already publishes
  `webserver-` so no deploy/helm consumer change is needed.

- [ ] **Step 3:** Lint, trigger, tag-diff (app + `webserver-<tag>`); confirm `generate_client`
  still runs when the OpenAPI spec changes.
- [ ] **Step 4:** Commit on branch, draft PR.

### Task 13: vin_decoder_service (Laravel, **staging**)

**Files:** Modify `vin_decoder_service/.github/workflows/Build.yaml`; update its deploy/helm
values for `nginx-` → `webserver-`.
- [ ] **Step 1:** Grep proxy-tag consumers: `grep -rn "nginx-" vin_decoder_service/deployments/ || true`.
- [ ] **Step 2:** Replace the file with the thin caller; preserve the staging deploy verbatim
  except `needs: [build]`:

```yaml
name: Build
on:
  workflow_dispatch:

concurrency:
  group: ${{ github.repository }}-build
  cancel-in-progress: false

jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-laravel.yaml@main
    with:
      dockerfile_app_path: ./build/Dockerfile-app
      dockerfile_webserver_path: ./build/Dockerfile-nginx
    secrets:
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  stage-deploy-eks:
    uses: encodium/vin_decoder_service/.github/workflows/deploy-eks.yaml@main
    needs: [build]
    with:
      environment: stg
      image_tag: ${{ needs.build.outputs.tag }}
      values-file: ./deployments/stg-eks-values.yaml
    secrets:
      kubeconfig: ${{ secrets.RP_STG_EKS_KUBECONFIG }}
      k8s_aws_access_id: ${{ secrets.RP_STG_EKS_ACCESS_KEY }}
      k8s_aws_access_secret: ${{ secrets.RP_STG_EKS_SECRET_KEY }}
      slack_webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
      jellyfish_api_token: ${{ secrets.JELLYFISH_API_TOKEN }}
```

> vin_decoder_service is `workflow_dispatch`-only today (no `push:` trigger) — preserved as-is.

- [ ] **Step 3:** Update proxy consumers `nginx-` → `webserver-`.
- [ ] **Step 4:** Lint, trigger, tag-diff (expect `webserver-<tag>`); boot-check image
  (new artisan caching).
- [ ] **Step 5:** Commit on branch, draft PR.

### Task 14: webstore (v1, integration, **profiler + apache + Node/S3 extraction**) — LAST

**Files:** Modify `webstore/.github/workflows/Build.yaml`.

- [ ] **Step 1: Extract the Node/S3 asset publish into its own caller job.** Lift the
  current `build-app` job's Node steps (Setup node, node_modules cache, `npm ci`,
  `npm rebuild`, `npm run build`, Configure AWS, gzip, `aws s3 cp` × N, remove dist) into a
  standalone job `publish-assets` that runs from `calculate-tag` independently of `build`.
  It needs no PHP/composer. Keep its AWS/npm secrets and the exact S3 paths.

- [ ] **Step 2: Thin caller for the PHP images** (app + profiler + apache + nginx):

```yaml
      images: >-
        [
          {"image_name":"","dockerfile":"./build/app/Dockerfile","target":"app","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"webstore-profiler","dockerfile":"./build/app/Dockerfile","target":"app-profiler","tag_prefix":"","extra_tag":"latest"},
          {"image_name":"","dockerfile":"./build/nginx/Dockerfile","target":"","tag_prefix":"nginx-","extra_tag":"nginx-latest"},
          {"image_name":"","dockerfile":"./build/apache/Dockerfile","target":"","tag_prefix":"apache-","extra_tag":"apache-latest"}
        ]
```
  Keep webstore's gated `integration-deploy` (hyphenated `Integration-EKS-Deploy.yaml`,
  `needs: [build]`).

- [ ] **Step 3: Verify CDN assets unchanged.** Trigger a build; confirm `publish-assets`
  uploads the **same** S3 keys as before (compare `aws s3 ls` listing of the CDN prefix
  pre/post). This is the highest-risk check — do not merge until identical.

- [ ] **Step 4:** Lint, tag-diff (app + `webstore-profiler` + `nginx-` + `apache-`).

- [ ] **Step 5:** Commit on branch, draft PR.

---

## Done criteria

- [ ] All 9 repos build via the shared orchestrators (`@main`); no repo retains inline
  composer/docker build steps for its PHP images.
- [ ] Every repo's produced image tags match its pre-migration baseline (profiler images,
  `nginx-`/`apache-` tags, `webserver-` for the two standardized Laravel repos).
- [ ] Integration repos skip deploy on `workflow_dispatch`, deploy on `push` (Phase 0 gate
  preserved in the thin callers).
- [ ] webstore CDN assets verified byte-path identical after Node/S3 extraction.
- [ ] `php-build-push.yaml` change is backward-compatible for any pre-existing callers.
```
