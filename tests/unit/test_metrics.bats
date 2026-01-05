#!/usr/bin/env bats
# Unit Tests for Metrics & Analytics

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export LOG_DIR="logs"
    mkdir -p "$LOG_DIR"
    export RALPH_STATS="${BATS_TEST_DIRNAME}/../../ralph-stats"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

track_metrics() {
    local loop_num=$1
    local duration=$2
    local success=$3
    local calls=$4
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    echo "{\"timestamp\":\"$timestamp\",\"loop\":$loop_num,\"duration\":$duration,\"success\":$success,\"calls\":$calls}" >> "$LOG_DIR/metrics.jsonl"
}

@test "track_metrics appends entries to metrics.jsonl" {
    track_metrics 1 45 "true" 1
    track_metrics 2 52 "true" 2
    run wc -l < "$LOG_DIR/metrics.jsonl"
    assert_equal "$(echo $output | tr -d ' ')" "2"
}

@test "track_metrics produces valid JSONL with correct fields" {
    track_metrics 1 45 "true" 5
    local line=$(cat "$LOG_DIR/metrics.jsonl")
    run jq -r '.loop' <<< "$line"
    assert_equal "$output" "1"
}

@test "track_metrics records correct loop number and duration" {
    track_metrics 5 120 "false" 10
    local line=$(cat "$LOG_DIR/metrics.jsonl")
    run jq -r '.loop' <<< "$line"
    assert_equal "$output" "5"
}

@test "ralph-stats produces expected JSON summary" {
    cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2025-09-30T12:00:00+0000","loop":1,"duration":45,"success":true,"calls":1}
{"timestamp":"2025-09-30T12:01:30+0000","loop":2,"duration":52,"success":true,"calls":2}
EOF
    run "$RALPH_STATS" "$LOG_DIR/metrics.jsonl"
    assert_success
    run jq -r '.total_loops' <<< "$output"
    assert_equal "$output" "2"
}