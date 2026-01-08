# Contributing to Ralph

Thank you for your interest in improving Ralph. This project aims to be a reliable, well-tested tool for autonomous development, and contributions are very welcome.

Before you start, please skim:

- `README.md` – overview, features, and usage
- `TESTING.md` – how to run tests and how we think about coverage
- `IMPLEMENTATION_STATUS.md` – current test counts, coverage estimates, and known gaps

---

## 1. Getting Set Up

1. **Fork and Clone**

   ```bash
   git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
   cd ralph-claude-code
   ```

2. **Install Test Dependencies**

   Ralph uses BATS for testing:

   ```bash
   npm install -g bats bats-support bats-assert
   ```

3. **Run the Test Suite**

   Make sure everything passes before you start changing code:

   ```bash
   npm test
   # or, by suite:
   npm run test:unit
   npm run test:integration
   npm run test:e2e
   ```

See `TESTING.md` for more detail on the test layout and CI behavior.

---

## 2. Types of Contributions

You can help in many ways:

- **Bug fixes** – Correctness issues, edge cases, portability problems
- **Improvements** – Better error handling, clearer logs, safer shell patterns
- **New tests** – Additional unit/integration/E2E coverage for existing behavior
- **Documentation** – Clarifying README, TESTING, or implementation notes
- **New features** – Carefully scoped improvements that fit the project goals

If you’re unsure whether a feature fits, open an issue or draft PR describing the idea before investing heavily.

---

## 3. Development Workflow

1. **Create a Branch**

   ```bash
   git checkout -b feature/short-description
   # or
   git checkout -b fix/short-description
   ```

2. **Make Changes**

   - Follow existing Bash patterns (quoting, `set -e`, array usage where needed).
   - Prefer small, focused commits.
   - Keep behavior changes aligned with the documented design.

3. **Add or Update Tests**

   - For new behavior or bug fixes, add tests under:
     - `tests/unit/` for small functions/modules
     - `tests/integration/` for script workflows
     - `tests/e2e/` for full-loop scenarios
   - Use helpers from `tests/helpers/test_helper.bash`, `fixtures.bash`, and `mocks.bash`.

4. **Run Tests**

   At minimum:

   ```bash
   npm run test:unit
   ```

   For broader changes:

   ```bash
   npm test
   ```

5. **Update Documentation**

   - Update `README.md` for user-visible changes.
   - Update `TESTING.md`, `CLAUDE.md`, or other docs if behavior or expectations change.

6. **Commit and Push**

   ```bash
   git add .
   git commit -m "feat(loop): brief description of change"
   git push origin feature/short-description
   ```

7. **Open a Pull Request**

   In your PR description, include:

   - What changed and why
   - Any breaking changes or migration considerations
   - Which tests you ran (`npm test`, specific suites/files)
   - Screenshots or log snippets if they clarify behavior

---

## 4. Tests and Coverage Expectations

Ralph currently has:

- 218 tests (unit, integration, E2E)
- ~70% estimated coverage of core paths

The goal is to steadily move toward **85–90% effective coverage** without adding meaningless tests.

When you change behavior:

- **Do**:
  - Add tests that would catch your change if it regressed.
  - Strengthen coverage in under-tested areas (see `IMPLEMENTATION_STATUS.md` for hints).
  - Keep tests deterministic and fast.

- **Avoid**:
  - Adding tests that only bump line coverage without checking behavior.
  - Removing or weakening existing tests unless they are incorrect.

If your change exposes a poorly tested area, adding one or two focused tests there is especially valuable.

---

## 5. Code Style and Patterns

- Shell scripts are Bash-based; follow the existing style in:
  - `ralph_loop.sh`
  - `lib/*.sh`
  - `tests/*.bats`
- Key conventions:
  - Quote variables unless there is a specific reason not to.
  - Use `set -e` at script entry where appropriate.
  - Prefer functions over inlined duplicated logic.
  - Avoid introducing new patterns for configuration or flags if an existing one fits.

If in doubt, mirror the style of the file you are editing.

---

## 6. PR Checklist

Before marking your PR ready for review:

- [ ] All relevant tests pass locally (`npm test`, or the suites you affected)
- [ ] New behavior is covered by tests where appropriate
- [ ] Documentation updated (README, TESTING, MIGRATION, etc. as needed)
- [ ] No debugging output or temporary files remain
- [ ] CI passes (unit, integration, and E2E suites green)

Thank you for helping make Ralph more robust and useful for the community.