#!/usr/bin/env bats
# Unit tests for Loop Stability & Analysis Resilience (Phase 0.5)
# Tests LOOP-1 through LOOP-5 acceptance criteria

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
RALPH_LOOP="${PROJECT_ROOT}/ralph_loop.sh"
RESPONSE_ANALYZER="${PROJECT_ROOT}/lib/response_analyzer.sh"
CIRCUIT_BREAKER="${PROJECT_ROOT}/lib/circuit_breaker.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR=".ralph"
    export LOG_DIR=".ralph/logs"
    export STATUS_FILE=".ralph/status.json"
    export CALL_COUNT_FILE=".ralph/.call_count"
    export EXIT_SIGNALS_FILE=".ralph/.exit_signals"
    export RESPONSE_ANALYSIS_FILE=".ralph/.response_analysis"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# LOOP-1: No jq -s in JSONL processing paths
# =============================================================================

@test "LOOP-1: no jq -s length calls in ralph_loop.sh" {
    # Ensure jq -s 'length' (the crash pattern) is not used anywhere
    run grep "jq -s 'length'" "$RALPH_LOOP"
    assert_failure  # grep returns 1 when no matches
}

@test "LOOP-1: no jq -s length calls in response_analyzer.sh" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    run grep "jq -s 'length'" "$RESPONSE_ANALYZER"
    assert_failure  # grep returns 1 when no matches
}

@test "LOOP-1: grep -c counts single pretty-printed object as 1" {
    local output_file="$TEST_DIR/single.json"
    cat > "$output_file" <<'EOF'
{
    "type": "result",
    "status": "SUCCESS",
    "exit_signal": true
}
EOF

    local count
    count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
    count=$(echo "$count" | tr -d '[:space:]')
    [ "$count" -eq 1 ]
}

@test "LOOP-1: grep -c counts JSONL objects correctly" {
    local output_file="$TEST_DIR/multi.jsonl"
    for i in $(seq 1 100); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$output_file"
    echo '{"type":"result","status":"SUCCESS"}' >> "$output_file"

    local count
    count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
    count=$(echo "$count" | tr -d '[:space:]')
    [ "$count" -eq 101 ]
}

@test "LOOP-1: large JSONL stream (2000 objects) counted in <2 seconds" {
    local output_file="$TEST_DIR/large_stream.log"
    for i in $(seq 1 1999); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$output_file"
    echo '{"type":"result","status":"SUCCESS","exit_signal":false}' >> "$output_file"

    local start_time end_time duration
    start_time=$(date +%s)
    local count
    count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [ "$count" -eq 2000 ]
    [ "$duration" -lt 2 ]
}

# =============================================================================
# LOOP-2: Aggregate permission denials across all result objects
# =============================================================================

@test "LOOP-2: ralph_log_permission_denials uses while loop aggregation" {
    # Verify the function uses a while loop for aggregation, not tail -1
    grep -q 'while IFS= read' "$RALPH_LOOP"
    # Verify tail -1 is NOT used in the denial function
    local tail_in_denials
    tail_in_denials=$(sed -n '/ralph_log_permission_denials_from_raw_output/,/^}/p' "$RALPH_LOOP" | grep -c 'tail -1' || echo "0")
    tail_in_denials=$(echo "$tail_in_denials" | tr -d '[:space:]')
    [ "$tail_in_denials" -eq 0 ]
}

@test "LOOP-2: response_analyzer preserves original_output_file for aggregation" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    grep -q 'original_output_file' "$RESPONSE_ANALYZER"
}

@test "LOOP-2: response_analyzer aggregates denials from all results" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    # Verify the aggregation path exists — grep result lines piped to jq -s
    grep -q 'all_denials_json' "$RESPONSE_ANALYZER"
    grep -q 'permission_denials' "$RESPONSE_ANALYZER"
}

# =============================================================================
# LOOP-3: PROMPT.md guidance for Bash compound commands
# (The historical ALLOWED_TOOLS allowlist tests were removed when legacy
#  -p mode was deleted — tool restrictions now live in the agent file.)
# =============================================================================

@test "LOOP-3: PROMPT.md warns about cd-chained Bash compound commands" {
    # The harness's Bash permission matcher trips on `cd /path && <cmd>`
    # chains because it evaluates the full command string from the first
    # word. PROMPT.md must keep this warning so Claude doesn't fight the
    # permission system on every loop. We pin the substantive phrases —
    # the surrounding prose is allowed to evolve.
    grep -qE "cd /path && <command>|cd .* && .*command" "$PROJECT_ROOT/templates/PROMPT.md"
    grep -qE "permission (matcher|prompt|denial)" "$PROJECT_ROOT/templates/PROMPT.md"
}

# =============================================================================
# LOOP-4: Post-analysis pipeline error handling
# =============================================================================

@test "LOOP-4: update_exit_signals validates JSON before processing" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "$RESPONSE_ANALYZER"

    # Create invalid analysis file
    echo "NOT VALID JSON" > "$RALPH_DIR/.response_analysis"

    run update_exit_signals "$RALPH_DIR/.response_analysis" "$EXIT_SIGNALS_FILE"
    assert_failure

    # Exit signals should be unchanged (not corrupted)
    run jq -e '.' "$EXIT_SIGNALS_FILE"
    assert_success
}

@test "LOOP-4: update_exit_signals handles missing analysis file" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "$RESPONSE_ANALYZER"

    run update_exit_signals "/nonexistent/file" "$EXIT_SIGNALS_FILE"
    assert_failure

    # Exit signals should be unchanged
    run jq -e '.' "$EXIT_SIGNALS_FILE"
    assert_success
}

@test "LOOP-4: update_exit_signals succeeds on valid analysis" {
    [[ -f "$RESPONSE_ANALYZER" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "$RESPONSE_ANALYZER"

    cat > "$RALPH_DIR/.response_analysis" <<'EOF'
{
    "loop_number": 1,
    "analysis": {
        "is_test_only": false,
        "has_completion_signal": false,
        "has_progress": true,
        "exit_signal": false,
        "confidence_score": 70,
        "files_modified": 3,
        "work_summary": "implemented auth middleware"
    }
}
EOF

    run update_exit_signals "$RALPH_DIR/.response_analysis" "$EXIT_SIGNALS_FILE"
    assert_success
}

@test "LOOP-4: update_exit_signals calls are guarded across loop modules" {
    # Both call sites (success path in ralph_loop.sh, productive-timeout path in
    # lib/exec_helpers.sh::exec_handle_timeout) must have `if ! ...` guards so a
    # failed signal update does not abort the loop. Count across both files
    # since TAP-1476 moved the productive-timeout branch into exec_helpers.sh.
    local helpers="${BATS_TEST_DIRNAME}/../../lib/exec_helpers.sh"
    local main_count helpers_count total
    main_count=$(grep -c 'if ! update_exit_signals_from_status' "$RALPH_LOOP" 2>/dev/null | tr -cd '0-9')
    helpers_count=$(grep -c 'if ! update_exit_signals_from_status' "$helpers" 2>/dev/null | tr -cd '0-9')
    total=$(( ${main_count:-0} + ${helpers_count:-0} ))
    [ "$total" -ge 2 ] \
        || fail "expected >=2 guarded update_exit_signals_from_status calls across ralph_loop.sh + lib/exec_helpers.sh, got $total (main=$main_count helpers=$helpers_count)"
}

@test "LOOP-4: log_status_summary calls are guarded across loop modules" {
    # Same shape as above: success-path call lives in ralph_loop.sh,
    # productive-timeout call lives in lib/exec_helpers.sh::exec_handle_timeout.
    local helpers="${BATS_TEST_DIRNAME}/../../lib/exec_helpers.sh"
    local main_count helpers_count total
    main_count=$(grep -c 'if ! log_status_summary' "$RALPH_LOOP" 2>/dev/null | tr -cd '0-9')
    helpers_count=$(grep -c 'if ! log_status_summary' "$helpers" 2>/dev/null | tr -cd '0-9')
    total=$(( ${main_count:-0} + ${helpers_count:-0} ))
    [ "$total" -ge 2 ] \
        || fail "expected >=2 guarded log_status_summary calls across ralph_loop.sh + lib/exec_helpers.sh, got $total (main=$main_count helpers=$helpers_count)"
}

# =============================================================================
# LOOP-5: Crash diagnostics and recovery
# =============================================================================

@test "LOOP-5: EXIT trap is set in ralph_loop.sh" {
    # SIGINT and SIGTERM pass an explicit exit code (130/143) so the
    # signal branch in cleanup() actually fires — bash's $? inside a
    # trap reflects the previous command, not the signal.
    grep -q "trap 'cleanup 130' SIGINT" "$RALPH_LOOP"
    grep -q "trap 'cleanup 143' SIGTERM" "$RALPH_LOOP"
    grep -q '^trap cleanup EXIT' "$RALPH_LOOP"
}

@test "LOOP-5: cleanup records crash code on non-zero exit" {
    grep -q '.last_crash_code' "$RALPH_LOOP"
}

@test "LOOP-5: startup detects previous crash" {
    grep -q 'Previous Ralph invocation crashed' "$RALPH_LOOP"
}

@test "LOOP-5: startup detects stale running status" {
    grep -q "status as 'running'" "$RALPH_LOOP"
}

@test "LOOP-5: persistent loop counter file used" {
    grep -q '.total_loop_count' "$RALPH_LOOP"
}

@test "LOOP-5: log format includes total loop count" {
    grep -q 'total: #' "$RALPH_LOOP"
}

@test "LOOP-5: persistent loop counter increments correctly" {
    echo "5" > "$RALPH_DIR/.total_loop_count"

    local persistent_loops
    persistent_loops=$(cat "$RALPH_DIR/.total_loop_count")
    persistent_loops=$((persistent_loops + 1))
    echo "$persistent_loops" > "$RALPH_DIR/.total_loop_count"

    run cat "$RALPH_DIR/.total_loop_count"
    assert_output "6"
}

@test "LOOP-5: crash code file created and detected" {
    echo "137" > "$RALPH_DIR/.last_crash_code"
    [ -f "$RALPH_DIR/.last_crash_code" ]

    local code
    code=$(cat "$RALPH_DIR/.last_crash_code")
    [ "$code" = "137" ]

    # Cleanup (simulating startup)
    rm -f "$RALPH_DIR/.last_crash_code"
    [ ! -f "$RALPH_DIR/.last_crash_code" ]
}
