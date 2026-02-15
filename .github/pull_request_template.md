## Description
<!--
short description or bulleted list of what the pull request contains

**Related PRs:**
- https://github.com/encodium/webstore/pull/1234
- https://github.com/encodium/common/pull/4321
-->
**Jira Issue:** https://revolutionparts.atlassian.net/browse/<issue>

## Background
<!--
explain the _how_ and _why_ we need this
- [relevant context]
- [why you decided to change things]
- [reason you're doing it now]
-->

## Testing Information
<!--
Please describe in detail how you tested your changes. Steps to Reproduce, etc.
This section should be thorough enough that reviewers can replicate the testing.
-->

## Checklist

- [ ] **Jira**: Jira key present (branch name / PR title / PR description) and Jira link filled in above
- [ ] **PR title**: includes Jira key (recommended: `[PROJECT-1234] ...`)
- [ ] **Commits**: conventional commits format (`type(scope): subject`)
- [ ] **Quality**: lint/format/static-analysis run and clean (as applicable)
- [ ] **Tests**: run and passing; added/updated tests where behavior changed
- [ ] **Type safety** (PHP/TS): explicit types; arrays/shapes documented where needed; no `empty()` in PHP
- [ ] **GitHub Actions changes** (if applicable): actionlint clean; avoid interpolating PR title/body directly in `run:` (pass via `env:`)

<!--
## Sonar Test Coverage
If your PR does not pass the SonarCloud Code Analysis, describe why it cannot pass before merging.
-->
<!--
For more information about creating PRs: https://revolutionparts.slite.com/app/docs/wLef9fVzlT0MDA/Creating-Pull-Requests
-->