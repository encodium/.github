# Nightly Common Bump Build-on-Tag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a nightly `revolutionparts/common` bump produce a new build/tag (and, for repos with an integration pipeline, an integration deploy) instead of being suppressed by `[skip actions]`.

**Architecture:** Add an optional `skip_ci` input (default `true`, fully backward-compatible) to the shared `php-common-bump.yaml`; the bump commit appends `[skip actions]` only when `skip_ci` is true. The 11 repos that have a nightly common-update workflow opt in by passing `skip_ci: false`. The merge-path `upgrade-common.yaml` is left untouched (keeps skipping → no merge double-builds).

**Tech Stack:** GitHub Actions reusable workflows (`workflow_call`), `mathieudutour/github-tag-action`, `REPO_WRITE_PAT` (PAT pushes trigger workflows).

**Spec:** `docs/superpowers/specs/2026-06-10-common-bump-build-on-nightly-design.md`
**Ticket:** DEVEX-1628.

---

## How "tests" work here

There is no unit harness for workflows, and a common bump only commits when common **actually
changed** (a `git diff-index` guard), so a build can't be forced on demand without mutating
`main`. Verification is therefore:
1. **Static lint** — `actionlint` on every changed file.
2. **Logic review** — confirm the conditional `[skip actions]` suffix is correct.
3. **Live observation** — after merge + opt-in, `workflow_dispatch` the pilot's nightly workflow
   and read the run: if common changed, confirm the bump commit has **no** `[skip actions]` and a
   `Build` run was triggered; if common was already current, confirm the run no-ops cleanly
   (expected) and confirm correctness on the next real common change.

Reusable workflows are referenced by ref. The `skip_ci` input must exist on
`encodium/.github` **`main`** before any caller passes it (an unknown input fails the call), so
**Task 1 (the shared change) must merge before the opt-in PRs (Tasks 3+)**.

---

## File Structure

**`encodium/.github` (shared — merges first):**
- Modify: `.github/workflows/php-common-bump.yaml` — add `skip_ci` input; conditional `[skip actions]`.

**Per service repo (one PR each) — add `skip_ci: false` to the nightly common-update workflow's `with:` block:**
- `Nightly Common Update.yaml` (8): rp_api, internal_api, catalog_api, license_api, returns-api, accounts-api, webstore, listings-url-service
- `nightly-common-update.yaml` (3): listings, marketplaces, payments

---

## Task 1: Add `skip_ci` input to `php-common-bump.yaml`

**Files:** Modify `.github/workflows/php-common-bump.yaml` (worktree `~/dev/claude/github-DEVEX-1628`, branch `DEVEX-1628-common-bump-build-on-nightly`).

- [ ] **Step 1: Add the input.** Under `on.workflow_call.inputs`, after `continue_on_error`, add:

```yaml
      skip_ci:
        description: "Append [skip actions] to the bump commit so it does NOT trigger workflows."
        required: false
        type: boolean
        default: true
```

- [ ] **Step 2: Make the commit suffix conditional.** In the `Commit Common Bump` step
  (`id: commit`), the bump currently runs:

```bash
          git commit -am "${{ inputs.commit_message }} [skip actions]"
```

Replace that single line with env-driven, conditional logic (keep everything else in the step —
the `diff-index` guard above it and the rebase-retry push below it — unchanged):

```bash
          SUFFIX=""
          [ "$SKIP_CI" = "true" ] && SUFFIX=" [skip actions]"
          git commit -am "${COMMIT_MESSAGE}${SUFFIX}"
```

And add an `env:` block to that step so the shell reads the inputs safely (place it on the
`Commit Common Bump` step, alongside `id: commit`):

```yaml
        env:
          SKIP_CI: ${{ inputs.skip_ci }}
          COMMIT_MESSAGE: ${{ inputs.commit_message }}
```

> `default: true` makes this byte-for-byte backward compatible — every caller that does not set
> `skip_ci` (upgrade-common, daemons, batch, the merge-main family) keeps committing with
> `[skip actions]`. Booleans render as the strings `"true"`/`"false"`, so `[ "$SKIP_CI" = "true" ]`
> is the correct test.

- [ ] **Step 3: Lint.** `actionlint .github/workflows/php-common-bump.yaml` → expect zero errors.
  Also confirm YAML parses: `ruby -ryaml -e "YAML.load_file('.github/workflows/php-common-bump.yaml')"`.

- [ ] **Step 4: Commit, push, open draft PR.**

```bash
git add .github/workflows/php-common-bump.yaml
git commit -m "feat: add skip_ci input to php-common-bump (default true)"
git push -u origin DEVEX-1628-common-bump-build-on-nightly
gh pr create --repo encodium/.github --draft --base main \
  --title "DEVEX-1628: optional skip_ci on php-common-bump" \
  --body "Adds an optional skip_ci input (default true = current behavior) so nightly common bumps can omit [skip actions] and trigger a build/tag. Backward-compatible: no existing caller changes behavior. Nightly workflows opt in via separate PRs. Refs DEVEX-1628"
```

## Task 2: Merge Task 1 (human review gate)

- [ ] **Step 1:** Reviewer approves and merges the `encodium/.github` PR to `main`. The opt-in
  PRs below reference `php-common-bump.yaml@main` and require the `skip_ci` input to exist there.

## Task 3: Pilot opt-in — internal_api

**Files:** Modify `internal_api/.github/workflows/Nightly Common Update.yaml`.

- [ ] **Step 1: Create a worktree.**

```bash
cd ~/dev/internal_api && git fetch origin -q
git worktree add -b DEVEX-1628-nightly-build ~/dev/claude/internal_api-DEVEX-1628 origin/main
```

- [ ] **Step 2: Add `skip_ci: false` to the `with:` block.** The job currently reads:

```yaml
  update-common:
    uses: encodium/.github/.github/workflows/php-common-bump.yaml@main
    with:
      php_version: "8.3"
      commit_message: "chore: nightly update revolutionparts/common"
    secrets:
      write_pat: ${{ secrets.REPO_WRITE_PAT }}
      packagist_username: ${{ secrets.PACKAGIST_USERNAME }}
      packagist_password: ${{ secrets.PACKAGIST_PASSWORD }}
```

Add one line to `with:`:

```yaml
    with:
      php_version: "8.3"
      commit_message: "chore: nightly update revolutionparts/common"
      skip_ci: false
```

- [ ] **Step 3: Lint.** `actionlint ".github/workflows/Nightly Common Update.yaml"` → zero errors.

- [ ] **Step 4: Commit, push, open draft PR.**

```bash
git add ".github/workflows/Nightly Common Update.yaml"
git commit -m "ci: build & tag on nightly common bump (skip_ci false)"
git push -u origin DEVEX-1628-nightly-build
gh pr create --repo encodium/internal_api --draft --base main \
  --title "DEVEX-1628: build & tag on nightly common bump" \
  --body "Nightly common bump now omits [skip actions] so it builds, tags, and deploys to integration. Refs DEVEX-1628"
```

- [ ] **Step 5: Mark ready + merge** (after Task 2 is merged). Then **live-verify** by dispatching
  the nightly workflow on `main`:

```bash
gh workflow run "Nightly Common Update.yaml" --repo encodium/internal_api --ref main
# find the run, then read the upgrade-common job log:
gh run list --repo encodium/internal_api --workflow "Nightly Common Update.yaml" --limit 1 --json databaseId,status
```
Expected, **if common changed**: a bump commit on `main` whose message has **no** `[skip actions]`,
and a new `Build` run kicks off (→ new `-main.N` tag → integration deploy). **If common was
already current**: the run logs "No changes to commit" and ends — that is correct; confirm the
suffix logic on the next real common change. Either way the run itself must succeed.

## Task 4: Fan out `skip_ci: false` to the remaining 10 repos

For each repo below: worktree off `origin/main`, add `skip_ci: false` to the nightly workflow's
`with:` block (exactly as Task 3 Step 2 — if a repo has no `with:` block, add one containing
`skip_ci: false`), `actionlint`, commit `ci: build & tag on nightly common bump (skip_ci false)`,
push, open a draft PR titled `DEVEX-1628: build & tag on nightly common bump`, then merge.

- [ ] **`Nightly Common Update.yaml`:** rp_api, catalog_api, license_api, returns-api, accounts-api, webstore, listings-url-service
- [ ] **`nightly-common-update.yaml`** (lowercase filename — confirm the exact path per repo): listings, marketplaces, payments

Per repo:
- [ ] Worktree: `git -C ~/dev/<repo> worktree add -b DEVEX-1628-nightly-build ~/dev/claude/<repo>-DEVEX-1628 origin/main`
- [ ] Edit the nightly workflow `with:` → add `skip_ci: false`
- [ ] `actionlint <nightly-workflow-file>` → zero errors
- [ ] Commit `ci: build & tag on nightly common bump (skip_ci false)`, push, draft PR (`Refs DEVEX-1628`), merge

> Note: the lowercase-`nightly-common-update.yaml` repos (listings, marketplaces, payments) are
> the merge-main family; their nightly bump triggers their own `push: main` build pipeline (build
> + tag per their flow) rather than the `Build.yaml` integration path. listings-url-service is a
> harmless no-op if it has no `push: main` build. All still take the uniform `skip_ci: false` edit.

## Done criteria

- [ ] `php-common-bump.yaml` on `main` has `skip_ci` (default `true`); no existing caller's behavior changed.
- [ ] All 11 nightly common-update workflows pass `skip_ci: false`; every `upgrade-common.yaml` is untouched.
- [ ] Pilot live-verified: a nightly bump with a real common change produces a commit without `[skip actions]` and triggers a build/tag (internal_api).
- [ ] No loop and no merge double-build observed (the `diff-index` guard + untouched merge path hold).
