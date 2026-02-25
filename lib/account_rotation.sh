#!/usr/bin/env bash

# account_rotation.sh - Multi-account rotation for API rate limit handling
# When Claude hits its 5-hour API limit, rotates to the next configured account
# instead of waiting. Falls back to existing wait behavior when all accounts exhausted.
# Issue: https://github.com/frankbria/ralph-claude-code/issues/81

# Source date utilities for cross-platform timestamps and epoch math
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# ============================================================================
# Constants
# ============================================================================

# Account rotation configuration
ACCOUNT_ROTATION="${ACCOUNT_ROTATION:-false}"

# Cooldown duration per rate-limited account (seconds). Matches existing 60-min wait.
ACCOUNT_COOLDOWN_SECONDS="${ACCOUNT_COOLDOWN_SECONDS:-3600}"

# State file location (inside .ralph/ like circuit_breaker_state)
RALPH_DIR="${RALPH_DIR:-.ralph}"
ACCOUNT_ROTATION_STATE_FILE="$RALPH_DIR/.account_rotation_state"

# Global config file for API keys (never committed to repos)
ACCOUNT_KEYS_FILE="${ACCOUNT_KEYS_FILE:-$HOME/.ralph/accounts.conf}"

# Arrays populated by load_account_config()
ACCOUNT_KEYS=()
ACCOUNT_CONFIG_DIRS=()

# ============================================================================
# Configuration Loading
# ============================================================================

# Load account configuration from two sources:
# 1. ~/.ralph/accounts.conf — API keys (CLAUDE_ACCOUNT_KEYS array)
# 2. .ralphrc — config dirs (CLAUDE_CONFIG_DIRS array)
# Returns 0 if at least one account is configured, 1 otherwise.
load_account_config() {
    ACCOUNT_KEYS=()
    ACCOUNT_CONFIG_DIRS=()

    # Load API keys from global config file
    if [[ -f "$ACCOUNT_KEYS_FILE" ]]; then
        # SECURITY: This sources arbitrary bash from the user's home directory.
        # The file is user-created and user-owned (~/.ralph/accounts.conf),
        # so we trust it the same way we trust .bashrc or .profile.
        local CLAUDE_ACCOUNT_KEYS=()
        source "$ACCOUNT_KEYS_FILE"
        if [[ ${#CLAUDE_ACCOUNT_KEYS[@]} -gt 0 ]]; then
            ACCOUNT_KEYS=("${CLAUDE_ACCOUNT_KEYS[@]}")
        fi
    fi

    # Load config dirs from .ralphrc (CLAUDE_CONFIG_DIRS)
    # .ralphrc is already sourced by ralph_loop.sh, so CLAUDE_CONFIG_DIRS may be set
    if [[ -n "${CLAUDE_CONFIG_DIRS+x}" && ${#CLAUDE_CONFIG_DIRS[@]} -gt 0 ]]; then
        ACCOUNT_CONFIG_DIRS=("${CLAUDE_CONFIG_DIRS[@]}")
    fi

    # Return success if at least one account type is configured
    local total_accounts=$(( ${#ACCOUNT_KEYS[@]} + ${#ACCOUNT_CONFIG_DIRS[@]} ))
    if [[ $total_accounts -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# State Management
# ============================================================================

# Get total number of configured accounts (keys + config dirs)
get_total_accounts() {
    echo $(( ${#ACCOUNT_KEYS[@]} + ${#ACCOUNT_CONFIG_DIRS[@]} ))
}

# Initialize the state file if it doesn't exist or is corrupted
_ensure_state_file() {
    if [[ -f "$ACCOUNT_ROTATION_STATE_FILE" ]]; then
        if ! jq '.' "$ACCOUNT_ROTATION_STATE_FILE" > /dev/null 2>&1; then
            rm -f "$ACCOUNT_ROTATION_STATE_FILE"
        fi
    fi

    if [[ ! -f "$ACCOUNT_ROTATION_STATE_FILE" ]]; then
        local tmpfile
        tmpfile=$(mktemp "${ACCOUNT_ROTATION_STATE_FILE}.XXXXXX")
        jq -n '{
            active_index: 0,
            active_type: "none",
            rate_limited: {},
            last_rotation: "",
            total_rotations: 0
        }' > "$tmpfile" && mv "$tmpfile" "$ACCOUNT_ROTATION_STATE_FILE"
    fi
}

# Get the currently active account index and type
# Output: "index type" (e.g., "0 key" or "2 config_dir")
get_active_account() {
    _ensure_state_file

    local index type
    index=$(jq -r '.active_index // 0' "$ACCOUNT_ROTATION_STATE_FILE" 2>/dev/null || echo "0")
    type=$(jq -r '.active_type // "none"' "$ACCOUNT_ROTATION_STATE_FILE" 2>/dev/null || echo "none")
    echo "$index $type"
}

# Mark an account as rate-limited with current timestamp
# Args: $1 = account index, $2 = account type ("key" or "config_dir")
mark_account_rate_limited() {
    local index=$1
    local type=$2
    _ensure_state_file

    local account_id="${type}:${index}"
    local timestamp
    timestamp=$(get_iso_timestamp)

    # Update the rate_limited map with this account's timestamp (atomic write)
    local state_data tmpfile
    state_data=$(cat "$ACCOUNT_ROTATION_STATE_FILE")
    tmpfile=$(mktemp "${ACCOUNT_ROTATION_STATE_FILE}.XXXXXX")
    echo "$state_data" | jq \
        --arg id "$account_id" \
        --arg ts "$timestamp" \
        '.rate_limited[$id] = $ts' \
        > "$tmpfile" && mv "$tmpfile" "$ACCOUNT_ROTATION_STATE_FILE"
}

# Check if an account is currently in cooldown (rate-limited within the cooldown window)
# Args: $1 = account identifier (e.g., "key:0" or "config_dir:1")
# Returns 0 if in cooldown, 1 if available
_is_account_in_cooldown() {
    local account_id=$1
    _ensure_state_file

    local limited_at
    limited_at=$(jq -r --arg id "$account_id" '.rate_limited[$id] // ""' "$ACCOUNT_ROTATION_STATE_FILE" 2>/dev/null || echo "")

    if [[ -z "$limited_at" || "$limited_at" == "null" ]]; then
        return 1  # Not rate-limited, available
    fi

    local limited_epoch current_epoch elapsed
    limited_epoch=$(parse_iso_to_epoch "$limited_at")
    current_epoch=$(get_epoch_seconds)
    elapsed=$(( current_epoch - limited_epoch ))

    if [[ $elapsed -lt $ACCOUNT_COOLDOWN_SECONDS ]]; then
        return 0  # Still in cooldown
    else
        return 1  # Cooldown expired, available
    fi
}

# Find the next available account not in cooldown
# Tries keys first, then config dirs, starting from after the current active account
# Output: "index type" of next available account, or empty string if none available
get_next_available_account() {
    _ensure_state_file

    local current_index current_type
    read -r current_index current_type <<< "$(get_active_account)"
    local total
    total=$(get_total_accounts)

    if [[ $total -eq 0 ]]; then
        echo ""
        return 1
    fi

    # Build a unified list: keys first (type=key), then config dirs (type=config_dir)
    # Convert type-local index to unified position before modular arithmetic.
    # Keys occupy positions 0..K-1, config dirs occupy K..K+D-1.
    local unified_pos=$current_index
    if [[ "$current_type" == "config_dir" ]]; then
        unified_pos=$(( current_index + ${#ACCOUNT_KEYS[@]} ))
    fi

    # Try each account starting from the one after the current active
    local i candidate_index candidate_type account_id
    for (( i = 1; i <= total; i++ )); do
        # Calculate the candidate position in the unified list
        local pos=$(( (unified_pos + i) % total ))

        if [[ $pos -lt ${#ACCOUNT_KEYS[@]} ]]; then
            candidate_index=$pos
            candidate_type="key"
        else
            candidate_index=$(( pos - ${#ACCOUNT_KEYS[@]} ))
            candidate_type="config_dir"
        fi

        account_id="${candidate_type}:${candidate_index}"

        if ! _is_account_in_cooldown "$account_id"; then
            echo "$candidate_index $candidate_type"
            return 0
        fi
    done

    # No available accounts
    echo ""
    return 1
}

# Switch to a specific account by setting the appropriate env var
# Args: $1 = account index, $2 = account type ("key" or "config_dir")
# Returns 0 on success, 1 on failure
switch_account() {
    local index=$1
    local type=$2
    _ensure_state_file

    if [[ "$type" == "key" ]]; then
        if [[ $index -ge ${#ACCOUNT_KEYS[@]} ]]; then
            return 1
        fi
        export ANTHROPIC_API_KEY="${ACCOUNT_KEYS[$index]}"
        # Clear config-dir selector so the API key is the only active mechanism
        unset CLAUDE_CONFIG_DIR
    elif [[ "$type" == "config_dir" ]]; then
        if [[ $index -ge ${#ACCOUNT_CONFIG_DIRS[@]} ]]; then
            return 1
        fi
        # Clear API key so the config-dir selector is the only active mechanism
        unset ANTHROPIC_API_KEY
        local target_dir="${ACCOUNT_CONFIG_DIRS[$index]}"
        # Resolve ~ to $HOME (tilde doesn't expand inside quoted array values)
        target_dir="${target_dir/#\~/$HOME}"
        # The default ~/.claude dir requires CLAUDE_CONFIG_DIR to be UNSET.
        # Setting it explicitly to ~/.claude breaks auth (credentials are in the
        # system keychain, tied to the unset state). For any other dir, set it.
        if [[ "$target_dir" == "$HOME/.claude" || "$target_dir" == "$HOME/.claude/" ]]; then
            unset CLAUDE_CONFIG_DIR
        else
            export CLAUDE_CONFIG_DIR="$target_dir"
        fi
    else
        return 1
    fi

    # Update state file (atomic write)
    local total_rotations
    total_rotations=$(jq -r '.total_rotations // 0' "$ACCOUNT_ROTATION_STATE_FILE" 2>/dev/null || echo "0")
    total_rotations=$(( total_rotations + 1 ))

    local state_data tmpfile
    state_data=$(cat "$ACCOUNT_ROTATION_STATE_FILE")
    tmpfile=$(mktemp "${ACCOUNT_ROTATION_STATE_FILE}.XXXXXX")
    echo "$state_data" | jq \
        --argjson idx "$index" \
        --arg type "$type" \
        --arg ts "$(get_iso_timestamp)" \
        --argjson rotations "$total_rotations" \
        '.active_index = $idx | .active_type = $type | .last_rotation = $ts | .total_rotations = $rotations' \
        > "$tmpfile" && mv "$tmpfile" "$ACCOUNT_ROTATION_STATE_FILE"

    return 0
}

# Check if all configured accounts are currently rate-limited
# Returns 0 if all exhausted, 1 if at least one is available
all_accounts_exhausted() {
    local total
    total=$(get_total_accounts)

    if [[ $total -eq 0 ]]; then
        return 0  # No accounts configured = "exhausted"
    fi

    # Check each account
    local i account_id
    for (( i = 0; i < ${#ACCOUNT_KEYS[@]}; i++ )); do
        account_id="key:${i}"
        if ! _is_account_in_cooldown "$account_id"; then
            return 1  # At least one available
        fi
    done

    for (( i = 0; i < ${#ACCOUNT_CONFIG_DIRS[@]}; i++ )); do
        account_id="config_dir:${i}"
        if ! _is_account_in_cooldown "$account_id"; then
            return 1  # At least one available
        fi
    done

    return 0  # All exhausted
}

# Reset all rate-limit state (clear cooldowns for all accounts)
# Args: $1 = reason for reset (optional, logged to state file)
reset_account_rotation() {
    local reason=${1:-"Manual reset"}

    # Ensure parent directory exists
    local state_dir
    state_dir="$(dirname "$ACCOUNT_ROTATION_STATE_FILE")"
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || return 1
    fi

    local tmpfile
    tmpfile=$(mktemp "${ACCOUNT_ROTATION_STATE_FILE}.XXXXXX")
    jq -n \
        --arg reason "$reason" \
        --arg last_rotation "$(get_iso_timestamp)" \
        '{
            active_index: 0,
            active_type: "none",
            rate_limited: {},
            last_rotation: $last_rotation,
            total_rotations: 0,
            last_reset_reason: $reason
        }' > "$tmpfile" && mv "$tmpfile" "$ACCOUNT_ROTATION_STATE_FILE"
}

# ============================================================================
# Initialization
# ============================================================================

# Initialize account rotation at loop startup
# Loads config, validates accounts, sets up state file
# Returns 0 if rotation is available, 1 if disabled or no accounts
init_account_rotation() {
    # Check if rotation is enabled
    if [[ "$ACCOUNT_ROTATION" != "true" ]]; then
        return 1
    fi

    # Load configuration
    if ! load_account_config; then
        return 1
    fi

    # Ensure state file exists
    _ensure_state_file

    local total
    total=$(get_total_accounts)

    # If active_type is "none", set to first account
    local active_type
    active_type=$(jq -r '.active_type // "none"' "$ACCOUNT_ROTATION_STATE_FILE" 2>/dev/null || echo "none")
    if [[ "$active_type" == "none" && $total -gt 0 ]]; then
        if [[ ${#ACCOUNT_KEYS[@]} -gt 0 ]]; then
            switch_account 0 "key"
        else
            switch_account 0 "config_dir"
        fi
    fi

    return 0
}

# ============================================================================
# High-level rotation function (called from ralph_loop.sh on exit code 2)
# ============================================================================

# Attempt to rotate to the next available account after a rate limit hit
# Returns 0 if rotation succeeded (loop should retry), 1 if no accounts available
try_rotate_account() {
    # Check if rotation is enabled and initialized
    if [[ "$ACCOUNT_ROTATION" != "true" ]]; then
        return 1
    fi

    local total
    total=$(get_total_accounts)
    if [[ $total -eq 0 ]]; then
        return 1
    fi

    # Mark current account as rate-limited
    local current_index current_type
    read -r current_index current_type <<< "$(get_active_account)"
    if [[ "$current_type" != "none" ]]; then
        mark_account_rate_limited "$current_index" "$current_type"
    fi

    # Try to find next available account
    local next
    next=$(get_next_available_account)
    if [[ -z "$next" ]]; then
        return 1  # All accounts exhausted
    fi

    local next_index next_type
    read -r next_index next_type <<< "$next"

    # Switch to the next account
    if switch_account "$next_index" "$next_type"; then
        return 0  # Rotation succeeded
    fi

    return 1
}

# ============================================================================
# Export functions for use in other scripts
# ============================================================================

export -f load_account_config
export -f get_total_accounts
export -f get_active_account
export -f mark_account_rate_limited
export -f get_next_available_account
export -f switch_account
export -f all_accounts_exhausted
export -f reset_account_rotation
export -f init_account_rotation
export -f try_rotate_account
# Private helpers — exported because public functions call them from subshells
export -f _ensure_state_file
export -f _is_account_in_cooldown
