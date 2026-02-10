#!/bin/bash
# Claude Provider for Ralph
# Implements the Claude Code CLI integration

# Provider-specific configuration
CLAUDE_CODE_CMD="claude"
CLAUDE_MIN_VERSION="2.0.76"

# Load Claude-specific logic
provider_init() {
    check_claude_version
}

# Check Claude CLI version for compatibility with modern flags
check_claude_version() {
    local version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
        return 0
    fi

    # Compare versions (simplified semver comparison)
    local required="$CLAUDE_MIN_VERSION"

    # Convert to comparable integers (major * 10000 + minor * 100 + patch)
    local ver_parts=(${version//./ })
    local req_parts=(${required//./ })

    local ver_num=$((${ver_parts[0]:-0} * 10000 + ${ver_parts[1]:-0} * 100 + ${ver_parts[2]:-0}))
    local req_num=$((${req_parts[0]:-0} * 10000 + ${req_parts[1]:-0} * 100 + ${req_parts[2]:-0}))

    if [[ $ver_num -lt $req_num ]]; then
        log_status "WARN" "Claude CLI version $version < $required. Some modern features may not work."
        log_status "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
        return 1
    fi

    log_status "INFO" "Claude CLI version $version (>= $required) - modern features enabled"
    return 0
}

# Validate allowed tools against whitelist
validate_allowed_tools() {
    local tools_input=$1
    local VALID_TOOL_PATTERNS=(
        "Write" "Read" "Edit" "MultiEdit" "Glob" "Grep" "Task" "TodoWrite"
        "WebFetch" "WebSearch" "Bash" "Bash(git *)" "Bash(npm *)"
        "Bash(bats *)" "Bash(python *)" "Bash(node *)" "NotebookEdit"
    )

    if [[ -z "$tools_input" ]]; then
        return 0
    fi

    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$tool" ]] && continue
        local valid=false
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            # Use glob-style matching for tool against the pattern
            if [[ "$tool" == $pattern ]]; then
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

# Build loop context for Claude Code session
build_loop_context() {
    local loop_count=$1
    local context="Loop #$loop_count. "

    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        context+="Remaining tasks: ${incomplete_tasks:-0}. "
    fi

    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        [[ "$cb_state" != "CLOSED" && -n "$cb_state" && "$cb_state" != "null" ]] && context+="Circuit breaker: $cb_state. "
    fi

    if [[ -f "$RALPH_DIR/.response_analysis" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RALPH_DIR/.response_analysis" 2>/dev/null | head -c 200)
        [[ -n "$prev_summary" && "$prev_summary" != "null" ]] && context+="Previous: $prev_summary"
    fi

    echo "${context:0:500}"
}

# Initialize or resume Claude session
init_claude_session() {
    local session_file="$RALPH_DIR/.claude_session_id"
    if [[ -f "$session_file" ]]; then
        local age_hours=$(get_session_file_age_hours "$session_file")
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Failed to determine session age, starting fresh"
            rm -f "$session_file"
            echo ""
        elif [[ $age_hours -ge ${CLAUDE_SESSION_EXPIRY_HOURS:-24} ]]; then
            log_status "INFO" "Session expired (age: $age_hours hours), starting fresh"
            rm -f "$session_file"
            echo ""
        else
            local session_id=$(cat "$session_file" 2>/dev/null)
            log_status "INFO" "Resuming Claude session: $session_id ($age_hours hours old)"
            echo "$session_id"
        fi
    else
        echo ""
    fi
}

# Execute provider loop
provider_execute() {
    local loop_count=$1
    local prompt_file=$2
    local live_mode=$3
    
    # Implementation follows the logic from execute_claude_code
    execute_claude_code "$loop_count" "$prompt_file" "$live_mode"
}

# Internal helper to execute Claude Code (extracted from ralph_loop.sh)
execute_claude_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    local loop_start_sha=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"

    # Build loop context for session continuity
    local loop_context=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        loop_context=$(build_loop_context "$loop_count")
        if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "INFO" "Loop context: $loop_context"
        fi
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        session_id=$(init_claude_session)
    fi

    # Live mode requires JSON output (stream-json) — use local override instead of global mutation
    local output_format="$CLAUDE_OUTPUT_FORMAT"
    if [[ "$LIVE_OUTPUT" == "true" && "$output_format" == "text" ]]; then
        log_status "WARN" "Live mode requires JSON output format. Using json override for this session."
        output_format="json"
    fi

    # Build the Claude CLI command with modern flags
    local use_modern_cli=false
    if build_claude_command "$PROMPT_FILE" "$loop_context" "$session_id" "$output_format"; then
        use_modern_cli=true
        log_status "INFO" "Using modern CLI mode (${output_format} output)"
    else
        log_status "WARN" "Failed to build modern CLI command, falling back to legacy mode"
        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    # Execute Claude Code
    local exit_code=0
    echo -e "\n\n=== Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # LIVE MODE implementation (same as in ralph_loop.sh)
        if ! command -v jq &> /dev/null || ! command -v stdbuf &> /dev/null; then
            log_status "ERROR" "Live mode dependencies missing. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        log_status "INFO" "📺 Live output mode enabled - showing Claude Code streaming..."
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Claude Code Output ━━━━━━━━━━━━━━━━${NC}"

        local -a LIVE_CMD_ARGS=()
        local skip_next=false
        for arg in "${CLAUDE_CMD_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                LIVE_CMD_ARGS+=("stream-json"); skip_next=false
            elif [[ "$arg" == "--output-format" ]]; then
                LIVE_CMD_ARGS+=("$arg"); skip_next=true
            else
                LIVE_CMD_ARGS+=("$arg")
            fi
        done
        LIVE_CMD_ARGS+=("--verbose" "--include-partial-messages")

        local jq_filter='if .type == "stream_event" then if .event.type == "content_block_delta" and .event.delta.type == "text_delta" then .event.delta.text elif .event.type == "content_block_start" and .event.content_block.type == "tool_use" then "\n\n⚡ [" + .event.content_block.name + "]\n" elif .event.type == "content_block_stop" then "\n" else empty end else empty end'

        set -o pipefail
        portable_timeout ${timeout_seconds}s stdbuf -oL "${LIVE_CMD_ARGS[@]}" < /dev/null 2>&1 | stdbuf -oL tee "$output_file" | stdbuf -oL jq --unbuffered -j "$jq_filter" 2>/dev/null | tee "$LIVE_LOG_FILE"
        local -a pipe_status=("${PIPESTATUS[@]}")
        set +o pipefail
        exit_code=${pipe_status[0]}
        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Output ━━━━━━━━━━━━━━━━━━━${NC}"

        if [[ "$CLAUDE_USE_CONTINUE" == "true" && -f "$output_file" ]]; then
            local stream_output_file="${output_file%.log}_stream.log"
            cp "$output_file" "$stream_output_file"
            local result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)
            if [[ -n "$result_line" ]] && echo "$result_line" | jq -e . >/dev/null 2>&1; then
                echo "$result_line" > "$output_file"
            fi
        fi
    else
        # BACKGROUND MODE
        if [[ "$use_modern_cli" == "true" ]]; then
            portable_timeout ${timeout_seconds}s "${CLAUDE_CMD_ARGS[@]}" < /dev/null > "$output_file" 2>&1 &
        else
            portable_timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 &
        fi
        local claude_pid=$!
        local progress_counter=0
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi
            jq -n \
                --arg status "executing" \
                --argjson elapsed_seconds "$((progress_counter * 10))" \
                --arg last_output "$last_line" \
                --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
                '{status: $status, elapsed_seconds: $elapsed_seconds, last_output: $last_output, timestamp: $timestamp}' > "$PROGRESS_FILE"
            sleep 10
        done
        wait $claude_pid
        exit_code=$?
    fi

    if [ $exit_code -eq 0 ]; then
        echo "$calls_made" > "$CALL_COUNT_FILE"
        jq -n \
            --arg status "completed" \
            --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
            '{status: $status, timestamp: $timestamp}' > "$PROGRESS_FILE"
        log_status "SUCCESS" "✅ Claude Code execution completed successfully"
        [[ "$CLAUDE_USE_CONTINUE" == "true" ]] && save_claude_session "$output_file"
        log_status "INFO" "🔍 Analyzing Claude Code response..."
        analyze_response "$output_file" "$loop_count"
        update_exit_signals
        log_analysis_summary
        
        local files_changed=0
        local current_sha=""
        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                files_changed=$({ git diff --name-only "$loop_start_sha" "$current_sha"; git diff --name-only HEAD; git diff --name-only --cached; } | sort -u | wc -l)
            else
                files_changed=$({ git diff --name-only; git diff --name-only --cached; } | sort -u | wc -l)
            fi
        fi

        local has_errors="false"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"
            log_status "WARN" "Errors detected in output"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        [[ $? -ne 0 ]] && return 3
        return 0
    else
        jq -n \
            --arg status "failed" \
            --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
            '{status: $status, timestamp: $timestamp}' > "$PROGRESS_FILE"
        if grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached" "$output_file"; then
            log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
            return 2
        else
            log_status "ERROR" "❌ Claude Code execution failed"
            return 1
        fi
    fi
}

# Build Claude CLI command with modern flags using array (shell-injection safe)
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local output_format="${4:-$CLAUDE_OUTPUT_FORMAT}"
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")
    [[ ! -f "$prompt_file" ]] && return 1
    [[ "$output_format" == "json" ]] && CLAUDE_CMD_ARGS+=("--output-format" "json")
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | xargs); [[ -n "$tool" ]] && CLAUDE_CMD_ARGS+=("$tool")
        done
    fi
    [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]] && CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    [[ -n "$loop_context" ]] && CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    CLAUDE_CMD_ARGS+=("-p" "$(cat "$prompt_file")")
}

# Save session ID after successful execution
save_claude_session() {
    local output_file=$1
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        [[ -n "$session_id" && "$session_id" != "null" ]] && echo "$session_id" > "$RALPH_DIR/.claude_session_id"
    fi
}

# Helper for session age
get_session_file_age_hours() {
    local file=$1
    [[ ! -f "$file" ]] && echo "-1" && return
    local file_mtime
    if file_mtime=$(stat -c %Y "$file" 2>/dev/null); then :
    elif file_mtime=$(stat -f %m "$file" 2>/dev/null); then :
    else file_mtime=$(date -r "$file" +%s 2>/dev/null); fi
    [[ -z "$file_mtime" || "$file_mtime" == "0" ]] && echo "-1" && return
    echo "$(( ($(date +%s) - file_mtime) / 3600 ))"
}
