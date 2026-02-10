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
