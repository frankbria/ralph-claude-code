#!/usr/bin/env bash
# Mock Functions for Ralph Test Suite

# Mock Claude Code CLI
export MOCK_CLAUDE_SUCCESS=true
export MOCK_CLAUDE_OUTPUT="Test output from Claude Code"
export MOCK_CLAUDE_EXIT_CODE=0

mock_claude_code() {
    if [[ "$MOCK_CLAUDE_SUCCESS" == "true" ]]; then
        echo "$MOCK_CLAUDE_OUTPUT"
        return $MOCK_CLAUDE_EXIT_CODE
    else
        echo "Error: Mock Claude Code failed"
        return 1
    fi
}

# Mock tmux commands
export MOCK_TMUX_AVAILABLE=true
export MOCK_TMUX_SESSION_NAME=""

mock_tmux() {
    local cmd=$1
    shift

    if [[ "$MOCK_TMUX_AVAILABLE" != "true" ]]; then
        echo "tmux: command not found"
        return 127
    fi

    case $cmd in
        new-session)
            # Extract session name from arguments
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -s)
                        MOCK_TMUX_SESSION_NAME=$2
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            echo "Mock: Created tmux session $MOCK_TMUX_SESSION_NAME"
            return 0
            ;;
        split-window)
            echo "Mock: Split tmux window"
            return 0
            ;;
        send-keys)
            echo "Mock: Sent keys to tmux"
            return 0
            ;;
        select-pane)
            echo "Mock: Selected tmux pane"
            return 0
            ;;
        rename-window)
            echo "Mock: Renamed tmux window"
            return 0
            ;;
        attach-session)
            echo "Mock: Attached to tmux session"
            return 0
            ;;
        list-sessions)
            echo "$MOCK_TMUX_SESSION_NAME: 1 windows"
            return 0
            ;;
        *)
            echo "Mock: Unknown tmux command: $cmd"
            return 1
            ;;
    esac
}

# Mock jq for JSON processing
mock_jq() {
    # Simple mock that handles basic queries
    local filter=$1
    local file=$2

    if [[ ! -f "$file" ]]; then
        echo "jq: $file: No such file or directory" >&2
        return 1
    fi

    # Handle common jq patterns
    case $filter in
        "empty")
            # Validate JSON
            if grep -q "{" "$file"; then
                return 0
            else
                return 1
            fi
            ;;
        ".test_only_loops | length")
            grep -o '"test_only_loops":\s*\[[^]]*\]' "$file" | grep -o "\[.*\]" | grep -o "," | wc -l | awk '{print $1+1}'
            ;;
        ".done_signals | length")
            grep -o '"done_signals":\s*\[[^]]*\]' "$file" | grep -o "\[.*\]" | grep -o "," | wc -l | awk '{print $1+1}'
            ;;
        *)
            # Use real jq if available
            if command -v jq &>/dev/null; then
                command jq "$@"
            else
                echo "0"
            fi
            ;;
    esac
}

# Mock git commands
export MOCK_GIT_AVAILABLE=true
export MOCK_GIT_REPO=true

mock_git() {
    local cmd=$1
    shift

    if [[ "$MOCK_GIT_AVAILABLE" != "true" ]]; then
        echo "git: command not found"
        return 127
    fi

    case $cmd in
        init)
            touch .git
            echo "Mock: Initialized git repository"
            return 0
            ;;
        add)
            echo "Mock: Added files to git"
            return 0
            ;;
        commit)
            echo "Mock: Created git commit"
            return 0
            ;;
        status)
            echo "On branch main"
            echo "nothing to commit, working tree clean"
            return 0
            ;;
        rev-parse)
            if [[ "$MOCK_GIT_REPO" == "true" ]]; then
                echo ".git"
                return 0
            else
                return 1
            fi
            ;;
        branch)
            echo "Mock: Created branch"
            return 0
            ;;
        *)
            echo "Mock: Unknown git command: $cmd"
            return 0
            ;;
    esac
}

# Mock notify-send (Linux notifications)
mock_notify_send() {
    echo "Mock: Notification sent: $*"
    return 0
}

# Mock osascript (macOS notifications)
mock_osascript() {
    echo "Mock: macOS notification sent"
    return 0
}

# Mock stat command (cross-platform file size)
mock_stat() {
    local file=""
    local format=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|-f)
                format=$2
                shift 2
                ;;
            *)
                file=$1
                shift
                ;;
        esac
    done

    if [[ ! -f "$file" ]]; then
        echo "stat: cannot stat '$file': No such file or directory" >&2
        return 1
    fi

    # Return mock file size (1MB)
    echo "1048576"
    return 0
}

# Mock timeout command (Linux)
mock_timeout() {
    local duration=$1
    shift

    # Execute the command without actual timeout
    "$@"
    return $?
}

# Mock gtimeout command (macOS coreutils)
# Same behavior as timeout - both are GNU coreutils timeout commands
mock_gtimeout() {
    local duration=$1
    shift

    # Execute the command without actual timeout
    "$@"
    return $?
}

# Mock portable_timeout (cross-platform wrapper from timeout_utils.sh)
# This mock bypasses the actual timeout detection and just executes the command
mock_portable_timeout() {
    local duration=$1
    shift

    # Execute the command without actual timeout
    "$@"
    return $?
}

# Setup all mocks
setup_mocks() {
    # Replace system commands with mocks
    function claude() { mock_claude_code "$@"; }
    function tmux() { mock_tmux "$@"; }
    function git() { mock_git "$@"; }
    function notify-send() { mock_notify_send "$@"; }
    function osascript() { mock_osascript "$@"; }
    function timeout() { mock_timeout "$@"; }
    function gtimeout() { mock_gtimeout "$@"; }
    function portable_timeout() { mock_portable_timeout "$@"; }

    export -f claude
    export -f tmux
    export -f git
    export -f notify-send
    export -f osascript
    export -f timeout
    export -f gtimeout
    export -f portable_timeout
}

# Teardown all mocks
teardown_mocks() {
    unset -f claude
    unset -f tmux
    unset -f git
    unset -f notify-send
    unset -f osascript
    unset -f timeout
    unset -f gtimeout
    unset -f portable_timeout
}

# Set mock behavior
set_mock_claude_success() { MOCK_CLAUDE_SUCCESS=true; }
set_mock_claude_failure() { MOCK_CLAUDE_SUCCESS=false; }
set_mock_tmux_available() { MOCK_TMUX_AVAILABLE=true; }
set_mock_tmux_unavailable() { MOCK_TMUX_AVAILABLE=false; }
set_mock_git_repo() { MOCK_GIT_REPO=true; }
set_mock_no_git_repo() { MOCK_GIT_REPO=false; }
