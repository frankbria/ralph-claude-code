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

