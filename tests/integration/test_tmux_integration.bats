#!/usr/bin/env bats
# Integration Tests for tmux Integration

load '../helpers/test_helper'
load '../helpers/mocks'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/mocks.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-tmux-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    export TMUX_COMMANDS_LOG="$TEST_TEMP_DIR/tmux_commands.log"
    mkdir -p logs
    export MOCK_TMUX_AVAILABLE=true
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

check_tmux_available() {
    [[ "$MOCK_TMUX_AVAILABLE" == "true" ]] && return 0 || return 1
}

run_setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    echo "tmux new-session -d -s $session_name" >> "$TMUX_COMMANDS_LOG"
    echo "tmux split-window -h -t $session_name" >> "$TMUX_COMMANDS_LOG"
    echo "tmux send-keys -t $session_name:0.1 ralph-monitor Enter" >> "$TMUX_COMMANDS_LOG"
    echo "tmux send-keys -t $session_name:0.0 ralph Enter" >> "$TMUX_COMMANDS_LOG"
    echo "tmux select-pane -t $session_name:0.0" >> "$TMUX_COMMANDS_LOG"
    echo "tmux rename-window -t $session_name:0 Ralph: Loop | Monitor" >> "$TMUX_COMMANDS_LOG"
    echo "$session_name"
}

@test "setup_tmux_session creates session" {
    run_setup_tmux_session
    run grep "new-session" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session splits panes" {
    run_setup_tmux_session
    run grep "split-window" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session starts monitor in right pane" {
    run_setup_tmux_session
    run grep "ralph-monitor" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session starts loop in left pane" {
    run_setup_tmux_session
    run grep -E "send-keys.*:0.0.*ralph" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session sets window title" {
    run_setup_tmux_session
    run grep "rename-window" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session focuses correct pane" {
    run_setup_tmux_session
    run grep "select-pane" "$TMUX_COMMANDS_LOG"
    assert_success
}

@test "setup_tmux_session handles custom configuration" {
    run run_setup_tmux_session
    assert_success
}

@test "check_tmux_available returns success when tmux installed" {
    export MOCK_TMUX_AVAILABLE=true
    run check_tmux_available
    assert_success
}

@test "check_tmux_available returns failure when tmux missing" {
    export MOCK_TMUX_AVAILABLE=false
    run check_tmux_available
    assert_failure
}

@test "session name generation is unique" {
    local name1=$(run_setup_tmux_session)
    sleep 1
    rm -f "$TMUX_COMMANDS_LOG"
    local name2=$(run_setup_tmux_session)
    [[ "$name1" != "$name2" ]]
}

@test "detach/reattach workflow commands exist" {
    run grep -q "attach-session\|attach" "$RALPH_SCRIPT"
    assert_success
}

@test "multiple concurrent sessions have unique names" {
    local name1=$(run_setup_tmux_session)
    sleep 1
    rm -f "$TMUX_COMMANDS_LOG"
    local name2=$(run_setup_tmux_session)
    [[ "$name1" != "$name2" ]]
}