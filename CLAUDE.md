# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Ralph for Claude Code — an autonomous AI development loop system enabling continuous development cycles with intelligent exit detection and rate limiting. See [README.md](README.md) for version info, changelog, and user documentation.

## Core Architecture

### Main Scripts

- **ralph_loop.sh** — main autonomous loop that executes Claude Code repeatedly
- **ralph_monitor.sh** — live monitoring dashboard for tracking loop status
- **setup.sh** — project initialization for new Ralph projects
- **create_files.sh** — bootstrap script that creates the entire Ralph system
- **ralph_import.sh** — converts PRD/spec documents to Ralph format; uses `--output-format json` with automatic text fallback for older CLI versions. Also imports single GitHub issues (`--github-issue <N>`, `--github-search <query>`, `--github-label <label>`, optional `--repo <owner/repo>`): fetches via `gh`, formats title/body/comments as a markdown PRD, and reuses the same conversion pipeline (Issue #69)
- **ralph_enable.sh** — interactive wizard enabling Ralph in existing projects (environment detection, task source selection, generates `.ralphrc`)
- **ralph_enable_ci.sh** — non-interactive version for CI/automation; `--json` output mode; exit codes: 0 (success), 1 (error), 2 (already enabled)

### Library Components (lib/)

- **circuit_breaker.sh** — prevents runaway loops via stagnation detection. States: CLOSED (normal) → HALF_OPEN (monitoring) → OPEN (halted), with automatic transitions and recovery. State file: `.ralph/.circuit_breaker_state` (JSON)
- **response_analyzer.sh** — analyzes Claude output for completion signals. Parses JSON (flat and Claude CLI formats) with text fallback; extracts status, exit_signal, work_type, files_modified, asking_questions, question_count. `detect_questions()` catches Claude asking questions instead of acting autonomously (Issue #190). Session management: session ID persisted to `.ralph/.claude_session_id` (24-hour expiration), transition history in `.ralph/.ralph_session_history` (last 50), lifecycle state in `.ralph/.ralph_session` (JSON: `session_id`, `created_at`, `last_used`, `reset_at`, `reset_reason`). Sessions auto-reset on circuit breaker open, manual interrupt, or project completion. Also detects test-only loops, stuck error patterns, and question-only loops
- **date_utils.sh** — cross-platform date utilities; `parse_iso_to_epoch()` for cooldown timer comparisons
- **timeout_utils.sh** — `portable_timeout()`: GNU `timeout` on Linux, `gtimeout` (Homebrew coreutils) on macOS, auto-detected with caching
- **enable_core.sh** — shared enable logic: idempotency checks (`is_ralph_enabled()`), safe file operations, project/git/task-source detection, template generation (`generate_prompt_md()`, `generate_ralphrc()`, etc.)
- **wizard_utils.sh** — interactive prompt utilities (confirm, select, print helpers); POSIX-compatible (`tr` instead of `${,,}`) for bash 3.x support
- **task_sources.sh** — task import from beads, GitHub Issues, and PRD documents (checkbox and numbered list formats); normalization and prioritization
- **file_protection.sh** — `validate_ralph_integrity()` checks `RALPH_REQUIRED_PATHS` exist; runs every loop iteration; `get_integrity_report()` for recovery instructions
- **log_utils.sh** — `rotate_logs()` rotates `$LOG_DIR/ralph.log` at 10MB, keeping 4 archives (`.log.1`–`.log.4`); GNU `stat -c%s` with BSD `stat -f%z` fallback

## Key Commands

### Installation
```bash
./install.sh             # Install Ralph globally (run once)
./install.sh uninstall   # Uninstall
```

### Project Setup
```bash
ralph-setup my-project-name   # Create a new Ralph-managed project
ralph-migrate                 # Migrate flat structure to .ralph/ subfolder (v0.10.0+)

# Enable Ralph in an existing project
ralph-enable                              # Interactive wizard
ralph-enable --from beads
ralph-enable --from github --label "sprint-1"
ralph-enable --from prd ./docs/requirements.md
ralph-enable --force                      # Overwrite existing .ralph/

ralph-enable-ci [--from github] [--project-type typescript] [--json]   # Non-interactive
```

### Running the Loop
```bash
ralph --monitor                  # Start with integrated tmux monitoring (recommended)
ralph                            # Start without monitoring
ralph --monitor --calls 50 --prompt my_custom_prompt.md
ralph --status                   # Check current status

# Circuit breaker
ralph --reset-circuit
ralph --circuit-status
ralph --auto-reset-circuit       # Auto-reset OPEN state on startup

ralph --reset-session            # Reset session state manually

# Backup and rollback (requires git)
ralph --backup                   # (-b) Enable automatic backup before each loop
ralph --rollback                 # List available backup branches
ralph --rollback ralph-backup-loop-3-1775155286   # Roll back to a specific backup
```

### Monitoring
```bash
ralph-monitor                    # Manual monitoring in separate terminal
tmux list-sessions / tmux attach -t <session-name>
```

### Testing
```bash
npm test                         # All tests
npm run test:unit / test:integration / test:e2e
bats tests/unit/test_cli_parsing.bats   # Individual file
```

## Ralph Loop Configuration

Loop control files live in the `.ralph/` subfolder:

- **.ralph/PROMPT.md** — main prompt driving each loop iteration
- **.ralph/fix_plan.md** — prioritized task list Ralph follows
- **.ralph/AGENT.md** — build/run instructions maintained by Ralph
- **.ralph/status.json** — real-time status tracking
- **.ralph/logs/** — execution logs per iteration

### Rate Limiting
- Default: 100 API calls/hour (`--calls` flag); automatic hourly reset with countdown; counters persist across restarts
- Optional token limit via `MAX_TOKENS_PER_HOUR` in `.ralphrc` (0 = disabled, default). Extracts `input_tokens + output_tokens` from each response (stream-json and CLI formats); blocks calls once the hourly budget is exhausted; call and token counters reset together on the hour

### Modern CLI Configuration

```bash
CLAUDE_CODE_CMD="claude"              # CLI command; configurable via .ralphrc for e.g. "npx @anthropic-ai/claude-code"
CLAUDE_OUTPUT_FORMAT="json"           # json (default) or text
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),...,Bash(npm *),Bash(pytest)"
CLAUDE_USE_CONTINUE=true              # Session continuity
CLAUDE_MIN_VERSION="2.0.76"           # Minimum Claude CLI version
CLAUDE_AUTO_UPDATE=true               # Auto-update Claude CLI at startup
CLAUDE_MODEL=""                       # --model override (e.g. claude-sonnet-4-6); empty = CLI default
CLAUDE_EFFORT=""                      # --effort override (high/low); empty = CLI default
ENABLE_NOTIFICATIONS=false            # Desktop notifications; or --notify / -n
ENABLE_BACKUP=false                   # Git backup branches; or --backup / -b
```

- **CLAUDE_CODE_CMD**: auto-detected during `ralph-enable`/`ralph-setup` (prefers `claude`, falls back to npx); validated at startup with `validate_claude_command()` (clear install instructions on failure), then `check_claude_version()` and `check_claude_updates()` run. Version comparisons use `compare_semver()` (proper major→minor→patch, safe for any patch number). Environment variable takes precedence over `.ralphrc`
- **CLAUDE_AUTO_UPDATE**: keep `true` on workstations (200-500ms overhead is negligible); set `false` in Docker (version pinned at image build) and air-gapped environments (registry unreachable). Update failure is non-blocking — Ralph logs a warning and continues
- **CLAUDE_MODEL / CLAUDE_EFFORT**: set in `.ralphrc` or as env vars (env takes precedence); applied as `--model`/`--effort` flags on every invocation
- **CLI options**: `--output-format json|text` (`--live` requires JSON and auto-switches), `--allowed-tools "..."`, `--no-continue` (fresh session each loop)

**Loop context**: each iteration injects context via `build_loop_context()` — loop number, remaining fix_plan.md tasks, circuit breaker state (if not CLOSED), previous loop summary, and corrective guidance if the previous loop detected questions.

## Exit Detection

Exit requires BOTH conditions (dual-condition check prevents premature exits):

1. `recent_completion_indicators >= 2` (heuristic detection from natural language patterns)
2. Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block, read from `.ralph/.response_analysis` (`.analysis.exit_signal`)

| completion_indicators | EXIT_SIGNAL | .response_analysis | Result |
|-----------------------|-------------|-------------------|--------|
| >= 2 | `true` | exists | **Exit** ("project_complete") |
| >= 2 | `false` | exists | **Continue** (Claude still working) |
| >= 2 | N/A | missing/malformed | **Continue** (defaults to false) |
| < 2 | `true` | exists | **Continue** (threshold not met) |

**Conflict resolution**: when `STATUS: COMPLETE` but `EXIT_SIGNAL: false`, the explicit EXIT_SIGNAL wins — Claude can mark a phase complete while more phases remain.

**Mode-specific heuristics (Issue #224)**: completion keywords like "done" in generated docs or tool output caused false-positive exits, so two defences are layered:
- **JSON mode** (default): heuristics suppressed entirely — only an explicit `EXIT_SIGNAL: true` in a RALPH_STATUS block can set `exit_signal=true`
- **Text mode**: requires `confidence_score >= 70` AND `has_completion_signal=true` (the old `>= 40 OR has_completion_signal` was too sensitive to documentation language)

**Other exit conditions** (checked before completion indicators):
- `MAX_CONSECUTIVE_DONE_SIGNALS=2` — repeated "done" signals from Claude
- `MAX_CONSECUTIVE_TEST_LOOPS=3` — too many test-only iterations (feature completeness)
- `TEST_PERCENTAGE_THRESHOLD=30%` — flag if testing dominates recent loops
- All items in `.ralph/fix_plan.md` marked complete

**Startup state reset (Issue #194)**: every `ralph` invocation unconditionally resets `.exit_signals` and removes `.response_analysis` before the main loop, so stale completion signals from a prior run (crash, SIGKILL, API-limit exit) can't trigger `should_exit_gracefully()` on the first iteration. The API-limit "user chose exit" path also calls `reset_session()`.

### Timeout Handling (Issues #175, #198)

When Claude Code exceeds `CLAUDE_TIMEOUT_MINUTES`, `portable_timeout` kills the process with exit code **124**. Live mode (`--live`/`--monitor`) captures per-command exit codes via `PIPESTATUS` and logs a WARN; background mode captures via `wait $claude_pid`.

**Productive timeout detection**: on exit 124, the handler checks git for work done during execution (HEAD vs `.loop_start_sha`):

| Timeout + git state | Result |
|---|---|
| Files changed (committed/staged/unstaged) | **Productive**: runs full analysis pipeline, writes `timed_out_productive` status, returns 0 |
| No files changed | **Idle**: returns 1 (generic error) |

**Session ID fallback**: when the stream is truncated (missing `"type":"result"`), session ID is extracted from the `"type":"system"` message, which is written first and survives truncation.

### API Limit Detection (Issues #183, #100)

Four-layer approach to avoid false positives — in stream-json mode, output files contain echoed file content from tool results (`"type":"user"` lines), so naive grep on "5-hour limit" matches project files and falsely triggers recovery:

1. **Timeout guard**: exit 124 checked first; never returns code 2 (API limit)
2. **Structural JSON detection (primary)**: parses `rate_limit_event` JSON for `"status":"rejected"` — the definitive CLI signal
3. **Filtered text fallback**: searches only `tail -30`, filtering out `"type":"user"`, `"tool_result"`, `"tool_use_id"` lines before pattern matching
4. **Extra Usage quota**: detects "You're out of extra usage" exhaustion with the same noise filtering

**Unattended mode**: if the API-limit prompt times out (30s, no user response), Ralph auto-waits instead of exiting.

### Circuit Breaker

Thresholds:
- `CB_NO_PROGRESS_THRESHOLD=3` — open after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` — open after 5 loops with repeated errors
- `CB_OUTPUT_DECLINE_THRESHOLD=70%` — open if output declines >70%
- `CB_PERMISSION_DENIAL_THRESHOLD=2` — open after 2 loops with permission denials

**Question loop suppression (Issue #190)**: when `asking_questions=true`, `consecutive_no_progress` is held steady (not incremented) so the breaker doesn't open prematurely when Claude asks questions in headless mode; a corrective message is injected via `build_loop_context()` next iteration.

**Auto-recovery (Issue #160)** — OPEN is not terminal:
```bash
CB_COOLDOWN_MINUTES=30    # Minutes before OPEN → HALF_OPEN on next init_circuit_breaker() (0 = immediate)
CB_AUTO_RESET=false       # true = bypass cooldown, reset to CLOSED on startup (unattended operation)
```
CLI flag `ralph --auto-reset-circuit` sets `CB_AUTO_RESET=true` for one run. The `opened_at` state field tracks when the circuit opened; old state files without it fall back to `last_change`.

### Permission Denial Detection (Issue #101)

When Claude Code is denied a command (e.g., `npm install`), Ralph extracts the `permission_denials` array from JSON output (`has_permission_denials`, `permission_denial_count`, `denied_commands`) and exits immediately with reason "permission_denied", displaying instructions to update `ALLOWED_TOOLS` in `.ralphrc`:

```bash
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"   # Broad (recommended for dev)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git commit),Bash(npm install)"    # Restrictive
```

### API Error Detection via `is_error` (Issues #134, #199)

The Claude CLI can exit 0 but set `is_error: true` for API-level failures (400 concurrency, 401 OAuth expiry). After exit 0, `execute_claude_code()` checks `.is_error` via jq **before persisting session state**: if true, the session is NOT persisted and is explicitly reset so the next loop starts fresh (prevents infinite retry with a bad session ID). "Tool use concurrency" errors get a targeted reset reason. `save_claude_session()` independently guards on `is_error` (defense in depth against refactored call order).

### Error Detection

Two-stage filtering eliminates false positives:

1. **JSON field filtering**: strips field patterns like `"is_error": false` that contain "error" but aren't errors — `grep -v '"[^"]*error[^"]*":'`
2. **Actual error detection**: `grep -cE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'`

**Multi-line error matching**: stuck-loop detection verifies ALL error lines appear in ALL recent history files, using literal `grep -qF` to avoid regex edge cases and false negatives when multiple distinct errors occur.

### File Protection (Issue #149)

Multi-layered defense against Claude deleting Ralph's own config:

1. **ALLOWED_TOOLS restriction**: defaults use granular `Bash(git add *)`, `Bash(git commit *)` instead of `Bash(git *)` — blocks `git clean`, `git rm`, etc. Users can override in `.ralphrc`
2. **PROMPT.md warning**: template includes a "Protected Files (DO NOT MODIFY)" section covering `.ralph/` and `.ralphrc`
3. **Pre-loop integrity check**: `validate_ralph_integrity()` runs at startup and before every iteration. On failure: logs error, displays recovery report, resets session, halts. Recovery: `ralph-enable --force`

| Required (validation fails) | Optional (no validation) |
|---|---|
| `.ralph/`, `.ralph/PROMPT.md`, `.ralph/fix_plan.md`, `.ralph/AGENT.md`, `.ralphrc` | `.ralph/logs/`, `.ralph/status.json`, `.ralph/.call_count`, `.ralph/.exit_signals`, `.ralph/.circuit_breaker_state` |

## Test Suite

Tests use bats, organized under `tests/unit/`, `tests/integration/`, and `tests/e2e/` (helpers in `tests/helpers/`). Run via `npm test` (all), `npm run test:unit` / `test:integration` / `test:e2e`, or `bats <file>` for one file. `npm test` reports the current count.

- File naming maps to subject: e.g. `test_circuit_breaker_recovery.bats`, `test_cli_modern.bats`, `test_exit_detection.bats`, `test_enable_core.bats` — add tests to the file matching the component you changed
- `tests/e2e/test_full_loop.bats` runs ralph_loop.sh as a real subprocess with an executable mock `claude` CLI (`tests/e2e/helpers/e2e_helper.bash`). The mock must take >1s per call — ralph's early-failure detection treats sub-second exits as startup failures
- **Test pass rate (100%) is the quality gate.** Coverage measurement with kcov is informational only (`COVERAGE_THRESHOLD=0`): kcov cannot instrument subprocesses spawned by bats (see [bats-core#15](https://github.com/bats-core/bats-core/issues/15))

## CI/CD Pipeline

GitHub Actions (`.github/workflows/`):
- **test.yml** — unit, integration, E2E on push to `main`/`develop` and PRs to `main`; unit and E2E suites are blocking, integration is currently advisory (`|| true`); kcov coverage uploaded as informational artifact
- **claude.yml** / **claude-code-review.yml** — Claude Code GitHub Actions integration and automated PR review

## Ralph-Managed Project Structure

```
project-name/
├── .ralph/                # Ralph configuration and state
│   ├── PROMPT.md          # Main development instructions
│   ├── fix_plan.md        # Prioritized TODO list
│   ├── AGENT.md           # Build/run instructions
│   ├── specs/  examples/  logs/  docs/generated/
└── src/                   # Source code at project root
```

- Hidden files in `.ralph/` (`.call_count`, `.exit_signals`, …) track loop state
- `docs/code-review/` (project root) for code review reports
- Templates in `templates/` (PROMPT.md, fix_plan.md, AGENT.md) seed new projects — keep them current when patterns change
- Existing flat-structure projects migrate with `ralph-migrate`

## Global Installation

`./install.sh` installs:
- **Commands** → `~/.local/bin/`: `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-migrate`, `ralph-enable`, `ralph-enable-ci`, `ralph-stats`
- **Scripts + templates** → `~/.ralph/` (main scripts, `templates/`, `lib/`)

**External dependencies**: Claude Code CLI (execution engine), tmux (integrated monitoring), git (projects must be repos), jq (JSON processing), standard Unix tools.

## Development Standards

All features must meet these requirements before being considered complete:

- **Tests**: 100% pass rate, no exceptions. Unit tests for bash functions, integration tests for loop behavior, E2E for full cycles. Tests validate behavior, not coverage metrics; comment complex test strategies
- **v2 UI (when introduced)**: Playwright E2E against real services (no mocked APIs) is the primary quality gate — happy-path coverage for every user-facing workflow, screenshot comparisons for layout-critical components, a11y checks (`@axe-core/playwright`), passing in CI before merge
- **Git**: conventional commits with scope (`feat(loop):`, `fix(monitor):`, `test(setup):`); feature branches only (`feature/<name>`, `fix/<issue>`), never commit directly to `main`; push completed work and ensure CI passes; PRs for all significant changes
- **Ralph integration**: update `.ralph/fix_plan.md` before starting work and mark items complete when done; test the Ralph loop with new features
- **Documentation sync**: update this CLAUDE.md (Key Commands, exit conditions, new behaviors), README feature lists/examples, and `templates/` whenever the implementation changes; remove outdated comments immediately; document breaking changes prominently

AI agents should apply these standards automatically to all feature development without explicit instruction.
