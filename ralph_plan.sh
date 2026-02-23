#!/bin/bash

# Ralph Planning Mode - AI-powered PRD-driven fix_plan.md builder
# Uses AI (Claude/Codex/Devin) to analyze PRDs and build fix_plan.md
# Does NOT execute tasks - planning only
#
# Usage: ralph_plan.sh [options]
#   --prd-dir <dir>    Directory containing PRD files (interactive if omitted)
#   --engine <name>    AI engine: claude (default), codex, devin
#   --help             Show help
#
# Version: 0.2.0

set -e

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"

# Configuration
RALPH_DIR=".ralph"
CONSTITUTION_FILE="$RALPH_DIR/constitution.md"
FIX_PLAN_FILE="$RALPH_DIR/fix_plan.md"
PROMPT_PLAN_FILE="$RALPH_DIR/PROMPT_PLAN.md"
LOG_DIR="$RALPH_DIR/logs"

# Planning mode settings
PRD_DIR=""

# Engine selection: claude (default), codex, devin
ENGINE="claude"

# Engine CLI commands
CLAUDE_CMD="claude"
CODEX_CMD="codex"
DEVIN_CMD="devin"

# Claude-specific: allowed tools for --allowedTools flag
declare -a CLAUDE_ALLOWED_TOOLS=('Read' 'Write' 'Glob' 'Grep')

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""

    case $level in
        "INFO")    color=$BLUE ;;
        "WARN")    color=$YELLOW ;;
        "ERROR")   color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "PLAN")    color=$PURPLE ;;
    esac

    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_DIR/ralph_plan.log"
}

show_help() {
    cat << 'HELPEOF'
Ralph Planning Mode - AI-powered fix_plan.md builder

Usage: ralph-plan [options]

Options:
    --prd-dir <dir>    Directory containing PRD files
                       (interactive prompt if omitted, remembers in constitution.md)
    --engine <name>    AI engine: claude (default), codex, devin
    -h, --help         Show this help

Examples:
    ralph-plan                                  # Interactive PRD directory, Claude engine
    ralph-plan --prd-dir ./docs/prds            # Specify PRD directory
    ralph-plan --engine codex                   # Use Codex for analysis
    ralph-plan --engine devin                   # Use Devin for analysis
    ralph-plan --prd-dir ./specs --engine codex # Codex on specific directory

What it does:
    1. Asks for (or reads) your PRD directory
    2. Sends PRDs to the AI engine for deep analysis
    3. AI reads all PRD files and extracts requirements
    4. AI builds/updates .ralph/fix_plan.md with prioritized tasks
    5. AI updates .ralph/constitution.md with project context

Planning mode does NOT execute tasks - it only builds the plan.

HELPEOF
}

# =============================================================================
# CONSTITUTION MANAGEMENT
# =============================================================================

# Read PRD directory from constitution.md if it exists
read_constitution_prd_dir() {
    if [[ ! -f "$CONSTITUTION_FILE" ]]; then
        echo ""
        return
    fi

    # Extract PRD directory from constitution
    local prd_dir
    prd_dir=$(grep -E '^\- \*\*PRD Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null \
        | sed 's/.*: //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Filter out template placeholders
    if [[ "$prd_dir" == *"configured by"* ]] || [[ "$prd_dir" == *"[configured"* ]] || [[ -z "$prd_dir" ]]; then
        echo ""
        return
    fi

    echo "$prd_dir"
}

# Update constitution.md with PRD directory and planning results
update_constitution() {
    local prd_dir=$1
    local prd_files_found=$2
    local beads_count=$3
    local json_count=$4
    local tasks_generated=$5
    local timestamp
    timestamp=$(get_iso_timestamp)

    # Create constitution from template if it doesn't exist
    if [[ ! -f "$CONSTITUTION_FILE" ]]; then
        local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
        if [[ -f "$ralph_home/templates/constitution.md" ]]; then
            cp "$ralph_home/templates/constitution.md" "$CONSTITUTION_FILE"
        elif [[ -f "$SCRIPT_DIR/templates/constitution.md" ]]; then
            cp "$SCRIPT_DIR/templates/constitution.md" "$CONSTITUTION_FILE"
        else
            # Inline minimal template
            cat > "$CONSTITUTION_FILE" << 'CONSTEOF'
# Ralph Project Constitution

> This file is Ralph's project memory. Updated by Planning Mode.

## Project Identity
- **Project Name**: unknown
- **Project Type**: unknown
- **Created**: unknown
- **Last Planned**: never

## PRD Configuration
- **PRD Directory**: not configured
- **PRD Files Found**: none

## Architecture Decisions

## Technology Stack

## Constraints & Non-Functional Requirements

## Conventions

## Planning History
| Date | PRDs Scanned | Beads Found | Tasks Generated | Notes |
|------|-------------|-------------|-----------------|-------|
CONSTEOF
        fi
    fi

    # Update PRD Directory
    if grep -q '^\- \*\*PRD Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*PRD Directory\*\*:.*|- **PRD Directory**: $prd_dir|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update PRD Files Found
    if grep -q '^\- \*\*PRD Files Found\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*PRD Files Found\*\*:.*|- **PRD Files Found**: $prd_files_found|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update Last Planned timestamp
    if grep -q '^\- \*\*Last Planned\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*Last Planned\*\*:.*|- **Last Planned**: $timestamp|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Append to planning history table
    local history_line="| $timestamp | $prd_files_found | $beads_count | $tasks_generated | Planning mode run |"
    echo "$history_line" >> "$CONSTITUTION_FILE"

    log "SUCCESS" "Updated constitution.md"
}

# =============================================================================
# INTERACTIVE PRD DIRECTORY SELECTION
# =============================================================================

prompt_prd_directory() {
    echo ""
    echo -e "${PURPLE}=== Ralph Planning Mode ===${NC}"
    echo ""

    # Check if we have a remembered directory
    local remembered_dir
    remembered_dir=$(read_constitution_prd_dir)

    if [[ -n "$remembered_dir" ]] && [[ -d "$remembered_dir" ]]; then
        echo -e "Previously configured PRD directory: ${CYAN}$remembered_dir${NC}"
        echo -n "Use this directory? [Y/n]: "
        read -r use_prev
        if [[ -z "$use_prev" ]] || [[ "$use_prev" =~ ^[Yy] ]]; then
            PRD_DIR="$remembered_dir"
            return
        fi
    fi

    # Scan for likely PRD directories
    echo "Scanning project for directories that may contain PRDs..."
    echo ""

    local candidates=()
    local candidate_names=()

    # Check common PRD directory names
    local common_dirs=("docs" "prds" "specs" "requirements" "docs/prds" "docs/specs" "docs/requirements" ".ralph/specs")
    for dir in "${common_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local md_count
            md_count=$(find "$dir" -maxdepth 2 -name "*.md" -o -name "*.txt" -o -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
            if [[ $md_count -gt 0 ]]; then
                candidates+=("$dir")
                candidate_names+=("$dir ($md_count files)")
            fi
        fi
    done

    # Also check for any .md files in project root
    local root_md_count
    root_md_count=$(find . -maxdepth 1 -name "*.md" -not -name "README.md" -not -name "CHANGELOG.md" -not -name "CONTRIBUTING.md" -not -name "LICENSE*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ $root_md_count -gt 0 ]]; then
        candidates+=(".")
        candidate_names+=("Project root ($root_md_count .md files)")
    fi

    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "Found potential PRD directories:"
        echo ""
        for i in "${!candidate_names[@]}"; do
            echo -e "  ${GREEN}$((i + 1)))${NC} ${candidate_names[$i]}"
        done
        echo -e "  ${GREEN}$((${#candidates[@]} + 1)))${NC} Enter custom path"
        echo ""
        echo -n "Select directory [1-$((${#candidates[@]} + 1))]: "
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#candidates[@]} ]]; then
            PRD_DIR="${candidates[$((selection - 1))]}"
        else
            echo -n "Enter PRD directory path: "
            read -r custom_dir
            PRD_DIR="$custom_dir"
        fi
    else
        echo "No common PRD directories found."
        echo -n "Enter PRD directory path: "
        read -r custom_dir
        PRD_DIR="$custom_dir"
    fi

    # Validate
    if [[ ! -d "$PRD_DIR" ]]; then
        log "ERROR" "Directory does not exist: $PRD_DIR"
        exit 1
    fi

    echo ""
    log "INFO" "Using PRD directory: $PRD_DIR"
}

# =============================================================================
# AI PLANNING
# =============================================================================

run_ai_planning() {
    local prd_dir=$1

    # Determine CLI command based on engine
    local cli_cmd=""
    case "$ENGINE" in
        claude) cli_cmd="$CLAUDE_CMD" ;;
        codex)  cli_cmd="$CODEX_CMD" ;;
        devin)  cli_cmd="$DEVIN_CMD" ;;
        *)
            log "ERROR" "Unknown engine: $ENGINE (expected: claude, codex, devin)"
            return 1
            ;;
    esac

    if ! command -v "$cli_cmd" &>/dev/null 2>&1; then
        log "ERROR" "$ENGINE CLI ('$cli_cmd') not found. Install it first."
        return 1
    fi

    log "PLAN" "Running AI planning with $ENGINE ($cli_cmd)..."

    # Ensure planning prompt exists
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local prompt_source=""
    if [[ -f "$PROMPT_PLAN_FILE" ]]; then
        prompt_source="$PROMPT_PLAN_FILE"
    elif [[ -f "$ralph_home/templates/PROMPT_PLAN.md" ]]; then
        prompt_source="$ralph_home/templates/PROMPT_PLAN.md"
        cp "$prompt_source" "$PROMPT_PLAN_FILE"
    elif [[ -f "$SCRIPT_DIR/templates/PROMPT_PLAN.md" ]]; then
        prompt_source="$SCRIPT_DIR/templates/PROMPT_PLAN.md"
        cp "$prompt_source" "$PROMPT_PLAN_FILE"
    fi

    if [[ -z "$prompt_source" ]] && [[ ! -f "$PROMPT_PLAN_FILE" ]]; then
        log "ERROR" "Planning prompt template not found (PROMPT_PLAN.md). Run install.sh first."
        return 1
    fi

    # Build context
    local context="PRD Directory: $prd_dir"
    context+="\nProject Root: $(pwd)"

    local prd_list
    prd_list=$(find "$prd_dir" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | sort)
    if [[ -n "$prd_list" ]]; then
        context+="\n\nPRD Files Found:\n$prd_list"
    fi

    # Check for beads if available
    if [[ -d ".beads" ]] && command -v bd &>/dev/null; then
        local beads_count
        beads_count=$(bd list --json --status open 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        context+="\n\nBeads: $beads_count open tasks in .beads/"
    fi

    # Build prompt file
    local prompt_file="$RALPH_DIR/.plan_prompt_input.md"
    {
        cat "$PROMPT_PLAN_FILE"
        echo ""
        echo "---"
        echo ""
        echo "## Planning Context"
        echo -e "$context"
        echo ""
        echo "## Instructions"
        echo "Analyze the PRD files listed above. Read each one, extract requirements, and generate the fix_plan.md content."
        echo "Write directly to .ralph/fix_plan.md and .ralph/constitution.md."
    } > "$prompt_file"

    local cli_exit_code=0
    local prompt_content
    prompt_content=$(cat "$prompt_file")

    log "PLAN" "Prompt: $(wc -c < "$prompt_file" | tr -d ' ') bytes"

    # Interactive invocation with bypass permissions — no --print/-p, no stdout redirect
    # AI runs in full TUI mode so user can watch it work
    case "$ENGINE" in
        claude)
            log "PLAN" "Launching: $cli_cmd (interactive) --permission-mode bypass --allowedTools ${CLAUDE_ALLOWED_TOOLS[*]}"
            if "$cli_cmd" --permission-mode bypass --allowedTools "${CLAUDE_ALLOWED_TOOLS[@]}" "$prompt_content"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        codex)
            log "PLAN" "Launching: $cli_cmd (interactive) --permission-mode dangerous"
            if "$cli_cmd" --permission-mode dangerous "$prompt_content"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        devin)
            log "PLAN" "Launching: $cli_cmd (interactive) --permission-mode dangerous --prompt-file $prompt_file"
            if "$cli_cmd" --permission-mode dangerous --prompt-file "$prompt_file"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
    esac

    log "PLAN" "$ENGINE CLI exited with code: $cli_exit_code"

    # Clean up prompt input
    rm -f "$prompt_file"

    # Check if the AI wrote fix_plan.md
    if [[ $cli_exit_code -eq 0 ]] && [[ -f "$FIX_PLAN_FILE" ]]; then
        log "SUCCESS" "AI planning completed - fix_plan.md updated"
        return 0
    fi

    log "ERROR" "AI planning failed (exit code: $cli_exit_code). Check $ENGINE CLI output above."
    return 1
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prd-dir)
                PRD_DIR="$2"
                shift 2
                ;;
            --engine)
                ENGINE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${PURPLE}Ralph Planning Mode${NC}"
    echo -e "${PURPLE}===================${NC}"
    echo ""

    # Ensure .ralph directory exists
    mkdir -p "$RALPH_DIR" "$LOG_DIR"

    # Step 1: Determine PRD directory
    if [[ -z "$PRD_DIR" ]]; then
        prompt_prd_directory
    else
        if [[ ! -d "$PRD_DIR" ]]; then
            log "ERROR" "PRD directory does not exist: $PRD_DIR"
            exit 1
        fi
        log "INFO" "Using PRD directory: $PRD_DIR"
    fi

    # Step 2: Run AI planning
    if run_ai_planning "$PRD_DIR"; then
        # AI handled everything, update constitution
        local prd_count
        prd_count=$(find "$PRD_DIR" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | wc -l | tr -d ' ')
        update_constitution "$PRD_DIR" "$prd_count files" "0" "0" "AI-generated"
        echo ""
        log "SUCCESS" "Planning complete!"
        echo ""
        echo "Next steps:"
        echo "  1. Review .ralph/fix_plan.md"
        echo "  2. Review .ralph/constitution.md"
        echo "  3. Run 'ralph --monitor' to start execution"
        echo ""
        echo "Re-run planning anytime with: ralph-plan"
    else
        log "ERROR" "AI planning failed. Ensure your $ENGINE CLI is installed and authenticated."
        exit 1
    fi
}

main "$@"
