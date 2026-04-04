#!/usr/bin/env bats
# Integration tests for tmux session management (Issue #14)
# Tests check_tmux_available(), get_tmux_base_index(), and setup_tmux_session()
# from ralph_loop.sh (lines 257-395)

bats_require_minimum_version 1.5.0

load '../helpers/test_helper'

# ==============================================================================
# INLINE FUNCTION DEFINITIONS FOR TESTING
# These mirror the implementations in ralph_loop.sh (lines 257-395).
# IMPORTANT: Keep in sync if ralph_loop.sh changes.
#
# Why inline instead of sourcing ralph_loop.sh directly:
#   ralph_loop.sh has top-level assignments (RALPH_DIR=".ralph", LOG_DIR=...,
#   etc.) that execute at source time and override exported test variables.
#   This is the established project pattern — see test_backup_rollback.bats
#   and test_cli_modern.bats for the same approach.
# ==============================================================================

log_status() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
}

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
    # Forward --output-format if non-default
    if [[ "$CLAUDE_OUTPUT_FORMAT" != "json" ]]; then
        ralph_cmd="$ralph_cmd --output-format $CLAUDE_OUTPUT_FORMAT"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    # Forward --timeout if non-default
    if [[ "$CLAUDE_TIMEOUT_MINUTES" != "15" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CLAUDE_TIMEOUT_MINUTES"
    fi
    # Forward --allowed-tools if non-default
    if [[ "$CLAUDE_ALLOWED_TOOLS" != "Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pytest)" ]]; then
        ralph_cmd="$ralph_cmd --allowed-tools '$CLAUDE_ALLOWED_TOOLS'"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CLAUDE_USE_CONTINUE" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default
    if [[ "$CLAUDE_SESSION_EXPIRY_HOURS" != "24" ]]; then
        ralph_cmd="$ralph_cmd --session-expiry $CLAUDE_SESSION_EXPIRY_HOURS"
    fi
    # Forward --auto-reset-circuit if enabled
    if [[ "$CB_AUTO_RESET" == "true" ]]; then
        ralph_cmd="$ralph_cmd --auto-reset-circuit"
    fi
    # Forward --backup if enabled
    if [[ "$ENABLE_BACKUP" == "true" ]]; then
        ralph_cmd="$ralph_cmd --backup"
    fi

    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd; tmux kill-session -t $session_name 2>/dev/null" Enter

    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:${base_win}.0"

    # Set pane titles
    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Claude Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    # Set window title
    tmux rename-window -t "$session_name:${base_win}" "Ralph: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"

    exit 0
}

# ==============================================================================
# SETUP / TEARDOWN
# ==============================================================================

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    # Standard ralph environment
    export RALPH_DIR=".ralph"
    export RALPH_HOME="${HOME}/.ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export LIVE_LOG_FILE="$RALPH_DIR/live.log"
    export MAX_CALLS_PER_HOUR=100
    export CLAUDE_OUTPUT_FORMAT="json"
    export VERBOSE_PROGRESS=false
    export CLAUDE_TIMEOUT_MINUTES=15
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pytest)"
    export CLAUDE_USE_CONTINUE=true
    export CLAUDE_SESSION_EXPIRY_HOURS=24
    export CB_AUTO_RESET=false
    export ENABLE_BACKUP=false

    mkdir -p "$RALPH_DIR/logs"
    touch "$RALPH_DIR/PROMPT.md"

    # File-based tmux call log — survives subshell boundary (used by 'run' tests)
    export TMUX_CALL_LOG="$TEST_TEMP_DIR/tmux_calls.log"
    > "$TMUX_CALL_LOG"
    export MOCK_TMUX_SESSION_NAME=""

    # Tracking tmux mock: records every invocation to $TMUX_CALL_LOG
    # attach-session returns 0 (does NOT exit) so tests survive the exit 0 in setup_tmux_session
    # show-options returns "0" for get_tmux_base_index
    function tmux() {
        local subcmd="${1:-}"
        shift || true
        echo "tmux ${subcmd} $*" >> "$TMUX_CALL_LOG"
        case "$subcmd" in
            new-session)
                # Capture session name (-s flag)
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -s) MOCK_TMUX_SESSION_NAME="$2"; shift 2 ;;
                        *)  shift ;;
                    esac
                done
                ;;
            show-options)
                echo "0"
                ;;
        esac
        return 0
    }
    export -f tmux
}

teardown() {
    unset -f tmux
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        cd /
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Helper: assert a pattern appears in the tmux call log
assert_tmux_called_with() {
    local pattern="$1"
    if ! grep -qE "$pattern" "$TMUX_CALL_LOG"; then
        echo "Expected tmux call matching: $pattern"
        echo "Actual calls:"
        cat "$TMUX_CALL_LOG"
        return 1
    fi
}

# ==============================================================================
# TEST 1: check_tmux_available returns success when tmux is installed
# ==============================================================================

@test "check_tmux_available returns success when tmux is installed" {
    # The tmux function exported in setup() satisfies 'command -v tmux'
    run check_tmux_available
    [ "$status" -eq 0 ]
}

# ==============================================================================
# TEST 2: check_tmux_available exits 1 when tmux is missing
# ==============================================================================

@test "check_tmux_available exits 1 with install instructions when tmux missing" {
    # Remove the tmux mock function so command -v tmux fails
    unset -f tmux

    # Restrict PATH so no real tmux binary is found
    local original_path="$PATH"
    PATH="/usr/bin:/bin"
    if command -v tmux &>/dev/null; then
        PATH="$original_path"
        skip "Cannot hide tmux from PATH in this environment"
    fi

    run check_tmux_available
    PATH="$original_path"

    [ "$status" -eq 1 ]
    [[ "$output" == *"tmux is not installed"* ]]
    [[ "$output" == *"Install tmux:"* ]]
}

# ==============================================================================
# TEST 3: get_tmux_base_index returns 0 as default
# ==============================================================================

@test "get_tmux_base_index returns 0 as default" {
    local result
    result=$(get_tmux_base_index)
    [ "$result" -eq 0 ]
    assert_tmux_called_with "tmux show-options"
}

# ==============================================================================
# TEST 4: setup_tmux_session creates session with -d flag and ralph- prefix
# ==============================================================================

@test "setup_tmux_session creates detached session with ralph- prefix" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    assert_tmux_called_with "tmux new-session -d -s ralph-[0-9]+"
}

# ==============================================================================
# TEST 5: setup_tmux_session splits window horizontally for vertical pane layout
# ==============================================================================

@test "setup_tmux_session splits window horizontally to create vertical panes" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    assert_tmux_called_with "tmux split-window -h"
}

# ==============================================================================
# TEST 6: setup_tmux_session adds second split (-v) for 3-pane layout
# ==============================================================================

@test "setup_tmux_session adds vertical split for 3-pane layout" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    assert_tmux_called_with "tmux split-window -v"
}

# ==============================================================================
# TEST 7: setup_tmux_session starts tail -f in right-top pane (pane 1)
# ==============================================================================

@test "setup_tmux_session starts live log tail in right-top pane" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    # pane 1 receives 'tail -f' for the live log file
    assert_tmux_called_with "tmux send-keys -t .+\.1 tail -f"
}

# ==============================================================================
# TEST 8: setup_tmux_session starts ralph-monitor or ralph_monitor.sh in pane 2
# ==============================================================================

@test "setup_tmux_session starts monitor in right-bottom pane" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    # pane 2 receives either ralph-monitor or ralph_monitor.sh
    assert_tmux_called_with "tmux send-keys -t .+\.2 .*(ralph-monitor|ralph_monitor\.sh)"
}

# ==============================================================================
# TEST 9: setup_tmux_session starts ralph loop in left pane without --monitor
# ==============================================================================

@test "setup_tmux_session starts ralph loop in left pane without --monitor flag" {
    run setup_tmux_session
    [ "$status" -eq 0 ]

    # pane 0 receives the ralph command
    assert_tmux_called_with "tmux send-keys -t .+\.0 .*(ralph|ralph_loop\.sh)"

    # --monitor must NOT appear in the left-pane command (would cause infinite recursion)
    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t .+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" != *"--monitor"* ]]
}

# ==============================================================================
# TEST 10: setup_tmux_session always adds --live to the loop command
# ==============================================================================

@test "setup_tmux_session includes --live in loop command" {
    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t .+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--live"* ]]
}

# ==============================================================================
# TEST 11: setup_tmux_session sets window title to correct string
# ==============================================================================

@test "setup_tmux_session sets window title to 'Ralph: Loop | Output | Status'" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    assert_tmux_called_with "tmux rename-window.*Ralph: Loop \| Output \| Status"
}

# ==============================================================================
# TEST 12: setup_tmux_session focuses left pane after setup
# ==============================================================================

@test "setup_tmux_session focuses left pane (pane 0) after setup" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    # Anchor at end-of-line so this only matches the bare focus call (no -T flag).
    # Without the anchor, title-setting calls like "select-pane -t S:0.0 -T Ralph Loop"
    # would also match, hiding regressions in pane-focus behaviour.
    assert_tmux_called_with '^tmux select-pane -t [^ ]+\.0$'
}

# ==============================================================================
# TEST 13: setup_tmux_session forwards --calls when non-default
# ==============================================================================

@test "setup_tmux_session forwards custom --calls to loop command" {
    export MAX_CALLS_PER_HOUR=50

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t .+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--calls 50"* ]]
}

# ==============================================================================
# TEST 14: setup_tmux_session forwards --prompt when non-default
# ==============================================================================

@test "setup_tmux_session forwards custom --prompt to loop command" {
    export PROMPT_FILE="$RALPH_DIR/custom_prompt.md"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t .+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--prompt"* ]]
}

# ==============================================================================
# TEST 15: session name follows ralph-EPOCH format
# ==============================================================================

@test "setup_tmux_session generates session name with current unix timestamp" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    # Extract the epoch from the session name and verify it is within 5 seconds of now.
    # This is distinct from test 4 (which only checks format): here we confirm the
    # implementation actually uses date +%s rather than a static or arbitrary value.
    local ts now delta
    ts=$(grep "^tmux new-session" "$TMUX_CALL_LOG" | grep -oE '[0-9]{10,}' | head -1)
    now=$(date +%s)
    delta=$(( now - ts ))
    [ "$delta" -ge 0 ] && [ "$delta" -le 5 ]
}

# ==============================================================================
# TEST 16: detach/reattach instructions appear in output
# ==============================================================================

@test "setup_tmux_session logs detach and reattach instructions" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ctrl+B"* ]]
    [[ "$output" == *"tmux attach"* ]]
}

# ==============================================================================
# TEST 17: two invocations each create their own new-session call
# ==============================================================================

@test "two concurrent setup_tmux_session invocations each create a tmux new-session call" {
    # Launch both invocations as true concurrent background subshells.
    # Each subshell inherits the tmux mock and appends to the shared TMUX_CALL_LOG.
    ( setup_tmux_session ) &
    local pid1=$!
    ( setup_tmux_session ) &
    local pid2=$!
    wait "$pid1" "$pid2"

    # Both must have issued new-session — two entries in the log
    local count
    count=$(grep -c "^tmux new-session" "$TMUX_CALL_LOG")
    [ "$count" -eq 2 ]
}
