# Nightly common bumps should build & tag (DEVEX-1628)

- **Date:** 2026-06-10
- **Ticket:** DEVEX-1628 (Bug, In Progress) — "Automatic Common bumps are not getting built or deployed to integration"
- **Repos affected:** `encodium/.github` (shared `php-common-bump.yaml`) + 11 service repos (their nightly common-update workflow)

## Problem

`php-common-bump.yaml` commits the `revolutionparts/common` version bump with `[skip actions]`
([line 85](https://github.com/encodium/.github/blob/main/.github/workflows/php-common-bump.yaml)).
That suppresses the `push: main`-triggered `Build.yaml`, so a common bump never produces a
new image tag and the integration environment never receives the updated common.

This interacts with DEVEX-1629: now that `workflow_dispatch` skips `integration-deploy`,
re-triggering a build via dispatch would not deploy either. The only clean way a common bump
reaches integration is for the bump to be a **real push to main** (which builds, tags, and —
being a push — deploys). The bump push is already made with `REPO_WRITE_PAT` (a PAT, which
*does* trigger workflows), so the literal `[skip actions]` text is the only thing stopping it.

## Goal

**Anything that depends on common should receive a new tag and be deployed to integration when
common changes.** Concretely: every **nightly** common bump that actually changes common produces
a new build/tag (and, for repos with an integration pipeline, an integration deploy) — the
ticket's "ideal scenario" — without disturbing the many other `php-common-bump` consumers.

This change covers every common-dependent repo that **has a nightly common-update workflow**
(the 11 below). Common-dependents that lack a nightly workflow (daemons, batch, radmin,
vin_decoder_service) cannot be opted in until one exists; bringing them to full coverage by
adding nightly workflows is a tracked follow-on (see Out of scope).

## Decisions (agreed)

- **Mechanism:** make the suppression configurable; do not remove `[skip actions]` globally.
- **Trigger context:** nightly only. The merge-path `upgrade-common.yaml` keeps skipping, so
  normal app merges don't double-build.
- **Scope:** every repo that has a nightly common-update workflow (all such consumers).

## Design

### Change 1 — `php-common-bump.yaml` (shared, one edit)

Add an optional input, **defaulting to today's behavior**:

```yaml
      skip_ci:
        description: "Append [skip actions] to the bump commit so it does NOT trigger workflows."
        required: false
        type: boolean
        default: true
```

In the `Commit Common Bump` step, append `[skip actions]` only when `skip_ci` is true (pass it
via `env:` to avoid expression-in-shell pitfalls):

```bash
SUFFIX=""
[ "$SKIP_CI" = "true" ] && SUFFIX=" [skip actions]"
git commit -am "${COMMIT_MESSAGE}${SUFFIX}"
```

`default: true` makes this **byte-for-byte backward compatible**: every existing caller that
does not set `skip_ci` (the merge-path `upgrade-common.yaml`, daemons, batch, the merge-main
family, etc.) keeps committing with `[skip actions]` exactly as today. Nothing else in the
workflow changes (checkout, composer install, `composer update revolutionparts/common`, the
`git diff-index` no-change guard, and the rebase-retry push all stay).

### Change 2 — nightly workflows opt in (11 repos)

Each repo's nightly common-update workflow passes `skip_ci: false` to the reusable workflow:

```yaml
  update-common:
    uses: encodium/.github/.github/workflows/php-common-bump.yaml@main
    with:
      php_version: "8.3"
      commit_message: "chore: nightly update revolutionparts/common"
      skip_ci: false                       # <-- added
    secrets:
      write_pat: ${{ secrets.REPO_WRITE_PAT }}
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
```

**Repos (11):**
- `Nightly Common Update.yaml` (8): rp_api, internal_api, catalog_api, license_api,
  returns-api, accounts-api, webstore, listings-url-service
- `nightly-common-update.yaml` (3): listings, marketplaces, payments

The merge-path `upgrade-common.yaml` files are **left unchanged** in every repo.

## Data flow (enabled)

```
nightly cron → composer update revolutionparts/common
  → (only if common changed) commit WITHOUT [skip actions] → push main (REPO_WRITE_PAT)
  → Build.yaml runs on push → tag-and-release cuts a new -main.N tag
  → integration-deploy runs (push event; DEVEX-1629 gate allows push) → integration has fresh common
```

For each repo the effect follows that repo's own `push: main` pipeline: the integration-app
repos build → tag → integration-deploy; the merge-main-family repos (listings, marketplaces,
payments) build + tag per their flow. A repo with no `push: main` build pipeline is a harmless
no-op (the commit simply omits `[skip actions]`).

## Edge cases / safety

- **No loop.** The bump push also re-triggers `upgrade-common` (it is `push: main`); it runs
  `composer update`, finds common already current, hits the `git diff-index` guard, commits
  nothing, and terminates.
- **Bounded churn.** The `diff-index` guard means a build happens only when common actually
  changed — at most one nightly build per repo per common change.
- **No merge double-builds.** Because `upgrade-common` keeps skipping, a normal app merge does
  not spawn a second bump-build.
- **Tag mechanics unchanged.** The `chore:` bump commit takes the default patch bump →
  `-main.N` prerelease tag, which the Start Release Train can later promote.

## Interactions

- **DEVEX-1630** (build-workflow unification): independent. This change edits *nightly*
  workflows + `php-common-bump.yaml`, not `Build.yaml`. It relies only on the push→tag→deploy
  behavior the thin callers preserve, so it works before or after that migration. No file
  conflict.
- **DEVEX-1629** (integration gate): complementary. A common bump is a real push, so it deploys
  via the push path — exactly the behavior the gate intends.

## Out of scope

- Repos without a nightly common-update workflow (daemons, batch, radmin, vin_decoder_service):
  no nightly bump exists to opt in. To fully satisfy "anything that depends on common" they would
  each need a nightly common-update workflow (and, for integration deploy, a push→integration
  build pipeline) added — a tracked follow-on, not part of this change.
- The merge-path (`upgrade-common.yaml`) build-on-bump — deliberately excluded (nightly only).
- The disabled `Nightly Integration Deploy.yaml` placeholder (deploy-latest-tag) — a separate,
  complementary idea, not needed for this ticket.
