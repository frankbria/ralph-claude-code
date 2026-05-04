# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [2.12.0] — 2026-05-04

SDK bumped to **2.2.0** alongside this release (TAP-1104 + TAP-542 + per-task model routing all touch the SDK surface).

### Added

- **TAP-542 — SDK quality gate (ruff + mypy + pytest-asyncio + pytest-timeout).** New blocking CI job `sdk-quality` runs alongside the bash test job. `ruff check` (E/W/F/I/B/UP families), `mypy` (pragmatic disable list for the str+Enum classes pending a follow-up StrEnum migration), `pytest-asyncio` mode=auto for the ~50 async tests, and a 30s `pytest-timeout` default. UP042 deferred — see `sdk/pyproject.toml` for the rationale. Documented `TracerProtocol` for the previously `Any | None` tracer parameter.
- **TAP-1201 — ralph-monitor mid-loop visibility + accurate liveness detection.** New `_classify_liveness` (`HEALTHY` / `STALE` / `DEAD` / `UNKNOWN`) factors in `status.json` mtime, `live.log` mtime within `LIVE_LOG_FRESH_SECS` (default 60s), and `ralph_loop.sh` PID liveness via `pgrep`. `DEAD` now requires BOTH stale `status.json` AND no live process — the conditions that masked the April-2026 NLTlabsPE Loop 1 false alarm. Added always-render "Working on:" / "Model:" rows with `(awaiting first loop)` placeholders. New PreToolUse hook `templates/hooks/on-linear-tool.sh` writes `.ralph/.current_issue` atomically when Claude calls a Linear MCP tool; per-project opt-in via `.claude/settings.json` matcher `mcp__plugin_linear_linear__.*`.
- **Per-task complexity-based model routing in the SDK.** New `model_routing_enabled` config flag (default off; opt-in). When enabled, `_build_claude_command` routes each Claude CLI invocation to the cheapest model that can credibly do the work (haiku → sonnet floor → opus) based on the next unchecked `fix_plan` task. Mirrors the bash `lib/complexity.sh::ralph_select_model` contract.
- **TAP-540 — first-time BATS coverage for `lib/github_issues.sh`.** 19 cases covering repo detection (SSH/HTTPS/missing remote), input validation (TAP-651 regression guard), happy-path import, gh failure modes (404/403/429/malformed JSON), label/assignee filters, idempotent re-import, batch processing, and assessment scoring. PATH-shim a fake `gh` binary controlled by env vars; stub `git remote get-url origin` via function shadowing.

### Changed

- **TAP-1104 — SDK only supports agent mode (mirror of bash ADR-0006).** Removed `use_agent` field + every reader (env / JSON / .ralphrc / export round-trip). `_build_claude_command` always emits `--agent <name>` and never emits `--allowedTools`. Bumped `claude_min_version` default `2.0.76 → 2.1.0` and added `_preflight_claude_version` that runs at `RalphAgent.run()` start; raises `RalphConfigError` (new typed exception) when the installed CLI is older. Cannot-detect degrades to a WARN log to mirror bash `check_claude_version`.
- **`HOOKS-2: hook scripts reference a known hook directory`** rewritten to accept BOTH `.ralph/hooks/` and `.claude/hooks/`. Original test rejected `.claude/hooks/` entries and broke as soon as tapps-mcp registered hooks there.
- **`all hook commands start with 'bash '`** widened to also accept the bare `.claude/hooks/<name>.sh` form that tapps-mcp / linear-MCP plugins emit. Still catches tool names (Write/Edit) or garbage strings landing in `command` fields.
- **`PreToolUse has exactly two entries`** rewritten as a positive invariant check: Ralph's Bash hook must wire to `validate-command.sh` AND its Edit|Write hook must wire to `protect-ralph-files.sh`. Plugin-injected entries are allowed; what is protected is removal or rewiring of Ralph's own defenses.
- **`.gitignore`** adds 7 new runtime-state entries (`.ralph/.model_routing.jsonl`, `.qa_failures.json`, `.current_issue`, `.coordinator_session`, `brief.json`, `forensic-*/`).
- **`docs/epics/`** committed: docs-mcp-generated epic + 9 story specs that previously lived untracked in working trees.

### Fixed

- **TAP-668 — Dockerfile.sandbox HEALTHCHECK readability + HOME env for ralph user.** Three concrete bugs: `ENV HOME=/home/ralph` was missing (npm/gh/claude config writes silently failed under the dropped user with `$HOME=/`); `HEALTHCHECK` used `test -f` which couldn't distinguish missing-file from permission-denied (now `test -r`); failure now emits a stderr cause line so `docker inspect --format='{{json .State.Health}}'` shows the actual reason. Documented bind-mount UID alignment requirement above `WORKDIR`.
- **Test count mismatch (`Executed 1455 instead of expected 1456 tests`).** Removed dead `dry_run_simulate logs allowed tools count` test in `tests/unit/test_log_rotation_dryrun.bats`. Asserted on a `CLAUDE_ALLOWED_TOOLS` log line that ADR-0006 deleted; sourcing `ralph_loop.sh` in the bats env triggered the post-ADR-0006 startup `exit`, so bats counted the @test in `1..N` but never produced an `ok N` line. Surfaced once the previously inactive Test Suite workflow was enabled.
- **Two integration tests asserting `setup.sh` ships `ALLOWED_TOOLS=...` in `.ralphrc`** replaced with a single negative invariant (`! grep -qE '^ALLOWED_TOOLS=' .ralphrc`) so the legacy field stays deleted.
- **One eval test (`FILE PROTECTION: blocks edit to .ralphrc`)** was asserting the wrong half of the hook contract — it ran with no `.ralphrc` fixture, but the hook's contract (HOOKS-5) is allow-create-when-absent / block-edit-when-present. Split into two tests covering both halves.
- **`.github/workflows/codeql-analysis.yml`** now pins `defaults.run.shell: bash` per TAP-667. Was the only hand-authored workflow without this; only became visible to CI once the Test Suite workflow was enabled.

### CI / Infrastructure

- **Test Suite workflow enabled.** `gh workflow enable "Test Suite"` registered the previously inactive workflow, giving end-to-end CI signal on every PR for the first time in this version range. The previously-undetected gaps fixed under "Fixed" above were all surfaced by this single change.

---

## [2.11.5] — 2026-05-02

### Changed

- **TappsMCP tooling refresh to 3.8.0.** Ran `tapps_upgrade` to resync project-managed agents, skills, hooks, and platform configs against TappsMCP 3.8.0. `AGENTS.md` excised the Karpathy block and refreshed the platform-hooks section. Claude Code platform: `CLAUDE.md` updated; new hooks (`tapps-pre-bash.sh`, `tapps-pre-linear-write.sh`, `tapps-pre-linear-list.sh`, `tapps-post-docs-validate.sh`, `tapps-post-linear-snapshot-get.sh`); 4 tapps agents and 14 skills updated; 2 new skills (`linear-read`, `linear-release-update`); new `.claude/rules/integration-hygiene.md`. Cursor platform: regenerated MCP config, 4 agents + 15 skills + 3 cursor rule types. GitHub: Copilot agent profiles, path instructions, issue/PR templates, dependabot, and ruleset scripts created; CodeQL workflow updated. Backup at `.tapps-mcp/backups/2026-05-02-171935`. No Ralph runtime behavior changed — tooling/dev-environment refresh only.

---

## [2.11.4] — 2026-04-30

### Fixed

- **Session-ID lazy-init was a lie (chronic `session_id is empty` warning).** `ralph_initialize_session` wrote `session_id: ""` "for lazy init" — but the lazy-init step that was supposed to fill it later never existed. `save_claude_session` writes the Claude CLI's session ID to `.claude_session_id` (a separate file), not `.ralph_session`. `get_session_id()` is also vestigial — defined but called nowhere. Net effect: every loop fired `WARN: Session file exists but session_id is empty — reinitializing`, the function rewrote empty, the next loop warned again, forever. The fix has `ralph_initialize_session` generate a real Ralph-internal ID via the existing `generate_session_id` helper (matching `init_session_tracking`'s pattern) so the file always has a non-empty session_id when valid. The misleading `(awaiting session_id from next Claude invocation)` log line is replaced with the actual generated id.

### Changed

- **Coordinator timeout configurable + default raised 60s → 120s.** The TAP-915 coordinator sub-agent that writes `.ralph/brief.json` had a hardcoded `timeout 60` that was too tight for setups with multiple MCP servers (tapps-mcp, docs-mcp, tapps-brain, Linear plugin) — the coordinator's `session_start` + Linear queue scan + brief write often exceeds 60s on cold start. NLTlabsPE saw 3 timeouts in 10 loops at the old default. New env var `RALPH_COORDINATOR_TIMEOUT_SECONDS` (default `120`); set `0` to disable the timeout altogether. The coordinator's failure log now distinguishes `timed out after Ns` (rc=124) from `spawn failed (exit N)` so the operator can tell whether to raise the timeout or debug a CLI/agent-config issue. Original "spawn failed or timed out" generic message removed.

### Tests

- 3 new regression tests in `tests/unit/test_session_init_repair.bats`:
  - `SESSION-ID-FIX: ralph_initialize_session writes a non-empty session_id` — asserts the generated id matches the canonical `ralph-<epoch>-<rand>` format.
  - `SESSION-ID-FIX: ralph_validate_session does NOT loop after ralph_initialize_session` — repro of the chronic-warning loop; asserts validate returns 0 with no `session_id is empty` warning after initialize.
  - `SESSION-ID-FIX: log message names the generated id` — asserts the misleading `awaiting session_id` text is gone.
- 1 new regression test in `tests/unit/test_coordinator_spawn.bats`:
  - `COORDINATOR-TIMEOUT: rc=124 emits 'timed out' message + names the env var to raise` — asserts the rc=124 path now emits the duration and the env var name so operators know the lever.
- Existing `TAP-915: spawn failure WARNs and leaves no brief` test updated: mock now returns rc=1 (generic spawn failure) instead of 124 (timeout), and asserts the new `spawn failed (exit 1)` message format. The rc=124 case is covered by the new COORDINATOR-TIMEOUT test.

---

## [2.11.3] — 2026-04-30

### Fixed

- **on-stop.sh status-block parser hardening (NLTlabsPE 2026-04-30 incident).** Two simultaneous parser bugs caused exit-gate bypass when Claude correctly reported `STATUS: BLOCKED + EXIT_SIGNAL: true` on a fully-blocked Linear backlog (10 wasted loops + CB trip):
  - **Field-name case drift.** Projects whose `PROMPT.md` uses lowercase `linear_open_count: 0` had the value silently dropped because the original grep was case-sensitive against `LINEAR_OPEN_COUNT:`. The hook now runs an `awk` pre-pass that uppercases the field-identifier portion of every `<ident>: <value>` line before extraction, so downstream parsing is case-insensitive without requiring every project to migrate its prompt.
  - **Unanchored greps + prose colon.** A `RECOMMENDATION:` line containing `STATUS:BLOCKED` in free-text prose poisoned `grep "STATUS:"` — `tail -1` picked the recommendation, `sed` stripped up to the *last* `STATUS:` occurrence, and the captured value was `BLOCKED)` (closing paren of the parenthetical). The EXIT-CLEAN equality check at `on-stop.sh:607` then failed and the hook fell through to the no-progress branch, incrementing `consecutive_no_progress` instead of recognising clean exit. Every field-extraction grep is now anchored to `^[[:space:]]*` so prose mid-line cannot be selected. The brittle `grep -v "TESTS_STATUS\|END_RALPH"` and `grep -v "LINEAR_EPIC_DONE\|LINEAR_EPIC_TOTAL"` workarounds are removed — the line anchor makes them redundant.

### Tests

- 3 new regression tests in `tests/unit/test_on_stop_hook.bats`:
  - `PARSER-HARDENING: RECOMMENDATION prose containing 'STATUS:BLOCKED' does NOT poison the STATUS field` — replays the exact NLTlabsPE Loop-12 payload and asserts `status=BLOCKED` (not `BLOCKED)`) and that EXIT-CLEAN Grounds 2 fires (counter resets, state stays CLOSED).
  - `PARSER-HARDENING: lowercase linear_open_count / linear_done_count (PROMPT.md drift) parses correctly` — asserts `linear_open_count=0` and `linear_done_count=142` with all-lowercase field names in the input.
  - `PARSER-HARDENING: TESTS_STATUS does NOT bleed into STATUS field via unanchored grep` — defense regression after removing the legacy `grep -v` filter.

---

## [2.11.2] — 2026-04-30

### Removed

- **Per-iteration cost cap (`RALPH_COST_CAP_USD`).** Briefly added in 2.11.1 (unreleased to operators), then removed: the Anthropic API's monthly spend cap is the real safety net (already detected via exit code 4 → `monthly_api_spend_cap`), and a per-loop cap creates false-positive trips on legitimately large loops. The four files that reference it (`ralph_loop.sh` post-execution block, `ralph_monitor.sh` cost colouring, `templates/ralphrc.template` `# COST CAP` section, CLAUDE.md config list) all reverted.

---

## [2.11.1] — 2026-04-30

### Fixed

- **Routing-default regression (April 2026 incident).** `lib/complexity.sh:23` defaulted `RALPH_MODEL_ROUTING_ENABLED` to `false` while CLAUDE.md, RELEASE.md, and the 2.11.0 changelog all promised `true`. Projects that did not explicitly set the variable in `.ralphrc` had every loop pinned to `CLAUDE_MODEL` (Opus where set) at ~$57/loop, with no routing decisions logged to `.ralph/.model_routing.jsonl`. A second hardcoded `:-false` fallback in `ralph_loop.sh:2918` would have continued masking a fix to the lib alone. Both now default `true`. Two regression tests in `tests/unit/test_complexity.bats` lock the default in place — one verifies the lib-level default in a clean subshell, one exercises `ralph_select_model` end-to-end with the env var unset.

### Added

- **Startup routing-health visibility.** `ralph` now logs `Model routing: ENABLED/DISABLED` at startup and emits a `WARN` if `RALPH_MODEL_ROUTING_ENABLED=true` but `.ralph/.model_routing.jsonl` is more than an hour stale — the same signal that would have flagged the routing-default regression on day one.
- **Monitor dashboard routing-log decision count.** A `Routing log: N decisions` line surfaces routing-log volume; if the log is >1h stale while `loop_count` keeps incrementing, the line goes red with a "likely inert" warning. Read-only diagnostic — no behaviour change.

---

## [2.9.2] — 2026-04-29

### Changed

- **MCP probe default timeout** raised again from 15s to 30s. Cold-start cases where stdio MCP servers spawn child processes plus HTTP MCPs do auth round-trips can occasionally exceed 15s on the very first invocation; warm runs return in 1–2s so the higher default has no visible cost. Override via `RALPH_MCP_PROBE_TIMEOUT_SECONDS`.

---

## [2.9.1] — 2026-04-29

### Changed

- **MCP probe timeout** is now configurable via `RALPH_MCP_PROBE_TIMEOUT_SECONDS` (default `15`, was hardcoded `5`). The previous 5-second cap was too tight for setups with 5+ MCP servers — `claude mcp list` health-checks each server in turn, so machines with Drive/Calendar/Gmail/Linear/docs-mcp/tapps-mcp/tapps-brain regularly tripped the timeout and lost the prompt-side guidance for the reachable servers. The probe failure was cosmetic (Claude's own MCP loading is independent), but the lost guidance reduced the chance Claude reaches for `mcp__tapps-brain__*` etc. organically.

---

## [2.9.0] — 2026-04-29

### Added

- **TAP-589 LINOPT epic — Linear cache-locality optimizer.** End-to-end:
  - **TAP-590 (LINOPT-1)**: `templates/hooks/on-stop.sh` walks the JSONL session transcript after each loop, extracts edited file paths from Edit/Write/MultiEdit/NotebookEdit tool uses, dedupes/caps at 100, strips `CLAUDE_PROJECT_DIR` prefix, writes `.ralph/.last_completed_files` atomically (8 BATS tests).
  - **TAP-591 (LINOPT-2)**: new `lib/linear_optimizer.sh` with `linear_optimizer_run` entry point — fetches top-N open issues, scores by `Jaccard(last_completed_files, issue_body_paths) + 0.3 × shared-parent-dir bonus`, ralph-explorer (Haiku) fallback for top-3 priority issues with no body paths (cached at `.ralph/.linear_optimizer_cache.json`, capped at 3 calls/session), atomic write to `.ralph/.linear_next_issue` (5 BATS tests).
  - **TAP-592 (LINOPT-3)**: import-graph dependency demotion. New `import_graph_predecessors` helper in `lib/import_graph.sh`. Two-phase optimizer: phase-1 collects scored candidates, phase-2 walks `FILES_OWNED_BY_OPEN` map and demotes candidates that import another open issue's file. `RALPH_NO_DEP_DEMOTE=true` opts out (5 BATS tests).
  - **TAP-593 (LINOPT-4)**: `build_loop_context()` in `ralph_loop.sh` reads `.ralph/.linear_next_issue`, sanitizes to `[A-Z0-9a-z-]`, injects `LOCALITY HINT: <ID>` into Claude's `--append-system-prompt`. ralph-workflow skill step 0 instructs Claude to honor the hint and delete the file after use (2 BATS tests).
  - **TAP-594 (LINOPT-5)**: telemetry + 5 fail-loud safety rails — stale-hint cleanup, fail-loud on Linear API error (preserves existing hint), project-unset guard, opt-out guard, PID-based lock file with stale-lock auto-cleanup. Per-session JSONL telemetry at `.ralph/metrics/linear_optimizer_YYYY-MM.jsonl`. New `ralph --optimize-linear` CLI flag for manual reruns (6 BATS tests).
  - **TAP-595 (LINOPT-6)**: full epic spec at `docs/specs/epic-linear-mode-optimizer.md`, README + `templates/ralphrc.template` + CLAUDE.md updated.

### Fixed

- **TAP-1103**: `ralph --dry-run` (and other CLI flags) silently overridden by `.ralphrc` because `load_ralphrc()` ran AFTER arg parsing and re-sourced variables of the same name. Burned $5.81 in NLTlabsPE before being killed. Fix: parallel `_cli_*` capture for every flag with a config-file counterpart (`--dry-run`, `--no-continue`, `--session-expiry`, `--output-format`, `--auto-reset-circuit`, `--log-max-size`, `--log-max-files`), restored AFTER `load_ralphrc()` and `load_json_config()`. Final precedence is now CLI > env > .ralphrc/json > defaults — same shape as the existing `_env_*` block. 7 BATS tests in `tests/unit/test_cli_rc_precedence.bats`.

### Configuration

- New `.ralphrc` knobs (all defaulted):
  - `RALPH_NO_LINEAR_OPTIMIZE=false` — disable optimizer entirely
  - `RALPH_NO_DEP_DEMOTE=false` — skip phase-2 dependency demotion
  - `RALPH_OPTIMIZER_FETCH_LIMIT=20` — max issues fetched per run
  - `RALPH_OPTIMIZER_EXPLORER_MAX=3` — max ralph-explorer calls per session

---

## [2.8.3] — 2026-04-20

### Added
- **TAP-741**: Push-mode Linear counts via `RALPH_STATUS` — `linear_get_open_count` / `linear_get_done_count` read `linear_open_count` / `linear_done_count` from `.ralph/status.json`, written by the on-stop hook from Claude's RALPH_STATUS block; entries older than `RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS` (default 900) abstain via the TAP-536 fail-loud path; `linear_check_configured` requires only `RALPH_LINEAR_PROJECT`. (OAuth-via-MCP is the only supported Linear-mode integration.)

### Fixed
- Monitor: repair zero-token / zero-cost display, staleness detection, and silent-UNKNOWN fallback
- MCP probe: use temp file + `--kill-after` to prevent probe hang on unresponsive servers
- `build_loop_context`: `tapps-mcp` guidance block is now injected unconditionally when the server is reachable (drops the stale `! ralph_task_is_docs_related` gate that silently suppressed the block on mixed docs/code loops); matches the documented design in CLAUDE.md

---

## [2.8.2] — 2026-04-20

### Added
- **SKILLS-INJECT-5**: `lib/skill_retro.sh` — friction signal detection: reads `status.json` and stream logs after each loop, identifies signals (permission denials, repeated stalls, test failures, tool errors), emits a structured JSON friction report
- **SKILLS-INJECT-6**: Retro apply in `lib/skill_retro.sh` — advisory mode by default (`RALPH_SKILL_AUTO_TUNE=false`); when enabled, installs ≤1 recommended skill per loop based on friction report; checksum-guard prevents overwriting user-modified skills
- **SKILLS-INJECT-7**: Periodic re-detection (`skill_retro_periodic_reconcile`) — re-runs Tier A project detection every N loops (default 10, `RALPH_SKILL_REDETECT_INTERVAL`) and reconciles installed skills against current project state
- **SKILLS-INJECT-8**: `record_skill_metric` / `ralph_show_skill_stats` in `lib/metrics.sh` — append skill events to `.ralph/metrics/skills.jsonl`; `ralph --stats` now includes a skill breakdown section

---

## [2.8.1] — 2026-04-20

### Added
- **SKILLS-INJECT-1–4**: Project skill detection, install, and PROMPT.md hints — `detect_tier_a_skills()` and `install_project_tier_a_skills()` in `lib/enable_core.sh`; `inject_skill_hints_into_prompt()` appends an "Available Skills" section to `.ralph/PROMPT.md` idempotently; 20 new BATS tests
- Session run-ID boundary tracking — `on-stop.sh` resets cost/token/MCP accumulators when run ID changes, preventing stale totals bleeding into a new session
- Monitor: Linear issue display with `(executing...)` fallback and MCP activity row (top-3 tools per loop by call count)

### Fixed
- **TAP-658**: Cap circuit breaker history at 200 entries (prevents jq OOM on long runs); atomic `mv` instead of `>` redirect
- **TAP-661**: Validate template hooks before and after copy in `ralph_upgrade_project.sh` — skip empty/syntax-invalid sources with WARN; write to tmp, `bash -n` verify, then atomic mv
- **TAP-662**: Track `_tokens_extracted` flag in `_extract_session_id()`; missing usage block emits `logger.warning` instead of silently recording $0 cost
- **TAP-659**: Replace sed-based JSON escape in `lib/notifications.sh` webhook with `jq --arg` — eliminates JSON injection vector
- **TAP-657**: Bump `actions/checkout` and `actions/setup-node` from v3 → v4 in `.github/workflows/test.yml`
- **TAP-656**: Remove corrupt duplicate hook entries from `.claude/settings.json`; add `tests/unit/test_settings_json.bats` (6 assertions) to guard against recurrence
- **TAP-730**: `ralph_upgrade_project.sh` now chmod u+w before overwriting read-only (555) hook/agent files
- Monitor: show cache% block when cache data present but tokens are zero
- Linear: tighten In Review rules — security bug fixes and hardening now default to Done; uncertainty defaults to Done (AC met) or In Progress, never In Review
- Signal trap cleanup now passes explicit 130/143 into `cleanup()` — stray loop iterations after `kill <pid>` eliminated
- `lib/tracing.sh`: build JSONL spans via `jq --arg` instead of shell interpolation; add jq validity check before appending

### Changed
- Upgrade Claude model IDs to April 2026 lineup — `claude-sonnet-4-6` (was `claude-sonnet-4-20250514`), `claude-opus-4-7` for LARGE/ARCHITECTURAL routing
- `templates/PROMPT.md`: RALPH:START/END marker support so `ralph-upgrade` can refresh only the managed section
- `templates/skills-local/ralph-workflow/SKILL.md`: step 6.5 deslop pass at epic boundaries via simplify skill; controlled by `RALPH_NO_DESLOP=true`
- `.mcp.json`: tapps-brain MCP server registered for this project

---

## [2.7.2] — 2026-04-20

### Fixed
- Linear workflow: codify In Review as rare/hard-blocker-only with four valid reasons; unmerged branches stay In Progress for self-retry
- Signal trap: SIGINT/SIGTERM pass explicit 130/143 exit codes; stray loop iteration after kill eliminated
- CI: remove dormant PR review workflows (`claude.yml`, `claude-code-review.yml`, `opencode-review.yml`) with unconfigured secrets

---

## [2.7.1] — 2026-04-20

Hardening release. 14 fix commits on top of 2.7.0 — no new features, all security/reliability/CI fixes surfaced by the internal code-review sweep.

### Security
- **TAP-622**: Stop splicing `fix_plan.md` content into an awk-driven shell command in `plan_section_hashes` — fixes shell injection via crafted task titles
- **TAP-623**: `protect-ralph-files.sh` now guards `.claude/` (agents, hooks, settings) in addition to `.ralph/`, so the loop cannot edit its own control plane
- **TAP-624**: Close multiple destructive-command bypasses in `validate-command.sh` whitelist
- **TAP-633**: Stop interpolating unquoted `project_root` into the `python3 -c` body in `lib/import_graph.sh` — fixes Python heredoc command injection
- **TAP-641**: `ralph.ps1` now passes arguments via argv splat instead of `bash -c` interpolation — fixes command injection via whitespace-containing args
- **TAP-643**: Replace in-place `sed` with a jq-based patch + backup when adjusting `.claude/settings.json` — prevents silent JSON corruption

### Fixed
- **TAP-621**: SDK token usage is now read from `obj["usage"]` (correct JSON level), re-enabling `CostTracker` and `TokenRateLimiter`
- **TAP-625**: `FileStateBackend` text writers all go through atomic write — SIGTERM races no longer corrupt rate-limit/counter state
- **TAP-628**: `plan_optimizer._validate_equivalence` actually checks the invariant (previously compared `sorted(same objects)` against itself)
- **TAP-630**: `CircuitBreaker` cooldown uses tz-aware datetime — fixes `time.mktime` / `tm_gmtoff` mis-parse on macOS/BSD
- **TAP-636**: `install.sh` enables `pipefail` on the sed|tr pipeline — prevents silent truncation of `ralph_loop.sh` on failure
- **TAP-638**: `uninstall.sh` lists stay in sync with `install.sh` — removes the dangling `ralph-upgrade-project` wrapper
- **TAP-646**: `ralph-tester` model matches docs (sonnet, not haiku); `ralph` / `ralph-architect` use valid `Agent(...)` tool schema
- **TAP-649**: `update-badges.yml` surfaces test failures instead of masking with `|| true`, and sanitizes `grep -c` output
- **TAP-651**: `lib/metrics.sh` and `lib/github_issues.sh` now build JSON/JSONL with `jq -n` instead of manual concat — no more JSON injection / corruption via field content
- Close missing `fi` branch introduced by the TAP-643 jq-patch refactor

---

## [2.7.0] — 2026-04-19

### Added
- **TAP-575**: Ralph-owned canonical skill library — `templates/skills/global/` now ships 5 Tier S skills (`search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`), each with Ralph-hardened `SKILL.md` + concrete loop examples under `examples/`. Every skill carries the Ralph frontmatter standard (name/description/version/ralph/ralph_version_min/attribution/user-invocable/disable-model-invocation/allowed-tools) and the four-section contract (When to invoke, Ralph-specific guidance, sub-agent integration, Exit criteria). 13 BATS cases in `tests/unit/test_skill_frontmatter.bats` + `test_skill_content.bats` enforce the schema so the retro/auto-tune loop (TAP-578/579) can rely on a stable shape. Combined with TAP-574, running `install.sh` now seeds `~/.claude/skills/` with the full Ralph baseline.
- **TAP-574**: Global Claude skill baseline via `install.sh` — new `lib/skills_install.sh` syncs `templates/skills/global/<name>/` into `~/.claude/skills/<name>/` with `.ralph-managed` sidecar for idempotency. Three install cases: fresh copy + sidecar; re-install refreshes only files whose hash still matches Ralph's baseline (WARN on user-modified); user-authored dirs without a sidecar are skipped. `uninstall.sh` and `install.sh uninstall` remove only Ralph-owned files, preserving user edits. `ralph-upgrade` picks up new baselines automatically. 13 BATS cases in `tests/unit/test_skills_install.bats`.

### Fixed
- **TAP-538**: Sync `.ralph/hooks/` with templates and harden circuit breaker self-healing — corrupt `.circuit_breaker_state` is now auto-reinitialized to `CLOSED` instead of crashing the loop; `ralph-doctor` warns on hook drift vs templates
- **TAP-537**: Unmask integration tests — `npm run test:integration` is now a hard-failing CI gate; deterministic eval suite added to required CI; stale version assertion, missing mock exec bit, and missing fixture repaired
- **TAP-535**: Atomic state writes and `pipefail` — all counter/state-file writes go through `atomic_write()` helper (write→fsync→mv); `set -o pipefail` enabled after library sourcing; Bash < 4 rejected at startup
- **TAP-534/533/536**: Security — sed/eval injection fixes in `ralph_loop.sh`; Linear API backend now fail-loud (returns non-zero + stderr on any error, never silently defaults to "complete")

---

## [2.6.0] — 2026-04

### Added
- **Linear task backend** (`RALPH_TASK_SOURCE=linear`) — replaces `fix_plan.md` reads with Linear via the Linear MCP plugin (OAuth); requires `RALPH_LINEAR_PROJECT`; fail-loud on stale counts (TAP-536 pattern)
- **`ralph-upgrade-project`** — propagate runtime files (hooks, templates) to existing managed projects without re-running full setup

### Changed
- Resolved 14 open issues; fixed 24 pre-existing test failures from integration gate

---

## [2.5.0] — 2026-03

### Added
- **Structured hook logging** — `on-stop.sh`, `on-session-start.sh`, `on-task-completed.sh` emit structured JSON lines for observability
- **Import graph + plan optimizer** (`lib/import_graph.sh`, `lib/plan_optimizer.sh`) — auto-reorder `fix_plan.md` tasks by dependency; Python SDK counterparts in `sdk/ralph_sdk/import_graph.py` and `sdk/ralph_sdk/plan_optimizer.py`
- **Episodic memory** (`sdk/ralph_sdk/memory.py`) — cross-session keyword-indexed failure/success recall with age decay
- **Task complexity classifier** (`sdk/ralph_sdk/complexity.py`, `lib/complexity.sh`) — 5-level TRIVIAL→ARCHITECTURAL classifier feeds dynamic model routing

### Changed
- Version bumped to 2.5.0; documentation updated

---

## [2.4.0] — 2026-02

### Added
- **Plan optimization epic** — automatic `fix_plan.md` task reordering at session start (`RALPH_NO_OPTIMIZE` disables); vague task file resolution via `ralph-explorer` (Haiku)
- **`RALPH_NO_OPTIMIZE`**, **`RALPH_NO_EXPLORER_RESOLVE`**, **`RALPH_MAX_EXPLORER_RESOLVE`** config variables

### Fixed
- `CLAUDE_CODE_CMD` from `.ralphrc` now respected in agent mode
- `ALLOWED_TOOLS` works correctly in agent mode

### Changed
- Default `MAX_CALLS_PER_HOUR` raised from 100 to 200 (v2.4.1 patch)

---

## [2.3.0] — 2026-01

### Added
- **Phase 14-17 features**: OpenTelemetry tracing (`lib/tracing.sh`), Docker sandbox v2 with rootless + gVisor support (`lib/sandbox.sh`), cross-session memory (`lib/memory.sh`), cost-aware routing with token rate limiting (`sdk/ralph_sdk/cost.py`), adaptive timeout with percentile tracking (`sdk/ralph_sdk/circuit_breaker.py`)
- **Continue-As-New** (`CTXMGMT-3`) — Temporal-inspired session reset after `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120)
- **Completion indicator decay** (SDK-SAFETY-3) — stale "done" signals reset when productive work occurs without `EXIT_SIGNAL: true`
- **MCP server process cleanup** (`ralph_cleanup_orphaned_mcp`) — kills orphaned MCP grandchild processes after each CLI invocation; Windows uses PowerShell CIM; Linux/macOS uses pgrep/kill
- **Upstream sync epic** (USYNC) — question detection, stuck-loop detection, CB permission denial, heuristic exit suppression, tmux sub-agent progress

### Fixed
- `jq` bootstrap in install path
- `ralph-doctor` PATH resolution
- WSL PowerShell auto-patching — bare `powershell` hooks auto-patched to `powershell.exe`

---

## [2.2.0] — 2025-12

### Added
- **SDK v2.1.0** — `ContinueAsNewState`, `plan_optimizer`, `import_graph`, `memory`, `complexity` modules; all models Pydantic v2; fully async with `run_sync()` wrapper
- **LOGFIX epic** — 8 production bug fixes from log analysis

### Fixed
- Block `git commit --trailer "Made-with: Cursor"` short `--no-verify` flag in hooks

---

## [2.0.0] — 2025-11

### Added
- **Python SDK v2.0.0** — full async agent, Pydantic v2 models, pluggable `RalphStateBackend` (File + Null), `EvidenceBundle` output, TaskPacket conversion, `CircuitBreaker` class, `ContextManager`, `CostTracker`, `MetricsCollector`, `JsonlMetricsCollector`
- **Sub-agents** — ralph-explorer (Haiku), ralph-tester (Sonnet, worktree-isolated), ralph-reviewer (Sonnet), ralph-architect (Opus)
- **Epic-boundary QA deferral** — ralph-tester and ralph-reviewer skipped mid-epic; mandatory before `EXIT_SIGNAL: true`
- **Speed optimizations** (v1.8.4+) — `bypassPermissions`, `effort: medium`, disabled PostToolUse hooks for throughput; increased batch sizes to 8 SMALL / 5 MEDIUM
- **FAILURE.md / FAILSAFE.md / KILLSWITCH.md** — failure protocol documents with audit logging
- **Hook-based response analysis** — `on-stop.sh` writes `status.json`; loop reads from it instead of parsing raw CLI output; `response_analyzer.sh` removed
- **File protection hooks** — `protect-ralph-files.sh` and `validate-command.sh` as PreToolUse hooks replace `file_protection.sh` module

### Changed
- **Phase 14 modernization** — `lib/metrics.sh`, `lib/notifications.sh`, `lib/backup.sh`, `lib/github_issues.sh`, `lib/sandbox.sh`, `lib/tracing.sh`, `lib/complexity.sh`, `lib/memory.sh` added
- `response_analyzer.sh` removed (replaced by hook)
- `file_protection.sh` removed (replaced by hooks)

---

## [1.9.0] — 2025-10

### Added
- **Cost-aware routing** — task complexity classifier, dynamic model routing, token rate limiting (Phase 8)
- **Task batching** — up to 8 SMALL / 5 MEDIUM tasks per invocation

---

## [1.8.x] — 2025-10

### Added
- **`--live` JSONL pipeline** — real-time streaming with tool names, elapsed time, sub-agent events, error extraction
- **Windows / Git Bash support** — MINGW detection, PowerShell MCP cleanup, WSL2 filesystem resilience
- **WSL version divergence detection** — compares WSL vs Windows `~/.ralph/` versions at startup
- **Log rotation** — `rotate_ralph_log()` on size threshold; `cleanup_old_output_logs()` beyond file count limit
- **Dry-run mode** (`--dry-run` / `DRY_RUN=true`) — simulates a loop without API calls
- **`ralph-enable` / `ralph-enable-ci`** — interactive and non-interactive setup wizards
- **`ralph-import`** — PRD/spec → Ralph task conversion
- **`ralph-doctor`** — dependency verification
- **`ralph-migrate`** — `.ralph/` directory migration

### Fixed
- Stream filter suppresses raw JSONL leaking to terminal in `--live` mode
- SIGTERM/SIGINT treated as clean stops, not crashes
- Compound command pattern support (`&&`, `||`, `;` in `ALLOWED_TOOLS`)

---

## [1.2.0] — 2025-10 (Phase 5)

### Added
- Stream parser v2 — JSONL primary path, multi-result filtering, unescape RALPH_STATUS
- WSL reliability polish — temp file cleanup, child process cleanup
- Circuit breaker decay — sliding window failure detection, session reinitialization

---

## [1.0.0] — 2025-09 (Initial)

### Added
- Core autonomous loop (`ralph_loop.sh`) — dual-condition exit gate, four-layer rate limit detection, session continuity
- Circuit breaker — three-state CLOSED/HALF_OPEN/OPEN with cooldown auto-recovery
- `ralph-setup` — project scaffolding with `.ralph/` directory structure
- `ralph-monitor` — live tmux dashboard
- BATS test suite — unit and integration tests via `npm test`
