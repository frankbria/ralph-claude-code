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

# Get the tmux pane-base-index (handles custom tmux configurations)
# Returns: the base pane index (typically 0 or 1)
get_tmux_pane_base_index() {
    local pane_base_index
    pane_base_index=$(tmux show-options -gwv pane-base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${pane_base_index:-0}"
}

# Setup tmux session with monitor
# Load the REAL setup_tmux_session from ralph_loop.sh (an inline mirror drifted
# silently and let forwarding regressions pass untested — PR #363)
eval "$(sed -n '/^setup_tmux_session() {/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

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
    # show-options returns value from MOCK_TMUX_BASE_INDEX / MOCK_TMUX_PANE_BASE_INDEX
    # (both default to 0; override per-test to simulate custom .tmux.conf settings).
    export MOCK_TMUX_BASE_INDEX="0"
    export MOCK_TMUX_PANE_BASE_INDEX="0"
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
                # Resolve which option was requested. Flags like -gv / -gwv
                # precede the option name.
                local opt=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -*) shift ;;
                        *)  opt="$1"; shift ;;
                    esac
                done
                case "$opt" in
                    base-index)      echo "$MOCK_TMUX_BASE_INDEX" ;;
                    pane-base-index) echo "$MOCK_TMUX_PANE_BASE_INDEX" ;;
                    *)               echo "0" ;;
                esac
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
# TEST 3a: setup_tmux_session detects base-index AFTER starting the server
# Regression: with a base-index 1 / pane-base-index 1 config and no tmux server
# running yet (the first `ralph --monitor`), detecting BEFORE new-session made
# `tmux show-options` fail (it does not auto-start a server), silently defaulting
# detection to 0. Every pane/window target was then off-by-one, so the `ralph
# --live` loop command was sent to a nonexistent pane and tmux opened to empty
# idle panes. The fix detects AFTER `tmux new-session` starts the server. This
# test guards the call ORDER: the first `new-session` must precede the first
# `show-options` in the tmux call log.
# ==============================================================================
@test "setup_tmux_session detects base-index only after new-session starts the server" {
    export MOCK_TMUX_BASE_INDEX="1"
    export MOCK_TMUX_PANE_BASE_INDEX="1"
    run setup_tmux_session
    [ "$status" -eq 0 ]

    local new_session_line show_options_line
    new_session_line=$(grep -nE '^tmux new-session -d' "$TMUX_CALL_LOG" | head -1 | cut -d: -f1)
    show_options_line=$(grep -nE '^tmux show-options' "$TMUX_CALL_LOG" | head -1 | cut -d: -f1)

    [ -n "$new_session_line" ]   || { echo "no new-session call logged:"; cat "$TMUX_CALL_LOG"; return 1; }
    [ -n "$show_options_line" ] || { echo "no show-options call logged:"; cat "$TMUX_CALL_LOG"; return 1; }

    # The ordering invariant: server starts first, THEN base-index is queried.
    if [ "$new_session_line" -ge "$show_options_line" ]; then
        echo "FAIL: new-session (line $new_session_line) must precede show-options (line $show_options_line)"
        echo "--- tmux call log ---"
        cat "$TMUX_CALL_LOG"
        return 1
    fi
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
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.1 tail -f"
}

# ==============================================================================
# TEST 8: setup_tmux_session starts ralph-monitor or ralph_monitor.sh in pane 2
# ==============================================================================

@test "setup_tmux_session starts monitor in right-bottom pane" {
    run setup_tmux_session
    [ "$status" -eq 0 ]
    # pane 2 receives either ralph-monitor or ralph_monitor.sh
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.2 .*(ralph-monitor|ralph_monitor\.sh)"
}

# ==============================================================================
# TEST 9: setup_tmux_session starts ralph loop in left pane without --monitor
# ==============================================================================

@test "setup_tmux_session starts ralph loop in left pane without --monitor flag" {
    run setup_tmux_session
    [ "$status" -eq 0 ]

    # pane 0 receives the ralph command
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.0 .*(ralph|ralph_loop\.sh)"

    # --monitor must NOT appear in the left-pane command (would cause infinite recursion)
    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" != *"--monitor"* ]]
}

# ==============================================================================
# TEST 10: setup_tmux_session always adds --live to the loop command
# ==============================================================================

@test "setup_tmux_session includes --live in loop command" {
    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
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
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
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
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--prompt"* ]]
}

# ==============================================================================
# Issue #73: --monitor forwards GitHub issue lifecycle flags to the loop command
# ==============================================================================

@test "setup_tmux_session forwards GitHub lifecycle flags to loop command" {
    export GITHUB_ISSUE="69"
    export COMMENT_PROGRESS=true COMMENT_INTERVAL=3
    export AUTO_CLOSE=true CREATE_PR=true LINK_ISSUE=true
    export CREATE_FOLLOWUPS=true FOLLOWUP_LABEL=followup ADD_COMPLETION_LABELS=done

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--github-issue '69'"* ]]
    [[ "$pane0_line" == *"--comment-progress"* ]]
    [[ "$pane0_line" == *"--comment-interval 3"* ]]
    [[ "$pane0_line" == *"--auto-close"* ]]
    [[ "$pane0_line" == *"--create-pr"* ]]
    [[ "$pane0_line" == *"--link-issue"* ]]
    [[ "$pane0_line" == *"--create-followups"* ]]
    [[ "$pane0_line" == *"--followup-label 'followup'"* ]]
    [[ "$pane0_line" == *"--add-label 'done'"* ]]
}

@test "setup_tmux_session omits lifecycle flags when no issue is tracked" {
    # No GITHUB_ISSUE set -> no lifecycle flags forwarded
    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" != *"--github-issue"* ]]
    [[ "$pane0_line" != *"--auto-close"* ]]
}

# ==============================================================================
# Issue #74: --monitor forwards Docker sandbox flags to the loop command
# ==============================================================================

@test "setup_tmux_session forwards sandbox flags to loop command" {
    export SANDBOX_PROVIDER=docker
    export SANDBOX_DOCKER_IMAGE="node:20"
    export SANDBOX_DOCKER_MEMORY="2g"
    export SANDBOX_DOCKER_CPUS="1.5"
    export SANDBOX_DOCKER_NETWORK="none"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sandbox docker"* ]]
    [[ "$pane0_line" == *"--sandbox-image 'node:20'"* ]]
    [[ "$pane0_line" == *"--sandbox-memory 2g"* ]]
    [[ "$pane0_line" == *"--sandbox-cpus 1.5"* ]]
    [[ "$pane0_line" == *"--sandbox-network none"* ]]
}

@test "setup_tmux_session omits sandbox flags when sandbox disabled" {
    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" != *"--sandbox"* ]]
}

@test "setup_tmux_session forwards sandbox sub-flags even when provider comes from .ralphrc" {
    # setup_tmux_session runs before main() loads .ralphrc — a CLI sub-flag
    # override must survive into the child even though SANDBOX_PROVIDER is
    # not yet set in this process (the child reads it from .ralphrc)
    export SANDBOX_DOCKER_IMAGE="node:20"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sandbox-image 'node:20'"* ]]
    [[ "$pane0_line" != *"--sandbox docker"* ]]
}

# ==============================================================================
# Issue #75: --monitor forwards E2B sandbox flags to the loop command
# ==============================================================================

@test "setup_tmux_session forwards e2b sandbox flags to loop command" {
    export SANDBOX_PROVIDER=e2b
    export SANDBOX_E2B_TEMPLATE="python"
    export SANDBOX_E2B_SANDBOX_ID="sbx_abc123"
    export SANDBOX_E2B_TIMEOUT="7200"
    export SANDBOX_E2B_KEEP_ALIVE="true"
    export SANDBOX_E2B_MAX_COST="5.00"
    export SANDBOX_E2B_COST_ALERT="2.00"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sandbox e2b"* ]]
    [[ "$pane0_line" == *"--sandbox-template 'python'"* ]]
    [[ "$pane0_line" == *"--sandbox-id 'sbx_abc123'"* ]]
    [[ "$pane0_line" == *"--sandbox-timeout 7200"* ]]
    [[ "$pane0_line" == *"--sandbox-keep-alive"* ]]
    [[ "$pane0_line" == *"--sandbox-max-cost 5.00"* ]]
    [[ "$pane0_line" == *"--sandbox-cost-alert 2.00"* ]]
}

@test "setup_tmux_session omits e2b flags at their defaults" {
    export SANDBOX_PROVIDER=e2b

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sandbox e2b"* ]]
    [[ "$pane0_line" != *"--sandbox-template"* ]]
    [[ "$pane0_line" != *"--sandbox-id"* ]]
    [[ "$pane0_line" != *"--sandbox-timeout"* ]]
    [[ "$pane0_line" != *"--sandbox-keep-alive"* ]]
    [[ "$pane0_line" != *"--sandbox-max-cost"* ]]
    [[ "$pane0_line" != *"--sandbox-cost-alert"* ]]
}

# ==============================================================================
# Issue #76: --monitor forwards sandbox sync filter flags to the loop command
# ==============================================================================

@test "setup_tmux_session forwards sync filter flags to loop command" {
    export SANDBOX_PROVIDER=e2b
    export SYNC_INCLUDE="src/**,*.md"
    export SYNC_EXCLUDE="*.log,node_modules"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sync-include 'src/**,*.md'"* ]]
    [[ "$pane0_line" == *"--sync-exclude '*.log,node_modules'"* ]]
}

@test "setup_tmux_session never forwards sync flags to a docker child (codex P2 round 2)" {
    # Env-supplied SYNC_* must not become CLI --sync-* flags when the
    # provider is explicitly docker — the child rejects that pairing and
    # monitor mode would fail to start
    export SANDBOX_PROVIDER=docker
    export SYNC_INCLUDE="src/**"
    export SYNC_EXCLUDE="*.log"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--sandbox docker"* ]]
    [[ "$pane0_line" != *"--sync-include"* ]]
    [[ "$pane0_line" != *"--sync-exclude"* ]]
}

@test "setup_tmux_session rejects CLI sync flags with the docker provider (CodeRabbit, PR #305)" {
    # Non-monitor runs reject --sync-* with --sandbox docker in main();
    # monitor runs exit inside setup_tmux_session before main() ever runs,
    # so the same validation must fire here instead of silently dropping
    # the user's flags
    export SANDBOX_PROVIDER=docker
    export _cli_SYNC_EXCLUDE="*.log"
    export SYNC_EXCLUDE="*.log"

    run setup_tmux_session
    [ "$status" -ne 0 ]
    [[ "$output" == *"bind mount"* ]]
}

@test "setup_tmux_session omits sync filter flags when unset" {
    export SANDBOX_PROVIDER=e2b

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" != *"--sync-include"* ]]
    [[ "$pane0_line" != *"--sync-exclude"* ]]
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
# TEST 18: setup_tmux_session respects pane-base-index 1 (regression)
# ==============================================================================
# When a user's ~/.tmux.conf sets `setw -g pane-base-index 1` (very common in
# popular dotfiles / Oh My Zsh), tmux panes are numbered starting at 1, not 0.
# Previously Ralph hardcoded .0 / .1 / .2, so send-keys to .0 silently failed
# and the Ralph loop never started — leaving two empty panes and a stray
# tail -f. See: https://github.com/frankbria/ralph-claude-code/issues/
@test "setup_tmux_session respects pane-base-index 1 for all pane targets" {
    export MOCK_TMUX_PANE_BASE_INDEX="1"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    # With pane-base-index=1, the 3 panes are .1 (loop), .2 (output), .3 (status)
    # Ralph loop command must target pane .1 (NOT .0 which doesn't exist)
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.1 .*(ralph|ralph_loop\.sh).*--live"
    # live.log tail must target pane .2 (Claude Output)
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.2 tail -f"
    # monitor must target pane .3 (Status)
    assert_tmux_called_with "tmux send-keys -t [^ ]+\.3 .*(ralph-monitor|ralph_monitor\.sh)"
    # No send-keys to .0 — that pane does not exist in this config
    run grep -E '^tmux send-keys -t [^ ]+\.0 ' "$TMUX_CALL_LOG"
    [ "$status" -ne 0 ]
}

# ==============================================================================
# TEST 19: setup_tmux_session handles base-index 1 AND pane-base-index 1
# ==============================================================================
# Both values non-zero is also common (users setting both together). Confirms
# the combination does not regress.
@test "setup_tmux_session respects both base-index and pane-base-index set to 1" {
    export MOCK_TMUX_BASE_INDEX="1"
    export MOCK_TMUX_PANE_BASE_INDEX="1"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    # Window 1 pane 1 = loop, 1.2 = output, 1.3 = status
    assert_tmux_called_with "tmux send-keys -t [^ ]+:1\.1 .*(ralph|ralph_loop\.sh).*--live"
    assert_tmux_called_with "tmux send-keys -t [^ ]+:1\.2 tail -f"
    assert_tmux_called_with "tmux send-keys -t [^ ]+:1\.3 .*(ralph-monitor|ralph_monitor\.sh)"
    assert_tmux_called_with "tmux rename-window -t [^ ]+:1 Ralph: Loop"
}

# ==============================================================================
# TEST 20: get_tmux_pane_base_index returns 0 as default
# ==============================================================================

@test "get_tmux_pane_base_index returns 0 as default" {
    local result
    result=$(get_tmux_pane_base_index)
    [ "$result" -eq 0 ]
    assert_tmux_called_with "tmux show-options.*pane-base-index"
}

# ==============================================================================
# TEST 21: two concurrent setup_tmux_session invocations each create a tmux new-session call
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

@test "setup_tmux_session forwards explicit CLI flags even at their default values (PR #363)" {
    # The child loads the repository .ralphrc; a flag the user typed must be
    # forwarded even when it equals the default, or the file wins in the pane
    export MAX_CALLS_PER_HOUR=100 _cli_MAX_CALLS_PER_HOUR=100
    export CLAUDE_TIMEOUT_MINUTES=15 _cli_CLAUDE_TIMEOUT_MINUTES=15
    export CLAUDE_SESSION_EXPIRY_HOURS=24 _cli_CLAUDE_SESSION_EXPIRY_HOURS=24
    export CLAUDE_OUTPUT_FORMAT=json _cli_CLAUDE_OUTPUT_FORMAT=json
    export ENABLE_NOTIFICATIONS=true _cli_ENABLE_NOTIFICATIONS=true

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--calls 100"* ]]
    [[ "$pane0_line" == *"--timeout 15"* ]]
    [[ "$pane0_line" == *"--session-expiry 24"* ]]
    [[ "$pane0_line" == *"--output-format json"* ]]
    [[ "$pane0_line" == *"--notify"* ]]
}

@test "setup_tmux_session forwards --dry-run and --show-tool-args (PR #363)" {
    # DRY_RUN is not exported: without forwarding, the pane child would make
    # real API calls despite an explicit --monitor --dry-run
    export DRY_RUN=true
    export LIVE_SHOW_TOOL_ARGS=true

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0" "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"--dry-run"* ]]
    [[ "$pane0_line" == *"--show-tool-args"* ]]
}

@test "setup_tmux_session forwards a relocated RALPH_DIR to the loop and monitor panes (#352)" {
    # tmux doesn't import the client environment into a running server, so
    # RALPH_DIR must ride on the pane commands themselves
    export RALPH_DIR=".custom-ralph"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane0_line pane2_line
    pane0_line=$(grep -E "tmux send-keys -t [^ ]+\.0 " "$TMUX_CALL_LOG" | head -1)
    pane2_line=$(grep -E "tmux send-keys -t [^ ]+\.2 " "$TMUX_CALL_LOG" | head -1)
    [[ "$pane0_line" == *"RALPH_DIR=.custom-ralph "* ]]
    [[ "$pane2_line" == *"RALPH_DIR=.custom-ralph "* ]]
}

@test "setup_tmux_session tails an absolute RALPH_DIR's live log without double-pathing (#352)" {
    export RALPH_DIR="/tmp/ralph-abs-state"
    export LIVE_LOG_FILE="$RALPH_DIR/live.log"

    run setup_tmux_session
    [ "$status" -eq 0 ]

    local pane1_line
    pane1_line=$(grep -E "tmux send-keys -t [^ ]+\.1 " "$TMUX_CALL_LOG" | head -1)
    [[ "$pane1_line" == *"tail -f '/tmp/ralph-abs-state/live.log'"* ]] || { echo "$pane1_line"; false; }
}
