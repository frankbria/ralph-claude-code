#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

set -e  # Exit on any error

# Configuration
PROMPT_FILE="PROMPT.md"
LOG_DIR="logs"
DOCS_DIR="docs/generated"
STATUS_FILE="status.json"
CLAUDE_CODE_CMD="npx @anthropic/claude-code"
MAX_CALLS_PER_HOUR=100  # Adjust based on your plan
SLEEP_DURATION=3600     # 1 hour in seconds
CALL_COUNT_FILE=".call_count"
TIMESTAMP_FILE=".last_reset"

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

# Initialize call tracking
init_call_tracking() {
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
    
    cat > "$STATUS_FILE" << EOF
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
