#!/bin/bash
# Session Management Component for Ralph

# Session file location
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"
CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"

# Get current session ID from Ralph session file
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    [[ -z "$session_id" || "$session_id" == "null" ]] && session_id=""
    echo "$session_id"
    return 0
}

# Reset session with reason logging
reset_session() {
    local reason=${1:-"manual_reset"}
    local explicit_loop_count=${2:-0}
    local reset_timestamp=$(get_iso_timestamp)

    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null

    if [[ -f "$RALPH_DIR/.exit_signals" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$RALPH_DIR/.exit_signals"
    fi
    rm -f "$RALPH_DIR/.response_analysis" 2>/dev/null

    log_session_transition "active" "reset" "$reason" "$explicit_loop_count" || true
    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}
    local ts=$(get_iso_timestamp)

    local transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    local history='[]'
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        jq empty <<<"$history" 2>/dev/null || history='[]'
    fi

    echo "$history" | jq ". += [$transition] | .[-50:]" > "$RALPH_SESSION_HISTORY_FILE"
}

# Generate a unique session ID
generate_session_id() {
    echo "ralph-$(date +%s)-$RANDOM"
}

# Initialize session tracking
init_session_tracking() {
    local ts=$(get_iso_timestamp)
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_sid=$(generate_session_id)
        jq -n \
            --arg session_id "$new_sid" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
        log_status "INFO" "Initialized session tracking (session: $new_sid)"
    fi
}

# Update last_used timestamp
update_session_last_used() {
    [[ ! -f "$RALPH_SESSION_FILE" ]] && return 0
    local ts=$(get_iso_timestamp)
    local updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    [[ -n "$updated" ]] && echo "$updated" > "$RALPH_SESSION_FILE"
}