#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

# Note: CLAUDE_CODE_ENABLE_DANGEROUS_PERMISSIONS_IN_SANDBOX and IS_SANDBOX
# environment variables are NOT exported here. Tool restrictions are handled
# via --allowedTools flag in CLAUDE_CMD_ARGS, which is the proper approach.
# Exporting sandbox variables without a verified sandbox would be misleading.

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh" || { echo "FATAL: Failed to source lib/date_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/timeout_utils.sh" || { echo "FATAL: Failed to source lib/timeout_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/response_analyzer.sh" || { echo "FATAL: Failed to source lib/response_analyzer.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/circuit_breaker.sh" || { echo "FATAL: Failed to source lib/circuit_breaker.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/file_protection.sh" || { echo "FATAL: Failed to source lib/file_protection.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/task_sources.sh" || { echo "FATAL: Failed to source lib/task_sources.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/parallel_spawn.sh" || { echo "FATAL: Failed to source lib/parallel_spawn.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/worktree_manager.sh" || { echo "FATAL: Failed to source lib/worktree_manager.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/pr_manager.sh" || { echo "FATAL: Failed to source lib/pr_manager.sh" >&2; exit 1; }

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
RALPH_ENGINE="claude"           # identifier used by pr_manager.sh
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
CLAUDE_CODE_CMD="claude"
SLEEP_DURATION=3600     # 1 hour in seconds
LIVE_OUTPUT=false       # Show Claude Code output in real-time (streaming)
PARALLEL_COUNT=0       # Number of parallel agents to spawn (0 = disabled)
PARALLEL_BG=false      # Force background mode for parallel agents
LIVE_LOG_FILE="$RALPH_DIR/live.log"  # Fixed file for live output monitoring
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-}"
_env_CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-}"
_env_CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-}"
_env_CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-}"
_env_CLAUDE_SESSION_EXPIRY_HOURS="${CLAUDE_SESSION_EXPIRY_HOURS:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_MAX_LOOPS="${MAX_LOOPS:-}"
_env_WORKTREE_ENABLED="${WORKTREE_ENABLED:-}"
_env_WORKTREE_MERGE_STRATEGY="${WORKTREE_MERGE_STRATEGY:-}"
_env_WORKTREE_QUALITY_GATES="${WORKTREE_QUALITY_GATES:-}"
_env_CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-}"
_env_CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-}"

# Now set defaults (only if not already set by environment)
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
MAX_LOOPS="${MAX_LOOPS:-0}"  # 0 = unlimited
QG_RETRY_COUNT=0
MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"

# Modern Claude CLI configuration (Phase 1.1)
CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-json}"
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git *),Bash(which *),Bash(bd *),Bash(cd *),Bash(npm *),Bash(pnpm *),Bash(yarn *),Bash(bun *),Bash(pytest)}"
CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-true}"
CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id" # Session ID persistence file
CLAUDE_MIN_VERSION="2.0.76"              # Minimum required Claude CLI version
CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-true}"  # Auto-update Claude CLI at startup

# Session management configuration (Phase 1.2)
# Note: SESSION_EXPIRATION_SECONDS is defined in lib/response_analyzer.sh (86400 = 24 hours)
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CLAUDE_SESSION_EXPIRY_HOURS=${CLAUDE_SESSION_EXPIRY_HOURS:-24}

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "NotebookEdit"
)

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# .ralphrc configuration file
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - CLAUDE_TIMEOUT_MINUTES
#   - CLAUDE_OUTPUT_FORMAT
#   - ALLOWED_TOOLS (mapped to CLAUDE_ALLOWED_TOOLS)
#   - SESSION_CONTINUITY (mapped to CLAUDE_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CLAUDE_SESSION_EXPIRY_HOURS)
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#   - CLAUDE_CODE_CMD (path or command for Claude Code CLI)
#   - CLAUDE_AUTO_UPDATE (auto-update Claude CLI at startup)
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
        CLAUDE_ALLOWED_TOOLS="$ALLOWED_TOOLS"
    fi
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
    [[ -n "$_env_CLAUDE_ALLOWED_TOOLS" ]] && CLAUDE_ALLOWED_TOOLS="$_env_CLAUDE_ALLOWED_TOOLS"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_MAX_LOOPS" ]] && MAX_LOOPS="$_env_MAX_LOOPS"
    [[ -n "$_env_WORKTREE_ENABLED" ]] && WORKTREE_ENABLED="$_env_WORKTREE_ENABLED"
    [[ -n "$_env_WORKTREE_MERGE_STRATEGY" ]] && WORKTREE_MERGE_STRATEGY="$_env_WORKTREE_MERGE_STRATEGY"
    [[ -n "$_env_WORKTREE_QUALITY_GATES" ]] && WORKTREE_QUALITY_GATES="$_env_WORKTREE_QUALITY_GATES"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"

    RALPHRC_LOADED=true
    return 0
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
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
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
    # Forward --allowed-tools if non-default
    if [[ "$CLAUDE_ALLOWED_TOOLS" != "Write,Read,Edit,Bash(git *),Bash(which *),Bash(bd *),Bash(cd *),Bash(npm *),Bash(pnpm *),Bash(yarn *),Bash(bun *),Bash(pytest)" ]]; then
        ralph_cmd="$ralph_cmd --allowed-tools '$CLAUDE_ALLOWED_TOOLS'"
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
    # Forward worktree flags
    if [[ "$WORKTREE_ENABLED" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-worktree"
    fi
    if [[ "$WORKTREE_MERGE_STRATEGY" != "squash" ]]; then
        ralph_cmd="$ralph_cmd --merge-strategy $WORKTREE_MERGE_STRATEGY"
    fi
    if [[ "$WORKTREE_QUALITY_GATES" != "auto" ]]; then
        ralph_cmd="$ralph_cmd --quality-gates '$WORKTREE_QUALITY_GATES'"
    fi

    # Chain tmux kill-session after the loop command so the entire tmux
    # session is torn down when the Ralph loop exits (graceful completion,
    # circuit breaker, error, or manual interrupt). Without this, the
    # tail -f and ralph_monitor.sh panes keep the session alive forever.
    # Issue: https://github.com/frankbria/ralph-claude-code/issues/176
    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd; tmux kill-session -t $session_name 2>/dev/null" Enter

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

# Initialize call tracking
init_call_tracking() {
    # Debug logging removed for cleaner output
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "engine": "claude",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "worktree_enabled": $([[ "$WORKTREE_ENABLED" == "true" ]] && echo "true" || echo "false"),
    "worktree_branch": "$(worktree_get_branch 2>/dev/null)",
    "worktree_path": "$(worktree_get_path 2>/dev/null)",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
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
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # Diagnostic logging for exit signal check (Issue #194)
    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "DEBUG" "Exit check: test_loops=$recent_test_loops done_signals=$recent_done_signals completion_indicators=$recent_completion_indicators"

    # Check for exit conditions

    # 0. Permission denials (highest priority - Issue #101)
    # When Claude Code is denied permission to run commands, halt immediately
    # to allow user to update .ralphrc ALLOWED_TOOLS configuration
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local has_permission_denials=$(jq -r '.analysis.has_permission_denials // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        if [[ "$has_permission_denials" == "true" ]]; then
            local denied_count=$(jq -r '.analysis.permission_denial_count // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
            local denied_cmds=$(jq -r '.analysis.denied_commands | join(", ")' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "unknown")
            log_status "WARN" "🚫 Permission denied for $denied_count command(s): $denied_cmds"
            log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
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
    # (not based on confidence score). This safety breaker catches cases where Claude signals
    # completion 5+ times but the normal exit path (completion_indicators >= 2 + EXIT_SIGNAL=true)
    # didn't trigger for some reason. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Claude explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in .response_analysis represents Claude's explicit intent.
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi
    
    # 5. Check fix_plan.md for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    # Valid patterns: "- [ ]" (uncompleted) and "- [x]" or "- [X]" (completed)
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$uncompleted_items" ]] && uncompleted_items=0
        local completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$completed_items" ]] && completed_items=0
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

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
    version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

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

# Check for Claude CLI updates and attempt auto-update (Issue #190)
check_claude_updates() {
    if [[ "${CLAUDE_AUTO_UPDATE:-true}" != "true" ]]; then
        return 0
    fi

    local installed_version
    installed_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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

    # Auto-update attempt
    log_status "INFO" "Claude CLI update available: $installed_version → $latest_version. Attempting auto-update..."
    local update_output
    if update_output=$(npm update -g @anthropic-ai/claude-code 2>&1); then
        local new_version
        new_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_status "SUCCESS" "Claude CLI updated: $installed_version → ${new_version:-$latest_version}"
        return 0
    fi

    # Auto-update failed — warn with environment-specific guidance
    log_status "WARN" "Claude CLI auto-update failed ($installed_version → $latest_version)"
    [[ -n "$update_output" ]] && log_status "DEBUG" "npm output: $update_output"
    log_status "WARN" "Update manually: npm update -g @anthropic-ai/claude-code"
    log_status "WARN" "In Docker: rebuild your image to include the latest version"
    return 1
}

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi

            # Check for Bash(*) pattern - any Bash with parentheses is allowed
            if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return 1
        fi
    done

    return 0
}

# Build loop context for Claude Code session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix_plan.md
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$incomplete_tasks" ]] && incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    # Add circuit breaker state
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary (truncated)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary} "
        fi
    fi

    # If previous loop detected questions, inject corrective guidance (Issue #190 Bug 2)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_asking_questions
        prev_asking_questions=$(jq -r '.analysis.asking_questions // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        if [[ "$prev_asking_questions" == "true" ]]; then
            context+="IMPORTANT: You asked questions in the previous loop. This is a headless automation loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe default and proceed autonomously. "
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
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
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CLAUDE_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CLAUDE_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        local session_id=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
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
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            echo "$session_id" > "$CLAUDE_SESSION_FILE"
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

    # Also clear the Claude session file for consistency
    rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Clear response analysis to prevent stale EXIT_SIGNAL from previous session
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    # Log the session transition
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
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
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Global array for Claude command arguments (avoids shell injection)
declare -a CLAUDE_CMD_ARGS=()

# Build Claude CLI command with modern flags using array (shell-injection safe)
# Populates global CLAUDE_CMD_ARGS array for direct execution
# Uses -p flag with prompt content (Claude CLI does not have --prompt-file)
#
# Args:
#   $1 - prompt_file: Path to the prompt file
#   $2 - loop_context: Additional context string for --append-system-prompt
#   $3 - session_id: Session ID for --resume (empty = new session)
#   $4 - worktree_directive: If set, prepended to prompt content so the agent
#        sees the working-directory constraint before any other instruction.
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local worktree_directive="${4:-}"

    # Reset global array
    # Note: We do NOT use --dangerously-skip-permissions here. Tool permissions
    # are controlled via --allowedTools from CLAUDE_ALLOWED_TOOLS in .ralphrc.
    # This preserves the permission denial circuit breaker (Issue #101).
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    # Add output format flag
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Add allowed tools (each tool as separate array element)
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi

    # Add session continuity flag
    # IMPORTANT: Use --resume with explicit session ID instead of --continue
    # --continue resumes the "most recent session in current directory" which
    # can hijack active Claude Code sessions. --resume with a specific session ID
    # ensures we only resume Ralph's own sessions. (Issue #151)
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    fi
    # If no session_id, start fresh - Claude will generate a new session ID
    # which we'll capture via save_claude_session() for future loops

    # Add loop context as system prompt (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi

    # Read prompt file content and use -p flag
    # Note: Claude CLI uses -p for prompts, not --prompt-file (which doesn't exist)
    # Array-based approach maintains shell injection safety
    local prompt_content
    prompt_content=$(cat "$prompt_file")

    # Worktree directive goes FIRST so the agent sees it before any other instruction
    if [[ -n "$worktree_directive" ]]; then
        prompt_content="${worktree_directive}

---

${prompt_content}"
    fi

    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# Main execution function
execute_claude_code() {
    local loop_count=$1
    local work_dir="${2:-$(pwd)}"
    local main_dir
    main_dir="$(pwd)"
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="${main_dir}/${LOG_DIR}/claude_output_${timestamp}.log"
    local calls_made
    calls_made=$(increment_call_counter)

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    # Store in file for access by progress detection after Claude execution
    local loop_start_sha=""
    if command -v git &>/dev/null; then
        if [[ "$work_dir" != "$main_dir" ]]; then
            loop_start_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        elif git rev-parse --git-dir &>/dev/null 2>&1; then
            loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"

    # Build loop context (always, regardless of session mode)
    local loop_context=""
    loop_context=$(build_loop_context "$loop_count")
    if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Loop context: $loop_context"
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
        log_status "INFO" "Working directory: $work_dir"
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

    # Use worktree's prompt file when in worktree mode
    local effective_prompt="$PROMPT_FILE"
    if [[ "$work_dir" != "$main_dir" && -f "$work_dir/$PROMPT_FILE" ]]; then
        effective_prompt="$work_dir/$PROMPT_FILE"
    elif [[ "$work_dir" != "$main_dir" && -f "${main_dir}/$PROMPT_FILE" ]]; then
        effective_prompt="${main_dir}/$PROMPT_FILE"
    fi

    # Build the Claude CLI command with modern flags
    local use_modern_cli=false

    if build_claude_command "$effective_prompt" "$loop_context" "$session_id" "$worktree_directive"; then
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
        # - --allowedTools (tool permissions)
        # - --append-system-prompt (loop context)
        # - --continue (session continuity)
        # - -p (prompt content)

        # Check dependencies for live mode
        if ! command -v jq &> /dev/null; then
            log_status "ERROR" "Live mode requires 'jq' but it's not installed. Falling back to background mode."
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

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        log_status "INFO" "📺 Live output mode enabled - showing Claude Code streaming..."
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Claude Code Output ━━━━━━━━━━━━━━━━${NC}"

        # Modify CLAUDE_CMD_ARGS: replace --output-format value with stream-json
        # and add streaming-specific flags
        local -a LIVE_CMD_ARGS=()
        local skip_next=false
        for arg in "${CLAUDE_CMD_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                # Replace "json" with "stream-json" for output format
                LIVE_CMD_ARGS+=("stream-json")
                skip_next=false
            elif [[ "$arg" == "--output-format" ]]; then
                LIVE_CMD_ARGS+=("$arg")
                skip_next=true
            else
                LIVE_CMD_ARGS+=("$arg")
            fi
        done

        # Add streaming-specific flags (--verbose and --include-partial-messages)
        # These are required for stream-json to work properly
        LIVE_CMD_ARGS+=("--verbose" "--include-partial-messages")

        # jq filter: show text + tool names + sub-agent progress + newlines for readability
        local jq_filter='
            if .type == "stream_event" then
                if .event.type == "content_block_delta" and .event.delta.type == "text_delta" then
                    .event.delta.text
                elif .event.type == "content_block_start" and .event.content_block.type == "tool_use" then
                    "\n\n⚡ [" + .event.content_block.name + "]\n"
                elif .event.type == "content_block_stop" then
                    "\n"
                else
                    empty
                end
            elif .type == "system" and .subtype == "task_started" then
                "\n\n🚀 Agent: " + (.description // "started") + "\n"
            elif .type == "system" and .subtype == "task_progress" then
                "📌 " + (.description // "working...") + "\n"
            else
                empty
            end'

        # Execute with streaming, preserving all flags from build_claude_command()
        # Use stdbuf to disable buffering for real-time output
        # Use portable_timeout for consistent timeout protection (Issue: missing timeout)
        # Capture all pipeline exit codes for proper error handling
        # stdin must be redirected from /dev/null because newer Claude CLI versions
        # read from stdin even in -p (print) mode, causing the process to hang
        # Redirect stderr to separate file to prevent Node.js warnings (e.g., UNDICI)
        # from corrupting the jq JSON pipeline (Issue #190)
        local stderr_file="${LOG_DIR}/claude_stderr_$(date '+%Y%m%d_%H%M%S').log"
        portable_timeout ${timeout_seconds}s stdbuf -oL "${LIVE_CMD_ARGS[@]}" \
            < /dev/null 2>"$stderr_file" | stdbuf -oL tee "$output_file" | stdbuf -oL jq --unbuffered -j "$jq_filter" 2>/dev/null | tee "$LIVE_LOG_FILE"

        # Capture exit codes from pipeline
        local -a pipe_status=("${PIPESTATUS[@]}")

        # Primary exit code is from Claude/timeout (first command in pipeline)
        exit_code=${pipe_status[0]}

        # Log timeout events explicitly (exit code 124 from portable_timeout)
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "Claude Code execution timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes"
        fi

        # Log stderr if non-empty, clean up empty stderr files
        if [[ -s "$stderr_file" ]]; then
            log_status "WARN" "Claude CLI wrote to stderr (see: $stderr_file)"
        else
            rm -f "$stderr_file" 2>/dev/null
        fi

        # Check for tee failures (second command) - could break logging/session
        if [[ ${pipe_status[1]} -ne 0 ]]; then
            log_status "WARN" "Failed to write stream output to log file (exit code ${pipe_status[1]})"
        fi

        # Check for jq failures (third command) - warn but don't fail
        if [[ ${pipe_status[2]} -ne 0 ]]; then
            log_status "WARN" "jq filter had issues parsing some stream events (exit code ${pipe_status[2]})"
        fi

        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Output ━━━━━━━━━━━━━━━━━━━${NC}"

        # Extract session ID from stream-json output for session continuity
        # Stream-json format has session_id in the final "result" type message
        # Keep full stream output in _stream.log, extract session data separately
        if [[ "$CLAUDE_USE_CONTINUE" == "true" && -f "$output_file" ]]; then
            # Preserve full stream output for analysis (don't overwrite output_file)
            local stream_output_file="${output_file%.log}_stream.log"
            cp "$output_file" "$stream_output_file"

            # Extract the result message and convert to standard JSON format
            # Use flexible regex to match various JSON formatting styles
            # Matches: "type":"result", "type": "result", "type" : "result"
            local result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)

            if [[ -n "$result_line" ]]; then
                # Validate that extracted line is valid JSON before using it
                if echo "$result_line" | jq -e . >/dev/null 2>&1; then
                    # Write validated result as the output_file for downstream processing
                    # (save_claude_session and analyze_response expect JSON format)
                    echo "$result_line" > "$output_file"
                    log_status "INFO" "Extracted and validated session data from stream output"
                else
                    log_status "WARN" "Extracted result line is not valid JSON, keeping stream output"
                    # Restore original stream output
                    cp "$stream_output_file" "$output_file"
                fi
            else
                log_status "WARN" "Could not find result message in stream output"
                # Fallback: extract session ID from "type":"system" message (Issue #198)
                # The system message is always written first and survives truncation
                local system_line
                system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | tail -1)
                if [[ -n "$system_line" ]] && echo "$system_line" | jq -e . >/dev/null 2>&1; then
                    local fallback_session_id
                    fallback_session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null)
                    if [[ -n "$fallback_session_id" ]]; then
                        echo "$fallback_session_id" > "$CLAUDE_SESSION_FILE"
                        log_status "INFO" "Extracted session ID from system message (timeout fallback)"
                    fi
                fi
                # Keep stream output as-is for debugging
            fi
        fi
    else
        # BACKGROUND MODE: Original behavior with progress monitoring
        if [[ "$use_modern_cli" == "true" ]]; then
            # Modern execution with command array (shell-injection safe)
            # Execute array directly without bash -c to prevent shell metacharacter interpretation
            # stdin must be redirected from /dev/null because newer Claude CLI versions
            # read from stdin even in -p (print) mode, causing SIGTTIN suspension
            # when the process is backgrounded
            if portable_timeout ${timeout_seconds}s "${CLAUDE_CMD_ARGS[@]}" < /dev/null > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process (modern mode)"
                # Fall back to legacy mode
                log_status "INFO" "Falling back to legacy mode..."
                use_modern_cli=false
            fi
        fi

        # Fall back to legacy stdin piping if modern mode failed or not enabled
        # Note: Legacy mode doesn't use --allowedTools, so tool permissions
        # will be handled by Claude Code's default permission system
        if [[ "$use_modern_cli" == "false" ]]; then
            if portable_timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process"
                return 1
            fi
        fi

        # Get PID and monitor progress
        local claude_pid=$!
        local progress_counter=0

        # Early failure detection: if the command doesn't exist or fails immediately,
        # the backgrounded process dies before the monitoring loop starts (Issue #97)
        sleep 1
        if ! kill -0 $claude_pid 2>/dev/null; then
            wait $claude_pid 2>/dev/null
            local early_exit=$?
            local early_output=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                early_output=$(tail -5 "$output_file" 2>/dev/null)
            fi
            log_status "ERROR" "❌ Claude Code process exited immediately (exit code: $early_exit)"
            if [[ -n "$early_output" ]]; then
                log_status "ERROR" "Output: $early_output"
            fi
            echo ""
            echo -e "${RED}Claude Code failed to start.${NC}"
            echo ""
            echo -e "${YELLOW}Possible causes:${NC}"
            echo "  - '${CLAUDE_CODE_CMD}' command not found or not executable"
            echo "  - Claude Code CLI not installed"
            echo "  - Authentication or configuration issue"
            echo ""
            echo -e "${YELLOW}To fix:${NC}"
            echo "  1. Verify Claude Code works: ${CLAUDE_CODE_CMD} --version"
            echo "  2. Or set a different command in .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
            echo ""
            return 1
        fi

        # Show progress while Claude Code is running
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            # Get last line from output if available
            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                # Copy to live.log for tmux monitoring
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi

            # Update progress file for monitor
            cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

            # Only log if verbose mode is enabled
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
                fi
            fi

            sleep 10
        done

        # Wait for the process to finish and get exit code
        wait $claude_pid
        exit_code=$?
    fi

    if [ $exit_code -eq 0 ]; then
        # Check for API errors hidden inside a successful exit code (e.g., rate limits)
        # Claude Code returns exit 0 but sets "is_error":true in JSON output (NDJSON format)
        # CRITICAL: set +e to prevent grep/jq non-zero returns from killing the script
        set +e
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            local api_error=""
            local error_line=""
            error_line=$(grep '"is_error"' "$output_file" 2>/dev/null | grep 'true' | tail -1)

            if [[ -n "$error_line" ]]; then
                api_error=$(echo "$error_line" | jq -r '.result // empty' 2>/dev/null)
            fi

            if [[ -z "$api_error" ]]; then
                api_error=$(grep -oE '"result":"[^"]*hit your limit[^"]*"' "$output_file" 2>/dev/null | head -1 | sed 's/"result":"//;s/"$//')
            fi
            if [[ -z "$api_error" ]]; then
                api_error=$(grep -oE '"text":"[^"]*hit your limit[^"]*"' "$output_file" 2>/dev/null | head -1 | sed 's/"text":"//;s/"$//')
            fi

            if [[ -n "$api_error" ]]; then
                log_status "ERROR" "Claude API error: $api_error"
                echo -e "\n${RED}━━━ Claude API Error ━━━${NC}"
                echo -e "${YELLOW}$api_error${NC}"
                echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
                echo '{"status": "failed", "error": "is_error:true", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                # Reset session to prevent infinite retry with bad session ID
                if echo "$api_error" | grep -qi "tool.use.concurrency\|concurrency"; then
                    reset_session "tool_use_concurrency_error"
                    log_status "WARN" "Session reset due to tool use concurrency error. Retrying with fresh session."
                else
                    reset_session "api_error_is_error_true"
                    log_status "WARN" "Session reset due to API error (is_error:true). Retrying with fresh session."
                fi

                set -e
                if echo "$api_error" | grep -qiE '(rate.limit|hit your limit|resets|quota|too many)'; then
                    return 2
                fi
                return 1
            fi
        fi
        set -e

        # Clear progress file (only after is_error check passes)
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Claude Code execution completed successfully"

        # Save session ID from JSON output (Phase 1.1)
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Analyze the response
        log_status "INFO" "🔍 Analyzing Claude Code response..."
        analyze_response "$output_file" "$loop_count"
        local analysis_exit_code=$?

        if [[ $analysis_exit_code -eq 0 ]]; then
            # Update exit signals based on analysis
            update_exit_signals

            # Log analysis summary
            log_analysis_summary
        else
            log_status "WARN" "Response analysis failed (exit $analysis_exit_code); skipping signal updates"
            rm -f "$RESPONSE_ANALYSIS_FILE"
        fi

        # Get file change count for circuit breaker
        # Fix #141: Detect both uncommitted changes AND committed changes
        local files_changed=0
        local loop_start_sha=""
        local current_sha=""

        if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
            loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
        fi

        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

            # Check if commits were made (HEAD changed)
            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                # Commits were made - count union of committed files AND working tree changes
                # This catches cases where Claude commits some files but still has other modified files
                files_changed=$(
                    {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null           # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
                [[ "$VERBOSE_PROGRESS" == "true" ]] && log_status "DEBUG" "Detected $files_changed unique files changed (commits + working tree) since loop start"
            else
                # No commits - check for uncommitted changes (staged + unstaged)
                files_changed=$(
                    {
                        git diff --name-only 2>/dev/null                # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        # Layer 1: Timeout guard — exit code 124 is a timeout, not an API limit
        # Issue #198: Check for productive work before treating as failure
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "⏱️ Claude Code execution timed out (not an API limit)"

            # Check git for actual changes made during the timed-out execution
            local timeout_loop_start_sha=""
            local timeout_current_sha=""
            local timeout_files_changed=0

            if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
                timeout_loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
            fi

            if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
                timeout_current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

                if [[ -n "$timeout_loop_start_sha" && -n "$timeout_current_sha" && "$timeout_loop_start_sha" != "$timeout_current_sha" ]]; then
                    timeout_files_changed=$(
                        {
                            git diff --name-only "$timeout_loop_start_sha" "$timeout_current_sha" 2>/dev/null
                            git diff --name-only HEAD 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                else
                    timeout_files_changed=$(
                        {
                            git diff --name-only 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                fi
            fi

            if [[ $timeout_files_changed -gt 0 ]]; then
                # Productive timeout — work was done despite the timeout
                log_status "INFO" "⏱️ Timeout but $timeout_files_changed file(s) changed — treating iteration as productive"
                echo '{"status": "timed_out_productive", "files_changed": '$timeout_files_changed', "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                # Save session ID (fallback already populated by Step 1 if stream was truncated)
                if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
                    save_claude_session "$output_file"
                fi

                # Run analysis pipeline on whatever output exists
                log_status "INFO" "🔍 Analyzing response from productive timeout..."
                analyze_response "$output_file" "$loop_count"
                local timeout_analysis_exit=$?

                if [[ $timeout_analysis_exit -eq 0 ]]; then
                    update_exit_signals
                    log_analysis_summary
                else
                    # Clear stale response analysis to prevent next loop from reusing
                    # old EXIT_SIGNAL, permission-denial, or question-detection state
                    log_status "WARN" "Timeout response analysis failed (exit $timeout_analysis_exit); clearing stale analysis"
                    rm -f "$RESPONSE_ANALYSIS_FILE"
                fi

                # Feed circuit breaker with progress data
                local timeout_output_length
                timeout_output_length=$(wc -c < "$output_file" 2>/dev/null || echo "0")
                record_loop_result "$loop_count" "$timeout_files_changed" "false" "$timeout_output_length"
                local timeout_circuit_result=$?

                if [[ $timeout_circuit_result -ne 0 ]]; then
                    log_status "WARN" "Circuit breaker opened - halting execution"
                    return 3
                fi

                return 0
            else
                # Idle timeout — no work detected
                log_status "WARN" "⏱️ Timeout with no detectable progress"
                return 1
            fi
        fi  # end timeout

        # Layer 2: Structural JSON detection — check rate_limit_event for status:"rejected"
        # This is the definitive signal from the Claude CLI
        if grep -q '"rate_limit_event"' "$output_file" 2>/dev/null; then
            local last_rate_event
            last_rate_event=$(grep '"rate_limit_event"' "$output_file" | tail -1)
            if echo "$last_rate_event" | grep -qE '"status"\s*:\s*"rejected"'; then
                log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
                return 2  # Real API limit
            fi
        fi

        # Layer 3: Filtered text fallback — only check tail, excluding tool result lines
        # Filters out type:user, tool_result, and tool_use_id lines which contain echoed file content
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached"; then
            log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
            return 2  # API limit detected via text fallback
        fi

        # Layer 4: Extra Usage quota detection (Issue #100)
        # Claude Code "Extra Usage" mode uses a different error message:
        # "You're out of extra usage · resets 9pm"
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "out of extra usage"; then
            log_status "ERROR" "🚫 Claude Extra Usage quota exhausted"
            return 2  # Extra Usage limit detected
        fi

        log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
        return 1
    fi
}

# Cleanup function
cleanup() {
    local trap_exit_code=$?

    # Reentrancy guard — prevent double execution from EXIT + signal combination
    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    # Only record "interrupted" status for abnormal exits (non-zero exit code)
    # Normal exit (code 0) preserves the status already written by the main loop
    if [[ $loop_count -gt 0 && $trap_exit_code -ne 0 ]]; then
        log_status "INFO" "Ralph loop interrupted. Cleaning up..."
        if worktree_is_active 2>/dev/null; then
            log_status "INFO" "Cleaning up active worktree..."
            worktree_cleanup "true" 2>/dev/null || true
        fi
        reset_session "manual_interrupt"
        update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    fi
    # No exit here — EXIT trap handles natural termination
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
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

    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"
    log_status "INFO" "Worktree: ${WORKTREE_ENABLED} | Merge: ${WORKTREE_MERGE_STRATEGY} | Gates: ${WORKTREE_QUALITY_GATES}"

    # Check if project uses old flat structure and needs migration
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
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

    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
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

    # Verify Ralph file integrity on startup (Issue #149)
    if ! validate_ralph_integrity; then
        log_status "ERROR" "Ralph integrity check failed - critical files missing"
        echo ""
        echo "$(get_integrity_report)"
        echo ""
        exit 1
    fi

    # Initialize session tracking before entering the loop
    init_session_tracking

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

    # Reset exit signals to prevent stale state from prior run causing premature exit (Issue #194)
    # This is unconditional: regardless of how the previous run ended (crash, SIGKILL, API limit exit),
    # every new ralph invocation starts with a clean exit-signal slate.
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null
    log_status "INFO" "Reset exit signals for fresh start"

    log_status "INFO" "Starting main loop..."

    while true; do
        loop_count=$((loop_count + 1))

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="

        # Check max loops limit
        if [[ "$MAX_LOOPS" -gt 0 && "$loop_count" -gt "$MAX_LOOPS" ]]; then
            log_status "SUCCESS" "Max loops reached ($MAX_LOOPS). Stopping."
            reset_session "max_loops_reached"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "max_loops" "completed" "max_loops_reached"
            break
        fi
        
        # Verify Ralph's critical files still exist (Issue #149)
        if ! validate_ralph_integrity; then
            # Ensure log directory exists for logging even if .ralph/ was deleted
            mkdir -p "$LOG_DIR" 2>/dev/null
            log_status "ERROR" "Ralph integrity check failed - critical files missing"
            echo ""
            echo "$(get_integrity_report)"
            echo ""
            reset_session "integrity_failure"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)" "integrity_failure" "halted" "files_deleted"
            break
        fi

        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
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
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "permission_denied" "halted" "permission_denied"

                # Display helpful guidance for resolving permission issues
                echo ""
                echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  PERMISSION DENIED - Loop Halted                          ║${NC}"
                echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}Claude Code was denied permission to execute commands.${NC}"
                echo ""
                echo -e "${YELLOW}To fix this:${NC}"
                echo "  1. Edit .ralphrc and update ALLOWED_TOOLS to include the required tools"
                echo "  2. Common patterns:"
                echo "     - Bash(npm *)     - All npm commands"
                echo "     - Bash(npm install) - Only npm install"
                echo "     - Bash(pnpm *)    - All pnpm commands"
                echo "     - Bash(yarn *)    - All yarn commands"
                echo ""
                echo -e "${YELLOW}After updating .ralphrc:${NC}"
                echo "  ralph --reset-session  # Clear stale session state"
                echo "  ralph --monitor        # Restart the loop"
                echo ""

                # Show current ALLOWED_TOOLS if .ralphrc exists
                if [[ -f ".ralphrc" ]]; then
                    local current_tools=$(grep "^ALLOWED_TOOLS=" ".ralphrc" 2>/dev/null | cut -d= -f2- | tr -d '"')
                    if [[ -n "$current_tools" ]]; then
                        echo -e "${BLUE}Current ALLOWED_TOOLS:${NC} $current_tools"
                        echo ""
                    fi
                fi

                break
            fi

            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
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

        # Pick next unclaimed task and mark it in-progress BEFORE execution
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
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"
        
        # Execute Claude Code (in worktree if active)
        # CRITICAL: Disable set -e for the entire execution + error detection block.
        # set -e causes silent script death at multiple points:
        #   1. Live mode pipeline when jq fails on non-stream-json (rate limit)
        #   2. grep commands returning 1 on no-match during error detection
        #   3. Function return codes triggering script exit
        set +e
        execute_claude_code "$loop_count" "$work_dir"
        local exec_result=$?

        # Check latest output log for API errors (rate limits return exit 0)
        local latest_log=""
        latest_log=$(ls -t "$LOG_DIR"/claude_output_*.log 2>/dev/null | head -1)
        if [[ -n "$latest_log" && -f "$latest_log" ]]; then
            if grep -q 'hit your limit\|rate_limit\|quota.*exceeded' "$latest_log" 2>/dev/null; then
                local _err_msg=""
                _err_msg=$(grep -o '"result":"[^"]*"' "$latest_log" 2>/dev/null | tail -1 | sed 's/"result":"//;s/"$//')
                if [[ -z "$_err_msg" ]]; then
                    _err_msg=$(grep -o '"text":"[^"]*"' "$latest_log" 2>/dev/null | tail -1 | sed 's/"text":"//;s/"$//')
                fi
                if [[ -n "$_err_msg" ]]; then
                    log_status "ERROR" "API Rate Limit: $_err_msg"
                    echo ""
                    echo -e "${RED}━━━ API Rate Limit Hit ━━━${NC}"
                    echo -e "${YELLOW}$_err_msg${NC}"
                    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    echo ""
                    exec_result=2
                fi
            fi
        fi
        set -e
        
        if [ $exec_result -eq 0 ]; then
            # Worktree: quality gates + interactive merge prompt + cleanup
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
                # Worktree was removed externally (e.g. via a merge command run by Claude).
                # Sync fix_plan.md from the committed state so the [~] marker is replaced.
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
                beads_post_sync "$RALPH_DIR/fix_plan.md" "$loop_count" "Ralph Claude" 2>&1 | while IFS= read -r sync_msg; do
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
                    git commit -m "ralph: sync .ralph state after loop #${loop_count}" 2>/dev/null || true
                fi
            fi

            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened — create failure PR before cleanup
            if worktree_is_active; then
                log_status "WARN" "Circuit breaker opened — creating failure PR before cleanup."
                worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count" || true
                worktree_cleanup "false"    # worktree directory removed; branch preserved
            fi
            QG_RETRY_COUNT=0
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 Claude API 5-hour limit reached!"
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}A Claude API usage limit has been reached (5-hour plan limit or Extra Usage quota).${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice || true
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]]; then
                log_status "INFO" "User chose to exit. Exiting loop..."
                reset_session "api_limit_exit"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                # Auto-wait on timeout (empty choice) or explicit "1" — supports unattended operation
                log_status "INFO" "Waiting for API limit reset (auto-wait for unattended mode)..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
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

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Claude Code

Usage: ralph [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
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
    --reset-session         Reset session state and exit (clears session continuity)
    --max-loops NUM         Stop after NUM loops (default: 0 = unlimited)
    --parallel N            Spawn N parallel ralph agents (iTerm2 tabs or IDE terminal tabs, auto-detected)
    --parallel-bg N         Spawn N parallel ralph agents as background processes (any terminal)

Modern CLI Options:
    --output-format FORMAT  Set Claude output format: json or text (default: $CLAUDE_OUTPUT_FORMAT)
                            Note: --live mode requires JSON and will auto-switch
    --allowed-tools TOOLS   Comma-separated list of allowed tools (default: $CLAUDE_ALLOWED_TOOLS)
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CLAUDE_SESSION_EXPIRY_HOURS)

Worktree Options:
    --no-worktree           Disable git worktree isolation
    --merge-strategy STR    Merge strategy: squash, merge, rebase (default: squash)
    --quality-gates GATES   Quality gates: auto, none, or "cmd1;cmd2" (default: auto)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    ralph --monitor            # Start Ralph with monitoring

Examples:
    ralph --calls 50 --prompt my_prompt.md
    ralph --monitor             # Start with integrated tmux monitoring
    ralph --live                # Show Claude Code output in real-time (streaming)
    ralph --live --verbose      # Live streaming + verbose logging
    ralph --monitor --timeout 30   # 30-minute timeout for complex tasks
    ralph --verbose --timeout 5    # 5-minute timeout with detailed progress
    ralph --output-format text     # Use legacy text output format
    ralph --no-continue            # Disable session continuity
    ralph --session-expiry 48      # 48-hour session expiration
    ralph --live --monitor --parallel 3  # Spawn 3 parallel agents (auto-detects terminal)

Bash Aliases (rpc):
    Add to ~/.bashrc or ~/.zshrc: source ~/.ralph/ALIASES.sh
    
    rpc              # Start loop
    rpc.hitl         # Live + monitor
    rpc.opus         # Use Opus model
    rpc.sonnet       # Use Sonnet model
    rpc.dev          # Development mode (live + monitor + verbose)
    rpc.install      # Install Ralph for Claude Code
    
    See ALIASES.sh for complete list of 50+ aliases

HELPEOF
}

# Save original args for parallel mode reconstruction
_RALPH_ORIGINAL_ARGS=("$@")

# Parse command line arguments
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
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
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
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CLAUDE_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CLAUDE_ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --no-continue)
            CLAUDE_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CLAUDE_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
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
        --no-worktree)
            WORKTREE_ENABLED=false
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
        spawn_parallel_agents "$PARALLEL_COUNT" ralph "${passthrough_args[@]}"
        exit $?
    fi

    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
