#!/bin/bash

# Codex CLI Adapter Layer for Ralph
# Wraps the Codex CLI to provide a consistent interface for the Ralph loop.
#
# Interface: codex [OPTIONS] [-- <PROMPT>...] [COMMAND]
#
# Key CLI mappings:
#   Non-interactive:  codex -p -- "prompt"
#   Prompt from file: codex -p --prompt-file FILE
#   Continue session: codex -c
#   Resume session:   codex -r SESSION_ID
#   List sessions:    codex list --format json
#   Auth check:       codex auth status
#   Model select:     codex --model gpt-4|gpt-3.5|claude
#   Permissions:      codex --permission-mode auto|dangerous
#
# Version: 0.1.0

# Codex CLI command
CODEX_CMD="codex"

# Session tracking
CODEX_SESSION_ID=""
CODEX_SESSION_FILE="${RALPH_DIR:-.ralph}/.codex_session_id"
CODEX_SESSION_HISTORY_FILE="${RALPH_DIR:-.ralph}/.codex_session_history"

# Codex-specific configuration (can be overridden from .ralphrc.codex)
CODEX_MODEL="${CODEX_MODEL:-}"                         # gpt-4, gpt-3.5, claude (empty = default)
CODEX_PERMISSION_MODE="${CODEX_PERMISSION_MODE:-dangerous}" # auto or dangerous

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check if Codex CLI is installed and authenticated
check_codex_cli() {
    if ! command -v "$CODEX_CMD" &>/dev/null; then
        echo "ERROR: Codex CLI ('$CODEX_CMD') is not installed." >&2
        echo "" >&2
        echo "Install the official Codex CLI:" >&2
        echo "  See: https://docs.codex.ai/ for installation instructions" >&2
        echo "" >&2
        echo "Then authenticate: codex auth login" >&2
        return 1
    fi

    # Check authentication status
    local auth_output
    auth_output=$("$CODEX_CMD" auth status 2>&1)
    local auth_exit=$?

    if [[ $auth_exit -ne 0 ]]; then
        echo "WARN: Codex CLI may not be authenticated. Run 'codex auth login' or 'codex setup'." >&2
    fi

    return 0
}

# =============================================================================
# COMMAND BUILDING
# =============================================================================

# Global array for Codex command arguments (avoids shell injection)
declare -a CODEX_CMD_ARGS=()

# Build Codex CLI command with proper flags using array (shell-injection safe)
# Populates global CODEX_CMD_ARGS array for direct execution
#
# Args:
#   $1 - prompt_file: Path to the prompt file
#   $2 - loop_context: Additional context string to append
#   $3 - session_id: Session ID for --resume (empty = new session)
#   $4 - print_mode: true = non-interactive (-p), false = interactive
build_codex_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local print_mode="${4:-false}"

    # Reset global array
    CODEX_CMD_ARGS=("$CODEX_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # Non-interactive print mode for background execution
    if [[ "$print_mode" == "true" ]]; then
        CODEX_CMD_ARGS+=("-p")
    fi

    # Add model selection
    if [[ -n "$CODEX_MODEL" ]]; then
        CODEX_CMD_ARGS+=("--model" "$CODEX_MODEL")
    fi

    # Add permission mode
    if [[ -n "$CODEX_PERMISSION_MODE" ]]; then
        CODEX_CMD_ARGS+=("--permission-mode" "$CODEX_PERMISSION_MODE")
    fi

    # Add session continuity flag
    if [[ -n "$session_id" ]]; then
        CODEX_CMD_ARGS+=("-r" "$session_id")
    fi

    # Merge prompt + context into a temp file if context exists
    if [[ -n "$loop_context" ]]; then
        local prompt_dir
        prompt_dir=$(dirname "$prompt_file")
        local combined_file="${prompt_dir}/.codex_prompt_combined.md"
        cat "$prompt_file" > "$combined_file"
        printf '\n\n---\nRALPH LOOP CONTEXT: %s\n' "$loop_context" >> "$combined_file"
        CODEX_CMD_ARGS+=("--prompt-file" "$combined_file")
    else
        CODEX_CMD_ARGS+=("--prompt-file" "$prompt_file")
    fi
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

# List recent Codex sessions as JSON
codex_list_sessions() {
    "$CODEX_CMD" list --format json 2>/dev/null
}

# Load saved session ID
codex_load_session() {
    if [[ -f "$CODEX_SESSION_FILE" ]]; then
        local session_id
        session_id=$(cat "$CODEX_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            CODEX_SESSION_ID="$session_id"
            echo "$session_id"
            return 0
        fi
    fi
    return 1
}

# Save session ID to file
codex_save_session() {
    local session_id=$1
    if [[ -n "$session_id" ]]; then
        echo "$session_id" > "$CODEX_SESSION_FILE"
        CODEX_SESSION_ID="$session_id"
        
        # Append to history with timestamp
        local timestamp
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
        echo "$timestamp $session_id" >> "$CODEX_SESSION_HISTORY_FILE"
        
        # Keep only last 50 entries
        if [[ -f "$CODEX_SESSION_HISTORY_FILE" ]]; then
            tail -50 "$CODEX_SESSION_HISTORY_FILE" > "${CODEX_SESSION_HISTORY_FILE}.tmp"
            mv "${CODEX_SESSION_HISTORY_FILE}.tmp" "$CODEX_SESSION_HISTORY_FILE"
        fi
    fi
}

# Reset session state
codex_reset_session() {
    rm -f "$CODEX_SESSION_FILE"
    CODEX_SESSION_ID=""
}

# Extract session ID from Codex output
codex_extract_session_id() {
    local output_file=$1
    
    if [[ ! -f "$output_file" ]]; then
        return 1
    fi
    
    # Try JSON format first
    local session_id
    session_id=$(jq -r '.sessionId // .session_id // empty' "$output_file" 2>/dev/null | head -1)
    
    # Fallback to text parsing
    if [[ -z "$session_id" ]]; then
        session_id=$(grep -oP 'session[_-]?id["\s:]+\K[a-zA-Z0-9_-]+' "$output_file" 2>/dev/null | head -1)
    fi
    
    if [[ -n "$session_id" ]]; then
        echo "$session_id"
        return 0
    fi
    
    return 1
}

# Check if session should be expired
codex_should_expire_session() {
    local expiry_hours="${CODEX_SESSION_EXPIRY_HOURS:-24}"
    
    if [[ ! -f "$CODEX_SESSION_FILE" ]]; then
        return 0  # No session file = expired
    fi
    
    local file_age_seconds
    if [[ "$(uname)" == "Darwin" ]]; then
        file_age_seconds=$(( $(date +%s) - $(stat -f %m "$CODEX_SESSION_FILE" 2>/dev/null || echo 0) ))
    else
        file_age_seconds=$(( $(date +%s) - $(stat -c %Y "$CODEX_SESSION_FILE" 2>/dev/null || echo 0) ))
    fi
    
    local expiry_seconds=$((expiry_hours * 3600))
    
    if [[ $file_age_seconds -gt $expiry_seconds ]]; then
        return 0  # Expired
    fi
    
    return 1  # Not expired
}

# Initialize session tracking
init_codex_session_tracking() {
    mkdir -p "$(dirname "$CODEX_SESSION_FILE")"
    
    # Check for expired session
    if codex_should_expire_session; then
        codex_reset_session
    fi
}
