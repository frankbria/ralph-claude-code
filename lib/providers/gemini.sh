#!/bin/bash
# Gemini Provider for Ralph
# Implements the Gemini CLI integration (Native Agent Mode)

# Source base provider for shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# Provider-specific configuration
GEMINI_CMD="gemini"

provider_init() {
    if ! command -v "$GEMINI_CMD" &> /dev/null; then
        log_status "ERROR" "Gemini CLI not found. Please install 'gemini'."
        exit 1
    fi
    log_status "INFO" "Gemini CLI provider initialized."
}

provider_execute() {
    local loop_count=$1
    local prompt_file=$2
    local live_mode=$3

    if [[ "$live_mode" == "true" ]]; then
        log_status "WARN" "Live mode is not yet supported for Gemini provider. Falling back to background mode."
    fi
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/gemini_output_${timestamp}.log"
    
    local session_arg=()
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        # Gemini uses --resume latest or session ID
        session_arg=(--resume latest) 
    fi
    
    # Build loop context
    local loop_context=$(build_loop_context "$loop_count")
    local prompt_content=$(cat "$prompt_file")
    local full_prompt
    full_prompt=$(printf "%s\n\n%s" "$loop_context" "$prompt_content")
    
    log_status "INFO" "Executing Gemini CLI (Agent Mode)..."
    
    # Execute Gemini
    # We use --yolo to enable autonomous agent behavior (auto-approve tools)
    # We use -p for non-interactive prompt
    
    $GEMINI_CMD -p "$full_prompt" \
        "${session_arg[@]}" \
        --yolo \
        --output-format text \
        > "$output_file" 2>&1
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_status "SUCCESS" "Gemini execution completed."
        analyze_response "$output_file" "$loop_count"
        update_exit_signals
        return 0
    else
        # Check for specific error conditions in output file
        if grep -qi "429\|quota\|limit" "$output_file"; then
            log_status "ERROR" "Gemini API rate limit reached."
            return 2
        fi
        
        log_status "ERROR" "Gemini execution failed."
        return 1
    fi
}

validate_allowed_tools() {
    # Gemini manages its own tools
    return 0
}

# Helper to build loop context
# (Now provided by lib/providers/base.sh)
