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
# e2e_mark_run_start / e2e_mark_run_end / e2e_hour_rolled_over
# =============================================================================

# Assert a marker file holds the current hour. The hour is sampled before and
# after the marker was written, and either value is accepted, so these tests
# cannot themselves flake at the top of the hour.
assert_marker_is_current_hour() {
    local file=$1 before=$2 after=$3
    local marker
    marker=$(cat "$file")
    [[ "$marker" == "$before" || "$marker" == "$after" ]] \
        || fail "Marker '$marker' is neither '$before' nor '$after'"
}

@test "e2e_mark_run_start records the current hour" {
    local before after
    before=$(date +%Y%m%d%H)
    e2e_mark_run_start
    after=$(date +%Y%m%d%H)

    assert_marker_is_current_hour "$E2E_DIR/.run_start_hour" "$before" "$after"
}

@test "e2e_mark_run_end records the current hour" {
    local before after
    before=$(date +%Y%m%d%H)
    e2e_mark_run_end
    after=$(date +%Y%m%d%H)

    assert_marker_is_current_hour "$E2E_DIR/.run_end_hour" "$before" "$after"
}

@test "e2e_hour_rolled_over is false when the hour has not changed" {
    e2e_mark_run_start
    e2e_mark_run_end

    run e2e_hour_rolled_over
    assert_failure
}

@test "e2e_hour_rolled_over compares start to recorded end, not assertion time" {
    # Run started and ended in the same (old) hour — even though the current
    # wall clock differs, the run itself never crossed a boundary, so the
    # counter cannot have been reset and assertions must stay strict.
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    echo "2020010100" > "$E2E_DIR/.run_end_hour"

    run e2e_hour_rolled_over
    assert_failure
}

@test "e2e_hour_rolled_over is true when the hour changed during the run" {
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    echo "2020010101" > "$E2E_DIR/.run_end_hour"

    run e2e_hour_rolled_over
    assert_success
}

@test "e2e_hour_rolled_over falls back to current time when no end was recorded" {
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    rm -f "$E2E_DIR/.run_end_hour"

    run e2e_hour_rolled_over
    assert_success
}

@test "e2e_hour_rolled_over is false when no run start was recorded" {
    rm -f "$E2E_DIR/.run_start_hour" "$E2E_DIR/.run_end_hour"

    run e2e_hour_rolled_over
    assert_failure
}

# =============================================================================
# assert_call_count
# =============================================================================

@test "assert_call_count passes when hour unchanged and count matches" {
    e2e_mark_run_start
    e2e_mark_run_end
    echo "3" > .ralph/.call_count

    run assert_call_count 3
    assert_success
}

@test "assert_call_count fails when hour unchanged and count differs" {
    e2e_mark_run_start
    e2e_mark_run_end
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_failure
}

@test "assert_call_count stays strict when the hour changed only after the run" {
    # Boundary crossed between run end and assertion — the counter was not
    # reset during the run, so a wrong value must still fail.
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    echo "2020010100" > "$E2E_DIR/.run_end_hour"
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_failure
}

@test "assert_call_count skips the check when the run crossed an hour boundary" {
    echo "2020010100" > "$E2E_DIR/.run_start_hour"
    echo "2020010101" > "$E2E_DIR/.run_end_hour"
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_success
    [[ "$output" == *"hour boundary"* ]]
}

@test "assert_call_count stays strict when no run start was recorded" {
    rm -f "$E2E_DIR/.run_start_hour" "$E2E_DIR/.run_end_hour"
    echo "0" > .ralph/.call_count

    run assert_call_count 3
    assert_failure
}

# =============================================================================
# run_ralph integration point
# =============================================================================

@test "run_ralph records run start and end hours and preserves exit status" {
    [[ -n "$E2E_TIMEOUT_CMD" ]] || skip "GNU timeout unavailable"

    # Stub ralph itself — this test only verifies the marker side effects
    # and that the exit status passes through the marker bookkeeping.
    RALPH_SCRIPT="$E2E_DIR/fake_ralph.sh"
    echo 'exit 7' > "$RALPH_SCRIPT"
    rm -f "$E2E_DIR/.run_start_hour" "$E2E_DIR/.run_end_hour"

    local before after
    before=$(date +%Y%m%d%H)
    run run_ralph
    after=$(date +%Y%m%d%H)

    [ "$status" -eq 7 ]
    assert_marker_is_current_hour "$E2E_DIR/.run_start_hour" "$before" "$after"
    assert_marker_is_current_hour "$E2E_DIR/.run_end_hour" "$before" "$after"
}
