# Development standards checklist

Use this checklist when opening PRs across Encodium projects. It is aligned with what our GitHub Actions workflows enforce (ex: Jira ticket verification, commit linting, action linting) and common review feedback patterns (ex: safe shell handling of PR title/body).

## PR metadata

- [ ] **Jira ticket is present and valid** (in branch name, PR title, or PR description) and links to Jira.
- [ ] **PR title format** includes the Jira key (recommended: `[PROJECT-1234] Human readable description`).
- [ ] **PR description** explains the *what* and the *why* (not just code diffs).
- [ ] **Testing Information** is complete and reproducible (steps + expected results).
- [ ] **Related PRs** are linked when changes span repos.

## Branching and commits

- [ ] **Branch name** follows: `<project>-<ticket_number>-<human-readable-dash-case>` (example: `SHOP-1234-add-user-authentication`).
- [ ] **Commit messages** follow conventional commits:
  - Format: `type(scope): subject`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Subject is imperative, no trailing period

## Quality checks (run locally before requesting review)

- [ ] **Formatting** (ex: Prettier / PHP-CS-Fixer / Pint) is run and clean.
- [ ] **Linting** is run and clean (ex: ESLint, PHP lint, actionlint).
- [ ] **Static analysis** is run and clean (ex: PHPStan, TypeScript typecheck).
- [ ] **Tests** are run and passing (unit/integration as applicable).
- [ ] **Scope of tests** matches our testing standards:
  - PHP tests use **Mockery** (not PHPUnit mocks).
  - Avoid mocking dependencies-of-dependencies; test the unit/system under test.
  - Prefer data providers over duplicative test cases.
  - Avoid global/alias/overload mocks; if unavoidable, isolate the test.

## Type safety (esp. PHP)

- [ ] **Types are explicit** (args, properties, returns); avoid “widening” types.
- [ ] **Array shapes are documented** in PHPDoc using phpstan syntax (no `mixed` escape hatches when generics exist).
- [ ] **Do not use `empty()`**; prefer type-enforcing checks.
- [ ] **Alphabetize where order doesn’t matter** (use statements, union types in PHPDoc, constants).

## GitHub Actions and shell scripting (common review feedback)

- [ ] **Run untrusted/user-supplied content safely**:
  - Do **not** directly interpolate `${{ github.event.pull_request.title }}` / `${{ github.event.pull_request.body }}` inside `run:` scripts.
  - Pass them via `env:` and read them as environment variables inside the script.
- [ ] **Quote variable expansions** and prefer `printf` for safely emitting content.
- [ ] **Avoid leaking secrets** to logs (never echo secret values; redact outputs).
- [ ] **Action workflows lint cleanly** (ex: `actionlint`) when modified.
- [ ] **Actions are pinned** to stable major versions (or more strictly, as required by the repo).

## Deployment / infra (when applicable)

- [ ] **Kubernetes/Helm changes** are validated (linting + kube-linter where applicable).
- [ ] **Observability and runbooks** are updated when behavior changes (alerts, dashboards, operational docs as required by the owning repo).
