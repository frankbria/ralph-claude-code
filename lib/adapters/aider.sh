#!/bin/bash
# =============================================================================
# Ralph Loop - Aider CLI Adapter
# =============================================================================
# Adapter for Aider - AI pair programming in your terminal.
# Supports multiple AI models including GPT-4, Claude, and local models.
#
# Requirements:
# - Aider: pip install aider-chat
# - API key for chosen model (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.)
#
# Documentation: https://aider.chat
# =============================================================================

# -----------------------------------------------------------------------------
# ADAPTER CONFIGURATION
# -----------------------------------------------------------------------------

ADAPTER_ID="aider"
ADAPTER_DISPLAY_NAME="Aider"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="aider"

# Default settings (can be overridden via environment or config)
AIDER_MODEL="${RALPH_AIDER_MODEL:-gpt-4-turbo}"
AIDER_EDIT_FORMAT="${RALPH_AIDER_EDIT_FORMAT:-diff}"
AIDER_AUTO_COMMITS="${RALPH_AIDER_AUTO_COMMITS:-false}"

# -----------------------------------------------------------------------------
# REQUIRED FUNCTIONS
# -----------------------------------------------------------------------------

adapter_name() {
    echo "$ADAPTER_DISPLAY_NAME"
}

adapter_id() {
    echo "$ADAPTER_ID"
}

adapter_version() {
    echo "$ADAPTER_VERSION"
}

adapter_check() {
    # Check if Aider is installed
    if ! command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        echo "Error: Aider not found."
        echo "Install with: pip install aider-chat"
        return 1
    fi
    
    # Check for API keys based on model
    case "$AIDER_MODEL" in
        gpt-*|o1-*|chatgpt-*)
            if [[ -z "$OPENAI_API_KEY" ]]; then
                echo "Warning: OPENAI_API_KEY not set. Required for OpenAI models."
            fi
            ;;
        claude-*)
            if [[ -z "$ANTHROPIC_API_KEY" ]]; then
                echo "Warning: ANTHROPIC_API_KEY not set. Required for Claude models."
            fi
            ;;
        ollama/*|ollama_chat/*)
            # Local models don't need API keys
            if ! command -v ollama &> /dev/null; then
                echo "Warning: Ollama not found. Required for local models."
            fi
            ;;
    esac
    
    return 0
}

adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"

    # Read prompt content
    local prompt_content
    prompt_content=$(cat "$prompt_file")

    # Build the Aider command as an array to avoid shell injection
    local cmd=("$ADAPTER_CLI_COMMAND" "--model" "$AIDER_MODEL" "--yes" "--no-stream")

    # Disable git integration if configured
    if [[ "$AIDER_AUTO_COMMITS" != "true" ]]; then
        cmd+=("--no-auto-commits")
    fi

    # Set edit format
    if [[ -n "$AIDER_EDIT_FORMAT" ]]; then
        cmd+=("--edit-format" "$AIDER_EDIT_FORMAT")
    fi

    # Add verbose flag
    if [[ "$verbose" == "true" ]]; then
        cmd+=("--verbose")
    fi

    # Pass the prompt as a message
    cmd+=("--message" "$prompt_content")

    # Add any extra arguments (space-delimited string)
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        local extra_array=($extra_args)
        cmd+=("${extra_array[@]}")
    fi

    # Execute with timeout
    local output
    local exit_code

    if [[ -n "$timeout_minutes" && "$timeout_minutes" -gt 0 ]]; then
        if ! output=$(timeout "${timeout_minutes}m" "${cmd[@]}" 2>&1); then
            exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                echo "Error: Execution timed out after ${timeout_minutes} minutes"
                echo "$output"
                return 124
            fi
        else
            exit_code=0
        fi
    else
        if ! output=$("${cmd[@]}" 2>&1); then
            exit_code=$?
        else
            exit_code=0
        fi
    fi

    echo "$output"
    return $exit_code
}

adapter_parse_output() {
    local output="$1"
    
    # Check for rate limiting
    if echo "$output" | grep -qiE "(rate limit|too many requests|quota exceeded|429|RateLimitError)"; then
        echo "RATE_LIMITED"
        return 0
    fi
    
    # Check for completion signals
    local completion_patterns=(
        "Applied edit"
        "No changes (needed|required|made)"
        "All files? (are |have been )?updated"
        "Task complete"
        "Done\\.?$"
        "nothing to do"
        "already.*(up to date|complete|done)"
    )
    
    # Count completion signals
    local completion_count=0
    for pattern in "${completion_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            ((completion_count++))
        fi
    done
    
    # Multiple completion signals = likely complete
    if [[ $completion_count -ge 2 ]]; then
        echo "COMPLETE"
        return 0
    fi
    
    # Check for errors
    local error_patterns=(
        "^Error:"
        "^fatal:"
        "API error"
        "APIError"
        "AuthenticationError"
        "InvalidRequestError"
        "model not found"
        "context.*(length|window|limit)"
    )
    
    for pattern in "${error_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            echo "ERROR"
            return 0
        fi
    done
    
    # Check for git conflicts or issues
    if echo "$output" | grep -qiE "(merge conflict|git error|commit failed)"; then
        echo "ERROR"
        return 0
    fi
    
    # Default: continue
    echo "CONTINUE"
    return 0
}

adapter_supports() {
    echo "streaming,multi-model,git-integration,code-editing,local-models"
}

# -----------------------------------------------------------------------------
# OPTIONAL FUNCTIONS
# -----------------------------------------------------------------------------

adapter_get_config() {
    cat << 'EOF'
{
    "max_context_tokens": 128000,
    "supports_tools": false,
    "supports_streaming": true,
    "supports_vision": true,
    "supports_local_models": true,
    "supports_git_integration": true,
    "default_timeout": 10,
    "rate_limit_per_hour": 60,
    "supported_providers": ["openai", "anthropic", "ollama", "azure", "gemini"]
}
EOF
}

adapter_get_models() {
    cat << 'EOF'
gpt-4-turbo
gpt-4o
gpt-4
gpt-3.5-turbo
claude-3-5-sonnet-20241022
claude-3-opus-20240229
claude-3-sonnet-20240229
claude-3-haiku-20240307
ollama/codellama
ollama/deepseek-coder
ollama/llama3
ollama/mistral
gemini/gemini-1.5-pro
gemini/gemini-1.5-flash
EOF
}

adapter_set_model() {
    local model_name="$1"
    AIDER_MODEL="$model_name"
    return 0
}

adapter_get_rate_limit_status() {
    # Aider doesn't expose rate limit status directly
    echo ""
}

adapter_handle_rate_limit() {
    local wait_seconds="${1:-60}"
    
    echo "Rate limit reached for $AIDER_MODEL."
    echo "Waiting ${wait_seconds} seconds before retrying..."
    
    sleep "$wait_seconds"
    return 0
}

adapter_cleanup() {
    # Aider may leave temp files
    # Clean up any .aider.* temp files if needed
    return 0
}

adapter_get_install_command() {
    echo "pip install aider-chat"
}

adapter_get_documentation_url() {
    echo "https://aider.chat"
}

# -----------------------------------------------------------------------------
# AIDER-SPECIFIC HELPERS
# -----------------------------------------------------------------------------

# Set edit format (diff, whole, udiff)
aider_set_edit_format() {
    local format="$1"
    AIDER_EDIT_FORMAT="$format"
}

# Enable/disable auto commits
aider_set_auto_commits() {
    local enabled="$1"
    AIDER_AUTO_COMMITS="$enabled"
}

# Add files to Aider context
aider_add_files() {
    local files="$*"
    AIDER_CONTEXT_FILES="$files"
}

# Get list of supported models from Aider
aider_list_models() {
    if command -v aider &> /dev/null; then
        aider --list-models 2>/dev/null | head -50
    else
        adapter_get_models
    fi
}
