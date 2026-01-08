# Testing Guide

This document explains how to run the test suite for this repository, how the tests are structured, and how we think about coverage.

For the most up-to-date test counts and coverage estimates, see **`IMPLEMENTATION_STATUS.md`**.

---

## 1. Test Stack Overview

- **Framework**: [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System)
- **Location**: `tests/`
  - `tests/unit/` – fast unit tests for individual functions and small modules
  - `tests/integration/` – integration tests for workflows and scripts
  - `tests/e2e/` – end-to-end tests simulating full loop scenarios
  - `tests/helpers/` – shared helpers, fixtures, and mocks
- **Runner scripts** (from `package.json`):
  - `npm test` – run all tests
  - `npm run test:unit` – unit tests only
  - `npm run test:integration` – integration tests only
  - `npm run test:e2e` – end-to-end tests only

---

## 2. Local Setup

Install BATS and helper libraries:

```bash
npm install -g bats bats-support bats-assert
```

Clone the repo and install any project dependencies:

```bash
git clone https://github.com/pt-act/ralph-claude-code.git
cd ralph-claude-code
npm install  # if you want local node_modules-based tools (optional)
```

---

## 3. Running Tests

### All Tests

```bash
npm test          # Runs all BATS tests (unit + integration + e2e)
```

### By Suite

```bash
npm run test:unit        # Unit tests (tests/unit/)
npm run test:integration # Integration tests (tests/integration/)
npm run test:e2e         # End-to-end tests (tests/e2e/)
```

### Individual Files

You can also invoke BATS directly:

```bash
bats tests/unit/test_config.bats
bats tests/integration/test_prd_import.bats
bats tests/e2e/test_full_loop.bats
```

---

## 4. Test Suites & Scope

High-level breakdown (see `IMPLEMENTATION_STATUS.md` for exact counts):

- **Unit tests** focus on:
  - Rate limiting and call tracking
  - Exit detection logic
  - Config loading
  - Metrics logging and `ralph-stats`
  - Notifications and backup/rollback helpers
  - Adapter registry and CLI parsing

- **Integration tests** cover:
  - Loop execution and edge cases
  - Installation and uninstallation
  - Project setup (`ralph-setup`)
  - PRD import (`ralph-import`)
  - tmux integration
  - Monitor dashboard behavior

- **E2E tests** simulate:
  - Full loop execution with mocked adapters
  - Multi-loop scenarios
  - Graceful exits (completion, test saturation)
  - State persistence and cleanup

---

## 5. Coverage Philosophy

We currently track **coverage qualitatively**, not with an automated coverage tool:

- **Estimated coverage**: ~70% of core paths (see `IMPLEMENTATION_STATUS.md`)
- **Coverage goal**: 85–90% over time
- **Focus areas**:
  - Core loop behavior (`ralph_loop.sh`)
  - Error detection and circuit breaker logic
  - PRD import, installation, and project setup flows

Guidance:

- New features should come with **meaningful tests** that validate behavior.
- Aim to **increase** effective coverage, or at least not reduce it.
- Prefer tests that protect critical flows and edge cases over superficial line coverage.

If you add language-specific components inside a Ralph-managed project (e.g., a Node.js or Python app), use that project’s own coverage tools (e.g. `npm run test:coverage`, `pytest --cov`) where appropriate.

---

## 6. CI Behavior

GitHub Actions (`.github/workflows/test.yml`) runs the following on each push and pull request:

```bash
npm run test:unit
npm run test:integration
npm run test:e2e
```

- Any failure in these suites **fails the build**.
- A summary is written to the GitHub Actions job summary indicating that each suite completed (see logs for details).

This means:

- You should run the tests locally before pushing.
- PRs are expected to keep the CI pipeline green.

---

## 7. Adding New Tests

When contributing changes:

1. **Decide the right level**:
   - Pure function or small helper → `tests/unit/`
   - Script behavior or cross-component flow → `tests/integration/`
   - Full user workflow or multi-step scenario → `tests/e2e/`

2. **Follow existing patterns**:
   - Use helpers from `tests/helpers/test_helper.bash`, `fixtures.bash`, and `mocks.bash`.
   - Keep tests focused and deterministic (avoid external network calls, real API usage, etc.).

3. **Keep coverage moving forward**:
   - Add tests alongside new or modified behavior.
   - Prefer tests that would catch regressions in the future.
   - If you touch a lightly-tested area, consider adding one or two focused tests to strengthen it.

4. **Run relevant suites before committing**:
   - At minimum: `npm run test:unit`
   - For broader changes: `npm test`

For detailed implementation status and which areas are still under-tested, refer to `IMPLEMENTATION_STATUS.md`.