#!/bin/bash
# =============================================================================
# Ralph Loop - Claude Code CLI Adapter
# =============================================================================
# Adapter for Anthropic's Claude Code CLI tool.
# This is the default adapter for Ralph Loop.
#
# Requirements:
# - Claude Code CLI: npm install -g @anthropic-ai/claude-code
# - Valid Anthropic API key or Claude Code authentication
# =============================================================================

# -----------------------------------------------------------------------------
# ADAPTER CONFIGURATION
# -----------------------------------------------------------------------------

ADAPTER_ID="claude"
ADAPTER_DISPLAY_NAME="Claude Code"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="claude"

# Default settings (can be overridden via environment or config)
CLAUDE_ALLOWED_TOOLS="${RALPH_CLAUDE_TOOLS:-Edit,Write,Bash,Read,Glob,TodoRead,TodoWrite}"
CLAUDE_MODEL="${RALPH_CLAUDE_MODEL:-}"

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
    # Check if Claude CLI is installed
    if ! command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        echo "Error: Claude Code CLI not found."
        echo "Install with: npm install -g @anthropic-ai/claude-code"
        return 1
    fi
    
    # Check version (optional but helpful for debugging)
    local version
    version=$($ADAPTER_CLI_COMMAND --version 2>/dev/null || echo "unknown")
    
    return 0
}

adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"
    
    # Build the Claude command
    local cmd="$ADAPTER_CLI_COMMAND"
    
    # Add prompt file
    cmd="$cmd -p \"$prompt_file\""
    
    # Add allowed tools
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        cmd="$cmd --allowedTools \"$CLAUDE_ALLOWED_TOOLS\""
    fi
    
    # Add model if specified
    if [[ -n "$CLAUDE_MODEL" ]]; then
        cmd="$cmd --model \"$CLAUDE_MODEL\""
    fi
    
    # Add verbose flag
    if [[ "$verbose" == "true" ]]; then
        cmd="$cmd --verbose"
    fi
    
    # Add any extra arguments
    if [[ -n "$extra_args" ]]; then
        cmd="$cmd $extra_args"
    fi
    
    # Execute with timeout
    local output
    local exit_code
    
    if [[ -n "$timeout_minutes" && "$timeout_minutes" -gt 0 ]]; then
        output=$(timeout "${timeout_minutes}m" bash -c "$cmd" 2>&1)
        exit_code=$?
        
        # Check for timeout
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
    
    # Check for Claude's 5-hour usage limit
    if echo "$output" | grep -qiE "(usage limit|rate limit exceeded|5.hour|five.hour|quota)"; then
        echo "RATE_LIMITED"
        return 0
    fi
    
    # Check for completion signals (strong indicators)
    local completion_patterns=(
        "all tasks (are |have been )?complete"
        "all items (are |have been )?complete"
        "nothing (left )?to do"
        "project (is |has been )?complete"
        "implementation (is |has been )?complete"
        "successfully completed all"
        "no more tasks"
        "everything.* done"
        "@fix_plan.md.* (all|every).* complete"
    )
    
    for pattern in "${completion_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            echo "COMPLETE"
            return 0
        fi
    done
    
    # Check for errors - but avoid false positives
    # Don't match "error" in JSON fields like "is_error": false
    local error_lines
    error_lines=$(echo "$output" | grep -iE "^error:|^fatal:|exception:|failed to|API error|authentication error" | head -5)
    
    if [[ -n "$error_lines" ]]; then
        # Verify it's a real error, not just a mention
        if echo "$error_lines" | grep -qvE '"error":\s*(false|null|0)'; then
            echo "ERROR"
            return 0
        fi
    fi
    
    # Check for stuck loop indicators
    if echo "$output" | grep -qiE "(stuck in a loop|infinite loop detected|same error repeated|no progress)"; then
        echo "ERROR"
        return 0
    fi
    
    # Default: continue to next iteration
    echo "CONTINUE"
    return 0
}

adapter_supports() {
    echo "streaming,tools,vision,context-window-200k,code-execution"
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
    "default_timeout": 15,
    "rate_limit_per_hour": 100,
    "default_allowed_tools": "Edit,Write,Bash,Read,Glob,TodoRead,TodoWrite"
}
EOF
}

adapter_get_models() {
    # Claude Code uses the latest Claude model by default
    cat << 'EOF'
claude-sonnet-4-20250514
claude-3-5-sonnet-20241022
claude-3-opus-20240229
claude-3-haiku-20240307
EOF
}

adapter_set_model() {
    local model_name="$1"
    CLAUDE_MODEL="$model_name"
    return 0
}

adapter_get_rate_limit_status() {
    # Claude Code doesn't expose rate limit status directly
    # Return empty to indicate not available
    echo ""
}

adapter_handle_rate_limit() {
    local wait_seconds="${1:-3600}"
    
    echo "Claude API rate limit reached."
    echo "You have two options:"
    echo "  1. Wait for the limit to reset (approximately ${wait_seconds} seconds)"
    echo "  2. Exit and try again later"
    echo ""
    echo "Waiting ${wait_seconds} seconds for rate limit reset..."
    
    sleep "$wait_seconds"
    return 0
}

adapter_cleanup() {
    # No specific cleanup needed for Claude
    return 0
}

adapter_get_install_command() {
    echo "npm install -g @anthropic-ai/claude-code"
}

adapter_get_documentation_url() {
    echo "https://docs.anthropic.com/en/docs/claude-code"
}

# -----------------------------------------------------------------------------
# CLAUDE-SPECIFIC HELPERS
# -----------------------------------------------------------------------------

# Set allowed tools for Claude
claude_set_tools() {
    local tools="$1"
    CLAUDE_ALLOWED_TOOLS="$tools"
}

# Get current tool configuration
claude_get_tools() {
    echo "$CLAUDE_ALLOWED_TOOLS"
}

# Parse Claude's structured output (if using JSON mode)
claude_parse_json_response() {
    local output="$1"
    
    # Extract JSON from output if present
    if echo "$output" | grep -q '```json'; then
        echo "$output" | sed -n '/```json/,/```/p' | grep -v '```'
    else
        echo "$output"
    fi
}
