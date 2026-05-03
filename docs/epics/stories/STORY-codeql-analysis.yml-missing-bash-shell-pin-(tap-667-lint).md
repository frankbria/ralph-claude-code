# codeql-analysis.yml missing bash shell pin (TAP-667 lint)

## What

codeql-analysis.yml missing bash shell pin (TAP-667 lint)

## Where

- `.github/workflows/codeql-analysis.yml:1-100`
- `tests/unit/test_ci_workflows.bats:77-140`

## Acceptance

- [ ] codeql-analysis.yml has defaults.run.shell or per-step shell bash
- [ ] TAP-667 unit tests pass
- [ ] test_ci_workflows BATS suite green
