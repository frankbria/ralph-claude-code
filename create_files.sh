#!/bin/bash

# Quick script to create all Ralph files in your GitHub repo
set -e

echo "🚀 Creating Ralph for Claude Code repository structure..."

# Create directories
mkdir -p {logs,docs/generated,specs/stdlib,src,examples,templates/specs}

# Create main scripts
cat >ralph_loop.sh <<'EOF'
#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

set -e  # Exit on any error

# Configuration
PROMPT_FILE="PROMPT.md"
LOG_DIR="logs"
DOCS_DIR="docs/generated"
STATUS_FILE="status.json"
CLAUDE_CODE_CMD="bunx @anthropic/claude-code"
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

# Cross-platform date function for calculating future times
# Works on both macOS (BSD date) and Linux (GNU date)
get_next_hour_time() {
    if date -v+1H &>/dev/null 2>&1; then
        # macOS / BSD date
        date -v+1H -Iseconds | cut -d'T' -f2 | cut -d'+' -f1
    else
        # GNU date (Linux)
        date -d '+1 hour' -Iseconds | cut -d'T' -f2 | cut -d'+' -f1
    fi
}

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
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(date -Iseconds)",
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
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    
    # Count recent signals (last 5 loops)
    local recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length')
    local recent_done_signals=$(echo "$signals" | jq '.done_signals | length')
    local recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length')
    
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
        local total_items=$(grep -c "^- \[" "@fix_plan.md" 2>/dev/null || echo "0")
        local completed_items=$(grep -c "^- \[x\]" "@fix_plan.md" 2>/dev/null || echo "0")
        
        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)"
            echo "plan_complete"
            return 0
        fi
    fi
    
    return 1  # Don't exit
}

# Main execution function
execute_claude_code() {
    local calls_made=$(increment_call_counter)
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    
    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    
    # Execute Claude Code with the prompt
    if $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1; then
        log_status "SUCCESS" "Claude Code execution completed successfully"
        
        # Extract key information from output if possible
        if grep -q "error\|Error\|ERROR" "$output_file"; then
            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        
        return 0
    else
        log_status "ERROR" "Claude Code execution failed, check: $output_file"
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

# Main loop
main() {
    local loop_count=0
    
    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"
    
    # Check if prompt file exists
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        exit 1
    fi
    
    while true; do
        ((loop_count++))
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi
        
        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ $? -eq 0 ]]; then
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

Options:
    -h, --help          Show this help message
    -c, --calls NUM     Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE   Set prompt file (default: $PROMPT_FILE)
    -s, --status        Show current status and exit

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)

Example:
    $0 --calls 50 --prompt my_prompt.md

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
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Start the main loop
main
EOF

# Create monitor script (simplified for brevity)
cat >ralph_monitor.sh <<'EOF'
#!/bin/bash

# Ralph Status Monitor - Live terminal dashboard for the Ralph loop
set -e

STATUS_FILE="status.json"
LOG_FILE="logs/ralph.log"
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
EOF

# Create setup script
cat >setup.sh <<'EOF'
#!/bin/bash

# Ralph Project Setup Script
set -e

PROJECT_NAME=${1:-"my-project"}

echo "🚀 Setting up Ralph project: $PROJECT_NAME"

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create structure
mkdir -p {specs/stdlib,src,examples,logs,docs/generated}

# Copy templates
cp ../templates/PROMPT.md .
cp ../templates/fix_plan.md @fix_plan.md
cp ../templates/AGENT.md @AGENT.md
cp -r ../templates/specs/* specs/ 2>/dev/null || true

# Initialize git
git init
echo "# $PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph project setup"

echo "✅ Project $PROJECT_NAME created!"
echo "Next steps:"
echo "  1. Edit PROMPT.md with your project requirements"
echo "  2. Update specs/ with your project specifications"  
echo "  3. Run: ../ralph_loop.sh"
echo "  4. Monitor: ../ralph_monitor.sh"
EOF

# Create template files
mkdir -p templates/specs

cat >templates/PROMPT.md <<'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a [YOUR PROJECT NAME] project.

## Current Objectives
1. Study specs/* to learn about the project specifications
2. Review @fix_plan.md for current priorities
3. Implement the highest priority item using best practices
4. Use parallel subagents for complex tasks (max 100 concurrent)
5. Run tests after each implementation
6. Update documentation and fix_plan.md

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update @fix_plan.md with your learnings
- Commit working changes with descriptive messages

## 🧪 Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop
- PRIORITIZE: Implementation > Documentation > Tests
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Do NOT add "additional test coverage" as busy work
- Focus on CORE functionality first, comprehensive testing later

## Execution Guidelines
- Before making changes: search codebase using subagents
- After implementation: run ESSENTIAL tests for the modified code only
- If tests fail: fix them as part of your current work
- Keep @AGENT.md updated with build/run instructions
- Document the WHY behind tests and implementations
- No placeholder implementations - build it properly

## Completion Awareness
If you believe the project is complete or nearly complete:
- Update @fix_plan.md to reflect completion status
- Summarize what has been accomplished
- Note any remaining minor tasks
- Do NOT continue with busy work like extensive testing
- Do NOT implement features not in the specifications

## File Structure
- specs/: Project specifications and requirements
- src/: Source code implementation  
- examples/: Example usage and test cases
- @fix_plan.md: Prioritized TODO list
- @AGENT.md: Project build and run instructions

## Current Task
Follow @fix_plan.md and choose the most important item to implement next.
Use your judgment to prioritize what will have the biggest impact on project progress.

Remember: Quality over speed. Build it right the first time. Know when you're done.
EOF

cat >templates/fix_plan.md <<'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Set up basic project structure and build system
- [ ] Define core data structures and types
- [ ] Implement basic input/output handling
- [ ] Create test framework and initial tests

## Medium Priority
- [ ] Add error handling and validation
- [ ] Implement core business logic
- [ ] Add configuration management
- [ ] Create user documentation

## Low Priority
- [ ] Performance optimization
- [ ] Extended feature set
- [ ] Integration with external services
- [ ] Advanced error recovery

## Completed
- [x] Project initialization

## Notes
- Focus on MVP functionality first
- Ensure each feature is properly tested
- Update this file after each major milestone
EOF

cat >templates/AGENT.md <<'EOF'
# Agent Build Instructions

## Project Setup
```bash
# Install dependencies (example for Node.js project)
bun install

# Or for Python project
pip install -r requirements.txt

# Or for Rust project  
cargo build
```

## Running Tests
```bash
# Node.js
bun test

# Python
pytest

# Rust
cargo test
```

## Build Commands
```bash
# Production build
bun run build
# or
cargo build --release
```

## Development Server
```bash
# Start development server
bun run dev
# or
cargo run
```

## Key Learnings
- Update this section when you learn new build optimizations
- Document any gotchas or special setup requirements
- Keep track of the fastest test/build cycle
EOF

# Create gitignore
cat >.gitignore <<'EOF'
# Ralph generated files
.call_count
.last_reset
.exit_signals
status.json

# Logs
logs/
*.log

# Generated documentation
docs/generated/

# OS files
.DS_Store
Thumbs.db

# Temporary files
*.tmp
.temp/

# Node modules (if using Node.js projects)
node_modules/

# Python cache (if using Python projects)
__pycache__/
*.pyc

# Rust build (if using Rust projects)
target/

# IDE files
.vscode/
.idea/
*.swp
*.swo
EOF

# Make scripts executable
chmod +x *.sh

echo "✅ All files created successfully!"
echo ""
echo "📁 Repository structure:"
echo "├── ralph_loop.sh          # Main Ralph loop"
echo "├── ralph_monitor.sh       # Live monitoring"
echo "├── setup.sh              # Project setup"
echo "├── templates/            # Template files"
echo "└── .gitignore           # Git ignore rules"
echo ""
echo "🚀 Next steps:"
echo "1. git add ."
echo "2. git commit -m 'Add Ralph for Claude Code implementation'"
echo "3. git push origin main"
echo "4. ./setup.sh my-first-project"
