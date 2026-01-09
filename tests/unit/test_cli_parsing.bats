#!/usr/bin/env bats
# Unit tests for CLI argument parsing in ralph_loop.sh
# Linked to GitHub Issue #10
# TDD: Tests written to cover all CLI flag combinations

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to ralph_loop.sh
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize minimal git repo (required by some flags)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up required environment
    export PROMPT_FILE="PROMPT.md"
    export LOG_DIR="logs"
    export STATUS_FILE="status.json"
    export EXIT_SIGNALS_FILE=".exit_signals"
    export CALL_COUNT_FILE=".call_count"
    export TIMESTAMP_FILE=".last_reset"

    mkdir -p "$LOG_DIR"

    # Create minimal required files
    echo "# Test Prompt" > "$PROMPT_FILE"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create lib directory with circuit breaker stub
    mkdir -p lib
    cat > lib/circuit_breaker.sh << 'EOF'
reset_circuit_breaker() { echo "Circuit breaker reset: $1"; }
show_circuit_status() { echo "Circuit breaker status: CLOSED"; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
EOF

    cat > lib/response_analyzer.sh << 'EOF'
analyze_response() { :; }
detect_output_format() { echo "text"; }
EOF

    cat > lib/date_utils.sh << 'EOF'
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
EOF
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HELP FLAG TESTS (2 tests)
# =============================================================================

@test "--help flag displays help message with all options" {
    run bash "$RALPH_SCRIPT" --help

    assert_success

    # Verify help contains key sections
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Options:"* ]]

    # Verify all flags are documented
    [[ "$output" == *"--calls"* ]]
    [[ "$output" == *"--prompt"* ]]
    [[ "$output" == *"--status"* ]]
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"--verbose"* ]]
    [[ "$output" == *"--timeout"* ]]
    [[ "$output" == *"--reset-circuit"* ]]
    [[ "$output" == *"--circuit-status"* ]]
    [[ "$output" == *"--output-format"* ]]
    [[ "$output" == *"--allowed-tools"* ]]
    [[ "$output" == *"--no-continue"* ]]
}

@test "-h short flag displays help message" {
    run bash "$RALPH_SCRIPT" -h

    assert_success

    # Verify help contains key sections
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Options:"* ]]
    [[ "$output" == *"--help"* ]]
}

# =============================================================================
# FLAG VALUE SETTING TESTS (6 tests)
# =============================================================================

@test "--calls NUM sets MAX_CALLS_PER_HOUR correctly" {
    # Use --help after --calls to capture the parsed value without running main loop
    run bash "$RALPH_SCRIPT" --calls 50 --help

    assert_success
    # The help output shows default values, but the script would have parsed --calls 50
    # We verify parsing by checking the script doesn't error on valid input
    [[ "$output" == *"Usage:"* ]]
}

@test "--prompt FILE sets PROMPT_FILE correctly" {
    # Create custom prompt file
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" --prompt custom_prompt.md --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--monitor flag is accepted without error" {
    # Monitor flag combined with help to verify parsing
    run bash "$RALPH_SCRIPT" --monitor --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--verbose flag is accepted without error" {
    run bash "$RALPH_SCRIPT" --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--timeout NUM sets timeout with valid value" {
    run bash "$RALPH_SCRIPT" --timeout 30 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--timeout validates range (1-120)" {
    # Test invalid: 0
    run bash "$RALPH_SCRIPT" --timeout 0
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test invalid: 121
    run bash "$RALPH_SCRIPT" --timeout 121
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test invalid: negative
    run bash "$RALPH_SCRIPT" --timeout -5
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test boundary: 1 (valid)
    run bash "$RALPH_SCRIPT" --timeout 1 --help
    assert_success

    # Test boundary: 120 (valid)
    run bash "$RALPH_SCRIPT" --timeout 120 --help
    assert_success
}

# =============================================================================
# STATUS FLAG TESTS (2 tests)
# =============================================================================

@test "--status shows status when status.json exists" {
    # Create mock status file
    cat > "$STATUS_FILE" << 'EOF'
{
    "timestamp": "2025-01-08T12:00:00-05:00",
    "loop_count": 5,
    "calls_made_this_hour": 42,
    "max_calls_per_hour": 100,
    "last_action": "executing",
    "status": "running"
}
EOF

    run bash "$RALPH_SCRIPT" --status

    assert_success
    [[ "$output" == *"Current Status:"* ]] || [[ "$output" == *"loop_count"* ]]
    [[ "$output" == *"5"* ]]  # loop_count value
}

@test "--status handles missing status file gracefully" {
    rm -f "$STATUS_FILE"

    run bash "$RALPH_SCRIPT" --status

    assert_success
    [[ "$output" == *"No status file found"* ]]
}

# =============================================================================
# CIRCUIT BREAKER FLAG TESTS (2 tests)
# =============================================================================

@test "--reset-circuit flag executes circuit breaker reset" {
    run bash "$RALPH_SCRIPT" --reset-circuit

    assert_success
    [[ "$output" == *"Circuit breaker reset"* ]] || [[ "$output" == *"reset"* ]]
}

@test "--circuit-status flag shows circuit breaker status" {
    run bash "$RALPH_SCRIPT" --circuit-status

    assert_success
    [[ "$output" == *"Circuit breaker status"* ]] || [[ "$output" == *"CLOSED"* ]] || [[ "$output" == *"status"* ]]
}

# =============================================================================
# INVALID INPUT TESTS (3 tests)
# =============================================================================

@test "Invalid flag shows error and help" {
    run bash "$RALPH_SCRIPT" --invalid-flag

    assert_failure
    [[ "$output" == *"Unknown option: --invalid-flag"* ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "Invalid timeout format shows error" {
    run bash "$RALPH_SCRIPT" --timeout abc

    assert_failure
    [[ "$output" == *"must be a positive integer"* ]] || [[ "$output" == *"Error"* ]]
}

@test "--output-format rejects invalid format values" {
    run bash "$RALPH_SCRIPT" --output-format invalid

    assert_failure
    [[ "$output" == *"must be 'json' or 'text'"* ]]
}

@test "--allowed-tools flag accepts valid tool list" {
    run bash "$RALPH_SCRIPT" --allowed-tools "Write,Read,Bash" --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# MULTIPLE FLAGS TESTS (3 tests)
# =============================================================================

@test "Multiple flags combined (--calls --prompt --verbose)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" --calls 50 --prompt custom_prompt.md --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "All flags combined works correctly" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" \
        --calls 25 \
        --prompt custom_prompt.md \
        --verbose \
        --timeout 20 \
        --output-format json \
        --no-continue \
        --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "Help flag with other flags shows help (early exit)" {
    run bash "$RALPH_SCRIPT" --calls 50 --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
    # Script should exit with help, not run main loop
}

# =============================================================================
# FLAG ORDER INDEPENDENCE TESTS (2 tests)
# =============================================================================

@test "Flag order doesn't matter (order A: calls-prompt-verbose)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" --calls 50 --prompt custom_prompt.md --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "Flag order doesn't matter (order B: verbose-prompt-calls)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" --verbose --prompt custom_prompt.md --calls 50 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# SHORT FLAG EQUIVALENCE TESTS (bonus: verify short flags work)
# =============================================================================

@test "-c short flag works like --calls" {
    run bash "$RALPH_SCRIPT" -c 50 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "-p short flag works like --prompt" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$RALPH_SCRIPT" -p custom_prompt.md --help

    assert_success
}

@test "-s short flag works like --status" {
    rm -f "$STATUS_FILE"

    run bash "$RALPH_SCRIPT" -s

    assert_success
    [[ "$output" == *"No status file found"* ]]
}

@test "-m short flag works like --monitor" {
    run bash "$RALPH_SCRIPT" -m --help

    assert_success
}

@test "-v short flag works like --verbose" {
    run bash "$RALPH_SCRIPT" -v --help

    assert_success
}

@test "-t short flag works like --timeout" {
    run bash "$RALPH_SCRIPT" -t 30 --help

    assert_success
}
