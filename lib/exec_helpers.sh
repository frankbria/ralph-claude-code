#!/usr/bin/env bash
# lib/exec_helpers.sh — runner helpers extracted from execute_claude_code (TAP-1473).
#
# Three functions live here:
#   - exec_build_live_argv  — pure transform: CLAUDE_CMD_ARGS → LIVE_CMD_ARGS
#   - exec_run_live         — foreground/live-mode runner (NDJSON pipeline)
#   - exec_run_background   — background runner with progress-spinner monitoring
#
# Globals consumed (set by the caller in ralph_loop.sh):
#   CLAUDE_CMD_ARGS, CLAUDE_CODE_CMD, CLAUDE_USE_CONTINUE, CLAUDE_SESSION_FILE,
#   CLAUDE_TIMEOUT_MINUTES, LIVE_LOG_FILE, LOG_DIR, PROGRESS_FILE, PROMPT_FILE,
#   PURPLE, NC, RED, YELLOW, SCRIPT_DIR, VERBOSE_PROGRESS
#
# Globals set:
#   LIVE_CMD_ARGS, LAST_TOOL_COUNT, RALPH_PIPELINE_PID
#
# Functions used (defined in ralph_loop.sh, available because this file is sourced):
#   log_status, portable_timeout, ralph_cleanup_orphaned_mcp
#
# Return codes:
#   exec_run_live, exec_run_background — Claude CLI exit code (0..127)
#   exec_run_background — 99 means "failed to launch before monitoring started"
#                         (caller in execute_claude_code should `return 1`)

# exec_build_live_argv — Pure transform.
#
# Reads global CLAUDE_CMD_ARGS, populates global LIVE_CMD_ARGS:
#   - rewrites the value following `--output-format` from "json" → "stream-json"
#   - appends `--verbose --include-partial-messages` (required for stream-json)
#   - preserves all other flags verbatim and in order
#
# Behavior is fully deterministic — same input produces the same output. This
# is the only nontrivial pure transformation in the runners; it gets unit-test
# coverage in tests/unit/test_exec_build_live_argv.bats.
exec_build_live_argv() {
    LIVE_CMD_ARGS=()
    local skip_next=false
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        if [[ "$skip_next" == "true" ]]; then
            LIVE_CMD_ARGS+=("stream-json")
            skip_next=false
        elif [[ "$arg" == "--output-format" ]]; then
            LIVE_CMD_ARGS+=("$arg")
            skip_next=true
        else
            LIVE_CMD_ARGS+=("$arg")
        fi
    done
    LIVE_CMD_ARGS+=("--verbose" "--include-partial-messages")
}

# exec_run_live — Foreground live-mode runner.
#
# Args:
#   $1 timeout_seconds   — wall-clock cap for the Claude CLI invocation
#   $2 output_file       — path receiving the full NDJSON stream (tee target)
#   $3 adaptive_timeout  — minutes, used in the "timed out" WARN message
#                          (defaults to CLAUDE_TIMEOUT_MINUTES)
#
# Pipeline shape:
#   portable_timeout claude … | tee output_file | awk -f stream_filter.awk | tee LIVE_LOG_FILE
#
# Post-pipeline housekeeping: pipe-status logging, stderr file cleanup,
# tool/agent/error stats, session-id extraction with WSL2/9P retry. Returns
# the Claude CLI exit code (pipe_status[0]).
exec_run_live() {
    local timeout_seconds=$1
    local output_file=$2
    local adaptive_timeout=${3:-${CLAUDE_TIMEOUT_MINUTES:-15}}
    local exit_code=0

    log_status "INFO" "📺 Live output mode enabled - showing Claude Code streaming..."
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Claude Code Output ━━━━━━━━━━━━━━━━${NC}"

    exec_build_live_argv

    local start_epoch
    start_epoch=$(date +%s)

    # Execute with streaming, preserving all flags from build_claude_command().
    # Use stdbuf to disable buffering for real-time output. portable_timeout
    # provides consistent timeout protection. stdin is redirected from
    # /dev/null because newer Claude CLI versions read stdin even in -p mode
    # and would hang otherwise. Stderr is redirected to a separate file so
    # Node.js warnings (e.g. UNDICI) do not corrupt the stream parser
    # pipeline (Issue #190).
    local stderr_file="${LOG_DIR}/claude_stderr_$(date '+%Y%m%d_%H%M%S').log"
    portable_timeout ${timeout_seconds}s stdbuf -oL "${LIVE_CMD_ARGS[@]}" \
        < /dev/null 2>"$stderr_file" | stdbuf -oL tee "$output_file" | stdbuf -oL awk -v st="$start_epoch" -v tc=0 -v ac=0 -v ec=0 -v it=0 -v ct="" -v ti="" -f "$SCRIPT_DIR/lib/stream_filter.awk" 2>/dev/null | tee "$LIVE_LOG_FILE"

    local -a pipe_status=("${PIPESTATUS[@]}")

    # MCP-CLEANUP: kill orphaned MCP server processes after pipeline completes.
    ralph_cleanup_orphaned_mcp

    # Primary exit code is from Claude/timeout (first command in pipeline).
    exit_code=${pipe_status[0]}

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Claude Code execution timed out after ${adaptive_timeout} minutes"
    fi

    if [[ -s "$stderr_file" ]]; then
        log_status "WARN" "Claude CLI wrote to stderr (see: $stderr_file)"
    else
        rm -f "$stderr_file" 2>/dev/null
    fi

    if [[ ${pipe_status[1]} -ne 0 ]]; then
        log_status "WARN" "Failed to write stream output to log file (exit code ${pipe_status[1]})"
    fi
    if [[ ${pipe_status[2]} -ne 0 ]]; then
        log_status "WARN" "Stream filter had issues parsing some events (exit code ${pipe_status[2]})"
    fi

    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Output ━━━━━━━━━━━━━━━━━━━${NC}"

    # CAPTURE-3: post-execution stats — strip newlines/whitespace to ensure
    # single-line output.
    local _tool_count _agent_count _error_count
    _tool_count=$(grep -c '"type":"tool_use"' "$output_file" 2>/dev/null | tr -d '[:space:]') || _tool_count=0
    _agent_count=$(grep -c '"subtype":"task_started"' "$output_file" 2>/dev/null | tr -d '[:space:]') || _agent_count=0
    _error_count=$(grep -c '"is_error":true' "$output_file" 2>/dev/null | tr -d '[:space:]') || _error_count=0
    # LOGFIX-4: export tool count for fast-trip detection in main loop.
    LAST_TOOL_COUNT=${_tool_count:-0}
    # LOGFIX-5: categorize errors into expected (tool scope) vs system (real failures).
    local _expected_errors=0 _system_errors=0
    if [[ ${_error_count:-0} -gt 0 ]]; then
        _expected_errors=$(grep -B1 '"is_error":true' "$output_file" 2>/dev/null \
            | grep -ciE 'permission|denied|too large|exceeds.*token|exceeds.*limit|outside.*allowed|not allowed' \
            || echo 0)
        _expected_errors=$(echo "$_expected_errors" | tr -d '[:space:]')
        _system_errors=$(( ${_error_count:-0} - ${_expected_errors:-0} ))
        [[ $_system_errors -lt 0 ]] && _system_errors=0
        log_status "WARN" "Execution stats: Tools=${_tool_count:-0} Agents=${_agent_count:-0} Errors=${_error_count:-0} (${_expected_errors} scope, ${_system_errors} system)"
    else
        log_status "INFO" "Execution stats: Tools=${_tool_count:-0} Agents=${_agent_count:-0} Errors=0"
    fi

    # Extract session ID from stream-json output for session continuity.
    # Stream-json format has session_id in the final "result" type message.
    # Keep full stream output in _stream.log; extract session data separately.
    # WSL2/NTFS 9P: metadata for -f can lag; retry with backoff before skipping
    # extraction.
    local _stream_file_visible=false
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        local _wait
        for _wait in 0 0.1 0.2 0.5 1.0; do
            [[ "$_wait" != "0" ]] && sleep "$_wait"
            if [[ -f "$output_file" ]]; then
                _stream_file_visible=true
                break
            fi
        done
        if [[ "$_stream_file_visible" != "true" ]]; then
            log_status "WARN" "Output file not visible after 1.8s wait (WSL2/9P race?): $output_file"
        fi
    fi

    if [[ "$CLAUDE_USE_CONTINUE" == "true" && "$_stream_file_visible" == "true" ]]; then
        # Preserve full stream output for analysis (don't overwrite output_file).
        local stream_output_file="${output_file%.log}_stream.log"
        cp "$output_file" "$stream_output_file"

        # Extract the result message and convert to standard JSON format.
        # Flexible regex matches "type":"result", "type": "result", "type" : "result".
        local result_line
        result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)

        if [[ -n "$result_line" ]]; then
            # Validate that extracted line is valid JSON before using it.
            if echo "$result_line" | jq -e . >/dev/null 2>&1; then
                # Write validated result as the output_file for downstream
                # processing (save_claude_session expects JSON format).
                echo "$result_line" > "$output_file"
                log_status "INFO" "Extracted and validated session data from stream output"
            else
                log_status "WARN" "Extracted result line is not valid JSON, keeping stream output"
                cp "$stream_output_file" "$output_file"
            fi
        else
            log_status "WARN" "Could not find result message in stream output"
            # Fallback: extract session ID from "type":"system" message (Issue #198).
            # The system message is always written first and survives truncation.
            local system_line
            system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | tail -1)
            if [[ -n "$system_line" ]] && echo "$system_line" | jq -e . >/dev/null 2>&1; then
                local fallback_session_id
                fallback_session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null)
                if [[ -n "$fallback_session_id" ]]; then
                    echo "$fallback_session_id" > "$CLAUDE_SESSION_FILE"
                    log_status "INFO" "Extracted session ID from system message (timeout fallback)"
                fi
            fi
        fi
    fi

    return $exit_code
}

# exec_run_background — Background runner with progress-spinner monitoring.
#
# Args:
#   $1 timeout_seconds   — wall-clock cap for the Claude CLI invocation
#   $2 output_file       — path receiving Claude CLI stdout
#   $3 use_modern_cli    — "true" / "false"; falls back to legacy on launch
#                          failure when "true"
#
# Returns:
#   - the Claude CLI exit code on normal completion
#   - 99 if Claude failed to start (caller should `return 1` from
#     execute_claude_code so the post-run analysis is skipped)
exec_run_background() {
    local timeout_seconds=$1
    local output_file=$2
    local use_modern_cli=${3:-true}
    local exit_code=0

    if [[ "$use_modern_cli" == "true" ]]; then
        # CAPTURE-1: line-buffer output to prevent data loss on SIGTERM. stdin
        # is redirected from /dev/null because newer Claude CLI versions read
        # stdin even in -p (print) mode, which would cause SIGTTIN suspension
        # when backgrounded.
        local _stdbuf_prefix=""
        if command -v stdbuf &>/dev/null; then
            _stdbuf_prefix="stdbuf -oL"
        fi
        # portable_timeout is a shell function, so it must be the first word
        # of the command line — `stdbuf` cannot exec it. Invert the order:
        # portable_timeout runs the `timeout` binary, which can then exec
        # stdbuf, which execs the final Claude command.
        if portable_timeout ${timeout_seconds}s $_stdbuf_prefix "${CLAUDE_CMD_ARGS[@]}" < /dev/null > "$output_file" 2>&1 &
        then
            :  # Continue to wait loop
        else
            log_status "ERROR" "❌ Failed to start Claude Code process (modern mode)"
            log_status "INFO" "Falling back to legacy mode..."
            use_modern_cli=false
        fi
    fi

    # Fallback to stdin-pipe invocation if modern CLI flag assembly failed.
    # Note: this path bypasses --agent, so the run uses Claude Code's default
    # permissions (no agent-defined disallowedTools). Last resort only.
    if [[ "$use_modern_cli" == "false" ]]; then
        if portable_timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 &
        then
            :  # Continue to wait loop
        else
            log_status "ERROR" "❌ Failed to start Claude Code process"
            return 99
        fi
    fi

    local claude_pid=$!
    RALPH_PIPELINE_PID=$claude_pid  # WSL-2: track for cleanup handler.
    local progress_counter=0

    # Early failure detection: if the command does not exist or fails
    # immediately, the backgrounded process dies before the monitoring loop
    # starts (Issue #97).
    sleep 1
    if ! kill -0 $claude_pid 2>/dev/null; then
        wait $claude_pid 2>/dev/null
        local early_exit=$?
        local early_output=""
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            early_output=$(tail -5 "$output_file" 2>/dev/null)
        fi
        log_status "ERROR" "❌ Claude Code process exited immediately (exit code: $early_exit)"
        if [[ -n "$early_output" ]]; then
            log_status "ERROR" "Output: $early_output"
        fi
        echo ""
        echo -e "${RED}Claude Code failed to start.${NC}"
        echo ""
        echo -e "${YELLOW}Possible causes:${NC}"
        echo "  - '${CLAUDE_CODE_CMD}' command not found or not executable"
        echo "  - Claude Code CLI not installed"
        echo "  - Authentication or configuration issue"
        echo ""
        echo -e "${YELLOW}To fix:${NC}"
        echo "  1. Verify Claude Code works: ${CLAUDE_CODE_CMD} --version"
        echo "  2. Or set a different command in .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
        echo ""
        return 99
    fi

    local progress_indicator
    while kill -0 $claude_pid 2>/dev/null; do
        progress_counter=$((progress_counter + 1))
        case $((progress_counter % 4)) in
            1) progress_indicator="⠋" ;;
            2) progress_indicator="⠙" ;;
            3) progress_indicator="⠹" ;;
            0) progress_indicator="⠸" ;;
        esac

        local last_line=""
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
            cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
        fi

        cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

        if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
            if [[ -n "$last_line" ]]; then
                log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
            else
                log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
            fi
        fi

        sleep 10
    done

    wait $claude_pid
    exit_code=$?
    return $exit_code
}
