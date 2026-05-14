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

# exec_classify_api_error — Unified is_error:true classifier (TAP-1474).
#
# Reads the output file (stream-json or single-result JSON) and inspects the
# top-level `.is_error` flag. Three branches:
#
#   - Not an is_error (or no output file, or invalid JSON) → return 0;
#     caller continues with the normal exit-code-based flow.
#   - Monthly Anthropic spend cap reached (matches "specified API usage
#     limit" or "regain access on YYYY-MM-DD") → set MONTHLY_CAP_DATE,
#     log error, return 4 → caller should `return 4` from
#     execute_claude_code (terminal until reset date).
#   - Generic is_error (tool-use-concurrency or anything else) → reset the
#     session with a categorized reason, log error, return 1 → caller
#     should `return 1` from execute_claude_code (retry with fresh
#     session).
#
# Runs BEFORE branching on exit_code so the same JSON-level error is handled
# identically whether the CLI exited 0 or non-zero (Issue #134 / #199 — the
# monthly-cap 400s sometimes come back with non-zero exit and would otherwise
# fall through to the generic 30s-retry path and burn calls against an
# immovable wall).
#
# Args:
#   $1 output_file — path to the Claude CLI result JSON
#   $2 exit_code   — Claude CLI exit code (used only in log messages)
#
# Side effects:
#   - PROGRESS_FILE rewritten with `{"status":"failed","error":"is_error:true",...}`
#   - MONTHLY_CAP_DATE set on cap detection (caller-visible global)
#   - reset_session called on the non-cap branch
exec_classify_api_error() {
    local output_file=$1
    local exit_code=$2

    [[ -f "$output_file" ]] || return 0

    local _is_error
    _is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
    [[ "$_is_error" == "true" ]] || return 0

    local _err_msg
    _err_msg=$(jq -r '.result // "unknown API error"' "$output_file" 2>/dev/null || echo "unknown API error")
    echo '{"status": "failed", "error": "is_error:true", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

    # Monthly spend cap (console.anthropic.com → Limits) — terminal until the reset date.
    # Example: "You have reached your specified API usage limits. You will regain access on 2026-05-01 at 00:00 UTC."
    # Retrying every 30s for days/weeks is pointless and noisy; surface the date and halt.
    if echo "$_err_msg" | grep -qiE "specified API usage limit|regain access on"; then
        MONTHLY_CAP_DATE=$(echo "$_err_msg" \
            | grep -oE "regain access on [0-9]{4}-[0-9]{2}-[0-9]{2}" \
            | head -1 \
            | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}")
        log_status "ERROR" "🛑 Monthly Anthropic API spend cap reached (exit_code=$exit_code). Access returns: ${MONTHLY_CAP_DATE:-unknown}"
        log_status "ERROR" "    Raise the cap at console.anthropic.com → Limits, or wait until ${MONTHLY_CAP_DATE:-the reset date}."
        return 4
    fi

    log_status "ERROR" "❌ Claude CLI returned is_error:true (exit_code=$exit_code): $_err_msg"

    # Reset session to prevent infinite retry with a poisoned session ID.
    if echo "$_err_msg" | grep -qi "tool.use.concurrency\|concurrency"; then
        reset_session "tool_use_concurrency_error"
        log_status "WARN" "Session reset due to tool use concurrency error. Retrying with fresh session."
    else
        reset_session "api_error_is_error_true"
        log_status "WARN" "Session reset due to API error (is_error:true). Retrying with fresh session."
    fi
    return 1
}

# exec_track_deferred_tests — TESTS_STATUS:DEFERRED state machine (TAP-1475).
#
# Reads `.tests_status` from ${RALPH_DIR}/status.json (as written by the
# on-stop hook) and updates the CONSECUTIVE_DEFERRED_TEST_COUNT global.
# Three transitions:
#
#   - PASSING / FAIL / UNKNOWN / missing file → counter resets to 0
#   - DEFERRED, counter < CB_MAX_DEFERRED_TESTS → counter increments silently
#   - DEFERRED, CB_MAX_DEFERRED_TESTS <= counter < 2× → counter increments + WARN
#   - DEFERRED, counter >= 2× CB_MAX_DEFERRED_TESTS → counter increments,
#     ERROR log, write CB_STATE_FILE with persistent_test_deferral reason,
#     reset session, update status, `break` the caller's main loop
#
# The `break` walks up the active loop stack, so it exits the outer
# `while ...; do execute_claude_code; done` in main even though it is
# triggered from inside this nested helper.
#
# Args:
#   $1 loop_count — current loop iteration, forwarded to update_status
#
# Globals consumed:
#   CB_MAX_DEFERRED_TESTS, CB_STATE_FILE, CB_STATE_OPEN, RALPH_DIR
#
# Globals mutated:
#   CONSECUTIVE_DEFERRED_TEST_COUNT (incremented or reset)
#   CB_STATE_FILE contents (on trip)
#
# Functions used (defined in ralph_loop.sh):
#   log_status, get_iso_timestamp, reset_session, update_status, _read_call_count
exec_track_deferred_tests() {
    local loop_count=$1

    local _tests_status
    _tests_status=$(jq -r '.tests_status // "UNKNOWN"' "${RALPH_DIR}/status.json" 2>/dev/null || echo "UNKNOWN")

    if [[ "$_tests_status" != "DEFERRED" ]]; then
        CONSECUTIVE_DEFERRED_TEST_COUNT=0
        return 0
    fi

    CONSECUTIVE_DEFERRED_TEST_COUNT=$((CONSECUTIVE_DEFERRED_TEST_COUNT + 1))

    if [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -ge $((CB_MAX_DEFERRED_TESTS * 2)) ]]; then
        log_status "ERROR" "Tests deferred for $CONSECUTIVE_DEFERRED_TEST_COUNT consecutive loops — possible environment issue. Tripping circuit breaker."
        local total_opens
        total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
        total_opens=$((total_opens + 1))
        cat > "$CB_STATE_FILE" << CBEOF
{
    "state": "$CB_STATE_OPEN",
    "last_change": "$(get_iso_timestamp)",
    "opened_at": "$(get_iso_timestamp)",
    "consecutive_no_progress": $CONSECUTIVE_DEFERRED_TEST_COUNT,
    "total_opens": $total_opens,
    "reason": "persistent_test_deferral: $CONSECUTIVE_DEFERRED_TEST_COUNT consecutive DEFERRED loops"
}
CBEOF
        reset_session "persistent_test_deferral"
        update_status "$loop_count" "$(_read_call_count)" "circuit_breaker_open" "halted" "persistent_test_deferral"
        # break propagates up the active loop stack to the main while loop in
        # ralph_loop.sh, exiting it cleanly. Same behavior as the inline block.
        break
    elif [[ "$CONSECUTIVE_DEFERRED_TEST_COUNT" -ge "$CB_MAX_DEFERRED_TESTS" ]]; then
        log_status "WARN" "Tests deferred for $CONSECUTIVE_DEFERRED_TEST_COUNT consecutive loops — possible environment issue"
    fi

    return 0
}

# exec_detect_rate_limit — 4-layer Claude API usage-cap detector (TAP-1476).
#
# Reads the CLI output file and returns:
#   - 0 if no rate-limit signal detected (caller falls through to generic
#     failure handling)
#   - 2 if any of the 4 signals fire (caller should `return 2` from
#     execute_claude_code so the main loop's rate-limit retry logic kicks in)
#
# The 4 layers, checked in order:
#   1. `rate_limit_event` JSON entries with `"status":"rejected"` — the
#      definitive signal from Claude CLI's structured stream.
#   2. Filtered text fallback on the last 30 lines of output, excluding
#      `tool_result` / `tool_use_id` / `type:user` lines (those echo file
#      content and would false-positive on the limit phrasing).
#   3. Same filter, looking for "out of extra usage" — Claude Code's
#      Extra Usage quota exhaustion phrasing (Issue #100).
#
# Args:
#   $1 output_file — path to the Claude CLI result / stream JSON
#
# Side effect:
#   - Logs an ERROR with the matching limit type when detected.
exec_detect_rate_limit() {
    local output_file=$1

    # Layer 2: structural JSON detection — check rate_limit_event for status:"rejected".
    if grep -q '"rate_limit_event"' "$output_file" 2>/dev/null; then
        local last_rate_event
        last_rate_event=$(grep '"rate_limit_event"' "$output_file" | tail -1)
        if echo "$last_rate_event" | grep -qE '"status"\s*:\s*"rejected"'; then
            log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
            return 2
        fi
    fi

    # Layer 3: filtered text fallback — only check tail, excluding tool result lines
    # which contain echoed file content that may match the limit phrasing.
    if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached"; then
        log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
        return 2
    fi

    # Layer 4: Extra Usage quota detection (Issue #100).
    # Claude Code "Extra Usage" mode uses a different error message:
    # "You're out of extra usage · resets 9pm"
    if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "out of extra usage"; then
        log_status "ERROR" "🚫 Claude Extra Usage quota exhausted"
        return 2
    fi

    return 0
}

# exec_handle_timeout — Exit-code-124 (timeout) handler (TAP-1476).
#
# Distinguishes productive timeouts (real work was done during the iteration)
# from unproductive timeouts (no file changes). Productive timeouts run the
# same downstream pipeline as the success path so progress is recorded;
# unproductive timeouts increment the consecutive-timeout counter and trip
# the circuit breaker at MAX_CONSECUTIVE_TIMEOUTS.
#
# Returns:
#   - 0 on productive timeout (caller should treat as success and continue)
#   - 1 on unproductive timeout below threshold (caller propagates)
#   - 3 on circuit-breaker trip (CB_STATE_FILE written, caller should `return 3`)
#
# Args:
#   $1 output_file              — path to the Claude CLI result / stream JSON
#   $2 invocation_start_epoch   — epoch seconds the invocation started, or
#                                 empty to skip latency recording
#
# Globals consumed:
#   CONSECUTIVE_TIMEOUT_COUNT, MAX_CONSECUTIVE_TIMEOUTS, RALPH_DIR,
#   CLAUDE_USE_CONTINUE, CB_STATE_FILE, CB_STATE_OPEN, STATUS_FILE,
#   PROGRESS_FILE
#
# Globals mutated:
#   CONSECUTIVE_TIMEOUT_COUNT, CB_STATE_FILE contents, STATUS_FILE contents,
#   PROGRESS_FILE contents
exec_handle_timeout() {
    local output_file=$1
    local invocation_start_epoch=${2:-}

    log_status "WARN" "⏱️ Claude Code execution timed out (not an API limit)"

    # GUARD-1: Check baseline to detect only changes made during THIS iteration.
    if ralph_has_real_changes; then
        # Productive timeout — real work was done during this iteration.
        local timeout_files_changed
        timeout_files_changed=$(_count_files_changed_since_loop_start)
        log_status "INFO" "⏱️ Timeout but $timeout_files_changed new file(s) changed during this iteration — treating as productive"
        echo '{"status": "timed_out_productive", "files_changed": '$timeout_files_changed', "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"
        # GUARD-2: reset the consecutive timeout counter on productive timeout.
        CONSECUTIVE_TIMEOUT_COUNT=0

        # ADAPTIVE-1: record timeout duration as a latency sample for
        # productive timeouts. Prevents "coordinated omission" bias where
        # only fast loops are recorded and slow QA/epic-boundary loops time
        # out without being counted.
        if [[ -n "$invocation_start_epoch" ]]; then
            local timeout_end_epoch timeout_duration
            timeout_end_epoch=$(date +%s)
            timeout_duration=$((timeout_end_epoch - invocation_start_epoch))
            ralph_record_latency "$timeout_duration"
            log_status "DEBUG" "Recorded productive timeout latency: ${timeout_duration}s (will push adaptive timeout higher)"
        fi

        ralph_prepare_claude_output_for_analysis "$output_file" "timeout"

        # Save session ID (fallback already populated by Step 1 if stream was truncated).
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Update exit signals from status.json (written by on-stop.sh hook).
        log_status "INFO" "🔍 Reading response analysis from status.json..."
        if ! update_exit_signals_from_status; then
            log_status "WARN" "Exit signal update failed; continuing with stale signals"
        fi
        if ! log_status_summary; then
            log_status "WARN" "Analysis summary logging failed; non-critical, continuing"
        fi

        # TAP-917: debrief coordinator on the productive-timeout path too.
        local _debrief_tasks_t _debrief_pd_t
        _debrief_tasks_t=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
        _debrief_pd_t=$(jq -r '.permission_denial_count // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
        if cb_is_open || [[ "${_debrief_pd_t:-0}" -gt 0 ]]; then
            local _detail_t
            _detail_t=$(jq -r '.recommendation // ""' "${RALPH_DIR}/status.json" 2>/dev/null || echo "")
            ralph_debrief_coordinator "failure" "$_detail_t"
        elif [[ "${_debrief_tasks_t:-0}" -gt 0 ]]; then
            ralph_debrief_coordinator "success" ""
        fi

        # TAP-924: task-boundary cleanup on the productive-timeout path. Same
        # ordering invariant as the success path: clear AFTER debrief.
        local _exit_sig_tc_t _tasks_done_tc_t
        _exit_sig_tc_t=$(jq -r '.exit_signal // "false"' "${RALPH_DIR}/status.json" 2>/dev/null || echo "false")
        _tasks_done_tc_t=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
        if [[ "$_exit_sig_tc_t" == "true" ]] || [[ "${_tasks_done_tc_t:-0}" -gt 0 ]]; then
            ralph_clear_coordinator_artifacts
            log_status "INFO" "coordinator: session+brief cleared (task complete)"
        fi

        # Check whether on-stop.sh hook transitioned the circuit breaker to OPEN.
        if cb_is_open; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3
        fi

        return 0
    fi

    # GUARD-2: increment the consecutive-timeout counter for unproductive timeouts.
    CONSECUTIVE_TIMEOUT_COUNT=$((CONSECUTIVE_TIMEOUT_COUNT + 1))
    log_status "WARN" "⏱️ Timeout with NO new file changes — iteration was unproductive ($CONSECUTIVE_TIMEOUT_COUNT/$MAX_CONSECUTIVE_TIMEOUTS)"

    if [[ "$CONSECUTIVE_TIMEOUT_COUNT" -ge "$MAX_CONSECUTIVE_TIMEOUTS" ]]; then
        log_status "ERROR" "Hit $MAX_CONSECUTIVE_TIMEOUTS consecutive unproductive timeouts — opening circuit breaker"
        log_status "ERROR" "Remediation options:"
        log_status "ERROR" "  1. Increase timeout: CLAUDE_TIMEOUT_MINUTES=45 in .ralphrc"
        log_status "ERROR" "  2. Break down tasks: split large tasks in fix_plan.md"
        log_status "ERROR" "  3. Reset and retry: ralph --reset-circuit"
        log_status "ERROR" "  4. Check if Claude is stuck: review last claude_output_*.log"

        # Write halt reason to status.json.
        echo '{"status": "HALTED", "reason": "consecutive_timeouts", "message": "'"$MAX_CONSECUTIVE_TIMEOUTS"' consecutive unproductive timeouts", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$STATUS_FILE"

        # Trip the circuit breaker.
        local total_opens
        total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
        total_opens=$((total_opens + 1))
        cat > "$CB_STATE_FILE" << CBEOF
{
    "state": "$CB_STATE_OPEN",
    "last_change": "$(get_iso_timestamp)",
    "opened_at": "$(get_iso_timestamp)",
    "consecutive_no_progress": $CONSECUTIVE_TIMEOUT_COUNT,
    "total_opens": $total_opens,
    "reason": "consecutive_timeouts: $MAX_CONSECUTIVE_TIMEOUTS unproductive timeouts"
}
CBEOF
        return 3
    fi

    return 1
}

# exec_post_run_coordinator — coordinator post-run state machine (TAP-1477).
#
# Combines three coordinator-related blocks that must run in this order:
#
#   1. Debrief decision (TAP-917) — read tasks_completed and
#      permission_denial_count from status.json. If circuit breaker is OPEN
#      OR permission_denial_count > 0, debrief the coordinator as "failure"
#      with the recommendation. Else if tasks_completed > 0, debrief as
#      "success". Otherwise no debrief.
#   2. BLOCK signal surfacing (TAP-923) — if the .coordinator_block flag
#      file exists (set by coordinator_rpc.sh consult on verdict=BLOCK),
#      log a WARN and remove the flag so it does not carry forward.
#   3. Task-boundary cleanup (TAP-924) — clear brief.json + the resumed
#      coordinator session AFTER the debrief reads them. Triggers: explicit
#      EXIT_SIGNAL or any tasks_completed > 0.
#
# Order matters: debrief reads brief.json, cleanup wipes it. The single
# helper makes that ordering invariant a property of the function rather
# than a comment a future contributor must notice.
#
# Globals consumed: RALPH_DIR
# Functions used:   log_status, cb_is_open, ralph_debrief_coordinator,
#                   ralph_clear_coordinator_artifacts
exec_post_run_coordinator() {
    # 1. Debrief decision
    local _debrief_tasks _debrief_pd
    _debrief_tasks=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
    _debrief_pd=$(jq -r '.permission_denial_count // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
    if cb_is_open || [[ "${_debrief_pd:-0}" -gt 0 ]]; then
        local _detail
        _detail=$(jq -r '.recommendation // ""' "${RALPH_DIR}/status.json" 2>/dev/null || echo "")
        ralph_debrief_coordinator "failure" "$_detail"
    elif [[ "${_debrief_tasks:-0}" -gt 0 ]]; then
        ralph_debrief_coordinator "success" ""
    fi

    # 2. BLOCK signal surfacing — log once, then remove the flag.
    if [[ -f "${RALPH_DIR}/.coordinator_block" ]]; then
        log_status "WARN" "coordinator: BLOCK verdict observed this loop — review the agent's last decision before resuming"
        rm -f "${RALPH_DIR}/.coordinator_block" 2>/dev/null || true
    fi

    # 3. Task-boundary cleanup — runs AFTER debrief so brief.json is still
    # readable when the debrief fires. Per-task grain: next task gets a
    # fresh coordinator + brief. Touches coordinator artifacts only; the
    # main Claude session lifecycle is unchanged.
    local _exit_sig_tc _tasks_done_tc
    _exit_sig_tc=$(jq -r '.exit_signal // "false"' "${RALPH_DIR}/status.json" 2>/dev/null || echo "false")
    _tasks_done_tc=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json" 2>/dev/null || echo "0")
    if [[ "$_exit_sig_tc" == "true" ]] || [[ "${_tasks_done_tc:-0}" -gt 0 ]]; then
        ralph_clear_coordinator_artifacts
        log_status "INFO" "coordinator: session+brief cleared (task complete)"
    fi
}

# exec_detect_output_errors — 2-stage error pattern detection (TAP-1484).
#
# Reads the Claude CLI output file and logs a WARN if specific error patterns
# are present. The 2-stage filter prevents JSON field names ("is_error":
# false) from false-positiving as actual errors:
#
#   Stage 1: filter out lines containing JSON field patterns matching the
#            "...error...": <value> shape
#   Stage 2: grep the filtered remainder for documented error markers:
#            ^Error: / ^ERROR: / ^error: / ]: error / Link: error /
#            Error occurred / failed with error / [Ee]xception / Fatal / FATAL
#
# When VERBOSE_PROGRESS=true, the first 3 matching lines are echoed at DEBUG
# level for diagnostics. Otherwise only the WARN log fires.
#
# The previous inline version stored the result in a `has_errors` local that
# was never read. This helper just logs the side-effect — no return value
# carries downstream.
#
# Args:
#   $1 output_file — path to the Claude CLI output JSON / log
#
# Returns:
#   0 if errors detected (and WARN logged)
#   1 if no errors / missing file (defensive)
exec_detect_output_errors() {
    local output_file=$1

    [[ -f "$output_file" ]] || return 1

    if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
       grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then

        if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "DEBUG" "Error patterns found:"
            grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                head -3 | while IFS= read -r line; do
                log_status "DEBUG" "  $line"
            done
        fi

        log_status "WARN" "Errors detected in output, check: $output_file"
        return 0
    fi

    return 1
}

# =============================================================================
# TAP-1682: per-issue coordinator brief cache.
#
# When the same Linear issue stays "current" across multiple loops (a 5-point
# story routinely spans 4–8 iterations), re-running the coordinator each loop
# regenerates the same brief at 60–120s per call. The cache short-circuits
# that: brief.json is copied to .ralph/.brief_cache/<id>.json after each
# successful run, and the next loop reads it back in <100ms.
#
# Cache schema (one file per Linear issue):
#   {
#     "linear_issue_id":    "TAP-1681",
#     "issue_updated_at":   "2026-05-14T02:02:29Z",   // optional; coordinator
#                                                    // sets this when it
#                                                    // observed updatedAt
#     "cached_at":          1747189349,               // unix epoch seconds
#     "brief":              { ... full brief.json ... }
#   }
#
# Eviction:
#   miss     — cache file does not exist
#   expired  — now - cached_at > RALPH_BRIEF_CACHE_MAX_AGE_SECONDS (default 1800)
#   stale    — current_issue_updated_at provided AND mismatches cached value
#   hit      — file present, fresh, and (if checkable) matching issue_updated_at
#
# In OAuth-via-MCP mode the harness cannot fetch updatedAt itself (no API
# key), so stale detection is best-effort — most evictions go through the
# age path, which is sufficient because the Linear backlog rarely changes
# in <30 min for an actively-worked issue.

# Resolved cache directory. Honors RALPH_BRIEF_CACHE_DIR override (tests use
# a tmpdir); otherwise lives under the active RALPH_DIR so it's wiped with
# the rest of state when an operator runs `ralph --rollback`.
brief_cache_dir() {
    echo "${RALPH_BRIEF_CACHE_DIR:-${RALPH_DIR:-.ralph}/.brief_cache}"
}

brief_cache_path() {
    local issue_id="$1"
    printf '%s/%s.json' "$(brief_cache_dir)" "$issue_id"
}

# exec_load_cached_brief — populate brief.json from cache when fresh.
#
# Args:
#   $1 issue_id              — Linear issue identifier (e.g. TAP-1681)
#   $2 current_updated_at    — OPTIONAL; if supplied and the cache's
#                              issue_updated_at mismatches, the cache is
#                              treated as stale and a refresh is forced.
#   $3 max_age_override      — OPTIONAL; defaults to
#                              RALPH_BRIEF_CACHE_MAX_AGE_SECONDS (1800).
#
# Returns:
#   0 — hit; brief.json was overwritten with the cached payload
#   1 — miss / stale / expired / malformed cache (caller should spawn coord)
#
# Logs (via log_status when available):
#   INFO  "coordinator: cache hit for <id> (age=<n>s)"
#   INFO  "coordinator: cache miss for <id>"
#   INFO  "coordinator: cache stale for <id> (updated_at changed)"
#   INFO  "coordinator: cache expired for <id> (age=<n>s > max=<m>s)"
exec_load_cached_brief() {
    local issue_id="${1:-}"
    local current_updated_at="${2:-}"
    local max_age="${3:-${RALPH_BRIEF_CACHE_MAX_AGE_SECONDS:-1800}}"

    [[ -n "$issue_id" ]] || return 1

    local cache_file
    cache_file=$(brief_cache_path "$issue_id")

    if [[ ! -s "$cache_file" ]]; then
        _brief_cache_log "INFO" "coordinator: cache miss for $issue_id"
        return 1
    fi

    # Read both fields in one jq pass — keeps the on-disk read cheap even
    # though jq itself is the slow part of the hit path.
    local meta
    meta=$(jq -r '[(.cached_at // 0), (.issue_updated_at // "")] | @tsv' "$cache_file" 2>/dev/null)
    if [[ -z "$meta" ]]; then
        _brief_cache_log "INFO" "coordinator: cache malformed for $issue_id — treating as miss"
        return 1
    fi
    local cached_at cached_updated_at
    cached_at=$(echo "$meta" | cut -f1)
    cached_updated_at=$(echo "$meta" | cut -f2)

    # Stale check first: if the caller knows the current updatedAt and it
    # disagrees with the cache, the brief is obsolete even if it is young.
    if [[ -n "$current_updated_at" && -n "$cached_updated_at" \
          && "$current_updated_at" != "$cached_updated_at" ]]; then
        _brief_cache_log "INFO" "coordinator: cache stale for $issue_id (updated_at changed: $cached_updated_at -> $current_updated_at)"
        return 1
    fi

    # Age check.
    local now age
    now=$(date -u +%s)
    age=$(( now - cached_at ))
    if [[ "$age" -gt "$max_age" ]]; then
        _brief_cache_log "INFO" "coordinator: cache expired for $issue_id (age=${age}s > max=${max_age}s)"
        return 1
    fi

    # Hit. Extract the brief payload and write to brief.json atomically so a
    # crash mid-copy cannot leave a half-written brief.
    local brief_target tmp
    if declare -F brief_path >/dev/null 2>&1; then
        brief_target=$(brief_path)
    else
        brief_target="${RALPH_DIR:-.ralph}/brief.json"
    fi
    [[ -n "$brief_target" ]] || return 1
    mkdir -p -- "$(dirname "$brief_target")" 2>/dev/null || true
    tmp="${brief_target}.tmp.$$.${RANDOM}"
    if ! jq -e '.brief' "$cache_file" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        _brief_cache_log "INFO" "coordinator: cache had no .brief payload for $issue_id — treating as miss"
        return 1
    fi
    sync -- "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$brief_target"; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi

    _brief_cache_log "INFO" "coordinator: cache hit for $issue_id (age=${age}s)"
    return 0
}

# exec_save_brief_cache — copy a freshly-written brief.json into the cache.
#
# Called from ralph_spawn_coordinator AFTER a successful coordinator run.
# Atomic-write per the TAP-535 pattern: tmp file + mv -f, with `rm -f` to
# clean up if the rename failed on WSL/NTFS.
#
# Args:
#   $1 issue_id              — Linear issue identifier
#   $2 issue_updated_at      — OPTIONAL; coordinator's observed updatedAt
#                              (the harness writes empty in OAuth-via-MCP
#                              mode where it has no Linear API access).
#
# Returns 0 on success, 1 on any failure (callers ignore the return code —
# cache write must never block the loop).
exec_save_brief_cache() {
    local issue_id="${1:-}"
    local issue_updated_at="${2:-}"
    [[ -n "$issue_id" ]] || return 1

    local brief_target
    if declare -F brief_path >/dev/null 2>&1; then
        brief_target=$(brief_path)
    else
        brief_target="${RALPH_DIR:-.ralph}/brief.json"
    fi
    [[ -s "$brief_target" ]] || return 1

    local cache_dir cache_file
    cache_dir=$(brief_cache_dir)
    cache_file=$(brief_cache_path "$issue_id")
    mkdir -p -- "$cache_dir" 2>/dev/null || return 1

    local now
    now=$(date -u +%s)
    local tmp="${cache_file}.tmp.$$.${RANDOM}"
    if ! jq -n \
        --arg id "$issue_id" \
        --arg ts "$issue_updated_at" \
        --argjson now "$now" \
        --slurpfile brief "$brief_target" \
        '{linear_issue_id: $id, issue_updated_at: $ts, cached_at: $now, brief: $brief[0]}' \
        > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    sync -- "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cache_file"; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    _brief_cache_log "INFO" "coordinator: brief cached for $issue_id"
    return 0
}

# Internal: log_status when the parent shell has it (ralph_loop.sh runtime),
# silent no-op otherwise (tests source this module standalone).
_brief_cache_log() {
    local level="$1"; shift
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "$*"
    fi
}

# =============================================================================
# TAP-1684: parallel epic-boundary QA aggregation.
#
# The ralph-workflow skill + ralph.md QA section instruct Claude to dispatch
# `ralph-tester`, `ralph-reviewer`, and `tapps-validator` in parallel at
# every epic boundary (three Task calls in one message). The agents run
# concurrently and each returns its own PASS / FAIL / TIMEOUT verdict.
# This helper collapses those three independent results to a single
# go/no-go decision that preserves the semantics serial mode had via
# early-exit: any FAIL or TIMEOUT collapses the gate to FAIL.
#
# The function is harness-side because the same aggregation rule applies in
# two places: (1) Claude reading its own sub-agent reports and writing a
# RALPH_STATUS block, (2) any future harness-driven dispatch that wants to
# decide PASS/FAIL without re-asking the main agent. Centralizing the rule
# keeps the two paths in lockstep.

# exec_aggregate_qa_results — combine three sub-agent verdicts to one.
#
# Args (positional, three pairs of <agent-name> <verdict>):
#   $1 $2  — first  agent name and verdict (PASS | FAIL | TIMEOUT)
#   $3 $4  — second agent name and verdict
#   $5 $6  — third  agent name and verdict
#
# Verdict normalization is case-insensitive. Anything outside the set
# {PASS, FAIL, TIMEOUT} is treated as FAIL (defensive — an unparseable
# verdict is no safer than an explicit fail).
#
# Output (stdout, one line):
#   "PASS"                          when all three are PASS
#   "FAIL: <agent1>[, <agent2>...]" listing every agent whose verdict was
#                                   not PASS, in argument order. The first
#                                   non-PASS verdict's category is reported
#                                   in parentheses, e.g.
#                                   "FAIL: ralph-tester (TIMEOUT)".
#
# Return code:
#   0 on PASS, 1 on any other aggregate. Callers can branch on either
#   stdout or the exit code.
exec_aggregate_qa_results() {
    local -a names=()
    local -a verdicts=()
    while [[ $# -gt 0 ]]; do
        names+=("$1")
        verdicts+=("$2")
        shift 2
    done

    # Defensive: any agent count != 3 is FAIL. The contract is fixed to
    # three (tester + reviewer + validator); other counts mean the caller
    # misread the skill's worked example.
    if [[ "${#names[@]}" -ne 3 ]]; then
        printf 'FAIL: bad-agent-count (got %d, expected 3)\n' "${#names[@]}"
        return 1
    fi

    local -a fail_names=()
    local first_fail_kind=""
    local i v
    for i in 0 1 2; do
        v=$(printf '%s' "${verdicts[$i]}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')
        case "$v" in
            PASS) ;;
            FAIL|TIMEOUT)
                fail_names+=("${names[$i]}")
                [[ -z "$first_fail_kind" ]] && first_fail_kind="$v"
                ;;
            *)
                fail_names+=("${names[$i]}")
                [[ -z "$first_fail_kind" ]] && first_fail_kind="FAIL"
                ;;
        esac
    done

    if [[ "${#fail_names[@]}" -eq 0 ]]; then
        printf 'PASS\n'
        return 0
    fi
    local joined
    joined=$(printf '%s, ' "${fail_names[@]}")
    joined="${joined%, }"
    printf 'FAIL: %s (%s)\n' "$joined" "$first_fail_kind"
    return 1
}
