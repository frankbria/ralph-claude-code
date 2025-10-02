#!/bin/bash
# Circuit Breaker Component for Ralph
# Prevents runaway token consumption by detecting stagnation
# Based on Michael Nygard's "Release It!" pattern

# Circuit Breaker States
CB_STATE_CLOSED="CLOSED"        # Normal operation, progress detected
CB_STATE_HALF_OPEN="HALF_OPEN"  # Monitoring mode, checking for recovery
CB_STATE_OPEN="OPEN"            # Failure detected, execution halted

# Circuit Breaker Configuration
CB_STATE_FILE=".circuit_breaker_state"
CB_HISTORY_FILE=".circuit_breaker_history"
CB_NO_PROGRESS_THRESHOLD=3      # Open circuit after N loops with no progress
CB_SAME_ERROR_THRESHOLD=5       # Open circuit after N loops with same error
CB_OUTPUT_DECLINE_THRESHOLD=70  # Open circuit if output declines by >70%

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize circuit breaker
init_circuit_breaker() {
    # Check if state file exists and is valid JSON
    if [[ -f "$CB_STATE_FILE" ]]; then
        if ! jq '.' "$CB_STATE_FILE" > /dev/null 2>&1; then
            # Corrupted, recreate
            rm -f "$CB_STATE_FILE"
        fi
    fi

    if [[ ! -f "$CB_STATE_FILE" ]]; then
        cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(date -Iseconds)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF
    fi

    # Check if history file exists and is valid JSON
    if [[ -f "$CB_HISTORY_FILE" ]]; then
        if ! jq '.' "$CB_HISTORY_FILE" > /dev/null 2>&1; then
            # Corrupted, recreate
            rm -f "$CB_HISTORY_FILE"
        fi
    fi

    if [[ ! -f "$CB_HISTORY_FILE" ]]; then
        echo '[]' > "$CB_HISTORY_FILE"
    fi
}

# Get current circuit breaker state
get_circuit_state() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "$CB_STATE_CLOSED"
        return
    fi

    jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED"
}

# Check if circuit breaker allows execution
can_execute() {
    local state=$(get_circuit_state)

    if [[ "$state" == "$CB_STATE_OPEN" ]]; then
        return 1  # Circuit is open, cannot execute
    else
        return 0  # Circuit is closed or half-open, can execute
    fi
}

# Record loop execution result
record_loop_result() {
    local loop_number=$1
    local files_changed=$2
    local has_errors=$3
    local output_length=$4

    init_circuit_breaker

    local state_data=$(cat "$CB_STATE_FILE")
    local current_state=$(echo "$state_data" | jq -r '.state')
    local consecutive_no_progress=$(echo "$state_data" | jq -r '.consecutive_no_progress' | tr -d '[:space:]')
    local consecutive_same_error=$(echo "$state_data" | jq -r '.consecutive_same_error' | tr -d '[:space:]')
    local last_progress_loop=$(echo "$state_data" | jq -r '.last_progress_loop' | tr -d '[:space:]')

    # Ensure integers
    consecutive_no_progress=$((consecutive_no_progress + 0))
    consecutive_same_error=$((consecutive_same_error + 0))
    last_progress_loop=$((last_progress_loop + 0))

    # Detect progress
    local has_progress=false
    if [[ $files_changed -gt 0 ]]; then
        has_progress=true
        consecutive_no_progress=0
        last_progress_loop=$loop_number
    else
        consecutive_no_progress=$((consecutive_no_progress + 1))
    fi

    # Detect same error repetition
    if [[ "$has_errors" == "true" ]]; then
        consecutive_same_error=$((consecutive_same_error + 1))
    else
        consecutive_same_error=0
    fi

    # Determine new state and reason
    local new_state="$current_state"
    local reason=""

    # State transitions
    case $current_state in
        "$CB_STATE_CLOSED")
            # Normal operation - check for failure conditions
            if [[ $consecutive_no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="No progress detected in $consecutive_no_progress consecutive loops"
            elif [[ $consecutive_same_error -ge $CB_SAME_ERROR_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="Same error repeated in $consecutive_same_error consecutive loops"
            elif [[ $consecutive_no_progress -ge 2 ]]; then
                new_state="$CB_STATE_HALF_OPEN"
                reason="Monitoring: $consecutive_no_progress loops without progress"
            fi
            ;;

        "$CB_STATE_HALF_OPEN")
            # Monitoring mode - either recover or fail
            if [[ "$has_progress" == "true" ]]; then
                new_state="$CB_STATE_CLOSED"
                reason="Progress detected, circuit recovered"
            elif [[ $consecutive_no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="No recovery, opening circuit after $consecutive_no_progress loops"
            fi
            ;;

        "$CB_STATE_OPEN")
            # Circuit is open - stays open (manual intervention required)
            reason="Circuit breaker is open, execution halted"
            ;;
    esac

    # Update state file
    local total_opens=$(echo "$state_data" | jq -r '.total_opens' | tr -d '[:space:]')
    total_opens=$((total_opens + 0))
    if [[ "$new_state" == "$CB_STATE_OPEN" && "$current_state" != "$CB_STATE_OPEN" ]]; then
        total_opens=$((total_opens + 1))
    fi

    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$new_state",
    "last_change": "$(date -Iseconds)",
    "consecutive_no_progress": $consecutive_no_progress,
    "consecutive_same_error": $consecutive_same_error,
    "last_progress_loop": $last_progress_loop,
    "total_opens": $total_opens,
    "reason": "$reason",
    "current_loop": $loop_number
}
EOF

    # Log state transition
    if [[ "$new_state" != "$current_state" ]]; then
        log_circuit_transition "$current_state" "$new_state" "$reason" "$loop_number"
    fi

    # Return exit code based on new state
    if [[ "$new_state" == "$CB_STATE_OPEN" ]]; then
        return 1  # Circuit opened, signal to stop
    else
        return 0  # Can continue
    fi
}

# Log circuit breaker state transitions
log_circuit_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=$4

    local history=$(cat "$CB_HISTORY_FILE")
    local transition="{
        \"timestamp\": \"$(date -Iseconds)\",
        \"loop\": $loop_number,
        \"from_state\": \"$from_state\",
        \"to_state\": \"$to_state\",
        \"reason\": \"$reason\"
    }"

    history=$(echo "$history" | jq ". += [$transition]")
    echo "$history" > "$CB_HISTORY_FILE"

    # Console log with colors
    case $to_state in
        "$CB_STATE_OPEN")
            echo -e "${RED}🚨 CIRCUIT BREAKER OPENED${NC}"
            echo -e "${RED}Reason: $reason${NC}"
            ;;
        "$CB_STATE_HALF_OPEN")
            echo -e "${YELLOW}⚠️  CIRCUIT BREAKER: Monitoring Mode${NC}"
            echo -e "${YELLOW}Reason: $reason${NC}"
            ;;
        "$CB_STATE_CLOSED")
            echo -e "${GREEN}✅ CIRCUIT BREAKER: Normal Operation${NC}"
            echo -e "${GREEN}Reason: $reason${NC}"
            ;;
    esac
}

# Display circuit breaker status
show_circuit_status() {
    init_circuit_breaker

    local state_data=$(cat "$CB_STATE_FILE")
    local state=$(echo "$state_data" | jq -r '.state')
    local reason=$(echo "$state_data" | jq -r '.reason')
    local no_progress=$(echo "$state_data" | jq -r '.consecutive_no_progress')
    local last_progress=$(echo "$state_data" | jq -r '.last_progress_loop')
    local current_loop=$(echo "$state_data" | jq -r '.current_loop')
    local total_opens=$(echo "$state_data" | jq -r '.total_opens')

    local color=""
    local status_icon=""

    case $state in
        "$CB_STATE_CLOSED")
            color=$GREEN
            status_icon="✅"
            ;;
        "$CB_STATE_HALF_OPEN")
            color=$YELLOW
            status_icon="⚠️ "
            ;;
        "$CB_STATE_OPEN")
            color=$RED
            status_icon="🚨"
            ;;
    esac

    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║           Circuit Breaker Status                          ║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${color}State:${NC}                 $status_icon $state"
    echo -e "${color}Reason:${NC}                $reason"
    echo -e "${color}Loops since progress:${NC} $no_progress"
    echo -e "${color}Last progress:${NC}        Loop #$last_progress"
    echo -e "${color}Current loop:${NC}         #$current_loop"
    echo -e "${color}Total opens:${NC}          $total_opens"
    echo ""
}

# Reset circuit breaker (for manual intervention)
reset_circuit_breaker() {
    local reason=${1:-"Manual reset"}

    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(date -Iseconds)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": "$reason"
}
EOF

    echo -e "${GREEN}✅ Circuit breaker reset to CLOSED state${NC}"
}

# Check if loop should halt (used in main loop)
should_halt_execution() {
    local state=$(get_circuit_state)

    if [[ "$state" == "$CB_STATE_OPEN" ]]; then
        show_circuit_status
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  EXECUTION HALTED: Circuit Breaker Opened                 ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Ralph has detected that no progress is being made.${NC}"
        echo ""
        echo -e "${YELLOW}Possible reasons:${NC}"
        echo "  • Project may be complete (check @fix_plan.md)"
        echo "  • Claude may be stuck on an error"
        echo "  • PROMPT.md may need clarification"
        echo "  • Manual intervention may be required"
        echo ""
        echo -e "${YELLOW}To continue:${NC}"
        echo "  1. Review recent logs: tail -20 logs/ralph.log"
        echo "  2. Check Claude output: ls -lt logs/claude_output_*.log | head -1"
        echo "  3. Update @fix_plan.md if needed"
        echo "  4. Reset circuit breaker: ralph --reset-circuit"
        echo ""
        return 0  # Signal to halt
    else
        return 1  # Can continue
    fi
}

# Export functions
export -f init_circuit_breaker
export -f get_circuit_state
export -f can_execute
export -f record_loop_result
export -f show_circuit_status
export -f reset_circuit_breaker
export -f should_halt_execution
