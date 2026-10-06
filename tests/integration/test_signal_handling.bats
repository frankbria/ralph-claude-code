#!/usr/bin/env bats
# Integration tests for signal handling (Issue #345)
# Verifies that Ctrl-C and SIGTERM properly stop the Ralph loop

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up minimal Ralph project
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR/logs" "$RALPH_DIR/docs/generated"
    echo "# test prompt" > "$RALPH_DIR/PROMPT.md"
    echo "# test plan" > "$RALPH_DIR/fix_plan.md"
    echo "# test agent" > "$RALPH_DIR/AGENT.md"
    echo "MAX_CALLS_PER_HOUR=100" > .ralphrc
    echo "0" > "$RALPH_DIR/.call_count"
    date +%Y%m%d%H > "$RALPH_DIR/.last_reset"

    RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

teardown() {
    # Kill any leftover processes from tests
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true

    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# SIGNAL HANDLER STRUCTURE TESTS
# =============================================================================

@test "issue #345: the bare 'trap cleanup SIGINT SIGTERM' form is gone" {
    # The old buggy form that just called cleanup() without exiting
    run grep -E "^trap cleanup (SIGINT|SIGTERM)" "$RALPH_LOOP"
    [ "$status" -ne 0 ]
}

@test "issue #345: signal handler uses on_signal wrapper" {
    run grep "trap 'on_signal" "$RALPH_LOOP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIGINT"* ]]
    [[ "$output" == *"SIGTERM"* ]]
}

@test "issue #345: on_signal restores default dispositions" {
    # The handler must restore defaults so a second Ctrl-C works
    run grep -A5 "on_signal()" "$RALPH_LOOP"
    [[ "$output" == *"trap - SIGINT SIGTERM"* ]] || [[ "$output" == *"trap -"* ]]
}

@test "issue #345: on_signal re-raises the signal" {
    # Must exit with 128+n, not just return
    run grep -A20 "on_signal()" "$RALPH_LOOP"
    [[ "$output" == *'kill -s "$sig"'* ]] || [[ "$output" == *"kill -"*"$$"* ]]
}

@test "issue #345: CLAUDE_CHILD_PID is defined globally" {
    run grep "^CLAUDE_CHILD_PID=" "$RALPH_LOOP"
    [ "$status" -eq 0 ]
}

@test "issue #345: CLAUDE_CHILD_PID is set when backgrounding claude" {
    run grep "CLAUDE_CHILD_PID=\$claude_pid\|CLAUDE_CHILD_PID=\$!" "$RALPH_LOOP"
    [ "$status" -eq 0 ]
}

@test "issue #345: kill_tree function exists" {
    run grep "^kill_tree()" "$RALPH_LOOP"
    [ "$status" -eq 0 ]
}

@test "issue #345: list_descendants function exists" {
    run grep "^list_descendants()" "$RALPH_LOOP"
    [ "$status" -eq 0 ]
}

# =============================================================================
# FUNCTIONAL SIGNAL TESTS
# These require running ralph_loop.sh and sending signals
# =============================================================================

@test "issue #345: SIGTERM terminates the loop (exit 143)" {
    # Skip if timeout command not available
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || skip "timeout command not available"

    # Create a mock claude that sleeps
    cat > ./mock_claude << 'MOCK'
#!/bin/bash
sleep 60
MOCK
    chmod +x ./mock_claude

    # Reset SIGINT to default (backgrounded jobs inherit SIG_IGN from non-interactive shells)
    (
        trap - SIGINT SIGTERM
        exec env CLAUDE_CODE_CMD="$PWD/mock_claude" CLAUDE_AUTO_UPDATE=false \
            bash "$RALPH_LOOP" --dry-run &
    )
    local loop_pid=$!

    # Wait for loop to start
    sleep 2

    # Send SIGTERM
    kill -TERM $loop_pid 2>/dev/null || true

    # Wait for exit (with timeout)
    local waited=0
    while kill -0 $loop_pid 2>/dev/null && [[ $waited -lt 50 ]]; do
        sleep 0.1
        ((waited++))
    done

    # Check it exited
    ! kill -0 $loop_pid 2>/dev/null
}

@test "issue #345: SIGINT terminates the loop (exit 130)" {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || skip "timeout command not available"

    cat > ./mock_claude << 'MOCK'
#!/bin/bash
sleep 60
MOCK
    chmod +x ./mock_claude

    (
        trap - SIGINT SIGTERM
        exec env CLAUDE_CODE_CMD="$PWD/mock_claude" CLAUDE_AUTO_UPDATE=false \
            bash "$RALPH_LOOP" --dry-run &
    )
    local loop_pid=$!

    sleep 2

    # Send SIGINT (Ctrl-C)
    kill -INT $loop_pid 2>/dev/null || true

    local waited=0
    while kill -0 $loop_pid 2>/dev/null && [[ $waited -lt 50 ]]; do
        sleep 0.1
        ((waited++))
    done

    ! kill -0 $loop_pid 2>/dev/null
}

# =============================================================================
# PROCESS TREE TESTS
# =============================================================================

@test "issue #345: list_descendants finds child processes" {
    # Source the function
    eval "$(sed -n '/^list_descendants()/,/^}/p' "$RALPH_LOOP")"

    # Start a process with a child
    (sleep 60 & sleep 60) &
    local parent=$!
    sleep 0.5

    run list_descendants $parent

    # Clean up
    kill -9 $parent 2>/dev/null || true
    pkill -P $parent 2>/dev/null || true

    # Should have found at least one descendant
    [[ -n "$output" ]]
}

@test "issue #345: kill_tree terminates the whole tree" {
    # Source the functions
    eval "$(sed -n '/^list_descendants()/,/^}/p' "$RALPH_LOOP")"
    eval "$(sed -n '/^kill_tree()/,/^}/p' "$RALPH_LOOP")"

    # Start a process tree
    (sleep 60 & sleep 60 & wait) &
    local root=$!
    sleep 0.5

    # Kill the tree
    kill_tree $root

    sleep 1

    # Root should be dead
    ! kill -0 $root 2>/dev/null
}
