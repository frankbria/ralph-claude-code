#!/bin/bash

# Devin CLI Adapter Layer for Ralph
# Wraps the official Cognition Devin CLI to provide a consistent interface for the Ralph loop.
#
# The official Devin CLI is a LOCAL agent (like Claude Code), NOT a cloud session API.
# Interface: devin [OPTIONS] [-- <PROMPT>...] [COMMAND]
#
# Key CLI mappings:
#   Non-interactive:  devin -p -- "prompt"
#   Prompt from file: devin -p --prompt-file FILE
#   Continue session: devin -c
#   Resume session:   devin -r SESSION_ID
#   List sessions:    devin list --format json
#   Auth check:       devin auth status
#   Model select:     devin --model opus|sonnet|swe|gpt
#   Permissions:      devin --permission-mode auto|dangerous
#
# Version: 0.2.0

# Devin CLI command
DEVIN_CMD="devin"

# Session tracking
DEVIN_SESSION_ID=""
DEVIN_SESSION_FILE="${RALPH_DIR:-.ralph}/.devin_session_id"
DEVIN_SESSION_HISTORY_FILE="${RALPH_DIR:-.ralph}/.devin_session_history"

# Devin-specific configuration (can be overridden from .ralphrc.devin)
DEVIN_MODEL="${DEVIN_MODEL:-}"                         # opus, sonnet, swe, gpt (empty = default)
DEVIN_PERMISSION_MODE="${DEVIN_PERMISSION_MODE:-auto}" # auto or dangerous

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check if Devin CLI is installed and authenticated
check_devin_cli() {
    if ! command -v "$DEVIN_CMD" &>/dev/null; then
        echo "ERROR: Devin CLI ('$DEVIN_CMD') is not installed." >&2
        echo "" >&2
        echo "Install the official Devin CLI:" >&2
        echo "  See: https://docs.devin.ai/ for installation instructions" >&2
        echo "" >&2
        echo "Then authenticate: devin auth login" >&2
        return 1
    fi

    # Check authentication status
    local auth_output
    auth_output=$("$DEVIN_CMD" auth status 2>&1)
    local auth_exit=$?

    if [[ $auth_exit -ne 0 ]]; then
        echo "WARN: Devin CLI may not be authenticated. Run 'devin auth login' or 'devin setup'." >&2
    fi

    return 0
}

# =============================================================================
# COMMAND BUILDING
# =============================================================================

# Global array for Devin command arguments (avoids shell injection)
declare -a DEVIN_CMD_ARGS=()

# Build Devin CLI command with proper flags using array (shell-injection safe)
# Populates global DEVIN_CMD_ARGS array for direct execution
#
# Args:
#   $1 - prompt_file: Path to the prompt file
#   $2 - loop_context: Additional context string to append
#   $3 - session_id: Session ID for --resume (empty = new session)
build_devin_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    DEVIN_CMD_ARGS=("$DEVIN_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # Non-interactive mode (print response and exit)
    DEVIN_CMD_ARGS+=("-p")

    # Add model selection
    if [[ -n "$DEVIN_MODEL" ]]; then
        DEVIN_CMD_ARGS+=("--model" "$DEVIN_MODEL")
    fi

    # Add permission mode
    if [[ -n "$DEVIN_PERMISSION_MODE" ]]; then
        DEVIN_CMD_ARGS+=("--permission-mode" "$DEVIN_PERMISSION_MODE")
    fi

    # Add session continuity flag
    # Use --resume with explicit session ID to avoid hijacking other sessions
    if [[ -n "$session_id" ]]; then
        DEVIN_CMD_ARGS+=("-r" "$session_id")
    fi

    # --prompt-file and -- PROMPT are mutually exclusive in Devin CLI.
    # When loop context exists, merge prompt + context into a temp file.
    if [[ -n "$loop_context" ]]; then
        local combined_file="${RALPH_DIR:-.ralph}/.devin_prompt_combined.md"
        cat "$prompt_file" > "$combined_file"
        printf '\n\n---\nRALPH LOOP CONTEXT: %s\n' "$loop_context" >> "$combined_file"
        DEVIN_CMD_ARGS+=("--prompt-file" "$combined_file")
    else
        DEVIN_CMD_ARGS+=("--prompt-file" "$prompt_file")
    fi
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

# List recent Devin sessions as JSON
# Returns: JSON output on stdout
devin_list_sessions() {
    "$DEVIN_CMD" list --format json 2>/dev/null
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

# Save session ID from Devin JSON output
# Extracts session ID from the output file and persists it
# Args:
#   $1 - output_file: Path to the Devin output file
devin_save_session() {
    local output_file=$1

    if [[ -f "$output_file" ]]; then
        local session_id
        session_id=$(jq -r '.metadata.session_id // .session_id // .sessionId // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            DEVIN_SESSION_ID="$session_id"
            echo "$session_id" > "$DEVIN_SESSION_FILE"
            return 0
        fi
    fi
    return 1
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

# Parse Devin output for Ralph-compatible analysis
# Attempts to extract RALPH_STATUS block from Devin's output
# Args:
#   $1 - output_file: File containing Devin output
# Returns: JSON analysis object on stdout
devin_parse_output() {
    local output_file="$1"

    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
        echo '{"has_content": false, "exit_signal": false, "work_summary": ""}'
        return 0
    fi

    local content
    content=$(cat "$output_file")

    local exit_signal="false"
    local work_summary=""
    local status_line=""

    # Look for RALPH_STATUS block (same format as Claude output)
    if echo "$content" | grep -q "RALPH_STATUS"; then
        # macOS-compatible: use sed instead of grep -oP
        exit_signal=$(echo "$content" | sed -n 's/.*EXIT_SIGNAL:[[:space:]]*\(true\|false\).*/\1/p' | tail -1)
        status_line=$(echo "$content" | sed -n 's/.*STATUS:[[:space:]]*\(.*\)/\1/p' | tail -1)
        work_summary=$(echo "$content" | sed -n 's/.*SUMMARY:[[:space:]]*\(.*\)/\1/p' | tail -1)
    fi

    # Fallback: check for common completion patterns
    if [[ "$exit_signal" != "true" ]]; then
        if echo "$content" | grep -qiE '(all tasks complete|project complete|nothing left to do|all items.*done)'; then
            exit_signal="true"
            [[ -z "$work_summary" ]] && work_summary="Detected completion pattern in output"
        fi
    fi

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

# Extract result text from Devin output
# Args:
#   $1 - output_file: File containing Devin output
# Returns: Plain text result on stdout
devin_extract_result_text() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]]; then
        echo ""
        return 1
    fi

    # Try JSON first (Devin may output structured JSON)
    local result
    result=$(jq -r '.result // .output // .message // empty' "$output_file" 2>/dev/null)

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    # Fallback: return raw content (truncated)
    head -c 5000 "$output_file"
}

# =============================================================================
# BEADS BIDIRECTIONAL SYNC
# =============================================================================

# beads_pre_sync - Fetch open beads and merge new ones into fix_plan.md
# Called at the start of each loop iteration.
# Only adds beads that aren't already present in fix_plan.md (by bead ID).
#
# Args:
#   $1 - fix_plan_file: Path to fix_plan.md
# Returns:
#   0 on success, 1 if beads unavailable
beads_pre_sync() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"

    # Check if bd is available
    if ! command -v bd &>/dev/null; then
        return 1
    fi

    # Fetch open beads as JSON
    local json_output
    json_output=$(bd list --json --status open 2>/dev/null) || return 1

    if [[ -z "$json_output" ]] || ! echo "$json_output" | jq empty 2>/dev/null; then
        return 1
    fi

    # Parse into "- [ ] [id] title" lines
    local bead_lines
    bead_lines=$(echo "$json_output" | jq -r '
        .[] |
        select((.id // "") != "" and (.title // "") != "") |
        "- [ ] [\(.id)] \(.title)"
    ' 2>/dev/null) || return 1

    if [[ -z "$bead_lines" ]]; then
        return 0
    fi

    # Ensure fix_plan.md exists
    if [[ ! -f "$fix_plan_file" ]]; then
        echo "# Fix Plan" > "$fix_plan_file"
    fi

    local existing_content
    existing_content=$(cat "$fix_plan_file")

    local added=0
    while IFS= read -r line; do
        # Extract bead ID from "- [ ] [some-id] ..."
        local bead_id
        bead_id=$(echo "$line" | sed -n 's/.*\[\([a-zA-Z0-9_-]*\)\].*/\1/p' | head -1)

        if [[ -z "$bead_id" ]]; then
            continue
        fi

        # Check if this bead ID already exists in fix_plan.md (open or completed)
        if ! grep -qF "[$bead_id]" "$fix_plan_file" 2>/dev/null; then
            echo "$line" >> "$fix_plan_file"
            added=$((added + 1))
        fi
    done <<< "$bead_lines"

    if [[ $added -gt 0 ]]; then
        echo "BEADS_PRE_SYNC: Added $added new bead(s) to fix_plan.md" >&2
    fi

    return 0
}

# beads_post_sync - Close beads that were marked completed in fix_plan.md
# Called at the end of each loop iteration.
# Scans fix_plan.md for "- [x] [bead-id] ..." lines and runs `bd close <id>`.
#
# Args:
#   $1 - fix_plan_file: Path to fix_plan.md
#   $2 - loop_count: Current loop number (for close reason)
# Returns:
#   0 on success, 1 if beads unavailable
beads_post_sync() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local loop_count="${2:-0}"

    # Check if bd is available
    if ! command -v bd &>/dev/null; then
        return 1
    fi

    if [[ ! -f "$fix_plan_file" ]]; then
        return 0
    fi

    # Find completed items with bead IDs: "- [x] [some-id] ..."
    local completed_lines
    completed_lines=$(grep -E '^\s*- \[[xX]\] \[' "$fix_plan_file" 2>/dev/null) || return 0

    if [[ -z "$completed_lines" ]]; then
        return 0
    fi

    # Get list of currently open beads so we only try to close open ones
    local open_ids=""
    if open_ids_json=$(bd list --json --status open 2>/dev/null); then
        open_ids=$(echo "$open_ids_json" | jq -r '.[].id // empty' 2>/dev/null)
    fi

    local closed=0
    while IFS= read -r line; do
        # Extract bead ID from "- [x] [some-id] ..."
        local bead_id
        bead_id=$(echo "$line" | sed -n 's/.*\[[xX]\] \[\([a-zA-Z0-9_-]*\)\].*/\1/p' | head -1)

        if [[ -z "$bead_id" ]]; then
            continue
        fi

        # Only close if this ID is in the open beads list
        if echo "$open_ids" | grep -qxF "$bead_id" 2>/dev/null; then
            if bd close "$bead_id" -r "Completed by Ralph Devin loop #${loop_count}" 2>/dev/null; then
                closed=$((closed + 1))
            fi
        fi
    done <<< "$completed_lines"

    if [[ $closed -gt 0 ]]; then
        echo "BEADS_POST_SYNC: Closed $closed bead(s)" >&2
    fi

    return 0
}

# beads_sync_available - Check if beads sync should be performed
# Returns 0 if bd CLI exists and .beads/ directory is present
beads_sync_available() {
    [[ -d ".beads" ]] && command -v bd &>/dev/null
}
