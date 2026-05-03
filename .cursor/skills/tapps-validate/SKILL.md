---
name: tapps-validate
description: Validate all changed files meet quality thresholds before declaring work complete.
mcp_tools:
  - tapps_validate_changed
---

Validate changed files using TappsMCP:

1. Identify the Python files you changed in this session (from git status or your edit history)
2. Call `tapps_validate_changed` with explicit `file_paths` (comma-separated) scoped to only those files. **Never call without `file_paths`** - auto-detect scans all git-changed files and can be very slow in large repos. Default is quick mode; only use `quick=false` as a last resort (pre-release, security audit).
3. Display each file with its score and pass/fail status
4. If any file fails, list it with the top issue preventing it from passing
5. Confirm explicitly when all changed files pass before declaring work done
6. If any files fail, do NOT mark the task as complete
