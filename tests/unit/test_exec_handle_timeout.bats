#!/usr/bin/env bats
# TAP-1476: behavior contract for exec_handle_timeout (lib/exec_helpers.sh).
#
# Focuses on the unproductive-timeout state machine — counter increment, CB
# trip at MAX_CONSECUTIVE_TIMEOUTS, CB_STATE_FILE write — which is the
# testable portion. The productive-timeout branch (return 0) is covered
# indirectly: it ends with a direct return 0 from a single helper call chain
# whose individual helpers (save_claude_session, ralph_debrief_coordinator,
# etc.) are tested elsewhere. Mocking that whole chain to assert return 0
# without re-testing each helper would duplicate existing coverage.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TMPDIR_TC="$(mktemp -d)"
    OUT="$TMPDIR_TC/out.json"
    PROGRESS_FILE="$TMPDIR_TC/progress.json"
    STATUS_FILE="$TMPDIR_TC/status.json"
    CB_STATE_FILE="$TMPDIR_TC/cb_state.json"
    CB_STATE_OPEN="OPEN"
    MAX_CONSECUTIVE_TIMEOUTS=3
    CONSECUTIVE_TIMEOUT_COUNT=0
    RALPH_DIR="$TMPDIR_TC/.ralph"
    mkdir -p "$RALPH_DIR"

    # Stub external functions used in the unproductive branch only.
    LAST_LOG_LEVEL=""
    LAST_LOG_MSG=""
    log_status() { LAST_LOG_LEVEL="$1"; LAST_LOG_MSG="$2"; }
    get_iso_timestamp() { echo "2026-05-06T16:30:00Z"; }
    # ralph_has_real_changes returns 1 (no changes) by default for these tests.
    # Tests covering the productive branch override this.
    ralph_has_real_changes() { return 1; }
    export -f log_status get_iso_timestamp ralph_has_real_changes

    # Fake output file so jq reads inside the helper do not crash.
    echo '{}' > "$RALPH_DIR/status.json"
    echo '{}' > "$OUT"

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

@test "TAP-1476: unproductive timeout below threshold → counter increments + return 1" {
    CONSECUTIVE_TIMEOUT_COUNT=0
    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1, got $rc"
    [[ "$CONSECUTIVE_TIMEOUT_COUNT" -eq 1 ]] \
        || fail "expected counter=1, got $CONSECUTIVE_TIMEOUT_COUNT"
    [[ ! -f "$CB_STATE_FILE" ]] \
        || fail "CB_STATE_FILE should not exist below threshold"
}

@test "TAP-1476: unproductive timeout at threshold − 1 → counter increments without trip" {
    CONSECUTIVE_TIMEOUT_COUNT=$((MAX_CONSECUTIVE_TIMEOUTS - 2))  # =1 → next makes it 2
    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1, got $rc"
    [[ "$CONSECUTIVE_TIMEOUT_COUNT" -eq $((MAX_CONSECUTIVE_TIMEOUTS - 1)) ]] \
        || fail "expected counter=$((MAX_CONSECUTIVE_TIMEOUTS - 1)), got $CONSECUTIVE_TIMEOUT_COUNT"
    [[ ! -f "$CB_STATE_FILE" ]] \
        || fail "CB should not be tripped one short of threshold"
}

@test "TAP-1476: hitting MAX_CONSECUTIVE_TIMEOUTS → return 3, CB tripped, STATUS_FILE written" {
    CONSECUTIVE_TIMEOUT_COUNT=$((MAX_CONSECUTIVE_TIMEOUTS - 1))
    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 3 ]] || fail "expected return 3 on trip, got $rc"
    [[ "$CONSECUTIVE_TIMEOUT_COUNT" -eq "$MAX_CONSECUTIVE_TIMEOUTS" ]] \
        || fail "expected counter=$MAX_CONSECUTIVE_TIMEOUTS, got $CONSECUTIVE_TIMEOUT_COUNT"
    [[ -f "$CB_STATE_FILE" ]] || fail "CB_STATE_FILE should be written on trip"
    [[ -f "$STATUS_FILE" ]] || fail "STATUS_FILE should be written on trip"

    # CB state contents
    local state reason
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]] || fail "expected state=OPEN, got '$state'"
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    [[ "$reason" == *"consecutive_timeouts"* ]] \
        || fail "expected consecutive_timeouts reason, got '$reason'"

    # STATUS_FILE contents
    local status_value
    status_value=$(jq -r '.status' "$STATUS_FILE")
    [[ "$status_value" == "HALTED" ]] || fail "expected status=HALTED, got '$status_value'"
    local halt_reason
    halt_reason=$(jq -r '.reason' "$STATUS_FILE")
    [[ "$halt_reason" == "consecutive_timeouts" ]] \
        || fail "expected reason=consecutive_timeouts, got '$halt_reason'"
}

@test "TAP-1476: trip increments existing total_opens counter" {
    cat > "$CB_STATE_FILE" <<'JSON'
{"state":"CLOSED","total_opens":2}
JSON
    CONSECUTIVE_TIMEOUT_COUNT=$((MAX_CONSECUTIVE_TIMEOUTS - 1))
    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 3 ]] || fail "expected return 3, got $rc"

    local total_opens
    total_opens=$(jq -r '.total_opens' "$CB_STATE_FILE")
    [[ "$total_opens" -eq 3 ]] \
        || fail "expected total_opens incremented 2→3, got '$total_opens'"
}

@test "TAP-1476: ralph_loop.sh dispatches via exec_handle_timeout" {
    grep -qE 'exec_handle_timeout[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_handle_timeout"
}

@test "TAP-1476: inline timeout block removed from ralph_loop.sh" {
    # The old inline GUARD-1 / GUARD-2 markers should no longer appear in
    # ralph_loop.sh — they live in lib/exec_helpers.sh now.
    ! grep -qE 'CONSECUTIVE_TIMEOUT_COUNT=\$\(\(CONSECUTIVE_TIMEOUT_COUNT \+ 1\)\)' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline counter increment"
}

@test "TAP-1476: productive timeout (real changes) returns 0" {
    # Override the default stub: simulate productive timeout with real changes
    # detected, then mock the helpers it needs.
    ralph_has_real_changes() { return 0; }
    _count_files_changed_since_loop_start() { echo "3"; }
    ralph_record_latency() { :; }
    ralph_prepare_claude_output_for_analysis() { :; }
    save_claude_session() { :; }
    update_exit_signals_from_status() { return 0; }
    log_status_summary() { return 0; }
    ralph_debrief_coordinator() { :; }
    ralph_clear_coordinator_artifacts() { :; }
    cb_is_open() { return 1; }   # CB closed
    export -f ralph_has_real_changes _count_files_changed_since_loop_start \
              ralph_record_latency ralph_prepare_claude_output_for_analysis \
              save_claude_session update_exit_signals_from_status \
              log_status_summary ralph_debrief_coordinator \
              ralph_clear_coordinator_artifacts cb_is_open

    CLAUDE_USE_CONTINUE="false"
    CONSECUTIVE_TIMEOUT_COUNT=2

    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 on productive timeout, got $rc"
    # GUARD-2 reset: counter should be 0 after productive timeout
    [[ "$CONSECUTIVE_TIMEOUT_COUNT" -eq 0 ]] \
        || fail "expected counter reset to 0 after productive timeout, got $CONSECUTIVE_TIMEOUT_COUNT"
    # PROGRESS_FILE should be marked timed_out_productive
    grep -q '"status": "timed_out_productive"' "$PROGRESS_FILE" \
        || fail "PROGRESS_FILE should be marked timed_out_productive"
}

@test "TAP-1476: productive timeout but CB opened during loop → return 3" {
    ralph_has_real_changes() { return 0; }
    _count_files_changed_since_loop_start() { echo "1"; }
    ralph_record_latency() { :; }
    ralph_prepare_claude_output_for_analysis() { :; }
    save_claude_session() { :; }
    update_exit_signals_from_status() { return 0; }
    log_status_summary() { return 0; }
    ralph_debrief_coordinator() { :; }
    ralph_clear_coordinator_artifacts() { :; }
    cb_is_open() { return 0; }   # CB OPEN — on-stop hook tripped it
    export -f ralph_has_real_changes _count_files_changed_since_loop_start \
              ralph_record_latency ralph_prepare_claude_output_for_analysis \
              save_claude_session update_exit_signals_from_status \
              log_status_summary ralph_debrief_coordinator \
              ralph_clear_coordinator_artifacts cb_is_open

    CLAUDE_USE_CONTINUE="false"

    local rc=0
    exec_handle_timeout "$OUT" "" || rc=$?
    [[ "$rc" -eq 3 ]] || fail "expected return 3 when CB is open, got $rc"
}
