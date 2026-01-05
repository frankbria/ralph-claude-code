#!/bin/bash
# =============================================================================
# Ralph Loop - Ollama CLI Adapter
# =============================================================================
# Adapter for Ollama - Run large language models locally.
# Supports fully offline operation with local models.
#
# Requirements:
# - Ollama: curl -fsSL https://ollama.ai/install.sh | sh
# - At least one model pulled: ollama pull codellama
#
# Documentation: https://ollama.ai
# =============================================================================

# -----------------------------------------------------------------------------
# ADAPTER CONFIGURATION
# -----------------------------------------------------------------------------

ADAPTER_ID="ollama"
ADAPTER_DISPLAY_NAME="Ollama (Local LLM)"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="ollama"

# Default settings
OLLAMA_MODEL="${RALPH_OLLAMA_MODEL:-codellama}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_CONTEXT_LENGTH="${RALPH_OLLAMA_CONTEXT:-4096}"
OLLAMA_TEMPERATURE="${RALPH_OLLAMA_TEMPERATURE:-0.7}"

# System prompt for code assistance
OLLAMA_SYSTEM_PROMPT="${RALPH_OLLAMA_SYSTEM:-You are an expert software developer. Analyze the requirements and implement the requested changes. Be concise and focus on working code.}"

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
    # Check if Ollama CLI is installed
    if ! command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        echo "Error: Ollama not found."
        echo "Install with: curl -fsSL https://ollama.ai/install.sh | sh"
        return 1
    fi
    
    # Check if Ollama server is running
    if ! curl -s "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        echo "Error: Ollama server is not running."
        echo "Start with: ollama serve"
        return 1
    fi
    
    # Check if the selected model is available
    local available_models
    available_models=$(curl -s "${OLLAMA_HOST}/api/tags" 2>/dev/null | grep -o '"name":"[^"]*"' | sed 's/"name":"//g;s/"//g')
    
    if ! echo "$available_models" | grep -q "^${OLLAMA_MODEL}"; then
        echo "Warning: Model '$OLLAMA_MODEL' not found locally."
        echo "Available models: $available_models"
        echo "Pull with: ollama pull $OLLAMA_MODEL"
        # Don't fail - the model might be pulled automatically
    fi
    
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
    
    # Escape the prompt for JSON
    local escaped_prompt
    escaped_prompt=$(echo "$prompt_content" | jq -Rs '.')
    
    # Escape the system prompt for JSON
    local escaped_system
    escaped_system=$(echo "$OLLAMA_SYSTEM_PROMPT" | jq -Rs '.')
    
    # Build the request JSON
    local request_json
    request_json=$(cat << EOF
{
    "model": "$OLLAMA_MODEL",
    "prompt": $escaped_prompt,
    "system": $escaped_system,
    "stream": false,
    "options": {
        "num_ctx": $OLLAMA_CONTEXT_LENGTH,
        "temperature": $OLLAMA_TEMPERATURE
    }
}
EOF
)
    
    if [[ "$verbose" == "true" ]]; then
        echo "=== Ollama Request ===" >&2
        echo "Model: $OLLAMA_MODEL" >&2
        echo "Host: $OLLAMA_HOST" >&2
        echo "Context: $OLLAMA_CONTEXT_LENGTH" >&2
        echo "======================" >&2
    fi
    
    # Execute with timeout using curl
    local output
    local exit_code
    local timeout_seconds=$((timeout_minutes * 60))
    
    output=$(curl -s --max-time "$timeout_seconds" \
        -X POST "${OLLAMA_HOST}/api/generate" \
        -H "Content-Type: application/json" \
        -d "$request_json" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Failed to connect to Ollama server"
        echo "$output"
        return 1
    fi
    
    # Extract the response text from JSON
    local response_text
    response_text=$(echo "$output" | jq -r '.response // empty' 2>/dev/null)
    
    if [[ -z "$response_text" ]]; then
        # Check for error in response
        local error_msg
        error_msg=$(echo "$output" | jq -r '.error // empty' 2>/dev/null)
        if [[ -n "$error_msg" ]]; then
            echo "Error from Ollama: $error_msg"
            return 1
        fi
        # Return raw output if can't parse
        echo "$output"
    else
        echo "$response_text"
    fi
    
    return 0
}

adapter_parse_output() {
    local output="$1"
    
    # Check for Ollama-specific errors
    if echo "$output" | grep -qiE "(Error from Ollama|Failed to connect|model.*not found|out of memory)"; then
        echo "ERROR"
        return 0
    fi
    
    # Check for completion signals
    local completion_patterns=(
        "task.*(complete|done|finished)"
        "implementation.*(complete|ready)"
        "all changes.*(applied|made)"
        "code.*(updated|modified|complete)"
        "nothing.*(left|more|else).*to do"
        "requirements.*(met|satisfied|fulfilled)"
    )
    
    local completion_count=0
    for pattern in "${completion_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            ((completion_count++))
        fi
    done
    
    if [[ $completion_count -ge 2 ]]; then
        echo "COMPLETE"
        return 0
    fi
    
    # Check for error patterns
    if echo "$output" | grep -qiE "^(error|fatal|exception):"; then
        echo "ERROR"
        return 0
    fi
    
    # Default: continue
    echo "CONTINUE"
    return 0
}

adapter_supports() {
    echo "local,offline,multi-model,no-rate-limit,streaming,context-customizable"
}

# -----------------------------------------------------------------------------
# OPTIONAL FUNCTIONS
# -----------------------------------------------------------------------------

adapter_get_config() {
    cat << EOF
{
    "max_context_tokens": $OLLAMA_CONTEXT_LENGTH,
    "supports_tools": false,
    "supports_streaming": true,
    "supports_vision": false,
    "supports_local": true,
    "supports_offline": true,
    "default_timeout": 10,
    "rate_limit_per_hour": -1,
    "default_model": "$OLLAMA_MODEL"
}
EOF
}

adapter_get_models() {
    # Get list of locally available models
    local models
    models=$(curl -s "${OLLAMA_HOST}/api/tags" 2>/dev/null | \
             jq -r '.models[].name' 2>/dev/null)
    
    if [[ -n "$models" ]]; then
        echo "$models"
    else
        # Fallback to common models
        cat << 'EOF'
codellama
codellama:7b
codellama:13b
codellama:34b
deepseek-coder
deepseek-coder:6.7b
deepseek-coder:33b
llama3
llama3:8b
llama3:70b
mistral
mistral:7b
mixtral
mixtral:8x7b
phi3
phi3:mini
starcoder2
starcoder2:7b
EOF
    fi
}

adapter_set_model() {
    local model_name="$1"
    OLLAMA_MODEL="$model_name"
    
    # Try to pull the model if not available
    if ! ollama list 2>/dev/null | grep -q "^${model_name}"; then
        echo "Model not found locally. Pulling $model_name..."
        ollama pull "$model_name"
    fi
    
    return 0
}

adapter_get_rate_limit_status() {
    # Local models have no rate limits
    echo '{"unlimited": true, "local": true}'
}

adapter_handle_rate_limit() {
    # Local models don't have rate limits
    echo "Note: Ollama (local) has no rate limits."
    return 0
}

adapter_cleanup() {
    # No cleanup needed for Ollama
    return 0
}

adapter_get_install_command() {
    echo "curl -fsSL https://ollama.ai/install.sh | sh && ollama pull codellama"
}

adapter_get_documentation_url() {
    echo "https://ollama.ai"
}

# -----------------------------------------------------------------------------
# OLLAMA-SPECIFIC HELPERS
# -----------------------------------------------------------------------------

# Set the context length
ollama_set_context() {
    local length="$1"
    OLLAMA_CONTEXT_LENGTH="$length"
}

# Set temperature for generation
ollama_set_temperature() {
    local temp="$1"
    OLLAMA_TEMPERATURE="$temp"
}

# Set custom system prompt
ollama_set_system_prompt() {
    local prompt="$1"
    OLLAMA_SYSTEM_PROMPT="$prompt"
}

# Pull a model
ollama_pull_model() {
    local model="$1"
    echo "Pulling model: $model"
    ollama pull "$model"
}

# List locally available models
ollama_list_models() {
    ollama list 2>/dev/null || echo "Error: Could not list models"
}

# Check if a specific model is available
ollama_has_model() {
    local model="$1"
    ollama list 2>/dev/null | grep -q "^${model}"
}

# Get model info
ollama_model_info() {
    local model="${1:-$OLLAMA_MODEL}"
    ollama show "$model" 2>/dev/null
}

# Start Ollama server if not running
ollama_ensure_server() {
    if ! curl -s "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        echo "Starting Ollama server..."
        ollama serve &
        sleep 3
    fi
}
