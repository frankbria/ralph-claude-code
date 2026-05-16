#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

# Note: CLAUDE_CODE_ENABLE_DANGEROUS_PERMISSIONS_IN_SANDBOX and IS_SANDBOX
# environment variables are NOT exported here. Tool restrictions are owned
# by the agent file (.claude/agents/ralph.md `tools:` allowlist +
# `disallowedTools:` blocklist) and PreToolUse hooks (validate-command.sh,
# protect-ralph-files.sh). Exporting sandbox variables without a verified
# sandbox would be misleading.

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh" || { echo "FATAL: Failed to source lib/date_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/timeout_utils.sh" || { echo "FATAL: Failed to source lib/timeout_utils.sh" >&2; exit 1; }
# response_analyzer.sh removed — response analysis handled by on-stop.sh hook → status.json
source "$SCRIPT_DIR/lib/circuit_breaker.sh" || { echo "FATAL: Failed to source lib/circuit_breaker.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/exec_helpers.sh" || { echo "FATAL: Failed to source lib/exec_helpers.sh" >&2; exit 1; }
# file_protection.sh removed — file protection handled by PreToolUse hooks (protect-ralph-files.sh, validate-command.sh)

# Optional library modules (Phase 8+) — fail-open if not present
[[ -f "$SCRIPT_DIR/lib/metrics.sh" ]] && source "$SCRIPT_DIR/lib/metrics.sh"
[[ -f "$SCRIPT_DIR/lib/notifications.sh" ]] && source "$SCRIPT_DIR/lib/notifications.sh"
[[ -f "$SCRIPT_DIR/lib/backup.sh" ]] && source "$SCRIPT_DIR/lib/backup.sh"
[[ -f "$SCRIPT_DIR/lib/audit.sh" ]] && source "$SCRIPT_DIR/lib/audit.sh"
[[ -f "$SCRIPT_DIR/lib/context_management.sh" ]] && source "$SCRIPT_DIR/lib/context_management.sh"
[[ -f "$SCRIPT_DIR/lib/complexity.sh" ]] && source "$SCRIPT_DIR/lib/complexity.sh"
[[ -f "$SCRIPT_DIR/lib/qa_failures.sh" ]] && source "$SCRIPT_DIR/lib/qa_failures.sh"
[[ -f "$SCRIPT_DIR/lib/tracing.sh" ]] && source "$SCRIPT_DIR/lib/tracing.sh"
[[ -f "$SCRIPT_DIR/lib/linear_backend.sh" ]] && source "$SCRIPT_DIR/lib/linear_backend.sh"
[[ -f "$SCRIPT_DIR/lib/linear_optimizer.sh" ]] && source "$SCRIPT_DIR/lib/linear_optimizer.sh"
[[ -f "$SCRIPT_DIR/lib/skill_retro.sh" ]] && source "$SCRIPT_DIR/lib/skill_retro.sh"
# BRAIN-PHASE-B1: memory writes from on-stop hook. Sourced here so the main
# loop also has access if we later want to write outside hook context.
[[ -f "$SCRIPT_DIR/lib/brain_client.sh" ]] && source "$SCRIPT_DIR/lib/brain_client.sh"
# TAP-914 / TAP-915: brief.json read/write/validate helpers used by the
# coordinator spawn point and by build_loop_context.
[[ -f "$SCRIPT_DIR/lib/brief.sh" ]] && source "$SCRIPT_DIR/lib/brief.sh"
[[ -f "$SCRIPT_DIR/lib/coordinator_session.sh" ]] && source "$SCRIPT_DIR/lib/coordinator_session.sh"

# TAP-924: ralph_clear_all_sessions — single helper for clearing the main
# Claude session id, the coordinator session id, and the coordinator brief.
# Used wherever the main session is reset (CB open, is_error, continue-as-new,
# manual reset, age expiry) so the coordinator session stays in lockstep with
# the main one. Safe to call when files are missing. Falls back to direct rm
# if the lib helpers are not yet sourced.
ralph_clear_all_sessions() {
    local _ralph_dir="${RALPH_DIR:-.ralph}"
    rm -f -- "${CLAUDE_SESSION_FILE:-${_ralph_dir}/.claude_session_id}" 2>/dev/null || true
    if declare -F coordinator_session_clear >/dev/null 2>&1; then
        coordinator_session_clear || true
    else
        rm -f -- "${_ralph_dir}/.coordinator_session" 2>/dev/null || true
    fi
    if declare -F brief_clear >/dev/null 2>&1; then
        brief_clear || true
    else
        rm -f -- "${_ralph_dir}/brief.json" 2>/dev/null || true
    fi
    return 0
}

# TAP-924: clear ONLY the coordinator session + brief (leave the main Claude
# session alone). Used at task boundaries (post-debrief task-complete) and
# on SIGINT/SIGTERM, where mid-task interrupt should not invalidate the main
# session if the user resumes. Brief is cleared with the session because they
# are paired — the brief belongs to the coordinator session that wrote it.
ralph_clear_coordinator_artifacts() {
    local _ralph_dir="${RALPH_DIR:-.ralph}"
    if declare -F coordinator_session_clear >/dev/null 2>&1; then
        coordinator_session_clear || true
    else
        rm -f -- "${_ralph_dir}/.coordinator_session" 2>/dev/null || true
    fi
    if declare -F brief_clear >/dev/null 2>&1; then
        brief_clear || true
    else
        rm -f -- "${_ralph_dir}/brief.json" 2>/dev/null || true
    fi
    return 0
}

# TAP-535: Bash 4+ required for `${BASH_VERSINFO[@]}`, mapfile/readarray, named
# refs, and the rest of the modern bash features used throughout this script.
if [[ -z "${BASH_VERSION:-}" ]] || (( ${BASH_VERSINFO[0]:-0} < 4 )); then
    echo "FATAL: ralph_loop.sh requires Bash 4.0+ (got: ${BASH_VERSION:-unknown})" >&2
    echo "       Install a newer bash via your package manager (Homebrew on macOS)." >&2
    exit 1
fi

# TAP-535: pipefail makes `cmd1 | cmd2` propagate cmd1's failure so jq/grep
# pipelines don't silently mask broken inputs. Applied AFTER library sourcing
# so library code (which has its own conventions) is unaffected.
set -o pipefail

# BRAIN-PHASE-A: Load user-level secrets (TAPPS_BRAIN_AUTH_TOKEN, etc.) from
# ~/.ralph/secrets.env. Non-interactive shells — systemd units, cron, tmux
# panes started before the user exported a var — never source ~/.bashrc, so
# variables the user "set once" in their shell rc never reach Ralph. A
# dedicated secrets file keeps them available regardless of invocation
# context. `set -a` exports everything sourced so the Claude CLI subprocess
# (and its MCP handshakes) inherit the values without a second export.
#
# Runs here — before arg parsing — so `ralph --mcp-status` picks secrets up
# too, not just the main loop.
load_ralph_secrets() {
    local secrets="$HOME/.ralph/secrets.env"
    [[ -f "$secrets" ]] || return 0
    local perms=""
    if command -v stat &>/dev/null; then
        perms=$(stat -c '%a' "$secrets" 2>/dev/null || stat -f '%A' "$secrets" 2>/dev/null || echo "")
    fi
    if [[ -n "$perms" && "${perms: -2}" != "00" ]]; then
        echo "WARN: $secrets is group/world-readable (mode $perms). Run: chmod 600 $secrets" >&2
    fi
    set -a
    # shellcheck source=/dev/null
    source "$secrets"
    set +a
}
load_ralph_secrets

# TAP-535: atomic_write — write VALUE to FILE via a unique temp + rename.
# Protects counters and other small state files from partial-write corruption
# when the script is killed mid-write, and avoids zero-byte counter files that
# silently default to 0 on the next read.
#
# Usage:   atomic_write <file> <value>
# Stdout:  nothing
# Exit:    0 on success, non-zero on any failure (target unchanged on failure)
#
# Notes:
#   * Temp file uses `$$` + `$RANDOM` to stay unique across concurrent runs.
#   * Best-effort `sync` is GNU-specific; ignored on macOS where it's a no-op.
#   * The `mv -f` rename is atomic on the same filesystem (POSIX rename(2)).
atomic_write() {
    local target="$1"
    local value="$2"
    [[ -n "$target" ]] || return 1
    local dir
    dir=$(dirname -- "$target")
    [[ -d "$dir" ]] || return 1
    local tmp="${target}.tmp.$$.${RANDOM}"
    if ! printf '%s\n' "$value" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    # Best-effort fsync on the temp file — GNU coreutils only. macOS `sync`
    # ignores arguments and syncs the whole FS; we tolerate either by ignoring
    # exit status. The rename below is the actual atomicity guarantee.
    sync -- "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# Version
RALPH_VERSION="2.15.0"

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
SLEEP_DURATION=3600     # 1 hour in seconds
LIVE_OUTPUT=false       # Show Claude Code output in real-time (streaming)
LIVE_LOG_FILE="$RALPH_DIR/live.log"  # Fixed file for live output monitoring
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
# TAP-1838: Sentinel-based MCP probe cache. When true (default), skips
# `claude mcp list` if the probe inputs (claude version + MCP config files)
# are unchanged since the last successful probe. Age threshold is in seconds.
RALPH_MCP_PROBE_SKIP_IF_UNCHANGED="${RALPH_MCP_PROBE_SKIP_IF_UNCHANGED:-true}"
RALPH_MCP_PROBE_SENTINEL_FILE="${RALPH_DIR}/.mcp-probe-sentinel"
RALPH_MCP_PROBE_SENTINEL_MAX_AGE="${RALPH_MCP_PROBE_SENTINEL_MAX_AGE:-86400}"
USE_TMUX=false
RALPH_SERVICE=""           # Monorepo service scope (Issue #163)
RALPH_TASK_SOURCE="file"   # Task backend: "file" (fix_plan.md) or "linear"
RALPH_LINEAR_PROJECT=""    # Linear project name (required when RALPH_TASK_SOURCE=linear)
RALPH_LINEAR_TEAM=""       # Linear team name (optional, used in log messages)

# TAP-1103: CLI-flag values get a parallel `_cli_*` capture so they survive
# `.ralphrc` and `ralph.config.json` sourcing. Final precedence after
# load_ralphrc() / load_json_config() runs the restore blocks:
#   CLI flag > env var > .ralphrc / ralph.config.json > script default.
# These are populated by the CLI dispatcher case statement near EOF when the
# user passes a flag, and restored at the end of load_ralphrc / load_json_config.
_cli_DRY_RUN=""
_cli_CLAUDE_USE_CONTINUE=""
_cli_CLAUDE_SESSION_EXPIRY_HOURS=""
_cli_CLAUDE_OUTPUT_FORMAT=""
_cli_CB_AUTO_RESET=""
_cli_LOG_MAX_SIZE_MB=""
_cli_LOG_MAX_FILES=""

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-}"
_env_CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-}"
_env_CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-}"
_env_CLAUDE_SESSION_EXPIRY_HOURS="${CLAUDE_SESSION_EXPIRY_HOURS:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-}"
_env_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
_env_CLAUDE_EFFORT="${CLAUDE_EFFORT:-}"
_env_CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-}"
_env_RALPH_SHELL_INIT_FILE="${RALPH_SHELL_INIT_FILE:-}"
_env_DRY_RUN="${DRY_RUN:-}"
_env_LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-}"
_env_LOG_MAX_FILES="${LOG_MAX_FILES:-}"
_env_LOG_MAX_OUTPUT_FILES="${LOG_MAX_OUTPUT_FILES:-}"

# Now set defaults (only if not already set by environment)
CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-claude}"

# E2E testing: override Claude command with mock (Issue #225)
if [[ "${RALPH_MOCK_CLAUDE:-false}" == "true" ]]; then
    CLAUDE_CODE_CMD="${RALPH_DIR}/../tests/mock_claude.sh"
fi

CLAUDE_MODEL="${CLAUDE_MODEL:-}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-}"
RALPH_SHELL_INIT_FILE="${RALPH_SHELL_INIT_FILE:-}"  # Shell init file (e.g. ~/.zshrc) sourced before launching claude; Issue #211
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-200}"
MAX_TOKENS_PER_HOUR="${MAX_TOKENS_PER_HOUR:-0}"  # 0 = disabled; Issue #223
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"

# Modern Claude CLI configuration (Phase 1.1)
CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-json}"
# Tool restrictions are owned by .claude/agents/ralph.md (`tools:` allowlist
# + `disallowedTools:` blocklist) and the .claude/hooks/validate-command.sh
# PreToolUse hook. The historical RALPH_DEFAULT_ALLOWED_TOOLS allowlist
# (Issue #149) was deleted along with legacy `-p` mode — see
# docs/decisions/0006-delete-legacy-mode.md and MIGRATING.md.
CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-true}"
CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id" # Session ID persistence file
CLAUDE_MIN_VERSION="2.1.0"               # --agent flag requires CLI v2.1+
CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-true}"  # Auto-update Claude CLI at startup

# GUARD-2: Consecutive timeout circuit breaker (Phase 13)
MAX_CONSECUTIVE_TIMEOUTS="${MAX_CONSECUTIVE_TIMEOUTS:-5}"
CONSECUTIVE_TIMEOUT_COUNT=0

# LOGFIX-4: Fast-trip circuit breaker on broken invocations (0 tools, <30s)
MAX_CONSECUTIVE_FAST_FAILURES="${MAX_CONSECUTIVE_FAST_FAILURES:-3}"
CONSECUTIVE_FAST_FAILURE_COUNT=0
LAST_TOOL_COUNT=0  # Exported from execute_claude_code for fast-trip detection
LAST_INVOCATION_DURATION=0  # Exported from execute_claude_code; invocation_start_epoch is local-scoped so the parent loop can't read it directly
MONTHLY_CAP_DATE=""  # Set by execute_claude_code when an Anthropic monthly spend cap is detected (YYYY-MM-DD or empty)

# LOGFIX-6: Stall detection for persistent deferred tests
CB_MAX_DEFERRED_TESTS="${CB_MAX_DEFERRED_TESTS:-5}"
CONSECUTIVE_DEFERRED_TEST_COUNT=0

# ADAPTIVE-1: Adaptive timeout configuration (Phase 13)
ADAPTIVE_TIMEOUT_ENABLED="${ADAPTIVE_TIMEOUT_ENABLED:-true}"
ADAPTIVE_TIMEOUT_MULTIPLIER="${ADAPTIVE_TIMEOUT_MULTIPLIER:-2}"
ADAPTIVE_TIMEOUT_MIN_MINUTES="${ADAPTIVE_TIMEOUT_MIN_MINUTES:-10}"
ADAPTIVE_TIMEOUT_MAX_MINUTES="${ADAPTIVE_TIMEOUT_MAX_MINUTES:-60}"
ADAPTIVE_TIMEOUT_MIN_SAMPLES="${ADAPTIVE_TIMEOUT_MIN_SAMPLES:-5}"

# Session management configuration (Phase 1.2)
SESSION_EXPIRATION_SECONDS=86400  # 24 hours
SESSION_FILE="$RALPH_DIR/.claude_session_id"
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CLAUDE_SESSION_EXPIRY_HOURS=${CLAUDE_SESSION_EXPIRY_HOURS:-24}

# Issue #213: Keep tmux monitor panes alive after loop exits
KEEP_MONITOR_AFTER_EXIT="${KEEP_MONITOR_AFTER_EXIT:-false}"

# CTXMGMT-3: Continue-As-New configuration (Temporal pattern for long sessions)
# After N iterations or M minutes in the same session, reset context carrying only essential state
RALPH_CONTINUE_AS_NEW_ENABLED=${RALPH_CONTINUE_AS_NEW_ENABLED:-true}
RALPH_MAX_SESSION_ITERATIONS=${RALPH_MAX_SESSION_ITERATIONS:-20}
RALPH_MAX_SESSION_AGE_MINUTES=${RALPH_MAX_SESSION_AGE_MINUTES:-120}
RALPH_CONTINUE_STATE_FILE="$RALPH_DIR/.continue_state.json"
_session_iteration_count=0
_session_start_epoch=""


# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
# Response analysis now handled by on-stop.sh hook → status.json (SKILLS-3)
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# Configuration files
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false
JSON_CONFIG_FILE="ralph.config.json"
JSON_CONFIG_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - CLAUDE_TIMEOUT_MINUTES
#   - CLAUDE_OUTPUT_FORMAT
#   - SESSION_CONTINUITY (mapped to CLAUDE_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CLAUDE_SESSION_EXPIRY_HOURS)
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#   - CLAUDE_CODE_CMD (path or command for Claude Code CLI)
#   - CLAUDE_MODEL (model override for Claude CLI)
#   - CLAUDE_EFFORT (effort level: low, medium, high)
#   - CLAUDE_AUTO_UPDATE (auto-update Claude CLI at startup)
#   - RALPH_SHELL_INIT_FILE (shell init file to source before launching claude)
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${SESSION_CONTINUITY:-}" ]]; then
        CLAUDE_USE_CONTINUE="$SESSION_CONTINUITY"
    fi
    if [[ -n "${SESSION_EXPIRY_HOURS:-}" ]]; then
        CLAUDE_SESSION_EXPIRY_HOURS="$SESSION_EXPIRY_HOURS"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore ONLY values that were explicitly set via environment variables
    # (not script defaults). The _env_* variables were captured BEFORE defaults were set.
    # If _env_* is non-empty, the user explicitly set it in their environment.
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CLAUDE_TIMEOUT_MINUTES" ]] && CLAUDE_TIMEOUT_MINUTES="$_env_CLAUDE_TIMEOUT_MINUTES"
    [[ -n "$_env_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_env_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_MODEL" ]] && CLAUDE_MODEL="$_env_CLAUDE_MODEL"
    [[ -n "$_env_CLAUDE_EFFORT" ]] && CLAUDE_EFFORT="$_env_CLAUDE_EFFORT"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"
    [[ -n "$_env_RALPH_SHELL_INIT_FILE" ]] && RALPH_SHELL_INIT_FILE="$_env_RALPH_SHELL_INIT_FILE"
    [[ -n "$_env_DRY_RUN" ]] && DRY_RUN="$_env_DRY_RUN"
    [[ -n "$_env_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_env_LOG_MAX_SIZE_MB"
    [[ -n "$_env_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_env_LOG_MAX_FILES"
    [[ -n "$_env_LOG_MAX_OUTPUT_FILES" ]] && LOG_MAX_OUTPUT_FILES="$_env_LOG_MAX_OUTPUT_FILES"

    # TAP-1103: Restore CLI-flag overrides AFTER the env restore so the final
    # precedence is CLI > env > .ralphrc > defaults. Without this, sourcing
    # `.ralphrc` silently clobbers any flag the user passed (e.g. `ralph
    # --dry-run` runs a real Claude call when `.ralphrc` has DRY_RUN=false).
    [[ -n "$_cli_DRY_RUN" ]] && DRY_RUN="$_cli_DRY_RUN"
    [[ -n "$_cli_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_cli_CLAUDE_USE_CONTINUE"
    [[ -n "$_cli_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_cli_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_cli_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_cli_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_cli_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_cli_CB_AUTO_RESET"
    [[ -n "$_cli_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_cli_LOG_MAX_SIZE_MB"
    [[ -n "$_cli_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_cli_LOG_MAX_FILES"

    RALPHRC_LOADED=true
    return 0
}

# load_json_config - Load JSON configuration from ralph.config.json
#
# JSON config takes precedence over .ralphrc when both exist.
# Environment variables still override JSON config.
# Requires jq for parsing.
#
load_json_config() {
    if [[ ! -f "$JSON_CONFIG_FILE" ]]; then
        return 0
    fi

    # Check jq availability
    if ! command -v jq &>/dev/null; then
        log_status "WARN" "ralph.config.json found but jq not installed — skipping JSON config"
        return 0
    fi

    # Validate JSON
    if ! jq empty "$JSON_CONFIG_FILE" 2>/dev/null; then
        log_status "WARN" "ralph.config.json is invalid JSON — skipping"
        return 0
    fi

    # PERF: Read ALL config values in a single jq call (was: 28 separate jq spawns)
    local _config_json
    _config_json=$(jq -r '{
      projectName: (.projectName // ""),
      projectType: (.projectType // ""),
      maxCallsPerHour: (.maxCallsPerHour // "" | tostring),
      timeoutMinutes: (.timeoutMinutes // "" | tostring),
      outputFormat: (.outputFormat // ""),
      sessionContinuity: (.sessionContinuity // "" | tostring),
      sessionExpiryHours: (.sessionExpiryHours // "" | tostring),
      cbNoProgressThreshold: (.cbNoProgressThreshold // "" | tostring),
      cbCooldownMinutes: (.cbCooldownMinutes // "" | tostring),
      cbAutoReset: (.cbAutoReset // "" | tostring),
      logMaxSizeMb: (.logMaxSizeMb // "" | tostring),
      logMaxFiles: (.logMaxFiles // "" | tostring),
      logMaxOutputFiles: (.logMaxOutputFiles // "" | tostring),
      dryRun: (.dryRun // "" | tostring),
      claudeAutoUpdate: (.claudeAutoUpdate // "" | tostring),
      verbose: (.verbose // "" | tostring),
      agentName: (.agentName // ""),
      enableTeams: (.enableTeams // "" | tostring),
      maxTeammates: (.maxTeammates // "" | tostring),
      webhookUrl: (.notifications.webhookUrl // ""),
      notifySound: (.notifications.sound // "" | tostring),
      autoCloseIssues: (.github.autoCloseIssues // "" | tostring),
      taskLabel: (.github.taskLabel // ""),
      sandboxRequired: (.sandbox.required // "" | tostring),
      sandboxCpuLimit: (.sandbox.cpuLimit // ""),
      sandboxMemoryLimit: (.sandbox.memoryLimit // ""),
      maxBackups: (.backup.maxBackups // "" | tostring)
    }' "$JSON_CONFIG_FILE" 2>/dev/null)

    if [[ -z "$_config_json" ]]; then
        log_status "WARN" "Failed to parse ralph.config.json"
        return 0
    fi

    # Apply values (helper to avoid repetition)
    _jc() { echo "$_config_json" | jq -r ".$1 // empty" 2>/dev/null; }

    local val
    val=$(_jc projectName);        [[ -n "$val" ]] && PROJECT_NAME="$val"
    val=$(_jc projectType);        [[ -n "$val" ]] && PROJECT_TYPE="$val"
    val=$(_jc maxCallsPerHour);    [[ -n "$val" ]] && MAX_CALLS_PER_HOUR="$val"
    val=$(_jc timeoutMinutes);     [[ -n "$val" ]] && CLAUDE_TIMEOUT_MINUTES="$val"
    val=$(_jc outputFormat);       [[ -n "$val" ]] && CLAUDE_OUTPUT_FORMAT="$val"
    val=$(_jc sessionContinuity);  [[ -n "$val" ]] && CLAUDE_USE_CONTINUE="$val"
    val=$(_jc sessionExpiryHours); [[ -n "$val" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$val"
    val=$(_jc cbNoProgressThreshold); [[ -n "$val" ]] && CB_NO_PROGRESS_THRESHOLD="$val"
    val=$(_jc cbCooldownMinutes);  [[ -n "$val" ]] && CB_COOLDOWN_MINUTES="$val"
    val=$(_jc cbAutoReset);        [[ -n "$val" ]] && CB_AUTO_RESET="$val"
    val=$(_jc logMaxSizeMb);       [[ -n "$val" ]] && LOG_MAX_SIZE_MB="$val"
    val=$(_jc logMaxFiles);        [[ -n "$val" ]] && LOG_MAX_FILES="$val"
    val=$(_jc logMaxOutputFiles);  [[ -n "$val" ]] && LOG_MAX_OUTPUT_FILES="$val"
    val=$(_jc dryRun);             [[ -n "$val" ]] && DRY_RUN="$val"
    val=$(_jc claudeAutoUpdate);   [[ -n "$val" ]] && CLAUDE_AUTO_UPDATE="$val"
    val=$(_jc verbose);            [[ -n "$val" ]] && VERBOSE_PROGRESS="$val"
    val=$(_jc agentName);          [[ -n "$val" ]] && RALPH_AGENT_NAME="$val"
    val=$(_jc enableTeams);        [[ -n "$val" ]] && RALPH_ENABLE_TEAMS="$val"
    val=$(_jc maxTeammates);       [[ -n "$val" ]] && RALPH_MAX_TEAMMATES="$val"
    val=$(_jc webhookUrl);         [[ -n "$val" ]] && RALPH_WEBHOOK_URL="$val"
    val=$(_jc notifySound);        [[ -n "$val" ]] && RALPH_NOTIFY_SOUND="$val"
    val=$(_jc autoCloseIssues);    [[ -n "$val" ]] && RALPH_AUTO_CLOSE_ISSUES="$val"
    val=$(_jc taskLabel);          [[ -n "$val" ]] && GITHUB_TASK_LABEL="$val"
    val=$(_jc sandboxRequired);    [[ -n "$val" ]] && RALPH_SANDBOX_REQUIRED="$val"
    val=$(_jc sandboxCpuLimit);    [[ -n "$val" ]] && RALPH_SANDBOX_CPU_LIMIT="$val"
    val=$(_jc sandboxMemoryLimit); [[ -n "$val" ]] && RALPH_SANDBOX_MEMORY_LIMIT="$val"
    val=$(_jc maxBackups);         [[ -n "$val" ]] && RALPH_MAX_BACKUPS="$val"

    # Restore env overrides (same pattern as load_ralphrc)
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CLAUDE_TIMEOUT_MINUTES" ]] && CLAUDE_TIMEOUT_MINUTES="$_env_CLAUDE_TIMEOUT_MINUTES"
    [[ -n "$_env_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_env_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_MODEL" ]] && CLAUDE_MODEL="$_env_CLAUDE_MODEL"
    [[ -n "$_env_CLAUDE_EFFORT" ]] && CLAUDE_EFFORT="$_env_CLAUDE_EFFORT"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"
    [[ -n "$_env_RALPH_SHELL_INIT_FILE" ]] && RALPH_SHELL_INIT_FILE="$_env_RALPH_SHELL_INIT_FILE"
    [[ -n "$_env_DRY_RUN" ]] && DRY_RUN="$_env_DRY_RUN"
    [[ -n "$_env_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_env_LOG_MAX_SIZE_MB"
    [[ -n "$_env_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_env_LOG_MAX_FILES"
    [[ -n "$_env_LOG_MAX_OUTPUT_FILES" ]] && LOG_MAX_OUTPUT_FILES="$_env_LOG_MAX_OUTPUT_FILES"

    # TAP-1103: Restore CLI-flag overrides AFTER env restore. Same precedence
    # as load_ralphrc: CLI > env > ralph.config.json > defaults.
    [[ -n "$_cli_DRY_RUN" ]] && DRY_RUN="$_cli_DRY_RUN"
    [[ -n "$_cli_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_cli_CLAUDE_USE_CONTINUE"
    [[ -n "$_cli_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_cli_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_cli_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_cli_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_cli_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_cli_CB_AUTO_RESET"
    [[ -n "$_cli_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_cli_LOG_MAX_SIZE_MB"
    [[ -n "$_cli_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_cli_LOG_MAX_FILES"

    JSON_CONFIG_LOADED=true
    return 0
}

# ralph_export_config - Export current config as JSON
#
# Usage: ralph config --format json
#
ralph_export_config() {
    local format="${1:-json}"
    if [[ "$format" != "json" ]]; then
        echo "Error: Only JSON format supported for config export"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        # Fallback without jq
        cat << JSONEOF
{
  "projectName": "${PROJECT_NAME:-my-project}",
  "maxCallsPerHour": ${MAX_CALLS_PER_HOUR:-200},
  "timeoutMinutes": ${CLAUDE_TIMEOUT_MINUTES:-15},
  "outputFormat": "${CLAUDE_OUTPUT_FORMAT:-json}",
  "sessionContinuity": ${CLAUDE_USE_CONTINUE:-true},
  "cbCooldownMinutes": ${CB_COOLDOWN_MINUTES:-30},
  "cbAutoReset": ${CB_AUTO_RESET:-false},
  "dryRun": ${DRY_RUN:-false},
  "verbose": ${VERBOSE_PROGRESS:-false}
}
JSONEOF
        return 0
    fi

    jq -n \
        --arg pn "${PROJECT_NAME:-my-project}" \
        --arg pt "${PROJECT_TYPE:-unknown}" \
        --argjson mc "${MAX_CALLS_PER_HOUR:-200}" \
        --argjson tm "${CLAUDE_TIMEOUT_MINUTES:-15}" \
        --arg of "${CLAUDE_OUTPUT_FORMAT:-json}" \
        --argjson sc "${CLAUDE_USE_CONTINUE:-true}" \
        --argjson seh "${CLAUDE_SESSION_EXPIRY_HOURS:-24}" \
        --argjson cbcm "${CB_COOLDOWN_MINUTES:-30}" \
        --argjson cbar "${CB_AUTO_RESET:-false}" \
        --argjson lms "${LOG_MAX_SIZE_MB:-10}" \
        --argjson lmf "${LOG_MAX_FILES:-5}" \
        --argjson dr "${DRY_RUN:-false}" \
        --argjson v "${VERBOSE_PROGRESS:-false}" \
        '{
            projectName: $pn,
            projectType: $pt,
            maxCallsPerHour: $mc,
            timeoutMinutes: $tm,
            outputFormat: $of,
            sessionContinuity: $sc,
            sessionExpiryHours: $seh,
            cbCooldownMinutes: $cbcm,
            cbAutoReset: $cbar,
            logMaxSizeMb: $lms,
            logMaxFiles: $lmf,
            dryRun: $dr,
            verbose: $v
        }'
}

# validate_claude_command - Verify the Claude Code CLI is available
#
# Checks that CLAUDE_CODE_CMD resolves to an executable command.
# For npx-based commands, validates that npx is available.
# Returns 0 if valid, 1 if not found (with helpful error message).
#
validate_claude_command() {
    local cmd="$CLAUDE_CODE_CMD"

    # For npx-based commands, check that npx itself is available
    if [[ "$cmd" == npx\ * ]] || [[ "$cmd" == "npx" ]]; then
        if ! command -v npx &>/dev/null; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  NPX NOT FOUND                                            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}CLAUDE_CODE_CMD is set to use npx, but npx is not installed.${NC}"
            echo ""
            echo -e "${YELLOW}To fix this:${NC}"
            echo "  1. Install Node.js (includes npx): https://nodejs.org"
            echo "  2. Or install Claude Code globally:"
            echo "     npm install -g @anthropic-ai/claude-code"
            echo "     Then set in .ralphrc: CLAUDE_CODE_CMD=\"claude\""
            echo ""
            return 1
        fi
        return 0
    fi

    # For direct commands, check that the command exists
    if ! command -v "$cmd" &>/dev/null; then
        # Issue #211: Try sourcing user's shell rc file (zsh/bash) to pick up PATH additions
        # Users who install claude via nvm/fnm/homebrew etc. may only have it in their shell profile
        local _rc_sourced=false
        if [[ -n "${ZSH_VERSION:-}" ]] && [[ -f "$HOME/.zshrc" ]]; then
            source "$HOME/.zshrc" 2>/dev/null && _rc_sourced=true
        elif [[ -f "$HOME/.zshrc" ]] && command -v zsh &>/dev/null; then
            # Running under bash but user has zsh config — extract PATH from zsh
            local _zsh_path
            _zsh_path=$(zsh -ic 'echo $PATH' 2>/dev/null) && export PATH="$_zsh_path" && _rc_sourced=true
        fi
        if [[ "$_rc_sourced" == "false" ]] && [[ -f "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc" 2>/dev/null && _rc_sourced=true
        fi
        # Also try common Node.js manager paths
        for _node_dir in "$HOME/.nvm" "$HOME/.fnm" "$HOME/.local/share/fnm" "$HOME/.volta"; do
            if [[ -d "$_node_dir" ]]; then
                export PATH="$_node_dir/current/bin:$_node_dir/bin:$PATH" 2>/dev/null
            fi
        done
        # Re-check after sourcing
        if ! command -v "$cmd" &>/dev/null; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  CLAUDE CODE CLI NOT FOUND                                ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}The Claude Code CLI command '${cmd}' is not available.${NC}"
            echo ""
            echo -e "${YELLOW}Installation options:${NC}"
            echo "  1. Install globally (recommended):"
            echo "     npm install -g @anthropic-ai/claude-code"
            echo ""
            echo "  2. Use npx (no global install needed):"
            echo "     Add to .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
            echo ""
            echo -e "${YELLOW}Current configuration:${NC} CLAUDE_CODE_CMD=\"${cmd}\""
            echo ""
            echo -e "${YELLOW}After installation or configuration:${NC}"
            echo "  ralph --monitor  # Restart Ralph"
            echo ""
            return 1
        fi
        [[ "$_rc_sourced" == "true" ]] && log_status "INFO" "Found '$cmd' after sourcing shell rc file"
    fi

    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Get the tmux base-index for windows (handles custom tmux configurations)
# Returns: the base window index (typically 0 or 1)
get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${base_index:-0}"
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    # TAP-678: defensive guard — reject whitespace in session name. Current
    # construction is epoch-based and always safe, but a future change that
    # interpolates $PROJECT_DIR or similar must not silently break `tmux
    # send-keys -t`. Replace any whitespace with underscore + fail-loud if
    # the result would still collide with a tmux metacharacter.
    session_name="${session_name//[[:space:]]/_}"
    if [[ "$session_name" =~ [[:space:].:] ]]; then
        log_status "ERROR" "tmux session name contains invalid characters: $session_name"
        return 1
    fi
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir="$(pwd)"

    # Get the tmux base-index to handle custom configurations (e.g., base-index 1)
    local base_win
    base_win=$(get_tmux_base_index)

    log_status "INFO" "Setting up tmux session: $session_name"

    # Initialize live.log file
    echo "=== Ralph Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    # Create new tmux session detached (left pane - Ralph loop)
    tmux new-session -d -s "$session_name" -c "$project_dir"

    # Split window vertically (right side)
    tmux split-window -h -t "$session_name" -c "$project_dir"

    # Split right pane horizontally (top: Claude output, bottom: status)
    tmux split-window -v -t "$session_name:${base_win}.1" -c "$project_dir"

    # Right-top pane (pane 1): Live Claude Code output
    tmux send-keys -t "$session_name:${base_win}.1" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane (pane 2): Ralph status monitor
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:${base_win}.2" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.2" "'$ralph_home/ralph_monitor.sh'" Enter
    fi

    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    # Forward all CLI parameters that were set by the user
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi

    # Always use --live mode in tmux for real-time streaming
    ralph_cmd="$ralph_cmd --live"

    # Forward --calls if non-default
    if [[ "$MAX_CALLS_PER_HOUR" != "200" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    # Forward --prompt if non-default
    if [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    # Forward --output-format if non-default (default is json)
    if [[ "$CLAUDE_OUTPUT_FORMAT" != "json" ]]; then
        ralph_cmd="$ralph_cmd --output-format $CLAUDE_OUTPUT_FORMAT"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    # Forward --timeout if non-default (default is 15)
    if [[ "$CLAUDE_TIMEOUT_MINUTES" != "15" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CLAUDE_TIMEOUT_MINUTES"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CLAUDE_USE_CONTINUE" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default (default is 24)
    if [[ "$CLAUDE_SESSION_EXPIRY_HOURS" != "24" ]]; then
        ralph_cmd="$ralph_cmd --session-expiry $CLAUDE_SESSION_EXPIRY_HOURS"
    fi
    # Forward --auto-reset-circuit if enabled
    if [[ "$CB_AUTO_RESET" == "true" ]]; then
        ralph_cmd="$ralph_cmd --auto-reset-circuit"
    fi
    # Forward --service if set (Issue #163)
    if [[ -n "$RALPH_SERVICE" ]]; then
        ralph_cmd="$ralph_cmd --service '$RALPH_SERVICE'"
    fi

    # Chain tmux kill-session after the loop command so the entire tmux
    # session is torn down when the Ralph loop exits (graceful completion,
    # circuit breaker, error, or manual interrupt). Without this, the
    # tail -f and ralph_monitor.sh panes keep the session alive forever.
    # Issue: https://github.com/frankbria/ralph-claude-code/issues/176
    # Issue #213: KEEP_MONITOR_AFTER_EXIT preserves tail -f and status panes
    if [[ "${KEEP_MONITOR_AFTER_EXIT:-false}" == "true" ]]; then
        tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd; echo 'Ralph loop exited. Monitor panes preserved. Run: tmux kill-session -t $session_name'" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd; tmux kill-session -t $session_name 2>/dev/null" Enter
    fi

    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:${base_win}.0"

    # Set pane titles (requires tmux 2.6+)
    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Claude Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    # Set window title
    tmux rename-window -t "$session_name:${base_win}" "Ralph: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph loop"
    log_status "INFO" "  Right-top:    Claude Code live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"

    exit 0
}

# Issue #156: Detect Windows Terminal availability
check_windows_terminal_available() {
    if command -v wt.exe &>/dev/null; then
        return 0
    fi
    # Check common Windows paths from WSL/Git Bash
    local wt_path="/mnt/c/Users/${USER}/AppData/Local/Microsoft/WindowsApps/wt.exe"
    if [[ -x "$wt_path" ]]; then
        return 0
    fi
    return 1
}

# Issue #156: Setup Windows Terminal split panes as tmux alternative
setup_windows_terminal_session() {
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir
    project_dir=$(pwd)

    log_status "INFO" "Setting up Windows Terminal split panes"

    # Initialize live.log file
    echo "=== Ralph Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    # Build the ralph command for the main pane
    local ralph_cmd
    if command -v ralph &>/dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi
    ralph_cmd="$ralph_cmd --live"
    if [[ "$MAX_CALLS_PER_HOUR" != "200" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    if [[ -n "$RALPH_SERVICE" ]]; then
        ralph_cmd="$ralph_cmd --service '$RALPH_SERVICE'"
    fi

    # Build monitor command
    local monitor_cmd
    if command -v ralph-monitor &>/dev/null; then
        monitor_cmd="ralph-monitor"
    else
        monitor_cmd="'$ralph_home/ralph_monitor.sh'"
    fi

    # Find wt.exe
    local wt_exe="wt.exe"
    if ! command -v wt.exe &>/dev/null; then
        wt_exe="/mnt/c/Users/${USER}/AppData/Local/Microsoft/WindowsApps/wt.exe"
    fi

    # Launch Windows Terminal with split panes:
    # Main pane: Ralph loop
    # Right pane (split vertical): tail -f live.log
    # Bottom-right pane (split horizontal): Ralph monitor
    "$wt_exe" \
        --title "Ralph Loop" \
        -d "$project_dir" bash -c "$ralph_cmd" \; \
        split-pane --vertical --title "Claude Output" \
        -d "$project_dir" bash -c "tail -f '$project_dir/$LIVE_LOG_FILE'" \; \
        split-pane --horizontal --title "Status" \
        -d "$project_dir" bash -c "$monitor_cmd" \
        2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_status "ERROR" "Failed to launch Windows Terminal split panes"
        log_status "INFO" "Falling back to standard execution. Use --monitor with tmux instead."
        return 1
    fi

    log_status "SUCCESS" "Windows Terminal session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph loop"
    log_status "INFO" "  Right-top:    Claude Code live output"
    log_status "INFO" "  Right-bottom: Status monitor"

    exit 0
}

# Initialize call tracking
init_call_tracking() {
    # Debug logging removed for cleaner output
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counters if it's a new hour (invocation + token counts)
    # TAP-535: atomic_write protects counters from partial-write corruption.
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        atomic_write "$CALL_COUNT_FILE" "0" || log_status "ERROR" "Failed to reset CALL_COUNT_FILE"
        atomic_write "$TOKEN_COUNT_FILE" "0" || log_status "ERROR" "Failed to reset TOKEN_COUNT_FILE"  # Issue #223
        atomic_write "$TIMESTAMP_FILE" "$current_hour" || log_status "ERROR" "Failed to write TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

}

# FAILSPEC-3: Check for killswitch file sentinel at each loop iteration.
# Headless/fleet operators can create .ralph/.killswitch to halt the loop.
# File content (if any) is logged as the stop reason.
ralph_check_killswitch() {
    if [[ -f "${RALPH_DIR}/.killswitch" ]]; then
        local reason
        reason=$(cat "${RALPH_DIR}/.killswitch" 2>/dev/null || echo "no reason given")
        reason="${reason:-no reason given}"
        log_status "CRITICAL" "KILLSWITCH activated: $reason"
        rm -f "${RALPH_DIR}/.killswitch"
        return 1
    fi
    return 0
}

# Log function with timestamps and colors
# PERF: Uses printf builtin for timestamp (no date subprocess). Called 30-50x per loop.
log_status() {
    local level=$1
    local message=$2
    local timestamp
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac

    # Write to stderr so log messages don't interfere with function return values
    # 2>/dev/null suppresses "Input/output error" when tmux pty is broken (Issue #188)
    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2 2>/dev/null
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log" 2>/dev/null
}

# Pre-analysis: log permission denials from raw output
ralph_log_permission_denials_from_raw_output() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0

    # Aggregate permission_denials from ALL result objects (not just last)
    local _denial_count=0
    local _denied_cmds=""

    while IFS= read -r _result_line; do
        local _line_denials
        _line_denials=$(echo "$_result_line" | jq '.permission_denials | if . then length else 0 end' 2>/dev/null || echo "0")
        _line_denials=$((_line_denials + 0))
        _denial_count=$((_denial_count + _line_denials))

        if [[ $_line_denials -gt 0 ]]; then
            local _line_cmds
            _line_cmds=$(echo "$_result_line" | jq -r \
                '[.permission_denials[] |
                  if .tool_name == "Bash"
                  then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))"
                  else .tool_name // "unknown"
                  end
                ] | join(", ")' 2>/dev/null || echo "unknown")
            if [[ -n "$_denied_cmds" ]]; then
                _denied_cmds="$_denied_cmds, $_line_cmds"
            else
                _denied_cmds="$_line_cmds"
            fi
        fi
    done < <(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null)

    [[ $_denial_count -gt 0 ]] || return 0

    # LOGFIX-7: Distinguish between bash command denials (fixable via the
    # agent file's disallowedTools blocklist or validate-command.sh) and
    # built-in tool denials (Glob, Grep, Read, Write, Edit — filesystem scope)
    local _builtin_pattern="^(Glob|Grep|Read|Write|Edit|NotebookEdit)$"
    local _has_bash_denials=false _has_builtin_denials=false
    local IFS_bak="$IFS"
    IFS=","
    for _cmd in $_denied_cmds; do
        _cmd=$(echo "$_cmd" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if echo "$_cmd" | grep -qE "$_builtin_pattern"; then
            _has_builtin_denials=true
        else
            _has_bash_denials=true
        fi
    done
    IFS="$IFS_bak"

    log_status "WARN" "Permission denied for $_denial_count command(s): $_denied_cmds"
    if [[ "$_has_bash_denials" == "true" ]]; then
        log_status "WARN" "Edit .claude/agents/ralph.md (disallowedTools blocklist) or .claude/hooks/validate-command.sh to lift the restriction."
    fi
    if [[ "$_has_builtin_denials" == "true" ]]; then
        log_status "INFO" "Built-in tool denials (Glob/Grep/Read) are filesystem scope restrictions, not blocklist issues"
    fi
}

# CAPTURE-2: Multi-result stream merging — JSONL is the primary path since CLI v2.1+
# Uses last-writer-wins: the final top-level result is authoritative.
# Sub-agent results (with parent_tool_use_id/subagent) are excluded from result count.
ralph_extract_result_from_stream() {
    local output_file=$1
    local extraction_context="${2:-normal}"  # LOGFIX-3: "normal" or "timeout"
    [[ -f "$output_file" ]] || return 0
    local _tl_count
    # Count top-level JSON objects by counting "type" keys (streaming — no memory load)
    # Avoids jq -s which loads entire file into memory and crashes on large JSONL streams
    _tl_count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null) || _tl_count=1
    [[ "$_tl_count" -gt 1 ]] || return 0

    # Count only top-level result objects — subagent results contain a
    # subagent or parent_tool_use_id field and should not be counted
    local _result_count _toplevel_count
    _result_count=$(grep -c -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null) || _result_count=0
    _toplevel_count=$(jq -c 'select(.type == "result") | select(.subagent == null and .parent_tool_use_id == null)' "$output_file" 2>/dev/null | wc -l || echo "$_result_count")
    _toplevel_count=$(echo "$_toplevel_count" | tr -d '[:space:]')
    _toplevel_count=$((_toplevel_count + 0))

    if [[ "$_toplevel_count" -eq 0 ]]; then
        # LOGFIX-3: Downgrade to WARN when failure is caused by a known timeout
        if [[ "$extraction_context" == "timeout" ]]; then
            log_status "WARN" "Stream extraction incomplete (timeout): no valid result object in stream"
        else
            log_status "ERROR" "Stream extraction failed: no valid result object in stream"
        fi
        return 1
    fi

    # CAPTURE-2: Multi-result is expected for multi-task batches — log at DEBUG, not WARN
    if [[ "$_toplevel_count" -gt 1 ]]; then
        log_status "DEBUG" "Stream contains $_toplevel_count top-level result objects — using last (authoritative)"
    elif [[ "$_result_count" -gt 1 ]]; then
        log_status "DEBUG" "Stream contains $_result_count result objects ($_toplevel_count top-level, $((_result_count - _toplevel_count)) subagent)"
    fi

    # Last-writer-wins: take the final top-level result (most authoritative)
    local _extracted_result
    _extracted_result=$(jq -c 'select(.type == "result") | select(.subagent == null and .parent_tool_use_id == null)' "$output_file" 2>/dev/null | tail -1)

    if [[ -n "$_extracted_result" ]] && echo "$_extracted_result" | jq -e . >/dev/null 2>&1; then
        local _backup="${output_file%.log}_stream.log"
        if [[ ! -f "$_backup" ]]; then
            cp "$output_file" "$_backup"
            log_status "INFO" "Created stream backup: $_backup"
        fi
        echo "$_extracted_result" > "$output_file"
        log_status "INFO" "Stream extraction: isolated result object from JSONL stream (extraction_method=stream)"
    else
        # LOGFIX-3: Downgrade to WARN when failure is caused by a known timeout
        if [[ "$extraction_context" == "timeout" ]]; then
            log_status "WARN" "Stream extraction incomplete (timeout): could not isolate result object"
        else
            log_status "ERROR" "Stream extraction failed: no valid result object in stream"
        fi
        return 1
    fi
}

# CAPTURE-1: Partial result extraction fallback for truncated streams (timeout/SIGTERM)
ralph_extract_partial_result() {
    local stream_file="$1"
    local result_file="$2"

    # Try normal extraction first
    if ralph_extract_result_from_stream "$stream_file"; then
        return 0
    fi

    # Fallback: find the last valid JSON line with type=result
    local last_result
    last_result=$(tac "$stream_file" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | jq -e '.type == "result"' >/dev/null 2>&1; then
            echo "$line"
            break
        fi
    done)

    if [[ -n "$last_result" ]]; then
        echo "$last_result" > "$result_file"
        log_status "INFO" "Extracted partial result from truncated stream"
        return 0
    fi

    # Last resort: count valid NDJSON lines for stats
    local valid_lines
    valid_lines=$(jq -c '.' "$stream_file" 2>/dev/null | wc -l)
    valid_lines=$(echo "$valid_lines" | tr -d '[:space:]')
    log_status "WARN" "No result object in stream ($valid_lines valid NDJSON lines found)"
    return 1
}

# UPKEEP-2: Post-run MCP failure logging with per-session suppression
ralph_log_failed_mcp_servers_from_output() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0
    local sys_line
    sys_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | head -1)
    [[ -n "$sys_line" ]] || return 0
    local failed_mcps
    failed_mcps=$(echo "$sys_line" | jq -r '[.mcp_servers[]? | select(.status == "failed") | .name] | join(", ")' 2>/dev/null)
    [[ -n "$failed_mcps" && "$failed_mcps" != "null" ]] || return 0

    # UPKEEP-2: Use per-session suppression instead of logging every time
    local IFS=','
    for server in $failed_mcps; do
        server=$(echo "$server" | tr -d '[:space:]')
        [[ -n "$server" ]] && ralph_record_mcp_failure "$server"
    done
}

# Run all lightweight pre-analyze steps on Claude output
ralph_prepare_claude_output_for_analysis() {
    local output_file=$1
    local extraction_context="${2:-normal}"  # LOGFIX-3: "normal" or "timeout"
    # Log from full stream before extraction removes system / multi-line context
    ralph_log_permission_denials_from_raw_output "$output_file"
    ralph_log_failed_mcp_servers_from_output "$output_file"
    ralph_extract_result_from_stream "$output_file" "$extraction_context"
}

# =============================================================================
# SESSION PERSISTENCE FUNCTIONS (moved from lib/response_analyzer.sh)
# =============================================================================

# Store session ID to file with timestamp
store_session_id() {
    local session_id=$1
    [[ -z "$session_id" ]] && return 1
    jq -n \
        --arg session_id "$session_id" \
        --arg timestamp "$(get_iso_timestamp)" \
        '{ session_id: $session_id, timestamp: $timestamp }' > "$SESSION_FILE"
    return 0
}

# Get the last stored session ID
get_last_session_id() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo ""
        return 0
    fi
    jq -r '.session_id // ""' "$SESSION_FILE" 2>/dev/null
    return 0
}

# Check if the stored session should be resumed
should_resume_session() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo "false"
        return 1
    fi

    local timestamp
    timestamp=$(jq -r '.timestamp // ""' "$SESSION_FILE" 2>/dev/null)
    if [[ -z "$timestamp" ]]; then
        echo "false"
        return 1
    fi

    local now session_time clean_timestamp
    now=$(get_epoch_seconds)
    clean_timestamp="${timestamp}"
    if [[ "$timestamp" =~ \.[0-9]+[+-Z] ]]; then
        clean_timestamp=$(echo "$timestamp" | sed 's/\.[0-9]*\([+-Z]\)/\1/')
    fi

    if command -v gdate &>/dev/null; then
        session_time=$(gdate -d "$clean_timestamp" +%s 2>/dev/null)
    elif date --version 2>&1 | grep -q GNU; then
        session_time=$(date -d "$clean_timestamp" +%s 2>/dev/null)
    else
        local date_only="${clean_timestamp%[+-Z]*}"
        session_time=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$date_only" +%s 2>/dev/null)
    fi

    if [[ -z "$session_time" || ! "$session_time" =~ ^[0-9]+$ ]]; then
        echo "false"
        return 1
    fi

    local age=$((now - session_time))
    if [[ $age -lt $SESSION_EXPIRATION_SECONDS ]]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}

# =============================================================================
# STATUS.JSON-BASED ANALYSIS FUNCTIONS (replaces analyze_response + friends)
# =============================================================================

# Update exit signals file based on status.json (replaces update_exit_signals from response_analyzer.sh)
update_exit_signals_from_status() {
    local status_file="${RALPH_DIR}/status.json"
    local exit_signals_file="${EXIT_SIGNALS_FILE}"

    if [[ ! -f "$status_file" ]]; then
        return 1
    fi

    # PERF: Read ALL status.json fields in single jq call (was: 6 separate jq spawns)
    local exit_signal status tasks_completed files_modified work_type loop_number
    local _status_tsv
    _status_tsv=$(jq -r '[
      (.exit_signal // "false"),
      (.status // "UNKNOWN"),
      (.tasks_completed // 0 | tostring),
      (.files_modified // 0 | tostring),
      (.work_type // "UNKNOWN"),
      (.loop_count // 0 | tostring)
    ] | @tsv' "$status_file" 2>/dev/null || echo "false	UNKNOWN	0	0	UNKNOWN	0")
    IFS=$'\t' read -r exit_signal status tasks_completed files_modified work_type loop_number <<< "$_status_tsv"

    # Determine derived flags
    local is_test_only="false"
    [[ "$work_type" == "TESTING" ]] && is_test_only="true"

    local has_completion_signal="false"
    [[ "$status" == "COMPLETE" ]] && has_completion_signal="true"

    local has_progress="false"
    [[ "$files_modified" -gt 0 || "$tasks_completed" -gt 0 ]] && has_progress="true"

    # PERF: Read, update, and write exit signals in a single jq call (was: 5 separate jq spawns)
    local signals
    signals=$(jq \
        --argjson loop "$loop_number" \
        --arg test_only "$is_test_only" \
        --arg complete "$has_completion_signal" \
        --arg exit_sig "$exit_signal" \
        --arg progress "$has_progress" '
      (if $test_only == "true" then .test_only_loops += [$loop]
       elif $progress == "true" then .test_only_loops = []
       else . end) |
      (if $complete == "true" then .done_signals += [$loop] else . end) |
      (if $exit_sig == "true" then .completion_indicators += [$loop]
       elif $progress == "true" then .completion_indicators = []
       else . end) |
      .test_only_loops = .test_only_loops[-5:] |
      .done_signals = .done_signals[-5:] |
      .completion_indicators = .completion_indicators[-5:]
    ' "$exit_signals_file" 2>/dev/null || echo '{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}')

    echo "$signals" > "$exit_signals_file"
    return 0
}

# Log analysis summary from status.json (replaces log_analysis_summary from response_analyzer.sh)
log_status_summary() {
    local status_file="${RALPH_DIR}/status.json"
    [[ -f "$status_file" ]] || return 1

    # PERF: Read ALL fields in single jq call (was: 5 separate jq spawns)
    local loop exit_sig files_modified work_type recommendation asking_q q_count has_pd pd_count
    local _summary_tsv
    _summary_tsv=$(jq -r '[
      (.loop_count // "?" | tostring),
      (.exit_signal // "false"),
      (.files_modified // 0 | tostring),
      (.work_type // "UNKNOWN"),
      (.recommendation // ""),
      (.asking_questions // false | tostring),
      (.question_count // 0 | tostring),
      (.has_permission_denials // false | tostring),
      (.permission_denial_count // 0 | tostring)
    ] | @tsv' "$status_file" 2>/dev/null || echo "?	false	0	UNKNOWN		false	0	false	0")
    IFS=$'\t' read -r loop exit_sig files_modified work_type recommendation asking_q q_count has_pd pd_count <<< "$_summary_tsv"

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Response Analysis - Loop #$loop                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Exit Signal:${NC}      $exit_sig"
    echo -e "${YELLOW}Files Changed:${NC}    $files_modified"
    echo -e "${YELLOW}Work Type:${NC}        $work_type"
    [[ "$asking_q" == "true" ]] && echo -e "${YELLOW}Questions:${NC}        $q_count patterns matched"
    [[ "$has_pd" == "true" ]] && echo -e "${RED}Perm Denials:${NC}     $pd_count detected"
    echo -e "${YELLOW}Summary:${NC}          $recommendation"
    echo ""
}

# USYNC-5: Detect stuck loops by comparing error patterns across recent outputs (upstream response_analyzer.sh)
# Returns 0 if stuck (same errors repeating in last 3+ outputs), 1 otherwise.
detect_stuck_loop() {
    local current_output="$1"
    local history_dir="${LOG_DIR:-$RALPH_DIR/logs}"

    [[ -f "$current_output" ]] || return 1

    # Get 3 most recent output files (excluding current)
    local recent_files
    recent_files=$(ls -t "$history_dir"/claude_output_*.log 2>/dev/null | grep -v "$(basename "$current_output")" | head -3)

    [[ -z "$recent_files" ]] && return 1  # Not enough history

    # Extract error lines from current output
    # Filter out JSON field false positives (e.g., "is_error": false)
    local current_errors
    current_errors=$(grep -v '"[^"]*error[^"]*":' "$current_output" 2>/dev/null \
        | grep -E '(^Error:|^ERROR:|^error:|\]: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' \
        | sort | uniq)

    [[ -z "$current_errors" ]] && return 1  # No errors = not stuck

    # Check if ALL recent files contain ALL current errors
    local all_match=true
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        while IFS= read -r error_line; do
            [[ -z "$error_line" ]] && continue
            if ! grep -qF "$error_line" "$file" 2>/dev/null; then
                all_match=false
                break 2
            fi
        done <<< "$current_errors"
    done <<< "$recent_files"

    if [[ "$all_match" == "true" ]]; then
        # Store stuck errors for diagnostics
        local stuck_error_sample
        stuck_error_sample=$(echo "$current_errors" | head -1 | cut -c1-120)
        log_status "WARN" "Stuck loop detected: same errors in last 3+ outputs: $stuck_error_sample"

        # Update status.json with stuck state (append fields via jq)
        if [[ -f "$RALPH_DIR/status.json" ]]; then
            local _tmp
            _tmp=$(mktemp "$RALPH_DIR/status.json.XXXXXX")
            jq --arg err "$stuck_error_sample" '.is_stuck = true | .stuck_error = $err' \
                "$RALPH_DIR/status.json" > "$_tmp" 2>/dev/null \
                && mv "$_tmp" "$RALPH_DIR/status.json"
            rm -f "$_tmp" 2>/dev/null
        fi
        return 0
    fi

    return 1
}

# Update status JSON for external monitoring.
# MERGE-1: Merge with existing status.json so on-stop.sh fields (linear_*, loop_model,
# cache stats, subagent counts) survive across update_status calls. Also always read
# the fresh .call_count from disk — the caller's $calls_made arg may be stale.
update_status() {
    local loop_count=$1
    local _caller_calls=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}

    # Prefer on-disk counter over caller's arg (counter is incremented post-invocation).
    local calls_made
    calls_made=$(_read_call_count 2>/dev/null || echo "${_caller_calls:-0}")
    [[ "$calls_made" =~ ^[0-9]+$ ]] || calls_made="${_caller_calls:-0}"

    local _tmp
    _tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
    local _loop_fields
    _loop_fields=$(jq -n \
        --arg ts "$(get_iso_timestamp)" \
        --argjson lc "$loop_count" \
        --argjson cm "$calls_made" \
        --argjson mc "$MAX_CALLS_PER_HOUR" \
        --arg la "$last_action" \
        --arg st "$status" \
        --arg er "$exit_reason" \
        --arg nr "$(get_next_hour_time)" \
        '{timestamp:$ts, loop_count:$lc, calls_made_this_hour:$cm, max_calls_per_hour:$mc, last_action:$la, status:$st, exit_reason:$er, next_reset:$nr}' 2>/dev/null)

    if [[ -f "$STATUS_FILE" ]] && jq -e 'type == "object"' "$STATUS_FILE" >/dev/null 2>&1; then
        # Merge: existing status.json + loop fields (loop fields win on overlap).
        printf '%s' "$_loop_fields" | jq -s --slurpfile prev "$STATUS_FILE" '$prev[0] * .[0]' > "$_tmp" 2>/dev/null \
            || printf '%s' "$_loop_fields" > "$_tmp"
    else
        printf '%s' "$_loop_fields" > "$_tmp"
    fi

    mv "$_tmp" "$STATUS_FILE"
    rm -f "$_tmp" 2>/dev/null  # WSL-1 safety
}

# PERF: Helper to read call count without cat subprocess
_read_call_count() {
    local _cc=0
    [[ -f "$CALL_COUNT_FILE" ]] && read -r _cc < "$CALL_COUNT_FILE" 2>/dev/null
    echo "${_cc:-0}"
}

# Issue #223: Helper to read token count
_read_token_count() {
    local _tc=0
    [[ -f "$TOKEN_COUNT_FILE" ]] && read -r _tc < "$TOKEN_COUNT_FILE" 2>/dev/null
    echo "${_tc:-0}"
}

# Check if we can make another call (invocation + token limits)
can_make_call() {
    local calls_made
    calls_made=$(_read_call_count)

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call — invocation limit
    fi

    # Issue #223: Token-based rate limiting (0 = disabled)
    if [[ "$MAX_TOKENS_PER_HOUR" -gt 0 ]]; then
        local tokens_used
        tokens_used=$(_read_token_count)
        if [[ $tokens_used -ge $MAX_TOKENS_PER_HOUR ]]; then
            log_status "WARN" "Token limit reached ($tokens_used/$MAX_TOKENS_PER_HOUR tokens/hour)"
            return 1  # Cannot make call — token limit
        fi
    fi

    return 0  # Can make call
}

# Increment call counter
increment_call_counter() {
    local calls_made
    calls_made=$(_read_call_count)

    ((calls_made++))
    # TAP-535: atomic_write — prevents zero-byte counter on SIGTERM mid-write.
    atomic_write "$CALL_COUNT_FILE" "$calls_made" || log_status "ERROR" "Failed to persist CALL_COUNT_FILE"
    echo "$calls_made"
}

# Issue #223: Accumulate token usage from Claude output
accumulate_tokens() {
    local output_file=$1
    [[ ! -f "$output_file" ]] && return 0
    [[ "$MAX_TOKENS_PER_HOUR" -eq 0 ]] && return 0  # Token tracking disabled

    local tokens_in tokens_out tokens_this_call
    tokens_in=$(jq -r '.usage.input_tokens // 0' "$output_file" 2>/dev/null || echo "0")
    tokens_out=$(jq -r '.usage.output_tokens // 0' "$output_file" 2>/dev/null || echo "0")
    tokens_this_call=$((tokens_in + tokens_out))

    if [[ $tokens_this_call -gt 0 ]]; then
        local current_tokens
        current_tokens=$(_read_token_count)
        local new_total=$((current_tokens + tokens_this_call))
        # TAP-535: atomic_write — token counter must survive partial writes.
        atomic_write "$TOKEN_COUNT_FILE" "$new_total" || log_status "ERROR" "Failed to persist TOKEN_COUNT_FILE"
        log_status "INFO" "Tokens this call: $tokens_this_call (total: $new_total/$MAX_TOKENS_PER_HOUR)"
    fi
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made
    calls_made=$(_read_call_count)
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counters (invocation + tokens) — TAP-535: atomic_write for safety.
    atomic_write "$CALL_COUNT_FILE" "0" || log_status "ERROR" "Failed to reset CALL_COUNT_FILE"
    atomic_write "$TOKEN_COUNT_FILE" "0" || log_status "ERROR" "Failed to reset TOKEN_COUNT_FILE"  # Issue #223
    atomic_write "$TIMESTAMP_FILE" "$(date +%Y%m%d%H)" || log_status "ERROR" "Failed to write TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals
    read -r signals < "$EXIT_SIGNALS_FILE" 2>/dev/null || signals='{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}'

    # PERF: Count ALL signal lengths in single jq call (was: 3 separate jq spawns)
    local recent_test_loops recent_done_signals recent_completion_indicators
    local _sig_tsv
    _sig_tsv=$(echo "$signals" | jq -r '[
      (.test_only_loops | length),
      (.done_signals | length),
      (.completion_indicators | length)
    ] | @tsv' 2>/dev/null || echo "0	0	0")
    IFS=$'\t' read -r recent_test_loops recent_done_signals recent_completion_indicators <<< "$_sig_tsv"

    # Diagnostic logging for exit signal check (Issue #194)
    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "DEBUG" "Exit check: test_loops=$recent_test_loops done_signals=$recent_done_signals completion_indicators=$recent_completion_indicators"

    # Check for exit conditions

    # 0. Permission denials (highest priority - Issue #101)
    # Check circuit breaker state for permission denial tracking (set by on-stop.sh hook)
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local perm_denials
        perm_denials=$(jq -r '.consecutive_permission_denials // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
        if [[ "$perm_denials" -ge "${CB_PERMISSION_DENIAL_THRESHOLD:-2}" ]]; then
            log_status "WARN" "🚫 Permission denied in $perm_denials consecutive loops"
            log_status "WARN" "Edit .claude/agents/ralph.md (disallowedTools blocklist) or .claude/hooks/validate-command.sh to lift the restriction."
            echo "permission_denied"
            return 0
        fi
    fi

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Safety circuit breaker - force exit after 5 consecutive EXIT_SIGNAL=true responses
    # Note: completion_indicators only accumulates when Claude explicitly sets EXIT_SIGNAL=true
    # (not based on confidence score), and resets to [] when productive work (files_modified > 0
    # or tasks_completed > 0) occurs with exit_signal=false. This decay prevents false positives
    # where Claude says "done" early, does more work, then says "done" again for a different reason.
    # This safety breaker catches cases where Claude signals completion 5+ times without any
    # intervening productive work. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Claude explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in status.json represents Claude's explicit intent (written by on-stop.sh hook).
    local claude_exit_signal="false"
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        claude_exit_signal=$(jq -r '.exit_signal // "false"' "$RALPH_DIR/status.json" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi
    
    # 5. Check task source for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-536: A Linear API failure must NOT trip a "plan_complete" exit.
        # The backend now distinguishes "exit 0 + value" (real count) from
        # "exit non-zero" (API/network/parse error). On any error we abstain
        # from this iteration's exit decision and let the next loop retry.
        local open_items done_items _lvl="WARN" _stderr=""
        # TAP-741: in push-mode (no API key) iter-1 has no hook counts yet;
        # log INFO instead of WARN so the expected bootstrap isn't noisy, and
        # hide the structured `linear_api_error:` stderr line for the same
        # reason. API-key mode keeps the old behavior (WARN + structured line).
        if [[ -z "${LINEAR_API_KEY:-}" ]]; then _lvl="INFO"; _stderr="/dev/null"; fi
        if ! open_items=$(linear_get_open_count 2>"${_stderr:-/dev/stderr}"); then
            log_status "$_lvl" "Linear count (open_count) unavailable — skipping exit gate this iteration" >&2
            echo ""
            return 0
        fi
        if ! done_items=$(linear_get_done_count 2>"${_stderr:-/dev/stderr}"); then
            log_status "$_lvl" "Linear count (done_count) unavailable — skipping exit gate this iteration" >&2
            echo ""
            return 0
        fi
        local total_items=$((open_items + done_items))
        # PREFLIGHT-EMPTY-PLAN (Linear branch): zero open issues = nothing to do
        # this iteration, regardless of whether the project has any done items.
        # Same rationale as the fix_plan.md branch: exit clean rather than burn
        # a Claude call into an empty backlog. Operator restarts after seeding work.
        # NOTE: open_items=0 here is an authoritative count (TAP-536 contract);
        # API failures took the abstain path above and never reach this check.
        if [[ $open_items -eq 0 ]]; then
            if [[ $total_items -gt 0 ]]; then
                log_status "WARN" "Exit condition: All Linear issues completed ($done_items/$total_items) in project '${RALPH_LINEAR_PROJECT}'" >&2
            else
                log_status "WARN" "Exit condition: Linear project '${RALPH_LINEAR_PROJECT}' has zero open issues (no work seeded)" >&2
            fi
            echo "plan_complete"
            return 0
        fi
    elif [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        # Valid patterns: "- [ ]" (uncompleted) and "- [x]" or "- [X]" (completed)
        local uncompleted_items
        uncompleted_items=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || uncompleted_items=0
        # Strip any whitespace/newlines from grep -c output to keep arithmetic safe
        # (mirrors the on-stop.sh fix for the same grep -c pitfall).
        uncompleted_items=$(echo "$uncompleted_items" | tr -cd '0-9'); uncompleted_items=${uncompleted_items:-0}
        local completed_items
        completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || completed_items=0
        completed_items=$(echo "$completed_items" | tr -cd '0-9'); completed_items=${completed_items:-0}
        local total_items=$((uncompleted_items + completed_items))

        # PREFLIGHT-EMPTY-PLAN: Zero unchecked items means there's nothing to do this
        # iteration — exit cleanly rather than burning a Claude call on an empty plan.
        # Three cases lead here:
        #   1. All items completed (total>0, completed==total) — original condition.
        #   2. fix_plan.md has only headers / explanatory text, no checkboxes at all
        #      (total==0). This is the EPIC-just-finished state where the next campaign
        #      hasn't been populated yet — Claude would just respond "nothing to do"
        #      every loop until the no-progress CB trips after 3 wasted calls.
        #   3. Mixed file with some checked items but zero open ones.
        # In all three, exiting now beats spinning. Operator restarts after editing the plan.
        if [[ $uncompleted_items -eq 0 ]]; then
            if [[ $total_items -gt 0 ]]; then
                log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            else
                log_status "WARN" "Exit condition: fix_plan.md has zero unchecked tasks (file present but empty of work)" >&2
            fi
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

# PERF: Cached Claude CLI version — avoids repeated Node.js launches (was: 4 separate --version calls)
_CACHED_CLAUDE_VERSION=""
get_cached_claude_version() {
    if [[ -z "$_CACHED_CLAUDE_VERSION" ]]; then
        _CACHED_CLAUDE_VERSION=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    echo "$_CACHED_CLAUDE_VERSION"
}

# Compare two semver strings: returns 0 if ver1 >= ver2, 1 if ver1 < ver2
# Uses sequential major→minor→patch comparison (safe for any patch number)
compare_semver() {
    local ver1="$1" ver2="$2"
    local v1_major v1_minor v1_patch
    local v2_major v2_minor v2_patch

    IFS='.' read -r v1_major v1_minor v1_patch <<< "$ver1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$ver2"

    v1_major=${v1_major:-0}; v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
    v2_major=${v2_major:-0}; v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}

    if [[ $v1_major -gt $v2_major ]]; then return 0; fi
    if [[ $v1_major -lt $v2_major ]]; then return 1; fi
    if [[ $v1_minor -gt $v2_minor ]]; then return 0; fi
    if [[ $v1_minor -lt $v2_minor ]]; then return 1; fi
    if [[ $v1_patch -lt $v2_patch ]]; then return 1; fi
    return 0
}

# Check Claude CLI version for compatibility with modern flags
check_claude_version() {
    local version
    version=$(get_cached_claude_version)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
        return 0
    fi

    if ! compare_semver "$version" "$CLAUDE_MIN_VERSION"; then
        log_status "WARN" "Claude CLI version $version < $CLAUDE_MIN_VERSION. Some modern features may not work."
        log_status "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
        return 1
    fi

    log_status "INFO" "Claude CLI version $version (>= $CLAUDE_MIN_VERSION) - modern features enabled"
    return 0
}

# UPKEEP-1: Check for Claude CLI updates with post-update verification (Issue #190)
UPDATE_FAILURE_FILE="${RALPH_DIR}/.update_failures"
MAX_UPDATE_ATTEMPTS="${MAX_UPDATE_ATTEMPTS:-3}"

check_claude_updates() {
    if [[ "${CLAUDE_AUTO_UPDATE:-true}" != "true" ]]; then
        return 0
    fi

    local installed_version
    installed_version=$(get_cached_claude_version)
    if [[ -z "$installed_version" ]]; then
        return 0
    fi

    # Query latest version from npm registry (with timeout to avoid hanging on flaky networks)
    local latest_version
    latest_version=$(portable_timeout 5s npm view @anthropic-ai/claude-code version 2>/dev/null)
    if [[ -z "$latest_version" ]]; then
        log_status "INFO" "Could not check for Claude CLI updates (npm registry unreachable)"
        return 0
    fi

    if [[ "$installed_version" == "$latest_version" ]]; then
        log_status "INFO" "Claude CLI is up to date ($installed_version)"
        return 0
    fi

    if compare_semver "$installed_version" "$latest_version"; then
        return 0
    fi

    # UPKEEP-1: Check if we've exceeded update attempts for this version
    if [[ -f "$UPDATE_FAILURE_FILE" ]]; then
        local failures
        failures=$(grep -c "$latest_version" "$UPDATE_FAILURE_FILE" 2>/dev/null || echo "0")
        if [[ "$failures" -ge "$MAX_UPDATE_ATTEMPTS" ]]; then
            log_status "DEBUG" "Skipping update to $latest_version (previous $failures failures exceeded threshold)"
            return 0
        fi
    fi

    # Auto-update attempt
    log_status "INFO" "Claude CLI update available: $installed_version → $latest_version. Attempting auto-update..."
    local update_output
    if update_output=$(npm update -g @anthropic-ai/claude-code 2>&1); then
        # UPKEEP-1: Post-update verification — check actual installed version
        local new_version
        new_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        if [[ "$new_version" == "$latest_version" ]]; then
            log_status "SUCCESS" "Claude CLI updated: $installed_version → $new_version"
            : > "$UPDATE_FAILURE_FILE" 2>/dev/null  # Clear failures on success
            return 0
        elif [[ -n "$new_version" && "$new_version" != "$installed_version" ]]; then
            log_status "WARN" "Claude CLI updated but to unexpected version: $installed_version → $new_version (expected $latest_version)"
            return 0
        else
            log_status "WARN" "Claude CLI update failed — version unchanged at $installed_version"
            echo "$(date +%s) $latest_version" >> "$UPDATE_FAILURE_FILE"
            local fail_count
            fail_count=$(grep -c "$latest_version" "$UPDATE_FAILURE_FILE" 2>/dev/null || echo "1")
            if [[ "$fail_count" -ge "$MAX_UPDATE_ATTEMPTS" ]]; then
                log_status "WARN" "Update to $latest_version has failed $fail_count times — suppressing further attempts"
                log_status "WARN" "Update manually: npm install -g @anthropic-ai/claude-code@$latest_version"
            fi
            return 1
        fi
    fi

    # Auto-update failed — warn with environment-specific guidance
    log_status "WARN" "Claude CLI auto-update failed ($installed_version → $latest_version)"
    [[ -n "$update_output" ]] && log_status "DEBUG" "npm output: $update_output"
    echo "$(date +%s) $latest_version" >> "$UPDATE_FAILURE_FILE"
    log_status "WARN" "Update manually: npm update -g @anthropic-ai/claude-code"
    log_status "WARN" "In Docker: rebuild your image to include the latest version"
    return 1
}

# Check if the installed Claude CLI supports agent teams (requires v2.1.32+)
check_teams_support() {
    local version
    version=$(get_cached_claude_version)

    if [[ -z "$version" ]]; then
        return 1
    fi

    # Teams require v2.1.32+
    compare_semver "$version" "2.1.32"
}

# Setup agent teams if enabled via RALPH_ENABLE_TEAMS
setup_teams() {
    if [[ "${RALPH_ENABLE_TEAMS:-false}" != "true" ]]; then
        return 0
    fi

    # Check CLI version supports teams
    if ! check_teams_support; then
        log_status "WARN" "Agent teams require Claude Code v2.1.32+. Falling back to sequential."
        RALPH_ENABLE_TEAMS=false
        return 0
    fi

    # Create local settings with teams env var
    local settings_local=".claude/settings.local.json"
    mkdir -p .claude
    cat > "$settings_local" <<EOF
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "${RALPH_TEAMMATE_MODE:-tmux}"
}
EOF

    log_status "INFO" "Agent teams enabled (max ${RALPH_MAX_TEAMMATES:-3} teammates, mode=${RALPH_TEAMMATE_MODE:-tmux})"
}

# Check for WSL/Windows version divergence
# Detects when Ralph is installed in both WSL and Windows and versions differ.
# This prevents silent loop crashes caused by one copy using removed APIs (e.g. response_analyzer.sh).
check_version_divergence() {
    # Only relevant in WSL environments
    if [[ ! -d "/mnt/c" ]] || [[ "$(uname -r)" != *icrosoft* && "$(uname -r)" != *WSL* ]]; then
        return 0
    fi

    # Find Windows user home directory
    local win_home=""
    for user_dir in /mnt/c/Users/*/; do
        if [[ -f "${user_dir}.ralph/ralph_loop.sh" ]]; then
            win_home="$user_dir"
            break
        fi
    done

    [[ -z "$win_home" ]] && return 0

    local win_script="${win_home}.ralph/ralph_loop.sh"
    # XPLAT-1: Strip \r, \n, and whitespace from both version strings before comparison
    # Windows NTFS files often have \r\n line endings, causing false divergence warnings
    local wsl_version win_version
    wsl_version=$(echo "$RALPH_VERSION" | tr -d '\r\n[:space:]')
    win_version=$(grep -m1 'RALPH_VERSION=' "$win_script" 2>/dev/null | sed 's/.*RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '\r\n[:space:]')

    if [[ -z "$win_version" ]]; then
        log_status "DEBUG" "Could not extract Windows Ralph version — skipping divergence check"
        return 0
    fi

    if [[ "$wsl_version" != "$win_version" ]]; then
        log_status "WARN" "VERSION DIVERGENCE: WSL=$wsl_version, Windows=$win_version"
        log_status "WARN" "This can cause silent loop crashes. Sync with:"
        log_status "WARN" "  cp -r '${win_home}.ralph/'* ~/.ralph/ && find ~/.ralph/ -type f -name '*.sh' -exec sed -i 's/\\r\$//' {} +"
    else
        log_status "DEBUG" "Version check OK: WSL=$wsl_version, Windows=$win_version"
    fi

    # Also check for stale response_analyzer.sh (removed in v1.0.0)
    if [[ -f "$SCRIPT_DIR/lib/response_analyzer.sh" ]]; then
        log_status "WARN" "STALE FILE: lib/response_analyzer.sh exists but was removed in v1.0.0"
        log_status "WARN" "This Ralph install may be outdated. Response analysis is now handled by on-stop.sh hook."
    fi
}

# =============================================================================
# XPLAT-2: Cross-Platform Hook Environment Detection (Phase 13)
# Validate hook scripts at startup and check platform-specific commands.
# =============================================================================

ralph_validate_hooks() {
    local hooks_dir="$RALPH_DIR/hooks"
    [[ -d "$hooks_dir" ]] || return 0

    local hook
    for hook in "$hooks_dir"/*.sh; do
        [[ -f "$hook" ]] || continue
        if [[ ! -x "$hook" ]]; then
            log_status "WARN" "Hook not executable: $hook (run: chmod +x $hook)"
        fi
    done

    # Check for bare 'powershell' references that will fail in WSL
    # Exclude platform_detect.sh itself (it contains the helper function definition)
    if grep -rl 'powershell[^.]' "$hooks_dir"/*.sh 2>/dev/null | grep -qv 'platform_detect.sh'; then
        # Check if we're in WSL
        if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || grep -qi "microsoft" /proc/version 2>/dev/null; then
            if ! command -v powershell &>/dev/null; then
                log_status "WARN" "Hooks reference 'powershell' but it's not available in WSL. Use 'powershell.exe' instead."
                log_status "INFO" "Source platform_detect.sh in your hooks for cross-platform compatibility"
            fi
        fi
    fi

    # XPLAT-2b: Check project's .claude/settings.json for bare 'powershell' hook commands
    # These hooks run at session start and cause errors if powershell isn't on PATH in WSL
    local project_settings=".claude/settings.json"
    if [[ -f "$project_settings" ]]; then
        if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || grep -qi "microsoft" /proc/version 2>/dev/null; then
            if ! command -v powershell &>/dev/null; then
                # Look for "command": "powershell ..." (bare powershell, not powershell.exe)
                # sed only replaces '"powershell -' so it won't double-patch existing .exe entries
                if grep -q '"powershell -' "$project_settings" 2>/dev/null; then
                    log_status "WARN" "Project .claude/settings.json has hooks calling bare 'powershell' which is unavailable in WSL"
                    log_status "INFO" "Auto-patching: replacing 'powershell' with 'powershell.exe' in $project_settings"
                    # TAP-643: edit JSON semantically via jq (walk .command
                    # fields only) instead of `sed -i`. The old sed pattern
                    # blindly rewrote any line containing `"powershell -`,
                    # corrupting description strings and leaving the file
                    # half-written on failure.
                    local _settings_tmp _settings_bak
                    _settings_tmp=$(mktemp "${project_settings}.XXXXXX") || {
                        log_status "ERROR" "Cannot create tmp file next to $project_settings"; :
                    }
                    if [[ -n "${_settings_tmp:-}" ]] && \
                       jq 'walk(if type == "object" and has("command") and ((.command | type) == "string") and (.command | test("^powershell\\s"))
                             then .command |= sub("^powershell"; "powershell.exe")
                             else . end)' "$project_settings" > "$_settings_tmp" 2>/dev/null && \
                       [[ -s "$_settings_tmp" ]] && \
                       jq empty "$_settings_tmp" 2>/dev/null; then
                        _settings_bak="${RALPH_DIR:-.ralph}/.upgrade-backups/settings.$(date +%s).json"
                        mkdir -p "$(dirname "$_settings_bak")" 2>/dev/null || true
                        cp -p "$project_settings" "$_settings_bak" 2>/dev/null || true
                        mv -f "$_settings_tmp" "$project_settings"
                        log_status "SUCCESS" "Patched powershell → powershell.exe in project settings (backup: $_settings_bak)"
                    else
                        rm -f "${_settings_tmp:-}"
                        log_status "ERROR" "Failed to safely patch $project_settings — leaving unchanged"
                    fi
                fi
            fi
        fi
    fi
}

# =============================================================================
# LOG ROTATION (Issue #18)
# =============================================================================

# Configuration for log rotation
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"         # Rotate when ralph.log exceeds this size (MB)
LOG_MAX_FILES="${LOG_MAX_FILES:-5}"               # Keep this many rotated log files
LOG_MAX_OUTPUT_FILES="${LOG_MAX_OUTPUT_FILES:-20}" # Keep this many claude_output_*.log files

# Rotate ralph.log when it exceeds LOG_MAX_SIZE_MB
rotate_ralph_log() {
    local log_file="$LOG_DIR/ralph.log"
    [[ -f "$log_file" ]] || return 0

    local file_size_bytes
    # Cross-platform file size detection
    if file_size_bytes=$(stat -c %s "$log_file" 2>/dev/null); then
        : # GNU stat
    elif file_size_bytes=$(stat -f %z "$log_file" 2>/dev/null); then
        : # BSD stat
    else
        return 0  # Can't determine size, skip rotation
    fi

    local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
    if [[ $file_size_bytes -lt $max_bytes ]]; then
        return 0
    fi

    log_status "INFO" "Rotating ralph.log (${file_size_bytes} bytes > ${max_bytes} byte limit)"

    # Shift existing rotated logs: .4 -> .5, .3 -> .4, etc.
    local i=$LOG_MAX_FILES
    while [[ $i -gt 1 ]]; do
        local prev=$((i - 1))
        [[ -f "${log_file}.${prev}" ]] && mv "${log_file}.${prev}" "${log_file}.${i}"
        i=$((i - 1))
    done

    # Move current to .1
    mv "$log_file" "${log_file}.1"

    # Start a fresh log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log rotated (previous log: ralph.log.1)" > "$log_file"
}

# Clean up old claude_output_*.log files, keeping only the most recent LOG_MAX_OUTPUT_FILES
cleanup_old_output_logs() {
    local count
    count=$(find "$LOG_DIR" -maxdepth 1 -name 'claude_output_*.log' 2>/dev/null | wc -l)
    count=$((count + 0))

    if [[ $count -le $LOG_MAX_OUTPUT_FILES ]]; then
        return 0
    fi

    local to_remove=$((count - LOG_MAX_OUTPUT_FILES))
    log_status "INFO" "Cleaning up $to_remove old output log(s) (keeping newest $LOG_MAX_OUTPUT_FILES)"

    # TAP-676: prune oldest by mtime (not lexicographic name). Requires GNU sort/head -z (same as prior pipeline).
    while IFS= read -r -d '' f; do
        [[ -f "$f" ]] || continue
        local m
        m=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
        printf '%s\t%s\0' "$m" "$f"
    done < <(find "$LOG_DIR" -maxdepth 1 -name 'claude_output_*.log' -print0 2>/dev/null) \
        | sort -z -t $'\t' -k1,1n \
        | head -z -n "$to_remove" \
        | cut -z -f2- \
        | xargs -0 rm -f 2>/dev/null
}

# =============================================================================
# DRY-RUN MODE (Issue #19)
# =============================================================================

DRY_RUN="${DRY_RUN:-false}"

# Simulate a Claude Code execution for dry-run mode
dry_run_simulate() {
    local prompt_content="$1"
    local loop_num="$2"

    log_status "INFO" "[DRY-RUN] Would execute Claude Code with:"
    log_status "INFO" "[DRY-RUN]   Command: $CLAUDE_CODE_CMD"
    log_status "INFO" "[DRY-RUN]   Output format: $CLAUDE_OUTPUT_FORMAT"
    log_status "INFO" "[DRY-RUN]   Timeout: ${CLAUDE_TIMEOUT_MINUTES}m"
    log_status "INFO" "[DRY-RUN]   Session continuity: $CLAUDE_USE_CONTINUE"
    if check_agent_support; then
        log_status "INFO" "[DRY-RUN]   Mode: --agent ${RALPH_AGENT_NAME:-ralph} (permissions via .claude/agents/ralph.md)"
    else
        log_status "ERROR" "[DRY-RUN]   Claude CLI does not support --agent. Update to v$CLAUDE_MIN_VERSION or higher: $CLAUDE_CODE_CMD update"
    fi

    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-536: surface API errors but don't fail the dry-run; "?" signals
        # "unknown" so operators can see the count is unreliable.
        local task_count done_count
        task_count=$(linear_get_open_count) || task_count="?"
        done_count=$(linear_get_done_count) || done_count="?"
        log_status "INFO" "[DRY-RUN]   Tasks (Linear/${RALPH_LINEAR_PROJECT}): $task_count open, $done_count done"
    elif [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local task_count
        task_count=$(grep -c '^\- \[ \]' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || task_count=0
        local done_count
        done_count=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || done_count=0
        log_status "INFO" "[DRY-RUN]   Tasks: $task_count open, $done_count done"
    fi

    # Write a simulated status.json
    cat > "$STATUS_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "loop_count": $loop_num,
  "status": "DRY_RUN",
  "exit_signal": "false",
  "tasks_completed": 0,
  "files_modified": 0,
  "work_type": "dry_run",
  "recommendation": "Dry-run mode — no changes made"
}
EOF

    log_status "SUCCESS" "[DRY-RUN] Simulation complete (no API call made)"
    return 0
}

# ralph_task_is_docs_related: return 0 when the next unchecked task/Linear
# issue looks docs-flavored (README, ADR, architecture, changelog, API doc,
# runbook, tutorial, onboarding, or a .md file target). Used to gate docs-mcp
# prompt guidance — injecting it on pure-code loops wastes ~200 tokens each
# iteration. Fail-closed: any error / empty task text returns non-zero so the
# block is omitted (preferred over a false positive steering Claude toward an
# irrelevant tool surface).
ralph_task_is_docs_related() {
    local task_text=""

    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # linear_get_next_task may not be sourced in unit-test harnesses;
        # guard with command -v so the classifier still returns cleanly.
        if command -v linear_get_next_task &>/dev/null; then
            task_text=$(linear_get_next_task 2>/dev/null) || task_text=""
        fi
    elif [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        task_text=$(grep -m1 -E "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || task_text=""
    fi

    [[ -z "$task_text" ]] && return 1

    # Case-insensitive keyword match. Word boundaries (via (^|[^a-z])...) keep
    # "doc" from matching inside "dock" or "docker". ".md" is anchored to avoid
    # matching mid-word ("commander", "somediff.md5").
    shopt -s nocasematch
    local rc=1
    if [[ "$task_text" =~ (^|[^a-z])(docs?|documentation|readme|adr|architecture|changelog|release[[:space:]-]?notes|api[[:space:]-]?docs?|runbook|tutorial|onboarding)([^a-z]|$) ]] \
       || [[ "$task_text" =~ \.md([[:space:]\)\]\.\,\;\:]|$) ]]; then
        rc=0
    fi
    shopt -u nocasematch
    return $rc
}

# TAP-669: Sanitize untrusted text before it reaches --append-system-prompt
# or the prompt body. fix_plan.md titles, Linear issue titles, status.json
# recommendations, and continue-as-new carried state can all contain
# attacker-editable content. Argv passing blocks shell injection, but the
# string still reaches the model as system-level instructions — so we
# defensively strip control chars, cap line length, and neutralize the
# role-tag sequences that prompt-injection attempts rely on.
#
# Reads untrusted text from stdin; writes sanitized text to stdout.
# Idempotent on already-clean input.
ralph_sanitize_prompt_text() {
    local max_line="${1:-300}"
    awk -v max="$max_line" '
        BEGIN { role_rx = "<\\|(system|assistant|user|end_of_turn|im_start|im_end)\\|>" }
        {
            # Strip ASCII control chars except \t (011), \n (012), \r (015)
            gsub(/[\000-\010\013\014\016-\037\177]/, "")
            # Truncate long lines (prompt-injection payloads are typically long)
            if (length($0) > max) $0 = substr($0, 1, max) "…[truncated]"
            # Neutralize explicit role-tag injections
            gsub(role_rx, "[role-marker-stripped]")
            # Neutralize common markdown chat-role prefixes at line start
            sub(/^### (System|Assistant|User|Human):[[:space:]]*/, "### ")
            sub(/^(SYSTEM|ASSISTANT|USER|HUMAN):[[:space:]]+/, "text: ")
            print
        }
    '
}

# Build loop context for Claude Code session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from task source
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-536: On API failure, mark counts as "unknown" instead of "0".
        # Treating a failed lookup as 0 remaining can falsely encourage Claude
        # to emit EXIT_SIGNAL: true.
        local incomplete_tasks _ctx_lvl="WARN" _ctx_stderr=""
        if [[ -z "${LINEAR_API_KEY:-}" ]]; then _ctx_lvl="INFO"; _ctx_stderr="/dev/null"; fi
        if incomplete_tasks=$(linear_get_open_count 2>"${_ctx_stderr:-/dev/stderr}"); then
            context+="Remaining tasks (Linear): ${incomplete_tasks}. "
        else
            log_status "$_ctx_lvl" "Linear count (open_count) unavailable — context will mark counts as unknown" >&2
            # Count is unknown (push-mode iteration 1, or hook hasn't written
            # counts yet). Block FALSE-POSITIVE plan-complete exits — Claude
            # must NOT emit `STATUS: COMPLETE + EXIT_SIGNAL: true` based on a
            # null count, since "unknown" is not "zero". But explicitly ALLOW
            # the genuinely-blocked exit (Grounds 2: STATUS: BLOCKED +
            # EXIT_SIGNAL: true) — assess every visible Linear issue this
            # loop, count blocked:* labeled ones as zero per the prompt's own
            # definition, and emit BLOCKED+true if every open issue is
            # blocked. The previous wording forbade ALL EXIT_SIGNAL when
            # counts were null, which trapped Claude on a fully-blocked queue
            # forever (loop ran 7+ iterations on 2026-04-30 burning ~$0.86).
            context+="Remaining tasks (Linear): unknown (counts not yet reported — do NOT emit STATUS: COMPLETE + EXIT_SIGNAL: true based on the unknown count, but you MAY emit STATUS: BLOCKED + EXIT_SIGNAL: true if every visible open issue is blocked:* labeled — list them via Linear MCP and verify before emitting). "
        fi
        # Check for in-progress (started) tickets from previous loops — these must
        # be retried before picking new backlog work to prevent branch pile-up.
        local in_progress_task
        in_progress_task=$(linear_get_in_progress_task 2>/dev/null) || in_progress_task=""
        # TAP-669: Linear titles are user-editable — sanitize before injecting
        # into the model's system prompt.
        if [[ -n "$in_progress_task" ]]; then
            in_progress_task=$(printf '%s' "$in_progress_task" | ralph_sanitize_prompt_text 300)
            context+="RESUME IN PROGRESS (do this FIRST): ${in_progress_task}. "
        fi
        # TAP-593 (LINOPT-4): Inject cache-locality optimizer hint when available.
        # linear_optimizer_run() wrote this at session start (TAP-591). Read the
        # first non-comment line as the issue identifier; strip to alphanumeric
        # and dash only to prevent prompt injection.
        if [[ -f "${RALPH_DIR}/.linear_next_issue" ]]; then
            local _opt_hint
            _opt_hint=$(grep -v '^#' "${RALPH_DIR}/.linear_next_issue" 2>/dev/null \
                | head -1 | tr -cd 'A-Z0-9a-z-')
            if [[ -n "$_opt_hint" ]]; then
                context+="LOCALITY HINT: ${_opt_hint} is cache-hot (its files overlap the last-completed loop). If ${_opt_hint} is Backlog/Todo/In-Progress, prefer it over normal priority selection; then run: rm -f .ralph/.linear_next_issue (so the stale hint does not re-apply). If the issue is Done/Cancelled or the hint seems wrong, ignore it and use normal priority. "
            fi
        fi
        # Inject Linear task source instructions for Claude
        local next_task
        next_task=$(linear_get_next_task) || next_task=""
        context+="TASK SOURCE: Linear project '${RALPH_LINEAR_PROJECT}'. "
        if [[ -n "$next_task" ]]; then
            next_task=$(printf '%s' "$next_task" | ralph_sanitize_prompt_text 300)
            context+="Next issue: ${next_task}. "
        fi
        # Per-task model routing input (lib/complexity.sh).
        # Prefer in-progress > next ticket; in OAuth-via-MCP mode (no
        # LINEAR_API_KEY), both are empty by design — `linear_get_*` early-
        # returns 1 without an API key. Fall back to the previous loop's
        # status.json (linear_issue + recommendation) so the classifier sees
        # task-shaped text instead of routing no_task_fallback every iteration.
        RALPH_CURRENT_TASK_TEXT="${in_progress_task:-$next_task}"
        if [[ -z "$RALPH_CURRENT_TASK_TEXT" && -f "$RALPH_DIR/status.json" ]]; then
            local _prev_task
            _prev_task=$(jq -r '
                [(.linear_issue // ""), (.recommendation // "")]
                | map(select(. != ""))
                | join(": ")
                | .[0:300]
            ' "$RALPH_DIR/status.json" 2>/dev/null) || _prev_task=""
            if [[ -n "$_prev_task" ]]; then
                RALPH_CURRENT_TASK_TEXT=$(printf '%s' "$_prev_task" | ralph_sanitize_prompt_text 300)
            fi
        fi
        context+="If 'RESUME IN PROGRESS' is shown above, work that ticket FIRST before starting any new issue — run \`git log main --grep='<TICKET-ID>'\` to check if commits exist; if the work is on an unmerged branch, merge it now (\`gh pr merge --squash --auto\` or \`git merge\`). Only start a new ticket after the in-progress one reaches Done or is confirmed blocked by a genuine R2 hard blocker. Use Linear MCP tools to list open issues, work on the highest priority one, and mark it Done as soon as the code is shipped — even if acceptance criteria are cosmetically misaligned (e.g. AC says '14 tools' and tests assert 15). 'Shipped' means commits are on \`main\`. Before Done, run \`git log main --grep='<TICKET-ID>'\` and confirm at least one matching commit exists. If work is only on a branch, attempt to self-merge (\`gh pr merge --squash --auto\` or \`git merge\`); if the merge is blocked (no permission, required checks pending, conflicts you cannot resolve this loop), post a Linear comment listing unmerged SHAs and leave the ticket **In Progress** so Ralph retries next loop — do NOT move it to In Review for this. RALPH IS HEADLESS: there is no human on standby to review, merge, or answer questions. There is no human reviewer. 'In Review' is reserved for HARD blockers only — the EXACT four: (1) missing credentials/API keys a human must generate (e.g. OAuth token requiring browser click-through), (2) explicit budget/spend cap reached, (3) irreversible destructive operation requiring human sign-off: production database migration dropping data, secret rotation, mass deletion, credential exfiltration risk — NOT security bug fixes or hardening (those are Done), (4) genuinely ambiguous product decision where both interpretations have real cost and neither is a safe default. When in doubt between Done and In Review: pick Done if AC is substantively met, In Progress if it is not. NEVER pick In Review out of uncertainty. Everything else is NOT In Review: unmerged branch → In Progress + retry; flaky tests / red build / lint failures → fix them; 'code probably works but I'm unsure' → Done if AC substantively met; 'needs code review' → Done (no reviewer exists); security bug fix or hardening → Done; 'couldn't figure out how to do X' → leave In Progress, Ralph retries with fresh context next loop. When you do use In Review, the last Linear comment MUST name one of the four exact reasons above verbatim — if you cannot, pick Done or In Progress instead. Do NOT read or modify fix_plan.md. Set EXIT_SIGNAL: true when no open issues remain. REQUIRED: include LINEAR_OPEN_COUNT: <N>, LINEAR_DONE_COUNT: <N>, and LINEAR_ISSUE: <ID-or-NONE> (the issue you worked this loop, e.g. TAP-915, or NONE if no issue was touched) in your RALPH_STATUS block. If you worked under an epic, also include LINEAR_EPIC: <ID>, LINEAR_EPIC_DONE: <N>, LINEAR_EPIC_TOTAL: <N>. Counts come from Linear MCP — the harness reads these to populate the live monitor."
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    elif [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks
        incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "
        # Per-task model routing input (lib/complexity.sh): first unchecked
        # task line, stripped of leading checkbox + whitespace, capped to 300
        # chars to keep classifier regex cheap.
        local _next_unchecked
        _next_unchecked=$(grep -m1 -E "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null \
            | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//' | head -c 300)
        RALPH_CURRENT_TASK_TEXT="$_next_unchecked"
    fi

    # PERF: Read circuit breaker state and previous summary in single jq call (was: 2 separate jq spawns)
    # TAP-669: sanitize prev_summary — it's a pass-through of Claude's own
    # recommendation from the prior loop, so in theory safe, but Claude's
    # output has no hard role-tag guarantee and status.json can be edited
    # externally between loops. Defense in depth.
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" && -f "$RALPH_DIR/status.json" ]]; then
        local cb_state prev_summary
        cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
        prev_summary=$(jq -r '.recommendation // "" | .[0:200]' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            prev_summary=$(printf '%s' "$prev_summary" | ralph_sanitize_prompt_text 250)
            context+="Previous: ${prev_summary} "
        fi
    elif [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    elif [[ -f "$RALPH_DIR/status.json" ]]; then
        local prev_summary
        prev_summary=$(jq -r '.recommendation // "" | .[0:200]' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            prev_summary=$(printf '%s' "$prev_summary" | ralph_sanitize_prompt_text 250)
            context+="Previous: ${prev_summary} "
        fi
    fi

    # USYNC-2: If previous loop detected questions, inject corrective guidance (upstream #190)
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        local prev_asking_questions
        prev_asking_questions=$(jq -r '.asking_questions // false' "$RALPH_DIR/status.json" 2>/dev/null || echo "false")
        if [[ "$prev_asking_questions" == "true" ]]; then
            context+="IMPORTANT: You asked questions in the previous loop. This is a headless automation loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe default and proceed autonomously. "
            log_status "INFO" "Injecting question-corrective guidance (previous loop asked questions)"
        fi
    fi

    # TAP-1683 (USYNC-2): hardened escalation + advance directive. These
    # are the highest-priority context for the loop, so they get PREPENDED
    # to `$context` rather than appended — the function ends with a hard
    # 1500-char truncation, and getting buried below the Linear-mode
    # boilerplate would silently drop them. The on-stop hook owns the
    # counter file and the .linear_advance_action marker; we only read.
    local _ql_count_file="$RALPH_DIR/.consecutive_questions"
    local _ql_threshold="${RALPH_QUESTION_LOOP_THRESHOLD:-2}"
    local _ql_prefix=""
    if [[ -f "$_ql_count_file" ]]; then
        local _ql_n
        read -r _ql_n < "$_ql_count_file" 2>/dev/null || _ql_n=0
        _ql_n=$(printf '%s' "$_ql_n" | tr -cd '0-9')
        _ql_n=${_ql_n:-0}
        if [[ "$_ql_n" -ge "$_ql_threshold" ]]; then
            _ql_prefix+="ESCALATION (USYNC-2): the previous ${_ql_n} consecutive loops ended with questions and no action. Stop asking. Pick the safest defensible default for every open question this loop, IMPLEMENT it, and DOCUMENT each assumption in your commit message and (in linear mode) as a Linear comment on the issue. If the question is a genuine R2 hard blocker (missing credentials, budget cap, irreversible destructive op, or a product decision where both options have real cost and neither is safe), state which of the four it is and emit STATUS: BLOCKED with EXIT_SIGNAL: false. \"I'm not sure\" is NOT a hard blocker. "
            log_status "INFO" "USYNC-2 escalation injected (consecutive_questions=$_ql_n threshold=$_ql_threshold)"
        fi
    fi
    local _ql_advance_file="$RALPH_DIR/.linear_advance_action"
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" && -f "$_ql_advance_file" ]]; then
        local _ql_adv_id _ql_adv_label
        _ql_adv_id=$(sed -n '1p' "$_ql_advance_file" 2>/dev/null | tr -cd 'A-Za-z0-9-')
        _ql_adv_label=$(sed -n '2p' "$_ql_advance_file" 2>/dev/null | tr -cd 'A-Za-z0-9:-')
        [[ -z "$_ql_adv_label" ]] && _ql_adv_label="blocked:waiting-for-answer"
        if [[ -n "$_ql_adv_id" ]]; then
            _ql_prefix+="URGENT (USYNC-2 advance): ${_ql_adv_id} has stalled on ${_ql_threshold}+ consecutive question loops. THIS LOOP: (1) add the label '${_ql_adv_label}' to ${_ql_adv_id} via mcp__plugin_linear_linear__save_issue, (2) post a Linear comment on ${_ql_adv_id} listing the unresolved questions, (3) delete .ralph/.linear_advance_action so it does not re-apply, (4) pick a DIFFERENT open issue (not ${_ql_adv_id}) and work that one. "
            log_status "WARN" "USYNC-2 advance directive injected for $_ql_adv_id (label=$_ql_adv_label)"
        else
            # Marker present but unparseable — clean up so we don't loop.
            rm -f "$_ql_advance_file" 2>/dev/null || true
        fi
    fi
    if [[ -n "$_ql_prefix" ]]; then
        context="${_ql_prefix}${context}"
    fi

    # CTXMGMT-3: Inject carried state from Continue-As-New reset
    # TAP-669: continue-state values (current_task, recommendation) originate
    # from Claude output or Linear — same untrusted surface as prev_summary.
    if [[ -f "$RALPH_CONTINUE_STATE_FILE" ]]; then
        local continued_context
        continued_context=$(ralph_inject_continue_state)
        if [[ -n "$continued_context" ]]; then
            continued_context=$(printf '%s' "$continued_context" | ralph_sanitize_prompt_text 400)
            context+="$continued_context "
        fi
    fi

    # TAP-585 (epic TAP-583): Inject MCP "when to use" guidance, gated on the
    # capability flags set by ralph_probe_mcp_servers() at startup. Without
    # explicit guidance Claude defaults to Read/Grep/Bash for things the MCP
    # servers do better/cheaper.
    #
    # docs-mcp: gated on the current task looking docs-related (keywords in
    # the next unchecked task / Linear issue). Code-only loops skip the block
    # to save ~200 prompt tokens per iteration. Fail-closed classifier.
    # tapps-mcp: injected unconditionally when reachable — the recommended
    # tools (quality_gate, lookup_docs, score_file) apply to virtually any
    # code-modifying loop, so gating would be a false economy.
    if [[ "${RALPH_MCP_DOCS_AVAILABLE:-false}" == "true" ]] && ralph_task_is_docs_related; then
        context+="docs-mcp available: prefer mcp__docs-mcp__* (docs_generate_adr/changelog/architecture, docs_check_links/drift/freshness, docs_module_map) for docs/ADR/changelog/README/API tasks instead of hand-writing. "
    fi
    # tapps-mcp: code quality tools (quality_gate, score_file, impact_analysis,
    # lookup_docs). Injected unconditionally when reachable — lookup_docs applies
    # to docs work too, and gating by task-type was a false economy that masked
    # the guidance on mixed docs/code loops.
    if [[ "${RALPH_MCP_TAPPS_AVAILABLE:-false}" == "true" ]]; then
        context+="tapps-mcp available: use mcp__tapps-mcp__tapps_quality_gate before declaring work complete, tapps_lookup_docs before calling external library APIs, tapps_score_file on modified Python files, tapps_impact_analysis before non-trivial refactors. "
    fi
    # tapps-brain: cross-session memory / learning. Projects register this MCP
    # via their own `.mcp.json` (dockerized HTTP server). When reachable,
    # steer Claude toward brain_recall at task start and the learn_*/remember
    # tools at epic boundaries so loops compound knowledge instead of starting
    # cold. Unconditional when the probe succeeds — recall-at-start applies
    # broadly and costs less than re-deriving context from scratch.
    if [[ "${RALPH_MCP_BRAIN_AVAILABLE:-false}" == "true" ]]; then
        context+="tapps-brain available: call mcp__tapps-brain__brain_recall at task start to surface prior learnings, brain_remember when a fix was non-obvious and worth preserving, and brain_learn_success / brain_learn_failure at epic boundaries to feed the quality loop. "
    elif [[ "${RALPH_MCP_BRAIN_AUTH_FAILED:-false}" == "true" ]]; then
        # TAP-1530: explicit negative — without this, Claude on a brain-aware
        # project may attempt brain_recall, hit auth error, and ask the user
        # to fix it instead of doing the task.
        context+="tapps-brain UNAVAILABLE (auth failed): do NOT call mcp__tapps-brain__* — proceed without cross-session memory, work from PROMPT.md / Linear context only. "
    fi

    # TAP-915: When the coordinator wrote a brief at the top of this loop,
    # nudge the main agent to read it. Validation already happened in
    # ralph_spawn_coordinator — a present file here is a valid brief.
    if [[ -s "$RALPH_DIR/brief.json" ]]; then
        context+=".ralph/brief.json available — read it at task start for prior learnings, risk level, and affected modules. "
        # TAP-922: when the brief marks this task HIGH-risk, inject the
        # COORDINATOR_RPC_PATH so ralph can run the consult gate before
        # starting implementation (see ralph.md "Coordinator Consultation").
        local _brief_risk
        _brief_risk=$(jq -r '.risk_level // empty' "$RALPH_DIR/brief.json" 2>/dev/null) || _brief_risk=""
        if [[ "$_brief_risk" == "HIGH" ]]; then
            local _rpc_path="${SCRIPT_DIR}/lib/coordinator_rpc.sh"
            context+="Risk level is HIGH — coordinator consultation required before implementation. COORDINATOR_RPC_PATH=${_rpc_path} "
            # TAP-1686: HIGH-risk → flip permission mode to plan for THIS
            # loop only. `build_claude_command` reads RALPH_PERMISSION_MODE
            # and appends `--permission-mode plan` to the CLI, overriding
            # the agent file's bypassPermissions default. Plan Mode forces
            # Claude to describe its changes before mutating files; the
            # next loop applies the plan (or rejects it after review).
            # Honors a pre-existing operator override — if someone has
            # already pinned RALPH_PERMISSION_MODE (e.g. during incident
            # response), don't second-guess them.
            if [[ -z "${RALPH_PERMISSION_MODE:-}" ]]; then
                export RALPH_PERMISSION_MODE="plan"
                context+="PLAN MODE ACTIVE (TAP-1686): emit a numbered plan first; do NOT write files this loop. Post the plan as a Linear comment so the next loop has it. Set WORK_TYPE: PLANNING and FILES_MODIFIED: 0 in your RALPH_STATUS block — the harness recognizes Plan Mode loops as productive even with zero files modified. "
                log_status "INFO" "TAP-1686: HIGH-risk brief → RALPH_PERMISSION_MODE=plan for loop"
            fi
        fi
    fi

    # Limit total length to ~1500 chars (raised from 800→1200→1500 as MCP
    # blocks were added — docs-mcp + tapps-mcp + tapps-brain run ~770 chars
    # combined, and that is before any loop-state / previous-summary prefix).
    # Truncation was silently dropping MCP guidance at the old caps.
    echo "${context:0:1500}"
}

# TAP-915: ralph_spawn_coordinator — invoke ralph-coordinator (Haiku) at
# the top of each loop to populate .ralph/brief.json with prior learnings,
# affected modules, and risk level. Stateless per loop; best-effort.
# Coordinator failure NEVER blocks the main agent — we log and continue.
#
# Honors RALPH_COORDINATOR_DISABLED=true (opt-out), DRY_RUN (skip), and
# CLAUDE_CODE_CMD missing (skip). Timeout 60s — coordinator is Haiku; longer
# hangs likely mean a real outage we should not wait on.
#
# Test seam: _coordinator_invoke_claude is split out so tests can override
# it without a real Claude CLI. Same pattern as _optimizer_invoke_explorer
# in lib/linear_optimizer.sh.
_coordinator_invoke_claude() {
    local input="$1"
    # TAP-921: when $2 is set to "fresh", suppress the resume-or-spawn
    # branch even if a session file exists — used by callers that need
    # a clean session (currently none, reserved for future debug paths).
    local force_fresh="${2:-}"
    local claude_cmd="${CLAUDE_CODE_CMD:-claude}"
    # TAP-1682: adaptive coordinator timeout. ralph_compute_coordinator_timeout
    # honors RALPH_COORDINATOR_TIMEOUT_SECONDS as a hard override; without
    # that, P95×2 of the last 30 wall-clock samples (clamped [30,600]) sizes
    # the budget to actual coordinator latency. Falls back to 120s when
    # samples are sparse.
    local _coord_timeout
    if declare -F ralph_compute_coordinator_timeout >/dev/null 2>&1; then
        _coord_timeout=$(ralph_compute_coordinator_timeout)
    else
        _coord_timeout="${RALPH_COORDINATOR_TIMEOUT_SECONDS:-120}"
    fi

    # TAP-921: resume-or-spawn — if a fresh persisted session_id exists,
    # pass `--resume <sid>` so the coordinator's accumulated context (prior
    # learnings, brief decisions, brain_recall results) persists across
    # loops. coordinator_session_read already filters out stale files.
    local _continue_args=()
    if [[ "$force_fresh" != "fresh" ]] && declare -F coordinator_session_read >/dev/null 2>&1; then
        local _sid
        _sid=$(coordinator_session_read 2>/dev/null)
        if [[ -n "$_sid" ]]; then
            _continue_args=(--resume "$_sid")
            log_status "DEBUG" "coordinator: resuming session ${_sid:0:8}…"
        fi
    fi

    # TAP-920: capture stdout to an internal temp file so we can extract
    # the session_id from the JSONL stream — both on first spawn (to
    # persist it) and on resume (to confirm it stayed stable). Tolerate
    # mktemp failure: fall back to /dev/null and skip the capture.
    local _stream_file
    _stream_file=$(mktemp -t "coord_stream.XXXXXX" 2>/dev/null || echo "")
    local _stdout_target="${_stream_file:-/dev/null}"
    local _fmt_args=()
    if [[ -n "$_stream_file" ]]; then
        _fmt_args=(--output-format stream-json --verbose)
    fi

    # TAP-1530: mark this child claude process as a coordinator invocation so
    # the project's on-stop hook skips RALPH_STATUS accounting for it. Without
    # this, every coordinator brief/debrief response (which has no
    # RALPH_STATUS block by design) increments .no_status_block_count and
    # trips the no_status_block_3x halt detector after 1–2 loops.
    # TAP-1682: record coordinator wall-clock so ralph_compute_coordinator_timeout
    # can adapt P95×2. Recorded regardless of success / failure / timeout so
    # the distribution reflects real ops (slow MCP cold starts and all).
    local _coord_start_ts _coord_end_ts _coord_duration
    _coord_start_ts=$(date -u +%s)
    if [[ "$_coord_timeout" == "0" ]]; then
        RALPH_COORDINATOR_INVOCATION=1 "$claude_cmd" \
            --agent ralph-coordinator \
            --permission-mode bypassPermissions \
            "${_continue_args[@]}" \
            "${_fmt_args[@]}" \
            -p "$input" \
            >"$_stdout_target" 2>&1
    else
        RALPH_COORDINATOR_INVOCATION=1 timeout "$_coord_timeout" "$claude_cmd" \
            --agent ralph-coordinator \
            --permission-mode bypassPermissions \
            "${_continue_args[@]}" \
            "${_fmt_args[@]}" \
            -p "$input" \
            >"$_stdout_target" 2>&1
    fi
    local _rc=$?
    _coord_end_ts=$(date -u +%s)
    _coord_duration=$(( _coord_end_ts - _coord_start_ts ))
    if declare -F ralph_record_coordinator_timing >/dev/null 2>&1; then
        ralph_record_coordinator_timing "$_coord_duration" "$_rc"
    fi

    # Always try to extract session_id, even on timeout/failure — partial
    # output usually still carries the system/init line with the session_id.
    if [[ -n "$_stream_file" && -s "$_stream_file" ]] \
       && declare -F coordinator_session_extract_from_stream >/dev/null 2>&1; then
        local _new_sid
        _new_sid=$(coordinator_session_extract_from_stream "$_stream_file" 2>/dev/null)
        if [[ -n "$_new_sid" ]]; then
            coordinator_session_write "$_new_sid" 2>/dev/null && \
                log_status "DEBUG" "coordinator: session captured (${_new_sid:0:8}…)"
        fi
    fi
    [[ -n "$_stream_file" ]] && rm -f -- "$_stream_file" 2>/dev/null
    return $_rc
}

# TAP-921: ralph_coordinator_invoke — public, mode-aware entry point that
# wraps `_coordinator_invoke_claude` with a MODE= header and the standard
# disabled / DRY_RUN / missing-CLI guards. Honors resume-or-spawn via the
# session_id captured at TAP-920. Use this from code paths that need
# direct access to the coordinator (story 2.3 mid-task consult). The
# brief- and debrief-mode wrappers (`ralph_spawn_coordinator`,
# `ralph_debrief_coordinator`) delegate here for the actual invocation.
#
# Args:
#   $1 — mode: brief | debrief | consult
#   $2 — body: free-form prompt (MODE= line is added automatically)
ralph_coordinator_invoke() {
    local mode="${1:?mode required: brief|debrief|consult}"
    local body="${2:-}"

    if [[ "${RALPH_COORDINATOR_DISABLED:-false}" == "true" ]]; then
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    local claude_cmd="${CLAUDE_CODE_CMD:-claude}"
    if ! command -v "$claude_cmd" >/dev/null 2>&1; then
        return 0
    fi

    local input="MODE=${mode}
${body}"
    _coordinator_invoke_claude "$input"
}

ralph_spawn_coordinator() {
    local loop_count="${1:-0}"
    local brief_target
    brief_target=$(brief_path)

    if [[ "${RALPH_COORDINATOR_DISABLED:-false}" == "true" ]]; then
        log_status "INFO" "coordinator: disabled via RALPH_COORDINATOR_DISABLED"
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    local claude_cmd="${CLAUDE_CODE_CMD:-claude}"
    if ! command -v "$claude_cmd" >/dev/null 2>&1; then
        log_status "WARN" "coordinator: claude CLI not on PATH — continuing without brief"
        return 0
    fi

    # Build task input from current source. linear_get_next_task is
    # tolerated to fail silently — the coordinator can still work with an
    # empty TASK_INPUT (it'll write a brief flagged with low confidence).
    local task_source="${RALPH_TASK_SOURCE:-file}"
    local task_input=""
    if [[ "$task_source" == "linear" ]]; then
        if declare -F linear_get_next_task >/dev/null 2>&1; then
            task_input=$(linear_get_next_task 2>/dev/null) || task_input=""
        fi
    else
        task_input=$(grep -m1 '^[[:space:]]*- \[ \]' "${RALPH_DIR}/fix_plan.md" 2>/dev/null) || task_input=""
    fi

    # TAP-1682: cache lookup BEFORE clearing the prior brief. The cache key
    # is the Linear issue identifier — read from status.json (.linear_issue
    # is written by the on-stop hook from Claude's RALPH_STATUS block) or
    # the locality-optimizer hint file. File-mode loops have no per-issue
    # identity, so caching is linear-mode-only by design.
    local _cache_issue_id=""
    if [[ "$task_source" == "linear" ]]; then
        if [[ -f "${RALPH_DIR}/status.json" ]]; then
            _cache_issue_id=$(jq -r '.linear_issue // empty' "${RALPH_DIR}/status.json" 2>/dev/null || echo "")
        fi
        if [[ -z "$_cache_issue_id" && -f "${RALPH_DIR}/.linear_next_issue" ]]; then
            _cache_issue_id=$(head -1 "${RALPH_DIR}/.linear_next_issue" 2>/dev/null | tr -d '[:space:]')
        fi
        if [[ -n "$_cache_issue_id" ]] && declare -F exec_load_cached_brief >/dev/null 2>&1; then
            if exec_load_cached_brief "$_cache_issue_id"; then
                # Hit: brief.json was already overwritten by the helper.
                local _risk
                _risk=$(brief_read_field risk_level 2>/dev/null) || _risk="unknown"
                log_status "INFO" "coordinator: using cached brief for $_cache_issue_id (risk=${_risk}) — skipping spawn"
                return 0
            fi
        fi
    fi

    # Drop any stale brief from a previous loop so a coordinator failure
    # leaves the consumer reading "no brief" rather than yesterday's
    # recommendation.
    brief_clear

    # TAP-921: brief body — MODE= header added by ralph_coordinator_invoke,
    # session capture + resume-or-spawn handled by _coordinator_invoke_claude.
    local coord_body
    coord_body="TASK_SOURCE=${task_source}
LOOP=${loop_count}
TASK_INPUT: ${task_input}

Write ${brief_target} per the schema in lib/brief.sh, then return a one-line summary."

    ralph_coordinator_invoke brief "$coord_body"
    local _coord_rc=$?
    if [[ $_coord_rc -ne 0 ]]; then
        # Distinguish timeout (124) from other spawn failures so the operator
        # can tell whether to raise RALPH_COORDINATOR_TIMEOUT_SECONDS or
        # debug a CLI/agent-config issue.
        if [[ $_coord_rc -eq 124 ]]; then
            local _tmo
            _tmo=$(ralph_compute_coordinator_timeout 2>/dev/null || echo "120")
            log_status "WARN" "coordinator: timed out after ${_tmo}s — continuing without brief (set RALPH_COORDINATOR_TIMEOUT_SECONDS to pin a value, or RALPH_COORDINATOR_DISABLED=true to turn it off)"
            # TAP-1682: graceful degradation — even a stale cached brief
            # beats no brief at all. Use a much higher max-age (24h) so a
            # cold-start outage still gets routing+prior-learnings context.
            if [[ -n "$_cache_issue_id" ]] && declare -F exec_load_cached_brief >/dev/null 2>&1; then
                if exec_load_cached_brief "$_cache_issue_id" "" 86400; then
                    log_status "WARN" "coordinator: falling back to stale cached brief for $_cache_issue_id"
                fi
            fi
        else
            log_status "WARN" "coordinator: spawn failed (exit $_coord_rc) — continuing without brief"
        fi
        return 0
    fi

    if [[ -s "$brief_target" ]] && brief_validate "$brief_target" 2>/dev/null; then
        local _risk
        _risk=$(brief_read_field risk_level 2>/dev/null) || _risk="unknown"
        log_status "INFO" "coordinator: brief written (risk=${_risk})"
        # TAP-1682: populate cache so subsequent loops for the same issue
        # skip the spawn entirely. issue_updated_at is read from brief.json
        # when the coordinator surfaced it (best-effort); empty otherwise.
        if [[ -n "$_cache_issue_id" ]] && declare -F exec_save_brief_cache >/dev/null 2>&1; then
            local _brief_updated_at=""
            _brief_updated_at=$(brief_read_field linear_issue_updated_at 2>/dev/null) || _brief_updated_at=""
            exec_save_brief_cache "$_cache_issue_id" "$_brief_updated_at" || true
        fi
    else
        log_status "WARN" "coordinator: brief missing or invalid — clearing"
        rm -f "$brief_target" 2>/dev/null || true
    fi
}

# TAP-917: ralph_debrief_coordinator — invoke ralph-coordinator (Haiku) at
# epic boundary / post-iteration to record outcomes via brain_learn_*.
# Stateless, best-effort. Failure NEVER blocks the loop. Honors the same
# disable / DRY_RUN / missing-CLI guards as the brief spawn.
#
# Args:
#   $1 — outcome: "success" or "failure" (default: "success")
#   $2 — outcome_detail: short text (e.g. error reason); may be empty
ralph_debrief_coordinator() {
    local outcome="${1:-success}"
    local detail="${2:-}"

    # TAP-921: delegate to ralph_coordinator_invoke so debrief also
    # benefits from resume-or-spawn (debrief on the same session that
    # wrote the brief = continuity for brain_learn tagging).
    local body
    body="OUTCOME=${outcome}
OUTCOME_DETAIL: ${detail}

Read .ralph/brief.json (if present), call brain_learn_success or brain_learn_failure with task_id and a short summary, then call brief_clear by deleting the brief file."

    ralph_coordinator_invoke debrief "$body"
    local _rc=$?
    if [[ $_rc -ne 0 ]]; then
        log_status "WARN" "coordinator: debrief failed (exit $_rc) — continuing"
        return 0
    fi
    log_status "INFO" "coordinator: debrief recorded (outcome=${outcome})"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    # Get file modification time using capability detection
    # Handles macOS with Homebrew coreutils where stat flags differ
    local file_mtime

    # Try GNU stat first (Linux, macOS with Homebrew coreutils)
    if file_mtime=$(stat -c %Y "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Try BSD stat (native macOS)
    elif file_mtime=$(stat -f %m "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Fallback to date -r (most portable)
    elif file_mtime=$(date -r "$file" +%s 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    else
        file_mtime=""
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Claude session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CLAUDE_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Claude starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_claude_session() {
    if [[ -f "$CLAUDE_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CLAUDE_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            ralph_clear_all_sessions
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CLAUDE_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CLAUDE_SESSION_EXPIRY_HOURS}h), starting new session"
            ralph_clear_all_sessions
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        # Issue #123: Support both JSON format (new) and plain text (legacy) for backward compat
        local session_id
        session_id=$(jq -r '.session_id // empty' "$CLAUDE_SESSION_FILE" 2>/dev/null)
        if [[ -z "$session_id" ]]; then
            # Fallback: plain text format (pre-#123 files)
            session_id=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
        fi
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            log_status "INFO" "Resuming Claude session: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Claude session"
    echo ""
}

# Save session ID after successful execution
save_claude_session() {
    local output_file=$1

    # Guard: never persist a session from a response where is_error is true (Issue #134, #199)
    if [[ -f "$output_file" ]]; then
        local is_error
        is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
        if [[ "$is_error" == "true" ]]; then
            log_status "WARN" "Skipping session save — response has is_error:true"
            return 0
        fi
    fi

    # Try to extract session ID from JSON output
    # Issue #123: Use JSON format consistent with store_session_id()
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            jq -n \
                --arg session_id "$session_id" \
                --arg timestamp "$(get_iso_timestamp)" \
                '{ session_id: $session_id, timestamp: $timestamp }' > "$CLAUDE_SESSION_FILE"
            log_status "INFO" "Saved Claude session: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # TAP-924: Clear main session + coordinator session + brief together so
    # the coordinator never resumes onto a stale brief written for a different
    # task / pre-reset state. ralph_clear_all_sessions handles all three.
    ralph_clear_all_sessions

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Log the session transition
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    log_status "INFO" "Session reset: $reason"
}

# =============================================================================
# CTXMGMT-3: Continue-As-New — Temporal pattern for long session context reset
# After N iterations or M minutes, reset context carrying only essential state.
# Research: agent success rate drops after ~35 min; doubling duration 4x failure rate.
# =============================================================================

# ralph_should_continue_as_new - Check if session should be reset for context freshness
#
# Returns:
#   0 - Session should be reset (exceeded iteration or age threshold)
#   1 - Session is within limits
#
ralph_should_continue_as_new() {
    if [[ "$RALPH_CONTINUE_AS_NEW_ENABLED" != "true" ]]; then
        return 1
    fi

    # Check iteration count
    if [[ "$_session_iteration_count" -ge "$RALPH_MAX_SESSION_ITERATIONS" ]]; then
        log_status "INFO" "Continue-As-New: session reached $_session_iteration_count iterations (max: $RALPH_MAX_SESSION_ITERATIONS)"
        return 0
    fi

    # Check session age
    if [[ -n "$_session_start_epoch" ]]; then
        local now age_minutes
        now=$(date +%s)
        age_minutes=$(( (now - _session_start_epoch) / 60 ))
        if [[ "$age_minutes" -ge "$RALPH_MAX_SESSION_AGE_MINUTES" ]]; then
            log_status "INFO" "Continue-As-New: session age ${age_minutes}m exceeds ${RALPH_MAX_SESSION_AGE_MINUTES}m"
            return 0
        fi
    fi

    return 1
}

# ralph_continue_as_new - Save essential state and reset session
#
# Saves current task, progress summary, and key findings to a state file,
# then resets the session. The next iteration starts fresh with state
# injected via on-session-start.sh.
#
ralph_continue_as_new() {
    local current_task="" progress="" recommendation=""

    # Extract current task from task source
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-536: API errors leave current_task empty; structured error from
        # the backend is already on stderr.
        current_task=$(linear_get_next_task) || current_task=""
    elif [[ -f "$FIX_PLAN_FILE" ]]; then
        current_task=$(grep -m1 '^\s*-\s*\[\s*\]' "$FIX_PLAN_FILE" 2>/dev/null | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//' || echo "")
    fi

    # Extract progress from status.json
    if [[ -f "$STATUS_FILE" ]]; then
        progress=$(jq -r '"\(.tasks_completed // 0) tasks done, \(.files_modified // 0) files modified"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
        recommendation=$(jq -r '.recommendation // ""' "$STATUS_FILE" 2>/dev/null || echo "")
    fi

    # Count completed vs remaining tasks
    local completed_tasks=0 remaining_tasks=0
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-536: snapshot path — defaults to 0 on API error. Structured error
        # from the backend lands on stderr.
        remaining_tasks=$(linear_get_open_count) || remaining_tasks=0
        completed_tasks=$(linear_get_done_count) || completed_tasks=0
    elif [[ -f "$FIX_PLAN_FILE" ]]; then
        completed_tasks=$(grep -cE '^\s*-\s*\[x\]' "$FIX_PLAN_FILE" 2>/dev/null) || completed_tasks=0
        remaining_tasks=$(grep -cE '^\s*-\s*\[\s*\]' "$FIX_PLAN_FILE" 2>/dev/null) || remaining_tasks=0
    fi

    # Save essential state
    jq -n \
        --arg task "$current_task" \
        --arg progress "$progress" \
        --arg recommendation "$recommendation" \
        --argjson loop "$loop_count" \
        --argjson session_iterations "$_session_iteration_count" \
        --argjson completed "$completed_tasks" \
        --argjson remaining "$remaining_tasks" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            current_task: $task,
            progress: $progress,
            recommendation: $recommendation,
            continued_from_loop: $loop,
            session_iterations: $session_iterations,
            completed_tasks: $completed,
            remaining_tasks: $remaining,
            saved_at: $timestamp
        }' > "$RALPH_CONTINUE_STATE_FILE"

    log_status "INFO" "Continue-As-New: saved state (loop #$loop_count, $completed_tasks done, $remaining_tasks remaining)"

    # Reset session (clears session ID, exit signals)
    reset_session "continue_as_new"

    # Reset session-local counters
    _session_iteration_count=0
    _session_start_epoch=$(date +%s)

    log_status "SUCCESS" "Continue-As-New: session reset, next iteration starts fresh with carried state"
}

# ralph_inject_continue_state - Inject carried state into session context
#
# Called by on-session-start.sh or build_loop_context to provide prior context.
#
# Outputs:
#   Text block describing the carried-over state (empty if no state file)
#
ralph_inject_continue_state() {
    if [[ ! -f "$RALPH_CONTINUE_STATE_FILE" ]]; then
        return 0
    fi

    local state_json
    state_json=$(<"$RALPH_CONTINUE_STATE_FILE")

    echo "## Continued Session"
    echo "This session continues from a previous session that was reset for context freshness."
    echo ""
    echo "Previous session context:"
    echo "- Current task: $(echo "$state_json" | jq -r '.current_task // "none"')"
    echo "- Progress: $(echo "$state_json" | jq -r '.progress // "unknown"')"
    echo "- Completed tasks: $(echo "$state_json" | jq -r '.completed_tasks // 0') done, $(echo "$state_json" | jq -r '.remaining_tasks // 0') remaining"
    echo "- Recommendation: $(echo "$state_json" | jq -r '.recommendation // "continue with next task"')"
    echo ""

    # Clean up after injection
    rm -f "$RALPH_CONTINUE_STATE_FILE"
}

# =============================================================================
# CBDECAY-2: Session State Reinitialization After CB Reset (Phase 13)
# Validates session file has a valid session_id. If empty (after CB trip),
# reinitializes with timestamps so the next Claude invocation populates it.
# =============================================================================

ralph_validate_session() {
    # Skip validation when session continuity is disabled — no session_id expected
    if [[ "${CLAUDE_USE_CONTINUE:-true}" != "true" ]]; then
        return 0
    fi

    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        log_status "INFO" "No session file — will initialize on first successful invocation"
        return 1
    fi

    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)

    if [[ -z "$session_id" ]]; then
        log_status "WARN" "Session file exists but session_id is empty — reinitializing"
        ralph_initialize_session
        return $?
    fi

    return 0
}

ralph_initialize_session() {
    local now
    now=$(get_iso_timestamp)

    # SESSION-ID-FIX (2026-04-30): the prior version wrote an empty
    # `session_id: ""` "for lazy init" — but the lazy-init step that was
    # supposed to fill it later never existed. `save_claude_session` writes
    # the Claude CLI's session ID to `.claude_session_id` (a separate file),
    # not to `.ralph_session`. `get_session_id()` is also vestigial — defined
    # but called nowhere. Net effect: `.ralph_session.session_id` was empty
    # forever, `ralph_validate_session` warned `session_id is empty` every
    # loop, then re-called this function which wrote empty again. Chronic
    # warning, infinite loop. Fix: generate a real Ralph-internal session ID
    # via the existing helper (same pattern as `init_session_tracking`), so
    # the file always has a non-empty session_id when valid.
    local new_session_id
    new_session_id=$(generate_session_id)

    local tmpfile="${RALPH_SESSION_FILE}.tmp.$$"
    jq -n \
        --arg session_id "$new_session_id" \
        --arg created "$now" \
        --arg last_used "$now" \
        --arg reset_reason "reinitialized" \
        '{
            session_id: $session_id,
            created_at: $created,
            last_used: $last_used,
            reset_at: $created,
            reset_reason: $reset_reason
        }' > "$tmpfile"
    mv "$tmpfile" "$RALPH_SESSION_FILE"
    rm -f "$tmpfile" 2>/dev/null  # WSL cleanup

    log_status "INFO" "Session reinitialized at $now (id: $new_session_id)"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
# PERF: Reduced from 4 jq calls to 1 (construct + append + trim in single pipeline)
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    local ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1

    # Build transition JSON and append+trim in single jq call
    local updated_history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        updated_history=$(jq -c \
            --arg ts "$ts" --arg fs "$from_state" --arg tos "$to_state" \
            --arg r "$reason" --argjson ln "$loop_number" \
            '. + [{timestamp: $ts, from_state: $fs, to_state: $tos, reason: $r, loop_number: $ln}] | .[-50:]' \
            "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
    fi

    if [[ -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh
        printf '[{"timestamp":"%s","from_state":"%s","to_state":"%s","reason":"%s","loop_number":%s}]' \
            "$ts" "$from_state" "$to_state" "$reason" "$loop_number" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
# PERF: Use touch to update mtime instead of jq read-modify-write (was: jq + get_iso_timestamp = 2 subprocesses)
# The session expiry check uses file mtime (get_session_file_age_hours), not the JSON field.
update_session_last_used() {
    [[ -f "$RALPH_SESSION_FILE" ]] && touch "$RALPH_SESSION_FILE" 2>/dev/null
}

# Global array for Claude command arguments (avoids shell injection)
declare -a CLAUDE_CMD_ARGS=()

# Build Claude CLI command with modern flags using array (shell-injection safe)
# Populates global CLAUDE_CMD_ARGS array for direct execution
# Check if Claude Code CLI supports --agent flag (requires v2.1+)
check_agent_support() {
    local version
    version=$(get_cached_claude_version | grep -oE '[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        return 1
    fi

    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    if [[ "$major" -gt 2 ]] || [[ "$major" -eq 2 && "$minor" -ge 1 ]]; then
        return 0
    fi

    return 1
}

# Append monorepo service scope to prompt content (Issue #163)
# When RALPH_SERVICE is set, adds a section scoping work to that service directory
ralph_scope_prompt_for_service() {
    local prompt_content="$1"
    local service_name="${RALPH_SERVICE:-}"

    if [[ -z "$service_name" ]]; then
        echo "$prompt_content"
        return 0
    fi

    # Determine the service directory path
    local monorepo_root="${MONOREPO_ROOT:-services/}"
    local service_dir="${monorepo_root%/}/${service_name}"

    # Check if service directory exists
    if [[ ! -d "$service_dir" ]]; then
        log_status "WARN" "Service directory not found: $service_dir"
        log_status "WARN" "Checked MONOREPO_ROOT='$monorepo_root' + service='$service_name'"
    fi

    # Append service scope section to prompt
    printf '%s\n\n## Monorepo Service Scope\nYou are scoped to the **%s** service.\n- Focus all work within the `%s` directory\n- Only modify files under `%s/` unless cross-service changes are explicitly required\n- Run tests and builds scoped to this service when possible\n- When referencing paths, use paths relative to the project root (e.g., `%s/src/...`)\n' \
        "$prompt_content" "$service_name" "$service_dir" "$service_dir" "$service_dir"
}

# ralph_should_skip_resume — TAP-1209.
# Returns 0 (true) when --resume should be skipped this loop because a fresh
# LINOPT locality hint is present at <ralph_dir>/.linear_next_issue.
#
# Why: Claude on a resumed session replays its prior judgment ("nothing
# actionable") and never re-reads the user-turn hint, so the hint file
# remains on disk with mtime unchanged. Forcing a cold start for hint loops
# bypasses the session-cached state. One-shot helper kept tiny so the
# TAP-1209 BATS regression can exercise it without re-sourcing the whole
# loop script.
#
# Usage: ralph_should_skip_resume "/path/to/.ralph"
ralph_should_skip_resume() {
    local ralph_dir="${1:-${RALPH_DIR:-.ralph}}"
    [[ -f "$ralph_dir/.linear_next_issue" ]]
}

# build_claude_command — assemble the Claude CLI invocation array.
#
# Always invokes `claude --agent <RALPH_AGENT_NAME>` (default "ralph").
# Tool restrictions are owned by the agent file
# (.claude/agents/ralph.md — `tools:` allowlist + `disallowedTools:`
# blocklist) plus the validate-command.sh / protect-ralph-files.sh
# PreToolUse hooks. The legacy `-p` mode + ALLOWED_TOOLS allowlist were
# removed (see docs/decisions/0006-delete-legacy-mode.md).
#
# Requires Claude CLI v2.1+ (CLAUDE_MIN_VERSION). Hard-fails if --agent
# is unsupported — silent fallback was the bug we were trying to fix.
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Hard-fail when the CLI is too old. The startup version check
    # (compare_semver against CLAUDE_MIN_VERSION) should already have
    # caught this, but defense in depth.
    if ! check_agent_support; then
        log_status "ERROR" "Claude CLI does not support --agent. Update to v$CLAUDE_MIN_VERSION+ via: $CLAUDE_CODE_CMD update"
        return 1
    fi

    # Model + effort flags
    # Per-task routing (lib/complexity.sh): when RALPH_MODEL_ROUTING_ENABLED=true,
    # ralph_select_model returns a tier model (haiku/sonnet/opus) based on task
    # type + QA failure count escalation, and appends a row to .model_routing.jsonl.
    # RALPH_CURRENT_QA_FAILURE_COUNT tracks consecutive failures per Linear issue;
    # when >= 3, escalates to Opus as a safety net. Defaults to 0 if not set.
    # Empty task text is intentionally NOT guarded out (TAP-1210): the router
    # logs a `task_type=none / reason=no_task_fallback` row so observability is
    # complete for no-task / fallback loops.
    # Local var so we don't mutate CLAUDE_MODEL across iterations.
    local effective_model="$CLAUDE_MODEL"
    local qa_failure_count="${RALPH_CURRENT_QA_FAILURE_COUNT:-0}"
    if [[ "${RALPH_MODEL_ROUTING_ENABLED:-true}" == "true" ]] \
        && declare -f ralph_select_model &>/dev/null; then
        local _routed_model
        _routed_model=$(ralph_select_model "${RALPH_CURRENT_TASK_TEXT:-}" "$qa_failure_count" 2>/dev/null) || _routed_model=""
        if [[ -n "$_routed_model" ]]; then
            effective_model="$_routed_model"
            if [[ "$effective_model" != "$CLAUDE_MODEL" ]]; then
                local _qa_note=""
                [[ "$qa_failure_count" -ge 3 ]] && _qa_note=" (QA escalation: $qa_failure_count failures)"
                log_status "INFO" "Model routed: $effective_model (task type)${_qa_note}, override of $CLAUDE_MODEL"
            fi
        fi
    fi
    [[ -n "$effective_model" ]] && CLAUDE_CMD_ARGS+=("--model" "$effective_model")
    [[ -n "$CLAUDE_EFFORT" ]] && CLAUDE_CMD_ARGS+=("--effort" "$CLAUDE_EFFORT")

    # TAP-1686: per-loop permission-mode override. When the coordinator
    # marks the current task HIGH-risk in `.ralph/brief.json`, build_loop_context
    # sets `RALPH_PERMISSION_MODE=plan` for this iteration. Without this
    # override the agent file's `permissionMode: bypassPermissions` would
    # take precedence and Plan Mode never engages. Pass-through for any
    # other valid mode (plan / acceptEdits / default / bypassPermissions)
    # so operators can pin a value via env var during incident response.
    if [[ -n "${RALPH_PERMISSION_MODE:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--permission-mode" "$RALPH_PERMISSION_MODE")
        log_status "INFO" "TAP-1686: permission-mode override=${RALPH_PERMISSION_MODE} (agent default bypassed for this loop)"
    fi

    # Agent invocation
    CLAUDE_CMD_ARGS+=("--agent" "${RALPH_AGENT_NAME:-ralph}")

    # Output format (json implies --print, which requires explicit input)
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Session continuity: --resume with explicit session ID. --continue is
    # avoided because it picks "most recent session in cwd" and can
    # hijack active interactive Claude Code sessions (Issue #151).
    # TAP-1209: Skip --resume when a fresh LINOPT locality hint is present.
    # Resumed sessions replay the prior "nothing actionable" judgment and
    # silently ignore the hint (proven by .linear_next_issue mtime never
    # changing). Cold-starting one loop costs ~5-10s but reclaims the
    # ~$0.30-$0.50 of a wasted no-op loop.
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        if ralph_should_skip_resume "${RALPH_DIR:-.ralph}"; then
            log_status "INFO" "TAP-1209: Skipping --resume for this loop to honor LINOPT locality hint (cold-start session)"
        else
            CLAUDE_CMD_ARGS+=("--resume" "$session_id")
        fi
    fi

    # Build the user-turn payload. Agent mode does not honor
    # --append-system-prompt, so loop context is concatenated into -p.
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    local prompt_content
    prompt_content=$(cat "$prompt_file")
    # Issue #163: Scope prompt to monorepo service if --service was specified
    prompt_content=$(ralph_scope_prompt_for_service "$prompt_content")

    # Inject loop context (loop count, MCP guidance, remaining tasks, CB
    # state) into the user turn. Without this, build_loop_context() was
    # computed but silently dropped — MCP guidance never reached Claude.
    if [[ -n "$loop_context" ]]; then
        prompt_content="${prompt_content}

---
${loop_context}"
    fi

    # CTXMGMT-1: progressive (trimmed) view of fix_plan.md so the agent
    # can use it directly without a full-file Read on large plans.
    # TAP-669: fix_plan.md is user-editable and lines from it become
    # system-level context — sanitize before injection to neutralize
    # role-tag injection payloads in task titles.
    if [[ "${RALPH_PROGRESSIVE_CONTEXT:-false}" == "true" && "${RALPH_TASK_SOURCE:-file}" == "file" ]]; then
        local _plan_excerpt
        _plan_excerpt=$(ralph_build_progressive_context 2>/dev/null) || _plan_excerpt=""
        if [[ -n "$_plan_excerpt" ]]; then
            _plan_excerpt=$(printf '%s' "$_plan_excerpt" | ralph_sanitize_prompt_text 500)
            prompt_content="${prompt_content}

---
Current fix_plan.md (progressive view — use this directly, skip re-reading the full file unless you need completed items):
${_plan_excerpt}"
        fi
    fi

    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
    return 0
}

# PERF: Shared helper for git file-change counting (was: duplicated ~30 lines in 2 places)
# Fix #141: Detect both uncommitted changes AND committed changes
_count_files_changed_since_loop_start() {
    local _start_sha="" _current_sha="" _files=0

    [[ -f "$RALPH_DIR/.loop_start_sha" ]] && read -r _start_sha < "$RALPH_DIR/.loop_start_sha" 2>/dev/null

    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        _current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

        if [[ -n "$_start_sha" && -n "$_current_sha" && "$_start_sha" != "$_current_sha" ]]; then
            _files=$(
                {
                    git diff --name-only "$_start_sha" "$_current_sha" 2>/dev/null
                    git diff --name-only HEAD 2>/dev/null
                    git diff --name-only --cached 2>/dev/null
                } | sort -u | wc -l
            )
        else
            _files=$(
                {
                    git diff --name-only 2>/dev/null
                    git diff --name-only --cached 2>/dev/null
                } | sort -u | wc -l
            )
        fi
    fi
    echo "${_files:-0}"
}

# =============================================================================
# GUARD-1: Git Diff Baseline Snapshotting (Phase 13)
# Capture working tree state before each invocation to detect only changes
# made during the current iteration — not pre-existing uncommitted files.
# =============================================================================

# Baseline state variables (set by ralph_capture_baseline, read by ralph_has_real_changes)
RALPH_BASELINE_TREEHASH=""
RALPH_BASELINE_UNTRACKED_HASH=""

# Capture a hash-based snapshot of the working tree before Claude invocation
ralph_capture_baseline() {
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        RALPH_BASELINE_TREEHASH=$(git diff 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")
        RALPH_BASELINE_UNTRACKED_HASH=$(git ls-files --others --exclude-standard 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")
    else
        RALPH_BASELINE_TREEHASH="none"
        RALPH_BASELINE_UNTRACKED_HASH="none"
    fi
}

# Compare current working tree against baseline to detect real changes
# Returns 0 if real changes exist, 1 if no new changes
ralph_has_real_changes() {
    if [[ "$RALPH_BASELINE_TREEHASH" == "none" && "$RALPH_BASELINE_UNTRACKED_HASH" == "none" ]]; then
        # No baseline captured (non-git project) — fall back to any-change detection
        local fallback_files
        fallback_files=$(_count_files_changed_since_loop_start)
        [[ "$fallback_files" -gt 0 ]]
        return $?
    fi

    local current_tree current_untracked
    current_tree=$(git diff 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")
    current_untracked=$(git ls-files --others --exclude-standard 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")

    if [[ "$current_tree" != "$RALPH_BASELINE_TREEHASH" ]] || \
       [[ "$current_untracked" != "$RALPH_BASELINE_UNTRACKED_HASH" ]]; then
        return 0  # Real changes exist
    fi

    # Also check for new commits since loop start
    local _start_sha="" _current_sha=""
    [[ -f "$RALPH_DIR/.loop_start_sha" ]] && read -r _start_sha < "$RALPH_DIR/.loop_start_sha" 2>/dev/null
    _current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "$_start_sha" && -n "$_current_sha" && "$_start_sha" != "$_current_sha" ]]; then
        return 0  # New commits made
    fi

    return 1  # No new changes
}

# =============================================================================
# DEPLOY-1: Container Freshness Check Before Integration Tests (Phase 13)
# Detects stale Docker containers and warns/skips integration tests.
# =============================================================================

DEPLOY_COMMAND="${DEPLOY_COMMAND:-}"
DEPLOY_HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-120}"
DEPLOY_AUTO_REBUILD="${DEPLOY_AUTO_REBUILD:-false}"
DEPLOY_SOURCE_DIRS="${DEPLOY_SOURCE_DIRS:-src/ lib/ app/}"

ralph_check_container_freshness() {
    local project_dir="${1:-.}"

    # Skip if no docker-compose file exists
    local compose_file=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [[ -f "$project_dir/$f" ]]; then
            compose_file="$project_dir/$f"
            break
        fi
    done
    [[ -z "$compose_file" ]] && return 0  # Not a Docker project

    # Check Docker is available
    if ! command -v docker &>/dev/null; then
        return 0
    fi

    # Get most recent code change timestamp
    local last_code_change
    last_code_change=$(cd "$project_dir" && git log -1 --format=%ct -- $DEPLOY_SOURCE_DIRS 2>/dev/null || echo "0")
    [[ "$last_code_change" == "0" ]] && return 0  # No git history

    # Get running containers
    local container_names
    container_names=$(cd "$project_dir" && docker compose ps --format '{{.Name}}' 2>/dev/null)
    [[ -z "$container_names" ]] && return 0  # No running containers

    local oldest_start=999999999999
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        local start_epoch
        start_epoch=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null \
            | xargs -I{} date -d {} +%s 2>/dev/null || echo "0")
        [[ "$start_epoch" -lt "$oldest_start" ]] && oldest_start=$start_epoch
    done <<< "$container_names"

    if [[ "$last_code_change" -gt "$oldest_start" ]]; then
        local age_hours=$(( ($(date +%s) - oldest_start) / 3600 ))
        log_status "WARN" "Docker containers are stale (started ${age_hours}h ago, code changed since)"
        log_status "WARN" "Integration/e2e tests may not reflect current code"

        if [[ "$DEPLOY_AUTO_REBUILD" == "true" && -n "$DEPLOY_COMMAND" ]]; then
            log_status "INFO" "Running deploy command: $DEPLOY_COMMAND"
            if (cd "$project_dir" && eval "$DEPLOY_COMMAND"); then
                log_status "SUCCESS" "Containers rebuilt successfully"
                sleep 5
                return 0
            else
                log_status "ERROR" "Deploy command failed — skipping integration tests"
                return 1
            fi
        elif [[ -n "$DEPLOY_COMMAND" ]]; then
            log_status "WARN" "Set DEPLOY_AUTO_REBUILD=true in .ralphrc to auto-rebuild"
            return 1
        else
            log_status "WARN" "No DEPLOY_COMMAND configured in .ralphrc — cannot auto-rebuild"
            log_status "WARN" "Set DEPLOY_COMMAND='docker compose up --build -d' in .ralphrc"
            return 1  # Signal that integration tests should be skipped
        fi
    fi

    return 0  # Containers are fresh
}

# =============================================================================
# UPKEEP-2: MCP Server Failure Suppression (Phase 13)
# Log-once-per-session pattern for MCP failures to reduce noise.
# =============================================================================

MCP_FAILURE_FILE="${RALPH_DIR}/.mcp_failures_session"

ralph_init_mcp_tracking() {
    : > "$MCP_FAILURE_FILE" 2>/dev/null
}

ralph_record_mcp_failure() {
    local server_name="$1"

    # Check if already recorded this session
    if grep -q "^${server_name}$" "$MCP_FAILURE_FILE" 2>/dev/null; then
        log_status "DEBUG" "MCP server '$server_name' still failing (suppressed — logged at session start)"
        return 0
    fi

    # First failure for this server this session
    echo "$server_name" >> "$MCP_FAILURE_FILE"
    log_status "WARN" "MCP server '$server_name' failed to connect — subsequent failures will be suppressed"
}

ralph_mcp_failure_summary() {
    if [[ ! -f "$MCP_FAILURE_FILE" ]] || [[ ! -s "$MCP_FAILURE_FILE" ]]; then
        return 0
    fi

    local count servers
    count=$(wc -l < "$MCP_FAILURE_FILE" | tr -d '[:space:]')
    servers=$(paste -sd',' "$MCP_FAILURE_FILE" 2>/dev/null)

    log_status "WARN" "MCP servers failed this session ($count): $servers"
    log_status "INFO" "Check MCP configuration: claude mcp list"
}

# =============================================================================
# TAP-1838: Compute a hash over the inputs that can invalidate a cached MCP
# probe result. Inputs: `claude --version` + `.mcp.json` + `~/.claude.json`.
# Outputs the hex digest on stdout; empty string when no hash command is
# available (caller must treat this as a cache-miss and run the live probe).
# =============================================================================
ralph_mcp_compute_probe_hash() {
    local _ver _mcp _global _input
    _ver=$(get_cached_claude_version 2>/dev/null || echo "unknown")
    _mcp=$(cat ".mcp.json" 2>/dev/null || echo "")
    _global=$(cat "${HOME}/.claude.json" 2>/dev/null || echo "")
    _input="${_ver}|${_mcp}|${_global}"
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$_input" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$_input" | shasum -a 256 | awk '{print $1}'
    else
        echo ""
    fi
}

# =============================================================================
# TAP-584 (epic TAP-583): Probe global MCP server availability ONCE at startup.
# Sets RALPH_MCP_TAPPS_AVAILABLE / RALPH_MCP_DOCS_AVAILABLE /
# RALPH_MCP_BRAIN_AVAILABLE in the environment. Downstream stories (TAP-585
# prompt guidance, TAP-588 counters, TAP-587 sub-agents) gate on these flags
# so a missing MCP doesn't trigger false-positive guidance pointing Claude at
# tools that don't exist.
#
# Fail-loud, never fail-stop: probe errors (timeout, parse failure, CLI missing)
# set all flags `false` + WARN, loop continues normally. Same posture as the
# TAP-536 fail-loud Linear handling — never abstain into a destructive default.
#
# Server registration: each MCP server is registered by the *project* (via
# `.mcp.json` or `claude mcp add`), not by Ralph. Ralph only probes and steers.
#
# TAP-1838: Sentinel cache — when RALPH_MCP_PROBE_SKIP_IF_UNCHANGED=true
# (default), a valid sentinel file with a matching input hash causes the
# function to return immediately with cached flag values, skipping the 30s
# `claude mcp list` call.
# =============================================================================
ralph_probe_mcp_servers() {
    export RALPH_MCP_TAPPS_AVAILABLE="false"
    export RALPH_MCP_DOCS_AVAILABLE="false"
    export RALPH_MCP_BRAIN_AVAILABLE="false"
    # TAP-1530: distinguishes "container down" (silent) from "container up but
    # token wrong" (explicit negative instruction needed so Claude does not
    # attempt brain_recall and stall waiting for a response).
    export RALPH_MCP_BRAIN_AUTH_FAILED="false"

    if ! command -v "$CLAUDE_CODE_CMD" &>/dev/null; then
        log_status "WARN" "MCP probe skipped: '$CLAUDE_CODE_CMD' not in PATH"
        return 0
    fi

    # TAP-1838: Sentinel cache check. If probe inputs (claude version + MCP
    # config files) are unchanged since the last successful probe and the
    # sentinel is < RALPH_MCP_PROBE_SENTINEL_MAX_AGE seconds old, load the
    # cached flags and skip the expensive `claude mcp list` call.
    local _sentinel_file="${RALPH_MCP_PROBE_SENTINEL_FILE:-${RALPH_DIR}/.mcp-probe-sentinel}"
    local _max_age="${RALPH_MCP_PROBE_SENTINEL_MAX_AGE:-86400}"
    if [[ "${RALPH_MCP_PROBE_SKIP_IF_UNCHANGED:-true}" == "true" && -f "$_sentinel_file" ]]; then
        local _ts _age _stored_hash _live_hash
        _ts=$(awk -F= '/^ts=/{print $2}' "$_sentinel_file" 2>/dev/null || echo 0)
        _age=$(( $(date +%s) - _ts ))
        if (( _age < _max_age )); then
            _stored_hash=$(awk -F= '/^hash=/{print $2}' "$_sentinel_file" 2>/dev/null || echo "")
            _live_hash=$(ralph_mcp_compute_probe_hash 2>/dev/null || echo "")
            if [[ -n "$_live_hash" && "$_stored_hash" == "$_live_hash" ]]; then
                RALPH_MCP_TAPPS_AVAILABLE=$(awk -F= '/^tapps=/{print $2}' "$_sentinel_file" 2>/dev/null || echo "false")
                RALPH_MCP_DOCS_AVAILABLE=$(awk -F= '/^docs=/{print $2}' "$_sentinel_file" 2>/dev/null || echo "false")
                RALPH_MCP_BRAIN_AVAILABLE=$(awk -F= '/^brain=/{print $2}' "$_sentinel_file" 2>/dev/null || echo "false")
                RALPH_MCP_BRAIN_AUTH_FAILED=$(awk -F= '/^brain_auth_failed=/{print $2}' "$_sentinel_file" 2>/dev/null || echo "false")
                log_status "INFO" "MCP probe cached (age ${_age}s): tapps=${RALPH_MCP_TAPPS_AVAILABLE} docs=${RALPH_MCP_DOCS_AVAILABLE} brain=${RALPH_MCP_BRAIN_AVAILABLE}"
                return 0
            fi
        fi
    fi

    # Upper bound on the probe wait — a hung MCP transport must not stall startup.
    # Default 30s covers cold-start cases where stdio MCP servers have to spawn
    # child processes and HTTP MCPs do auth round-trips. Warm runs return in
    # 1–2s so the high default is invisible most of the time.
    # Set RALPH_MCP_PROBE_TIMEOUT_SECONDS to override.
    # Use a temp file instead of $() to avoid the pipe-stays-open problem:
    # claude spawns MCP server child processes that keep the pipe's write-fd
    # open after claude exits from SIGTERM, so $() never sees EOF and hangs.
    # Redirecting to a file lets timeout exit cleanly regardless of children.
    local probe_output probe_tmp probe_timeout
    probe_timeout="${RALPH_MCP_PROBE_TIMEOUT_SECONDS:-30}"
    probe_tmp=$(mktemp)
    timeout --kill-after=3s "${probe_timeout}s" $CLAUDE_CODE_CMD mcp list >"$probe_tmp" 2>&1 || true
    probe_output=$(cat "$probe_tmp" 2>/dev/null)
    rm -f "$probe_tmp"
    if [[ -z "$probe_output" ]]; then
        log_status "WARN" "MCP probe failed: '$CLAUDE_CODE_CMD mcp list' returned no output or timed out"
        return 0
    fi

    # Match a line where the server name appears as a column / key, AND the
    # same line contains a positive status indicator. Tolerant of formatting
    # variations across CLI versions; conservative fallback when in doubt is
    # "unavailable" so we never inject prompt guidance for an absent server.
    if echo "$probe_output" | grep -E '(^|[[:space:]])tapps-mcp([[:space:]:]|$)' \
       | grep -qiE '(connected|✓|ok|ready|running)'; then
        RALPH_MCP_TAPPS_AVAILABLE="true"
        log_status "INFO" "MCP probe: tapps-mcp reachable"
    else
        log_status "WARN" "MCP probe: tapps-mcp NOT reachable — Ralph will not steer Claude toward it"
    fi

    if echo "$probe_output" | grep -E '(^|[[:space:]])docs-mcp([[:space:]:]|$)' \
       | grep -qiE '(connected|✓|ok|ready|running)'; then
        RALPH_MCP_DOCS_AVAILABLE="true"
        log_status "INFO" "MCP probe: docs-mcp reachable"
    else
        log_status "WARN" "MCP probe: docs-mcp NOT reachable — Ralph will not steer Claude toward it"
    fi

    # tapps-brain typically runs as a dockerized HTTP MCP server (not a uv
    # subprocess like tapps-mcp/docs-mcp), so it has no orphan-cleanup story —
    # its container lifecycle is managed outside Ralph.
    if echo "$probe_output" | grep -E '(^|[[:space:]])tapps-brain([[:space:]:]|$)' \
       | grep -qiE '(connected|✓|ok|ready|running)'; then
        RALPH_MCP_BRAIN_AVAILABLE="true"
        log_status "INFO" "MCP probe: tapps-brain reachable"
    else
        ralph_diagnose_brain_probe_failure
    fi

    # TAP-1838: Write sentinel so the next startup can skip the live probe when
    # inputs are unchanged. Only written when the hash is computable — if
    # sha256sum/shasum are absent the sentinel stays missing and the probe
    # runs every time (safe degradation).
    if [[ "${RALPH_MCP_PROBE_SKIP_IF_UNCHANGED:-true}" == "true" ]]; then
        local _cur_hash
        _cur_hash=$(ralph_mcp_compute_probe_hash 2>/dev/null || echo "")
        if [[ -n "$_cur_hash" ]]; then
            {
                printf 'ts=%d\n' "$(date +%s)"
                printf 'hash=%s\n' "$_cur_hash"
                printf 'tapps=%s\n' "$RALPH_MCP_TAPPS_AVAILABLE"
                printf 'docs=%s\n' "$RALPH_MCP_DOCS_AVAILABLE"
                printf 'brain=%s\n' "$RALPH_MCP_BRAIN_AVAILABLE"
                printf 'brain_auth_failed=%s\n' "$RALPH_MCP_BRAIN_AUTH_FAILED"
            } > "$_sentinel_file" 2>/dev/null || true
        fi
    fi
}

# BRAIN-PHASE-A: When `claude mcp list` reports tapps-brain as "failed to
# connect", that single bit conflates "container down" and "container up but
# bearer token missing/wrong". Curl the /health endpoint (unauthenticated by
# design) to distinguish, so operators aren't left grep'ing docker logs.
#
# Runs only on probe failure — success path stays fast.
ralph_diagnose_brain_probe_failure() {
    log_status "WARN" "MCP probe: tapps-brain NOT reachable — Ralph will not steer Claude toward it"

    # Parse the endpoint from the project's .mcp.json so we probe the exact
    # URL the MCP client is using. Fall back to the conventional local-dev
    # endpoint if jq is missing or the entry isn't present.
    local brain_url=""
    if [[ -f "./.mcp.json" ]] && command -v jq &>/dev/null; then
        brain_url=$(jq -r '.mcpServers["tapps-brain"].url // ""' \
            "./.mcp.json" 2>/dev/null || echo "")
    fi
    [[ -z "$brain_url" || "$brain_url" == "null" ]] && brain_url="http://127.0.0.1:8080/mcp/"

    # Derive scheme://host[:port]/health from the MCP URL.
    local health_url
    health_url=$(echo "$brain_url" | sed -E 's#(https?://[^/]+).*#\1/health#')

    if ! command -v curl &>/dev/null; then
        log_status "INFO" "  curl not installed — cannot diagnose further"
        return 0
    fi

    local code
    code=$(curl -sS -o /dev/null --max-time 3 -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")
    case "$code" in
        200)
            log_status "INFO" "  $health_url -> 200 (container up) — bearer token is likely missing or wrong"
            # TAP-1530: explicit auth-failed flag so build_loop_context can
            # inject a negative instruction (do not attempt brain_recall).
            export RALPH_MCP_BRAIN_AUTH_FAILED="true"
            if [[ -z "${TAPPS_BRAIN_AUTH_TOKEN:-}" ]]; then
                log_status "INFO" "  TAPPS_BRAIN_AUTH_TOKEN is not set. Add it to ~/.ralph/secrets.env (chmod 600)."
            else
                log_status "INFO" "  TAPPS_BRAIN_AUTH_TOKEN is set — verify it matches the brain container's configured token"
            fi
            ;;
        000|"")
            log_status "INFO" "  $health_url unreachable — brain container appears to be down (check: docker ps | grep tapps-brain)"
            ;;
        *)
            log_status "INFO" "  $health_url -> HTTP $code — unexpected response; check the brain container logs"
            ;;
    esac
}

# TAP-584: Print a capability summary for `ralph --mcp-status`. Runs the probe
# (so the user can debug "why isn't Ralph using the MCP" without grepping
# logs), then prints all flag values regardless of probe outcome.
ralph_print_mcp_status() {
    ralph_probe_mcp_servers >&2
    echo "tapps-mcp:   ${RALPH_MCP_TAPPS_AVAILABLE:-false}"
    echo "docs-mcp:    ${RALPH_MCP_DOCS_AVAILABLE:-false}"
    echo "tapps-brain: ${RALPH_MCP_BRAIN_AVAILABLE:-false}"
}

# =============================================================================
# MCP-CLEANUP: Kill orphaned MCP server processes between loop iterations.
# Claude Code spawns MCP servers (tapps-mcp, docsmcp) as grandchild processes.
# On Windows, these survive after the CLI exits because process group teardown
# doesn't cascade. Each loop iteration leaks one pair (uv + python per server).
# This function kills them so they're re-spawned fresh on the next invocation.
# =============================================================================

ralph_cleanup_orphaned_mcp() {
    local killed=0

    # Detect Windows environments: native (MINGW/Cygwin) and WSL (MCP servers
    # are Windows processes even when Ralph runs in WSL, so pkill won't find them)
    local _is_windows=false
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
        _is_windows=true
    elif [[ "$(uname -r 2>/dev/null)" == *icrosoft* || "$(uname -r 2>/dev/null)" == *WSL* ]]; then
        _is_windows=true
    fi

    if [[ "$_is_windows" == "true" ]]; then
        # Windows (Git Bash / MINGW64 / Cygwin): use PowerShell via temp script
        # to avoid bash→PowerShell quote-escaping issues with WMI filters.
        # Only kills ORPHANED MCP processes (parent dead) to avoid disrupting
        # MCP servers belonging to the user's editor (Cursor, VS Code, etc.).
        # On WSL, /tmp is Linux-only; PowerShell can't read it.
        # Use Windows %TEMP% via wslpath, or fall back to /tmp (MINGW).
        local _tmpbase="${TMPDIR:-/tmp}"
        if command -v wslpath &>/dev/null; then
            _tmpbase=$(wslpath "$(powershell.exe -NoProfile -NonInteractive -Command 'Write-Output $env:TEMP' 2>/dev/null | tr -d '\r')" 2>/dev/null) || _tmpbase="/tmp"
        fi
        local ps_script
        ps_script=$(mktemp "${_tmpbase}/ralph_mcp_cleanup.XXXXXX.ps1")
        cat > "$ps_script" << 'PSEOF'
# Collect MCP server processes (uv wrappers + python workers)
$candidates = @()
$candidates += Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match "(tapps-mcp|docsmcp).*serve" }
$candidates += Get-CimInstance Win32_Process -Filter "Name='uv.exe'" |
    Where-Object { $_.CommandLine -match "(tapps-mcp|docsmcp).*serve" }

$count = 0
foreach ($p in $candidates) {
    # Only kill orphans: parent process no longer exists
    $parentAlive = $null -ne (Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue)
    if (-not $parentAlive) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $count++ } catch {}
    }
}
Write-Output $count
PSEOF
        # Convert Unix path to Windows path (cygpath on MINGW, wslpath on WSL)
        local win_path
        if command -v cygpath &>/dev/null; then
            win_path=$(cygpath -w "$ps_script")
        elif command -v wslpath &>/dev/null; then
            win_path=$(wslpath -w "$ps_script")
        else
            win_path="$ps_script"
        fi
        # 10s timeout prevents blocking in signal traps if PowerShell hangs
        killed=$(timeout 10s powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win_path" 2>/dev/null || echo "0")
        rm -f "$ps_script" 2>/dev/null
    elif command -v pgrep &>/dev/null; then
        # Linux / macOS: pgrep + parent-alive/reaper check (TAP-670).
        # Mirrors the PowerShell branch: a process is an orphan if its current
        # parent is a reaper that is not the original spawner. Three signals:
        #   1. ppid == 1 — classic reparent target in bare shells and
        #      PID-namespaced containers (tini is PID 1).
        #   2. ppid refers to a process that no longer exists — true death
        #      between pgrep and ps.
        #   3. parent comm matches a known reaper (systemd-user service
        #      manager, launchd on macOS, upstart-user). PID 1 heuristic
        #      alone misses these; kill -0 alone misses them too (reaper
        #      is always alive). Covers the WSL systemd-user case.
        local pids
        pids=$(pgrep -f "(tapps-mcp|docsmcp).*serve" 2>/dev/null) || true
        for pid in $pids; do
            local ppid pcomm
            ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            # Skip unreadable ppid (process exited mid-check)
            [[ -z "$ppid" ]] && continue
            pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ')
            if [[ "$ppid" == "1" ]] \
               || ! kill -0 "$ppid" 2>/dev/null \
               || [[ "$pcomm" =~ ^(systemd|init|tini|launchd|upstart)$ ]]; then
                kill "$pid" 2>/dev/null && killed=$((killed + 1))
            fi
        done
    fi

    killed=$(echo "$killed" | tr -d '[:space:]')
    if [[ "${killed:-0}" -gt 0 ]]; then
        log_status "INFO" "MCP-CLEANUP: Killed $killed orphaned MCP server processes"
    fi
}

# =============================================================================
# ADAPTIVE-1: Percentile-Based Adaptive Timeout (Phase 13)
# Track completion times and compute P95-based adaptive timeout.
# =============================================================================

LATENCY_LOG="${RALPH_DIR}/.invocation_latencies"

# Record a successful invocation's duration (in seconds)
ralph_record_latency() {
    local duration_seconds="$1"
    echo "$duration_seconds" >> "$LATENCY_LOG"

    # Keep only the last 50 samples to bound file size
    if [[ -f "$LATENCY_LOG" ]]; then
        local count
        count=$(wc -l < "$LATENCY_LOG" 2>/dev/null | tr -d '[:space:]')
        if [[ "$count" -gt 50 ]]; then
            tail -50 "$LATENCY_LOG" > "${LATENCY_LOG}.tmp"
            mv "${LATENCY_LOG}.tmp" "$LATENCY_LOG"
            rm -f "${LATENCY_LOG}.tmp" 2>/dev/null
        fi
    fi
}

# Compute adaptive timeout based on P95 of historical completion times
ralph_compute_adaptive_timeout() {
    # If adaptive timeout is disabled, use static setting
    if [[ "${ADAPTIVE_TIMEOUT_ENABLED:-true}" != "true" ]]; then
        echo "${CLAUDE_TIMEOUT_MINUTES:-15}"
        return
    fi

    # Need minimum samples before adapting
    local sample_count
    if [[ -f "$LATENCY_LOG" ]]; then
        sample_count=$(wc -l < "$LATENCY_LOG" 2>/dev/null | tr -d '[:space:]')
    else
        sample_count=0
    fi

    if [[ "$sample_count" -lt "$ADAPTIVE_TIMEOUT_MIN_SAMPLES" ]]; then
        log_status "DEBUG" "Adaptive timeout: only $sample_count samples (need $ADAPTIVE_TIMEOUT_MIN_SAMPLES) — using static ${CLAUDE_TIMEOUT_MINUTES:-15}m"
        echo "${CLAUDE_TIMEOUT_MINUTES:-15}"
        return
    fi

    # Compute P95
    local p95_index p95_seconds timeout_seconds timeout_minutes
    p95_index=$(( (sample_count * 95) / 100 ))
    [[ "$p95_index" -lt 1 ]] && p95_index=1

    p95_seconds=$(sort -n "$LATENCY_LOG" | sed -n "${p95_index}p")
    [[ -z "$p95_seconds" ]] && { echo "${CLAUDE_TIMEOUT_MINUTES:-15}"; return; }

    # Apply multiplier
    timeout_seconds=$((p95_seconds * ADAPTIVE_TIMEOUT_MULTIPLIER))
    timeout_minutes=$(( (timeout_seconds + 59) / 60 ))  # Round up

    # Clamp to min/max
    [[ "$timeout_minutes" -lt "$ADAPTIVE_TIMEOUT_MIN_MINUTES" ]] && timeout_minutes=$ADAPTIVE_TIMEOUT_MIN_MINUTES
    [[ "$timeout_minutes" -gt "$ADAPTIVE_TIMEOUT_MAX_MINUTES" ]] && timeout_minutes=$ADAPTIVE_TIMEOUT_MAX_MINUTES

    log_status "DEBUG" "Adaptive timeout: P95=${p95_seconds}s × ${ADAPTIVE_TIMEOUT_MULTIPLIER} = ${timeout_minutes}m (range: ${ADAPTIVE_TIMEOUT_MIN_MINUTES}-${ADAPTIVE_TIMEOUT_MAX_MINUTES}m, samples: $sample_count)"
    echo "$timeout_minutes"
}

# =============================================================================
# TAP-1682: Coordinator adaptive timeout — P95×2 of the last 30 coordinator
# wall-clock samples, clamped to [30, 600] seconds, falling back to 120 when
# no samples exist. Mirrors ralph_compute_adaptive_timeout but scoped to the
# coordinator path because coordinator latency (10–30s on warm MCP, 90–180s
# on cold start) has a very different distribution from main-loop Claude
# invocations. Samples live in .ralph/.coordinator_timings.jsonl — one
# `{"ts":<epoch>,"duration_seconds":<int>,"exit_code":<int>}` per line.
# =============================================================================

COORDINATOR_TIMINGS_LOG="${RALPH_DIR}/.coordinator_timings.jsonl"
COORDINATOR_TIMING_SAMPLE_CAP=30

# Append one coordinator wall-clock sample. Called from
# _coordinator_invoke_claude regardless of success/failure so the P95 reflects
# real-world latency including transient failures.
ralph_record_coordinator_timing() {
    local duration_seconds="$1"
    local exit_code="${2:-0}"
    [[ -n "$duration_seconds" ]] || return 0
    local line
    line=$(printf '{"ts":%s,"duration_seconds":%s,"exit_code":%s}' \
        "$(date -u +%s)" "$duration_seconds" "$exit_code")
    printf '%s\n' "$line" >> "$COORDINATOR_TIMINGS_LOG" 2>/dev/null || return 0
    # Bound the file so a long-running ralph install does not unbounded-grow.
    local count
    count=$(wc -l < "$COORDINATOR_TIMINGS_LOG" 2>/dev/null | tr -d '[:space:]')
    if [[ "${count:-0}" -gt "$COORDINATOR_TIMING_SAMPLE_CAP" ]]; then
        tail -"$COORDINATOR_TIMING_SAMPLE_CAP" "$COORDINATOR_TIMINGS_LOG" \
            > "${COORDINATOR_TIMINGS_LOG}.tmp" 2>/dev/null
        mv -f "${COORDINATOR_TIMINGS_LOG}.tmp" "$COORDINATOR_TIMINGS_LOG" 2>/dev/null
        rm -f "${COORDINATOR_TIMINGS_LOG}.tmp" 2>/dev/null || true
    fi
}

# Compute the coordinator timeout in SECONDS (not minutes — coordinator runs
# are bounded enough to want sub-minute granularity). Honors
# RALPH_COORDINATOR_TIMEOUT_SECONDS as a hard override so operators can pin a
# value during incident response without disabling adaptivity globally.
ralph_compute_coordinator_timeout() {
    # Operator override always wins. "0" still means "no timeout" downstream.
    if [[ -n "${RALPH_COORDINATOR_TIMEOUT_SECONDS:-}" ]]; then
        echo "${RALPH_COORDINATOR_TIMEOUT_SECONDS}"
        return 0
    fi

    local min_samples="${RALPH_COORDINATOR_TIMEOUT_MIN_SAMPLES:-3}"
    local min_seconds="${RALPH_COORDINATOR_TIMEOUT_MIN_SECONDS:-30}"
    local max_seconds="${RALPH_COORDINATOR_TIMEOUT_MAX_SECONDS:-600}"
    local fallback="${RALPH_COORDINATOR_TIMEOUT_FALLBACK_SECONDS:-120}"

    local sample_count=0
    if [[ -f "$COORDINATOR_TIMINGS_LOG" ]]; then
        sample_count=$(wc -l < "$COORDINATOR_TIMINGS_LOG" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ "${sample_count:-0}" -lt "$min_samples" ]]; then
        echo "$fallback"
        return 0
    fi

    # Extract durations, sort, pick P95 index, ×2.
    local p95_index p95_seconds
    p95_index=$(( (sample_count * 95) / 100 ))
    [[ "$p95_index" -lt 1 ]] && p95_index=1
    p95_seconds=$(jq -r '.duration_seconds // empty' "$COORDINATOR_TIMINGS_LOG" 2>/dev/null \
        | grep -E '^[0-9]+$' \
        | sort -n \
        | sed -n "${p95_index}p")
    if [[ -z "$p95_seconds" ]]; then
        echo "$fallback"
        return 0
    fi
    local timeout_seconds=$((p95_seconds * 2))
    [[ "$timeout_seconds" -lt "$min_seconds" ]] && timeout_seconds=$min_seconds
    [[ "$timeout_seconds" -gt "$max_seconds" ]] && timeout_seconds=$max_seconds
    echo "$timeout_seconds"
}

# Main execution function
execute_claude_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    local calls_made
    calls_made=$(increment_call_counter)

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    # Store in file for access by progress detection after Claude execution
    local loop_start_sha=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    # CBDECAY-2: Validate session before invocation (catches empty session_id after CB reset)
    ralph_validate_session

    # GUARD-1: Capture working tree baseline before Claude invocation
    ralph_capture_baseline

    local _token_info=""
    if [[ "$MAX_TOKENS_PER_HOUR" -gt 0 ]]; then
        _token_info=" | Tokens $(_read_token_count)/$MAX_TOKENS_PER_HOUR"
    fi
    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR${_token_info})"

    # ADAPTIVE-1: Use adaptive timeout if enabled, otherwise static
    local adaptive_timeout
    adaptive_timeout=$(ralph_compute_adaptive_timeout)
    local timeout_seconds=$((adaptive_timeout * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${adaptive_timeout}m)"

    # Track invocation start time for latency recording
    local invocation_start_epoch
    invocation_start_epoch=$(date +%s)

    # Build loop context (always, regardless of session mode)
    local loop_context=""
    loop_context=$(build_loop_context "$loop_count")
    if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Loop context: $loop_context"
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        session_id=$(init_claude_session)
    fi

    # Live mode requires JSON output (stream-json) — override text format
    if [[ "$LIVE_OUTPUT" == "true" && "$CLAUDE_OUTPUT_FORMAT" == "text" ]]; then
        log_status "WARN" "Live mode requires JSON output format. Overriding text → json for this session."
        CLAUDE_OUTPUT_FORMAT="json"
    fi

    # Build the Claude CLI command with modern flags
    local use_modern_cli=false

    if build_claude_command "$PROMPT_FILE" "$loop_context" "$session_id"; then
        use_modern_cli=true
        log_status "INFO" "Using modern CLI mode (${CLAUDE_OUTPUT_FORMAT} output)"
    else
        log_status "WARN" "Failed to build modern CLI command, falling back to legacy mode"
        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    # Execute Claude Code
    local exit_code=0

    # Initialize live.log for this execution
    echo -e "\n\n=== Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # LIVE MODE: Show streaming output in real-time using stream-json + jq
        # Based on: https://www.ytyng.com/en/blog/claude-stream-json-jq/
        #
        # Uses CLAUDE_CMD_ARGS from build_claude_command() to preserve:
        # - --agent (agent definition + tool permissions)
        # - --resume (session continuity)
        # - -p (prompt content + loop context)

        # Check dependencies for live mode
        if ! command -v awk &> /dev/null; then
            log_status "ERROR" "Live mode requires 'awk' but it's not installed. Falling back to background mode."
            LIVE_OUTPUT=false
        elif ! command -v stdbuf &> /dev/null; then
            log_status "ERROR" "Live mode requires 'stdbuf' (from coreutils) but it's not installed. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # Safety check: live mode requires a successfully built modern command
        if [[ "$use_modern_cli" != "true" || ${#CLAUDE_CMD_ARGS[@]} -eq 0 ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    # Dispatch to the appropriate runner. Helpers live in lib/exec_helpers.sh
    # (TAP-1473). exec_run_background returns 99 on early-launch failure;
    # propagate as `return 1` so the post-run analysis is skipped.
    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        exec_run_live "$timeout_seconds" "$output_file" "$adaptive_timeout"
        exit_code=$?
    else
        exec_run_background "$timeout_seconds" "$output_file" "$use_modern_cli"
        exit_code=$?
        [[ $exit_code -eq 99 ]] && return 1
    fi

    # MCP-CLEANUP: Kill orphaned MCP server processes after each CLI invocation.
    # Claude Code spawns these as grandchildren that survive CLI exit on Windows.
    ralph_cleanup_orphaned_mcp

    # Expose invocation duration to caller so the fast-trip detector in the main
    # loop can see it (invocation_start_epoch is local-scoped to this function).
    if [[ -n "${invocation_start_epoch:-}" ]]; then
        LAST_INVOCATION_DURATION=$(( $(date +%s) - invocation_start_epoch ))
    fi

    # Unified is_error:true classifier (extracted to lib/exec_helpers.sh — TAP-1474).
    # Runs BEFORE branching on exit_code so the same JSON-level error is handled
    # identically whether the CLI exited 0 or non-zero (Issue #134 / #199).
    exec_classify_api_error "$output_file" "$exit_code"
    case $? in
        0) ;;     # Not an is_error — fall through to exit-code-based handling
        4) return 4 ;;  # Monthly spend cap reached — terminal until reset date
        *) return 1 ;;  # Generic is_error — session reset done; retry next loop
    esac

    if [ $exit_code -eq 0 ]; then
        # Clear progress file (is_error:true was already classified above)
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Claude Code execution completed successfully"

        ralph_prepare_claude_output_for_analysis "$output_file"

        # Save session ID from JSON output (Phase 1.1)
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Issue #223: Accumulate token usage from this call
        accumulate_tokens "$output_file"

        # Update exit signals from status.json (written by on-stop.sh hook)
        log_status "INFO" "🔍 Reading response analysis from status.json..."
        if ! update_exit_signals_from_status; then
            log_status "WARN" "Exit signal update failed; continuing with stale signals"
        fi

        # Coordinator post-run state machine (TAP-1477) — debrief decision
        # (TAP-917), BLOCK signal surfacing (TAP-923), and task-boundary
        # cleanup (TAP-924). Order is enforced inside the helper: debrief
        # reads brief.json before cleanup wipes it.
        exec_post_run_coordinator

        # LOGFIX-6: track consecutive TESTS_STATUS: DEFERRED to detect environment
        # stalls. Extracted to lib/exec_helpers.sh (TAP-1475) — trips the circuit
        # breaker at 2× CB_MAX_DEFERRED_TESTS and `break`s the main loop.
        exec_track_deferred_tests "$loop_count"

        # Log analysis summary (non-critical)
        if ! log_status_summary; then
            log_status "WARN" "Analysis summary logging failed; non-critical, continuing"
        fi

        # USYNC-5: Check for stuck loop (same errors repeating across recent outputs)
        if detect_stuck_loop "$output_file"; then
            log_status "WARN" "Stuck loop detected — same errors in 3+ consecutive outputs"
        fi

        # Get file change count for circuit breaker
        local files_changed
        files_changed=$(_count_files_changed_since_loop_start)

        # Two-stage error pattern detection (TAP-1484, lib/exec_helpers.sh).
        # Filters JSON field names then greps for documented error markers.
        # No downstream consumer of the result — helper logs WARN/DEBUG only.
        exec_detect_output_errors "$output_file" || true

        # Check if on-stop.sh hook transitioned circuit breaker to OPEN
        if cb_is_open; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        # ADAPTIVE-1: Record latency for successful (non-timeout) completions
        if [[ -n "${invocation_start_epoch:-}" ]]; then
            local invocation_end_epoch duration_seconds
            invocation_end_epoch=$(date +%s)
            duration_seconds=$((invocation_end_epoch - invocation_start_epoch))
            ralph_record_latency "$duration_seconds"
        fi

        # CBDECAY-1: Record success for sliding window
        cb_record_success

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        # Layer 1: timeout guard — exit code 124 is a timeout, not an API limit.
        # Productive vs unproductive split + consecutive-timeout CB trip live
        # in lib/exec_helpers.sh::exec_handle_timeout (TAP-1476). Issue #198.
        if [[ $exit_code -eq 124 ]]; then
            exec_handle_timeout "$output_file" "${invocation_start_epoch:-}"
            return $?
        fi

        # Layers 2-4: Claude API rate-limit / Extra Usage quota detection.
        # Extracted to lib/exec_helpers.sh::exec_detect_rate_limit (TAP-1476).
        # Returns 0 (no limit, fall through) or 2 (limit detected, propagate).
        exec_detect_rate_limit "$output_file"
        case $? in
            0) ;;
            2) return 2 ;;
        esac

        log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
        return 1
    fi
}

# Cleanup function — fires on SIGINT, SIGTERM, and EXIT.
# When invoked via the signal traps below it gets an explicit exit-code
# argument (130/143). Inside a trap bash's $? reflects the *previous*
# command, not the signal, so we can't rely on $? alone to distinguish
# a user-initiated stop from a normal EXIT.
cleanup() {
    local trap_exit_code=${1:-$?}

    # Reentrancy guard — prevent double execution from EXIT + signal combination
    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    # WSL-2: Kill pipeline children to prevent spurious exit-code-130 log spam
    if [[ -n "${RALPH_PIPELINE_PID:-}" ]]; then
        kill -- -"$RALPH_PIPELINE_PID" 2>/dev/null || kill "$RALPH_PIPELINE_PID" 2>/dev/null || true
        wait "$RALPH_PIPELINE_PID" 2>/dev/null || true
    fi

    # MCP-CLEANUP: Kill orphaned MCP server processes on exit
    ralph_cleanup_orphaned_mcp 2>/dev/null || true

    # CAPTURE-1: Sync filesystem to flush buffered writes on SIGTERM
    sync 2>/dev/null || true

    # UPKEEP-2: Emit MCP failure summary at session end
    ralph_mcp_failure_summary 2>/dev/null || true

    if [[ $loop_count -gt 0 ]]; then
        if [[ $trap_exit_code -eq 130 || $trap_exit_code -eq 143 ]]; then
            # SIGINT (130) / SIGTERM (143) — user-initiated stop, not a crash.
            # Without the explicit `exit` the trap returns and bash resumes the
            # main loop, so `kill <pid>` silently spawns one more iteration.
            log_status "INFO" "Ralph stopped by signal (exit code: $trap_exit_code)"
            # TAP-924: Clear coordinator session+brief on SIGINT/SIGTERM so a
            # restart starts fresh. Main Claude session is preserved — the
            # operator may want to resume mid-task on the same conversation.
            ralph_clear_coordinator_artifacts 2>/dev/null || true
            update_status "$loop_count" "$(_read_call_count)" "stopped" "signal" "exit_code_$trap_exit_code"
            exit "$trap_exit_code"
        elif [[ $trap_exit_code -ne 0 ]]; then
            # LOGFIX-1: Check if status was already set to graceful_exit/completed
            # before reporting a crash. The break from the exit gate can leave a
            # non-zero $? from intermediate commands (hook rejections, etc.)
            local current_status
            current_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
            if [[ "$current_status" == "graceful_exit" || "$current_status" == "completed" ]]; then
                log_status "INFO" "Ralph exited gracefully (ignoring intermediate exit code: $trap_exit_code)"
            else
                log_status "ERROR" "Ralph loop crashed (exit code: $trap_exit_code)"
                update_status "$loop_count" "$(_read_call_count)" "crashed" "error" "exit_code_$trap_exit_code"
                # Record crash for startup detection
                echo "$trap_exit_code" > "$RALPH_DIR/.last_crash_code"
            fi
        else
            # Normal exit (code 0) — check if status was properly updated
            local current_status
            current_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
            if [[ "$current_status" == "running" ]]; then
                log_status "WARN" "Ralph exited normally but status still 'running' — possible silent crash"
                update_status "$loop_count" "$(_read_call_count)" "unexpected_exit" "stopped"
            fi
        fi
    fi
}

# Set up signal handlers. Pass an explicit exit code into cleanup() for
# signals so the signal branch in cleanup() actually fires — bash's $?
# inside a trap holds the previous command's status, not the signal.
trap 'cleanup 130' SIGINT
trap 'cleanup 143' SIGTERM
trap cleanup EXIT

# =============================================================================
# LOCK-1: Flock-Based Instance Locking (Phase 13)
# Prevents multiple Ralph instances from running on the same project.
# Uses flock(2) kernel syscall — atomic, no TOCTOU race, auto-releases on exit.
# =============================================================================

LOCKFILE="${RALPH_DIR}/.ralph.lock"

acquire_instance_lock() {
    if ! command -v flock &>/dev/null; then
        # Fallback for systems without flock (macOS without util-linux)
        log_status "WARN" "flock not available — instance locking disabled"
        log_status "WARN" "Install util-linux for concurrent instance prevention"
        return 0
    fi

    # Open file descriptor 99 for the lock file (high FD avoids conflicts — BashFAQ/045)
    exec 99>"$LOCKFILE"

    if ! flock -n 99; then
        local existing_pid
        existing_pid=$(cat "$LOCKFILE" 2>/dev/null | head -1)

        # LOGFIX-2: Auto-terminate stale instances instead of just advising manual kill
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            log_status "WARN" "Terminating existing Ralph instance (PID: $existing_pid)"
            kill "$existing_pid" 2>/dev/null || true
            # Wait up to 5 seconds for graceful shutdown
            local wait_count=0
            while kill -0 "$existing_pid" 2>/dev/null && [[ $wait_count -lt 5 ]]; do
                sleep 1
                ((wait_count++)) || true
            done
            # Force kill if still alive
            if kill -0 "$existing_pid" 2>/dev/null; then
                log_status "WARN" "Force-killing stale Ralph instance (PID: $existing_pid)"
                kill -9 "$existing_pid" 2>/dev/null || true
                sleep 1
            fi
            # Retry acquiring the lock
            if ! flock -n 99; then
                echo "[ERROR] Could not acquire lock after terminating PID $existing_pid" >&2
                echo "[ERROR] Project: $(pwd)" >&2
                echo "[ERROR] Lock: $LOCKFILE" >&2
                exit 1
            fi
            log_status "INFO" "Lock acquired after terminating previous instance"
        else
            echo "[ERROR] Another Ralph instance holds the lock (PID: ${existing_pid:-unknown})" >&2
            echo "[ERROR] Project: $(pwd)" >&2
            echo "[ERROR] Lock: $LOCKFILE" >&2
            echo "" >&2
            echo "If the process is gone, the lock auto-releases. Otherwise:" >&2
            echo "  kill ${existing_pid:-<pid>}    # Stop the other instance" >&2
            echo "  ralph --status        # Check current state" >&2
            exit 1
        fi
    fi

    # Write PID for informational display only (flock manages actual locking)
    echo $$ > "$LOCKFILE"
    log_status "INFO" "Acquired instance lock (PID: $$)"
}

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Session guard: tell .ralph/hooks/on-stop.sh that this Stop event came
    # from an autonomous ralph loop, not an interactive Claude Code session
    # sharing the same .claude/settings.json. Without this export, every
    # interactive session in a ralph-managed repo increments
    # .no_status_block_count, mutates status.json, and accumulates
    # session_cost_usd against the autonomous run's tally — observed in
    # ralph-claude-code (May 2026): 885 interactive Stop events tallied
    # $16,489 against zero ralph iterations.
    export RALPH_LOOP_ACTIVE=1

    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
        fi
    fi

    # Load JSON configuration (takes precedence over .ralphrc)
    if load_json_config; then
        if [[ "$JSON_CONFIG_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from ralph.config.json"
        fi
    fi

    # TAP-779: Fail fast on missing PROMPT.md — before any expensive startup work
    # (instance lock, MCP probes, version checks). Without task instructions Claude
    # loops blind, never emits a RALPH_STATUS block, and the dual-condition exit
    # gate never fires. Also handles old flat-structure projects that pre-date
    # the .ralph/ migration.
    #
    # Note: `.ralph/logs` is created during script source (line 601), so we can't
    # use `! -d ".ralph"` as the migration signal — it would always be false.
    # Instead detect flat structure as "root PROMPT.md present AND .ralph/PROMPT.md
    # absent", which is the actual pre-v0.10.0 layout.
    if [[ -f "PROMPT.md" ]] && [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo ""
        echo "Ralph v0.10.0+ uses a .ralph/ subfolder to keep your project root clean."
        echo ""
        echo "To upgrade your project, run:"
        echo "  ralph-migrate"
        echo ""
        echo "This will move Ralph-specific files to .ralph/ while preserving src/ at root."
        echo "A backup will be created before migration."
        exit 1
    fi
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        if [[ -f "$RALPH_DIR/fix_plan.md" ]] || [[ -d "$RALPH_DIR/specs" ]] || [[ -f "$RALPH_DIR/AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing .ralph/PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi
        echo ""
        echo "To fix this:"
        echo "  1. Enable Ralph in existing project: ralph-enable"
        echo "  2. Create a new project: ralph-setup my-project"
        echo "  3. Import existing requirements: ralph-import requirements.md"
        echo "  4. Navigate to an existing Ralph project directory"
        echo "  5. Or create .ralph/PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/, src/, etc."
        exit 1
    fi

    # LOCK-1: Acquire instance lock (prevents concurrent Ralph instances on same project)
    acquire_instance_lock

    # Issue #211: source the user's shell init file before validating the CLI.
    # Use case: zsh/Nix/asdf users whose `claude` lives on a PATH that is only
    # set in ~/.zshrc — bash startup wouldn't pick it up otherwise.
    if [[ -n "${RALPH_SHELL_INIT_FILE:-}" ]]; then
        if [[ -f "$RALPH_SHELL_INIT_FILE" ]]; then
            # shellcheck source=/dev/null
            source "$RALPH_SHELL_INIT_FILE"
            log_status "INFO" "Sourced shell init file: $RALPH_SHELL_INIT_FILE"
        else
            log_status "WARN" "RALPH_SHELL_INIT_FILE not found: $RALPH_SHELL_INIT_FILE"
        fi
    fi

    # Validate Claude Code CLI is available before starting
    if ! validate_claude_command; then
        log_status "ERROR" "Claude Code CLI not found: $CLAUDE_CODE_CMD"
        exit 1
    fi

    # Check CLI version compatibility and auto-update (Issue #190)
    check_claude_version
    check_claude_updates

    # Check for WSL/Windows version divergence
    check_version_divergence

    # Setup agent teams if enabled (Phase 4 — Experimental)
    setup_teams

    # UPKEEP-2: Initialize MCP failure tracking for this session
    ralph_init_mcp_tracking

    # TAP-584 (epic TAP-583): Probe global MCP availability so downstream stories
    # (TAP-585 prompt guidance, TAP-588 counters) can gate on the result.
    ralph_probe_mcp_servers

    # BRAIN-PHASE-B1: clear the session-scoped kill-switch so a new run isn't
    # stuck disabled from a prior session's HTTP failure. The switch re-arms
    # on the first failing write in this session.
    declare -F brain_client_clear_session_disable >/dev/null 2>&1 && \
        brain_client_clear_session_disable "$RALPH_DIR"

    # XPLAT-2: Validate hooks at startup
    ralph_validate_hooks

    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"

    # Surface model-routing health at startup. The "default false" regression in
    # lib/complexity.sh silently pinned every loop to CLAUDE_MODEL=opus and
    # bled ~$57/loop without any visible signal. Make routing state visible
    # *and* check whether prior loops actually logged decisions when enabled.
    if [[ "${RALPH_MODEL_ROUTING_ENABLED:-true}" == "true" ]]; then
        log_status "INFO" "Model routing: ENABLED (per-task type + QA escalation)"
        local _routing_log="$RALPH_DIR/.model_routing.jsonl"
        if [[ -f "$_routing_log" ]]; then
            local _routing_entries
            _routing_entries=$(wc -l <"$_routing_log" 2>/dev/null | tr -cd '0-9')
            _routing_entries=${_routing_entries:-0}
            local _now=$(date +%s)
            local _mtime
            _mtime=$(stat -c %Y "$_routing_log" 2>/dev/null || stat -f %m "$_routing_log" 2>/dev/null || echo "$_now")
            local _age=$((_now - _mtime))
            # Old log file while routing is on. Most often this just means
            # no productive loops have run since the prior session — a stale
            # log does not imply routing is disabled (the default in
            # lib/complexity.sh is `true`). Surface it as INFO so operators
            # don't chase a non-existent default-drift bug.
            if [[ "$_age" -gt 3600 ]]; then
                log_status "INFO" "Model routing log .model_routing.jsonl has not been written in $((_age / 60))min ($_routing_entries entries). Routing is enabled; this just means no productive loops have appended a decision since then. A new entry will appear on the next task pickup."
            fi
        fi
    else
        log_status "WARN" "Model routing: DISABLED — every loop will run on CLAUDE_MODEL=${CLAUDE_MODEL:-(unset)}. Set RALPH_MODEL_ROUTING_ENABLED=true in .ralphrc to control cost."
    fi

    # PROMPT.md / flat-structure checks run early (TAP-779) — fail fast before
    # MCP probes or lock acquisition, so a misconfigured project doesn't burn
    # 10–20 s of startup work before erroring.

    # File integrity validation removed — PreToolUse hooks handle file protection
    # (protect-ralph-files.sh blocks edits to .ralph/, validate-command.sh blocks destructive commands)

    # Initialize session tracking before entering the loop
    init_session_tracking

    # Detect previous crash (LOOP-5)
    # Save crash info before circuit breaker reset (which checks this file)
    local _had_crash=false
    if [[ -f "$RALPH_DIR/.last_crash_code" ]]; then
        local last_crash_code
        last_crash_code=$(cat "$RALPH_DIR/.last_crash_code" 2>/dev/null || echo "unknown")
        log_status "WARN" "Previous Ralph invocation crashed (exit code: $last_crash_code)"
        _had_crash=true
    fi

    # Detect stale "running" status from a crashed run
    if [[ -f "$STATUS_FILE" ]]; then
        local stale_status
        stale_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
        if [[ "$stale_status" == "running" ]]; then
            log_status "WARN" "Previous run left status as 'running' — likely crashed during execution"
        fi
    fi

    # Reset exit signals to prevent stale state from prior run causing premature exit (Issue #194)
    # This is unconditional: regardless of how the previous run ended (crash, SIGKILL, API limit exit),
    # every new ralph invocation starts with a clean exit-signal slate.
    # However, if task source is already 100% complete, pre-seed completion_indicators with 1
    # so only 1 more EXIT_SIGNAL: true loop is needed (avoids zombie verification loops).
    local _pre_uncompleted=1
    if [[ "${RALPH_TASK_SOURCE:-file}" == "linear" ]]; then
        # TAP-664: Resolve RALPH_LINEAR_PROJECT name → project UUID ONCE at
        # startup. Without this, `name.eq` filtering is case/whitespace-sensitive
        # and silently returns 0 issues when the configured name drifts from
        # Linear's actual project name — which the TAP-536 fail-loud guard
        # cannot distinguish from a legitimate empty backlog, leading to a
        # bogus plan_complete exit on a populated project.
        if [[ -n "${LINEAR_API_KEY:-}" ]] && declare -F linear_init >/dev/null 2>&1; then
            linear_init || log_status "ERROR" "Linear init failed — queries will fall back to name-filter (vulnerable to whitespace/case mismatch)"
        fi

        # TAP-591 (LINOPT-2): Fire the cache-locality optimizer in the background.
        # Writes .ralph/.linear_next_issue for build_loop_context() to consume.
        # Background fire-and-forget: the hint is read on the first list_issues
        # consultation, so blocking startup is unnecessary.
        if declare -F linear_optimizer_run >/dev/null 2>&1; then
            linear_optimizer_run 2>>"${LOG_DIR}/ralph.log" &
        fi

        # TAP-536: API failure here defaults to "1 incomplete" (the safe answer
        # — never pre-seeds completion_indicators on failure, so we don't get a
        # zombie 1-loop verification cycle when Linear is down at startup).
        local _pre_completed _pre_lvl="WARN" _pre_stderr=""
        if [[ -z "${LINEAR_API_KEY:-}" ]]; then _pre_lvl="INFO"; _pre_stderr="/dev/null"; fi
        if ! _pre_uncompleted=$(linear_get_open_count 2>"${_pre_stderr:-/dev/stderr}"); then
            log_status "$_pre_lvl" "Linear count (open_count) unavailable at startup pre-seed — assuming incomplete" >&2
            _pre_uncompleted=1
        fi
        if ! _pre_completed=$(linear_get_done_count 2>"${_pre_stderr:-/dev/stderr}"); then
            log_status "$_pre_lvl" "Linear count (done_count) unavailable at startup pre-seed — assuming none done" >&2
            _pre_completed=0
        fi
        if [[ $_pre_completed -eq 0 ]]; then
            _pre_uncompleted=1  # No tasks at all — treat as incomplete
        fi
    elif [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        _pre_uncompleted=$(grep -cE '^\s*- \[ \]' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || _pre_uncompleted=0
        local _pre_completed
        _pre_completed=$(grep -cE '^\s*- \[[xX]\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || _pre_completed=0
        if [[ $_pre_completed -eq 0 ]]; then
            _pre_uncompleted=1  # No tasks at all — treat as incomplete
        fi
    fi

    if [[ $_pre_uncompleted -eq 0 ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [0]}' > "$EXIT_SIGNALS_FILE"
        log_status "INFO" "Reset exit signals for fresh start (pre-seeded: fix_plan 100% complete)"
    else
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        log_status "INFO" "Reset exit signals for fresh start"
    fi

    # SESSION-SCOPE: Generate a unique run ID for this Ralph invocation.
    # Written to .ralph_run_id so on-stop.sh can detect session boundaries and
    # reset session-accumulator fields (cost, tokens, subagents) in status.json
    # instead of inheriting stale totals from a previous (possibly killed) run.
    local _run_id
    _run_id="$(date +%s 2>/dev/null || echo "0")${RANDOM}"
    printf '%s\n' "$_run_id" > "$RALPH_DIR/.ralph_run_id"

    # Zero out session accumulator fields in status.json so on-stop.sh starts
    # fresh. Merge onto the existing file so other fields (circuit breaker,
    # linear_*, last_action) survive the restart.
    if [[ -f "$STATUS_FILE" ]] && command -v jq &>/dev/null; then
        local _sreset_tmp
        _sreset_tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
        jq --arg rid "$_run_id" \
           '.ralph_run_id = $rid |
            .session_cost_usd = 0 |
            .session_input_tokens = 0 |
            .session_output_tokens = 0 |
            .session_cache_read_tokens = 0 |
            .session_cache_create_tokens = 0 |
            .session_subagents = {} |
            .session_mcp_calls = {"tapps_mcp":0,"docs_mcp":0,"by_tool":{}}' \
           "$STATUS_FILE" > "$_sreset_tmp" 2>/dev/null \
        && mv "$_sreset_tmp" "$STATUS_FILE" \
        || rm -f "$_sreset_tmp" 2>/dev/null
    elif command -v jq &>/dev/null; then
        jq -n --arg rid "$_run_id" \
           '{ralph_run_id: $rid,
             session_cost_usd: 0, session_input_tokens: 0, session_output_tokens: 0,
             session_cache_read_tokens: 0, session_cache_create_tokens: 0,
             session_subagents: {}, session_mcp_calls: {"tapps_mcp":0,"docs_mcp":0,"by_tool":{}}}' \
           > "$STATUS_FILE" 2>/dev/null || true
    fi
    log_status "INFO" "Session run ID: $_run_id"

    # Reset circuit breaker for new session
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        if [[ "$_had_crash" == "true" ]]; then
            # Genuine crash — preserve OPEN/CLOSED state, only reset counters
            if jq '.consecutive_no_progress = 0 |
                .consecutive_same_error = 0 |
                .consecutive_permission_denials = 0 |
                .current_loop = 0 |
                .last_progress_loop = 0' \
                "$RALPH_DIR/.circuit_breaker_state" > "${RALPH_DIR}/.circuit_breaker_state.tmp" 2>/dev/null && \
                mv "${RALPH_DIR}/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
            then
                log_status "INFO" "Reset circuit breaker counters for new session (state preserved after crash)"
            fi
        else
            # Clean restart (signal exit or normal exit) — reset to CLOSED
            local prev_state
            prev_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
            if jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)" \
                '.state = "CLOSED" |
                .consecutive_no_progress = 0 |
                .consecutive_same_error = 0 |
                .consecutive_permission_denials = 0 |
                .current_loop = 0 |
                .last_progress_loop = 0 |
                .last_change = $ts |
                .reason = "Fresh start (clean restart)"' \
                "$RALPH_DIR/.circuit_breaker_state" > "${RALPH_DIR}/.circuit_breaker_state.tmp" 2>/dev/null && \
                mv "${RALPH_DIR}/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
            then
                if [[ "$prev_state" != "CLOSED" ]]; then
                    log_status "INFO" "Circuit breaker reset to CLOSED (was $prev_state, clean restart)"
                else
                    log_status "INFO" "Reset circuit breaker for new session"
                fi
            fi
        fi
    fi

    # Clean up crash code file after circuit breaker has consumed it
    rm -f "$RALPH_DIR/.last_crash_code" 2>/dev/null

    # Optional: warn if Docker MCP containers (label ralph.mcp=true) are not running
    if command -v docker >/dev/null 2>&1; then
        local mcp_containers_down=()
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
                mcp_containers_down+=("$container")
            fi
        done < <(docker ps -a --filter "label=ralph.mcp=true" --format '{{.Names}}' 2>/dev/null)

        if [[ ${#mcp_containers_down[@]} -gt 0 ]]; then
            log_status "WARN" "MCP containers not running: ${mcp_containers_down[*]}"
            log_status "INFO" "Start with: docker compose up -d (or check docker-compose.yml)"
        fi
    fi

    # Persistent loop counter — tracks total loops across restarts (LOOP-5)
    local persistent_loop_file="$RALPH_DIR/.total_loop_count"
    local persistent_loops=0
    if [[ -f "$persistent_loop_file" ]]; then
        persistent_loops=$(cat "$persistent_loop_file" 2>/dev/null || echo "0")
        persistent_loops=$((persistent_loops + 0))
    fi

    # Perform initial log rotation at startup
    rotate_ralph_log
    cleanup_old_output_logs
    ralph_rotate_audit_log 2>/dev/null

    # WSL-1: Clean stale temp files from previous runs (cross-fs orphans)
    find "$RALPH_DIR" -name "status.json.*" -mmin +60 -delete 2>/dev/null || true
    find "$RALPH_DIR" -name ".circuit_breaker_state.*" -mmin +60 -delete 2>/dev/null || true

    if [[ "$DRY_RUN" == "true" ]]; then
        log_status "INFO" "DRY-RUN MODE: No API calls will be made"
    fi

    log_status "INFO" "Starting main loop..."

    # CTXMGMT-3: Initialize session tracking for Continue-As-New
    _session_start_epoch=$(date +%s)
    _session_iteration_count=0

    while true; do
        loop_count=$((loop_count + 1))
        persistent_loops=$((persistent_loops + 1))
        # TAP-535: atomic_write so the lifetime loop counter cannot be zeroed
        # by a SIGTERM landing between the redirection's truncate and write.
        atomic_write "$persistent_loop_file" "$persistent_loops" || log_status "ERROR" "Failed to persist persistent_loop_file"

        # CTXMGMT-3: Track per-session iteration count
        _session_iteration_count=$((_session_iteration_count + 1))

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count (total: #$persistent_loops) - calling init_call_tracking..."
        init_call_tracking

        log_status "LOOP" "=== Starting Loop #$loop_count (total: #$persistent_loops) ==="

        # OTEL-1/3: Start trace for this iteration
        export LOOP_COUNT="$loop_count"
        declare -f ralph_trace_start &>/dev/null && ralph_trace_start

        # SKILLS-INJECT-7: Periodic Tier A skill re-detection (every N loops)
        declare -f skill_retro_periodic_reconcile &>/dev/null && \
            skill_retro_periodic_reconcile "$loop_count" "$PWD" 2>/dev/null || true

        # FAILSPEC-4: Audit log — loop iteration start
        ralph_audit "loop_start" "ralph_loop" "begin_iteration" "loop_count=$loop_count,total=$persistent_loops" "started" 2>/dev/null

        # File integrity validation removed — PreToolUse hooks handle file protection in real-time

        # FAILSPEC-3: Check killswitch file sentinel before proceeding
        if ! ralph_check_killswitch; then
            ralph_audit "killswitch" "operator" "emergency_halt" "killswitch_file_detected" "halted" 2>/dev/null
            update_status "$loop_count" "$(_read_call_count)" "killswitch" "halted" "killswitch_activated"
            log_status "ERROR" "KILLSWITCH file detected - emergency halt"
            break
        fi

        # TAP-1528 / TAP-1529: harness halt sentinel set by on-stop.sh when
        # consecutive RALPH_STATUS-missing responses or CB-OPEN thrashing is
        # detected. Resists CB_AUTO_RESET — operator must clear the file
        # after fixing the cause.
        if [[ -f "$RALPH_DIR/.harness_halt_reason" ]]; then
            local halt_reason
            halt_reason=$(cat "$RALPH_DIR/.harness_halt_reason" 2>/dev/null || echo "unknown")
            ralph_audit "harness_halt" "on_stop_hook" "halt_execution" "reason=$halt_reason,loop_count=$loop_count" "halted" 2>/dev/null
            update_status "$loop_count" "$(_read_call_count)" "harness_halt" "halted" "$halt_reason"
            log_status "ERROR" "🛑 Harness halt: $halt_reason"
            log_status "INFO" "  Clear .ralph/.harness_halt_reason after diagnosing the root cause to resume."
            break
        fi

        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            ralph_audit "circuit_breaker" "circuit_breaker" "halt_execution" "state=OPEN,loop_count=$loop_count" "halted" 2>/dev/null
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(_read_call_count)" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            # Handle permission_denied specially (Issue #101)
            if [[ "$exit_reason" == "permission_denied" ]]; then
                log_status "ERROR" "🚫 Permission denied - halting loop"
                reset_session "permission_denied"
                update_status "$loop_count" "$(_read_call_count)" "permission_denied" "halted" "permission_denied"

                # Display helpful guidance for resolving permission issues
                echo ""
                echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  PERMISSION DENIED - Loop Halted                          ║${NC}"
                echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}Claude Code was denied permission to execute commands.${NC}"
                echo ""
                echo -e "${YELLOW}To fix this:${NC}"
                echo "  Permissions are controlled by the agent file and the bash command hook."
                echo ""
                echo "  1. Edit .claude/agents/ralph.md — adjust 'disallowedTools' (blocklist)."
                echo "     Add a Bash(...) pattern to block a command, or remove one to allow it."
                echo ""
                echo "  2. Edit .claude/hooks/validate-command.sh — this PreToolUse hook"
                echo "     blocks specific bash patterns at the harness layer regardless"
                echo "     of agent settings (e.g. 'rm -rf', 'git reset --hard')."
                echo ""
                echo -e "${YELLOW}After updating:${NC}"
                echo "  ralph --reset-session  # Clear stale session state"
                echo "  ralph --monitor        # Restart the loop"
                echo ""

                break
            fi

            ralph_audit "exit_decision" "exit_gate" "graceful_exit" "reason=$exit_reason,loop_count=$loop_count" "completed" 2>/dev/null
            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(_read_call_count)" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(_read_call_count)"
            log_status "INFO" "  - Exit reason: $exit_reason"

            break
        fi
        
        # Rotate logs periodically (every 10 iterations to reduce stat overhead)
        if (( loop_count % 10 == 0 )); then
            rotate_ralph_log
        fi

        # Update status
        local calls_made=$(_read_call_count)
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Dry-run mode: simulate execution without calling Claude Code
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run_simulate "" "$loop_count"
            log_status "INFO" "[DRY-RUN] Loop #$loop_count complete. Exiting after single dry-run iteration."
            break
        fi

        # TAP-915: spawn coordinator to populate .ralph/brief.json before the
        # main agent runs. Best-effort — failure does not block the loop.
        ralph_spawn_coordinator "$loop_count"

        # Execute Claude Code
        execute_claude_code "$loop_count"
        local exec_result=$?
        
        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(_read_call_count)" "completed" "success"
            # GUARD-2: Reset consecutive timeout counter on successful completion
            CONSECUTIVE_TIMEOUT_COUNT=0
            # LOGFIX-4: Reset fast failure counter on success
            CONSECUTIVE_FAST_FAILURE_COUNT=0

            # Brief pause between successful executions (reduced from 5s in v1.8.5)
            sleep 2

            # CTXMGMT-3: Check if session should be reset for context freshness
            if ralph_should_continue_as_new; then
                ralph_continue_as_new
            fi
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(_read_call_count)" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 4 ]; then
            # Monthly Anthropic API spend cap — terminal until the reset date.
            # Sleeping for days/weeks is not viable; surface the date and halt cleanly.
            # Trip the circuit breaker so a future restart sees OPEN until manually cleared.
            reset_session "monthly_api_spend_cap"
            local _cap_date="${MONTHLY_CAP_DATE:-unknown}"
            local _total_opens
            _total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
            _total_opens=$((_total_opens + 1))
            cat > "$CB_STATE_FILE" << CBEOF
{
    "state": "$CB_STATE_OPEN",
    "last_change": "$(get_iso_timestamp)",
    "opened_at": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "total_opens": $_total_opens,
    "reason": "monthly_api_spend_cap: access returns ${_cap_date}"
}
CBEOF
            update_status "$loop_count" "$(_read_call_count)" "monthly_cap" "stopped" "monthly_api_spend_cap"

            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  MONTHLY API SPEND CAP REACHED                            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Your Anthropic monthly spend limit has been hit.${NC}"
            echo -e "${YELLOW}Access returns: ${GREEN}${_cap_date}${NC}"
            echo ""
            echo -e "${YELLOW}Next steps:${NC}"
            echo -e "  ${GREEN}•${NC} Raise the cap at console.anthropic.com → Limits, then run 'ralph --reset-circuit' and re-run."
            echo -e "  ${GREEN}•${NC} Or wait until ${_cap_date} and re-run 'ralph'."
            echo ""
            log_status "ERROR" "🛑 Halting loop — monthly API spend cap (returns ${_cap_date})"
            break
        elif [ $exec_result -eq 2 ]; then
            # Issue #102: API plan limit / Extra Usage exhaustion — parse reset time and auto-sleep
            update_status "$loop_count" "$(_read_call_count)" "api_limit" "paused"
            log_status "WARN" "🛑 Claude API usage limit reached!"

            # Try to extract reset time from the output (e.g., "resets 9pm", "try back in 3 hours")
            local reset_hint=""
            local wait_minutes=60  # default: 1 hour
            if [[ -f "$output_file" ]]; then
                # "resets 9pm" pattern (Extra Usage)
                reset_hint=$(tail -30 "$output_file" 2>/dev/null | grep -oiE 'resets?\s+[0-9]{1,2}\s*(am|pm)' | tail -1)
                if [[ -n "$reset_hint" ]]; then
                    local reset_hour
                    reset_hour=$(echo "$reset_hint" | grep -oE '[0-9]+')
                    local reset_ampm
                    reset_ampm=$(echo "$reset_hint" | grep -oiE 'am|pm')
                    # Convert to 24h and calculate wait
                    if [[ "${reset_ampm,,}" == "pm" && "$reset_hour" -ne 12 ]]; then
                        reset_hour=$((reset_hour + 12))
                    elif [[ "${reset_ampm,,}" == "am" && "$reset_hour" -eq 12 ]]; then
                        reset_hour=0
                    fi
                    local current_hour=$(date +%H)
                    local current_min=$(date +%M)
                    local mins_until=$(( (reset_hour * 60 - current_hour * 60 - current_min + 1440) % 1440 ))
                    [[ $mins_until -le 0 ]] && mins_until=60
                    [[ $mins_until -gt 360 ]] && mins_until=60  # cap at 6h, fallback
                    wait_minutes=$mins_until
                fi
                # "try back in N hours" pattern
                if [[ -z "$reset_hint" ]]; then
                    reset_hint=$(tail -30 "$output_file" 2>/dev/null | grep -oiE 'try.*(back|again).*in\s+[0-9]+\s*hour' | tail -1)
                    if [[ -n "$reset_hint" ]]; then
                        local hours_back
                        hours_back=$(echo "$reset_hint" | grep -oE '[0-9]+' | tail -1)
                        [[ -n "$hours_back" && "$hours_back" -gt 0 ]] && wait_minutes=$((hours_back * 60))
                    fi
                fi
            fi

            local wait_h=$((wait_minutes / 60))
            local wait_m=$((wait_minutes % 60))
            local resume_time
            resume_time=$(date -d "+${wait_minutes} minutes" '+%H:%M' 2>/dev/null || date -v+${wait_minutes}M '+%H:%M' 2>/dev/null || echo "~${wait_h}h ${wait_m}m from now")

            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  PLAN LIMIT EXHAUSTED                                     ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Your Claude plan credits have been exhausted.${NC}"
            [[ -n "$reset_hint" ]] && echo -e "${YELLOW}Detected reset info: ${reset_hint}${NC}"
            echo -e "${YELLOW}Estimated resume time: ${GREEN}${resume_time}${NC} (${wait_minutes} minutes)"
            echo ""
            echo -e "${YELLOW}Options:${NC}"
            echo -e "  ${GREEN}1)${NC} Auto-sleep until credits reset (${wait_minutes} min)"
            echo -e "  ${GREEN}2)${NC} Exit the loop"
            echo -e "\n${BLUE}Choose an option (1 or 2) [auto-sleep in 30s]:${NC} "

            read -t 30 -n 1 user_choice || true
            echo

            if [[ "$user_choice" == "2" ]]; then
                log_status "INFO" "User chose to exit. Exiting loop..."
                reset_session "api_limit_exit"
                update_status "$loop_count" "$(_read_call_count)" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                log_status "INFO" "Auto-sleeping for $wait_minutes minutes until credit reset (~$resume_time)..."
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}💤 Ralph sleeping — credits reset in: %02d:%02d — resume ~${resume_time}${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
                log_status "INFO" "Credit reset period complete. Resuming loop..."
            fi
        else
            update_status "$loop_count" "$(_read_call_count)" "failed" "error"

            # LOGFIX-4: Fast-trip circuit breaker on broken invocations
            # Detect rapid failures with 0 tool calls (e.g., missing stdin, bad prompt).
            # NOTE: invocation_start_epoch is local-scoped inside execute_claude_code, so
            # the function exports LAST_INVOCATION_DURATION for us to read here.
            local _exec_duration=${LAST_INVOCATION_DURATION:-30}
            if [[ ${LAST_TOOL_COUNT:-0} -eq 0 && $_exec_duration -lt 30 ]]; then
                CONSECUTIVE_FAST_FAILURE_COUNT=$((CONSECUTIVE_FAST_FAILURE_COUNT + 1))
                log_status "WARN" "Fast failure detected: 0 tools, ${_exec_duration}s ($CONSECUTIVE_FAST_FAILURE_COUNT/$MAX_CONSECUTIVE_FAST_FAILURES)"
                if [[ "$CONSECUTIVE_FAST_FAILURE_COUNT" -ge "$MAX_CONSECUTIVE_FAST_FAILURES" ]]; then
                    log_status "ERROR" "Fast-trip: $MAX_CONSECUTIVE_FAST_FAILURES consecutive instant failures (0 tools, <30s each)"
                    log_status "ERROR" "Likely cause: prompt construction failure or CLI misconfiguration"
                    local total_opens
                    total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
                    total_opens=$((total_opens + 1))
                    cat > "$CB_STATE_FILE" << CBEOF
{
    "state": "$CB_STATE_OPEN",
    "last_change": "$(get_iso_timestamp)",
    "opened_at": "$(get_iso_timestamp)",
    "consecutive_no_progress": $CONSECUTIVE_FAST_FAILURE_COUNT,
    "total_opens": $total_opens,
    "reason": "fast_trip: $MAX_CONSECUTIVE_FAST_FAILURES consecutive instant failures (0 tools)"
}
CBEOF
                    reset_session "fast_trip_circuit_breaker"
                    update_status "$loop_count" "$(_read_call_count)" "circuit_breaker_open" "halted" "fast_trip"
                    break
                fi
            else
                CONSECUTIVE_FAST_FAILURE_COUNT=0
            fi

            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        # OTEL-3/4: Record trace cost and export spans at end of iteration
        if declare -f ralph_trace_record_cost &>/dev/null; then
            # Extract model from status.json or default to sonnet
            local _trace_model="sonnet"
            if [[ -f "${RALPH_DIR}/status.json" ]]; then
                local _sm
                _sm=$(jq -r '.model // empty' "${RALPH_DIR}/status.json" 2>/dev/null || true)
                [[ -n "$_sm" ]] && _trace_model="$_sm"
            fi
            # Token counts are not yet tracked in status.json;
            # record with zeros so cost_file tracks iterations.
            # When token extraction is added upstream, pass real values here.
            ralph_trace_record_cost "$_trace_model" "0" "0"
        fi
        declare -f ralph_otlp_export &>/dev/null && ralph_otlp_export

        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Claude Code

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -V, --version           Show version and exit
    --mcp-status            Probe configured MCP servers (tapps-mcp, docs-mcp, tapps-brain) and exit
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Show Claude Code output in real-time (auto-switches to JSON output)
    -t, --timeout MIN       Set Claude Code execution timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup (bypasses cooldown)
    --optimize-linear       Run Linear cache-locality optimizer once and exit (TAP-594)
    --reset-session         Reset session state and exit (clears session continuity)

Modern CLI Options (Phase 1.1):
    --output-format FORMAT  Set Claude output format: json or text (default: $CLAUDE_OUTPUT_FORMAT)
                            Note: --live mode requires JSON and will auto-switch
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CLAUDE_SESSION_EXPIRY_HOURS)
    --dry-run               Preview loop execution without calling Claude Code API
    --log-max-size MB       Set max ralph.log size before rotation (default: $LOG_MAX_SIZE_MB)
    --log-max-files NUM     Set max rotated log files to keep (default: $LOG_MAX_FILES)

SDK Mode (Phase 6 — v1.3.0):
    --sdk                   Run in SDK mode (Python Agent SDK instead of bash loop)
    --sdk-model MODEL       Set Claude model for SDK mode (default: claude-sonnet-4-6)
    --sdk-max-turns NUM     Set max turns per iteration in SDK mode (default: 50)

Observability (Phase 8 — v1.5.0):
    --stats                 Show metrics summary and exit
    --stats-json            Show metrics as JSON and exit
    --stats-last PERIOD     Filter metrics by period (e.g., 7d, 30d, 24h)
    --rollback              Restore latest backup with confirmation
    --rollback-list         Show available backups

GitHub Issues (Phase 10 — v1.7.0):
    --issue NUM             Import GitHub issue into fix_plan.md
    --issues                List open GitHub issues
    --issue-label LABEL     Filter issues by label
    --issue-assignee USER   Filter issues by assignee
    --assess-only           Show issue assessment without importing
    --batch                 Process multiple issues sequentially
    --batch-issues NUMS     Comma-separated issue numbers for batch
    --stop-on-failure       Stop batch processing on first failure

Cost Optimization (Phase 14):
    --cost-dashboard        Show unified cost dashboard and exit
    --costs                 Alias for --cost-dashboard

Monorepo (Issue #163):
    --service NAME          Scope Ralph to a monorepo service directory

Beads Integration (Issue #87):
    --beads                 Shortcut: set TASK_SOURCES="beads"

Windows (Issue #156):
    --wt                    Use Windows Terminal split panes instead of tmux (auto-detected)

Sandbox (Phase 11 — v1.8.0):
    --sandbox               Run loop inside Docker container
    --sandbox-required      Fail if Docker not available (instead of fallback)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Behavior notes (v1.2.0+):
    - --live uses stream-json output: full stream preserved (*_stream.log), result line
      extracted when possible; WSL2/NTFS mounts retry file visibility before extraction.
    - Before each loop iteration: JSONL stream extraction isolates the result object;
      permission denials and failed MCP servers logged from raw output.
    - Analysis via on-stop.sh hook → status.json (RALPH_STATUS fields auto-unescaped).
    - Subagent result objects are filtered from multi-result count (no false violations).
    - New ralph invocation resets circuit breaker *counters* (not OPEN/CLOSED state).
    - Stale temp files (status.json.*, .circuit_breaker_state.*) cleaned on startup.
    - Pipeline children are killed cleanly on SIGINT (no spurious exit-130 warnings).

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --live                # Show Claude Code output in real-time (streaming)
    $0 --live --verbose      # Live streaming + verbose logging
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --output-format text     # Use legacy text output format
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration
    $0 --dry-run                # Preview execution without API calls
    $0 --log-max-size 20        # Rotate ralph.log at 20 MB

HELPEOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -V|--version)
            echo "ralph $RALPH_VERSION"
            exit 0
            ;;
        --mcp-status)
            # TAP-584: Probe + print capability summary so users can debug
            # "why isn't Ralph using the MCP" without grepping logs.
            ralph_print_mcp_status
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        --max-tokens)
            MAX_TOKENS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            # LOCK-1: Show instance lock status
            if [[ -f "$LOCKFILE" ]]; then
                local lock_pid
                lock_pid=$(cat "$LOCKFILE" 2>/dev/null | head -1)
                if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                    echo "Instance: RUNNING (PID: $lock_pid)"
                else
                    echo "Instance: NOT RUNNING (stale lock — will auto-release)"
                fi
            else
                echo "Instance: NOT RUNNING"
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -l|--live)
            LIVE_OUTPUT=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CLAUDE_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            # Reset session state only
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --optimize-linear)
            # TAP-594: Manual rerun of the Linear cache-locality optimizer.
            # Loads .ralphrc + secrets so RALPH_TASK_SOURCE / LINEAR_API_KEY /
            # RALPH_LINEAR_PROJECT are available, then invokes linear_optimizer_run.
            load_ralphrc 2>/dev/null || true
            if [[ "${RALPH_TASK_SOURCE:-file}" != "linear" ]]; then
                echo "Error: --optimize-linear requires RALPH_TASK_SOURCE=linear" >&2
                exit 1
            fi
            if declare -F linear_optimizer_run >/dev/null 2>&1; then
                linear_optimizer_run
                exit 0
            else
                echo "Error: lib/linear_optimizer.sh not loaded" >&2
                exit 1
            fi
            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CLAUDE_OUTPUT_FORMAT="$2"
                _cli_CLAUDE_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --no-continue)
            CLAUDE_USE_CONTINUE=false
            _cli_CLAUDE_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CLAUDE_SESSION_EXPIRY_HOURS="$2"
            _cli_CLAUDE_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            _cli_CB_AUTO_RESET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            _cli_DRY_RUN=true
            shift
            ;;
        --log-max-size)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --log-max-size requires a positive integer (MB)"
                exit 1
            fi
            LOG_MAX_SIZE_MB="$2"
            _cli_LOG_MAX_SIZE_MB="$2"
            shift 2
            ;;
        --log-max-files)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --log-max-files requires a positive integer"
                exit 1
            fi
            LOG_MAX_FILES="$2"
            _cli_LOG_MAX_FILES="$2"
            shift 2
            ;;
        --sdk)
            RALPH_SDK_MODE=true
            shift
            ;;
        --sdk-model)
            RALPH_SDK_MODEL="$2"
            shift 2
            ;;
        --sdk-max-turns)
            RALPH_SDK_MAX_TURNS="$2"
            shift 2
            ;;
        --stats)
            ralph_show_stats
            exit 0
            ;;
        --stats-json)
            ralph_show_stats --json
            exit 0
            ;;
        --stats-last)
            ralph_show_stats --last "$2"
            shift 2
            exit 0
            ;;
        --cost-dashboard|--costs)
            source "$SCRIPT_DIR/lib/tracing.sh" 2>/dev/null || true
            source "$SCRIPT_DIR/lib/metrics.sh" 2>/dev/null || true
            ralph_show_cost_dashboard "${@:2}"
            exit 0
            ;;
        --rollback)
            ralph_rollback
            exit $?
            ;;
        --rollback-list)
            ralph_rollback --list
            exit 0
            ;;
        --issue)
            RALPH_GITHUB_ISSUE="$2"
            shift 2
            ;;
        --issues)
            ralph_list_issues
            exit 0
            ;;
        --issue-label)
            RALPH_ISSUE_LABEL="$2"
            shift 2
            ;;
        --issue-assignee)
            RALPH_ISSUE_ASSIGNEE="$2"
            shift 2
            ;;
        --assess-only)
            RALPH_ASSESS_ONLY=true
            shift
            ;;
        --batch)
            RALPH_BATCH_MODE=true
            shift
            ;;
        --batch-issues)
            RALPH_BATCH_ISSUES="$2"
            shift 2
            ;;
        --stop-on-failure)
            RALPH_STOP_ON_FAILURE=true
            shift
            ;;
        --service)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --service requires a service name"
                exit 1
            fi
            RALPH_SERVICE="$2"
            shift 2
            ;;
        --beads)
            TASK_SOURCES="beads"
            shift
            ;;
        --wt)
            USE_WINDOWS_TERMINAL=true
            shift
            ;;
        --sandbox)
            RALPH_SANDBOX_MODE=true
            shift
            ;;
        --sandbox-required)
            RALPH_SANDBOX_REQUIRED=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # SDK mode dispatch (Phase 6 — v1.3.0)
    if [[ "${RALPH_SDK_MODE:-false}" == "true" ]]; then
        SDK_CMD="python -m ralph_sdk"
        SDK_ARGS=("--project-dir" ".")

        # Forward relevant flags
        [[ "${DRY_RUN:-false}" == "true" ]] && SDK_ARGS+=("--dry-run")
        [[ -n "${RALPH_SDK_MODEL:-}" ]] && SDK_ARGS+=("--model" "$RALPH_SDK_MODEL")
        [[ -n "${RALPH_SDK_MAX_TURNS:-}" ]] && SDK_ARGS+=("--max-turns" "$RALPH_SDK_MAX_TURNS")
        [[ "${VERBOSE_PROGRESS:-false}" == "true" ]] && SDK_ARGS+=("--verbose")
        SDK_ARGS+=("--calls" "$MAX_CALLS_PER_HOUR")
        SDK_ARGS+=("--timeout" "$CLAUDE_TIMEOUT_MINUTES")

        # Check SDK availability
        RALPH_SDK_DIR="$SCRIPT_DIR/sdk"
        if [[ -d "$RALPH_SDK_DIR/.venv" ]]; then
            # Use venv Python
            if [[ -f "$RALPH_SDK_DIR/.venv/bin/python" ]]; then
                SDK_CMD="$RALPH_SDK_DIR/.venv/bin/python -m ralph_sdk"
            elif [[ -f "$RALPH_SDK_DIR/.venv/Scripts/python.exe" ]]; then
                SDK_CMD="$RALPH_SDK_DIR/.venv/Scripts/python.exe -m ralph_sdk"
            fi
        fi

        # Add SDK to PYTHONPATH
        export PYTHONPATH="$RALPH_SDK_DIR:${PYTHONPATH:-}"

        echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Ralph SDK Mode (Python Agent SDK)   ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"

        exec $SDK_CMD "${SDK_ARGS[@]}"
    fi

    # GitHub issue import (Phase 10 — v1.7.0)
    if [[ -n "${RALPH_GITHUB_ISSUE:-}" ]]; then
        source "$SCRIPT_DIR/lib/github_issues.sh" 2>/dev/null || {
            echo "Error: GitHub issue integration not available. Install Ralph v1.7.0+"
            exit 1
        }
        ralph_import_issue "$RALPH_GITHUB_ISSUE"
        [[ "${RALPH_ASSESS_ONLY:-false}" == "true" ]] && exit 0
    fi

    # Batch mode (Phase 10 — v1.7.0)
    if [[ "${RALPH_BATCH_MODE:-false}" == "true" ]]; then
        source "$SCRIPT_DIR/lib/github_issues.sh" 2>/dev/null || {
            echo "Error: GitHub issue integration not available. Install Ralph v1.7.0+"
            exit 1
        }
        ralph_batch_process
        exit $?
    fi

    # Sandbox mode (Phase 11 — v1.8.0)
    if [[ "${RALPH_SANDBOX_MODE:-false}" == "true" ]]; then
        source "$SCRIPT_DIR/lib/sandbox.sh" 2>/dev/null || {
            echo "Error: Sandbox module not available. Install Ralph v1.8.0+"
            exit 1
        }
        ralph_sandbox_run "$@"
        exit $?
    fi

    # If tmux mode requested, set it up
    # Issue #156: On Windows, auto-detect Windows Terminal as tmux alternative
    if [[ "$USE_TMUX" == "true" ]] || [[ "${USE_WINDOWS_TERMINAL:-false}" == "true" ]]; then
        if [[ "${USE_WINDOWS_TERMINAL:-false}" == "true" ]]; then
            # Explicit --wt flag
            if check_windows_terminal_available; then
                setup_windows_terminal_session
            else
                log_status "ERROR" "Windows Terminal (wt.exe) not found. Install from Microsoft Store or use --monitor with tmux."
                exit 1
            fi
        elif command -v tmux &>/dev/null; then
            check_tmux_available
            setup_tmux_session
        elif check_windows_terminal_available; then
            log_status "INFO" "tmux not available, using Windows Terminal split panes instead"
            setup_windows_terminal_session
        else
            log_status "ERROR" "Neither tmux nor Windows Terminal (wt.exe) found."
            echo "Install one of:"
            echo "  tmux:             sudo apt-get install tmux (WSL/Linux)"
            echo "  Windows Terminal: Available from Microsoft Store"
            exit 1
        fi
    fi

    # Start the main loop
    main
fi
