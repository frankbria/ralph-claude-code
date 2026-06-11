#!/bin/bash

# Ralph Status Monitor - Live terminal dashboard for the Ralph loop
# Note: set -e intentionally removed — the monitor is a display-only loop
# that must be resilient to transient write errors on broken tmux ptys (Issue #188)

STATUS_FILE=".ralph/status.json"
LOG_FILE=".ralph/logs/ralph.log"
REFRESH_INTERVAL=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Clear screen and hide cursor
clear_screen() {
    clear
    printf '\033[?25l'  # Hide cursor
}

# Show cursor on exit
show_cursor() {
    printf '\033[?25h'  # Show cursor
}

# Cleanup function
cleanup() {
    show_cursor
    echo
    echo "Monitor stopped."
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM EXIT

# Main display function
display_status() {
    clear_screen
    
    # Header
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                           🤖 RALPH MONITOR                              ║${NC}"
    echo -e "${WHITE}║                        Live Status Dashboard                           ║${NC}"
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Status section
    if [[ -f "$STATUS_FILE" ]]; then
        # Parse JSON status
        local status_data=$(cat "$STATUS_FILE")
        local loop_count=$(echo "$status_data" | jq -r '.loop_count // "0"' 2>/dev/null || echo "0")
        local calls_made=$(echo "$status_data" | jq -r '.calls_made_this_hour // "0"' 2>/dev/null || echo "0")
        local max_calls=$(echo "$status_data" | jq -r '.max_calls_per_hour // "100"' 2>/dev/null || echo "100")
        local status=$(echo "$status_data" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        
        echo -e "${CYAN}┌─ Current Status ────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} Loop Count:     ${WHITE}#$loop_count${NC}"
        echo -e "${CYAN}│${NC} Status:         ${GREEN}$status${NC}"
        echo -e "${CYAN}│${NC} API Calls:      $calls_made/$max_calls"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
        
    else
        echo -e "${RED}┌─ Status ────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}│${NC} Status file not found. Ralph may not be running."
        echo -e "${RED}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
    fi
    
    # Claude Code Progress section
    if [[ -f ".ralph/progress.json" ]]; then
        local progress_data=$(cat ".ralph/progress.json" 2>/dev/null)
        local progress_status=$(echo "$progress_data" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")
        
        if [[ "$progress_status" == "executing" ]]; then
            local indicator=$(echo "$progress_data" | jq -r '.indicator // "⠋"' 2>/dev/null || echo "⠋")
            local elapsed=$(echo "$progress_data" | jq -r '.elapsed_seconds // "0"' 2>/dev/null || echo "0")
            local last_output=$(echo "$progress_data" | jq -r '.last_output // ""' 2>/dev/null || echo "")
            
            echo -e "${YELLOW}┌─ Claude Code Progress ──────────────────────────────────────────────────┐${NC}"
            echo -e "${YELLOW}│${NC} Status:         ${indicator} Working (${elapsed}s elapsed)"
            if [[ -n "$last_output" && "$last_output" != "" ]]; then
                # Truncate long output for display
                local display_output=$(echo "$last_output" | head -c 60)
                echo -e "${YELLOW}│${NC} Output:         ${display_output}..."
            fi
            echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────────────┘${NC}"
            echo
        fi
    fi
    
    # Sandbox section (Issues #74/#75) - only shown when a sandbox is active
    display_sandbox_status

    # Issue queue section (Issue #72) - only shown when a queue exists
    display_queue_status

    # Recent logs
    echo -e "${BLUE}┌─ Recent Activity ───────────────────────────────────────────────────────┐${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 8 "$LOG_FILE" | while IFS= read -r line; do
            echo -e "${BLUE}│${NC} $line"
        done
    else
        echo -e "${BLUE}│${NC} No log file found"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
    
    # Footer
    echo
    echo -e "${YELLOW}Controls: Ctrl+C to exit | Refreshes every ${REFRESH_INTERVAL}s | $(date '+%H:%M:%S')${NC}"
}

# Sandbox state (Issues #74/#75). No-op unless status.json reports an active
# sandbox provider. Shows the container/sandbox id and, for cloud providers,
# the estimated cost so far.
display_sandbox_status() {
    [[ -f "$STATUS_FILE" ]] || return 0

    local provider
    provider=$(jq -r '.sandbox.provider // "none"' "$STATUS_FILE" 2>/dev/null)
    [[ -z "$provider" || "$provider" == "none" || "$provider" == "null" ]] && return 0

    local sandbox_id status cost
    sandbox_id=$(jq -r '.sandbox.sandbox_id // .sandbox.container_id // ""' "$STATUS_FILE" 2>/dev/null)
    status=$(jq -r '.sandbox.status // "unknown"' "$STATUS_FILE" 2>/dev/null)
    cost=$(jq -r '.sandbox.estimated_cost // ""' "$STATUS_FILE" 2>/dev/null)

    echo -e "${PURPLE}┌─ Sandbox ───────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│${NC} Provider:       ${WHITE}$provider${NC}"
    if [[ -n "$sandbox_id" ]]; then
        echo -e "${PURPLE}│${NC} Sandbox:        ${sandbox_id:0:24}"
    fi
    echo -e "${PURPLE}│${NC} Status:         $status"
    if [[ -n "$cost" && "$cost" != "null" ]]; then
        echo -e "${PURPLE}│${NC} Est. Cost:      \$$cost"
    fi
    echo -e "${PURPLE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
    echo
}

# Issue queue progress (Issue #72). No-op unless .ralph/queue.json exists.
display_queue_status() {
    local queue_file=".ralph/queue.json"
    [[ -f "$queue_file" ]] || return 0

    local total pending processing completed failed
    total=$(jq -r '.queue | length' "$queue_file" 2>/dev/null || echo 0)
    [[ "$total" -eq 0 ]] 2>/dev/null && return 0

    pending=$(jq -r '[.queue[] | select(.status=="pending")] | length' "$queue_file" 2>/dev/null || echo 0)
    processing=$(jq -r '[.queue[] | select(.status=="processing")] | length' "$queue_file" 2>/dev/null || echo 0)
    completed=$(jq -r '[.queue[] | select(.status=="completed")] | length' "$queue_file" 2>/dev/null || echo 0)
    failed=$(jq -r '[.queue[] | select(.status=="failed")] | length' "$queue_file" 2>/dev/null || echo 0)

    local current
    current=$(jq -r 'first(.queue[] | select(.status=="processing")) // empty
                     | "#\(.issue_number // .id) \(.title // "")"' "$queue_file" 2>/dev/null)
    # Strip control characters; issue titles are untrusted and would otherwise
    # let a crafted title inject terminal escape sequences (CodeRabbit #72).
    current=$(printf '%s' "$current" | tr -d '\000-\037')

    echo -e "${CYAN}┌─ Issue Queue ───────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} Progress:       ${WHITE}${completed}/${total}${NC} done  (${pending} pending, ${processing} active, ${failed} failed)"
    if [[ -n "$current" ]]; then
        # %s (not echo -e) so backslash sequences in the title are not interpreted
        printf "${CYAN}│${NC} Current:        %s\n" "$current"
    fi
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────┘${NC}"
    echo
}

# Main monitor loop
main() {
    echo "Starting Ralph Monitor..."
    sleep 2
    
    while true; do
        display_status
        sleep "$REFRESH_INTERVAL"
    done
}

main
