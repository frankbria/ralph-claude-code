#!/usr/bin/env bash
# Test Helper Utilities for Ralph Test Suite

# Simple assertion functions (replacing bats-assert)
fail() {
    echo "$1"
    return 1
}

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

    # Set up test environment variables
    export PROMPT_FILE="PROMPT.md"
    export LOG_DIR="logs"
    export DOCS_DIR="docs/generated"
    export STATUS_FILE="status.json"
    export PROGRESS_FILE="progress.json"
    export CALL_COUNT_FILE=".call_count"
    export TIMESTAMP_FILE=".last_reset"
    export EXIT_SIGNALS_FILE=".exit_signals"

    # Create necessary directories
    mkdir -p "$LOG_DIR" "$DOCS_DIR"

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

    # Clean up xargs wrapper directory (Windows compatibility)
    if [[ -n "$_XARGS_WRAPPER_DIR" && -d "$_XARGS_WRAPPER_DIR" ]]; then
        rm -rf "$_XARGS_WRAPPER_DIR"
    fi
}

# Helper: Strip ANSI color codes from output
strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Helper: Create a mock PROMPT.md file
create_mock_prompt() {
    cat > "$PROMPT_FILE" << 'EOF'
# Test Prompt
This is a test prompt for Ralph.

## Task
Test the system.
EOF
}

# Helper: Create a mock @fix_plan.md file
create_mock_fix_plan() {
    local total=${1:-5}
    local completed=${2:-0}

    cat > "@fix_plan.md" << EOF
# Fix Plan

## High Priority
EOF

    for ((i=1; i<=completed; i++)); do
        echo "- [x] Completed task $i" >> "@fix_plan.md"
    done

    for ((i=completed+1; i<=total; i++)); do
        echo "- [ ] Pending task $i" >> "@fix_plan.md"
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

# =============================================================================
# WINDOWS COMPATIBILITY
# =============================================================================

# Detect if running on Windows (Git Bash/MSYS/Cygwin)
is_windows_test_env() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# On Windows, xargs fails with "environment is too large" when functions are exported.
# Create a wrapper script that runs xargs with a minimal environment.
if is_windows_test_env; then
    # Create wrapper directory in temp
    _XARGS_WRAPPER_DIR="${BATS_TEST_TMPDIR:-/tmp}/xargs_wrapper_$$"
    mkdir -p "$_XARGS_WRAPPER_DIR"

    # Find real xargs
    _REAL_XARGS=$(command -v xargs)

    # Create wrapper script - escape variables for runtime expansion
    cat > "$_XARGS_WRAPPER_DIR/xargs" << WRAPPER_EOF
#!/bin/bash
exec env -i PATH="\$PATH" HOME="\$HOME" TERM="\$TERM" "$_REAL_XARGS" "\$@"
WRAPPER_EOF
    chmod +x "$_XARGS_WRAPPER_DIR/xargs"

    # Prepend to PATH so our wrapper is found first
    export PATH="$_XARGS_WRAPPER_DIR:$PATH"
fi
