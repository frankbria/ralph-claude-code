#!/bin/bash

# Ralph Loop - Multi-CLI Autonomous Development Loop
# Supports multiple AI CLI clients through an adapter pattern
# Default adapter: Claude Code | Also supports: Aider, Ollama, custom adapters

set -e  # Exit on any error

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/adapters/adapter_interface.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/metrics.sh"
source "$SCRIPT_DIR/lib/notifications.sh"
source "$SCRIPT_DIR/lib/backup.sh"

# Configuration
PROMPT_FILE="PROMPT.md"
LOG_DIR="logs"
DOCS_DIR="docs/generated"
STATUS_FILE="status.json"
PROGRESS_FILE="progress.json"
MAX_CALLS_PER_HOUR=100  # Adjust based on your plan
VERBOSE_PROGRESS=false  # Default: no verbose progress updates
EXECUTION_TIMEOUT_MINUTES=15  # Default: 15 minutes timeout for execution
SLEEP_DURATION=3600     # 1 hour in seconds
CALL_COUNT_FILE=".call_count"
TIMESTAMP_FILE=".last_reset"
USE_TMUX=false

# Feature toggles
ENABLE_BACKUP="${ENABLE_BACKUP:-false}"
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-false}"

# Adapter configuration
RALPH_ADAPTER="${RALPH_ADAPTER:-claude}"  # Default adapter
DRY_RUN_MODE=false
ADAPTER_EXTRA_ARGS=""

# Exit detection configuration
EXIT_SIGNALS_FILE=".exit_signals"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Load and verify the selected adapter
init_adapter() {
    log_status "INFO" "Initializing adapter: $RALPH_ADAPTER"
    
    if ! load_adapter "$RALPH_ADAPTER"; then
        log_status "ERROR" "Failed to load adapter: $RALPH_ADAPTER"
        log_status "INFO" "Available adapters:"
        list_available_adapters | while read -r adapter; do
            echo "  - $adapter"
        done
        exit 1
    fi
    
    # Verify adapter is available
    if ! adapter_check; then
        log_status "ERROR" "Adapter '$RALPH_ADAPTER' check failed"
        log_status "INFO" "Install with: $(adapter_get_install_command)"
        exit 1
    fi
    
    log_status "SUCCESS" "Adapter loaded: $(adapter_name) v$(adapter_version)"
    log_status "INFO" "Supported features: $(adapter_supports)"
}

# List available adapters
show_adapters() {
    echo "Available CLI Adapters:"
    echo "========================"
    echo ""
    
    local adapters
    adapters=$(list_available_adapters)
    
    for adapter in $adapters; do
        local info
        info=$(get_adapter_info "$adapter" 2>/dev/null)
        
        if [[ -n "$info" && "$info" != *"error"* ]]; then
            local name version available supports
            name=$(echo "$info" | jq -r '.name // "Unknown"')
            version=$(echo "$info" | jq -r '.version // "0.0.0"')
            available=$(echo "$info" | jq -r '.available // false')
            supports=$(echo "$info" | jq -r '.supports // "basic"')
            
            local status_icon="❌"
            [[ "$available" == "true" ]] && status_icon="✅"
            
            local default_marker=""
            [[ "$adapter" == "claude" ]] && default_marker=" (default)"
            
            echo "  $status_icon $adapter$default_marker"
            echo "     Name: $name v$version"
            echo "     Features: $supports"
            echo ""
        else
            echo "  ❓ $adapter (unable to load)"
            echo ""
        fi
    done
    
    echo "Usage: ralph --adapter <name>"
    echo "Example: ralph --adapter aider --monitor"
}

# Show detailed adapter info
show_adapter_info() {
    local adapter_name="$1"
    
    local info
    info=$(get_adapter_info "$adapter_name" 2>/dev/null)
    
    if [[ -z "$info" || "$info" == *"error"* ]]; then
        echo "Error: Adapter '$adapter_name' not found"
        return 1
    fi
    
    echo "Adapter: $(echo "$info" | jq -r '.name')"
    echo "Version: $(echo "$info" | jq -r '.version')"
    echo "Available: $(echo "$info" | jq -r '.available')"
    echo "Features: $(echo "$info" | jq -r '.supports')"
    echo "Install: $(echo "$info" | jq -r '.install_command')"
    echo "Documentation: $(echo "$info" | jq -r '.documentation')"
    echo ""
    echo "Configuration:"
    echo "$info" | jq '.config'
}

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    
    log_status "INFO" "Setting up tmux session: $session_name"
    
    # Create new tmux session detached
    tmux new-session -d -s "$session_name" -c "$(pwd)"
    
    # Split window vertically to create monitor pane on the right
    tmux split-window -h -t "$session_name" -c "$(pwd)"
    
    # Start monitor in the right pane
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:0.1" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:0.1" "'$ralph_home/ralph_monitor.sh'" Enter
    fi
    
    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi
    
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    if [[ "$PROMPT_FILE" != "PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    
    tmux send-keys -t "$session_name:0.0" "$ralph_cmd" Enter
    
    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:0.0"
    
    # Set window title
    tmux rename-window -t "$session_name:0" "Ralph: Loop | Monitor"
    
    log_status "SUCCESS" "Tmux session created. Attaching to session..."
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"
    
    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"
    
    exit 0
}

# Initialize call tracking
init_call_tracking() {
    log_status "INFO" "DEBUG: Entered init_call_tracking..."
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

    log_status "INFO" "DEBUG: Completed init_call_tracking successfully"
}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    log_status "INFO" "DEBUG: Checking exit conditions..." >&2
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        log_status "INFO" "DEBUG: No exit signals file found, continuing..." >&2
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    log_status "INFO" "DEBUG: Exit signals content: $signals" >&2
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")
    
    log_status "INFO" "DEBUG: Exit counts - test_loops:$recent_test_loops, done_signals:$recent_done_signals, completion:$recent_completion_indicators" >&2
    
    # Check for exit conditions
    
    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Strong completion indicators
    if [[ $recent_completion_indicators -ge 2 ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators)"
        echo "project_complete"
        return 0
    fi
    
    # 4. Check fix_plan.md for completion
    if [[ -f "@fix_plan.md" ]]; then
        local total_items=$(grep -c "^- \[" "@fix_plan.md" 2>/dev/null)
        local completed_items=$(grep -c "^- \[x\]" "@fix_plan.md" 2>/dev/null)
        
        # Handle case where grep returns no matches (exit code 1)
        [[ -z "$total_items" ]] && total_items=0
        [[ -z "$completed_items" ]] && completed_items=0
        
        log_status "INFO" "DEBUG: @fix_plan.md check - total_items:$total_items, completed_items:$completed_items" >&2
        
        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    else
        log_status "INFO" "DEBUG: @fix_plan.md file not found" >&2
    fi
    
    log_status "INFO" "DEBUG: No exit conditions met, continuing loop" >&2
    echo ""  # Return empty string instead of using return code
}

# Main execution function - Uses adapter pattern for CLI abstraction
execute_with_adapter() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S') || {
        log_status "ERROR" "Failed to determine timestamp for adapter execution"
        return 1
    }

    local adapter_id
    if ! adapter_id=$(adapter_id); then
        log_status "ERROR" "Failed to resolve adapter id"
        return 1
    fi

    local output_file="$LOG_DIR/${adapter_id}_output_${timestamp}.log"
    local loop_count=$1

    local calls_made
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        if ! calls_made=$(cat "$CALL_COUNT_FILE"); then
            log_status "WARN" "Failed to read call count; defaulting to 0"
            calls_made=0
        fi
    else
        calls_made=0
    fi
    calls_made=$((calls_made + 1))

    local adapter_display
    if ! adapter_display=$(adapter_name); then
        log_status "ERROR" "Failed to resolve adapter display name"
        return 1
    fi

    log_status "LOOP" "Executing $adapter_display (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    log_status "INFO" "⏳ Starting $adapter_display execution... (timeout: ${EXECUTION_TIMEOUT_MINUTES}m)"

    # Dry run mode - show what would happen without executing
    if [[ "$DRY_RUN_MODE" == "true" ]]; then
        log_status "INFO" "🔬 DRY RUN MODE - No actual execution"
        log_status "INFO" "Would execute: $(adapter_name)"
        log_status "INFO" "Prompt file: $PROMPT_FILE"
        log_status "INFO" "Timeout: ${EXECUTION_TIMEOUT_MINUTES} minutes"
        log_status "INFO" "Adapter features: $(adapter_supports)"
        printf '{"dry_run":true,"adapter":"%s","timestamp":"%s"}\n' \
            "$adapter_id" "$(date '+%Y-%m-%d %H:%M:%S')" > "$PROGRESS_FILE"
        return 0
    fi

    # Execute using the adapter in background to allow progress monitoring
    adapter_execute "$PROMPT_FILE" "$EXECUTION_TIMEOUT_MINUTES" "$VERBOSE_PROGRESS" "$ADAPTER_EXTRA_ARGS" > "$output_file" 2>&1 &
    local adapter_pid=$!
    local progress_counter=0

    # Show progress while adapter is running
    while kill -0 "$adapter_pid" 2>/dev/null; do
        progress_counter=$((progress_counter + 1))
        local progress_indicator
        case $((progress_counter % 4)) in
            1) progress_indicator="⠋" ;;
            2) progress_indicator="⠙" ;;
            3) progress_indicator="⠹" ;;
            0) progress_indicator="⠸" ;;
        esac

        # Get last line from output if available
        local last_line=""
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
        fi

        # Update progress file for monitor
        cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "adapter": "$adapter_id",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

        # Only log if verbose mode is enabled
        if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
            if [[ -n "$last_line" ]]; then
                log_status "INFO" "$progress_indicator $adapter_display: $last_line... (${progress_counter}0s)"
            else
                log_status "INFO" "$progress_indicator $adapter_display working... (${progress_counter}0s elapsed)"
            fi
        fi

        sleep 10
    done

    # Wait for the process to finish and get exit code
    wait "$adapter_pid"
    local exit_code=$?

    # Parse the output using adapter-specific logic
    local output_content
    output_content=$(cat "$output_file" 2>/dev/null)
    local parse_result
    parse_result=$(adapter_parse_output "$output_content")

    if [ $exit_code -eq 0 ] || [[ "$parse_result" == "COMPLETE" ]] || [[ "$parse_result" == "CONTINUE" ]]; then
        # Only increment counter on successful execution
        echo "$calls_made" > "$CALL_COUNT_FILE"

        # Clear progress file
        printf '{"status":"completed","adapter":"%s","timestamp":"%s"}\n' \
            "$adapter_id" "$(date '+%Y-%m-%d %H:%M:%S')" > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ $adapter_display execution completed successfully"

        # Analyze the response
        log_status "INFO" "🔍 Analyzing $adapter_display response..."
        analyze_response "$output_file" "$loop_count"
        local analysis_exit_code=$?
        if [[ $analysis_exit_code -ne 0 ]]; then
            log_status "WARN" "Response analysis returned non-zero exit code ($analysis_exit_code)"
        fi

        # Update exit signals based on analysis
        update_exit_signals

        # Log analysis summary
        log_analysis_summary

        # Get file change count for circuit breaker
        local files_changed
        files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo 0)
        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length
        output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        # Perform adapter cleanup
        adapter_cleanup

        return 0
    elif [[ "$parse_result" == "RATE_LIMITED" ]]; then
        # Rate limit detected by adapter
        printf '{"status":"rate_limited","adapter":"%s","timestamp":"%s"}\n' \
            "$adapter_id" "$(date '+%Y-%m-%d %H:%M:%S')" > "$PROGRESS_FILE"
        log_status "ERROR" "🚫 Rate limit reached for $adapter_display"
        return 2  # Special return code for rate limit
    else
        # Clear progress file on failure
        printf '{"status":"failed","adapter":"%s","timestamp":"%s"}\n' \
            "$adapter_id" "$(date '+%Y-%m-%d %H:%M:%S')" > "$PROGRESS_FILE"

        # Check if the failure is due to API rate/usage limit
        if grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached\|rate.limit\|quota" "$output_file"; then
            log_status "ERROR" "🚫 API usage/rate limit reached"
            return 2  # Special return code for API limit
        else
            log_status "ERROR" "❌ $adapter_display execution failed, check: $output_file"
            return 1
        fi
    fi
}

# Backward compatibility wrapper
execute_claude_code() {
    execute_with_adapter "$@"
}

# Cleanup function
cleanup() {
    log_status "INFO" "Ralph loop interrupted. Cleaning up..."
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Initialize the adapter first
    init_adapter
    
    local adapter_display=$(adapter_name)
    log_status "SUCCESS" "🚀 Ralph loop starting with $adapter_display"
    log_status "INFO" "Adapter: $RALPH_ADAPTER | Max calls/hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"
    
    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "@fix_plan.md" ]] || [[ -d "specs" ]] || [[ -f "@AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi
        
        echo ""
        echo "To fix this:"
        echo "  1. Create a new project: ralph-setup my-project"
        echo "  2. Import existing requirements: ralph-import requirements.md"
        echo "  3. Navigate to an existing Ralph project directory"
        echo "  4. Or create PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: PROMPT.md, @fix_plan.md, specs/, src/, etc."
        exit 1
    fi
    
    log_status "INFO" "Starting main loop..."
    log_status "INFO" "DEBUG: About to enter while loop, loop_count=$loop_count"
    
    while true; do
        loop_count=$((loop_count + 1))
        log_status "INFO" "DEBUG: Successfully incremented loop_count to $loop_count"
        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason
        exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"

            if [[ "${ENABLE_NOTIFICATIONS:-false}" == "true" ]]; then
                send_notification "Ralph loop completed" "Exit reason: $exit_reason (loops: $loop_count)"
            fi

            break
        fi

        # Create backup before executing, if enabled
        if [[ "${ENABLE_BACKUP:-false}" == "true" ]]; then
            create_backup "$loop_count" || log_status "ERROR" "Backup failed for loop #$loop_count"
        fi

        # Update status
        local calls_made
        calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Track loop duration for metrics
        local loop_start loop_end loop_duration
        loop_start=$(date +%s || echo 0)

        # Execute Claude Code (via adapter)
        execute_claude_code "$loop_count"
        local exec_result=$?

        loop_end=$(date +%s || echo 0)
        if [[ "$loop_start" =~ ^[0-9]+$ ]] && [[ "$loop_end" =~ ^[0-9]+$ ]] && [[ $loop_end -ge $loop_start ]]; then
            loop_duration=$((loop_end - loop_start))
        else
            loop_duration=0
        fi

        # Record metrics if helper is available
        if declare -f track_metrics >/dev/null 2>&1; then
            local calls_after
            calls_after=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
            local success_flag="false"
            [[ $exec_result -eq 0 ]] && success_flag="true"
            track_metrics "$loop_count" "$loop_duration" "$success_flag" "$calls_after"
        fi

        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 Claude API 5-hour limit reached!"
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}The Claude API 5-hour usage limit has been reached.${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]] || [[ -z "$user_choice" ]]; then
                log_status "INFO" "User chose to exit (or timed out). Exiting loop..."
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                log_status "INFO" "User chose to wait. Waiting for API limit reset..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop - Multi-CLI Autonomous Development Loop

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -t, --timeout MIN       Set execution timeout in minutes (default: $EXECUTION_TIMEOUT_MINUTES)
    -d, --dry-run           Preview what would be executed without running
    -n, --notify            Enable desktop/terminal notifications (best-effort)
    -b, --backup            Enable automatic git backups before each loop
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit

Adapter Options:
    -a, --adapter NAME      Select CLI adapter (default: claude)
                            Available: claude, aider, ollama, or custom adapters
    --list-adapters         List all available adapters and their status
    --adapter-info NAME     Show detailed information about an adapter
    --adapter-check         Verify the current adapter is properly configured

Adapter-Specific Settings (via environment or .ralphrc):
    RALPH_ADAPTER           Default adapter to use
    RALPH_CLAUDE_TOOLS      Claude Code allowed tools
    RALPH_AIDER_MODEL       Aider model (e.g., gpt-4-turbo, claude-3-opus)
    RALPH_OLLAMA_MODEL      Ollama model (e.g., codellama, deepseek-coder)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)

Example workflow:
    ralph-setup my-project        # Create project
    cd my-project                 # Enter project directory  
    $0 --monitor                  # Start Ralph with monitoring (uses Claude Code)

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor                        # Start with integrated tmux monitoring
    $0 --adapter aider --monitor        # Use Aider instead of Claude Code
    $0 --adapter ollama --timeout 30    # Use local Ollama with 30-min timeout
    $0 --dry-run                        # Preview without executing
    $0 --list-adapters                  # See available adapters
    $0 --verbose --timeout 5            # 5-minute timeout with detailed progress

HELPEOF
}

# Load configuration before parsing CLI so flags can override config values
if declare -f load_config >/dev/null 2>&1; then
    load_config
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                jq . "$STATUS_FILE" 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                EXECUTION_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN_MODE=true
            shift
            ;;
        -a|--adapter)
            RALPH_ADAPTER="$2"
            shift 2
            ;;
        -n|--notify)
            ENABLE_NOTIFICATIONS=true
            shift
            ;;
        -b|--backup)
            ENABLE_BACKUP=true
            shift
            ;;
        --list-adapters)
            show_adapters
            exit 0
            ;;
        --adapter-info)
            show_adapter_info "$2"
            exit 0
            ;;
        --adapter-check)
            init_adapter
            echo "✅ Adapter '$RALPH_ADAPTER' is ready"
            exit 0
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            reset_circuit_breaker "Manual reset via command line"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# If tmux mode requested, set it up
if [[ "$USE_TMUX" == "true" ]]; then
    check_tmux_available
    setup_tmux_session
fi

# Start the main loop
main
