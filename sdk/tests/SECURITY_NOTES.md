# SDK test-suite security suppressions

`tapps_security_scan` and raw `bandit -r sdk/tests/` previously flagged 581 issues in this directory. After triage, every finding fell into a single category and was annotated per line — no file-scope or directory-scope suppression is in effect.

## Suppressed bandit IDs

| ID | Reason | Annotation |
|----|--------|------------|
| **B101** (`assert_used`) | pytest's primary assertion mechanism is the bare `assert` statement. Stripped under `python -O`, but tests are never run optimised. | `# nosec B101  # pytest assertion` |

581 / 581 findings carry this annotation. There are zero unannotated findings remaining (re-verify with `uv run --frozen bandit -r sdk/tests/`).

## Out of scope

- No production module under `sdk/ralph_sdk/` was touched in this triage (TAP-1516).
- New bandit IDs that appear in future scans (B602/B603 subprocess, B105/B106 hardcoded passwords, etc.) must be triaged the same way: per-line `# nosec BXXX  # <one-phrase reason>`. **Do not** add `# nosec` without an ID, and do not add `# bandit:skip-file` to a test module.

## Refs

- TAP-1516 — Triage bandit findings in SDK test suite
- Parent epic: TAP-1512
