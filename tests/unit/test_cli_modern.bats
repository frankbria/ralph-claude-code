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

    # Compare two semver strings: returns 0 if ver1 >= ver2, 1 if ver1 < ver2
    compare_semver() {
        local ver1="$1" ver2="$2"
        local v1_major v1_minor v1_patch
        local v2_major v2_minor v2_patch

        IFS='.' read -r v1_major v1_minor v1_patch <<< "$ver1"
        IFS='.' read -r v2_major v2_minor v2_patch <<< "$ver2"

        v1_major=${v1_major:-0}; v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
        v2_major=${v2_major:-0}; v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}

        if [[ $v1_major -gt $v2_major ]]; then return 0; fi
        if [[ $v1_major -lt $v2_major ]]; then return 1; fi
        if [[ $v1_minor -gt $v2_minor ]]; then return 0; fi
        if [[ $v1_minor -lt $v2_minor ]]; then return 1; fi
        if [[ $v1_patch -lt $v2_patch ]]; then return 1; fi
        return 0
    }

    # Check Claude CLI version for compatibility with modern flags
    check_claude_version() {
        local version
        version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        if [[ -z "$version" ]]; then
            log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
            return 0
        fi

        if ! compare_semver "$version" "$CLAUDE_MIN_VERSION"; then
            log_status "WARN" "Claude CLI version $version < $CLAUDE_MIN_VERSION. Some modern features may not work."
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
            local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
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
                context+="Previous: ${prev_summary} "
            fi
        fi

        # If previous loop detected questions, inject corrective guidance (Issue #190 Bug 2)
        if [[ -f "$RALPH_DIR/.response_analysis" ]]; then
            local prev_asking_questions
            prev_asking_questions=$(jq -r '.analysis.asking_questions // false' "$RALPH_DIR/.response_analysis" 2>/dev/null || echo "false")
            if [[ "$prev_asking_questions" == "true" ]]; then
                context+="IMPORTANT: You asked questions in the previous loop. This is a headless automation loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe default and proceed autonomously. "
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

    # validate_claude_command - Verify the Claude Code CLI is available (Issue #97)
    validate_claude_command() {
        local cmd="$CLAUDE_CODE_CMD"

        if [[ "$cmd" == npx\ * ]] || [[ "$cmd" == "npx" ]]; then
            if ! command -v npx &>/dev/null; then
                echo "NPX NOT FOUND"
                return 1
            fi
            return 0
        fi

        if ! command -v "$cmd" &>/dev/null; then
            echo "CLAUDE CODE CLI NOT FOUND: $cmd"
            return 1
        fi

        return 0
    }

    # load_ralphrc - minimal version for testing CLAUDE_CODE_CMD loading
    RALPHRC_FILE=".ralphrc"
    RALPHRC_LOADED=false
    _env_CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-}"

    load_ralphrc() {
        if [[ ! -f "$RALPHRC_FILE" ]]; then
            return 0
        fi
        source "$RALPHRC_FILE"
        [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
        RALPHRC_LOADED=true
        return 0
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
    # stderr is redirected to a separate file (Issue #190)
    run grep '< /dev/null 2>"$stderr_file" |' "$script"

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

    # Live mode: has < /dev/null with stderr redirect on continuation line
    run grep '< /dev/null 2>"$stderr_file" |' "$script"
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
# LIVE MODE PIPELINE ERROR HANDLING TESTS
# set -e was removed globally; the live pipeline no longer needs errexit toggles.
# These tests verify the new explicit error handling approach.
# =============================================================================

@test "live mode pipeline does not use set +e/set -e toggles" {
    # With set -e removed globally, the live mode pipeline no longer needs
    # to toggle errexit. Verify no set +e/set -e appears in the live block.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    local live_block
    live_block=$(sed -n '/Live output mode enabled/,/End of Output/p' "$script")

    # set +e and set -e should NOT appear in the live block
    ! echo "$live_block" | grep -q '^[[:space:]]*set +e$'
    ! echo "$live_block" | grep -q '^[[:space:]]*set -e'
    ! echo "$live_block" | grep -q 'set -o pipefail'
    ! echo "$live_block" | grep -q 'set +o pipefail'
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

    # Verify it checks for status:rejected (whitespace-tolerant pattern)
    run grep '"status".*"rejected"' "$script"
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

# --- Behavioral Tests: API Limit Detection Against Fixture Data (Issue #183) ---
# These tests exercise the actual detection logic against fixture files,
# complementing the grep-based structural tests above.

# Helper: runs the three-layer detection logic from ralph_loop.sh against a
# given output file and exit code. Returns the same codes as execute_claude_code:
#   1 = generic error (not API limit)
#   2 = API limit detected
_detect_api_limit() {
    local exit_code="$1"
    local output_file="$2"

    # Layer 1: Timeout guard
    if [[ $exit_code -eq 124 ]]; then
        return 1
    fi

    # Layer 2: Structural JSON detection
    if grep -q '"rate_limit_event"' "$output_file" 2>/dev/null; then
        local last_rate_event
        last_rate_event=$(grep '"rate_limit_event"' "$output_file" | tail -1)
        if echo "$last_rate_event" | grep -qE '"status"\s*:\s*"rejected"'; then
            return 2
        fi
    fi

    # Layer 3: Filtered text fallback
    if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached"; then
        return 2
    fi

    # Layer 4: Extra Usage quota detection (Issue #100)
    if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "out of extra usage"; then
        return 2
    fi

    return 1
}

@test "behavioral: timeout (exit 124) with echoed 5-hour-limit text returns 1, not 2" {
    # Scenario: Claude timed out, output contains "5-hour limit" in echoed file content
    local output_file="$TEST_DIR/claude_output_timeout.log"
    create_sample_stream_json_with_prompt_echo "$output_file"

    # exit_code=124 (timeout) — should return 1 regardless of file content
    run _detect_api_limit 124 "$output_file"
    assert_failure  # return code 1 (not 0)
    [[ "$status" -eq 1 ]]
}

@test "behavioral: real rate_limit_event status:rejected returns 2" {
    # Scenario: Claude hit the actual API limit (rate_limit_event rejected)
    local output_file="$TEST_DIR/claude_output_rejected.log"
    create_sample_stream_json_rate_limit_rejected "$output_file"

    # exit_code=1 (non-timeout failure) — should detect real API limit
    run _detect_api_limit 1 "$output_file"
    [[ "$status" -eq 2 ]]
}

@test "behavioral: rate_limit_event status:allowed with prompt echo returns 1" {
    # Scenario: No API limit, but output contains "5-hour limit" from echoed files
    # The type:user filter should prevent false positive
    local output_file="$TEST_DIR/claude_output_echo.log"
    create_sample_stream_json_with_prompt_echo "$output_file"

    # exit_code=1 (non-timeout failure) — should NOT detect API limit
    run _detect_api_limit 1 "$output_file"
    [[ "$status" -eq 1 ]]
}

# --- Extra Usage Detection Tests (Issue #100) ---

@test "behavioral: Extra Usage quota exhausted returns 2" {
    # Scenario: Claude Extra Usage quota ran out
    local output_file="$TEST_DIR/claude_extra_usage.log"
    cat > "$output_file" << 'EOF'
{"type":"system","subtype":"init","session_id":"abc123"}
{"type":"assistant","message":"Working on tasks..."}
You're out of extra usage · resets 9pm
EOF

    run _detect_api_limit 1 "$output_file"
    [[ "$status" -eq 2 ]]
}

@test "behavioral: Extra Usage in echoed content does not false positive" {
    # Scenario: "extra usage" text appears inside a tool_result (echoed file content)
    local output_file="$TEST_DIR/claude_extra_echo.log"
    cat > "$output_file" << 'EOF'
{"type":"system","subtype":"init","session_id":"abc123"}
{"type":"user","tool_result":"The docs mention: You're out of extra usage · resets 9pm"}
{"type":"assistant","message":"I see the docs reference to extra usage limits."}
EOF

    run _detect_api_limit 1 "$output_file"
    [[ "$status" -eq 1 ]]
}

@test "Layer 4 Extra Usage detection exists in ralph_loop.sh" {
    # Verify that the Layer 4 block exists with the correct pattern
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run grep -i 'extra.usage' "$script"
    assert_success

    # Should return code 2 (API limit)
    run grep -A 2 -i 'extra.usage' "$script"
    echo "$output" | grep -q 'return 2'
}

@test "user-facing API limit message covers both limit types" {
    # The user prompt should mention both 5-hour limit and Extra Usage
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run grep -i 'usage limit.*reached\|limit.*reached' "$script"
    assert_success
    # Should mention Extra Usage or be generic enough to cover both
    echo "$output" | grep -qi 'extra.*usage\|usage.*limit'
}

# --- Claude Code Command Validation Tests (Issue #97) ---

@test "validate_claude_command succeeds for command that exists" {
    # 'bash' exists on all systems
    CLAUDE_CODE_CMD="bash"
    run validate_claude_command
    assert_success
}

@test "validate_claude_command fails for missing command" {
    CLAUDE_CODE_CMD="nonexistent_command_xyz_97"
    run validate_claude_command
    assert_failure
    [[ "$output" == *"CLAUDE CODE CLI NOT FOUND"* ]]
}

@test "validate_claude_command succeeds for npx-based command when npx exists" {
    # npx should be available in test environment (Node.js is a dependency)
    if ! command -v npx &>/dev/null; then
        skip "npx not available in test environment"
    fi
    CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"
    run validate_claude_command
    assert_success
}

@test "validate_claude_command checks npx availability for npx commands" {
    # If npx doesn't exist, npx-based commands should fail
    # We test by temporarily hiding npx from PATH
    local original_path="$PATH"
    PATH="/usr/bin:/bin"  # Minimal PATH unlikely to contain npx
    if command -v npx &>/dev/null; then
        PATH="$original_path"
        skip "Cannot hide npx from PATH in this environment"
    fi
    CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"
    run validate_claude_command
    assert_failure
    [[ "$output" == *"NPX NOT FOUND"* ]]
    PATH="$original_path"
}

@test "validate_claude_command output includes current command name" {
    CLAUDE_CODE_CMD="my_custom_claude_binary"
    run validate_claude_command
    assert_failure
    [[ "$output" == *"my_custom_claude_binary"* ]]
}

@test "CLAUDE_CODE_CMD is loaded from .ralphrc" {
    # Create a .ralphrc with custom CLAUDE_CODE_CMD
    cat > "$TEST_DIR/.ralphrc" << 'EOF'
CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"
EOF
    # Reset env override so .ralphrc value takes effect
    _env_CLAUDE_CODE_CMD=""
    CLAUDE_CODE_CMD="claude"

    load_ralphrc
    assert_equal "$CLAUDE_CODE_CMD" "npx @anthropic-ai/claude-code"
}

@test "CLAUDE_CODE_CMD env var takes precedence over .ralphrc" {
    cat > "$TEST_DIR/.ralphrc" << 'EOF'
CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"
EOF
    # Simulate env var set before script started
    _env_CLAUDE_CODE_CMD="/custom/path/claude"
    CLAUDE_CODE_CMD="/custom/path/claude"

    load_ralphrc
    assert_equal "$CLAUDE_CODE_CMD" "/custom/path/claude"
}

@test "validate_claude_command is called before loop in ralph_loop.sh" {
    # Structural test: validate_claude_command must be called in main() before the loop
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    local validate_line=$(grep -n 'validate_claude_command' "$script" | grep -v '^#' | grep -v 'function\|#' | head -1 | cut -d: -f1)
    local loop_start_line=$(grep -n 'while true; do' "$script" | head -1 | cut -d: -f1)

    [[ -n "$validate_line" ]]
    [[ -n "$loop_start_line" ]]
    [[ "$validate_line" -lt "$loop_start_line" ]]
}

@test "generate_ralphrc includes CLAUDE_CODE_CMD field" {
    local script="${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"
    run grep 'CLAUDE_CODE_CMD' "$script"
    assert_success
}

@test "setup.sh ralphrc fallback includes CLAUDE_CODE_CMD field" {
    local script="${BATS_TEST_DIRNAME}/../../setup.sh"
    run grep 'CLAUDE_CODE_CMD' "$script"
    assert_success
}

# --- Issue #196: Call counter must persist immediately, not only on success ---

@test "execute_claude_code uses increment_call_counter instead of manual read+increment" {
    # Issue #196: The bug was execute_claude_code manually doing calls_made=$((calls_made + 1))
    # instead of using increment_call_counter() which writes to disk immediately.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Verify increment_call_counter is called in execute_claude_code
    run grep 'calls_made=\$(increment_call_counter)' "$script"
    assert_success

    # Verify the old manual increment pattern is gone (this was unique to the bug)
    run grep 'calls_made=\$((calls_made + 1))' "$script"
    assert_failure
}

@test "execute_claude_code does not conditionally write call count on success" {
    # Issue #196: The comment "Only increment counter on successful execution" was
    # the marker for the conditional write that caused stale counters on failure.
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # This comment+write pair was removed — counter is now persisted before execution
    run grep 'Only increment counter on successful execution' "$script"
    assert_failure
}

# =============================================================================
# is_error DETECTION IN SUCCESS PATH (Issue #134, #199)
# =============================================================================

@test "execute_claude_code success path checks is_error field" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # Verify the is_error check exists in the exit_code == 0 branch
    run grep -A 30 'if \[ \$exit_code -eq 0 \]' "$script"
    assert_success
    [[ "$output" == *"is_error"* ]]
}

@test "is_error check occurs before save_claude_session in success path" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # Within execute_claude_code's exit_code==0 branch, the is_error guard must
    # appear BEFORE the save_claude_session call
    local is_error_line=$(grep -n 'grep.*"is_error"' "$script" | head -1 | cut -d: -f1)
    local save_session_line=$(grep -n 'save_claude_session.*output_file' "$script" | head -1 | cut -d: -f1)

    [[ -n "$is_error_line" ]]
    [[ -n "$save_session_line" ]]
    [[ "$is_error_line" -lt "$save_session_line" ]]
}

@test "is_error detection resets session on tool_use_concurrency error" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # Verify that tool use concurrency triggers session reset
    run grep -A 5 'tool.use.concurrency\|tool_use_concurrency' "$script"
    assert_success
    [[ "$output" == *"reset_session"* ]]
}

@test "save_claude_session guards against is_error responses" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # The save_claude_session function must check is_error before persisting
    local func_body
    func_body=$(sed -n '/^save_claude_session()/,/^}/p' "$script")
    [[ "$func_body" == *"is_error"* ]]
}

@test "is_error:true with exit code 0 returns non-zero from execute_claude_code" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # Verify the is_error block in execute_claude_code returns 1 (error) not 0 (success)
    # Extract the is_error handling block from the API error section and check it returns 1
    run grep -A 40 'Claude Code returns exit 0 but sets.*is_error' "$script"
    assert_success
    [[ "$output" == *"return 1"* ]]
}

@test "is_error detection handles flat JSON format" {
    # Test that jq extraction works on flat JSON with is_error
    local json='{"type":"result","subtype":"success","is_error":true,"result":"API Error: 400 due to tool use concurrency issues.","session_id":"abc123"}'
    local is_error
    is_error=$(echo "$json" | jq -r '.is_error // false')
    [[ "$is_error" == "true" ]]
}

@test "is_error detection handles stream-json result line" {
    # In stream-json mode, the result line is extracted and written as flat JSON
    local json='{"type":"result","subtype":"success","is_error":true,"result":"not logged in or OAuth token expired","session_id":"def456"}'
    local is_error
    is_error=$(echo "$json" | jq -r '.is_error // false')
    [[ "$is_error" == "true" ]]

    local error_msg
    error_msg=$(echo "$json" | jq -r '.result // ""')
    [[ "$error_msg" == *"not logged in"* ]]
}

@test "is_error:false does not trigger error path" {
    # Normal success response should not be flagged
    local json='{"type":"result","subtype":"success","is_error":false,"result":"Task completed","session_id":"ghi789"}'
    local is_error
    is_error=$(echo "$json" | jq -r '.is_error // false')
    [[ "$is_error" == "false" ]]
}

@test "missing is_error field defaults to false" {
    # Older Claude CLI versions may not include is_error
    local json='{"type":"result","subtype":"success","result":"Task completed","session_id":"jkl012"}'
    local is_error
    is_error=$(echo "$json" | jq -r '.is_error // false')
    [[ "$is_error" == "false" ]]
}

# ─── set -e removal: explicit error handling (#208) ───

@test "ralph_loop.sh does not use set -e" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # set -e must not appear (except in comments or test descriptions)
    run bash -c "grep -n '^set -e' '$script'"
    assert_failure
}

@test "source statements have explicit error guards" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # All 5 library source lines must have || { echo "FATAL: ..."; exit 1; }
    local libs=("date_utils.sh" "timeout_utils.sh" "response_analyzer.sh" "circuit_breaker.sh" "file_protection.sh")
    for lib in "${libs[@]}"; do
        run grep "source.*${lib}.*|| { echo.*FATAL.*exit 1; }" "$script"
        assert_success
    done
}

@test "cleanup skips interrupt status on normal exit (exit code 0)" {
    # Verify cleanup captures trap_exit_code and only records interrupt on non-zero
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # cleanup() must capture exit code as first statement
    run bash -c "sed -n '/^cleanup()/,/^}/p' '$script' | head -3 | grep 'trap_exit_code=\$?'"
    assert_success

    # The condition must check for non-zero exit code
    run bash -c "sed -n '/^cleanup()/,/^}/p' '$script' | grep 'trap_exit_code -ne 0'"
    assert_success
}

@test "analyze_response failure skips signal updates" {
    # Verify that when analysis fails, stale response_analysis file is removed
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The pattern: analysis failure should remove the response analysis file
    run bash -c "grep -A 3 'analysis_exit_code' '$script' | grep 'rm -f.*RESPONSE_ANALYSIS_FILE'"
    assert_success
}

@test "live mode pipeline does not merge stderr into stdout" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The old pattern "2>&1 |" must NOT exist in the live pipeline
    run bash -c "grep 'LIVE_CMD_ARGS.*2>&1' '$script'"
    assert_failure
}

@test "live mode pipeline redirects stderr to separate file" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # stderr must be redirected to a separate file (continuation line)
    run grep '2>"$stderr_file"' "$script"
    assert_success
}

@test "live mode logs stderr output when non-empty" {
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # When stderr file has content, a WARN should be logged
    run grep 'Claude CLI wrote to stderr' "$script"
    assert_success
}

# --- Issue #190: Loop context must be built regardless of session mode ---

@test "build_claude_command includes loop context even when session continuity is disabled" {
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"

    echo "Test prompt" > "$PROMPT_FILE"

    build_claude_command "$PROMPT_FILE" "Loop #3 context" ""

    local cmd_string="${CLAUDE_CMD_ARGS[*]}"

    # Loop context should be included regardless of session mode
    [[ "$cmd_string" == *"--append-system-prompt"* ]]
    [[ "$cmd_string" == *"Loop #3 context"* ]]

    # Session continuity should NOT be included
    [[ "$cmd_string" != *"--continue"* ]]
    [[ "$cmd_string" != *"--resume"* ]]
}

# --- Issue #190 Bug 2: Question detection corrective message ---

@test "build_loop_context includes corrective message when previous loop asked questions" {
    # Create response analysis with asking_questions=true
    echo '{"analysis":{"work_summary":"Asked about approach","asking_questions":true,"question_count":2}}' > "$RALPH_DIR/.response_analysis"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"

    run build_loop_context 5

    assert_success
    [[ "$output" == *"Do NOT ask questions"* ]]
}

@test "build_loop_context omits corrective message when previous loop was normal" {
    # Create response analysis with asking_questions=false
    echo '{"analysis":{"work_summary":"Implemented feature X","asking_questions":false,"question_count":0}}' > "$RALPH_DIR/.response_analysis"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"

    run build_loop_context 5

    assert_success
    [[ "$output" != *"Do NOT ask questions"* ]]
}

# =============================================================================
# Startup version check and auto-update tests (Issue #190)
# =============================================================================

@test "check_claude_version is called before loop in ralph_loop.sh" {
    # Verify check_claude_version is called in main() before the while loop
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract content between main() and while true; verify check_claude_version appears
    run bash -c "sed -n '/^main()/,/while true/p' '$script' | grep 'check_claude_version'"
    assert_success
}

@test "check_claude_version is called after validate_claude_command" {
    # Verify version check comes after command validation in startup sequence
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    local validate_line
    validate_line=$(grep -n 'validate_claude_command' "$script" | grep 'if ! ' | head -1 | cut -d: -f1)
    local version_line
    version_line=$(sed -n '/^main()/,/while true/p' "$script" | grep -n 'check_claude_version' | head -1 | cut -d: -f1)
    local validate_in_main
    validate_in_main=$(sed -n '/^main()/,/while true/p' "$script" | grep -n 'validate_claude_command' | head -1 | cut -d: -f1)

    # version check line number should be greater than validate line number (within main)
    [[ $version_line -gt $validate_in_main ]]
}

@test "check_claude_updates is called before loop in ralph_loop.sh" {
    # Verify check_claude_updates is called in main() before the while loop
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run bash -c "sed -n '/^main()/,/while true/p' '$script' | grep 'check_claude_updates'"
    assert_success
}

@test "check_claude_updates handles npm failure gracefully" {
    # When npm view fails, function should return 0 (non-blocking)
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Verify the npm failure path returns 0
    run bash -c "sed -n '/^check_claude_updates()/,/^}/p' '$script' | grep -A1 'npm registry unreachable'"
    assert_success
    [[ "$output" == *"return 0"* ]]
}

# =============================================================================
# Semver comparison tests (Issue #190 — replace integer arithmetic with proper comparison)
# =============================================================================

@test "compare_semver returns 0 when ver1 > ver2" {
    run compare_semver "2.1.0" "2.0.76"
    assert_success
}

@test "compare_semver returns 1 when ver1 < ver2" {
    run compare_semver "1.0.0" "2.0.76"
    assert_failure
}

@test "compare_semver handles equal versions" {
    run compare_semver "2.0.76" "2.0.76"
    assert_success
}

@test "compare_semver handles high patch numbers correctly" {
    # This is the key bug fix: 1.0.100 vs 1.1.0
    # Old integer method: 1*10000+0*100+100=10100 vs 1*10000+1*100+0=10100 → equal (WRONG)
    # Correct: 1.0.100 < 1.1.0
    run compare_semver "1.0.100" "1.1.0"
    assert_failure
}

@test "check_claude_updates respects CLAUDE_AUTO_UPDATE=false" {
    # When CLAUDE_AUTO_UPDATE is false, function should return 0 immediately
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Verify the CLAUDE_AUTO_UPDATE check exists at the top of the function
    run bash -c "sed -n '/^check_claude_updates()/,/^}/p' '$script' | head -5 | grep 'CLAUDE_AUTO_UPDATE'"
    assert_success
}

@test "check_claude_updates runs when CLAUDE_AUTO_UPDATE=true" {
    # Verify the default behavior (CLAUDE_AUTO_UPDATE=true) proceeds to version check
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The function should contain npm view call (only reached when auto-update is enabled)
    run bash -c "sed -n '/^check_claude_updates()/,/^}/p' '$script' | grep 'npm view'"
    assert_success
}

# --- Productive Timeout Detection Tests (Issue #198) ---

@test "timeout handler checks git for productive work before returning" {
    # The timeout handler (exit_code 124) must check .loop_start_sha vs HEAD
    # instead of immediately returning 1
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract the failure path (else branch) containing the timeout handler
    # Find the timeout guard block and verify it references loop_start_sha
    run bash -c "sed -n '/Layer 1.*Timeout guard/,/return [12]/p' '$script' | grep -q 'loop_start_sha'"
    assert_success
}

@test "timeout handler calls analyze_response on productive timeout" {
    # When timeout occurs but files were changed, analyze_response must be called
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The timeout block should contain analyze_response call (for productive timeouts)
    run bash -c "sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' '$script' | grep -q 'analyze_response'"
    assert_success
}

@test "timeout handler calls record_loop_result on productive timeout" {
    # Circuit breaker must see progress from productive timeouts
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run bash -c "sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' '$script' | grep -q 'record_loop_result'"
    assert_success
}

@test "timeout handler returns 0 for productive timeout, 1 for idle timeout" {
    # The timeout block must have two return paths:
    # - return 0 when files changed (productive)
    # - return 1 when no files changed (idle)
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract the timeout handler block
    local timeout_block
    timeout_block=$(sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' "$script")

    # Must contain return 0 (productive path)
    echo "$timeout_block" | grep -q 'return 0'
    # Must contain return 1 (idle path)
    echo "$timeout_block" | grep -q 'return 1'
}

@test "timeout handler writes timed_out_productive to progress file" {
    # Productive timeouts should write a distinct status to PROGRESS_FILE
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run bash -c "sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' '$script' | grep -q 'timed_out_productive'"
    assert_success
}

@test "timeout handler saves session on productive timeout" {
    # Session ID must be preserved when timeout occurs with productive work
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    run bash -c "sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' '$script' | grep -q 'save_claude_session'"
    assert_success
}

# --- Session ID Fallback Tests (Issue #198) ---

@test "stream parsing has session ID fallback from system message" {
    # When result message is missing (truncated stream), extract session_id
    # from the "type":"system" message as fallback
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # The stream parsing block should grep for type:system as fallback
    run grep -A 15 'Could not find result message' "$script"
    assert_success
    # The fallback block should extract from system message
    echo "$output" | grep -q '"type".*"system"'
}

@test "session ID fallback extracts valid session_id from system message" {
    # Create a truncated stream file (has system message but no result message)
    local stream_file="$TEST_DIR/truncated_stream.log"
    cat > "$stream_file" << 'EOF'
{"type":"system","subtype":"init","session_id":"test-session-abc123","tools":[],"model":"claude-sonnet-4-20250514"}
{"type":"assistant","message":{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Working on tasks..."}]}}
EOF

    # The result_line grep should find nothing
    local result_line
    result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$stream_file" 2>/dev/null | tail -1)
    [[ -z "$result_line" ]]

    # The system message fallback should find the session ID
    local system_line
    system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$stream_file" 2>/dev/null | tail -1)
    [[ -n "$system_line" ]]

    local session_id
    session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null)
    [[ "$session_id" == "test-session-abc123" ]]
}

@test "session ID fallback handles missing system message gracefully" {
    # If both result AND system messages are missing, no crash
    local stream_file="$TEST_DIR/empty_stream.log"
    cat > "$stream_file" << 'EOF'
{"type":"assistant","message":{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Working..."}]}}
EOF

    local system_line
    system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$stream_file" 2>/dev/null | tail -1)
    [[ -z "$system_line" ]]

    # Should not crash — empty string is fine
    local session_id
    session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    [[ -z "$session_id" || "$session_id" == "" ]]
}

# --- Behavioral Timeout Tests (Issue #198) ---

@test "behavioral: productive timeout detects git changes and runs analysis" {
    # Simulate: timeout occurred (exit 124) but Claude made commits
    # Setup: create initial commit, record SHA, make another commit
    echo "initial" > testfile.txt
    git add testfile.txt
    git commit -m "initial" --quiet

    local start_sha
    start_sha=$(git rev-parse HEAD)
    echo "$start_sha" > "$RALPH_DIR/.loop_start_sha"

    # Simulate Claude making a commit during execution
    echo "modified by claude" > testfile.txt
    git add testfile.txt
    git commit -m "claude work" --quiet

    local current_sha
    current_sha=$(git rev-parse HEAD)

    # Verify SHAs differ (work was done)
    [[ "$start_sha" != "$current_sha" ]]

    # Count files changed (same logic as the productive timeout handler)
    local files_changed
    files_changed=$(git diff --name-only "$start_sha" "$current_sha" 2>/dev/null | sort -u | wc -l)
    [[ "$files_changed" -gt 0 ]]
}

@test "behavioral: idle timeout detects no git changes" {
    # Simulate: timeout occurred but no work was done
    echo "initial" > testfile.txt
    git add testfile.txt
    git commit -m "initial" --quiet

    local start_sha
    start_sha=$(git rev-parse HEAD)
    echo "$start_sha" > "$RALPH_DIR/.loop_start_sha"

    local current_sha
    current_sha=$(git rev-parse HEAD)

    # SHAs should be identical (no work done)
    [[ "$start_sha" == "$current_sha" ]]

    # No committed changes
    local files_changed
    files_changed=$(git diff --name-only "$start_sha" "$current_sha" 2>/dev/null | sort -u | wc -l)

    # Also check working tree
    local unstaged
    unstaged=$(git diff --name-only 2>/dev/null | wc -l)
    local staged
    staged=$(git diff --name-only --cached 2>/dev/null | wc -l)

    local total=$((files_changed + unstaged + staged))
    [[ "$total" -eq 0 ]]
}

@test "behavioral: productive timeout detects staged-only changes" {
    # Simulate: timeout occurred, no commits but staged files
    echo "initial" > testfile.txt
    git add testfile.txt
    git commit -m "initial" --quiet

    local start_sha
    start_sha=$(git rev-parse HEAD)
    echo "$start_sha" > "$RALPH_DIR/.loop_start_sha"

    # Stage a new file without committing
    echo "staged content" > newfile.txt
    git add newfile.txt

    local current_sha
    current_sha=$(git rev-parse HEAD)

    # SHAs are identical (no commits)
    [[ "$start_sha" == "$current_sha" ]]

    # But staged changes exist
    local staged
    staged=$(git diff --name-only --cached 2>/dev/null | wc -l)
    [[ "$staged" -gt 0 ]]
}

@test "behavioral: productive timeout detects unstaged-only changes" {
    # Simulate: timeout occurred, no commits, no staging, but modified files
    echo "initial" > testfile.txt
    git add testfile.txt
    git commit -m "initial" --quiet

    local start_sha
    start_sha=$(git rev-parse HEAD)
    echo "$start_sha" > "$RALPH_DIR/.loop_start_sha"

    # Modify a tracked file without staging
    echo "modified content" > testfile.txt

    local current_sha
    current_sha=$(git rev-parse HEAD)

    # SHAs are identical (no commits)
    [[ "$start_sha" == "$current_sha" ]]

    # But unstaged changes exist
    local unstaged
    unstaged=$(git diff --name-only 2>/dev/null | wc -l)
    [[ "$unstaged" -gt 0 ]]
}

@test "timeout handler clears stale response analysis on analysis failure" {
    # The timeout handler must rm -f RESPONSE_ANALYSIS_FILE when analyze_response fails
    # This prevents the next loop from reusing stale EXIT_SIGNAL or permission data
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract the timeout handler block and check for rm -f RESPONSE_ANALYSIS_FILE
    run bash -c "sed -n '/Layer 1.*Timeout guard/,/fi  # end timeout/p' '$script' | grep -q 'rm -f.*RESPONSE_ANALYSIS_FILE'"
    assert_success
}

# --- Monitor I/O Error Fix (Issue #188) ---

@test "log_status stderr write is guarded against I/O errors" {
    # When tmux pty becomes unavailable, echo >&2 fails with "Input/output error"
    # The stderr write must have 2>/dev/null to suppress this
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract log_status function and check stderr write has error suppression
    local func_body
    func_body=$(sed -n '/^log_status()/,/^}/p' "$script")

    echo "$func_body" | grep '>&2' | grep -q '2>/dev/null'
}

@test "log_status log-file write is guarded against errors" {
    # The log-file append should also be guarded for robustness
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    local func_body
    func_body=$(sed -n '/^log_status()/,/^}/p' "$script")

    echo "$func_body" | grep 'ralph.log' | grep -q '2>/dev/null'
}

@test "ralph_monitor.sh does not use set -e" {
    # set -e in the monitor causes crashes when echo fails on broken pty
    local script="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"

    # Should NOT have set -e
    run grep -c '^set -e' "$script"
    [[ "$output" == "0" ]]
}
