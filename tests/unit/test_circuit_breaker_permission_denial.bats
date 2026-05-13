#!/usr/bin/env bats
# Unit Tests for Circuit Breaker permission-denial counter (Issue #243 follow-up)
#
# record_loop_result tracks `consecutive_permission_denials` independently
# of should_exit_gracefully. Without status-aware counting, the wrapper trips
# even after PR #264 — a productive loop with a benign denial still increments
# the counter, and two such loops in a row open the circuit.
#
# Verified against game-one production: 2026-05-13 14:39 UTC, loop 4 merged
# PR #464 successfully (status IN_PROGRESS) but had 4 denied compound-bash
# calls. Combined with loop 3's 2 denials (status IN_PROGRESS), the counter
# went 0→0→1→2 and the circuit opened.

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    export CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    export CB_PERMISSION_DENIAL_THRESHOLD=2

    mkdir -p "$RALPH_DIR"

    source "$SCRIPT_DIR/date_utils.sh"
    source "$SCRIPT_DIR/circuit_breaker.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: write a .response_analysis with given agent status and denial flag.
# Default `files_modified` is 1 to mirror real productive loops (game-one
# loop 4 reported FILES_MODIFIED: 8) — without it the no-progress counter
# would trip on its own, masking the denial-counter behavior we're testing.
write_analysis() {
    local agent_status="$1"
    local has_denials="$2"
    local files_modified="${3:-1}"
    cat > "$RESPONSE_ANALYSIS_FILE" << EOF
{
    "loop_number": 1,
    "analysis": {
        "status": "$agent_status",
        "has_permission_denials": $has_denials,
        "permission_denial_count": $([[ "$has_denials" == "true" ]] && echo 1 || echo 0),
        "denied_commands": $([[ "$has_denials" == "true" ]] && echo '["Bash(some compound)"]' || echo '[]'),
        "exit_signal": false,
        "has_completion_signal": false,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": false,
        "files_modified": $files_modified,
        "asking_questions": false
    }
}
EOF
}

# Helper: read the current denial counter from state file.
get_counter() {
    jq -r '.consecutive_permission_denials' "$CB_STATE_FILE"
}

get_state() {
    jq -r '.state' "$CB_STATE_FILE"
}

@test "denial with STATUS=COMPLETE does not increment counter" {
    write_analysis "COMPLETE" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "0"
    assert_equal "$(get_state)" "CLOSED"
}

@test "denial with STATUS=IN_PROGRESS does not increment counter" {
    write_analysis "IN_PROGRESS" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "0"
    assert_equal "$(get_state)" "CLOSED"
}

@test "denial with STATUS=BLOCKED increments counter" {
    write_analysis "BLOCKED" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "1"
}

@test "denial with STATUS=UNKNOWN increments counter (preserves #101 safety)" {
    write_analysis "UNKNOWN" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "1"
}

@test "denial with no .response_analysis still increments (preserves #101 safety)" {
    rm -f "$RESPONSE_ANALYSIS_FILE"
    # Create a minimal stub the existing code expects, with denial flag but no status
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "has_permission_denials": true
    }
}
EOF
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "1"
}

@test "two consecutive IN_PROGRESS denials do NOT open circuit (game-one repro)" {
    # This is the exact production failure mode: loops 3+4 both had denials,
    # both IN_PROGRESS, and the circuit opened at threshold=2 even though the
    # agent merged a PR in loop 4. The fix must keep this scenario closed.
    write_analysis "IN_PROGRESS" "true"
    record_loop_result 3 0 "false" 1000
    write_analysis "IN_PROGRESS" "true"
    record_loop_result 4 0 "false" 1000

    assert_equal "$(get_counter)" "0"
    assert_equal "$(get_state)" "CLOSED"
}

@test "two consecutive BLOCKED denials open the circuit" {
    write_analysis "BLOCKED" "true"
    record_loop_result 1 0 "false" 1000
    write_analysis "BLOCKED" "true"
    # record_loop_result returns non-zero when it opens the circuit; that's
    # signalling, not an error — use `|| true` so the state-check below runs.
    record_loop_result 2 0 "false" 1000 || true

    assert_equal "$(get_counter)" "2"
    assert_equal "$(get_state)" "OPEN"
}

@test "BLOCKED denial then IN_PROGRESS denial resets counter (recovery)" {
    write_analysis "BLOCKED" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "1"

    # Next loop: still a denial, but agent recovered — counter resets
    write_analysis "IN_PROGRESS" "true"
    record_loop_result 2 0 "false" 1000
    assert_equal "$(get_counter)" "0"
    assert_equal "$(get_state)" "CLOSED"
}

@test "no denial resets counter regardless of status" {
    write_analysis "BLOCKED" "true"
    record_loop_result 1 0 "false" 1000
    assert_equal "$(get_counter)" "1"

    write_analysis "IN_PROGRESS" "false"
    record_loop_result 2 0 "false" 1000
    assert_equal "$(get_counter)" "0"
}
