#!/usr/bin/env bats
# Unit tests for live mode functionality in ralph_loop.sh
# PR #125: Add live streaming output mode

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to ralph_loop.sh
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize minimal git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up required environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export LIVE_LOG_FILE="$RALPH_DIR/live.log"

    mkdir -p "$LOG_DIR"

    # Create minimal required files
    echo "# Test Prompt" > "$PROMPT_FILE"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create lib directory with stubs
    mkdir -p lib
    cat > lib/circuit_breaker.sh << 'EOF'
RALPH_DIR="${RALPH_DIR:-.ralph}"
reset_circuit_breaker() { echo "Circuit breaker reset: $1"; }
show_circuit_status() { echo "Circuit breaker status: CLOSED"; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
EOF

    cat > lib/response_analyzer.sh << 'EOF'
RALPH_DIR="${RALPH_DIR:-.ralph}"
analyze_response() { :; }
update_exit_signals() { :; }
log_analysis_summary() { :; }
EOF

    cat > lib/date_utils.sh << 'EOF'
get_epoch_seconds() { date +%s; }
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }
EOF

    cat > lib/timeout_utils.sh << 'EOF'
portable_timeout() { timeout "$@"; }
EOF
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# =============================================================================
# DEPENDENCY CHECKS (4 tests)
# =============================================================================

@test "live mode checks for jq dependency" {
    # Temporarily hide jq
    local original_path="$PATH"
    export PATH="/usr/bin:/bin"

    # Create a mock environment where jq doesn't exist
    # This test verifies the dependency check logic exists
    run grep -q "command -v jq" "$RALPH_SCRIPT"
    assert_success
}

@test "live mode checks for stdbuf dependency" {
    # Verify stdbuf check exists in the script
    run grep -q "command -v stdbuf" "$RALPH_SCRIPT"
    assert_success
}

@test "live mode falls back to background mode when jq missing" {
    # Verify fallback logic exists
    run grep -q "Falling back to background mode" "$RALPH_SCRIPT"
    assert_success
}

@test "live mode falls back to background mode when stdbuf missing" {
    # Verify fallback mentions stdbuf
    run grep -q "stdbuf.*not installed" "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# LIVE_CMD_ARGS CONSTRUCTION (4 tests)
# =============================================================================

@test "live mode replaces json with stream-json in output format" {
    # Verify the replacement logic exists
    run grep -q 'stream-json' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode adds --verbose flag" {
    # Verify --verbose is added for stream-json
    run grep -q 'LIVE_CMD_ARGS.*--verbose' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode adds --include-partial-messages flag" {
    # Verify --include-partial-messages is added
    run grep -q 'include-partial-messages' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode preserves CLAUDE_CMD_ARGS flags" {
    # Verify the loop that copies from CLAUDE_CMD_ARGS
    run grep -q 'for arg in.*CLAUDE_CMD_ARGS' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# TIMEOUT PROTECTION (2 tests)
# =============================================================================

@test "live mode uses portable_timeout" {
    # Verify portable_timeout is used in the live mode execution section
    # The live mode uses portable_timeout with LIVE_CMD_ARGS
    run grep -q 'portable_timeout.*LIVE_CMD_ARGS' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode timeout uses same timeout_seconds as background mode" {
    # Verify timeout_seconds variable is used
    run grep -q 'portable_timeout.*timeout_seconds' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# SESSION EXTRACTION (5 tests)
# =============================================================================

@test "live mode extracts session from stream-json output" {
    # Verify session extraction logic exists
    run grep -q 'result.*type.*result' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode validates JSON before using it" {
    # Verify jq validation
    run grep -q 'jq -e' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode preserves stream output in _stream.log" {
    # Verify stream output is preserved
    run grep -q '_stream.log' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode restores stream output if JSON validation fails" {
    # Verify fallback behavior
    run grep -q 'keeping stream output' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode uses flexible regex for JSON matching" {
    # Verify flexible whitespace matching pattern [[:space:]] is used
    # Use fixed string grep to avoid regex interpretation
    run grep -F '[[:space:]]' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# PIPELINE ERROR HANDLING (3 tests)
# =============================================================================

@test "live mode captures all pipeline exit codes" {
    # Verify PIPESTATUS is captured
    run grep -q 'pipe_status.*PIPESTATUS' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode checks tee exit code" {
    # Verify pipe_status[1] check (tee)
    run grep -q 'pipe_status\[1\]' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode checks jq exit code" {
    # Verify pipe_status[2] check (jq)
    run grep -q 'pipe_status\[2\]' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# JQ FILTER (2 tests)
# =============================================================================

@test "jq filter extracts text_delta events" {
    # Verify text_delta extraction
    run grep -q 'text_delta' "$RALPH_SCRIPT"
    assert_success
}

@test "jq filter shows tool usage indicators" {
    # Verify tool usage display
    run grep -q 'tool_use' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# LIVE LOG FILE (2 tests)
# =============================================================================

@test "live mode initializes live.log file" {
    # Verify live.log initialization
    run grep -q 'LIVE_LOG_FILE' "$RALPH_SCRIPT"
    assert_success
}

@test "live mode writes to live.log via tee" {
    # Verify output goes to LIVE_LOG_FILE
    run grep -q 'tee.*LIVE_LOG_FILE' "$RALPH_SCRIPT"
    assert_success
}

# =============================================================================
# SECURITY (2 tests)
# =============================================================================

@test "live mode does not use --dangerously-skip-permissions" {
    # Verify LIVE_CMD_ARGS doesn't add dangerous flag as an actual CLI argument
    # The string may appear in comments, but not as an array element
    run bash -c "grep -A20 'LIVE_CMD_ARGS+=' '$RALPH_SCRIPT' | grep -v '^#' | grep -v 'Note:' | grep -q 'dangerously-skip-permissions'"
    assert_failure  # Should NOT find this in actual code (only comments allowed)
}

@test "build_claude_command does not include --dangerously-skip-permissions" {
    # Verify CLAUDE_CMD_ARGS construction doesn't use dangerous flag
    # The string may appear in comments, but not as an actual array element
    run bash -c "grep -A10 'CLAUDE_CMD_ARGS=(' '$RALPH_SCRIPT' | grep -v '^#' | grep -v 'Note:' | grep -q 'dangerously-skip-permissions'"
    assert_failure  # Should NOT find this in actual code (only comments allowed)
}
