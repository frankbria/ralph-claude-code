#!/usr/bin/env bats
# Unit tests for the E2E harness assertion helpers (Issue #285)
#
# The hourly rate-limit reset (init_call_tracking) legitimately zeroes
# .ralph/.call_count whenever `date +%Y%m%d%H` changes mid-run, so raw
# counter assertions in the E2E suite must be conditional: assert_call_count
# only checks the value when the recorded run-start hour still matches the
# current hour (mock_call_count remains the unconditional invocation proof).

load '../helpers/test_helper'
load '../e2e/helpers/e2e_helper'

setup() {
    E2E_DIR="$(mktemp -d)"
    PROJECT_DIR="$E2E_DIR/project"
    mkdir -p "$PROJECT_DIR/.ralph"
    cd "$PROJECT_DIR"
}

teardown() {
    cd /
    if [[ -n "$E2E_DIR" && -d "$E2E_DIR" ]]; then
        rm -rf "$E2E_DIR"
    fi
}

# =============================================================================
# e2e_mark_run_start / e2e_hour_rolled_over
# =============================================================================

@test "e2e_mark_run_start records the current hour" {
    e2e_mark_run_start

    assert_equal "$(cat "$E2E_DIR/.run_start_hour")" "$(date +%Y%m%d%H)"
}

@test "e2e_hour_rolled_over is false when the hour has not changed" {
    e2e_mark_run_start

    run e2e_hour_rolled_over
    assert_failure
}

@test "e2e_hour_rolled_over is true when the recorded hour is stale" {
    echo "2020010100" > "$E2E_DIR/.run_start_hour"

    run e2e_hour_rolled_over
    assert_success
}

@test "e2e_hour_rolled_over is false when no run start was recorded" {
    rm -f "$E2E_DIR/.run_start_hour"

    run e2e_hour_rolled_over
    assert_failure
}

# =============================================================================
# assert_call_count
# =============================================================================

@test "assert_call_count passes when hour unchanged and count matches" {
    e2e_mark_run_start
    echo "3" > .ralph/.call_count

    run assert_call_count 3
    assert_success
}

@test "assert_call_count fails when hour unchanged and count differs" {
    e2e_mark_run_start
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_failure
}

@test "assert_call_count skips the check when the run crossed an hour boundary" {
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_success
    [[ "$output" == *"hour boundary"* ]]
}

@test "assert_call_count stays strict when no run start was recorded" {
    rm -f "$E2E_DIR/.run_start_hour"
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_failure
}

# =============================================================================
# run_ralph integration point
# =============================================================================

@test "run_ralph records the run start hour before invoking ralph" {
    # Stub ralph itself — this test only verifies the marker side effect.
    RALPH_SCRIPT="$E2E_DIR/fake_ralph.sh"
    echo 'exit 0' > "$RALPH_SCRIPT"
    rm -f "$E2E_DIR/.run_start_hour"

    run run_ralph

    assert_success
    assert_equal "$(cat "$E2E_DIR/.run_start_hour")" "$(date +%Y%m%d%H)"
}
