# .github

## Reusable workflows

### SonarQube manual scan (`sonarqube-manual.yaml`)

On-demand SonarCloud analysis with a configurable quality profile. Intended for security-heavy profiles or full scans without slowing every PR.

**Consumer setup** — add a `workflow_dispatch` workflow in your repo:

```yaml
jobs:
  sonarqube:
    uses: encodium/.github/.github/workflows/sonarqube-manual.yaml@main
    with:
      quality_profile: ${{ inputs.quality_profile }}
      ref: ${{ inputs.ref }}
      coverage_workflow_run_id: ${{ inputs.coverage_workflow_run_id }}
      coverage_files_to_rewrite: coverage/coverage.xml  # repo-specific paths
    secrets:
      sonar_token: ${{ secrets.SONAR_TOKEN }}
```

**Inputs**

| Input | Required | Description |
| --- | --- | --- |
| `quality_profile` | yes | SonarCloud profile name (e.g. `Sonar way`) |
| `ref` | no | Branch/tag/SHA; defaults to caller ref |
| `coverage_workflow_run_id` | no | GitHub Actions run ID to pull coverage artifacts from |
| `coverage_artifact_pattern` | no | Defaults to `coverage*` |
| `coverage_files_to_rewrite` | no | Comma-separated `coverage.xml` paths for `/github/workspace` rewrite |

**Run from GitHub UI:** Actions → your repo's manual Sonar workflow → Run workflow.

For coverage, pass the run ID from a recent unit-test workflow (Actions → PHP Unit Tests → copy run ID from the URL).
