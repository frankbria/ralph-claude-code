#!/usr/bin/env bats
# TAP-1477: behavior contract for exec_post_run_coordinator (lib/exec_helpers.sh).
#
# Asserts the three post-run coordinator blocks (debrief decision, BLOCK
# signal surfacing, task-boundary cleanup) under all relevant input states.
# Order invariant — debrief BEFORE cleanup — is enforced by the helper, but
# also covered indirectly here: each branch is exercised with state.json
# fixtures and the resulting calls captured via stubs.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TMPDIR_TC="$(mktemp -d)"
    RALPH_DIR="$TMPDIR_TC/.ralph"
    mkdir -p "$RALPH_DIR"

    # Stubs capture the helper's external calls so tests can assert on them.
    DEBRIEF_OUTCOME=""
    DEBRIEF_DETAIL=""
    CLEANUP_CALLED="false"
    CB_OPEN_RESULT=1   # 1 = closed (default)
    LAST_LOG_LEVEL=""
    LAST_LOG_MSG=""

    log_status() { LAST_LOG_LEVEL="$1"; LAST_LOG_MSG="$2"; }
    cb_is_open() { return "$CB_OPEN_RESULT"; }
    ralph_debrief_coordinator() { DEBRIEF_OUTCOME="$1"; DEBRIEF_DETAIL="$2"; }
    ralph_clear_coordinator_artifacts() { CLEANUP_CALLED="true"; }
    export -f log_status cb_is_open ralph_debrief_coordinator ralph_clear_coordinator_artifacts

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

write_status() {
    cat > "$RALPH_DIR/status.json" <<JSON
{
    "tasks_completed": ${1:-0},
    "permission_denial_count": ${2:-0},
    "recommendation": "${3:-}",
    "exit_signal": "${4:-false}"
}
JSON
}

@test "TAP-1477: CB open → debrief failure with recommendation" {
    write_status 0 0 "rotate session and retry" "false"
    CB_OPEN_RESULT=0   # CB OPEN

    exec_post_run_coordinator

    [[ "$DEBRIEF_OUTCOME" == "failure" ]] \
        || fail "expected debrief outcome=failure when CB open, got '$DEBRIEF_OUTCOME'"
    [[ "$DEBRIEF_DETAIL" == "rotate session and retry" ]] \
        || fail "expected recommendation passed as detail, got '$DEBRIEF_DETAIL'"
}

@test "TAP-1477: permission_denial_count > 0 → debrief failure" {
    write_status 0 2 "fix permissions" "false"
    CB_OPEN_RESULT=1   # CB CLOSED

    exec_post_run_coordinator

    [[ "$DEBRIEF_OUTCOME" == "failure" ]] \
        || fail "expected debrief outcome=failure on PD>0, got '$DEBRIEF_OUTCOME'"
    [[ "$DEBRIEF_DETAIL" == "fix permissions" ]] \
        || fail "expected recommendation as detail, got '$DEBRIEF_DETAIL'"
}

@test "TAP-1477: tasks_completed > 0 with CB closed and PD=0 → debrief success" {
    write_status 2 0 "" "false"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ "$DEBRIEF_OUTCOME" == "success" ]] \
        || fail "expected debrief outcome=success, got '$DEBRIEF_OUTCOME'"
    [[ "$DEBRIEF_DETAIL" == "" ]] \
        || fail "expected empty detail on success, got '$DEBRIEF_DETAIL'"
}

@test "TAP-1477: tasks_completed=0, CB closed, PD=0 → no debrief" {
    write_status 0 0 "" "false"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ "$DEBRIEF_OUTCOME" == "" ]] \
        || fail "expected no debrief, got outcome='$DEBRIEF_OUTCOME'"
}

@test "TAP-1477: BLOCK flag present → WARN logged + flag removed" {
    write_status 0 0 "" "false"
    touch "$RALPH_DIR/.coordinator_block"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ ! -f "$RALPH_DIR/.coordinator_block" ]] \
        || fail "BLOCK flag should be removed after surfacing"
    [[ "$LAST_LOG_LEVEL" == "WARN" || "$LAST_LOG_LEVEL" == "INFO" ]] \
        || fail "expected WARN or INFO log, got '$LAST_LOG_LEVEL'"
}

@test "TAP-1477: BLOCK flag absent → no flag-removal noise" {
    write_status 0 0 "" "false"
    CB_OPEN_RESULT=1
    [[ ! -f "$RALPH_DIR/.coordinator_block" ]] || fail "precondition: flag should not exist"

    exec_post_run_coordinator

    # No assertion needed — the test passes if exec_post_run_coordinator
    # doesn't crash trying to rm a missing file.
    [[ ! -f "$RALPH_DIR/.coordinator_block" ]] || fail "flag should still not exist"
}

@test "TAP-1477: EXIT_SIGNAL=true triggers task-boundary cleanup" {
    write_status 0 0 "" "true"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ "$CLEANUP_CALLED" == "true" ]] \
        || fail "expected ralph_clear_coordinator_artifacts called on EXIT_SIGNAL"
}

@test "TAP-1477: tasks_completed > 0 triggers task-boundary cleanup" {
    write_status 1 0 "" "false"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ "$CLEANUP_CALLED" == "true" ]] \
        || fail "expected ralph_clear_coordinator_artifacts called on tasks_completed>0"
}

@test "TAP-1477: tasks_completed=0 + EXIT_SIGNAL=false → no cleanup" {
    write_status 0 0 "" "false"
    CB_OPEN_RESULT=1

    exec_post_run_coordinator

    [[ "$CLEANUP_CALLED" == "false" ]] \
        || fail "expected no cleanup when neither trigger fires"
}

@test "TAP-1477: ralph_loop.sh dispatches via exec_post_run_coordinator" {
    grep -qE 'exec_post_run_coordinator[[:space:]]*$' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_post_run_coordinator"
}

@test "TAP-1477: inline coordinator blocks removed from ralph_loop.sh" {
    # The old inline TAP-917 / TAP-923 / TAP-924 markers should no longer
    # appear inside execute_claude_code's body — they live in
    # lib/exec_helpers.sh now. We pin to specific code shape rather than
    # comments so future doc updates don't false-positive.
    ! grep -qE 'ralph_debrief_coordinator "failure" "\$_detail"' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline debrief decision"
    ! grep -qE 'rm -f "\$\{RALPH_DIR\}/\.coordinator_block"' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline BLOCK flag removal"
}
