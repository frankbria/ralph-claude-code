#!/bin/bash

# Ralph Import for Devin CLI - Convert PRDs to Ralph format using Devin
# Parallel to ralph_import.sh (Claude Code) — uses Devin sessions for conversion
#
# Version: 0.1.0

set -e

# Source Devin adapter
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Minimal RALPH_DIR for adapter
RALPH_DIR=".ralph"

source "$SCRIPT_DIR/lib/devin_adapter.sh"

# Configuration
DEVIN_TIMEOUT_MINUTES=15

# Temporary files
CONVERSION_OUTPUT_FILE=".ralph_devin_conversion_output.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
    esac

    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

show_help() {
    cat << EOF
Ralph Import for Devin CLI - Convert PRDs to Ralph format

Usage: ralph-devin-import [OPTIONS] <prd-file> [project-name]

Arguments:
    prd-file        Path to PRD/requirements document
    project-name    Target project name (optional, derived from filename)

Options:
    --print         Non-interactive mode (output to stdout)
    --timeout MIN   Set Devin session timeout (default: $DEVIN_TIMEOUT_MINUTES)
    -h, --help      Show this help message

Supported formats:
    .md, .txt, .json, .docx, .pdf, or any text-based format

Examples:
    ralph-devin-import product-requirements.md my-app
    ralph-devin-import requirements.txt webapp
    ralph-devin-import --print api-spec.json

EOF
}

# Parse arguments
PRINT_MODE=false
PRD_FILE=""
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --print)
            PRINT_MODE=true
            shift
            ;;
        --timeout)
            DEVIN_TIMEOUT_MINUTES="$2"
            shift 2
            ;;
        *)
            if [[ -z "$PRD_FILE" ]]; then
                PRD_FILE="$1"
            elif [[ -z "$PROJECT_NAME" ]]; then
                PROJECT_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Validate inputs
if [[ -z "$PRD_FILE" ]]; then
    log "ERROR" "No PRD file specified"
    show_help
    exit 1
fi

# Handle relative and absolute paths
if [[ "$PRD_FILE" != /* ]]; then
    PRD_FILE="$(pwd)/$PRD_FILE"
fi

if [[ ! -f "$PRD_FILE" ]]; then
    log "ERROR" "PRD file not found: $PRD_FILE"
    exit 1
fi

# Derive project name from filename if not provided
if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME=$(basename "$PRD_FILE" | sed 's/\.[^.]*$//' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
fi

log "INFO" "Converting PRD to Ralph format using Devin CLI..."
log "INFO" "Source: $PRD_FILE"
log "INFO" "Project: $PROJECT_NAME"

# Check Devin CLI
if ! check_devin_cli; then
    exit 1
fi

# Read PRD content
PRD_CONTENT=$(cat "$PRD_FILE")

# Build conversion prompt
CONVERSION_PROMPT="You are converting a PRD/requirements document into a structured Ralph project format.

Read the following document and create these files for a project called '$PROJECT_NAME':

1. .ralph/PROMPT.md - Main development instructions derived from the PRD
2. .ralph/fix_plan.md - Prioritized task list with markdown checkboxes
3. .ralph/specs/requirements.md - Technical specifications extracted from the document

## Document Content:

$PRD_CONTENT

## Output Format:

Create the files with clear section separators. Use this exact format:

=== FILE: .ralph/PROMPT.md ===
[content]

=== FILE: .ralph/fix_plan.md ===
[content with - [ ] checkbox items]

=== FILE: .ralph/specs/requirements.md ===
[content]

## Guidelines:
- PROMPT.md should be actionable development instructions
- fix_plan.md should have prioritized tasks as markdown checkboxes (- [ ] task)
- specs/requirements.md should contain technical details and acceptance criteria
- Preserve the original intent and requirements
- Make tasks specific and implementable

RALPH_STATUS
STATUS: COMPLETE
EXIT_SIGNAL: true
SUMMARY: PRD conversion complete
"

# Create project directory
log "INFO" "Creating project directory: $PROJECT_NAME"
mkdir -p "$PROJECT_NAME"
mkdir -p "$PROJECT_NAME/.ralph/"{specs/stdlib,examples,logs,docs/generated}
mkdir -p "$PROJECT_NAME/src"

# Create Devin session for conversion
log "INFO" "Creating Devin session for PRD conversion..."
local_output_file="$PROJECT_NAME/$CONVERSION_OUTPUT_FILE"

timeout_seconds=$((DEVIN_TIMEOUT_MINUTES * 60))

session_id=$(devin_create_session "$CONVERSION_PROMPT" "Ralph Import: $PROJECT_NAME" "" "")
create_exit=$?

if [[ $create_exit -ne 0 || -z "$session_id" ]]; then
    log "ERROR" "Failed to create Devin session for conversion"
    exit 1
fi

log "SUCCESS" "Devin session created: ${session_id:0:20}..."
log "INFO" "Waiting for conversion to complete..."

# Poll for completion
devin_poll_session "$session_id" "$local_output_file" "$timeout_seconds" ""
poll_exit=$?

if [[ $poll_exit -ne 0 ]]; then
    log "ERROR" "Devin conversion session failed or timed out"
    log "INFO" "You can check the session at: devin open $session_id"
    exit 1
fi

log "SUCCESS" "Devin conversion completed"

# Parse output and create files
output_content=$(devin_extract_result_text "$local_output_file")

if [[ -n "$output_content" ]]; then
    # Extract individual files from the output
    if echo "$output_content" | grep -q "=== FILE:"; then
        # Parse structured output
        local current_file=""
        local current_content=""

        while IFS= read -r line; do
            if [[ "$line" =~ ^"=== FILE: "(.*)" ===" ]]; then
                # Save previous file
                if [[ -n "$current_file" && -n "$current_content" ]]; then
                    mkdir -p "$PROJECT_NAME/$(dirname "$current_file")"
                    echo "$current_content" > "$PROJECT_NAME/$current_file"
                    log "SUCCESS" "Created: $current_file"
                fi
                current_file="${BASH_REMATCH[1]}"
                current_content=""
            else
                current_content+="$line"$'\n'
            fi
        done <<< "$output_content"

        # Save last file
        if [[ -n "$current_file" && -n "$current_content" ]]; then
            mkdir -p "$PROJECT_NAME/$(dirname "$current_file")"
            echo "$current_content" > "$PROJECT_NAME/$current_file"
            log "SUCCESS" "Created: $current_file"
        fi
    else
        # Fallback: save raw output as PROMPT.md
        echo "$output_content" > "$PROJECT_NAME/.ralph/PROMPT.md"
        log "WARN" "Could not parse structured output, saved as PROMPT.md"
    fi
fi

# Ensure required files exist with defaults
if [[ ! -f "$PROJECT_NAME/.ralph/PROMPT.md" ]]; then
    # Copy from templates
    if [[ -f "$HOME/.ralph/templates/PROMPT.md" ]]; then
        cp "$HOME/.ralph/templates/PROMPT.md" "$PROJECT_NAME/.ralph/PROMPT.md"
    else
        echo "# $PROJECT_NAME" > "$PROJECT_NAME/.ralph/PROMPT.md"
        echo "" >> "$PROJECT_NAME/.ralph/PROMPT.md"
        echo "## Requirements" >> "$PROJECT_NAME/.ralph/PROMPT.md"
        echo "Imported from: $(basename "$PRD_FILE")" >> "$PROJECT_NAME/.ralph/PROMPT.md"
    fi
fi

if [[ ! -f "$PROJECT_NAME/.ralph/fix_plan.md" ]]; then
    if [[ -f "$HOME/.ralph/templates/fix_plan.md" ]]; then
        cp "$HOME/.ralph/templates/fix_plan.md" "$PROJECT_NAME/.ralph/fix_plan.md"
    else
        echo "# Fix Plan" > "$PROJECT_NAME/.ralph/fix_plan.md"
        echo "" >> "$PROJECT_NAME/.ralph/fix_plan.md"
        echo "- [ ] Review imported requirements" >> "$PROJECT_NAME/.ralph/fix_plan.md"
        echo "- [ ] Implement initial structure" >> "$PROJECT_NAME/.ralph/fix_plan.md"
    fi
fi

if [[ ! -f "$PROJECT_NAME/.ralph/AGENT.md" ]]; then
    if [[ -f "$HOME/.ralph/templates/AGENT.md" ]]; then
        cp "$HOME/.ralph/templates/AGENT.md" "$PROJECT_NAME/.ralph/AGENT.md"
    fi
fi

# Generate Devin-specific .ralphrc.devin (separate from Claude's .ralphrc)
cat > "$PROJECT_NAME/.ralphrc.devin" << RALPHRCEOF
# .ralphrc.devin - Ralph project configuration (Devin CLI)
# Generated by: ralph-devin-import
# Source: $(basename "$PRD_FILE")

# Project identification
PROJECT_NAME="${PROJECT_NAME}"
PROJECT_TYPE="generic"

# Engine selection
RALPH_ENGINE="devin"

# Loop settings
MAX_CALLS_PER_HOUR=100
DEVIN_TIMEOUT_MINUTES=30

# Session management
DEVIN_USE_CONTINUE=true
DEVIN_SESSION_EXPIRY_HOURS=24

# Polling configuration
DEVIN_POLL_INTERVAL=15
DEVIN_MAX_POLL_ATTEMPTS=240

# Task sources
TASK_SOURCES="local"

# Circuit breaker thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_OUTPUT_DECLINE_THRESHOLD=70
RALPHRCEOF

# Initialize git
cd "$PROJECT_NAME"
if [[ ! -d ".git" ]]; then
    git init
fi
echo "# $PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph+Devin project from PRD import"
cd ..

# Clean up temp files
rm -f "$local_output_file"

log "SUCCESS" "Project '$PROJECT_NAME' created with Devin CLI support!"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_NAME"
echo "  2. Review .ralph/PROMPT.md and .ralph/fix_plan.md"
echo "  3. Run: ralph-devin --monitor"
