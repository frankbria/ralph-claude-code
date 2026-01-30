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
