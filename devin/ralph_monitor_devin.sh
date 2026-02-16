#!/bin/bash

# Ralph Monitor for Devin CLI - Live Status Dashboard
# Parallel to ralph_monitor.sh (Claude Code) — adapted for Devin session monitoring
#
# Version: 0.1.0

set -e

# Configuration
RALPH_DIR=".ralph"
STATUS_FILE="$RALPH_DIR/status.json"
LOG_FILE="$RALPH_DIR/logs/ralph.log"
LIVE_LOG_FILE="$RALPH_DIR/live.log"
REFRESH_INTERVAL=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

show_help() {
    cat << EOF
Ralph Monitor for Devin CLI - Live Status Dashboard

Usage: ralph-devin-monitor [OPTIONS]

Options:
    -r, --refresh SEC   Set refresh interval (default: $REFRESH_INTERVAL)
    -h, --help          Show this help message

The monitor displays:
    - Current loop count and status
    - Devin session info
    - API calls used vs. limit
    - Circuit breaker state
    - Recent log entries
    - Rate limit countdown

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -r|--refresh) REFRESH_INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check if this is a Ralph project
if [[ ! -d "$RALPH_DIR" ]]; then
    echo "Error: Not a Ralph project directory (no .ralph/ found)"
    echo "Run 'ralph-devin-enable' or 'ralph-devin-setup' first"
    exit 1
fi

# Main monitor loop
while true; do
    clear

    echo -e "${BOLD}${PURPLE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${PURPLE}║         Ralph Monitor (Devin CLI Engine)             ║${NC}"
    echo -e "${BOLD}${PURPLE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Read status file
    if [[ -f "$STATUS_FILE" ]]; then
        local_status=$(cat "$STATUS_FILE" 2>/dev/null)

        loop_count=$(echo "$local_status" | jq -r '.loop_count // 0' 2>/dev/null || echo "0")
        calls_made=$(echo "$local_status" | jq -r '.calls_made_this_hour // 0' 2>/dev/null || echo "0")
        max_calls=$(echo "$local_status" | jq -r '.max_calls_per_hour // 100' 2>/dev/null || echo "100")
        status=$(echo "$local_status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        last_action=$(echo "$local_status" | jq -r '.last_action // "none"' 2>/dev/null || echo "none")
        exit_reason=$(echo "$local_status" | jq -r '.exit_reason // ""' 2>/dev/null || echo "")
        devin_session=$(echo "$local_status" | jq -r '.devin_session_id // ""' 2>/dev/null || echo "")
        next_reset=$(echo "$local_status" | jq -r '.next_reset // ""' 2>/dev/null || echo "")
        timestamp=$(echo "$local_status" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
        engine=$(echo "$local_status" | jq -r '.engine // "devin"' 2>/dev/null || echo "devin")

        # Status color
        case "$status" in
            running|success) status_color=$GREEN ;;
            halted|error|failed) status_color=$RED ;;
            paused|waiting) status_color=$YELLOW ;;
            completed) status_color=$CYAN ;;
            *) status_color=$NC ;;
        esac

        echo -e "  ${BOLD}Engine:${NC}     ${PURPLE}$engine${NC}"
        echo -e "  ${BOLD}Status:${NC}     ${status_color}${status}${NC}"
        echo -e "  ${BOLD}Loop:${NC}       #${loop_count}"
        echo -e "  ${BOLD}API Calls:${NC}  ${calls_made}/${max_calls} this hour"
        echo -e "  ${BOLD}Action:${NC}     ${last_action}"

        if [[ -n "$devin_session" ]]; then
            echo -e "  ${BOLD}Session:${NC}    ${devin_session:0:30}..."
        fi

        if [[ -n "$exit_reason" && "$exit_reason" != "null" && "$exit_reason" != "" ]]; then
            echo -e "  ${BOLD}Exit:${NC}       ${YELLOW}${exit_reason}${NC}"
        fi

        if [[ -n "$next_reset" && "$next_reset" != "null" ]]; then
            echo -e "  ${BOLD}Next Reset:${NC} ${next_reset}"
        fi

        if [[ -n "$timestamp" && "$timestamp" != "null" ]]; then
            echo -e "  ${BOLD}Updated:${NC}    ${timestamp}"
        fi
    else
        echo -e "  ${YELLOW}No status file found. Ralph Devin may not be running.${NC}"
    fi

    echo ""

    # Circuit breaker status
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        cb_trips=$(jq -r '.trip_count // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)

        case "$cb_state" in
            CLOSED) cb_color=$GREEN ;;
            HALF_OPEN) cb_color=$YELLOW ;;
            OPEN) cb_color=$RED ;;
            *) cb_color=$NC ;;
        esac

        echo -e "  ${BOLD}Circuit Breaker:${NC} ${cb_color}${cb_state}${NC} (trips: ${cb_trips})"
    fi

    # Worktree status
    if [[ -f "$STATUS_FILE" ]]; then
        wt_enabled=$(echo "$local_status" | jq -r '.worktree_enabled // false' 2>/dev/null || echo "false")
        wt_branch=$(echo "$local_status" | jq -r '.worktree_branch // ""' 2>/dev/null || echo "")
        wt_path=$(echo "$local_status" | jq -r '.worktree_path // ""' 2>/dev/null || echo "")

        if [[ "$wt_enabled" == "true" ]]; then
            echo -e "  ${BOLD}Worktree:${NC}       ${GREEN}enabled${NC}"
            if [[ -n "$wt_branch" && "$wt_branch" != "null" ]]; then
                echo -e "  ${BOLD}WT Branch:${NC}      ${CYAN}${wt_branch}${NC}"
            fi
            if [[ -n "$wt_path" && "$wt_path" != "null" ]]; then
                echo -e "  ${BOLD}WT Path:${NC}        ${wt_path}"
            fi
        else
            echo -e "  ${BOLD}Worktree:${NC}       ${YELLOW}disabled${NC}"
        fi
    fi

    # Devin session info
    if [[ -f "$RALPH_DIR/.devin_session_id" ]]; then
        devin_sid=$(cat "$RALPH_DIR/.devin_session_id" 2>/dev/null)
        if [[ -n "$devin_sid" ]]; then
            echo -e "  ${BOLD}Devin Session ID:${NC} ${CYAN}${devin_sid}${NC}"
        fi
    fi

    echo ""
    echo -e "${BOLD}━━━ Recent Log Entries ━━━${NC}"

    if [[ -f "$LOG_FILE" ]]; then
        tail -15 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
            # Colorize log levels
            if echo "$line" | grep -q "\[ERROR\]"; then
                echo -e "  ${RED}${line}${NC}"
            elif echo "$line" | grep -q "\[WARN\]"; then
                echo -e "  ${YELLOW}${line}${NC}"
            elif echo "$line" | grep -q "\[SUCCESS\]"; then
                echo -e "  ${GREEN}${line}${NC}"
            elif echo "$line" | grep -q "\[LOOP\]"; then
                echo -e "  ${PURPLE}${line}${NC}"
            else
                echo "  ${line}"
            fi
        done
    else
        echo -e "  ${YELLOW}No log file found${NC}"
    fi

    echo ""
    echo -e "${BOLD}━━━ Fix Plan Progress ━━━${NC}"

    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        completed=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        remaining=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        total=$((completed + remaining))

        if [[ $total -gt 0 ]]; then
            pct=$((completed * 100 / total))
            # Progress bar
            bar_len=30
            filled=$((pct * bar_len / 100))
            empty=$((bar_len - filled))

            printf "  ["
            printf "${GREEN}"
            for ((i=0; i<filled; i++)); do printf "█"; done
            printf "${NC}"
            for ((i=0; i<empty; i++)); do printf "░"; done
            printf "] ${pct}%% (${completed}/${total})\n"
        else
            echo "  No tasks found"
        fi
    else
        echo -e "  ${YELLOW}No fix_plan.md found${NC}"
    fi

    echo ""
    echo -e "${BLUE}Refreshing every ${REFRESH_INTERVAL}s | Press Ctrl+C to exit${NC}"

    sleep "$REFRESH_INTERVAL"
done
