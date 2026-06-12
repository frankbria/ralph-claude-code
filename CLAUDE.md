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
- **ralph_import.sh** — converts PRD/spec documents to Ralph format; uses `--output-format json` with automatic text fallback for older CLI versions
  - GitHub issue import (Issue #69): `--github-issue <N>` for an exact issue, plus `--repo <owner/repo>`, `--include-comments`
  - Fetches via `gh` into a markdown PRD, then the normal conversion pipeline. Comments off by default (prompt-injection surface); source content is treated as data, not instructions
  - Metadata filtering + selection (Issue #71), implemented in `resolve_github_issue_candidates()` / `select_issue_from_candidates()` / `preview_issue_matches()` (replaced `resolve_github_issue_number()`; "first match" is now oldest, not gh's newest-first):
    - Combinable primary filters: `--github-search <query>`, `--github-label <labels>` (comma = AND), `--github-title <pattern>` (`*` wildcard only, rest literal, case-insensitive), `--github-assignee <user|@me|none>`, `--github-milestone <name>`, `--github-state <open|closed|all>`; modifiers (`--exclude-label <labels>`, `--select`, `--dry-run`) require ≥1 primary filter; `--github-issue` is mutually exclusive with all of them
    - One `gh issue list --limit 500` query (server-side where gh supports it; exclude-label and title matching client-side via jq); candidates sorted oldest-first. Cap-hit handling (gh returns newest-first, so a capped set may be missing the true oldest matches): WARN for server-side-only queries; hard ERROR when client-side filters are active (they could pick the wrong issue or report zero matches over a truncated set)
    - `--select first|interactive|priority` picks among multiple matches: priority understands bare `P0`–`P9` and `priority: PN` labels (ties → oldest, none → first); interactive falls back to first on non-TTY/EOF. `--dry-run` previews the match table + would-be selection without importing
  - Completeness assessment + plan generation (Issue #70): issues are scored 0–100 via `lib/issue_analyzer.sh`; below `--completeness-threshold` (default 60) an implementation plan is generated via Claude CLI (`--plan-model` passthrough) and appended to the PRD before conversion, plus saved to `.ralph/specs/implementation-plan.md`. Flags: `--generate-plan` (force), `--no-generate-plan` (fail if below threshold), `--plan-model <model>`, `--completeness-threshold <0-100>`, `--auto-approve` (skip the approval prompt; non-TTY sessions auto-accept)
- **ralph_queue.sh** — `ralph-queue` command: batch processing and issue queue management (Issue #72). Builds a persistent queue at `.ralph/queue.json` of GitHub issues (reuses `ralph_import.sh`'s `gh` machinery: `resolve_github_issue_candidates`, `fetch_github_issue`, `format_issue_as_prd`) or local PRD specs. Subcommands: `add` (`--github-issues N,N` | filter flags | `--prd <file>`), `status [--json]`, `next`, `remove`, `clear`, `reorder`, `validate`, `process [--halt-on-failure]`, `resume`. The sequential processor stages `.ralph/` from each ready item (priority + dependency order), runs the loop via `RALPH_LOOP_CMD` (default `ralph_loop.sh`; overridable for tests), commits `Fix #N: <title>` per issue, skips failures (or halts), and writes `.ralph/logs/queue_processing.log`. Single branch, no concurrency. See [docs/QUEUE_MANAGEMENT.md](docs/QUEUE_MANAGEMENT.md)
- **GitHub issue lifecycle** (Issue #73): when `ralph` is run with `--github-issue <ref>`, it tracks the issue across the loop via `lib/github_lifecycle.sh`. During development it can post progress comments every N loops (`--comment-progress`, `--comment-interval`); on graceful completion it runs a completion workflow — summary comment (`--close-summary`), PR creation linked with `Closes #N` (`--create-pr --link-issue`, optional `--draft-pr`), grouped follow-up issue from TODO/FIXME markers added during dev (`--create-followups --followup-label`), and issue close with optional labels (`--auto-close --add-label`). All steps are opt-in and degrade gracefully (a gh permission failure is logged and the loop continues). State lives in `.ralph/.github_lifecycle_state`. Uses the `gh` CLI exclusively (not raw REST/`GITHUB_TOKEN`)
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
- **issue_analyzer.sh** — `assess_issue_completeness()`: deterministic 0–100 heuristic scoring of issue PRDs (acceptance criteria +25, checklists/code blocks/sections/keywords/length +15 each); JSON output with `confidence_score`, `completeness_level`, `missing_elements`, `recommendation`; `log_issue_analysis()` for summaries
- **file_protection.sh** — `validate_ralph_integrity()` checks `RALPH_REQUIRED_PATHS` exist; runs every loop iteration; `get_integrity_report()` for recovery instructions
- **log_utils.sh** — `rotate_logs()` rotates `$LOG_DIR/ralph.log` at 10MB, keeping 4 archives (`.log.1`–`.log.4`); GNU `stat -c%s` with BSD `stat -f%z` fallback
- **github_lifecycle.sh** — GitHub issue lifecycle management backing `ralph --github-issue` (Issue #73). `parse_issue_reference` (N | #N | owner/repo#N | URL → number+repo); gh wrappers `gh_issue_comment`/`gh_close_issue`/`gh_add_labels`/`gh_create_pr`/`gh_create_issue` (each logs + returns non-zero on failure, never exits); state primitives `init_github_lifecycle`/`lifecycle_get`/`_lifecycle_apply` (atomic temp+`mv` at `.ralph/.github_lifecycle_state`, program-first signature like `_queue_apply`); generators `generate_progress_comment`/`generate_completion_summary`/`scan_for_todos`; orchestration `lifecycle_post_progress <loop>` (interval-gated) and `lifecycle_on_completion` (summary → PR → followups → close, each flag-guarded, always returns 0). Reuses `lib/date_utils.sh` timestamps
- **sandbox_docker.sh** — Docker sandbox execution backing `ralph --sandbox docker` (Issue #74). Containerizes only the Claude CLI execution: one persistent container per run (`docker run -d … sleep infinity`, project bind-mounted rw at `/workspace`), each iteration wrapped as `docker exec -i -w /workspace <cid> claude …` via `build_sandbox_exec_args`/`wrap_claude_command_for_sandbox` (works in live and background modes); ralph orchestration, analysis, and status.json stay host-side so ralph-monitor is unaffected. `validate_sandbox_config` (image/memory/cpus/network), `init_docker_sandbox` (daemon + image checks with build/pull guidance), `setup_docker_credentials` (ANTHROPIC_API_KEY → 0600 env-file via `--env-file`, else host `~/.claude/.credentials.json` copied into a container-scoped home — never `docker secret`, which needs Swarm), `handle_sandbox_timeout` (exit 124 kills only the docker-exec client → `docker restart` reaps orphans), idempotent `cleanup_docker_sandbox` on all exit paths. State: `.ralph/.docker_sandbox_state` (atomic temp+`mv`). Setup failure is fatal — never falls back to host execution. Config: `SANDBOX_PROVIDER`, `SANDBOX_DOCKER_IMAGE/MEMORY/CPUS/NETWORK` (env > CLI > .ralphrc); sandbox `_env_*` capture sits BEFORE the lib source block in ralph_loop.sh because the lib sets defaults at source time. Default image from GHCR (`docker pull ghcr.io/frankbria/ralph-sandbox:latest`, published on `v*` tags by `.github/workflows/docker-publish.yml` — multi-arch amd64+arm64, smoke-tested before push, dry-run via workflow_dispatch `push=false`; guards in `tests/unit/test_workflow_docker_publish.bats`, Issue #298) or built locally from the repo `Dockerfile` (`docker build -t ralph-sandbox .`; install.sh copies it to `~/.ralph`). `get_sandbox_status` is the provider router for status.json (docker impl renamed `get_docker_sandbox_status`; routes to `get_e2b_sandbox_status` when `SANDBOX_PROVIDER=e2b`)
- **sandbox_e2b.sh** + **e2b_helper.py** — E2B cloud sandbox execution backing `ralph --sandbox e2b` (Issue #75). Same host-side-orchestration model as docker, but the E2B SDK is Python/JS-only, so all transport goes through `lib/e2b_helper.py` (thin CLI over `pip install e2b`: `check`/`create`/`connect`/`info`/`exec`/`upload`/`download`/`ack-download`/`write-file`/`kill`; JSON on stdout, `exec` streams remote output + propagates the remote exit code; secrets only via env/stdin, never argv — tests substitute the interpreter via `SANDBOX_E2B_PYTHON`). No bind mount in the cloud → project uploaded once at start (`git ls-files -coz` + `.ralph` control files, tar over stdin), changed files downloaded after EVERY iteration (sandbox-side `.ralph_sync_marker` mtime; marker advanced via `ack-download` only after host extraction + deletion pass succeed — a missed ack re-delivers the same changes, at-least-once delivery; download runs before git-based progress detection so cloud work counts; `.git` excluded both directions → in-sandbox commits are NOT synced, content arrives as uncommitted host changes). Sandbox-side deletions/renames propagate: each download tar carries a `.ralph_e2b_manifest` member (full workspace file list); host files in `.ralph/.e2b_synced_files` (upload list ∪ synced-down files) that left the manifest are deleted — host-only files and `.git`/`.ralph` paths are never deletion candidates (codex review finding, #75). One sandbox per run, reused across loops; expiry (session `--sandbox-timeout`, default 3600s) detected by the pre-exec liveness probe → fresh create + re-upload. Claude CLI bootstrap: `claude --version` in-sandbox, one `npm install -g @anthropic-ai/claude-code` attempt, else fatal with custom-template guidance. Credentials: `E2B_API_KEY` env or `~/.ralph/e2b_api_key` (0600, never .ralphrc); claude auth via `ANTHROPIC_API_KEY` as sandbox env at create, else host `~/.claude/.credentials.json` seeded over stdin. Cost: estimate = `accrued_cost` (prior sandbox segments) + active runtime × `SANDBOX_E2B_COST_PER_HOUR` (default 0.10); previous segment's cost folded into `accrued_cost` before epoch reset on sandbox recreation so `--sandbox-max-cost` spans the whole run; `--sandbox-cost-alert` warns once, summary in `.ralph/logs/e2b_cost.log` + status.json + monitor Sandbox panel. Exit 124 → remote `pkill -f claude`. `cleanup_e2b_sandbox` (final sync + kill, idempotent) on all exit paths; `--sandbox-keep-alive` skips the kill and logs the id for `--sandbox-id` reuse. State: `.ralph/.e2b_sandbox_state` (atomic temp+`mv`). Setup failure is fatal — never falls back to host execution. Sync filtering (Issue #76, via lib/sync.sh): upload list runs include → exclude → `.ralphignore` → large-file policy with `.ralph` control files force-included past any filter; download extraction selects members explicitly (`-T` list after hard exclusions + user patterns, tar `--exclude` kept as defense in depth) and logs filtered counts; deletion safety — filtered files never enter the synced-files baseline and excluded paths are never deletion candidates (`_apply_e2b_deletions` pipes candidates through the download filter)
- **sync.sh** — backend-agnostic sandbox sync filtering (Issue #76), consumed by sandbox_e2b.sh (Docker needs none — its rw bind mount is real-time by architecture; `--sync-*` flags are rejected with docker). `.ralphignore` parsing (gitignore-like SUBSET: bare name = basename/segment at any depth, `*.ext` basename glob, `dir/` tree, `src/**` full-path glob with `*` crossing `/`; comments/blank dropped, `!negation` unsupported and dropped), `_sync_path_matches_pattern`/`_sync_path_matches_list` matchers, `sync_filter_file_list` (upload, NUL-separated: include → exclude → `.ralphignore` → size policy), `sync_filter_download_list` (download, newline-separated: exclude + `.ralphignore` only — include deliberately not applied so new artifacts come back; size policy upload-only), `validate_sync_config`, `_sync_file_size` (GNU/BSD stat), `format_sync_size`, `log_sync_summary`. Config: `SYNC_INCLUDE`/`SYNC_EXCLUDE` (comma-separated; CLI `--sync-include`/`--sync-exclude`), `SYNC_MAX_FILE_SIZE` (default 10485760, 0=unlimited), `SYNC_LARGE_FILE_ACTION` (warn|skip). `_env_*` capture sits BEFORE the lib source block in ralph_loop.sh (lib sets defaults at source time). Git-based sync + E2B realtime sync deliberately descoped (conflicts with the `.git`-exclusion safety model) — see docs/SANDBOX_SYNC.md
- **queue_manager.sh** — queue state primitives backing `ralph-queue` (Issue #72). State at `.ralph/queue.json` (`{version, created_at, updated_at, repository, queue:[…]}`); entries carry `id`/`source` (`github`|`prd`)/`issue_number`/`path`/`title`/`priority`/`labels`/`milestone`/`dependencies`/`status`/timestamps. Functions: `init_queue`, `add_to_queue` (dedupe by id, fills defaults; rc 0/1/2), `remove_from_queue`, `clear_queue`, `mark_issue_status` (validates status, stamps started/completed), `get_queue_status` (counts JSON), `sort_queue_by_priority` (rank then FIFO), `get_priority_from_labels` (reuses the P0–P9 / `priority: PN` parser), `parse_issue_dependencies` (`depends on/blocked by/requires #N`), `is_dependency_satisfied`, `get_next_issue` (ready+priority+FIFO), `validate_dependencies` (jq cycle detection). All mutations are atomic temp-file+`mv` via `_queue_apply`

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

### GitHub Issue Lifecycle (Issue #73)
```bash
# Track an issue and post progress comments every 5 loops
ralph --github-issue 69 --comment-progress --comment-interval 5

# On completion: open a PR that closes the issue, then close it with a summary
ralph --github-issue 69 --create-pr --link-issue --close-summary --auto-close

# Add labels on close and open a follow-up issue for any TODO/FIXME left behind
ralph --github-issue owner/repo#69 --auto-close --add-label completed \
      --create-followups --followup-label tech-debt

# Draft PR for manual review before merge
ralph --github-issue 69 --create-pr --draft-pr
```
All lifecycle flags are opt-in and require `--github-issue`. Each GitHub operation
degrades gracefully — a permission failure is logged and the loop continues.

### Batch Processing / Issue Queue (Issue #72)
```bash
# Build a queue (GitHub issues or local PRDs)
ralph-queue add --github-label "bug,P0"      # filters reuse the ralph-import flags
ralph-queue add --github-issues 69,70,71     # explicit list
ralph-queue add --github-milestone "v1.0"
ralph-queue add --prd ./docs/feature.md

# Manage
ralph-queue status [--json]      # also: ralph --queue-status
ralph-queue next                 # also: ralph --queue-next
ralph-queue reorder              # sort by priority (P0 first)
ralph-queue validate             # detect circular dependencies
ralph-queue remove 69            # also: ralph --queue-remove 69
ralph-queue clear                # also: ralph --queue-clear

# Process sequentially (priority + dependency order; one commit per issue)
ralph --process-queue            # also: ralph-queue process
ralph --process-queue --halt-on-failure
ralph --resume-queue             # continue remaining pending items
```

### Docker Sandbox Execution (Issue #74)
```bash
docker pull ghcr.io/frankbria/ralph-sandbox:latest          # One time: official image (published on v* tags)
docker tag ghcr.io/frankbria/ralph-sandbox:latest ralph-sandbox:latest
# ...or build locally: docker build -t ralph-sandbox .  (or ~/.ralph post-install)

ralph --sandbox docker                   # Run Claude in an isolated container
ralph --sandbox docker --sandbox-image node:20 --sandbox-memory 8g --sandbox-cpus 4
ralph --sandbox docker --sandbox-network none   # Full isolation (blocks Claude API — special images only)
ralph --monitor --sandbox docker         # Flags forwarded through tmux
```
Providers daytona/cloudflare are rejected as not supported (#79/#80 closed as not planned — Docker + E2B are the final provider set). Sub-flags require their provider (docker sub-flags pair only with `--sandbox docker`, E2B sub-flags only with `--sandbox e2b`). See [docs/DOCKER_SANDBOX.md](docs/DOCKER_SANDBOX.md).

### E2B Cloud Sandbox Execution (Issue #75)
```bash
pip install e2b                          # One time: the SDK transport
export E2B_API_KEY="e2b_..."             # or ~/.ralph/e2b_api_key (chmod 600)

ralph --sandbox e2b                      # base template; claude CLI auto-bootstrapped via npm
ralph --sandbox e2b --sandbox-template my-template --sandbox-timeout 7200
ralph --sandbox e2b --sandbox-max-cost 5.00 --sandbox-cost-alert 2.00   # budget controls
ralph --sandbox e2b --sandbox-keep-alive # leave running; reuse with --sandbox-id <id>
ralph --monitor --sandbox e2b            # Flags forwarded through tmux; cost in monitor panel
ralph --sandbox e2b --sync-include "src/**,tests/**" --sync-exclude "*.log,node_modules"   # sync filtering (#76)
```
Project uploads once at start; changed files sync back after every iteration (in-sandbox commits are NOT synced — `.git` excluded both directions). Sync filtering: `--sync-include`/`--sync-exclude` (e2b only), `.ralphignore`, `SYNC_MAX_FILE_SIZE`/`SYNC_LARGE_FILE_ACTION` in `.ralphrc`. See [docs/E2B_SANDBOX.md](docs/E2B_SANDBOX.md) and [docs/SANDBOX_SYNC.md](docs/SANDBOX_SYNC.md).

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
- All items in `.ralph/fix_plan.md` marked complete — but unchecked items under **optional sections** are excluded (Issue #239). `_count_blocking_unchecked()` (awk, section-aware) counts only unchecked `- [ ]` items NOT under a heading whose title matches `OPTIONAL_SECTIONS` (default `"Optional,Future,Future Enhancements,Nice to Have"`, case-insensitive, comma-separated, configurable in `.ralphrc`). Optional context persists into deeper subsections and closes at the next same-or-higher-level heading. This resolves the deadlock where Claude treats "Low Priority"/optional items as skippable while Ralph keeps looping for them. With no optional sections present, behavior is identical to the prior full-file count (backward compatible)

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
- `tests/e2e/test_full_loop.bats` runs ralph_loop.sh as a real subprocess with an executable mock `claude` CLI (`tests/e2e/helpers/e2e_helper.bash`). The mock must take >1s per call — ralph's early-failure detection treats sub-second exits as startup failures. Raw `.ralph/.call_count` assertions go through `assert_call_count`, which skips only when the run itself crossed an hour boundary (the hourly rate-limit reset legitimately zeroes the counter — Issue #285); `mock_call_count` stays the unconditional invocation proof
- **Test pass rate (100%) is the quality gate.** Coverage measurement with kcov is informational only (`COVERAGE_THRESHOLD=0`): kcov cannot instrument subprocesses spawned by bats (see [bats-core#15](https://github.com/bats-core/bats-core/issues/15))

## CI/CD Pipeline

GitHub Actions (`.github/workflows/`):
- **test.yml** — unit, integration, E2E on push to `main`/`develop` and PRs to `main`; unit and E2E suites are blocking, integration is currently advisory (`|| true`); kcov coverage uploaded as informational artifact
- **docker-publish.yml** — builds + publishes the ralph-sandbox image to GHCR on `v*` tags (Issue #298): amd64 smoke test (`claude --version` as non-root) gates the multi-arch (amd64+arm64) push; `workflow_dispatch` with `push=false` (default) is a dry-run usable from any branch; auth is the workflow `GITHUB_TOKEN` only
- **claude.yml** / **claude-code-review.yml** — Claude Code GitHub Actions integration and automated PR review
- **Supply-chain hardening (Issue #275)**: all external actions in the hand-maintained workflows are pinned to full commit SHAs with `# vX.Y.Z` tag comments; `.github/dependabot.yml` (github-actions ecosystem, weekly, grouped) keeps pins updated; `tests/unit/test_workflow_sha_pinning.bats` is the regression guard. When adding an action, pin its SHA (resolve via `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`, dereference annotated tags) — the guard fails on mutable tags
- **Credential hygiene (Issue #282)**: every `actions/checkout` step sets `persist-credentials: false` (guard: `tests/unit/test_workflow_credential_hygiene.bats`). Safe even for the claude workflows — claude-code-action strips checkout's auth header (`configureGitAuth`) and uses its own GitHub App token for git operations

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
- **Commands** → `~/.local/bin/`: `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-queue`, `ralph-migrate`, `ralph-enable`, `ralph-enable-ci`, `ralph-stats`
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
