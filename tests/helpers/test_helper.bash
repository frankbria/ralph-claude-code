#!/usr/bin/env bash
# Test Helper Utilities for Ralph Test Suite

# Helper: Fail with message (for use in assertions)
fail() {
    echo "$1"
    return 1
}

# Simple assertion functions (replacing bats-assert)
assert_success() {
    if [ "$status" -ne 0 ]; then
        echo "Expected success but got status $status"
        echo "Output: $output"
        return 1
    fi
}

assert_failure() {
    if [ "$status" -eq 0 ]; then
        echo "Expected failure but got success"
        echo "Output: $output"
        return 1
    fi
}

assert_equal() {
    if [ "$1" != "$2" ]; then
        echo "Expected '$2' but got '$1'"
        return 1
    fi
}

assert_output() {
    local expected="$1"
    if [ "$output" != "$expected" ]; then
        echo "Expected output: '$expected'"
        echo "Actual output: '$output'"
        return 1
    fi
}

# Test temporary directory management
export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats-ralph-$$}"

# Setup function - runs before each test
setup() {
    # Create unique temp directory for this test
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/test.XXXXXX")"
    cd "$TEST_TEMP_DIR"

    # Set up test environment variables with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export PROGRESS_FILE="$RALPH_DIR/progress.json"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"

    # Create necessary directories
    mkdir -p "$LOG_DIR" "$DOCS_DIR" "$RALPH_DIR"

    # Initialize files
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
}

# Teardown function - runs after each test
teardown() {
    # Clean up temp directory
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Helper: Strip ANSI color codes from output
strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Helper: Create a mock PROMPT.md file
create_mock_prompt() {
    mkdir -p "$RALPH_DIR"
    cat > "$PROMPT_FILE" << 'EOF'
# Test Prompt
This is a test prompt for Ralph.

## Task
Test the system.
EOF
}

# Helper: Create a mock fix_plan.md file
create_mock_fix_plan() {
    local total=${1:-5}
    local completed=${2:-0}
    local fix_plan_file="$RALPH_DIR/fix_plan.md"

    mkdir -p "$RALPH_DIR"
    cat > "$fix_plan_file" << EOF
# Fix Plan

## High Priority
EOF

    for ((i=1; i<=completed; i++)); do
        echo "- [x] Completed task $i" >> "$fix_plan_file"
    done

    for ((i=completed+1; i<=total; i++)); do
        echo "- [ ] Pending task $i" >> "$fix_plan_file"
    done
}

# Helper: Create a mock status.json file
create_mock_status() {
    local loop_count=${1:-1}
    local calls_made=${2:-0}
    local max_calls=${3:-100}

    cat > "$STATUS_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $max_calls,
    "last_action": "test",
    "status": "running",
    "exit_reason": ""
}
EOF
}

# Helper: Create a mock exit signals file
create_mock_exit_signals() {
    local test_loops=${1:-0}
    local done_signals=${2:-0}
    local completion=${3:-0}

    local test_array="[]"
    local done_array="[]"
    local comp_array="[]"

    if [[ $test_loops -gt 0 ]]; then
        test_array="[$(seq -s, 1 $test_loops)]"
    fi

    if [[ $done_signals -gt 0 ]]; then
        done_array="[$(seq -s, 1 $done_signals)]"
    fi

    if [[ $completion -gt 0 ]]; then
        comp_array="[$(seq -s, 1 $completion)]"
    fi

    cat > "$EXIT_SIGNALS_FILE" << EOF
{
    "test_only_loops": $test_array,
    "done_signals": $done_array,
    "completion_indicators": $comp_array
}
EOF
}

# Helper: Validate JSON structure
assert_valid_json() {
    local file=$1
    run jq empty "$file"
    assert_success
}

# Helper: Get JSON field value
get_json_field() {
    local file=$1
    local field=$2
    jq -r ".$field" "$file"
}

# Helper: Assert file exists
assert_file_exists() {
    local file=$1
    [[ -f "$file" ]] || fail "File does not exist: $file"
}

# Helper: Assert file does not exist
assert_file_not_exists() {
    local file=$1
    [[ ! -f "$file" ]] || fail "File exists but should not: $file"
}

# Helper: Assert directory exists
assert_dir_exists() {
    local dir=$1
    [[ -d "$dir" ]] || fail "Directory does not exist: $dir"
}

# Helper: Mock date command for deterministic tests
mock_date() {
    local timestamp=$1
    function date() {
        if [[ "$1" == "+%Y%m%d%H" ]]; then
            echo "$timestamp"
        elif [[ "$1" == "-Iseconds" ]]; then
            echo "2025-09-30T12:00:00-04:00"
        else
            command date "$@"
        fi
    }
    export -f date
}

# Helper: Restore original date command
restore_date() {
    unset -f date
}

# Helper: Source ralph functions without executing main
source_ralph_functions() {
    # Source the script but prevent main execution
    # We'll extract functions into a separate file for testing
    :
}
