# Unify PHP build workflows into shared reusable orchestrators

- **Date:** 2026-06-08
- **Tickets:** DEVEX-1630 (Phase 1, this spec) — blocked by DEVEX-1629 (Phase 0, the gate fix)
- **Repos affected:** `encodium/.github` (shared workflows) + 6 PHP service repos

## Problem

The six PHP service repos each carry a full, copy-pasted `Build.yaml`
(`calculate-tag → build images → tag-and-release → integration-deploy`). They have
already drifted back together and are now near-identical, which means every
fleet-wide build change must be made six times. The immediate trigger was
DEVEX-1629 ("hotfix builds are being deployed to the integration environment"):
the same one-line fix has to land in six places.

## Goal

Move the shared build spine into reusable workflows in `encodium/.github` so the
next fleet-wide change is one edit, not six — without changing any image tags that
deploy/helm consumers depend on.

## Scope

In scope — nine PHP services, split by application class. Determined by an
org-wide sweep (`shivammathur/setup-php` in build workflows + root `artisan` marker):

| Repo | Class (`artisan`?) | Build primitive | Images today | Deploy |
|---|---|---|---|---|
| rp_api | v1 (no) | `php-build-push` matrix | `app`, `app-profiler`, `nginx` | integration |
| internal_api | v1 (no) | `php-build-push` matrix | `app`, `app-profiler`, `nginx` | integration |
| catalog_api | v1 (no) | `php-build-push` matrix | `app`, `nginx` | integration |
| license_api | v1 (no) | `php-build-push` matrix | `app`, `nginx` | integration |
| radmin | v1 (no) | `php-build-push` matrix | `app`, `nginx` | **staging** |
| webstore | v1 (no) | `php-build-push` matrix | `app`, `app-profiler`, `nginx`, `apache` | integration |
| returns-api | Laravel (yes) | `php-laravel-build-push` | `app`, `nginx` | integration |
| accounts-api | Laravel (yes) | `php-laravel-build-push` | `app`, `webserver` (already migrated) | integration |
| vin_decoder_service | Laravel (yes) | `php-laravel-build-push` | `app`, `nginx` | **staging** |

`radmin` and `vin_decoder_service` deploy to **staging** via their own
repo-specific `deploy-eks.yaml` (not integration). Since deploy stays in the caller
(below), this is just a different deploy job in those two callers; the build
unification applies unchanged. The Phase 0 integration gate (DEVEX-1629) does not
apply to them — their staging auto-deploy is a separate DEVEX-1087 concern.

`webstore` is a v1 PHP build **plus** a Node asset-publish step; only the PHP image
builds are unified here (see "webstore" below).

Out of scope:
- **batch** — builds/deploys to EC2 via SSM (`build-ec2.yaml`), an entirely different
  model. Left untouched.
- **rp-cli-zero** — `build-and-release.yaml` only runs composer + `action-gh-release`;
  builds no deployable image.
- **checkout, manage** — Node/frontend, no PHP.
- The deploy engine (`helm-deploy-eks.yaml`) and standalone deploy workflows — unchanged.

## Phase 0 — the gate (DEVEX-1629, lands first)

Add a trigger gate to the existing `integration-deploy` job in all six repos:

```yaml
integration-deploy:
  needs: [tag-and-release]
  if: ${{ github.event_name == 'push' }}   # keep push→integration CD; skip on hotfix dispatch
  uses: ./.github/workflows/Integration EKS Deploy.yaml   # (hyphenated in internal_api)
  with: { image_tag: ${{ needs.tag-and-release.outputs.tag }} }
  secrets: inherit
```

Push to `main` still deploys to integration; hotfix `workflow_dispatch` builds,
tags, and releases but does not deploy. Intentional integration deploys use the
standalone `Integration EKS Deploy.yaml` dispatch. Six small PRs, very low risk.

This is the same job that survives into Phase 1 (see below), so Phase 0 is not
throwaway.

## Phase 1 — unification design

### Two orchestrators (not one parametrized file)

Mirrors the existing helper split and avoids skipped-job / `needs` gymnastics:

- **`encodium/.github/.github/workflows/build-php-v1.yaml`** — for the four v1 repos.
- **`encodium/.github/.github/workflows/build-php-laravel.yaml`** — for the two Laravel repos.

Both implement the identical spine and expose a `tag` output:

```
calculate-tag (dry run, release_branches: stage,hotfix,rc, fetch_all_tags: true)
   → build            (differs per orchestrator — see below)
   → tag-and-release  (real bump + GitHub prerelease; output: tag)
```

### Build job — v1 orchestrator

Fan out over an `images` JSON array, one call to `php-build-push.yaml` per image,
via a matrix on the reusable-workflow `uses:`:

```yaml
build:
  needs: [calculate-tag]
  strategy:
    matrix:
      image: ${{ fromJSON(inputs.images) }}
  uses: encodium/.github/.github/workflows/php-build-push.yaml@main
  with:
    image_name: ${{ matrix.image.image_name }}   # default github.repository
    dockerfile: ${{ matrix.image.dockerfile }}
    build_target: ${{ matrix.image.target }}
    tag: ${{ matrix.image.tag_prefix }}${{ needs.calculate-tag.outputs.tag }}
  secrets: inherit
```

Per-repo `images` reproduce **today's exact tags** (verified against `main`):

| Image | `image_name` | `dockerfile` | `target` | tag | extra | repos |
|---|---|---|---|---|---|---|
| app | `<repo>` | `./build/app/Dockerfile` | `app` | `<tag>` | `+ :latest` | all v1 |
| nginx | `<repo>` | `./build/nginx/Dockerfile` | _(none)_ | `nginx-<tag>` | `+ :nginx-latest` | all v1 |
| profiler | `<repo>-profiler` | `./build/app/Dockerfile` | `app-profiler` | `<tag>` | `+ :latest` | rp_api, internal_api, webstore |
| apache | `<repo>` | `./build/apache/Dockerfile` | _(none)_ | `apache-<tag>` | `+ :apache-latest` | webstore only |

> Profiler is a **separate image name** (`ghcr.io/<repo>-profiler:<tag>`), not a tag
> prefix. `nginx`/`apache` are prefixed tags on the same image. The matrix carries
> only the images a given repo declares — extra image types (profiler, apache) need no
> orchestrator change, just additional matrix entries.

### `php-build-push.yaml` modernization (prerequisite for the v1 path)

The current helper cannot reproduce these tags as-is. Required changes:

1. Add `image_name` input (default `${{ github.repository }}`) so profiler can target `<repo>-profiler`.
2. Push the `latest` companion tag (`:latest` or `:<prefix>latest`) — add an
   `extra_tag`/`push_latest` input; repos currently push both.
3. Bump action versions to match the rest of the fleet:
   `setup-buildx-action@v1→v3`, `login-action@v1→v3`, `build-push-action@v2→v6`.
4. Cache: current helper uses `type=registry` buildcache; the repos' inline builds
   use `type=gha`. Pick one in the pilot (lean `type=gha` to match current behavior)
   and apply consistently.

Before editing, grep for other consumers of `php-build-push.yaml` across the org;
bump conservatively and verify none break.

### webstore (special case, v1)

webstore's current `build-app` job interleaves a **Node asset publish** (npm build →
gzip → `aws s3 cp` to CDN → **`rm -rf dist`**) with the PHP image build. Because the
`dist` folder is removed *before* `docker build`, the app image does **not** bake in
Node assets — they are CDN-served. So the PHP images (app, profiler, nginx, apache)
delegate to `build-php-v1.yaml` like any other v1 repo, and the Node/S3 asset publish
is extracted into a **standalone job in webstore's caller** (no PHP/composer; needs the
existing AWS/S3 + npm secrets). The asset-publish job and the build orchestrator both
fan from `calculate-tag`; neither depends on the other.

This makes webstore the most involved v1 migration — do it **last** in the v1 fan-out,
after the matrix path is proven on simpler repos.

### Build job — Laravel orchestrator

Single call to the existing `php-laravel-build-push.yaml` (app + webserver toggles,
runs `artisan config:cache/route:cache/view:cache`). accounts-api already uses it.
Its `dockerfile_app_path`/`dockerfile_webserver_path` defaults
(`./build/Dockerfile-app`, `./build/Dockerfile-nginx`) already match returns-api and
vin_decoder_service.

**Proxy tag prefix — DECIDED: parametrize, keep each repo's current prefix.** The
Laravel helper previously hardcoded `webserver-<tag>`, but returns-api and
vin_decoder_service publish `nginx-<tag>` and consume that prefix in **two** places each
(`deployments/templates/deployment.yaml` image line + `Start Release Train.yaml`
`image_tag_prefixes`). To avoid that blast radius, `php-laravel-build-push.yaml` now
takes an optional `webserver_tag_prefix` input (default `"webserver-"`, so its many
existing callers — nexus, shopping, shipping, accounts-api, … — are byte-for-byte
unaffected); `build-php-laravel.yaml` threads it through. returns-api and
vin_decoder_service pass `webserver_tag_prefix: "nginx-"` and thus keep their exact
current tags — **no deployment.yaml or SRT change needed**.

**Artisan caching is newly introduced** for returns-api/vin_decoder_service. Their
current inline builds do not run `artisan *:cache`; the helper does. Laravel
`config:cache` can fail if build-time env is missing; accounts-api proves it is
solvable. Verify the image boots correctly after each repo's first build.

### Deploy stays in the thin caller (hard constraint)

A reusable workflow's `uses: ./.github/workflows/...` resolves inside
`encodium/.github`, **not** the caller — so the orchestrators cannot invoke a repo's
local `Integration EKS Deploy.yaml`. Therefore the gated `integration-deploy` job
**remains in each repo's `Build.yaml`**, consuming the orchestrator's `tag` output:

```yaml
jobs:
  build:
    uses: encodium/.github/.github/workflows/build-php-v1.yaml@main   # or -laravel
    with:
      images: '[ ... per-repo ... ]'        # v1 only
    secrets: inherit

  integration-deploy:
    needs: [build]
    if: ${{ github.event_name == 'push' }}  # the Phase 0 gate, unchanged
    uses: ./.github/workflows/Integration EKS Deploy.yaml
    with: { image_tag: ${{ needs.build.outputs.tag }} }
    secrets: inherit
```

Each `Build.yaml` collapses from ~130 lines to a ~25-line caller plus this gated
deploy job. Caller-specific jobs stay in the caller:

- **radmin, vin_decoder_service** keep their existing `stage-eks-deploy`
  (`encodium/<repo>/.github/workflows/deploy-eks.yaml@main`, `stg-eks-values.yaml`)
  instead of an integration-deploy job — no Phase 0 gate.
- **webstore** keeps the extracted Node/S3 asset-publish job.
- **accounts-api** keeps its OpenAPI client-generation jobs.

## Rollout

1. Modernize `php-build-push.yaml` (additive inputs + version bumps); confirm no other consumers break.
2. Author `build-php-v1.yaml` and `build-php-laravel.yaml`.
3. **Pilot v1** on **license_api** (simplest: app + nginx, no profiler). Verify a
   `push` build produces identical tags and the integration deploy runs; verify a
   `workflow_dispatch` build skips deploy.
4. **Pilot Laravel** on **returns-api** (passes `webserver_tag_prefix: nginx-` to keep
   its tags; validates new artisan caching). Verify image boots.
5. Fan out v1: rp_api, internal_api, catalog_api (incl. profiler validation on
   rp_api/internal_api), radmin (staging deploy), then **webstore last** (Node/S3
   asset-publish extraction + apache image).
6. Fan out Laravel: vin_decoder_service (also passes `webserver_tag_prefix: nginx-`;
   same artisan change as the returns-api pilot, staging deploy), accounts-api (keeps
   default `webserver-`; mostly a thin-caller refactor since it already calls the helper).

Each repo is its own PR; the shared-workflow PR(s) to `encodium/.github` merge first
and are referenced `@main`.

## Risks

- **Tag fidelity** → reproduced verbatim via the `images` matrix and the
  `php-build-push` `image_name`/latest-tag inputs; pilots diff produced tags against
  current before fan-out.
- **Matrix + reusable `uses:` + `secrets: inherit`** → supported by Actions; validated
  on the v1 pilot before fan-out.
- **Laravel artisan caching** → newly introduced for returns-api and vin_decoder_service;
  verified per-repo via an image boot-check (returns-api first as the Laravel pilot). The
  proxy prefix is preserved per-repo via the `webserver_tag_prefix` input (default
  `webserver-`), so no deploy/SRT consumer changes and no risk to existing helper callers.
- **webstore Node/S3 extraction** → the asset-publish must keep publishing identical
  CDN paths after being split into its own job; verify CDN assets land unchanged before
  removing the old inline steps. Highest-risk single migration → scheduled last.
- **Shared `php-build-push.yaml` edit blast radius** → grep consumers first; changes are
  additive (new optional inputs) + conservative version bumps.

## Out of scope

See the exclusions table under **Scope** (batch, rp-cli-zero, checkout, manage). Also:

- The deploy engine (`helm-deploy-eks.yaml`) and the standalone deploy workflows.
- webstore's Node build itself — only its PHP image builds are unified; the Node/S3
  asset publish is relocated, not redesigned.
- Staging-deploy decoupling (DEVEX-1087) — related but separate.
