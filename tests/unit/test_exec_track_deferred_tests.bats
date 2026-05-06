#!/usr/bin/env bats
# TAP-1475: behavior contract for exec_track_deferred_tests (lib/exec_helpers.sh).
#
# Tests the TESTS_STATUS:DEFERRED state machine — counter increments, threshold
# WARN, and 2× threshold CB-trip — without invoking the actual circuit breaker.
# Tests the *trip* branch indirectly: assert CB_STATE_FILE is written with the
# expected contents and that the helper attempts to break (we cannot test the
# actual break inside a non-loop test context, but we can assert the file
# write that immediately precedes it).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TMPDIR_TC="$(mktemp -d)"
    RALPH_DIR="$TMPDIR_TC/.ralph"
    mkdir -p "$RALPH_DIR"
    CB_STATE_FILE="$TMPDIR_TC/cb_state.json"
    CB_STATE_OPEN="OPEN"
    CB_MAX_DEFERRED_TESTS=3
    CONSECUTIVE_DEFERRED_TEST_COUNT=0

    # Capture-stub external functions used by the helper.
    LAST_LOG_LEVEL=""
    LAST_LOG_MSG=""
    LAST_RESET_REASON=""
    LAST_UPDATE_STATUS_ARGS=""
    log_status() { LAST_LOG_LEVEL="$1"; LAST_LOG_MSG="$2"; }
    reset_session() { LAST_RESET_REASON="$1"; }
    update_status() { LAST_UPDATE_STATUS_ARGS="$*"; }
    get_iso_timestamp() { echo "2026-05-06T16:00:00Z"; }
    _read_call_count() { echo "5"; }
    export -f log_status reset_session update_status get_iso_timestamp _read_call_count

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

write_status() {
    local tests_status="$1"
    cat > "$RALPH_DIR/status.json" <<JSON
{"tests_status":"$tests_status"}
JSON
}

@test "TAP-1475: PASSING resets counter to 0" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=2
    write_status "PASSING"
    exec_track_deferred_tests 1
    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq 0 ]] \
        || fail "expected counter=0 after PASSING, got $CONSECUTIVE_DEFERRED_TEST_COUNT"
}

@test "TAP-1475: UNKNOWN resets counter to 0" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=4
    write_status "UNKNOWN"
    exec_track_deferred_tests 1
    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq 0 ]] \
        || fail "expected counter=0 after UNKNOWN, got $CONSECUTIVE_DEFERRED_TEST_COUNT"
}

@test "TAP-1475: missing status.json resets counter to 0 (jq fallback)" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=4
    rm -f "$RALPH_DIR/status.json"
    exec_track_deferred_tests 1
    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq 0 ]] \
        || fail "expected counter=0 with missing status.json, got $CONSECUTIVE_DEFERRED_TEST_COUNT"
}

@test "TAP-1475: DEFERRED below threshold increments silently" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=0
    write_status "DEFERRED"
    exec_track_deferred_tests 1
    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq 1 ]] \
        || fail "expected counter=1, got $CONSECUTIVE_DEFERRED_TEST_COUNT"
    [[ "$LAST_LOG_LEVEL" == "" ]] \
        || fail "expected no log below threshold, got '$LAST_LOG_LEVEL: $LAST_LOG_MSG'"
}

@test "TAP-1475: DEFERRED at threshold (CB_MAX_DEFERRED_TESTS) WARNs without tripping" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=$((CB_MAX_DEFERRED_TESTS - 1))  # =2 → next call makes it 3
    write_status "DEFERRED"
    exec_track_deferred_tests 1
    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq "$CB_MAX_DEFERRED_TESTS" ]] \
        || fail "expected counter=$CB_MAX_DEFERRED_TESTS, got $CONSECUTIVE_DEFERRED_TEST_COUNT"
    [[ "$LAST_LOG_LEVEL" == "WARN" ]] \
        || fail "expected WARN level at threshold, got '$LAST_LOG_LEVEL'"
    [[ "$LAST_LOG_MSG" == *"possible environment issue"* ]] \
        || fail "expected environment-issue WARN, got '$LAST_LOG_MSG'"
    # CB should NOT have been tripped at 1× threshold
    [[ ! -f "$CB_STATE_FILE" ]] \
        || fail "CB_STATE_FILE should not be written at 1× threshold"
}

# The 2×-threshold branch ends with `break`, which behaves differently inside a
# test context (no enclosing loop). Wrap the call in a synthetic while loop so
# `break` exits cleanly and we can inspect side effects after.
run_with_break_loop() {
    local i=0
    while [[ $i -lt 1 ]]; do
        i=$((i + 1))
        exec_track_deferred_tests "$1"
    done
}

@test "TAP-1475: DEFERRED at 2× threshold trips CB and writes CB_STATE_FILE" {
    CONSECUTIVE_DEFERRED_TEST_COUNT=$((CB_MAX_DEFERRED_TESTS * 2 - 1))  # =5 → next makes it 6
    write_status "DEFERRED"
    run_with_break_loop 7

    [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -eq $((CB_MAX_DEFERRED_TESTS * 2)) ]] \
        || fail "expected counter=$((CB_MAX_DEFERRED_TESTS * 2)), got $CONSECUTIVE_DEFERRED_TEST_COUNT"
    [[ "$LAST_LOG_LEVEL" == "ERROR" ]] \
        || fail "expected ERROR log on trip, got '$LAST_LOG_LEVEL'"
    [[ "$LAST_LOG_MSG" == *"Tripping circuit breaker"* ]] \
        || fail "expected trip message, got '$LAST_LOG_MSG'"
    [[ "$LAST_RESET_REASON" == "persistent_test_deferral" ]] \
        || fail "expected reset_session called with persistent_test_deferral, got '$LAST_RESET_REASON'"
    [[ -f "$CB_STATE_FILE" ]] \
        || fail "CB_STATE_FILE should be written on trip"

    # Verify CB state file contents
    local state reason
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]] || fail "expected state=OPEN, got '$state'"
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    [[ "$reason" == *"persistent_test_deferral"* ]] \
        || fail "expected persistent_test_deferral in reason, got '$reason'"
    local consecutive
    consecutive=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    [[ "$consecutive" -eq $((CB_MAX_DEFERRED_TESTS * 2)) ]] \
        || fail "expected consecutive_no_progress=$((CB_MAX_DEFERRED_TESTS * 2)), got '$consecutive'"
}

@test "TAP-1475: 2× trip increments existing total_opens count" {
    # Pre-existing CB state with total_opens=4
    cat > "$CB_STATE_FILE" <<'JSON'
{"state":"CLOSED","total_opens":4}
JSON
    CONSECUTIVE_DEFERRED_TEST_COUNT=$((CB_MAX_DEFERRED_TESTS * 2 - 1))
    write_status "DEFERRED"
    run_with_break_loop 9

    local total_opens
    total_opens=$(jq -r '.total_opens' "$CB_STATE_FILE")
    [[ "$total_opens" -eq 5 ]] \
        || fail "expected total_opens incremented 4→5, got '$total_opens'"
}

@test "TAP-1475: ralph_loop.sh dispatches via exec_track_deferred_tests" {
    grep -qE 'exec_track_deferred_tests[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_track_deferred_tests"
}

@test "TAP-1475: inline DEFERRED counter block removed from ralph_loop.sh" {
    # The old inline `if [[ "$_tests_status" == "DEFERRED" ]]; then` block
    # immediately followed by CONSECUTIVE_DEFERRED_TEST_COUNT++ should be gone.
    ! grep -qE 'CONSECUTIVE_DEFERRED_TEST_COUNT=\$\(\(CONSECUTIVE_DEFERRED_TEST_COUNT \+ 1\)\)' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline counter increment"
}
