# Migration Guide: pre-1.0.0 → 1.0.0

This guide is for users upgrading from earlier Ralph releases (0.8.x / 0.9.x) to v1.0.0.

The 1.0.0 release is largely backwards-compatible, but a few behaviours changed in ways that may affect automation or long-running projects.

## Configuration loading

Ralph now loads configuration files automatically before parsing CLI arguments:

1. Global config: `~/.ralphrc`
2. Project config: `./.ralphrc`
3. CLI flags (highest precedence)

**What changed**

- In pre-1.0.0 builds, only CLI flags and environment variables were considered.
- In 1.0.0, values from `.ralphrc` files can override built-in defaults (for example `RALPH_MAX_CALLS`, `RALPH_TIMEOUT`, `RALPH_NOTIFY`, `RALPH_BACKUP`, `RALPH_METRICS`), and then CLI flags override those.

**What to check**

- Any scripts or CI jobs that relied on default values only. If your automation sets neither CLI flags nor `RALPH_*` env vars, `.ralphrc` files may now influence behaviour.
- For fully deterministic runs, either:
  - pass explicit CLI flags, or
  - run with a clean HOME/project directory that does not contain `.ralphrc` files.

## Git backup branches

The `--backup` flag now creates explicit git snapshots before each loop iteration.

**What changed**

- When `--backup` is enabled, Ralph will:
  - stage all changes,
  - create an (allow-empty) commit,
  - create a branch named `ralph-backup-loop-<loop>-<timestamp>` pointing at that commit.

**What to check**

- CI/CD pipelines or tooling that:
  - assume a linear history,
  - enumerate branches and perform operations on all of them,
  - use simple `git rev-list --all` statistics.
- If these backups are not desired in automation:
  - avoid passing `--backup`, or
  - explicitly ignore `ralph-backup-*` branches (for example in release scripts).

## PRD import behaviour

`ralph-import` was rewritten to be deterministic and independent of external AI tools.

**What changed**

- Older versions could invoke Claude Code (or other CLIs) to “intelligently” transform PRDs.
- v1.0.0 uses a local, predictable transformation:
  - copies the original file into the project,
  - extracts bullet points as tasks in `@fix_plan.md` where possible,
  - embeds the PRD in `PROMPT.md`,
  - copies the full content to `specs/requirements.md`.

**What to check**

- If you relied on the previous AI-generated structure, expect slight differences in how tasks and specs are phrased.
- For reproducible imports in CI, the new behaviour is safer and recommended.

## CI behaviour

The GitHub Actions workflow `.github/workflows/test.yml` now runs and enforces:

- `npm run test:unit`
- `npm run test:integration`
- `npm run test:e2e`

Any failure in these suites will now fail the build.

**What to check**

- Existing branches or PRs that previously “passed” despite integration/E2E issues may now be blocked until those tests are fixed or updated.

---

For more detail on current state, test counts, and breaking changes, see `IMPLEMENTATION_STATUS.md`.