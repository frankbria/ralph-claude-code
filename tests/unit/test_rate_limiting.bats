#!/usr/bin/env bats
# Unit Tests for Rate Limiting Logic

load '../helpers/test_helper'

# Source ralph functions (we need to extract these first)
setup() {
    # Source helper functions
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export MAX_CALLS_PER_HOUR=100
    export MAX_TOKENS_PER_HOUR=0
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"

    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    mkdir -p "$RALPH_DIR"

    # Initialize files
    echo "0" > "$CALL_COUNT_FILE"
    echo "0" > "$TOKEN_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
}

teardown() {
    # Clean up
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper function: extract_token_usage (extracted from ralph_loop.sh)
extract_token_usage() {
    local output_file=$1
    if [[ ! -f "$output_file" ]]; then
        echo "0"
        return
    fi
    local tokens
    tokens=$(jq -r '
        ((.usage.input_tokens // .metadata.usage.input_tokens // 0) |
         if type == "number" then . else 0 end) +
        ((.usage.output_tokens // .metadata.usage.output_tokens // 0) |
         if type == "number" then . else 0 end)
    ' "$output_file" 2>/dev/null)
    echo "${tokens:-0}"
}

# Helper function: update_token_count (extracted from ralph_loop.sh)
update_token_count() {
    local output_file=$1
    local new_tokens
    new_tokens=$(extract_token_usage "$output_file")
    if [[ "$new_tokens" -gt 0 ]] 2>/dev/null; then
        local current
        current=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
        echo $(( current + new_tokens )) > "$TOKEN_COUNT_FILE"
    fi
}

# Helper function: can_make_call (extracted from ralph_loop.sh)
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call — invocation limit reached
    fi

    if [[ "${MAX_TOKENS_PER_HOUR:-0}" -gt 0 ]] 2>/dev/null; then
        local tokens_used=0
        tokens_used=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
        if [[ $tokens_used -ge $MAX_TOKENS_PER_HOUR ]]; then
            return 1  # Cannot make call — token limit reached
        fi
    fi

    return 0  # Can make call
}

# Helper function: increment_call_counter (extracted from ralph_loop.sh)
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Test 1: can_make_call returns success when under limit
@test "can_make_call returns success when under limit" {
    echo "50" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 2: can_make_call returns success when exactly at limit minus 1
@test "can_make_call returns success when at limit minus 1" {
    echo "99" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 3: can_make_call returns failure when at limit
@test "can_make_call returns failure when at limit" {
    echo "100" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 4: can_make_call returns failure when over limit
@test "can_make_call returns failure when over limit" {
    echo "150" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 5: can_make_call returns success when file doesn't exist (0 calls)
@test "can_make_call returns success when call count file missing" {
    rm -f "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 6: increment_call_counter increases from 0
@test "increment_call_counter increases from 0 to 1" {
    echo "0" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 7: increment_call_counter increases from middle value
@test "increment_call_counter increases from 42 to 43" {
    echo "42" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "43"
    assert_equal "$(cat $CALL_COUNT_FILE)" "43"
}

# Test 8: increment_call_counter works near limit
@test "increment_call_counter increases from 99 to 100" {
    echo "99" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "100"
    assert_equal "$(cat $CALL_COUNT_FILE)" "100"
}

# Test 9: increment_call_counter works when file missing
@test "increment_call_counter creates file and sets to 1 when missing" {
    rm -f "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 12: Counter persistence across multiple increments
@test "counter persists correctly across multiple increments" {
    echo "0" > "$CALL_COUNT_FILE"

    result1=$(increment_call_counter)  # 1
    result2=$(increment_call_counter)  # 2
    result3=$(increment_call_counter)  # 3
    result4=$(increment_call_counter)  # 4

    assert_equal "$result4" "4"
    assert_equal "$(cat $CALL_COUNT_FILE)" "4"
}

# Test 13: Call count file contains only a number
@test "call count file contains valid integer" {
    run increment_call_counter

    # Check the call count file contains a valid integer
    value=$(cat "$CALL_COUNT_FILE")
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "Call count file does not contain valid integer: $value"
        return 1
    }
}

# =============================================================================
# Issue #223: Token-based rate limiting
# =============================================================================

@test "can_make_call ignores token limit when MAX_TOKENS_PER_HOUR is 0" {
    echo "0" > "$CALL_COUNT_FILE"
    echo "9999999" > "$TOKEN_COUNT_FILE"
    export MAX_TOKENS_PER_HOUR=0

    run can_make_call
    assert_success
}

@test "can_make_call blocks when token limit exceeded" {
    echo "0" > "$CALL_COUNT_FILE"
    echo "600000" > "$TOKEN_COUNT_FILE"
    export MAX_TOKENS_PER_HOUR=500000

    run can_make_call
    assert_failure
}

@test "can_make_call blocks when token limit exactly reached" {
    echo "0" > "$CALL_COUNT_FILE"
    echo "500000" > "$TOKEN_COUNT_FILE"
    export MAX_TOKENS_PER_HOUR=500000

    run can_make_call
    assert_failure
}

@test "can_make_call allows call when under token limit" {
    echo "0" > "$CALL_COUNT_FILE"
    echo "499999" > "$TOKEN_COUNT_FILE"
    export MAX_TOKENS_PER_HOUR=500000

    run can_make_call
    assert_success
}

@test "can_make_call blocks on invocation limit even when tokens are fine" {
    echo "100" > "$CALL_COUNT_FILE"
    echo "0" > "$TOKEN_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100
    export MAX_TOKENS_PER_HOUR=500000

    run can_make_call
    assert_failure
}

@test "extract_token_usage returns 0 for missing file" {
    run extract_token_usage "/nonexistent/file.log"
    assert_output "0"
}

@test "extract_token_usage reads flat usage format (stream-json)" {
    local output_file="$RALPH_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{"type":"result","result":"done","usage":{"input_tokens":1200,"output_tokens":300}}
EOF
    run extract_token_usage "$output_file"
    assert_output "1500"
}

@test "extract_token_usage reads nested metadata.usage format (CLI)" {
    local output_file="$RALPH_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{"result":"done","sessionId":"s1","metadata":{"usage":{"input_tokens":2000,"output_tokens":500}}}
EOF
    run extract_token_usage "$output_file"
    assert_output "2500"
}

@test "extract_token_usage returns 0 when usage fields absent" {
    local output_file="$RALPH_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{"result":"done","sessionId":"s1"}
EOF
    run extract_token_usage "$output_file"
    assert_output "0"
}

@test "update_token_count accumulates across invocations" {
    local output_file="$RALPH_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{"type":"result","result":"done","usage":{"input_tokens":1000,"output_tokens":200}}
EOF
    echo "500" > "$TOKEN_COUNT_FILE"

    update_token_count "$output_file"

    assert_equal "$(cat "$TOKEN_COUNT_FILE")" "1700"
}

@test "update_token_count is a no-op when file has no token data" {
    local output_file="$RALPH_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{"result":"done"}
EOF
    echo "300" > "$TOKEN_COUNT_FILE"

    update_token_count "$output_file"

    assert_equal "$(cat "$TOKEN_COUNT_FILE")" "300"
}

@test "ralph_loop.sh defines TOKEN_COUNT_FILE" {
    run grep 'TOKEN_COUNT_FILE=' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    assert_success
}

@test "ralph_loop.sh calls update_token_count after execution" {
    run grep 'update_token_count' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    assert_success
}

@test "ralph_loop.sh resets TOKEN_COUNT_FILE in wait_for_reset" {
    run grep -A5 'Reset counters' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    assert_success
    [[ "$output" == *"TOKEN_COUNT_FILE"* ]]
}

# =============================================================================
# Configurable RESET_WAIT_MINUTES
#
# The original reset window is hardcoded to wall-clock hour boundaries: reset
# on `date +%Y%m%d%H` change, wait "until the top of the next hour" on rate
# limit. That means a rate limit hit at :01 past the hour waits ~59 minutes
# even though the provider's actual limit window may be much shorter (or
# configurable per plan). RESET_WAIT_MINUTES makes that wait — and the reset
# cadence — explicit. It defaults to 0, which keeps the original hour-boundary
# behavior, so existing installs only change once they opt in.
# =============================================================================

# _use_rolling_window (extracted from ralph_loop.sh)
_use_rolling_window() {
    [[ "${RESET_WAIT_MINUTES:-0}" -gt 0 ]] 2>/dev/null
}

# _last_reset_epoch (extracted from ralph_loop.sh)
#
# TIMESTAMP_FILE holds an epoch in rolling-window mode but a YYYYMMDDHH stamp in
# legacy mode, and that stamp is also ten digits, so a digit count alone would
# read it as an epoch years in the future. Values ahead of now report as unknown.
_last_reset_epoch() {
    local now_epoch=$1
    local raw_ts=""
    [[ -f "$TIMESTAMP_FILE" ]] && raw_ts=$(cat "$TIMESTAMP_FILE" 2>/dev/null)
    if [[ ! "$raw_ts" =~ ^[0-9]{10}$ ]]; then
        echo "0"
        return
    fi
    # Force base 10: a leading zero would otherwise be read as octal.
    local ts=$((10#$raw_ts))
    if (( ts > now_epoch )); then
        echo "0"
        return
    fi
    echo "$ts"
}

# should_reset_counters (extracted from ralph_loop.sh's init_call_tracking)
should_reset_counters() {
    local now_epoch=$1

    if _use_rolling_window; then
        local reset_window_secs=$((RESET_WAIT_MINUTES * 60))
        local last_reset_epoch
        last_reset_epoch=$(_last_reset_epoch "$now_epoch")
        [[ $last_reset_epoch -eq 0 ]] && return 0
        (( now_epoch - last_reset_epoch >= reset_window_secs ))
        return
    fi

    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""
    [[ -f "$TIMESTAMP_FILE" ]] && last_reset_hour=$(cat "$TIMESTAMP_FILE")
    [[ "$current_hour" != "$last_reset_hour" ]]
}

# remaining_wait_secs (extracted from ralph_loop.sh's wait_for_reset)
remaining_wait_secs() {
    local now_epoch=$1
    local reset_window_secs=$((RESET_WAIT_MINUTES * 60))
    local last_reset_epoch
    last_reset_epoch=$(_last_reset_epoch "$now_epoch")
    local wait_time
    if [[ $last_reset_epoch -eq 0 ]]; then
        wait_time=$reset_window_secs
    else
        wait_time=$((reset_window_secs - (now_epoch - last_reset_epoch)))
    fi
    (( wait_time < 0 )) && wait_time=0
    echo "$wait_time"
}

@test "RESET_WAIT_MINUTES defaults to 0 so existing installs keep hour-boundary resets" {
    run env -u RESET_WAIT_MINUTES bash -c \
        "source '${BATS_TEST_DIRNAME}/../../ralph_loop.sh' >/dev/null 2>&1; echo \"\$RESET_WAIT_MINUTES\""
    assert_success
    assert_output "0"
}

@test "RESET_WAIT_MINUTES in .ralphrc is applied by load_ralphrc" {
    printf 'RESET_WAIT_MINUTES=3\n' > .ralphrc

    run env -u RESET_WAIT_MINUTES bash -c \
        "source '${BATS_TEST_DIRNAME}/../../ralph_loop.sh' >/dev/null 2>&1; load_ralphrc >/dev/null 2>&1; echo \"\$RESET_WAIT_MINUTES\""
    assert_success
    assert_output "3"
}

@test "RESET_WAIT_MINUTES from the environment overrides .ralphrc" {
    printf 'RESET_WAIT_MINUTES=3\n' > .ralphrc

    run env RESET_WAIT_MINUTES=9 bash -c \
        "source '${BATS_TEST_DIRNAME}/../../ralph_loop.sh' >/dev/null 2>&1; load_ralphrc >/dev/null 2>&1; echo \"\$RESET_WAIT_MINUTES\""
    assert_success
    assert_output "9"
}

@test "should_reset_counters: RESET_WAIT_MINUTES=0 falls back to legacy hour-boundary reset" {
    export RESET_WAIT_MINUTES=0
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"

    run should_reset_counters "$(date +%s)"
    assert_failure  # same hour as last reset -> no reset yet
}

@test "should_reset_counters: window elapsed with RESET_WAIT_MINUTES>0 triggers reset" {
    export RESET_WAIT_MINUTES=5
    local now=$(date +%s)
    echo "$((now - 301))" > "$TIMESTAMP_FILE"  # 5m1s ago, window = 300s

    run should_reset_counters "$now"
    assert_success
}

@test "should_reset_counters: window not yet elapsed with RESET_WAIT_MINUTES>0 does not reset" {
    export RESET_WAIT_MINUTES=5
    local now=$(date +%s)
    echo "$((now - 100))" > "$TIMESTAMP_FILE"  # 100s ago, window = 300s

    run should_reset_counters "$now"
    assert_failure
}

@test "should_reset_counters: missing timestamp file always resets" {
    export RESET_WAIT_MINUTES=5
    rm -f "$TIMESTAMP_FILE"

    run should_reset_counters "$(date +%s)"
    assert_success
}

@test "should_reset_counters: a legacy YYYYMMDDHH stamp does not stall the rolling window" {
    export RESET_WAIT_MINUTES=5
    # Ten digits like an epoch, but as an epoch it lands years in the future —
    # which is exactly the state of anyone switching from the default 0 to >0.
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"

    run should_reset_counters "$(date +%s)"
    assert_success
}

@test "remaining_wait_secs: sleeps only what is left of the window" {
    export RESET_WAIT_MINUTES=5
    local now=$(date +%s)
    echo "$((now - 270))" > "$TIMESTAMP_FILE"  # 4m30s into a 5m window

    run remaining_wait_secs "$now"
    assert_output "30"
}

@test "remaining_wait_secs: never returns a negative sleep" {
    export RESET_WAIT_MINUTES=5
    local now=$(date +%s)
    echo "$((now - 600))" > "$TIMESTAMP_FILE"  # window already elapsed twice over

    run remaining_wait_secs "$now"
    assert_output "0"
}

@test "remaining_wait_secs: an untrustworthy timestamp falls back to the full window" {
    export RESET_WAIT_MINUTES=5
    rm -f "$TIMESTAMP_FILE"

    run remaining_wait_secs "$(date +%s)"
    assert_output "300"
}
