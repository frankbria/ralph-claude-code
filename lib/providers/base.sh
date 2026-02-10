#!/bin/bash
# Base Provider Loader for Ralph

# Load the configured provider
load_provider() {
    local raw_provider="${RALPH_PROVIDER:-claude}"

    # Sanitize and validate provider name to prevent path traversal
    if [[ ! "$raw_provider" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_status "ERROR" "Invalid AI provider name: $raw_provider (only alphanumeric, underscores, and hyphens allowed)"
        exit 1
    fi

    local provider_name="$raw_provider"
    local provider_script="$RALPH_HOME/lib/providers/${provider_name}.sh"
    
    # Fallback to local path if RALPH_HOME not set or script not found
    if [[ ! -f "$provider_script" ]]; then
        provider_script="$(dirname "${BASH_SOURCE[0]}")/${provider_name}.sh"
    fi

    if [[ -f "$provider_script" ]]; then
        source "$provider_script"
        log_status "INFO" "Loaded AI provider: $provider_name"
    else
        log_status "ERROR" "AI provider script not found: $provider_script"
        exit 1
    fi
}

# Helper to build loop context shared by all providers
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
