#!/bin/bash

# Devin CLI Adapter Layer for Ralph
# Wraps Devin CLI commands to provide a consistent interface for the Ralph loop.
#
# Devin CLI is session-based and cloud-hosted, unlike Claude Code's local CLI.
# This adapter translates Ralph's execution model into Devin session operations:
#   - create_session  → devin create-session
#   - poll_session    → devin status / list-sessions --json
#   - watch_session   → devin watch
#   - message_session → devin message
#   - terminate       → devin terminate
#
# Version: 0.1.0

# Devin CLI command
DEVIN_CMD="devin"

# Session tracking
DEVIN_SESSION_ID=""
DEVIN_SESSION_FILE="${RALPH_DIR:-.ralph}/.devin_session_id"
DEVIN_SESSION_HISTORY_FILE="${RALPH_DIR:-.ralph}/.devin_session_history"

# Poll configuration
DEVIN_POLL_INTERVAL="${DEVIN_POLL_INTERVAL:-15}"       # seconds between status polls
DEVIN_MAX_POLL_ATTEMPTS="${DEVIN_MAX_POLL_ATTEMPTS:-240}" # max polls (240 * 15s = 60min)

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check if Devin CLI is installed and configured
check_devin_cli() {
    if ! command -v "$DEVIN_CMD" &>/dev/null; then
        echo "ERROR: Devin CLI ('$DEVIN_CMD') is not installed."
        echo ""
        echo "Install via one of:"
        echo "  brew tap revanthpobala/tap && brew install devin-cli"
        echo "  pipx install devin-cli"
        echo "  pip install devin-cli"
        echo ""
        echo "Then configure: devin configure"
        return 1
    fi

    # Check if configured (has API token)
    if [[ -z "${DEVIN_API_TOKEN:-}" ]]; then
        # Try to run a lightweight command to see if configured
        if ! "$DEVIN_CMD" list-sessions --limit 1 &>/dev/null 2>&1; then
            echo "WARN: Devin CLI may not be configured. Run 'devin configure' to set your API token."
        fi
    fi

    return 0
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

# Create a new Devin session with the given prompt
# Args:
#   $1 - prompt_content: The prompt text to send
#   $2 - title (optional): Session title
#   $3 - file_path (optional): File to attach
#   $4 - max_acu (optional): Max ACU limit
# Returns: Session ID on stdout, or empty on failure
# Exit code: 0 on success, 1 on failure
devin_create_session() {
    local prompt_content="$1"
    local title="${2:-Ralph Loop Session}"
    local file_path="${3:-}"
    local max_acu="${4:-}"

    local -a cmd_args=("$DEVIN_CMD" "create-session")

    # Add title
    cmd_args+=("-t" "$title")

    # Add file if specified
    if [[ -n "$file_path" && -f "$file_path" ]]; then
        # Use attach instead of create-session when file is provided
        cmd_args=("$DEVIN_CMD" "attach" "$file_path")
    fi

    # Add max ACU if specified
    if [[ -n "$max_acu" ]]; then
        cmd_args+=("--max-acu" "$max_acu")
    fi

    # Add prompt
    cmd_args+=("$prompt_content")

    # Execute and capture output
    local output
    output=$("${cmd_args[@]}" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: Failed to create Devin session: $output" >&2
        return 1
    fi

    # Extract session ID from output
    # Devin CLI typically outputs the session ID or a JSON response
    local session_id
    session_id=$(echo "$output" | grep -oE '[a-f0-9-]{36}' | head -1)

    if [[ -z "$session_id" ]]; then
        # Try JSON parsing
        session_id=$(echo "$output" | jq -r '.session_id // .id // empty' 2>/dev/null)
    fi

    if [[ -z "$session_id" ]]; then
        echo "ERROR: Could not extract session ID from Devin output" >&2
        echo "Output: $output" >&2
        return 1
    fi

    # Store session ID
    DEVIN_SESSION_ID="$session_id"
    echo "$session_id" > "$DEVIN_SESSION_FILE"

    echo "$session_id"
    return 0
}

# Create a Devin session from a file (reads prompt from file)
# Args:
#   $1 - prompt_file: Path to prompt file
#   $2 - title (optional): Session title
#   $3 - max_acu (optional): Max ACU limit
# Returns: Session ID on stdout
devin_create_session_from_file() {
    local prompt_file="$1"
    local title="${2:-Ralph Loop Session}"
    local max_acu="${3:-}"

    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    devin_create_session "$prompt_content" "$title" "" "$max_acu"
}

# Create a session and wait for completion (blocking)
# Args:
#   $1 - prompt_content: The prompt text
#   $2 - title (optional): Session title
#   $3 - timeout_seconds (optional): Max wait time
# Returns: Session output on stdout
# Exit code: 0 on success, 1 on failure, 2 on timeout
devin_create_session_wait() {
    local prompt_content="$1"
    local title="${2:-Ralph Loop Session}"
    local timeout_seconds="${3:-900}"

    local -a cmd_args=("$DEVIN_CMD" "create-session")
    cmd_args+=("-t" "$title")
    cmd_args+=("$prompt_content")

    # Execute with timeout
    local output
    local exit_code=0

    if command -v gtimeout &>/dev/null; then
        output=$(gtimeout "${timeout_seconds}s" "${cmd_args[@]}" 2>&1) || exit_code=$?
    elif command -v timeout &>/dev/null; then
        output=$(timeout "${timeout_seconds}s" "${cmd_args[@]}" 2>&1) || exit_code=$?
    else
        output=$("${cmd_args[@]}" 2>&1) || exit_code=$?
    fi

    # Check for timeout (exit code 124)
    if [[ $exit_code -eq 124 ]]; then
        echo "TIMEOUT: Devin session exceeded ${timeout_seconds}s" >&2
        return 2
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: Devin session failed: $output" >&2
        return 1
    fi

    # Extract and save session ID
    local session_id
    session_id=$(echo "$output" | grep -oE '[a-f0-9-]{36}' | head -1)
    if [[ -z "$session_id" ]]; then
        session_id=$(echo "$output" | jq -r '.session_id // .id // empty' 2>/dev/null)
    fi

    if [[ -n "$session_id" ]]; then
        DEVIN_SESSION_ID="$session_id"
        echo "$session_id" > "$DEVIN_SESSION_FILE"
    fi

    echo "$output"
    return 0
}

# Get status of a Devin session
# Args:
#   $1 - session_id (optional): defaults to current session
# Returns: JSON status on stdout
devin_get_status() {
    local session_id="${1:-$DEVIN_SESSION_ID}"

    if [[ -z "$session_id" ]]; then
        # Try to read from file
        if [[ -f "$DEVIN_SESSION_FILE" ]]; then
            session_id=$(cat "$DEVIN_SESSION_FILE")
        fi
    fi

    if [[ -z "$session_id" ]]; then
        echo '{"status": "unknown", "error": "no_session_id"}' 
        return 1
    fi

    local output
    output=$("$DEVIN_CMD" status "$session_id" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo '{"status": "error", "error": "'"$(echo "$output" | tr '"' "'")"'"}' 
        return 1
    fi

    echo "$output"
    return 0
}

# List recent Devin sessions
# Args:
#   $1 - limit (optional): max sessions to return, default 5
# Returns: JSON array of sessions on stdout
devin_list_sessions() {
    local limit="${1:-5}"

    local output
    output=$("$DEVIN_CMD" list-sessions --limit "$limit" --json 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "[]"
        return 1
    fi

    echo "$output"
    return 0
}

# Send a message to an active Devin session
# Args:
#   $1 - message: The message text
#   $2 - session_id (optional): defaults to current session
# Returns: 0 on success, 1 on failure
devin_send_message() {
    local message="$1"
    local session_id="${2:-$DEVIN_SESSION_ID}"

    if [[ -z "$session_id" && -f "$DEVIN_SESSION_FILE" ]]; then
        session_id=$(cat "$DEVIN_SESSION_FILE")
    fi

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session to send message to" >&2
        return 1
    fi

    local output
    output=$("$DEVIN_CMD" message "$message" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: Failed to send message: $output" >&2
        return 1
    fi

    return 0
}

# Watch a Devin session (streams output to a file, runs in background)
# Args:
#   $1 - output_file: File to write streamed output to
#   $2 - session_id (optional): defaults to current session
# Returns: PID of background watch process on stdout
devin_watch_session() {
    local output_file="$1"
    local session_id="${2:-$DEVIN_SESSION_ID}"

    if [[ -z "$session_id" && -f "$DEVIN_SESSION_FILE" ]]; then
        session_id=$(cat "$DEVIN_SESSION_FILE")
    fi

    # Start watch in background, redirect to file
    if [[ -n "$session_id" ]]; then
        "$DEVIN_CMD" watch "$session_id" > "$output_file" 2>&1 &
    else
        "$DEVIN_CMD" watch > "$output_file" 2>&1 &
    fi

    local watch_pid=$!
    echo "$watch_pid"
    return 0
}

# Terminate a Devin session
# Args:
#   $1 - session_id (optional): defaults to current session
# Returns: 0 on success, 1 on failure
devin_terminate_session() {
    local session_id="${1:-$DEVIN_SESSION_ID}"

    if [[ -z "$session_id" && -f "$DEVIN_SESSION_FILE" ]]; then
        session_id=$(cat "$DEVIN_SESSION_FILE")
    fi

    if [[ -z "$session_id" ]]; then
        echo "WARN: No session to terminate" >&2
        return 0
    fi

    "$DEVIN_CMD" terminate "$session_id" &>/dev/null
    return $?
}

# =============================================================================
# SESSION POLLING
# =============================================================================

# Poll a Devin session until completion or timeout
# Args:
#   $1 - session_id: The session to poll
#   $2 - output_file: File to write session output to
#   $3 - timeout_seconds (optional): Max poll time, default 900
#   $4 - live_log_file (optional): File for live output (for monitoring)
# Returns: Session final output on stdout
# Exit code: 0 = completed, 1 = failed, 2 = timeout, 3 = blocked
devin_poll_session() {
    local session_id="$1"
    local output_file="$2"
    local timeout_seconds="${3:-900}"
    local live_log_file="${4:-}"

    local start_time
    start_time=$(date +%s)
    local poll_count=0
    local last_status=""

    # Start watch process if live log requested
    local watch_pid=""
    if [[ -n "$live_log_file" ]]; then
        watch_pid=$(devin_watch_session "$live_log_file" "$session_id")
    fi

    while true; do
        poll_count=$((poll_count + 1))

        # Check timeout
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_seconds ]]; then
            # Kill watch process
            [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
            echo "TIMEOUT" > "$output_file"
            return 2
        fi

        # Get session status
        local status_output
        status_output=$(devin_get_status "$session_id" 2>/dev/null)

        # Parse status
        local session_status
        session_status=$(echo "$status_output" | jq -r '.status // .status_enum // "unknown"' 2>/dev/null)

        # Log status changes
        if [[ "$session_status" != "$last_status" ]]; then
            echo "[$(date '+%H:%M:%S')] Session status: $session_status" >&2
            last_status="$session_status"
        fi

        case "$session_status" in
            completed|finished|done|stopped)
                # Session completed successfully
                echo "$status_output" > "$output_file"
                [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
                return 0
                ;;
            failed|error)
                echo "$status_output" > "$output_file"
                [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
                return 1
                ;;
            blocked)
                echo "$status_output" > "$output_file"
                [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
                return 3
                ;;
            running|started|working)
                # Still running, continue polling
                ;;
            *)
                # Unknown status, continue polling
                ;;
        esac

        sleep "$DEVIN_POLL_INTERVAL"
    done
}

# =============================================================================
# SESSION PERSISTENCE
# =============================================================================

# Load saved session ID
# Returns: Session ID on stdout, or empty if none saved
devin_load_session() {
    if [[ -f "$DEVIN_SESSION_FILE" ]]; then
        local session_id
        session_id=$(cat "$DEVIN_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            DEVIN_SESSION_ID="$session_id"
            echo "$session_id"
            return 0
        fi
    fi
    echo ""
    return 0
}

# Save session ID
# Args:
#   $1 - session_id: The session ID to save
devin_save_session() {
    local session_id="$1"
    DEVIN_SESSION_ID="$session_id"
    echo "$session_id" > "$DEVIN_SESSION_FILE"
}

# Clear saved session
devin_clear_session() {
    DEVIN_SESSION_ID=""
    rm -f "$DEVIN_SESSION_FILE" 2>/dev/null
}

# Log session transition to history
# Args:
#   $1 - from_state
#   $2 - to_state
#   $3 - reason
#   $4 - loop_number
devin_log_session_transition() {
    local from_state="$1"
    local to_state="$2"
    local reason="$3"
    local loop_number="${4:-0}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        --arg session_id "${DEVIN_SESSION_ID:-}" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number,
            devin_session_id: $session_id
        }')

    local history='[]'
    if [[ -f "$DEVIN_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$DEVIN_SESSION_HISTORY_FILE" 2>/dev/null)
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    fi

    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    if [[ $? -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$DEVIN_SESSION_HISTORY_FILE"
    else
        echo "[$transition]" > "$DEVIN_SESSION_HISTORY_FILE"
    fi
}

# =============================================================================
# OUTPUT PARSING
# =============================================================================

# Parse Devin session output for Ralph-compatible analysis
# Attempts to extract RALPH_STATUS block from Devin's output
# Args:
#   $1 - output_file: File containing session output
# Returns: JSON analysis object on stdout
devin_parse_output() {
    local output_file="$1"

    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
        echo '{"has_content": false, "exit_signal": false, "work_summary": ""}'
        return 0
    fi

    local content
    content=$(cat "$output_file")

    # Try to detect RALPH_STATUS block (same format as Claude output)
    local exit_signal="false"
    local work_summary=""
    local status_line=""

    # Look for RALPH_STATUS block
    if echo "$content" | grep -q "RALPH_STATUS"; then
        exit_signal=$(echo "$content" | grep -oP 'EXIT_SIGNAL:\s*\K(true|false)' | tail -1)
        status_line=$(echo "$content" | grep -oP 'STATUS:\s*\K.*' | tail -1)
        work_summary=$(echo "$content" | grep -oP 'SUMMARY:\s*\K.*' | tail -1)
    fi

    # Fallback: check for common completion patterns
    if [[ "$exit_signal" != "true" ]]; then
        if echo "$content" | grep -qiE '(all tasks complete|project complete|nothing left to do|all items.*done)'; then
            exit_signal="true"
            [[ -z "$work_summary" ]] && work_summary="Detected completion pattern in output"
        fi
    fi

    # Build analysis JSON
    jq -n \
        --argjson has_content true \
        --arg exit_signal "${exit_signal:-false}" \
        --arg work_summary "${work_summary:-}" \
        --arg status "${status_line:-}" \
        '{
            has_content: $has_content,
            exit_signal: ($exit_signal == "true"),
            work_summary: $work_summary,
            status: $status
        }'
}

# Extract result text from Devin session output
# Args:
#   $1 - output_file: File containing session output
# Returns: Plain text result on stdout
devin_extract_result_text() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]]; then
        echo ""
        return 1
    fi

    # Try JSON first
    local result
    result=$(jq -r '.result // .output // .message // empty' "$output_file" 2>/dev/null)

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    # Fallback: return raw content (truncated)
    head -c 5000 "$output_file"
}
