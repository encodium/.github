# .github

## Reusable workflows

### SonarQube manual scan (`sonarqube-manual.yaml`)

On-demand SonarCloud analysis with a configurable quality profile. Intended for security-heavy profiles or full scans without slowing every PR.

SonarCloud does not support selecting a quality profile via scanner arguments. This workflow temporarily assigns the requested profile to the project using the SonarCloud API, runs the scan, then restores the previous profile.

**Consumer setup** — add a `workflow_dispatch` workflow in your repo:

```yaml
jobs:
  sonarqube:
    uses: encodium/.github/.github/workflows/sonarqube-manual.yaml@main
    with:
      quality_profile: ${{ inputs.quality_profile }}
      ref: ${{ inputs.ref }}
      coverage_workflow_run_id: ${{ inputs.coverage_workflow_run_id }}
      coverage_artifact_pattern: coverage*  # repo-specific; see below
    secrets:
      sonar_token: ${{ secrets.SONAR_TOKEN }}
```

**Inputs**

| Input | Required | Description |
| --- | --- | --- |
| `quality_profile` | yes | SonarCloud profile name (e.g. `Sonar way`) |
| `sonar_language` | no | Language key for profile assignment (default: `php`) |
| `ref` | no | Branch/tag/SHA; defaults to caller ref |
| `coverage_workflow_run_id` | no | GitHub Actions run ID to pull coverage artifacts from |
| `coverage_artifact_pattern` | no | Required with `coverage_workflow_run_id`; repo-specific glob |

**Coverage artifact patterns** (set both `coverage_workflow_run_id` and `coverage_artifact_pattern`):

| Repo workflow | Typical pattern |
| --- | --- |
| `encodium/common` unit tests | `coverage*` |
| `php-unit-test.yaml` reusable workflow | `phpunit-code-coverage-report` or `*coverage*` |

**Run from GitHub UI:** Actions → your repo's manual Sonar workflow → Run workflow.

For coverage, pass the run ID from a recent unit-test workflow (Actions → workflow run → copy ID from the URL).
