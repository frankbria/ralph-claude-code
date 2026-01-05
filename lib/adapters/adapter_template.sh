#!/bin/bash
# =============================================================================
# Ralph Loop - Custom Adapter Template
# =============================================================================
# Copy this file to create your own adapter for a custom CLI tool.
# 
# Steps to create a custom adapter:
# 1. Copy this file: cp adapter_template.sh my_tool.sh
# 2. Update the ADAPTER_* variables below
# 3. Implement all the required functions
# 4. Place in ~/.ralph/adapters/ or lib/adapters/
# 5. Use with: ralph --adapter my_tool
# =============================================================================

# -----------------------------------------------------------------------------
# ADAPTER CONFIGURATION - Update these for your tool
# -----------------------------------------------------------------------------

ADAPTER_ID="my_tool"
ADAPTER_DISPLAY_NAME="My Custom Tool"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="mytool"

# -----------------------------------------------------------------------------
# REQUIRED FUNCTIONS - You MUST implement these
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
    # Check if the CLI tool is installed and accessible
    # Return 0 if ready, 1 if not available
    
    if command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        # Optionally check for API keys or other requirements
        # if [[ -z "$MY_TOOL_API_KEY" ]]; then
        #     echo "Error: MY_TOOL_API_KEY environment variable not set"
        #     return 1
        # fi
        return 0
    else
        echo "Error: $ADAPTER_DISPLAY_NAME CLI not found."
        echo "Install with: $(adapter_get_install_command)"
        return 1
    fi
}

adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"
    
    # Read the prompt content
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    
    # Build the command
    # Customize this for your specific CLI tool
    local cmd="$ADAPTER_CLI_COMMAND"
    
    # Add your tool-specific arguments
    # Example: cmd="$cmd --input \"$prompt_file\""
    # Example: cmd="$cmd --message \"$prompt_content\""
    
    if [[ "$verbose" == "true" ]]; then
        cmd="$cmd --verbose"
    fi
    
    # Add any extra arguments
    if [[ -n "$extra_args" ]]; then
        cmd="$cmd $extra_args"
    fi
    
    # Execute with timeout
    # Capture both stdout and stderr
    local output
    local exit_code
    
    if [[ -n "$timeout_minutes" && "$timeout_minutes" -gt 0 ]]; then
        output=$(timeout "${timeout_minutes}m" bash -c "$cmd" 2>&1)
        exit_code=$?
    else
        output=$(bash -c "$cmd" 2>&1)
        exit_code=$?
    fi
    
    # Output the result
    echo "$output"
    
    return $exit_code
}

adapter_parse_output() {
    local output="$1"
    
    # Analyze the output to determine execution status
    # Return one of: COMPLETE, ERROR, CONTINUE, RATE_LIMITED
    
    # Check for completion signals
    # Customize these patterns for your tool's output
    if echo "$output" | grep -qiE "(all (tasks|items) complete|nothing (left )?to do|project (is )?complete|successfully completed)"; then
        echo "COMPLETE"
        return 0
    fi
    
    # Check for rate limiting
    if echo "$output" | grep -qiE "(rate limit|too many requests|quota exceeded|try again later)"; then
        echo "RATE_LIMITED"
        return 0
    fi
    
    # Check for errors
    # Be careful to avoid false positives from JSON fields like "is_error": false
    if echo "$output" | grep -qiE "^(error|fatal|exception|failed):" || \
       echo "$output" | grep -qiE "(API error|connection failed|authentication failed)"; then
        echo "ERROR"
        return 0
    fi
    
    # Default: continue to next iteration
    echo "CONTINUE"
    return 0
}

adapter_supports() {
    # Return comma-separated list of supported features
    # Common features: streaming, tools, vision, multi-model, local, offline
    echo "basic"
}

# -----------------------------------------------------------------------------
# OPTIONAL FUNCTIONS - Override these for enhanced functionality
# -----------------------------------------------------------------------------

adapter_get_config() {
    # Return adapter configuration as JSON
    cat << 'EOF'
{
    "max_context_tokens": 100000,
    "supports_tools": false,
    "supports_streaming": false,
    "supports_vision": false,
    "default_timeout": 15,
    "rate_limit_per_hour": 100
}
EOF
}

adapter_get_models() {
    # Return available models, one per line
    echo "default"
}

adapter_set_model() {
    local model_name="$1"
    # Set the model to use
    # You might store this in a variable: ADAPTER_CURRENT_MODEL="$model_name"
    return 0
}

adapter_get_rate_limit_status() {
    # Return rate limit status as JSON, or empty if not applicable
    echo ""
}

adapter_handle_rate_limit() {
    local wait_seconds="${1:-60}"
    echo "Rate limited. Waiting ${wait_seconds} seconds..."
    sleep "$wait_seconds"
    return 0
}

adapter_cleanup() {
    # Perform any cleanup after execution
    # For example: remove temp files, close connections
    return 0
}

adapter_get_install_command() {
    # Return the command to install this CLI tool
    echo "# Visit https://example.com/my-tool for installation instructions"
}

adapter_get_documentation_url() {
    # Return URL to documentation
    echo "https://example.com/my-tool/docs"
}

# -----------------------------------------------------------------------------
# ADAPTER-SPECIFIC HELPERS - Add your own helper functions below
# -----------------------------------------------------------------------------

# Example helper function
_my_tool_helper() {
    # Your helper logic here
    :
}
