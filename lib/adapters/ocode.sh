#!/bin/bash
# =============================================================================
# Ralph Loop - O-Code Adapter
# =============================================================================
# Adapter for O-Code (opencode) - The open source AI coding agent.
# A full-featured AI-powered coding assistant with multi-provider support.
#
# GitHub: https://github.com/pt-act/o-code
#
# Requirements:
# - O-Code installed: bun add -g opencode-ai (or from source)
# - API key for chosen provider (Anthropic, OpenAI, Google, etc.)
#
# Features:
# - Multi-model support (OpenAI, Anthropic, Google, AWS Bedrock, Ollama, etc.)
# - Built-in agents (build, plan)
# - Client/server architecture
# - Tool/function calling
# - File system access
# - Session management
# =============================================================================

# -----------------------------------------------------------------------------
# ADAPTER CONFIGURATION
# -----------------------------------------------------------------------------

ADAPTER_ID="ocode"
ADAPTER_DISPLAY_NAME="O-Code"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="opencode"

# Default settings (can be overridden via environment)
OCODE_MODEL="${RALPH_OCODE_MODEL:-}"
OCODE_AGENT="${RALPH_OCODE_AGENT:-build}"
OCODE_OUTPUT_FORMAT="${RALPH_OCODE_FORMAT:-default}"
OCODE_SERVER_URL="${RALPH_OCODE_SERVER:-}"
OCODE_SESSION_ID="${RALPH_OCODE_SESSION:-}"

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
    if ! command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        echo "Error: O-Code CLI not found."
        echo "Install with one of:"
        echo "  bun add -g opencode-ai"
        echo "  npm install -g opencode-ai"
        echo "  Or build from source: https://github.com/pt-act/o-code"
        return 1
    fi
    
    local version
    version=$($ADAPTER_CLI_COMMAND --version 2>/dev/null || echo "unknown")
    
    return 0
}

adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"
    
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    
    local cmd="$ADAPTER_CLI_COMMAND run"
    
    if [[ -n "$OCODE_SERVER_URL" ]]; then
        cmd="$cmd --attach \"$OCODE_SERVER_URL\""
    fi
    
    if [[ -n "$OCODE_SESSION_ID" ]]; then
        cmd="$cmd --session \"$OCODE_SESSION_ID\""
    fi
    
    if [[ -n "$OCODE_MODEL" ]]; then
        cmd="$cmd --model \"$OCODE_MODEL\""
    fi
    
    if [[ -n "$OCODE_AGENT" ]]; then
        cmd="$cmd --agent \"$OCODE_AGENT\""
    fi
    
    if [[ "$OCODE_OUTPUT_FORMAT" == "json" ]]; then
        cmd="$cmd --format json"
    fi
    
    if [[ -n "$extra_args" ]]; then
        cmd="$cmd $extra_args"
    fi
    
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$prompt_content" | sed "s/'/'\\\\''/g")
    cmd="$cmd -- '$escaped_prompt'"
    
    local output
    local exit_code
    
    if [[ -n "$timeout_minutes" && "$timeout_minutes" -gt 0 ]]; then
        output=$(timeout "${timeout_minutes}m" bash -c "$cmd" 2>&1)
        exit_code=$?
        
        if [[ $exit_code -eq 124 ]]; then
            echo "Error: Execution timed out after ${timeout_minutes} minutes"
            echo "$output"
            return 124
        fi
    else
        output=$(bash -c "$cmd" 2>&1)
        exit_code=$?
    fi
    
    echo "$output"
    return $exit_code
}

adapter_parse_output() {
    local output="$1"
    
    if echo "$output" | grep -qiE "(rate limit|too many requests|quota exceeded|429|RateLimitError)"; then
        echo "RATE_LIMITED"
        return 0
    fi
    
    local completion_patterns=(
        "all tasks (are |have been )?complete"
        "all items (are |have been )?complete"
        "nothing (left )?to do"
        "project (is |has been )?complete"
        "implementation (is |has been )?complete"
        "successfully completed all"
        "no more tasks"
        "everything.* done"
        "work (is |has been )?complete"
        "feature (is |has been )?complete"
    )
    
    for pattern in "${completion_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            echo "COMPLETE"
            return 0
        fi
    done
    
    if [[ "$OCODE_OUTPUT_FORMAT" == "json" ]]; then
        if echo "$output" | grep -qE '"type":\s*"error"'; then
            if ! echo "$output" | grep -qE '"type":\s*"text"'; then
                echo "ERROR"
                return 0
            fi
        fi
    fi
    
    local error_lines
    error_lines=$(echo "$output" | grep -iE "^(error|fatal|exception):|failed to|API error|authentication error|provider.*error" | head -5)
    
    if [[ -n "$error_lines" ]]; then
        if echo "$error_lines" | grep -qvE '"error":\s*(false|null|0)'; then
            echo "ERROR"
            return 0
        fi
    fi
    
    if echo "$output" | grep -qiE "(stuck in a loop|infinite loop detected|same error repeated|no progress)"; then
        echo "ERROR"
        return 0
    fi
    
    echo "CONTINUE"
    return 0
}

adapter_supports() {
    echo "streaming,tools,multi-model,multi-provider,code-editing,session-management,file-access,agents"
}

# -----------------------------------------------------------------------------
# OPTIONAL FUNCTIONS
# -----------------------------------------------------------------------------

adapter_get_config() {
    cat << 'EOF'
{
    "max_context_tokens": 200000,
    "supports_tools": true,
    "supports_streaming": true,
    "supports_vision": true,
    "supports_code_execution": true,
    "supports_multi_provider": true,
    "supports_session_management": true,
    "default_timeout": 15,
    "rate_limit_per_hour": 100,
    "default_agent": "build",
    "available_agents": ["build", "plan"]
}
EOF
}

adapter_get_models() {
    cat << 'EOF'
anthropic/claude-sonnet-4-20250514
anthropic/claude-3-5-sonnet-20241022
anthropic/claude-3-opus-20240229
openai/gpt-4o
openai/gpt-4-turbo
openai/o1
openai/o3-mini
google/gemini-2.0-flash-exp
google/gemini-1.5-pro
ollama/codellama
ollama/deepseek-coder
EOF
}

adapter_set_model() {
    local model_name="$1"
    OCODE_MODEL="$model_name"
    return 0
}

adapter_get_rate_limit_status() {
    echo ""
}

adapter_handle_rate_limit() {
    local wait_seconds="${1:-60}"
    
    echo "O-Code provider rate limit reached."
    echo "Waiting ${wait_seconds} seconds before retrying..."
    
    sleep "$wait_seconds"
    return 0
}

adapter_cleanup() {
    return 0
}

adapter_get_install_command() {
    cat << 'EOF'
# Install from npm/bun
bun add -g opencode-ai
# or
npm install -g opencode-ai

# Or build from source
git clone https://github.com/pt-act/o-code
cd o-code
bun install
bun run build
EOF
}

adapter_get_documentation_url() {
    echo "https://github.com/pt-act/o-code"
}

# -----------------------------------------------------------------------------
# OCODE-SPECIFIC HELPERS
# -----------------------------------------------------------------------------

ocode_set_agent() {
    local agent="$1"
    if [[ "$agent" == "build" || "$agent" == "plan" ]]; then
        OCODE_AGENT="$agent"
        return 0
    else
        echo "Error: Unknown agent '$agent'. Available: build, plan"
        return 1
    fi
}

ocode_get_agent() {
    echo "$OCODE_AGENT"
}

ocode_set_server() {
    local url="$1"
    OCODE_SERVER_URL="$url"
}

ocode_get_server() {
    echo "$OCODE_SERVER_URL"
}

ocode_enable_json_output() {
    OCODE_OUTPUT_FORMAT="json"
}

ocode_disable_json_output() {
    OCODE_OUTPUT_FORMAT="default"
}

ocode_set_session() {
    local session_id="$1"
    OCODE_SESSION_ID="$session_id"
}

ocode_clear_session() {
    OCODE_SESSION_ID=""
}

ocode_continue_session() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    
    local cmd="$ADAPTER_CLI_COMMAND run --continue"
    
    if [[ -n "$OCODE_SERVER_URL" ]]; then
        cmd="$cmd --attach \"$OCODE_SERVER_URL\""
    fi
    
    if [[ -n "$OCODE_MODEL" ]]; then
        cmd="$cmd --model \"$OCODE_MODEL\""
    fi
    
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$prompt_content" | sed "s/'/'\\\\''/g")
    cmd="$cmd -- '$escaped_prompt'"
    
    local output
    if [[ -n "$timeout_minutes" && "$timeout_minutes" -gt 0 ]]; then
        output=$(timeout "${timeout_minutes}m" bash -c "$cmd" 2>&1)
    else
        output=$(bash -c "$cmd" 2>&1)
    fi
    
    echo "$output"
}

ocode_attach_to_server() {
    local server_url="${1:-http://localhost:4096}"
    local prompt_file="$2"
    local timeout_minutes="${3:-15}"
    
    OCODE_SERVER_URL="$server_url"
    adapter_execute "$prompt_file" "$timeout_minutes" "false" "--attach \"$server_url\""
}

ocode_parse_json_event() {
    local output="$1"
    local event_type="$2"
    
    echo "$output" | grep "\"type\":\"$event_type\"" | while read -r line; do
        echo "$line"
    done
}

ocode_extract_tool_calls() {
    local output="$1"
    ocode_parse_json_event "$output" "tool_use"
}

ocode_extract_text_output() {
    local output="$1"
    
    if [[ "$OCODE_OUTPUT_FORMAT" == "json" ]]; then
        echo "$output" | grep '"type":"text"' | while read -r line; do
            echo "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p'
        done
    else
        echo "$output"
    fi
}

ocode_list_providers() {
    cat << 'EOF'
anthropic    - Anthropic (Claude models)
openai       - OpenAI (GPT models)
google       - Google AI (Gemini models)
bedrock      - AWS Bedrock
azure        - Azure OpenAI
groq         - Groq
xai          - xAI (Grok models)
ollama       - Ollama (local models)
copilot      - GitHub Copilot
EOF
}
