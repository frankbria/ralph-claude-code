# Ralph SDK — Claude guidance

This is the Python Agent SDK subtree. Patterns and behavioral guidelines live in [`../CLAUDE.md`](../CLAUDE.md); see [`AGENTS.md`](AGENTS.md) for the SDK-local quick reference.

When editing under `ralph_sdk/`:

- Run `uv run --frozen pytest -x -q` after any change.
- Use `tapps_quick_check(file_path=...)` after each Python edit.
- Use `tapps_validate_changed(file_paths=...)` before declaring done.
- Refactors must be surgical (Karpathy guidelines in `../CLAUDE.md`): extract helpers, add types/docstrings, no speculative abstractions.

When editing under `tests/`: bandit `B101` (`assert_used`) is suppressed per line — see [`tests/SECURITY_NOTES.md`](tests/SECURITY_NOTES.md).
