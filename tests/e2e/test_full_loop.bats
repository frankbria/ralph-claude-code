#!/usr/bin/env bats
# E2E tests for complete Ralph loop execution (Issue #17)
#
# These tests run ralph_loop.sh as a TRUE SUBPROCESS with a mock `claude`
# executable on disk — exercising the full lifecycle: startup validation,
# loop iterations, response analysis, exit detection, and final status.
# See tests/e2e/helpers/e2e_helper.bash for the harness.
#
# Scenarios already covered at unit/integration level (sourced functions) are
# intentionally NOT duplicated here; each test below verifies behavior that
# only manifests in a real end-to-end subprocess run.

load '../helpers/test_helper'
load 'helpers/e2e_helper'

setup() {
    setup_e2e_project
}

teardown() {
    teardown_e2e_project
}

# =============================================================================
# STARTUP VALIDATION
# =============================================================================

@test "E2E: missing .ralph/PROMPT.md halts startup with guidance" {
    rm .ralph/PROMPT.md

    run run_ralph

    assert_failure
    [[ "$output" == *"PROMPT.md"* ]]
    [[ "$output" == *"ralph-enable"* ]]
    # Claude must never have been invoked
    assert_equal "$(mock_call_count)" "0"
}

@test "E2E: missing .ralphrc fails the integrity check at startup" {
    rm .ralphrc

    run run_ralph

    assert_failure
    [[ "$output" == *".ralphrc"* ]]
    assert_equal "$(mock_call_count)" "0"
}

# =============================================================================
# GRACEFUL EXITS
# =============================================================================

@test "E2E: fully completed fix_plan exits plan_complete with zero API calls" {
    e2e_fix_plan 0 3   # all items checked

    run run_ralph

    assert_success
    assert_equal "$(mock_call_count)" "0"
    assert_equal "$(status_field exit_reason)" "plan_complete"
    assert_equal "$(status_field status)" "completed"
    assert_equal "$(status_field last_action)" "graceful_exit"
}

@test "E2E: repeated EXIT_SIGNAL true responses trigger graceful completion exit" {
    queue_response 1 "COMPLETE" "true" "All planned work has shipped."
    queue_productive_effect 1
    queue_response 2 "COMPLETE" "true" "Confirming: nothing left to build."
    queue_productive_effect 2

    run run_ralph

    assert_success
    # Exit check at the start of loop 3 sees two completion signals
    assert_equal "$(mock_call_count)" "2"
    assert_equal "$(status_field exit_reason)" "completion_signals"
    assert_equal "$(status_field status)" "completed"

    # Side effects of a real loop iteration
    assert_file_exists "src/work_1.txt"
    [[ "$output" == *"Analyzing Claude Code response"* ]]
    # Graceful exit resets the session (which clears .response_analysis)
    assert_equal "$(jq -r '.reset_reason' .ralph/.ralph_session)" "project_complete"
    assert_equal "$(cat .ralph/.call_count)" "2"
    [[ $(ls .ralph/logs/claude_output_*.log 2>/dev/null | wc -l) -ge 2 ]]
}

@test "E2E: multi-loop run progresses through fix_plan to plan_complete" {
    e2e_fix_plan 3 0
    local i
    for i in 1 2 3; do
        queue_response "$i" "IN_PROGRESS" "false" "Implemented open task $i."
        queue_productive_effect "$i"
    done

    run run_ralph

    assert_success
    assert_equal "$(mock_call_count)" "3"
    assert_equal "$(status_field exit_reason)" "plan_complete"
    # Loop counter advanced past the three working iterations
    assert_equal "$(status_field loop_count)" "4"
    assert_equal "$(cat .ralph/.call_count)" "3"
    # Each loop produced its own output log
    [[ $(ls .ralph/logs/claude_output_*.log | wc -l) -eq 3 ]]
    # All work landed
    assert_file_exists "src/work_1.txt"
    assert_file_exists "src/work_2.txt"
    assert_file_exists "src/work_3.txt"
    ! grep -q '^- \[ \]' .ralph/fix_plan.md
}

@test "E2E: three test-only loops exit with test_saturation" {
    # work_type TEST_ONLY at top level marks the loop test-only; productive
    # effects keep the circuit breaker from opening first.
    local i
    for i in 1 2 3; do
        queue_response "$i" "IN_PROGRESS" "false" "Ran the test suite again." \
            "" '+ {work_type: "TEST_ONLY"}'
        queue_effect "$i" << EOF
echo "test run $i" > "src/tests_$i.txt"
git add "src/tests_$i.txt"
EOF
    done

    run run_ralph

    assert_success
    assert_equal "$(mock_call_count)" "3"
    assert_equal "$(status_field exit_reason)" "test_saturation"
    assert_equal "$(status_field status)" "completed"
}

# =============================================================================
# CIRCUIT BREAKER (full-loop halt path)
# =============================================================================

@test "E2E: three no-progress loops open the circuit breaker and halt" {
    # Default mock response is a no-progress analysis loop; queue nothing.

    run run_ralph

    # The loop halts via `break`; the script itself exits 0 (current behavior)
    assert_success
    assert_equal "$(mock_call_count)" "3"
    assert_equal "$(status_field status)" "halted"
    assert_equal "$(status_field last_action)" "circuit_breaker_open"
    assert_equal "$(jq -r '.state' .ralph/.circuit_breaker_state)" "OPEN"
}

# =============================================================================
# STALE STATE PROTECTION (Issue #194)
# =============================================================================

@test "E2E: stale exit signals from a prior run do not cause premature exit" {
    # Simulate a crashed prior run that left completion signals behind
    cat > .ralph/.exit_signals << 'EOF'
{"test_only_loops": [], "done_signals": [1, 2], "completion_indicators": [1, 2]}
EOF
    queue_response 1 "COMPLETE" "true" "Wrapping up the remaining work."
    queue_productive_effect 1
    queue_response 2 "COMPLETE" "true" "Everything is finished now."
    queue_productive_effect 2

    run run_ralph

    assert_success
    # The stale signals were reset: Claude WAS invoked (twice) rather than
    # the loop exiting at the first check with zero calls.
    assert_equal "$(mock_call_count)" "2"
    assert_equal "$(status_field exit_reason)" "completion_signals"
}

# =============================================================================
# SESSION CONTINUITY
# =============================================================================

@test "E2E: session ID from loop 1 is persisted and resumed in loop 2" {
    export CLAUDE_USE_CONTINUE=true
    e2e_fix_plan 2 0

    queue_response 1 "IN_PROGRESS" "false" "Started task one." "e2e-sess-abc123"
    queue_productive_effect 1
    queue_response 2 "IN_PROGRESS" "false" "Finished task two." "e2e-sess-abc123"
    queue_productive_effect 2

    run run_ralph

    assert_success
    assert_equal "$(mock_call_count)" "2"

    # Session was persisted after loop 1 (the graceful exit later clears the
    # session file, so the argv of loop 2 is the durable evidence)
    [[ "$output" == *"Saved Claude session"* ]]

    # Loop 1 started fresh (no --resume); loop 2 resumed the stored session
    ! grep -qx -- "--resume" "$MOCK_DIR/calls/argv_1.log"
    grep -qx -- "--resume" "$MOCK_DIR/calls/argv_2.log"
    grep -qx "e2e-sess-abc123" "$MOCK_DIR/calls/argv_2.log"
}

# =============================================================================
# RATE LIMIT TRACKING
# =============================================================================

@test "E2E: stale hourly counter is reset before the loop proceeds" {
    # Simulate a counter exhausted in a previous hour
    echo "99" > .ralph/.call_count
    echo "2020010100" > .ralph/.last_reset

    e2e_fix_plan 1 0
    queue_response 1 "IN_PROGRESS" "false" "Knocked out the last open task."
    queue_productive_effect 1

    run run_ralph

    assert_success
    # Counter was reset for the new hour, then incremented once — not 100
    assert_equal "$(cat .ralph/.call_count)" "1"
    assert_equal "$(cat .ralph/.last_reset)" "$(date +%Y%m%d%H)"
    assert_equal "$(status_field exit_reason)" "plan_complete"
}

# =============================================================================
# CLI FLAGS IN A REAL RUN
# =============================================================================

@test "E2E: --calls and --no-continue take effect in a full run" {
    # Pre-seed a stored session that --no-continue must ignore
    echo "e2e-stale-session" > .ralph/.claude_session_id

    e2e_fix_plan 1 0
    queue_response 1 "IN_PROGRESS" "false" "Completed the only open task."
    queue_productive_effect 1

    run run_ralph --calls 7 --no-continue

    assert_success
    assert_equal "$(status_field max_calls_per_hour)" "7"
    # --no-continue: the stored session must NOT be resumed
    ! grep -qx -- "--resume" "$MOCK_DIR/calls/argv_1.log"
}

# =============================================================================
# API LIMIT HANDLING
# =============================================================================

@test "E2E: API 5-hour limit response with user exit choice stops the loop" {
    queue_raw_response 1 1 << 'EOF'
You've reached your 5-hour usage limit for Claude.
Please try again later when your limit resets.
EOF

    # Feed "2" (exit) to the interactive limit prompt
    run bash -c "printf '2' | timeout --foreground -k 5 120 bash '$RALPH_SCRIPT'"

    assert_success
    assert_equal "$(mock_call_count)" "1"
    assert_equal "$(status_field last_action)" "api_limit_exit"
    assert_equal "$(status_field status)" "stopped"
    assert_equal "$(status_field exit_reason)" "api_5hour_limit"
}

# =============================================================================
# INTERRUPTION (signal → cleanup trap)
# =============================================================================

# Note: SIGTERM is used because background jobs started by a non-interactive
# shell (bats) have SIGINT set to SIG_IGN, which bash cannot trap. A terminal
# Ctrl-C (SIGINT) runs the exact same cleanup() handler.
@test "E2E: termination signal during execution records interrupted status and preserves call count" {
    # Mock sleeps long enough for us to interrupt mid-execution
    echo "60" > "$MOCK_DIR/responses/1.sleep"

    bash "$RALPH_SCRIPT" > "$E2E_DIR/ralph_run.log" 2>&1 < /dev/null &
    local ralph_pid=$!

    # Wait until loop 1 is executing (call counter incremented)
    local waited=0
    while [[ "$(mock_call_count)" == "0" && $waited -lt 200 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    assert_equal "$(mock_call_count)" "1"

    # Signal ralph. Bash defers the trap until its current foreground command
    # (the progress-monitor `sleep`) completes, so also signal ralph's sleep
    # children — exactly what a terminal Ctrl-C does to the foreground process
    # group. The mock claude keeps sleeping, which holds the loop in its
    # monitor phase and keeps the interrupted status stable for assertion.
    kill -TERM "$ralph_pid"
    local i
    for i in $(seq 1 100); do
        pkill -TERM -P "$ralph_pid" -x sleep 2>/dev/null || true
        if jq -e '.last_action == "interrupted"' .ralph/status.json >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done

    # cleanup() writes last_action="interrupted", status="stopped"
    assert_equal "$(status_field last_action)" "interrupted"
    assert_equal "$(status_field status)" "stopped"
    # Call counter preserved across interruption
    assert_equal "$(cat .ralph/.call_count)" "1"

    kill -KILL "$ralph_pid" 2>/dev/null || true
    wait "$ralph_pid" 2>/dev/null || true
}
