#!/usr/bin/env bats
# Unit Tests for Metrics Tracking (Issue #21)
# TDD: Tests written before implementation

load '../helpers/test_helper'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
STATS_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph-stats.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR="$TEST_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_TIMEOUT_MINUTES="15"
    export MAX_CALLS_PER_HOUR="100"

    mkdir -p "$LOG_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# METRICS TRACKING TESTS (4 tests)
# =============================================================================

@test "track_metrics: writes valid JSON Lines to metrics.jsonl" {
    source "$RALPH_SCRIPT"

    track_metrics 1 45 true 3

    [ -f "$LOG_DIR/metrics.jsonl" ]
    local line
    line=$(cat "$LOG_DIR/metrics.jsonl")
    # Validate it is parseable JSON
    echo "$line" | jq . > /dev/null
    # Check all required fields are present and correct
    [[ "$(echo "$line" | jq -r '.loop')" == "1" ]]
    [[ "$(echo "$line" | jq -r '.duration')" == "45" ]]
    [[ "$(echo "$line" | jq -r '.success')" == "true" ]]
    [[ "$(echo "$line" | jq -r '.calls')" == "3" ]]
    [[ "$(echo "$line" | jq -r '.timestamp')" != "null" ]]
}

@test "track_metrics: appends one entry per loop iteration" {
    source "$RALPH_SCRIPT"

    track_metrics 1 30 true 2
    track_metrics 2 60 false 5
    track_metrics 3 45 true 7

    local line_count
    line_count=$(wc -l < "$LOG_DIR/metrics.jsonl")
    [ "$line_count" -eq 3 ]
    # Each line must be valid JSON
    while IFS= read -r line; do
        echo "$line" | jq . > /dev/null || fail "Invalid JSON: $line"
    done < "$LOG_DIR/metrics.jsonl"
}

@test "ralph-stats: outputs correct JSON summary from metrics.jsonl" {
    mkdir -p "$RALPH_DIR/logs"
    cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2025-01-01T00:00:00+00:00","loop":1,"duration":30,"success":true,"calls":2}
{"timestamp":"2025-01-01T00:01:00+00:00","loop":2,"duration":60,"success":true,"calls":5}
{"timestamp":"2025-01-01T00:02:00+00:00","loop":3,"duration":45,"success":false,"calls":7}
EOF

    run env RALPH_DIR="$RALPH_DIR" bash "$STATS_SCRIPT"

    assert_success
    [[ "$(echo "$output" | jq -r '.total_loops')" == "3" ]]
    [[ "$(echo "$output" | jq -r '.successful')" == "2" ]]
    # total_calls = sum of per-loop calls: 2+5+7 = 14
    [[ "$(echo "$output" | jq -r '.total_calls')" == "14" ]]
    # avg_duration: (30+60+45)/3 = 45
    [[ "$(echo "$output" | jq -r '.avg_duration')" == "45" ]]
}

@test "print_metrics_summary: outputs summary when metrics file exists" {
    source "$RALPH_SCRIPT"

    cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2025-01-01T00:00:00+00:00","loop":1,"duration":30,"success":true,"calls":2}
{"timestamp":"2025-01-01T00:01:00+00:00","loop":2,"duration":50,"success":true,"calls":4}
EOF

    run print_metrics_summary

    assert_success
    [[ "$output" == *"total_loops"* ]]
    [[ "$output" == *"2"* ]]
}
