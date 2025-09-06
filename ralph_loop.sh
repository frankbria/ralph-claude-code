#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

set -e  # Exit on any error

# Configuration
PROMPT_FILE="PROMPT.md"
LOG_DIR="logs"
DOCS_DIR="docs/generated"
STATUS_FILE="status.json"
PROGRESS_FILE="progress.json"
CLAUDE_CODE_CMD="claude"
MAX_CALLS_PER_HOUR=100  # Adjust based on your plan
VERBOSE_PROGRESS=false  # Default: no verbose progress updates
CLAUDE_TIMEOUT_MINUTES=15  # Default: 15 minutes timeout for Claude Code execution
SLEEP_DURATION=3600     # 1 hour in seconds
CALL_COUNT_FILE=".call_count"
TIMESTAMP_FILE=".last_reset"
USE_TMUX=false

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
    "timestamp": "$(date -Iseconds)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(date -d '+1 hour' -Iseconds | cut -d'T' -f2 | cut -d'+' -f1)"
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

# Main execution function
execute_claude_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))
    
    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"
    
    # Execute Claude Code with the prompt, streaming output
    if timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 & 
    then
        local claude_pid=$!
        local progress_counter=0
        
        # Show progress while Claude Code is running
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
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
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
            
            # Only log if verbose mode is enabled
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
                fi
            fi
            
            sleep 10
        done
        
        # Wait for the process to finish and get exit code
        wait $claude_pid
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            # Only increment counter on successful execution
            echo "$calls_made" > "$CALL_COUNT_FILE"
            
            # Clear progress file
            echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"
            
            log_status "SUCCESS" "✅ Claude Code execution completed successfully"
            
            # Extract key information from output if possible
            if grep -q "error\|Error\|ERROR" "$output_file"; then
                log_status "WARN" "Errors detected in output, check: $output_file"
            fi
            
            return 0
        else
            # Clear progress file on failure
            echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"
            log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
            return 1
        fi
    else
        log_status "ERROR" "❌ Failed to start Claude Code process"
        return 1
    fi
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
    
    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
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
        
        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi
        
        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"
            
            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"
            
            break
        fi
        
        # Update status
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"
        
        # Execute Claude Code
        if execute_claude_code "$loop_count"; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"
            
            # Brief pause between successful executions
            sleep 5
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
Ralph Loop for Claude Code

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help          Show this help message
    -c, --calls NUM     Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE   Set prompt file (default: $PROMPT_FILE)
    -s, --status        Show current status and exit
    -m, --monitor       Start with tmux session and live monitor (requires tmux)
    -v, --verbose       Show detailed progress updates during execution
    -t, --timeout MIN   Set Claude Code execution timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory  
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress

HELPEOF
}

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
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
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
                CLAUDE_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
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
