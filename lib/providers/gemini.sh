#!/bin/bash
# Gemini Provider for Ralph
# Implements the Gemini CLI integration (Native Agent Mode)

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
        log_status "ERROR" "Gemini execution failed."
        return 1
    fi
}

validate_allowed_tools() {
    # Gemini manages its own tools
    return 0
}

# Helper to build loop context
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
