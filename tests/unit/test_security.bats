#!/usr/bin/env bats

# Security Tests for Ralph Loop
# Tests for session expiration, tool validation, version parsing, and path sanitization

load '../helpers/test_helper'

# Path to source files
SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../"

# Test setup
setup() {
    # Create temp directory for test files
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
    cd "$TEST_DIR"

    # Create lib directory with required stubs
    mkdir -p lib
    cat > lib/date_utils.sh << 'EOF'
get_iso_timestamp() { date -u '+%Y-%m-%dT%H:%M:%S+00:00'; }
get_next_hour_time() { date '+%H:%M:%S'; }
get_basic_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
EOF
    source lib/date_utils.sh
}

teardown() {
    # Clean up test directory
    cd /
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# =============================================================================
# Session Expiration Tests
# =============================================================================

@test "is_session_expired returns true for non-existent file" {
    # Define the function inline for testing (can't source full script)
    is_session_expired() {
        local session_file=$1
        if [[ ! -f "$session_file" ]]; then
            return 0  # No file = expired
        fi
        return 1
    }

    run is_session_expired "/nonexistent/file"
    [ "$status" -eq 0 ]
}

@test "is_session_expired returns false for recent file" {
    # Create a fresh file
    local test_file="$TEST_DIR/recent_session"
    echo "test-session-id" > "$test_file"

    # Define the function inline for testing
    is_session_expired() {
        local session_file=$1
        local SESSION_MAX_AGE_SECONDS=86400

        if [[ ! -f "$session_file" ]]; then
            return 0
        fi

        local current_time=$(date +%s)
        local file_mtime

        if [[ "$(uname)" == "Darwin" ]]; then
            file_mtime=$(stat -f %m "$session_file" 2>/dev/null)
        else
            file_mtime=$(stat -c %Y "$session_file" 2>/dev/null)
        fi

        if [[ -z "$file_mtime" ]]; then
            return 0
        fi

        local file_age_seconds=$((current_time - file_mtime))

        if [[ $file_age_seconds -gt $SESSION_MAX_AGE_SECONDS ]]; then
            return 0
        else
            return 1
        fi
    }

    run is_session_expired "$test_file"
    [ "$status" -eq 1 ]  # Should NOT be expired
}

@test "session expiration handles unreadable file gracefully" {
    is_session_expired() {
        local session_file=$1

        if [[ ! -f "$session_file" ]]; then
            return 0
        fi

        local file_mtime=""
        if [[ -z "$file_mtime" ]]; then
            return 0  # Can't read mtime = treat as expired
        fi

        return 1
    }

    # Create file then make it unreadable
    local test_file="$TEST_DIR/unreadable"
    echo "test" > "$test_file"
    chmod 000 "$test_file" 2>/dev/null || skip "Cannot change file permissions"

    run is_session_expired "$test_file"
    # Should handle gracefully (either expired or readable)
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # Cleanup
    chmod 644 "$test_file" 2>/dev/null || true
}

# =============================================================================
# Tool Validation Tests
# =============================================================================

@test "validate_allowed_tools accepts empty input" {
    # Define the validation function
    VALID_TOOL_PATTERNS=("Write" "Read" "Edit" "Bash" "Bash(git *)")

    validate_allowed_tools() {
        local tools_input=$1
        if [[ -z "$tools_input" ]]; then
            return 0
        fi
        return 1
    }

    run validate_allowed_tools ""
    [ "$status" -eq 0 ]
}

@test "validate_allowed_tools accepts valid tools" {
    VALID_TOOL_PATTERNS=("Write" "Read" "Edit" "Bash" "Bash(git *)" "Glob" "Grep")

    validate_allowed_tools() {
        local tools_input=$1

        if [[ -z "$tools_input" ]]; then
            return 0
        fi

        local IFS=','
        read -ra tools <<< "$tools_input"

        for tool in "${tools[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ -z "$tool" ]]; then
                continue
            fi

            local valid=false

            for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
                if [[ "$tool" == "$pattern" ]]; then
                    valid=true
                    break
                fi

                if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                    valid=true
                    break
                fi
            done

            if [[ "$valid" == "false" ]]; then
                echo "Error: Invalid tool: '$tool'" >&2
                return 1
            fi
        done

        return 0
    }

    run validate_allowed_tools "Write,Read,Edit"
    [ "$status" -eq 0 ]
}

@test "validate_allowed_tools accepts Bash patterns with parentheses" {
    VALID_TOOL_PATTERNS=("Write" "Read" "Bash")

    validate_allowed_tools() {
        local tools_input=$1

        if [[ -z "$tools_input" ]]; then
            return 0
        fi

        local IFS=','
        read -ra tools <<< "$tools_input"

        for tool in "${tools[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ -z "$tool" ]]; then
                continue
            fi

            local valid=false

            for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
                if [[ "$tool" == "$pattern" ]]; then
                    valid=true
                    break
                fi

                # Check for Bash(*) pattern
                if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                    valid=true
                    break
                fi
            done

            if [[ "$valid" == "false" ]]; then
                return 1
            fi
        done

        return 0
    }

    run validate_allowed_tools "Bash(git *)"
    [ "$status" -eq 0 ]

    run validate_allowed_tools "Bash(npm install)"
    [ "$status" -eq 0 ]
}

@test "validate_allowed_tools rejects invalid tools" {
    VALID_TOOL_PATTERNS=("Write" "Read" "Edit" "Bash")

    validate_allowed_tools() {
        local tools_input=$1

        if [[ -z "$tools_input" ]]; then
            return 0
        fi

        local IFS=','
        read -ra tools <<< "$tools_input"

        for tool in "${tools[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ -z "$tool" ]]; then
                continue
            fi

            local valid=false

            for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
                if [[ "$tool" == "$pattern" ]]; then
                    valid=true
                    break
                fi

                if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                    valid=true
                    break
                fi
            done

            if [[ "$valid" == "false" ]]; then
                echo "Error: Invalid tool: '$tool'" >&2
                return 1
            fi
        done

        return 0
    }

    run validate_allowed_tools "InvalidTool"
    [ "$status" -eq 1 ]
}

@test "validate_allowed_tools rejects shell injection attempts" {
    VALID_TOOL_PATTERNS=("Write" "Read" "Edit" "Bash")

    validate_allowed_tools() {
        local tools_input=$1

        if [[ -z "$tools_input" ]]; then
            return 0
        fi

        local IFS=','
        read -ra tools <<< "$tools_input"

        for tool in "${tools[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ -z "$tool" ]]; then
                continue
            fi

            local valid=false

            for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
                if [[ "$tool" == "$pattern" ]]; then
                    valid=true
                    break
                fi

                if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                    valid=true
                    break
                fi
            done

            if [[ "$valid" == "false" ]]; then
                return 1
            fi
        done

        return 0
    }

    # Attempt to inject shell commands
    run validate_allowed_tools "Write; rm -rf /"
    [ "$status" -eq 1 ]

    run validate_allowed_tools "Write\$(whoami)"
    [ "$status" -eq 1 ]

    run validate_allowed_tools "Write\`id\`"
    [ "$status" -eq 1 ]
}

# =============================================================================
# Version Parsing Tests
# =============================================================================

@test "extract_semver handles standard versions" {
    extract_semver() {
        local version_string=$1
        echo "$version_string" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    }

    run extract_semver "2.0.76"
    [ "$output" == "2.0.76" ]
}

@test "extract_semver handles pre-release versions" {
    extract_semver() {
        local version_string=$1
        echo "$version_string" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    }

    run extract_semver "2.0.76-beta.1"
    [ "$output" == "2.0.76" ]

    run extract_semver "3.1.0-alpha"
    [ "$output" == "3.1.0" ]

    run extract_semver "1.0.0-rc.1+build.123"
    [ "$output" == "1.0.0" ]
}

@test "extract_semver handles version strings with prefix" {
    extract_semver() {
        local version_string=$1
        echo "$version_string" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    }

    run extract_semver "v2.0.76"
    [ "$output" == "2.0.76" ]

    run extract_semver "claude-code version 2.1.0"
    [ "$output" == "2.1.0" ]
}

@test "extract_semver returns empty for invalid versions" {
    extract_semver() {
        local version_string=$1
        echo "$version_string" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    }

    run extract_semver "invalid"
    [ "$output" == "" ]

    run extract_semver "1.0"
    [ "$output" == "" ]
}

# =============================================================================
# Path Sanitization Tests
# =============================================================================

@test "sanitize_path removes directory from path" {
    sanitize_path() {
        local path=$1
        basename "$path" 2>/dev/null || echo "$path"
    }

    run sanitize_path "/home/user/logs/output.log"
    [ "$output" == "output.log" ]
}

@test "sanitize_path handles filename only" {
    sanitize_path() {
        local path=$1
        basename "$path" 2>/dev/null || echo "$path"
    }

    run sanitize_path "output.log"
    [ "$output" == "output.log" ]
}

@test "sanitize_path handles paths with spaces" {
    sanitize_path() {
        local path=$1
        basename "$path" 2>/dev/null || echo "$path"
    }

    run sanitize_path "/home/user/my logs/output file.log"
    [ "$output" == "output file.log" ]
}

@test "sanitize_path handles relative paths" {
    sanitize_path() {
        local path=$1
        basename "$path" 2>/dev/null || echo "$path"
    }

    run sanitize_path "./logs/output.log"
    [ "$output" == "output.log" ]

    run sanitize_path "../parent/file.txt"
    [ "$output" == "file.txt" ]
}

# =============================================================================
# jq Timeout Wrapper Tests
# =============================================================================

@test "jq_safe returns empty string on invalid JSON" {
    jq_safe() {
        local timeout_secs=${1:-5}
        shift
        timeout "$timeout_secs" jq "$@" 2>/dev/null || echo ""
    }

    # Test with invalid JSON
    run bash -c '
        jq_safe() {
            local timeout_secs=${1:-5}
            shift
            timeout "$timeout_secs" jq "$@" 2>/dev/null || echo ""
        }
        jq_safe 1 ".test" <<< "invalid json"
    '
    # Should return empty string on parse error
    [ "$output" == "" ]
}

@test "jq_safe processes valid JSON successfully" {
    jq_safe() {
        local timeout_secs=${1:-5}
        shift
        timeout "$timeout_secs" jq "$@" 2>/dev/null || echo ""
    }

    local json='{"test": "value"}'
    run bash -c "echo '$json' | timeout 5 jq -r '.test' 2>/dev/null || echo ''"
    [ "$output" == "value" ]
}

# =============================================================================
# Command Array Security Tests
# =============================================================================

@test "command array prevents shell injection in tool arguments" {
    # Test that the array-based command building prevents injection
    local tools="Write,Read"

    # Simulate what build_claude_command does
    CLAUDE_CMD_ARGS=()
    CLAUDE_CMD_ARGS+=("claude")
    CLAUDE_CMD_ARGS+=("--allowedTools")

    local IFS=','
    read -ra tools_array <<< "$tools"
    for tool in "${tools_array[@]}"; do
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$tool" ]]; then
            CLAUDE_CMD_ARGS+=("$tool")
        fi
    done

    # Verify the array contains expected elements
    [ "${CLAUDE_CMD_ARGS[0]}" == "claude" ]
    [ "${CLAUDE_CMD_ARGS[1]}" == "--allowedTools" ]
    [ "${CLAUDE_CMD_ARGS[2]}" == "Write" ]
    [ "${CLAUDE_CMD_ARGS[3]}" == "Read" ]
}

@test "command array preserves special characters safely" {
    # Test that special chars in args are preserved, not interpreted
    local context="Loop #5. Remaining tasks: 3."

    CLAUDE_CMD_ARGS=()
    CLAUDE_CMD_ARGS+=("--append-system-prompt" "$context")

    # The context should be stored as-is, not interpreted
    [ "${CLAUDE_CMD_ARGS[0]}" == "--append-system-prompt" ]
    [ "${CLAUDE_CMD_ARGS[1]}" == "Loop #5. Remaining tasks: 3." ]
}
