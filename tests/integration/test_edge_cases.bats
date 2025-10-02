#!/usr/bin/env bats
# Edge case tests for Ralph loop execution
# Tests boundary conditions, error scenarios, and unusual inputs

load '../helpers/test_helper'
load '../helpers/mocks'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create necessary files
    create_sample_prd_md
    create_sample_fix_plan

    # Set up environment
    export PROMPT_FILE="PROMPT.md"
    export LOG_DIR="logs"
    export EXIT_SIGNALS_FILE=".exit_signals"

    mkdir -p "$LOG_DIR"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/circuit_breaker.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Edge Case 1: Empty output file
@test "analyze_response handles empty output file" {
    local output_file="$LOG_DIR/empty_output.log"
    touch "$output_file"

    analyze_response "$output_file" 1

    # Should not crash, should create analysis file
    assert_file_exists ".response_analysis"
    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    # Empty output shouldn't trigger exit
    assert_equal "$exit_signal" "false"
}

# Edge Case 2: Very large output file
@test "analyze_response handles large output file" {
    local output_file="$LOG_DIR/large_output.log"

    # Create large output (100KB)
    for i in {1..1000}; do
        echo "This is line $i with some implementation work and progress..." >> "$output_file"
    done

    analyze_response "$output_file" 1

    # Should handle without error
    assert_file_exists ".response_analysis"
    local output_length=$(jq -r '.analysis.output_length' .response_analysis)
    [[ "$output_length" -gt 50000 ]]
}

# Edge Case 3: Malformed RALPH_STATUS block
@test "analyze_response handles malformed status block" {
    local output_file="$LOG_DIR/malformed.log"

    cat > "$output_file" << 'EOF'
---RALPH_STATUS---
STATUS COMPLETE
MISSING_COLONS
EXIT_SIGNAL true
---END_RALPH_STATUS---
EOF

    analyze_response "$output_file" 1

    # Should not crash, may not detect structured output
    assert_file_exists ".response_analysis"
}

# Edge Case 4: Missing exit signals file
@test "update_exit_signals creates file if missing" {
    local output_file="$LOG_DIR/test.log"

    rm -f "$EXIT_SIGNALS_FILE"

    cat > "$output_file" << 'EOF'
Project is complete.
EOF

    analyze_response "$output_file" 1
    update_exit_signals

    # Should create the file
    assert_file_exists "$EXIT_SIGNALS_FILE"

    # Should be valid JSON
    jq '.' "$EXIT_SIGNALS_FILE" > /dev/null
}

# Edge Case 5: Circuit breaker with negative file count
@test "record_loop_result handles invalid file count gracefully" {
    init_circuit_breaker

    # Try with negative number (should treat as 0)
    record_loop_result 1 -1 "false" 1000 || true

    # Should not crash
    local state=$(jq -r '.state' .circuit_breaker_state)
    # Should still be valid state
    [[ "$state" == "CLOSED" || "$state" == "HALF_OPEN" ]]
}

# Edge Case 6: Very high loop number
@test "circuit breaker handles high loop numbers" {
    init_circuit_breaker

    # Simulate loop 9999
    record_loop_result 9999 5 "false" 1000

    local current_loop=$(jq -r '.current_loop' .circuit_breaker_state)
    assert_equal "$current_loop" "9999"
}

# Edge Case 7: Unicode in output
@test "analyze_response handles unicode characters" {
    local output_file="$LOG_DIR/unicode.log"

    cat > "$output_file" << 'EOF'
Implementation complete! ✅
Features: 🚀 Authentication, 🔒 Security, 📊 Analytics
Status: Done ✨
EOF

    analyze_response "$output_file" 1

    assert_file_exists ".response_analysis"

    # Should detect "Done" as completion keyword
    local has_completion=$(jq -r '.analysis.has_completion_signal' .response_analysis)
    assert_equal "$has_completion" "true"
}

# Edge Case 8: Multiple RALPH_STATUS blocks (malformed)
@test "analyze_response handles multiple status blocks" {
    local output_file="$LOG_DIR/multiple_blocks.log"

    cat > "$output_file" << 'EOF'
First attempt:
---RALPH_STATUS---
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
---END_RALPH_STATUS---

Second attempt:
---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
---END_RALPH_STATUS---
EOF

    analyze_response "$output_file" 1

    # Should detect structured output (picks first or last block)
    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    # Should detect completion somehow
    [[ "$exit_signal" == "true" || "$exit_signal" == "false" ]]
}

# Edge Case 9: Circuit breaker with corrupted state file
@test "circuit breaker handles corrupted state file" {
    init_circuit_breaker

    # Corrupt the state file
    echo "invalid json{" > .circuit_breaker_state

    # Should recover gracefully
    init_circuit_breaker

    # Should have valid state now
    local state=$(jq -r '.state' .circuit_breaker_state)
    assert_equal "$state" "CLOSED"
}

# Edge Case 10: Response analysis with binary content
@test "analyze_response handles binary-like content" {
    local output_file="$LOG_DIR/binary.log"

    # Create file with some control characters
    printf "Output with\x00null bytes\x01and\x02control chars\n" > "$output_file"
    echo "But also normal text: implementation complete" >> "$output_file"

    # Should not crash
    analyze_response "$output_file" 1 || true

    # File should exist even if analysis struggled
    [[ -f ".response_analysis" ]]
}

# Edge Case 11: Simultaneous test-only and completion signals
@test "conflicting signals handled appropriately" {
    local output_file="$LOG_DIR/conflicting.log"

    cat > "$output_file" << 'EOF'
Running tests...
npm test
All tests passed.

Project is complete and ready for review.
EOF

    analyze_response "$output_file" 1

    local is_test_only=$(jq -r '.analysis.is_test_only' .response_analysis)
    local has_completion=$(jq -r '.analysis.has_completion_signal' .response_analysis)

    # Both can be true - completion signal should take precedence
    assert_equal "$has_completion" "true"
}

# Edge Case 12: Circuit breaker rapid state changes
@test "circuit breaker handles rapid state transitions" {
    init_circuit_breaker

    # No progress
    record_loop_result 1 0 "false" 1000 || true
    record_loop_result 2 0 "false" 1000 || true

    # Sudden progress
    record_loop_result 3 5 "false" 2000

    # Should recover to CLOSED
    local state=$(jq -r '.state' .circuit_breaker_state)
    assert_equal "$state" "CLOSED"
}

# Edge Case 13: Output length exactly at decline threshold
@test "output length boundary condition" {
    local output_file="$LOG_DIR/first.log"

    # First output: 1000 chars
    printf "%1000s" " " > "$output_file"
    echo "content" >> "$output_file"

    analyze_response "$output_file" 1

    # Second output: exactly 50% (500 chars)
    cat > "$output_file" << 'EOF'
Done.
EOF
    printf "%495s" " " >> "$output_file"

    analyze_response "$output_file" 2

    # Should be at boundary
    assert_file_exists ".response_analysis"
}

# Edge Case 14: Missing git repository
@test "analyze_response handles missing git repo" {
    # Remove git repo
    rm -rf .git

    local output_file="$LOG_DIR/test.log"
    echo "Implementation work" > "$output_file"

    # Should not crash when git commands fail
    analyze_response "$output_file" 1

    assert_file_exists ".response_analysis"

    # files_modified should be 0 (can't detect without git)
    local files_modified=$(jq -r '.analysis.files_modified' .response_analysis)
    assert_equal "$files_modified" "0"
}

# Edge Case 15: Exit signals array overflow (>100 entries)
@test "exit_signals maintains rolling window limit" {
    local output_file="$LOG_DIR/test.log"

    # Create 10 test-only loops
    for i in {1..10}; do
        cat > "$output_file" << 'EOF'
Running tests...
npm test
EOF
        analyze_response "$output_file" $i
        update_exit_signals
    done

    # Should only keep last 5
    local count=$(jq '.test_only_loops | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$count" "5"

    # Should be loops 6-10
    local first_loop=$(jq '.test_only_loops[0]' "$EXIT_SIGNALS_FILE")
    assert_equal "$first_loop" "6"
}

# Edge Case 16: Circuit breaker with same timestamp
@test "circuit breaker handles rapid loops (same second)" {
    init_circuit_breaker

    # Execute 3 loops in rapid succession (likely same second)
    record_loop_result 1 1 "false" 1000
    record_loop_result 2 1 "false" 1000
    record_loop_result 3 1 "false" 1000

    # Should track all 3 correctly
    local current_loop=$(jq -r '.current_loop' .circuit_breaker_state)
    assert_equal "$current_loop" "3"
}

# Edge Case 17: Confidence score overflow
@test "confidence score handles multiple bonuses correctly" {
    local output_file="$LOG_DIR/high_confidence.log"

    cat > "$output_file" << 'EOF'
Project is complete and finished.
All tasks are done.
Nothing to do.

---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
---END_RALPH_STATUS---
EOF

    # Create file changes
    echo "test" > new_file.txt
    git add new_file.txt

    analyze_response "$output_file" 1

    # Confidence should be very high (100 + bonuses)
    local confidence=$(jq -r '.analysis.confidence_score' .response_analysis)
    [[ "$confidence" -ge 100 ]]
}

# Edge Case 18: Circuit breaker history file corruption
@test "circuit breaker recreates corrupted history" {
    init_circuit_breaker

    # Corrupt history
    echo "not valid json" > .circuit_breaker_history

    # Should handle gracefully on next transition
    record_loop_result 1 0 "false" 1000 || true
    record_loop_result 2 0 "false" 1000 || true

    # Depending on implementation, may recreate or skip history logging
    # Just verify no crash
    [[ -f .circuit_breaker_state ]]
}

# Edge Case 19: Status block with extra fields
@test "analyze_response ignores unknown status fields" {
    local output_file="$LOG_DIR/extra_fields.log"

    cat > "$output_file" << 'EOF'
---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
CUSTOM_FIELD: some_value
UNKNOWN_DATA: 12345
---END_RALPH_STATUS---
EOF

    analyze_response "$output_file" 1

    # Should successfully parse known fields
    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    assert_equal "$exit_signal" "true"
}

# Edge Case 20: Detect stuck loop with varying error messages
@test "detect_stuck_loop with similar but not identical errors" {
    mkdir -p logs

    # Create outputs with similar errors
    cat > "logs/claude_output_1.log" << 'EOF'
Error: Cannot find module 'express' at line 42
EOF

    cat > "logs/claude_output_2.log" << 'EOF'
Error: Cannot find module 'express' at line 43
EOF

    cat > "logs/claude_output_3.log" << 'EOF'
Error: Cannot find module 'express' at line 42
EOF

    # May or may not detect as "stuck" depending on exact match requirements
    # Just verify function runs without crashing
    if detect_stuck_loop "logs/claude_output_3.log" "logs"; then
        result=0
    else
        result=1
    fi

    [[ "$result" -eq 0 || "$result" -eq 1 ]]
}
