#!/bin/bash

# Ralph Loop for Devin CLI
# Autonomous AI development loop using the official Cognition Devin CLI.
# This is a parallel implementation to ralph_loop.sh (Claude Code) — no shared state.
#
# The official Devin CLI is a local agent (like Claude Code):
#   devin -p --prompt-file FILE     # Non-interactive execution
#   devin -r SESSION_ID             # Resume specific session
#   devin --model opus|sonnet       # Model selection
#   devin --permission-mode auto    # Permission control
#
# Config: Uses .ralphrc.devin (separate from Claude's .ralphrc)
#
# Version: 0.2.0

# Note: set -e intentionally NOT used — see Issue #208.
# set -e causes silent script death in pipelines, command substitutions,
# and piped subshells (e.g., cleanup prompt injection, quality gate checks).
# Errors are handled explicitly throughout the script.

# Source library components (shared with Claude version)
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$RALPH_ROOT/lib/date_utils.sh"
source "$RALPH_ROOT/lib/timeout_utils.sh"
source "$RALPH_ROOT/lib/response_analyzer.sh"
source "$RALPH_ROOT/lib/circuit_breaker.sh"
source "$RALPH_ROOT/lib/task_sources.sh"
source "$SCRIPT_DIR/lib/devin_adapter.sh"
source "$SCRIPT_DIR/lib/worktree_manager.sh"
source "$RALPH_ROOT/lib/parallel_spawn.sh"
source "$RALPH_ROOT/lib/pr_manager.sh"

# Configuration
RALPH_DIR=".ralph"
RALPH_ENGINE="devin"           # identifier used by pr_manager.sh
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
LIVE_LOG_FILE="$RALPH_DIR/live.log"
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false
LIVE_OUTPUT=false
PARALLEL_COUNT=0
PARALLEL_BG=false
SLEEP_DURATION=3600

# Save environment variable state BEFORE setting defaults
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_DEVIN_TIMEOUT_MINUTES="${DEVIN_TIMEOUT_MINUTES:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_DEVIN_MODEL="${DEVIN_MODEL:-}"
_env_DEVIN_PERMISSION_MODE="${DEVIN_PERMISSION_MODE:-}"
_env_DEVIN_AUTO_EXIT="${DEVIN_AUTO_EXIT:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_MAX_LOOPS="${MAX_LOOPS:-}"
_env_WORKTREE_ENABLED="${WORKTREE_ENABLED:-}"
_env_WORKTREE_MERGE_STRATEGY="${WORKTREE_MERGE_STRATEGY:-}"
_env_WORKTREE_QUALITY_GATES="${WORKTREE_QUALITY_GATES:-}"

# Defaults
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
DEVIN_TIMEOUT_MINUTES="${DEVIN_TIMEOUT_MINUTES:-30}"
DEVIN_USE_CONTINUE="${DEVIN_USE_CONTINUE:-true}"
DEVIN_AUTO_EXIT="${DEVIN_AUTO_EXIT:-true}"  # true = use -p flag (auto-exit), false = interactive
MAX_LOOPS="${MAX_LOOPS:-0}"  # 0 = unlimited
QG_RETRY_COUNT=0
MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"

# Session management
DEVIN_SESSION_EXPIRY_HOURS="${DEVIN_SESSION_EXPIRY_HOURS:-24}"

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30

# .ralphrc.devin configuration file (separate from Claude's .ralphrc)
RALPHRC_FILE=".ralphrc.devin"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${DEVIN_TIMEOUT:-}" ]]; then
        DEVIN_TIMEOUT_MINUTES="$DEVIN_TIMEOUT"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore explicitly set environment variables (CLI flags > env vars > .ralphrc.devin)
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_DEVIN_TIMEOUT_MINUTES" ]] && DEVIN_TIMEOUT_MINUTES="$_env_DEVIN_TIMEOUT_MINUTES"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_DEVIN_MODEL" ]] && DEVIN_MODEL="$_env_DEVIN_MODEL"
    [[ -n "$_env_DEVIN_PERMISSION_MODE" ]] && DEVIN_PERMISSION_MODE="$_env_DEVIN_PERMISSION_MODE"
    [[ -n "$_env_DEVIN_AUTO_EXIT" ]] && DEVIN_AUTO_EXIT="$_env_DEVIN_AUTO_EXIT"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_MAX_LOOPS" ]] && MAX_LOOPS="$_env_MAX_LOOPS"
    [[ -n "$_env_WORKTREE_ENABLED" ]] && WORKTREE_ENABLED="$_env_WORKTREE_ENABLED"
    [[ -n "$_env_WORKTREE_MERGE_STRATEGY" ]] && WORKTREE_MERGE_STRATEGY="$_env_WORKTREE_MERGE_STRATEGY"
    [[ -n "$_env_WORKTREE_QUALITY_GATES" ]] && WORKTREE_QUALITY_GATES="$_env_WORKTREE_QUALITY_GATES"

    RALPHRC_LOADED=true
    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# =============================================================================
# TMUX INTEGRATION
# =============================================================================

check_tmux_available() {
    if ! command -v tmux &>/dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        exit 1
    fi
}

get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    echo "${base_index:-0}"
}

setup_tmux_session() {
    local session_name="ralph-devin-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir
    project_dir=$(pwd)

    local base_win
    base_win=$(get_tmux_base_index)

    log_status "INFO" "Setting up tmux session: $session_name"

    echo "=== Ralph Devin Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    tmux new-session -d -s "$session_name" -c "$project_dir"
    tmux split-window -h -t "$session_name" -c "$project_dir"
    tmux split-window -v -t "$session_name:${base_win}.1" -c "$project_dir"

    # Right-top pane: Live Devin output
    tmux send-keys -t "$session_name:${base_win}.1" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane: Ralph status monitor
    if command -v ralph-devin-monitor &>/dev/null; then
        tmux send-keys -t "$session_name:${base_win}.2" "ralph-devin-monitor" Enter
    elif [[ -f "$ralph_home/devin/ralph_monitor_devin.sh" ]]; then
        tmux send-keys -t "$session_name:${base_win}.2" "'$ralph_home/devin/ralph_monitor_devin.sh'" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.2" "watch -n 5 cat '$project_dir/$STATUS_FILE'" Enter
    fi

    # Build ralph-devin command for left pane
    local ralph_cmd
    if command -v ralph-devin &>/dev/null; then
        ralph_cmd="ralph-devin"
    else
        ralph_cmd="'$ralph_home/devin/ralph_loop_devin.sh'"
    fi

    ralph_cmd="$ralph_cmd --live"

    [[ "$MAX_CALLS_PER_HOUR" != "100" ]] && ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]] && ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    [[ "$VERBOSE_PROGRESS" == "true" ]] && ralph_cmd="$ralph_cmd --verbose"
    [[ "$DEVIN_TIMEOUT_MINUTES" != "30" ]] && ralph_cmd="$ralph_cmd --timeout $DEVIN_TIMEOUT_MINUTES"
    [[ "$DEVIN_USE_CONTINUE" == "false" ]] && ralph_cmd="$ralph_cmd --no-continue"
    [[ "$CB_AUTO_RESET" == "true" ]] && ralph_cmd="$ralph_cmd --auto-reset-circuit"
    [[ "$WORKTREE_ENABLED" == "false" ]] && ralph_cmd="$ralph_cmd --no-worktree"
    [[ "$WORKTREE_MERGE_STRATEGY" != "squash" ]] && ralph_cmd="$ralph_cmd --merge-strategy $WORKTREE_MERGE_STRATEGY"

    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd" Enter
    tmux select-pane -t "$session_name:${base_win}.0"

    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Devin Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Devin Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    tmux rename-window -t "$session_name:${base_win}" "Ralph Devin: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph Devin loop"
    log_status "INFO" "  Right-top:    Devin live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    tmux attach-session -t "$session_name"
    exit 0
}

# =============================================================================
# CALL TRACKING & RATE LIMITING
# =============================================================================

init_call_tracking() {
    local current_hour
    current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    init_circuit_breaker
}

# =============================================================================
# LOGGING
# =============================================================================

log_status() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac

    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# =============================================================================
# STATUS TRACKING
# =============================================================================

update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}

    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "engine": "devin",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "devin_session_id": "${DEVIN_SESSION_ID:-}",
    "worktree_enabled": $([[ "$WORKTREE_ENABLED" == "true" ]] && echo "true" || echo "false"),
    "worktree_branch": "$(worktree_get_branch 2>/dev/null)",
    "worktree_path": "$(worktree_get_path 2>/dev/null)",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# =============================================================================
# RATE LIMITING
# =============================================================================

can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1
    else
        return 0
    fi
}

increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

wait_for_reset() {
    local calls_made
    calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."

    local current_minute
    current_minute=$(date +%M)
    local current_second
    current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))

    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."

    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))

        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"

    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# =============================================================================
# EXIT DETECTION
# =============================================================================

should_exit_gracefully() {
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1
    fi

    local signals
    signals=$(cat "$EXIT_SIGNALS_FILE")

    local recent_test_loops
    local recent_done_signals
    local recent_completion_indicators

    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

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

    # 3. Safety circuit breaker
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators with EXIT_SIGNAL gate
    local devin_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        devin_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$devin_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi

    # 5. Check fix_plan.md for completion
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items
        uncompleted_items=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$uncompleted_items" ]] && uncompleted_items=0
        local completed_items
        completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$completed_items" ]] && completed_items=0
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""
}

# =============================================================================
# LOOP CONTEXT
# =============================================================================

build_loop_context() {
    local loop_count=$1
    local context=""

    context="Loop #${loop_count}. "

    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks
        incomplete_tasks=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$incomplete_tasks" ]] && incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state
        cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary
        prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary}"
        fi
    fi

    echo "${context:0:500}"
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

reset_session() {
    local reason=${1:-"manual_reset"}

    devin_clear_session
    devin_log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    # Clear exit signals
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    log_status "INFO" "Session reset: $reason"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

execute_devin_session() {
    local loop_count=$1
    local work_dir="${2:-$(pwd)}"
    local main_dir
    main_dir="$(pwd)"
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="${main_dir}/${LOG_DIR}/devin_output_${timestamp}.log"
    local calls_made
    calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))

    # Capture git HEAD SHA at loop start for progress detection
    local loop_start_sha=""
    if command -v git &>/dev/null; then
        if [[ "$work_dir" != "$main_dir" ]]; then
            loop_start_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        elif git rev-parse --git-dir &>/dev/null 2>&1; then
            loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Devin CLI (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((DEVIN_TIMEOUT_MINUTES * 60))
    log_status "INFO" "Starting Devin execution... (timeout: ${DEVIN_TIMEOUT_MINUTES}m)"

    # Build loop context for session continuity
    local loop_context=""
    if [[ "$DEVIN_USE_CONTINUE" == "true" ]]; then
        loop_context=$(build_loop_context "$loop_count")
        if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "INFO" "Loop context: $loop_context"
        fi
    fi

    # When in worktree mode, build a standalone directive that will be
    # prepended at the TOP of the prompt so the agent sees it first.
    local worktree_directive=""
    if [[ "$work_dir" != "$main_dir" ]]; then
        worktree_directive="# ⚠️  CRITICAL: WORKING DIRECTORY CONSTRAINT

You are operating inside an **isolated git worktree**.

- **Your working directory**: \`${work_dir}\`
- **DO NOT** navigate to, read from, or modify files in \`${main_dir}\` or any other directory.
- All file edits, git operations, and shell commands **MUST** stay within \`${work_dir}\`.
- Run \`pwd\` before any file operation to confirm you are in the correct directory.
- If a tool or command attempts to change to a different directory, refuse and stay in \`${work_dir}\`."
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$DEVIN_USE_CONTINUE" == "true" ]]; then
        session_id=$(devin_load_session)
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Devin session: ${session_id:0:20}..."
        fi
    fi

    # Build the Devin CLI command
    # --live mode: interactive (no -p), user sees Devin's TUI directly
    # background mode: non-interactive (-p), output captured to file
    # DEVIN_AUTO_EXIT controls -p flag: true = auto-exit, false = interactive
    local print_mode="true"
    if [[ "$DEVIN_AUTO_EXIT" == "false" ]]; then
        # Interactive mode - no -p flag, Devin waits for user input
        print_mode="false"
    elif [[ "$LIVE_OUTPUT" == "true" && "$WORKTREE_ENABLED" != "true" ]]; then
        # Legacy behavior: live output without worktree = interactive
        print_mode="false"
    fi

    # Use worktree's prompt file (absolute path) when in worktree mode
    local effective_prompt="$PROMPT_FILE"
    if [[ "$work_dir" != "$main_dir" && -f "$work_dir/$PROMPT_FILE" ]]; then
        effective_prompt="$work_dir/$PROMPT_FILE"
    elif [[ "$work_dir" != "$main_dir" && -f "${main_dir}/$PROMPT_FILE" ]]; then
        effective_prompt="${main_dir}/$PROMPT_FILE"
    fi

    if ! build_devin_command "$effective_prompt" "$loop_context" "$session_id" "$print_mode" "$worktree_directive"; then
        log_status "ERROR" "Failed to build Devin command"
        return 1
    fi

    log_status "INFO" "Using Devin CLI (model: ${DEVIN_MODEL:-default}, permissions: ${DEVIN_PERMISSION_MODE:-auto})"
    log_status "INFO" "Command: ${DEVIN_CMD_ARGS[*]}"
    if [[ "$work_dir" != "$main_dir" ]]; then
        log_status "INFO" "Working directory: $work_dir"
    fi

    # Initialize live.log for this execution
    echo -e "\n\n=== Devin Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"
    echo "Command: ${DEVIN_CMD_ARGS[*]}" >> "$LIVE_LOG_FILE"

    # Execute Devin CLI
    local exit_code=0

    # Use interactive mode if print_mode is false (DEVIN_AUTO_EXIT=false or legacy live mode)
    # Otherwise use background mode (which supports live streaming)
    if [[ "$print_mode" == "false" ]]; then
        log_status "INFO" "Live output mode - Devin running interactively..."
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Devin Session ━━━━━━━━━━━━━━━━${NC}"

        # Run Devin directly on the terminal (interactive TUI needs real TTY)
        # Use script to capture a copy of the output while keeping TTY intact
        # Note: portable_timeout is a bash function, not an executable.
        # script spawns a subprocess that can't see functions, so resolve to actual binary.
        local resolved_timeout_cmd
        resolved_timeout_cmd=$(detect_timeout_command 2>/dev/null)

        if command -v script &>/dev/null && [[ -n "$resolved_timeout_cmd" ]]; then
            (cd "$work_dir" && script -q "$output_file" "$resolved_timeout_cmd" ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}")
            exit_code=$?
        elif [[ -n "$resolved_timeout_cmd" ]]; then
            (cd "$work_dir" && "$resolved_timeout_cmd" ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}")
            exit_code=$?
        else
            (cd "$work_dir" && "${DEVIN_CMD_ARGS[@]}")
            exit_code=$?
        fi

        cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Session ━━━━━━━━━━━━━━━━━━━${NC}"

        # After interactive Devin session completes in worktree mode,
        # print a notice. Ralph's post-loop code handles auto-commit,
        # push, PR creation, and worktree cleanup automatically.
        if [[ "$DEVIN_AUTO_EXIT" == "false" && "$WORKTREE_ENABLED" == "true" && "$exit_code" -eq 0 ]]; then
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━ Post-Session ━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}Ralph will now auto-commit any remaining changes,${NC}"
            echo -e "${BLUE}push the branch, and open a pull request.${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        fi
    else
        # Background mode: non-interactive (-p flag), output to file
        (cd "$work_dir" && portable_timeout ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}") \
            < /dev/null > "$output_file" 2>&1 &

        local devin_pid=$!
        local progress_counter=0
        local last_displayed_line=0

        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Devin Session (Live Output) ━━━━━━━━━━━━━━━━${NC}"
            sleep 1  # Wait for output file to be created
        fi

        # Show progress while Devin is running
        while kill -0 $devin_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                # If LIVE_OUTPUT is enabled, display new lines from output file
                if [[ "$LIVE_OUTPUT" == "true" ]]; then
                    local current_lines
                    current_lines=$(wc -l < "$output_file" 2>/dev/null || echo "0")
                    if [[ $current_lines -gt $last_displayed_line ]]; then
                        # Display new lines since last check
                        tail -n +$((last_displayed_line + 1)) "$output_file" 2>/dev/null
                        last_displayed_line=$current_lines
                    fi
                fi

                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi

            cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

            if [[ "$VERBOSE_PROGRESS" == "true" && "$LIVE_OUTPUT" != "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Devin: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Devin working... (${progress_counter}0s elapsed)"
                fi
            fi

            sleep 2  # Reduced from 10s to 2s for more responsive live output
        done

        wait $devin_pid
        exit_code=$?

        # Display any remaining output
        if [[ "$LIVE_OUTPUT" == "true" && -f "$output_file" ]]; then
            local final_lines
            final_lines=$(wc -l < "$output_file" 2>/dev/null || echo "0")
            if [[ $final_lines -gt $last_displayed_line ]]; then
                tail -n +$((last_displayed_line + 1)) "$output_file" 2>/dev/null
            fi
            echo ""
            echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Session ━━━━━━━━━━━━━━━━━━━${NC}"
        fi
    fi

    # Process results
    if [[ $exit_code -eq 0 ]]; then
        # Check for API errors hidden inside a successful exit code (e.g., rate limits)
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            local api_error=""
            api_error=$(jq -r 'select(.is_error == true) | .result // empty' "$output_file" 2>/dev/null | head -1)

            if [[ -n "$api_error" ]]; then
                log_status "ERROR" "API error: $api_error"
                echo -e "\n${RED}━━━ API Error ━━━${NC}"
                echo -e "${YELLOW}$api_error${NC}"
                echo -e "${RED}━━━━━━━━━━━━━━━━━${NC}\n"

                if echo "$api_error" | grep -qiE '(rate.limit|hit your limit|resets|quota|too many)'; then
                    return 2
                fi
                return 1
            fi
        fi

        echo "$calls_made" > "$CALL_COUNT_FILE"
        echo '{"status": "completed", "timestamp": "'"$(date '+%Y-%m-%d %H:%M:%S')"'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "Devin execution completed successfully"

        # Save session ID from output for future continuation
        if [[ "$DEVIN_USE_CONTINUE" == "true" ]]; then
            devin_save_session "$output_file"
        fi

        # Analyze the response
        log_status "INFO" "Analyzing Devin response..."

        local devin_analysis
        devin_analysis=$(devin_parse_output "$output_file")

        local devin_exit_signal
        devin_exit_signal=$(echo "$devin_analysis" | jq -r '.exit_signal' 2>/dev/null || echo "false")
        local devin_summary
        devin_summary=$(echo "$devin_analysis" | jq -r '.work_summary' 2>/dev/null || echo "")

        jq -n \
            --arg exit_signal "$devin_exit_signal" \
            --arg work_summary "$devin_summary" \
            --argjson loop_count "$loop_count" \
            '{
                analysis: {
                    exit_signal: ($exit_signal == "true"),
                    work_summary: $work_summary,
                    has_permission_denials: false,
                    permission_denial_count: 0,
                    denied_commands: []
                },
                loop_count: $loop_count,
                engine: "devin"
            }' > "$RESPONSE_ANALYSIS_FILE"

        # Update exit signals
        update_exit_signals

        # Log analysis summary
        log_analysis_summary

        # Get file change count for circuit breaker
        local files_changed=0
        local current_sha=""
        local git_dir="$main_dir"
        [[ "$work_dir" != "$main_dir" ]] && git_dir="$work_dir"

        if command -v git &>/dev/null; then
            current_sha=$(cd "$git_dir" && git rev-parse HEAD 2>/dev/null || echo "")

            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                files_changed=$(
                    cd "$git_dir" && {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null
                        git diff --name-only --cached 2>/dev/null
                    } | sort -u | wc -l
                )
            else
                files_changed=$(
                    cd "$git_dir" && {
                        git diff --name-only 2>/dev/null
                        git diff --name-only --cached 2>/dev/null
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"
        if [[ -f "$output_file" ]]; then
            if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
               grep -qE '(^Error:|^ERROR:|^error:|\]: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
                has_errors="true"
                log_status "WARN" "Errors detected in output, check: $output_file"
            fi
        fi

        local output_length
        output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3
        fi

        return 0
    else
        echo '{"status": "failed", "timestamp": "'"$(date '+%Y-%m-%d %H:%M:%S')"'"}' > "$PROGRESS_FILE"
        log_status "ERROR" "Devin execution failed (exit code: $exit_code), check: $output_file"
        return 1
    fi
}

# =============================================================================
# CLEANUP & SIGNAL HANDLERS
# =============================================================================

cleanup() {
    log_status "INFO" "Ralph Devin loop interrupted. Cleaning up..."
    if worktree_is_active 2>/dev/null; then
        log_status "INFO" "Cleaning up active worktree..."
        worktree_cleanup "true" 2>/dev/null || true
    fi
    reset_session "manual_interrupt"
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Global variable for loop count
loop_count=0

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc.devin"
        fi
    fi

    # Check Devin CLI availability
    if ! check_devin_cli; then
        exit 1
    fi

    log_status "SUCCESS" "Ralph loop starting with Devin CLI"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Timeout per session: ${DEVIN_TIMEOUT_MINUTES}m"
    log_status "INFO" "Logs: $LOG_DIR/ | Status: $STATUS_FILE"
    log_status "INFO" "Worktree: ${WORKTREE_ENABLED} | Merge: ${WORKTREE_MERGE_STRATEGY} | Gates: ${WORKTREE_QUALITY_GATES}"

    # Check if this is a Ralph project directory
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo "Run: ralph-migrate"
        exit 1
    fi

    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        echo "This directory is not a Ralph project."
        echo "To fix:"
        echo "  1. ralph-devin-enable   # Enable Ralph+Devin in existing project"
        echo "  2. ralph-devin-setup my-project  # Create new project"
        echo "  3. ralph-devin-import prd.md     # Import requirements"
        exit 1
    fi

    # Initialize worktree system
    if [[ "$WORKTREE_ENABLED" == "true" ]]; then
        if worktree_init; then
            log_status "SUCCESS" "Worktree mode enabled (base: $(worktree_get_base_dir))"
        else
            log_status "WARN" "Worktree init failed, using direct mode"
            WORKTREE_ENABLED="false"
        fi
    fi

    # Run PR preflight checks once before entering the loop
    pr_preflight_check

    log_status "INFO" "Starting main loop..."

    while true; do
        loop_count=$((loop_count + 1))

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking

        log_status "LOOP" "=== Starting Loop #$loop_count ==="

        # Check max loops limit
        if [[ $MAX_LOOPS -gt 0 ]] && [[ $loop_count -gt $MAX_LOOPS ]]; then
            log_status "SUCCESS" "Max loops reached ($MAX_LOOPS). Stopping."
            reset_session "max_loops_reached"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "max_loops" "completed" "max_loops_reached"
            break
        fi

        # Check circuit breaker
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason
        exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            log_status "SUCCESS" "Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"
            break
        fi

        # Beads pre-sync: pull new open beads into fix_plan.md
        if beads_sync_available; then
            log_status "INFO" "Syncing open beads into fix_plan.md..."
            beads_pre_sync "$RALPH_DIR/fix_plan.md" 2>&1 | while IFS= read -r sync_msg; do
                log_status "INFO" "$sync_msg"
            done
        fi

        # Pick next unclaimed task and mark it in-progress BEFORE worktree creation
        # This enables parallel loops to each pick a different task
        local picked_task_id=""
        local picked_line_num=""
        local picked_bead_id=""
        local task_info=""
        local picked_task_name=""
        if task_info=$(pick_next_task "$RALPH_DIR/fix_plan.md"); then
            picked_task_id=$(echo "$task_info" | cut -d'|' -f1)
            picked_line_num=$(echo "$task_info" | cut -d'|' -f2)
            picked_bead_id=$(echo "$task_info" | cut -d'|' -f3)
            picked_task_name=$(sed -n "${picked_line_num}p" "$RALPH_DIR/fix_plan.md" 2>/dev/null | sed 's/.*\[.\] //' | tr -d '\n' || echo "")

            log_status "SUCCESS" "Picked and locked task: $picked_task_id (line $picked_line_num)"

            # Claim the specific bead as in_progress (if it's a bead task)
            if [[ -n "$picked_bead_id" ]] && beads_sync_available; then
                if mark_single_bead_in_progress "$picked_bead_id" 2>&1 | while IFS= read -r sync_msg; do
                    log_status "INFO" "$sync_msg"
                done; then
                    :
                fi
            fi
        else
            log_status "WARN" "No unclaimed tasks found in fix_plan.md"
        fi

        # Create worktree for this loop iteration
        # NOTE: worktree_create must NOT be called inside $() — that runs a subshell
        # and the internal state variables (_WT_CURRENT_PATH, _WT_CURRENT_BRANCH)
        # would be lost. Instead, call directly and use accessors afterward.
        local work_dir
        work_dir="$(pwd)"
        if [[ "$WORKTREE_ENABLED" == "true" ]]; then
            if worktree_is_active; then
                # QG retry — reuse existing worktree (do not create a new one)
                work_dir="$(worktree_get_path)"
                log_status "INFO" "QG retry #${QG_RETRY_COUNT}: reusing worktree $work_dir (branch: $(worktree_get_branch))"
            else
                QG_RETRY_COUNT=0   # reset counter when starting fresh with a new worktree
                local wt_task_id="${picked_task_id:-loop-${loop_count}-$(date +%s)}"
                if worktree_create "$loop_count" "$wt_task_id" > /dev/null; then
                    work_dir="$(worktree_get_path)"
                    log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
                else
                    log_status "WARN" "Worktree creation failed, using main directory"
                fi
            fi
        fi

        # Update status
        local calls_made
        calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Execute Devin session (in worktree if active)
        execute_devin_session "$loop_count" "$work_dir"
        local exec_result=$?

        if [[ $exec_result -eq 0 ]]; then
            # Worktree: quality gates + commit + push + PR + cleanup
            if [[ "$WORKTREE_ENABLED" == "true" ]] && worktree_is_active; then
                log_status "INFO" "Running quality gates in worktree..."
                local gate_output
                gate_output=$(worktree_run_quality_gates 2>&1)
                local gate_result=$?
                while IFS= read -r line; do [[ -n "$line" ]] && log_status "INFO" "$line"; done <<< "$gate_output"

                if [[ $gate_result -eq 0 ]]; then
                    # Quality gates passed — commit + push + open PR
                    log_status "SUCCESS" "Quality gates passed."
                    QG_RETRY_COUNT=0
                    local wt_branch_for_log
                    wt_branch_for_log="$(worktree_get_branch)"
                    local pr_result=0
                    worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "true" "$loop_count" || pr_result=$?
                    worktree_cleanup "false"    # worktree directory removed; branch preserved as PR head
                    if [[ $pr_result -eq 0 ]]; then
                        if [[ -n "$picked_line_num" ]] && [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
                            mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
                        fi
                    else
                        log_status "ERROR" "PR workflow failed. Branch preserved for manual recovery: $wt_branch_for_log"
                    fi
                else
                    # Quality gates failed — increment retry counter, keep worktree alive
                    QG_RETRY_COUNT=$((QG_RETRY_COUNT + 1))
                    log_status "WARN" "Quality gates failed (attempt $QG_RETRY_COUNT/$MAX_QG_RETRIES)."
                    if [[ $QG_RETRY_COUNT -ge $MAX_QG_RETRIES ]]; then
                        log_status "WARN" "Max QG retries reached. Creating PR with failure details."
                        worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count" || true
                        worktree_cleanup "false"    # worktree directory removed; branch preserved
                        QG_RETRY_COUNT=0
                    else
                        log_status "INFO" "Keeping worktree alive for QG retry in next loop iteration."
                        # do NOT call worktree_cleanup — worktree stays active for next iteration
                    fi
                fi
            elif [[ "$WORKTREE_ENABLED" == "true" ]] && [[ -n "$_WT_CURRENT_PATH" ]] && [[ ! -d "$_WT_CURRENT_PATH" ]]; then
                # Worktree was removed externally (e.g. via dewtm or the cleanup injection).
                # Sync fix_plan.md from the committed state so the [~] marker written by
                # pick_next_task is replaced with whatever the merge committed (typically [x]).
                if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
                    git checkout HEAD -- "$RALPH_DIR/fix_plan.md" 2>/dev/null || true
                fi
                # If the branch was deleted (merge committed), mark the task complete
                if [[ -n "$_WT_CURRENT_BRANCH" ]] && ! git rev-parse --verify "$_WT_CURRENT_BRANCH" &>/dev/null 2>&1; then
                    if [[ -n "$picked_line_num" ]] && [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
                        mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
                        log_status "INFO" "Marked task complete after external worktree merge"
                    fi
                fi
                _WT_CURRENT_PATH=""
                _WT_CURRENT_BRANCH=""
            fi

            # Non-worktree PR: create branch + push + PR when not using worktrees
            if [[ "$WORKTREE_ENABLED" != "true" ]]; then
                worktree_fallback_branch_pr "$picked_task_id" "$picked_task_name" "$loop_count" "true" || true
            fi

            # Beads post-sync: close completed beads
            if beads_sync_available; then
                log_status "INFO" "Syncing completed tasks back to beads..."
                beads_post_sync "$RALPH_DIR/fix_plan.md" "$loop_count" 2>&1 | while IFS= read -r sync_msg; do
                    log_status "INFO" "$sync_msg"
                done
            fi

            # Commit tracked .ralph/ state files (fix_plan.md, AGENT.md) to avoid
            # leaving them as uncommitted changes at the end of the loop.
            if git rev-parse --git-dir &>/dev/null 2>&1; then
                local ralph_staged=""
                git add "$RALPH_DIR/fix_plan.md" "$RALPH_DIR/AGENT.md" 2>/dev/null || true
                ralph_staged=$(git diff --cached --name-only 2>/dev/null)
                if [[ -n "$ralph_staged" ]]; then
                    git commit -m "ralph-devin: sync .ralph state after loop #${loop_count}" 2>/dev/null || true
                fi
            fi

            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"
            sleep 5
        elif [[ $exec_result -eq 3 ]]; then
            # Circuit breaker opened — create failure PR before cleanup
            if worktree_is_active; then
                log_status "WARN" "Circuit breaker opened — creating failure PR before cleanup."
                worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count" || true
                worktree_cleanup "false"    # worktree directory removed; branch preserved
            fi
            QG_RETRY_COUNT=0
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph-devin --reset-circuit' to reset"
            break
        else
            if worktree_is_active; then
                log_status "WARN" "Cleaning up worktree after failure..."
                worktree_cleanup "true"
            fi
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi

        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << HELPEOF
Ralph Loop for Devin CLI

Usage: ralph-devin [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Show Devin output in real-time
    -t, --timeout MIN       Set Devin session timeout in minutes (default: $DEVIN_TIMEOUT_MINUTES)
    --model MODEL           Set Devin model: opus, sonnet, swe, gpt
    --permission-mode MODE  Set permission mode: auto or dangerous (default: auto)
    --no-continue           Disable session continuity across loops
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup
    --reset-session         Reset session state and exit
    --max-loops NUM         Stop after NUM loops (default: 0 = unlimited)
    --no-worktree           Disable git worktree isolation
    --merge-strategy STR    Merge strategy: squash, merge, rebase (default: squash)
    --quality-gates GATES   Quality gates: auto, none, or "cmd1;cmd2" (default: auto)
    --devin-auto-exit       Force Devin to auto-exit with -p flag (default: true)
    --no-devin-auto-exit    Disable auto-exit, inject cleanup prompt after work

Examples:
    ralph-devin --calls 50 --timeout 30
    ralph-devin --monitor
    ralph-devin --live --verbose
    ralph-devin --model opus
    ralph-devin --max-loops 5
    ralph-devin --permission-mode dangerous
    ralph-devin --no-worktree
    ralph-devin --merge-strategy merge --quality-gates "npm test;npm run lint"

Bash Aliases (rpd):
    Add to ~/.bashrc or ~/.zshrc: source ~/.ralph/devin/ALIASES.sh
    
    rpd              # Start loop
    rpd.hitl         # Live + monitor
    rpd.opus         # Use Opus model
    rpd.wt.full      # Full worktree mode
    rpd.int          # Interactive with cleanup prompt
    rpd.install      # Install Ralph for Devin
    
    See devin/ALIASES.sh for complete list of 60+ aliases

HELPEOF
}

# =============================================================================
# CLI ARGUMENT PARSING
# =============================================================================

_RALPH_ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status (Devin):"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph Devin may not be running."
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
                DEVIN_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --model)
            DEVIN_MODEL="$2"
            shift 2
            ;;
        --permission-mode)
            if [[ "$2" == "auto" || "$2" == "dangerous" ]]; then
                DEVIN_PERMISSION_MODE="$2"
            else
                echo "Error: --permission-mode must be 'auto' or 'dangerous'"
                exit 1
            fi
            shift 2
            ;;
        --max-loops)
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                MAX_LOOPS="$2"
            else
                echo "Error: --max-loops must be a non-negative integer"
                exit 1
            fi
            shift 2
            ;;
        --no-continue)
            DEVIN_USE_CONTINUE=false
            shift
            ;;
        --reset-circuit)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/circuit_breaker.sh"
            source "$RALPH_ROOT/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32mSession state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
            ;;
        --no-worktree)
            WORKTREE_ENABLED=false
            shift
            ;;
        --devin-auto-exit)
            DEVIN_AUTO_EXIT=true
            shift
            ;;
        --no-devin-auto-exit)
            DEVIN_AUTO_EXIT=false
            shift
            ;;
        --merge-strategy)
            if [[ "$2" == "squash" || "$2" == "merge" || "$2" == "rebase" ]]; then
                WORKTREE_MERGE_STRATEGY="$2"
            else
                echo "Error: --merge-strategy must be 'squash', 'merge', or 'rebase'"
                exit 1
            fi
            shift 2
            ;;
        --quality-gates)
            WORKTREE_QUALITY_GATES="$2"
            shift 2
            ;;
        --parallel)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --parallel requires a positive integer (number of agents)"
                exit 1
            fi
            PARALLEL_COUNT="$2"
            shift 2
            ;;
        --parallel-bg)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --parallel-bg requires a positive integer (number of agents)"
                exit 1
            fi
            PARALLEL_COUNT="$2"
            PARALLEL_BG=true
            shift 2
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
    # If parallel mode requested, spawn agents (iTerm tabs or background jobs)
    if [[ "$PARALLEL_COUNT" -gt 0 ]]; then
        # Rebuild args without --parallel N / --parallel-bg N
        passthrough_args=()
        skip_next=false
        for arg in "${_RALPH_ORIGINAL_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                skip_next=false
                continue
            fi
            if [[ "$arg" == "--parallel" || "$arg" == "--parallel-bg" ]]; then
                skip_next=true
                continue
            fi
            passthrough_args+=("$arg")
        done
        export PARALLEL_BG
        spawn_parallel_agents "$PARALLEL_COUNT" ralph-devin "${passthrough_args[@]}"
        exit $?
    fi

    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    main
fi
