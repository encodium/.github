# `_compute-rt-tag` composite action

Computes and emits the next Release Train v2 (RT v2) tag and matching prerelease for the current `rt-<N>` branch. Designed for the per-repo `Build.yaml` rt-* push trigger.

Part of [DEVEX-1579](https://revolutionparts.atlassian.net/browse/DEVEX-1579).

## Behaviour

On push to `rt-<N>`, this action:

1. Parses `<N>` from the branch name.
2. Finds the rt-N **cut SHA** as `git merge-base origin/main HEAD`.
3. Reads the **base version** `vX.Y.Z` from the tag at the cut SHA (relies on main tagging every push via mathieudutour).
4. Counts existing `vX.Y.Z-rc.<N>.*` tags to compute the next `iter`.
5. Pushes a lightweight tag `vX.Y.Z-rc.<N>.<iter>`.
6. Creates a matching GitHub Release with `prerelease=true`.

Tag and release are emitted **atomically as a pair** — the promote workflow can later flip `prerelease=false` knowing the GH Release always exists.

## Tag format ⚠️

The original DEVEX-1579 spec proposed `vX.Y.Z-rt.<N>.rc.<iter>`. **That format does not work** because composer's `VersionParser` rejects custom pre-release identifiers (only `rc`, `beta`, `alpha`, `dev`, `patch` are accepted).

This action uses **`vX.Y.Z-rc.<N>.<iter>`** instead (e.g., `v4.7.0-rc.147.3`):
- Composer accepts it as-is, even with `minimum-stability: stable`.
- Standard semver sort order is correct (`rc.147.1 < rc.147.2 < rc.147.10 < rc.148.1 < (stable) X.Y.Z`).
- Train number and iter are uniquely parseable via `rc\.(\d+)\.(\d+)`.
- Distinguishable from legacy v1 `vX.Y.Z-rc.<iter>` (2-segment) by segment count.

## Caller requirements

- Branch matches `rt-<N>` (numeric N).
- `actions/checkout` with `fetch-depth: 0` and `fetch-tags: true` (or no `fetch-tags: false`).
- `Build.yaml` declares `concurrency: { group: 'rt-build-${{ github.ref }}', cancel-in-progress: false }` to prevent iter races. This action does **not** serialise on its own.
- A token with `contents: write` is provided via the `github_token` input.

## Inputs

| Name | Required | Description |
|---|---|---|
| `github_token` | yes | Token with `contents: write` for tag push and `gh release create`. |

## Outputs

| Name | Example | Description |
|---|---|---|
| `tag` | `v4.7.0-rc.147.3` | Full emitted tag. |
| `train_number` | `147` | Train N parsed from the branch name. |
| `iter` | `3` | rc iteration number. |
| `base_version` | `v4.7.0` | Frozen base version from cut SHA. |

## Usage

```yaml
# In <app>/.github/workflows/Build.yaml

on:
  push:
    branches:
      - main
      - 'rt-*'

concurrency:
  group: rt-build-${{ github.ref }}
  cancel-in-progress: false

jobs:
  rt-build:
    if: startsWith(github.ref, 'refs/heads/rt-')
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true

      - id: rt_tag
        uses: encodium/.github/.github/actions/_compute-rt-tag@main
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        run: |
          docker build -t "ghcr.io/${{ github.repository }}:${{ steps.rt_tag.outputs.tag }}" .
          docker push "ghcr.io/${{ github.repository }}:${{ steps.rt_tag.outputs.tag }}"
```

## Failure modes

| Error | Cause | Fix |
|---|---|---|
| `Expected branch matching 'rt-<N>'` | Action invoked on a non-rt branch | Gate the rt-build job with `if: startsWith(github.ref, 'refs/heads/rt-')`. |
| `Could not find merge-base` | Checkout didn't fetch full history | Set `fetch-depth: 0` on `actions/checkout`. |
| `No vX.Y.Z tag at cut SHA` | Main isn't tagging every push, or the cut SHA's tag is missing | Verify Phase 1 (DEVEX-1651) foundation work landed — main path of Build.yaml must invoke mathieudutour. |
| `Computed tag already exists` | Iter race — two rt-build runs computed the same iter concurrently | Confirm `concurrency:` group set on Build.yaml. |

## Why a lightweight tag, not annotated?

Matches the existing `encodium/common` semantic-release pattern (`git tag "$FINAL_TAG"`). The GH Release carries the metadata (title, notes); the tag itself is just a pointer.
