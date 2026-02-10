#!/bin/bash
# GitHub Copilot Provider for Ralph
# Implements the GitHub Copilot CLI integration

# Source base provider for shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# Provider-specific configuration
COPILOT_CMD="copilot"

provider_init() {
    if ! command -v "$COPILOT_CMD" &> /dev/null; then
        log_status "ERROR" "Copilot CLI not found. Please install 'gh copilot' or 'copilot'."
        exit 1
    fi
    log_status "INFO" "GitHub Copilot provider initialized."
}

provider_execute() {
    local loop_count=$1
    local prompt_file=$2
    local live_mode=$3
    
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/copilot_output_${timestamp}.log"
    local session_file="$RALPH_DIR/.copilot_session_id"
    
    local session_arg=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        # Copilot uses --resume [sessionId]
        # We need to extract the session ID from previous runs if possible
        # Currently we don't have a reliable way to get sessionId from stdout unless we parse it
        # For now, we try --resume without ID which resumes "most recent"
        session_arg="--resume" 
    fi
    
    # Build loop context
    local loop_context=$(build_loop_context "$loop_count")
    
    if [[ ! -r "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found or unreadable: $prompt_file"
        return 1
    fi
    local prompt_content=$(cat "$prompt_file")
    local full_prompt="$loop_context

$prompt_content"
    
    log_status "INFO" "Executing Copilot CLI..."
    
    # Execute Copilot
    # We use --allow-all-tools to enable agentic behavior
    # We use --no-ask-user to prevent blocking prompts
    # We capture stdout/stderr to output_file
    
    # Note: We cannot easily stream output in real-time AND capture it cleanly for analysis without named pipes or complex redirection,
    # but since this is a bash script, we can use the same trick as in ralph_loop.sh if needed.
    # For now, simplistic execution.
    
    $COPILOT_CMD -p "$full_prompt" \
        $session_arg \
        --allow-all-tools \
        --no-ask-user \
        > "$output_file" 2>&1
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_status "SUCCESS" "Copilot execution completed."
        
        # Analyze response
        # Copilot output is text, so we rely on text heuristics
        analyze_response "$output_file" "$loop_count"
        update_exit_signals
        return 0
    else
        log_status "ERROR" "Copilot execution failed."
        # TODO: Detect specific API limit errors if Copilot exposes them in stdout/stderr
        # If grep -q "rate limit" "$output_file"; then return 2; fi
        return 1
    fi
}

validate_allowed_tools() {
    # Copilot manages its own permissions via --allow-tool flags.
    # We could map ALLOWED_TOOLS to --allow-tool flags here.
    return 0
}

# Helper to build loop context
# (Now provided by lib/providers/base.sh)
