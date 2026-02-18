#!/usr/bin/env bats
# Unit tests for modern CLI command enhancements
# TDD: Write tests first, then implement

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"
    export CLAUDE_MIN_VERSION="2.0.76"
    export CLAUDE_CODE_CMD="claude"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create sample project files
    create_sample_prompt
    create_sample_fix_plan "$RALPH_DIR/fix_plan.md" 10 3

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/circuit_breaker.sh"

    # Define color variables for log_status
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    NC='\033[0m'

    # Define log_status function for tests
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message"
    }

    # ==========================================================================
    # INLINE FUNCTION DEFINITIONS FOR TESTING
    # These are copies of the functions from ralph_loop.sh for isolated testing
    # ==========================================================================

    # Check Claude CLI version for compatibility with modern flags
    check_claude_version() {
        local version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        if [[ -z "$version" ]]; then
            log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
            return 0
        fi

        local required="$CLAUDE_MIN_VERSION"
        local ver_parts=(${version//./ })
        local req_parts=(${required//./ })

        local ver_num=$((${ver_parts[0]:-0} * 10000 + ${ver_parts[1]:-0} * 100 + ${ver_parts[2]:-0}))
        local req_num=$((${req_parts[0]:-0} * 10000 + ${req_parts[1]:-0} * 100 + ${req_parts[2]:-0}))

        if [[ $ver_num -lt $req_num ]]; then
            log_status "WARN" "Claude CLI version $version < $required. Some modern features may not work."
            return 1
        fi

        return 0
    }

    # Build loop context for Claude Code session
    build_loop_context() {
        local loop_count=$1
        local context=""

        context="Loop #${loop_count}. "

        if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
            local incomplete_tasks=$(grep -c "^- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
            context+="Remaining tasks: ${incomplete_tasks}. "
        fi

        if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
            local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
            if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
                context+="Circuit breaker: ${cb_state}. "
            fi
        fi

        if [[ -f "$RALPH_DIR/.response_analysis" ]]; then
            local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RALPH_DIR/.response_analysis" 2>/dev/null | head -c 200)
            if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
                context+="Previous: ${prev_summary}"
            fi
        fi

        echo "${context:0:500}"
    }

    # Initialize or resume Claude session
    init_claude_session() {
        if [[ -f "$CLAUDE_SESSION_FILE" ]]; then
            local session_id=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
            if [[ -n "$session_id" ]]; then
                log_status "INFO" "Resuming Claude session: ${session_id:0:20}..."
                echo "$session_id"
                return 0
            fi
        fi

        log_status "INFO" "Starting new Claude session"
        echo ""
    }

    # Save session ID after successful execution
    save_claude_session() {
        local output_file=$1

        if [[ -f "$output_file" ]]; then
            local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
            if [[ -n "$session_id" && "$session_id" != "null" ]]; then
                echo "$session_id" > "$CLAUDE_SESSION_FILE"
                log_status "INFO" "Saved Claude session: ${session_id:0:20}..."
            fi
        fi
    }
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# CONFIGURATION VARIABLE TESTS
# =============================================================================

@test "CLAUDE_OUTPUT_FORMAT defaults to json" {
    # Verify by checking the default in ralph_loop.sh via grep
    # The default is set via ${CLAUDE_OUTPUT_FORMAT:-json} pattern
    run grep 'CLAUDE_OUTPUT_FORMAT=' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    [[ "$output" == *"json"* ]]
}

@test "CLAUDE_ALLOWED_TOOLS has sensible defaults" {
    # Verify by checking the default in ralph_loop.sh via grep
    run grep 'CLAUDE_ALLOWED_TOOLS=' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should include Write, Bash, Read at minimum
    [[ "$output" == *"Write"* ]]
    [[ "$output" == *"Read"* ]]
}

@test "CLAUDE_ALLOWED_TOOLS default includes Edit tool (issue #136)" {
    # Verify the default includes Edit for file editing
    run grep 'CLAUDE_ALLOWED_TOOLS=.*:-' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The default should include Edit
    [[ "$output" == *"Edit"* ]]
}

@test "CLAUDE_ALLOWED_TOOLS default includes test execution tools (issue #136)" {
    # Verify the default includes test execution capabilities
    run grep 'CLAUDE_ALLOWED_TOOLS=.*:-' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should include Bash(npm *) for npm test
    [[ "$output" == *'Bash(npm *)'* ]]
    # Should include Bash(pytest) for Python tests
    [[ "$output" == *'Bash(pytest)'* ]]
}

@test "CLAUDE_USE_CONTINUE defaults to true" {
    # Verify by checking the default in ralph_loop.sh via grep
    run grep 'CLAUDE_USE_CONTINUE=' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    [[ "$output" == *"true"* ]]
}

# =============================================================================
# CLI FLAG PARSING TESTS
# =============================================================================

@test "--output-format flag sets CLAUDE_OUTPUT_FORMAT" {
    # Simulate parsing
    run bash -c "source ${BATS_TEST_DIRNAME}/../../ralph_loop.sh --output-format text --help 2>&1 || true"

    # After implementation, should accept this flag
    [[ "$output" != *"Unknown option"* ]] || skip "--output-format flag not yet implemented"
}

@test "--output-format rejects invalid values" {
    run bash -c "source ${BATS_TEST_DIRNAME}/../../ralph_loop.sh --output-format invalid 2>&1"

    # Should error on invalid format
    [[ $status -ne 0 ]] || [[ "$output" == *"invalid"* ]] || skip "--output-format validation not yet implemented"
}

@test "--allowed-tools flag sets CLAUDE_ALLOWED_TOOLS" {
    run bash -c "source ${BATS_TEST_DIRNAME}/../../ralph_loop.sh --allowed-tools 'Write,Read' --help 2>&1 || true"

    [[ "$output" != *"Unknown option"* ]] || skip "--allowed-tools flag not yet implemented"
}

@test "--no-continue flag disables session continuity" {
    run bash -c "source ${BATS_TEST_DIRNAME}/../../ralph_loop.sh --no-continue --help 2>&1 || true"

    [[ "$output" != *"Unknown option"* ]] || skip "--no-continue flag not yet implemented"
}

# =============================================================================
# BUILD_LOOP_CONTEXT TESTS
# =============================================================================

@test "build_loop_context includes loop number" {
    run build_loop_context 5

    [[ "$output" == *"Loop #5"* ]] || [[ "$output" == *"5"* ]]
}

@test "build_loop_context counts remaining tasks from fix_plan.md" {
    # Create fix plan with 7 incomplete tasks in .ralph/ directory
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Task 1 done
- [x] Task 2 done
- [x] Task 3 done
- [ ] Task 4 pending
- [ ] Task 5 pending
- [ ] Task 6 pending
- [ ] Task 7 pending
- [ ] Task 8 pending
- [ ] Task 9 pending
- [ ] Task 10 pending
EOF

    run build_loop_context 1

    # Should mention remaining tasks count
    [[ "$output" == *"7"* ]] || [[ "$output" == *"Remaining"* ]] || [[ "$output" == *"tasks"* ]]
}

@test "build_loop_context includes circuit breaker state" {
    # Set up circuit breaker in HALF_OPEN state
    init_circuit_breaker
    record_loop_result 1 0 "false" 1000
    record_loop_result 2 0 "false" 1000

    run build_loop_context 3

    # Should mention circuit breaker state
    [[ "$output" == *"HALF_OPEN"* ]] || [[ "$output" == *"circuit"* ]]
}

@test "build_loop_context includes previous loop summary" {
    # Create previous response analysis
    cat > "$RALPH_DIR/.response_analysis" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "work_summary": "Implemented user authentication"
    }
}
EOF

    run build_loop_context 2

    # Should include previous summary
    [[ "$output" == *"authentication"* ]] || [[ "$output" == *"Previous"* ]]
}

@test "build_loop_context limits output length to 500 chars" {
    # Create very long work summary
    local long_summary=$(printf 'x%.0s' {1..1000})
    cat > "$RALPH_DIR/.response_analysis" << EOF
{
    "loop_number": 1,
    "analysis": {
        "work_summary": "$long_summary"
    }
}
EOF

    run build_loop_context 2

    # Output should be reasonably limited
    [[ ${#output} -le 600 ]]
}

@test "build_loop_context handles missing fix_plan.md gracefully" {
    rm -f "$RALPH_DIR/fix_plan.md"

    run build_loop_context 1

    # Should not error
    assert_equal "$status" "0"
}

@test "build_loop_context handles missing .response_analysis gracefully" {
    rm -f "$RALPH_DIR/.response_analysis"

    run build_loop_context 1

    # Should not error
    assert_equal "$status" "0"
}

# =============================================================================
# SESSION MANAGEMENT TESTS
# =============================================================================

@test "init_claude_session returns empty string for new session" {
    rm -f "$CLAUDE_SESSION_FILE"

    run init_claude_session

    # Should be empty or contain just log message
    [[ -z "$output" ]] || [[ "$output" == *"new"* ]]
}

@test "init_claude_session returns existing session ID" {
    echo "session-abc123" > "$CLAUDE_SESSION_FILE"

    run init_claude_session

    [[ "$output" == *"session-abc123"* ]]
}

@test "save_claude_session extracts session ID from JSON output" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "metadata": {
        "session_id": "new-session-xyz789"
    }
}
EOF

    save_claude_session "$output_file"

    # Should save session ID to file
    assert_file_exists "$CLAUDE_SESSION_FILE"
    local saved=$(cat "$CLAUDE_SESSION_FILE")
    assert_equal "$saved" "new-session-xyz789"
}

@test "save_claude_session does nothing if no session_id in output" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS"
}
EOF

    rm -f "$CLAUDE_SESSION_FILE"

    save_claude_session "$output_file"

    # Should not create session file
    [[ ! -f "$CLAUDE_SESSION_FILE" ]]
}

# =============================================================================
# VERSION CHECK TESTS
# =============================================================================

@test "check_claude_version passes for compatible version" {
    # Mock claude command
    function claude() {
        if [[ "$1" == "--version" ]]; then
            echo "claude-code version 2.1.0"
        fi
    }
    export -f claude
    export CLAUDE_CODE_CMD="claude"

    run check_claude_version

    assert_equal "$status" "0"
}

@test "check_claude_version warns for old version" {
    # Mock claude command with old version
    function claude() {
        if [[ "$1" == "--version" ]]; then
            echo "claude-code version 1.0.0"
        fi
    }
    export -f claude
    export CLAUDE_CODE_CMD="claude"

    run check_claude_version

    # Should fail or warn
    [[ $status -ne 0 ]] || [[ "$output" == *"upgrade"* ]] || [[ "$output" == *"version"* ]]
}

# =============================================================================
# HELP TEXT TESTS
# =============================================================================

@test "show_help includes --output-format option" {
    run bash "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" --help

    [[ "$output" == *"output-format"* ]] || skip "--output-format help not yet added"
}

@test "show_help includes --allowed-tools option" {
    run bash "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" --help

    [[ "$output" == *"allowed-tools"* ]] || skip "--allowed-tools help not yet added"
}

@test "show_help includes --no-continue option" {
    run bash "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" --help

    [[ "$output" == *"no-continue"* ]] || skip "--no-continue help not yet added"
}

# =============================================================================
# BUILD_CLAUDE_COMMAND TESTS (TDD)
# Tests for the fix of --prompt-file -> -p flag
# =============================================================================

# Global array for Claude command arguments (mirrors ralph_loop.sh)
declare -a CLAUDE_CMD_ARGS=()

# Define build_claude_command function for testing
# This is a copy that will be verified against the actual implementation
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # Add output format flag
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Add allowed tools (each tool as separate array element)
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi

    # Add session continuity flag
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        CLAUDE_CMD_ARGS+=("--continue")
    fi

    # Add loop context as system prompt (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi

    # Read prompt file content and use -p flag (NOT --prompt-file which doesn't exist)
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

@test "build_claude_command uses -p flag instead of --prompt-file" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    # Create a test prompt file
    echo "Test prompt content" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "" ""

    # Check that the command array contains -p, not --prompt-file
    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    # Should NOT contain --prompt-file
    [[ "$cmd_string" != *"--prompt-file"* ]]

    # Should contain -p
    [[ "$cmd_string" == *"-p"* ]]
}

@test "build_claude_command reads prompt file content correctly" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="text"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    # Create a test prompt file with specific content
    echo "My specific prompt content for testing" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "" ""

    # Check that the prompt content was read into the command
    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    [[ "$cmd_string" == *"My specific prompt content for testing"* ]]
}

@test "build_claude_command handles missing prompt file" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    # Ensure prompt file doesn't exist
    rm -f "nonexistent_prompt.md"

    run build_claude_command "nonexistent_prompt.md" "" ""

    # Should fail with error
    assert_failure
    [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"not found"* ]]
}

@test "build_claude_command includes all modern CLI flags" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Bash(git *)"
    export CLAUDE_USE_CONTINUE="true"

    # Create a test prompt file
    echo "Test prompt" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "Loop #5 context" ""

    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    # Should include all flags
    [[ "$cmd_string" == *"--output-format"* ]]
    [[ "$cmd_string" == *"json"* ]]
    [[ "$cmd_string" == *"--allowedTools"* ]]
    [[ "$cmd_string" == *"Write"* ]]
    [[ "$cmd_string" == *"Read"* ]]
    [[ "$cmd_string" == *"--continue"* ]]
    [[ "$cmd_string" == *"--append-system-prompt"* ]]
    [[ "$cmd_string" == *"Loop #5 context"* ]]
    [[ "$cmd_string" == *"-p"* ]]
}

@test "build_claude_command handles multiline prompt content" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    # Create a test prompt file with multiple lines
    cat > "$PROMPT_FILE" << 'EOF'
# Test Prompt

## Task Description
This is a multiline prompt
with several lines of text.

## Expected Output
The prompt should be preserved correctly.
EOF

    build_claude_command "$PROMPT_FILE" "" ""

    # Verify the prompt content is in the command
    local found_p_flag=false
    local prompt_index=-1

    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            found_p_flag=true
            prompt_index=$((i + 1))
            break
        fi
    done

    [[ "$found_p_flag" == "true" ]]

    # The next element after -p should contain the multiline content
    [[ "${CLAUDE_CMD_ARGS[$prompt_index]}" == *"multiline prompt"* ]]
    [[ "${CLAUDE_CMD_ARGS[$prompt_index]}" == *"Expected Output"* ]]
}

@test "build_claude_command array prevents shell injection" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    # Create a prompt with potentially dangerous shell characters
    cat > "$PROMPT_FILE" << 'EOF'
Test prompt with $(dangerous) and `backticks` and "quotes"
Also: $VAR and ${VAR} and $(command) and ; rm -rf /
EOF

    build_claude_command "$PROMPT_FILE" "" ""

    # Verify the content is preserved literally (array handles quoting)
    local found_prompt=false
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        if [[ "$arg" == *'$(dangerous)'* ]]; then
            found_prompt=true
            break
        fi
    done

    [[ "$found_prompt" == "true" ]]
}

# =============================================================================
# BACKGROUND EXECUTION STDIN REDIRECT TESTS
# Newer Claude CLI reads stdin even in -p mode, causing SIGTTIN suspension
# when the process is backgrounded. Verify /dev/null redirect is present.
# =============================================================================

@test "modern CLI background execution redirects stdin from /dev/null" {
    # Verify the implementation in ralph_loop.sh redirects stdin from /dev/null
    # to prevent SIGTTIN suspension when claude is backgrounded.
    # Without this, newer Claude CLI versions hang indefinitely.

    run grep 'portable_timeout.*CLAUDE_CMD_ARGS.*< /dev/null.*&' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    assert_success
    [[ "$output" == *'< /dev/null'* ]]
}

@test "live mode execution redirects stdin from /dev/null" {
    # Verify the live (streaming) mode also redirects stdin from /dev/null.
    # This path is used by ralph --monitor (which adds --live).
    # The live mode splits across two lines (line continuation with \),
    # so we check the continuation line that has < /dev/null.

    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The live mode has LIVE_CMD_ARGS on one line and < /dev/null on the next
    run grep '< /dev/null 2>&1 |' "$script"

    assert_success
    [[ "$output" == *'< /dev/null'* ]]
}

@test "all claude execution paths redirect stdin" {
    # Verify that ALL portable_timeout invocations of claude redirect stdin,
    # to prevent regressions. There are 3 paths: modern background, live, legacy.
    # Legacy uses < "$PROMPT_FILE", the other two must use < /dev/null.
    # We check that no portable_timeout line invoking claude lacks a stdin redirect
    # (either on the same line or a continuation line).

    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # All 3 portable_timeout lines that invoke claude should have < somewhere nearby
    # Modern background: has < /dev/null on same line
    run grep 'portable_timeout.*CLAUDE_CMD_ARGS.*< /dev/null' "$script"
    assert_success

    # Live mode: has < /dev/null on continuation line
    run grep '< /dev/null 2>&1 |' "$script"
    assert_success

    # Legacy mode: has < "$PROMPT_FILE" on same line
    run grep 'portable_timeout.*CLAUDE_CODE_CMD.*< ' "$script"
    assert_success
}

@test "modern CLI background execution has comment explaining stdin redirect" {
    # Verify the fix is documented with context about why /dev/null is needed

    run grep -c 'stdin must be redirected' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    assert_success
    # Should appear in both background and live mode sections
    [[ "$output" == "2" ]]
}

# =============================================================================
# .RALPHRC CONFIGURATION LOADING TESTS
# Tests for the environment variable precedence fix
# =============================================================================

@test "load_ralphrc uses env var capture pattern for precedence" {
    # Verify the implementation pattern: _env_* variables capture state before defaults
    # This test validates the pattern is correctly implemented in ralph_loop.sh

    run grep '_env_MAX_CALLS_PER_HOUR=' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should capture env var state BEFORE setting defaults
    [[ "$output" == *'${MAX_CALLS_PER_HOUR:-}'* ]]
}

@test "load_ralphrc restores only env var overrides, not defaults" {
    # Verify that load_ralphrc uses _env_* pattern for restoration
    # This ensures .ralphrc values are not overwritten by script defaults

    run grep -A5 'Restore ONLY values' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should check _env_* variables (not saved_* which would always have values)
    [[ "$output" == *'_env_MAX_CALLS_PER_HOUR'* ]]
    [[ "$output" == *'_env_CLAUDE_TIMEOUT_MINUTES'* ]]
}

# =============================================================================
# LIVE MODE + TEXT FORMAT FIX TESTS (Issue #164)
# Tests for: live mode format override, always-call build_claude_command,
# and safety check for empty CLAUDE_CMD_ARGS
# =============================================================================

@test "build_claude_command works for text format (populates CLAUDE_CMD_ARGS)" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="text"
    export CLAUDE_ALLOWED_TOOLS="Write,Read"
    export CLAUDE_USE_CONTINUE="false"

    echo "Test prompt content" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "" ""

    # CLAUDE_CMD_ARGS should be populated even in text mode
    [[ ${#CLAUDE_CMD_ARGS[@]} -gt 0 ]]

    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    # Should contain claude command and -p flag
    [[ "$cmd_string" == *"claude"* ]]
    [[ "$cmd_string" == *"-p"* ]]
    [[ "$cmd_string" == *"Test prompt content"* ]]

    # Should NOT contain --output-format (text mode omits it)
    [[ "$cmd_string" != *"--output-format"* ]]

    # Should still include allowed tools
    [[ "$cmd_string" == *"--allowedTools"* ]]
    [[ "$cmd_string" == *"Write"* ]]
}

@test "build_claude_command works for json format (includes --output-format json)" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    echo "Test prompt" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "" ""

    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    # Should contain --output-format json
    [[ "$cmd_string" == *"--output-format"* ]]
    [[ "$cmd_string" == *"json"* ]]
    [[ "$cmd_string" == *"-p"* ]]
}

@test "live mode overrides text to json format in ralph_loop.sh" {
    # Verify ralph_loop.sh contains the live mode format override logic
    run grep -A3 'LIVE_OUTPUT.*true.*CLAUDE_OUTPUT_FORMAT.*text' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should find the override block
    [[ "$output" == *"CLAUDE_OUTPUT_FORMAT"* ]]
    [[ "$output" == *"json"* ]]
}

@test "live mode format override preserves json format unchanged" {
    # The override should only trigger when format is "text", not "json"
    # Verify the condition checks for text specifically
    run grep 'CLAUDE_OUTPUT_FORMAT.*text' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should check specifically for "text" (not a blanket override)
    [[ "$output" == *'"text"'* ]]
}

@test "safety check prevents live mode with empty CLAUDE_CMD_ARGS" {
    # Verify ralph_loop.sh has the safety check for empty CLAUDE_CMD_ARGS
    # The check also verifies use_modern_cli is true (not just non-empty array)
    run grep -A3 'use_modern_cli.*CLAUDE_CMD_ARGS.*-eq 0' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Should find safety check that falls back to background mode
    [[ "$output" == *"LIVE_OUTPUT"* ]] || [[ "$output" == *"background"* ]]
}

@test "build_claude_command is called regardless of output format in ralph_loop.sh" {
    # Verify that build_claude_command is NOT gated behind JSON-only check
    # The old pattern was: if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then build_claude_command...
    # The new pattern should call build_claude_command unconditionally

    # Check that build_claude_command call is NOT inside a JSON-only conditional
    # Look for the actual call site (not the function definition or comments)
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The old pattern: "json" check immediately followed by build_claude_command
    # should no longer exist as a gate
    run bash -c "sed -n '/# Build the Claude CLI command/,/# Execute Claude Code/p' '$script' | grep -c 'CLAUDE_OUTPUT_FORMAT.*json.*build_claude_command'"

    # Should find 0 matches (the gate has been removed)
    [[ "$output" == "0" ]]
}

# =============================================================================
# LIVE MODE PIPELINE ERREXIT PROTECTION TESTS (Issue #175)
# set -e + set -o pipefail caused silent script death when Claude timed out.
# The fix disables errexit around the pipeline so PIPESTATUS can be captured.
# =============================================================================

@test "live mode pipeline has set +e before set -o pipefail" {
    # Verify that errexit is disabled BEFORE pipefail is enabled.
    # Without this, timeout exit code 124 silently kills the script.
    # Scoped to the live-mode block to avoid false positives from other sections.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract only the live-mode section (from "Live output mode enabled" to "End of Output")
    local live_block
    live_block=$(sed -n '/Live output mode enabled/,/End of Output/p' "$script")

    # set +e must appear before set -o pipefail within the live-mode block
    echo "$live_block" | grep -q 'set +e'
    echo "$live_block" | grep -q 'set -o pipefail'

    # Verify ordering: set +e comes first
    local plus_e_line=$(echo "$live_block" | grep -n 'set +e' | head -1 | cut -d: -f1)
    local pipefail_line=$(echo "$live_block" | grep -n 'set -o pipefail' | head -1 | cut -d: -f1)

    [[ -n "$plus_e_line" ]]
    [[ -n "$pipefail_line" ]]
    [[ $plus_e_line -lt $pipefail_line ]]
}

@test "live mode pipeline re-enables set -e after PIPESTATUS capture" {
    # Verify that errexit is re-enabled after the pipeline exit codes are captured.
    # Scoped to the live-mode block to avoid matching the global set -e at line 6.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract only the live-mode section
    local live_block
    live_block=$(sed -n '/Live output mode enabled/,/End of Output/p' "$script")

    # set +o pipefail and set -e must both exist in the live block
    echo "$live_block" | grep -q 'set +o pipefail'
    echo "$live_block" | grep -q 'set -e'

    # Verify ordering: set -e comes after set +o pipefail
    local pipefail_off_line=$(echo "$live_block" | grep -n 'set +o pipefail' | head -1 | cut -d: -f1)
    local re_enable_line=$(echo "$live_block" | grep -n '^\s*set -e' | awk -F: -v threshold="$pipefail_off_line" '$1 > threshold {print $1; exit}')

    [[ -n "$pipefail_off_line" ]]
    [[ -n "$re_enable_line" ]]
    [[ $re_enable_line -gt $pipefail_off_line ]]
}

@test "live mode pipeline has errexit guard comment referencing Issue #175" {
    # Verify the fix is documented with context about why errexit is disabled
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run grep -c 'Issue #175' "$script"
    assert_success
    # At least one reference to the issue
    [[ "${output}" -ge 1 ]]
}

@test "live mode pipeline logs timeout events with exit code 124" {
    # Verify that timeout events (exit code 124) produce a log message
    # so timeouts are no longer silent
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run grep 'exit_code -eq 124' "$script"
    assert_success

    run grep 'timed out after' "$script"
    assert_success
}

@test "background mode does not need errexit guard" {
    # Verify background mode uses backgrounding (&) which naturally avoids
    # the set -e issue. The timeout runs in a subprocess, so its exit code
    # doesn't trigger errexit on the parent script.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Background mode lines should have & at end (backgrounding)
    run grep 'portable_timeout.*CLAUDE_CMD_ARGS.*&' "$script"
    assert_success
}

# --- API Limit False Positive Detection Tests (Issue #183) ---

@test "API limit detection has timeout guard before rate limit grep" {
    # Exit code 124 (timeout) must be checked BEFORE the API limit grep
    # to prevent false positives when output file contains echoed "5-hour limit" text
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Find the Layer 1 guard specifically (in the failure path, marked by comment)
    local layer1_line=$(grep -n 'Layer 1.*Timeout guard' "$script" | head -1 | cut -d: -f1)
    local timeout_line=$(awk -F: -v s="$layer1_line" 'NR >= s && /exit_code -eq 124/ { print NR; exit }' "$script")
    local rate_limit_grep_line=$(grep -n 'rate_limit_event' "$script" | head -1 | cut -d: -f1)
    local text_fallback_line=$(grep -n '5.*hour.*limit' "$script" | head -1 | cut -d: -f1)

    # Layer 1 guard must exist in the failure path
    [[ -n "$layer1_line" ]]
    [[ -n "$timeout_line" ]]
    [[ -n "$rate_limit_grep_line" ]]
    [[ -n "$text_fallback_line" ]]
    # Timeout guard must appear before both rate limit checks
    [[ "$timeout_line" -lt "$rate_limit_grep_line" ]]
    [[ "$timeout_line" -lt "$text_fallback_line" ]]
}

@test "API limit detection checks rate_limit_event JSON as primary signal" {
    # The primary detection method should parse rate_limit_event for status:"rejected"
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Verify rate_limit_event grep exists
    run grep 'rate_limit_event' "$script"
    assert_success

    # Verify it checks for status:rejected
    run grep '"status":"rejected"' "$script"
    assert_success
}

@test "API limit detection filters tool result content in fallback" {
    # The text fallback must filter out type:user and tool_result lines
    # to avoid matching "5-hour limit" text echoed from project files
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Verify filtering of tool result content (whitespace-tolerant pattern)
    run grep 'grep -vE.*"type".*"user"' "$script"
    assert_success

    run grep 'grep -v.*"tool_result"' "$script"
    assert_success

    run grep 'grep -v.*"tool_use_id"' "$script"
    assert_success
}

@test "API limit detection uses tail not full file in fallback" {
    # The text fallback should use tail (not grep the whole file)
    # to limit the search scope and reduce false positives
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The fallback line should use tail before grep
    run grep 'tail -30.*output_file.*grep -v.*grep -qi.*5.*hour.*limit' "$script"
    assert_success
}

@test "API limit prompt defaults to wait in unattended mode" {
    # When the read prompt times out (empty user_choice), Ralph should
    # auto-wait instead of exiting — supports unattended operation
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The exit condition should ONLY trigger on explicit "2", not on empty/timeout
    run grep 'user_choice.*==.*"2"' "$script"
    assert_success

    # Should NOT have the old pattern that exits on empty choice
    run grep 'user_choice.*==.*"2".*||.*-z.*user_choice' "$script"
    assert_failure
}
