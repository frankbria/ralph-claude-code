#!/bin/bash

# Ralph Planning Mode - PRD-driven fix_plan.md builder
# Scans PRDs, beads, and JSON specs to build/update fix_plan.md
# Does NOT execute tasks - planning only
#
# Usage: ralph_plan.sh [options]
#   --prd-dir <dir>    Directory containing PRD files (interactive if omitted)
#   --no-beads         Skip beads scanning
#   --no-json          Skip JSON spec scanning
#   --dry-run          Show what would be planned without writing
#   --help             Show help
#
# Version: 0.1.0

set -e

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/task_sources.sh"

# Configuration
RALPH_DIR=".ralph"
CONSTITUTION_FILE="$RALPH_DIR/constitution.md"
FIX_PLAN_FILE="$RALPH_DIR/fix_plan.md"
SPECS_DIR="$RALPH_DIR/specs"
PROMPT_PLAN_FILE="$RALPH_DIR/PROMPT_PLAN.md"
LOG_DIR="$RALPH_DIR/logs"

# Planning mode settings
PRD_DIR=""
SKIP_BEADS=false
SKIP_JSON=false
DRY_RUN=false
USE_AI=false
CLAUDE_CODE_CMD="claude"

# Modern CLI Configuration (matches ralph_import.sh)
# Use bash array for proper quoting of each tool argument
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
        "SCAN")    color=$CYAN ;;
    esac

    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_DIR/ralph_plan.log"
}

show_help() {
    cat << 'HELPEOF'
Ralph Planning Mode - Build fix_plan.md from PRDs, Beads & JSON specs

Usage: ralph-plan [options]

Options:
    --prd-dir <dir>    Directory containing PRD files
                       (interactive prompt if omitted, remembers in constitution.md)
    --no-beads         Skip beads scanning
    --no-json          Skip JSON spec scanning
    --ai               Use Claude AI to intelligently analyze and prioritize PRDs
    --dry-run          Show what would be planned without writing files
    -h, --help         Show this help

Examples:
    ralph-plan                          # Interactive - asks for PRD directory
    ralph-plan --prd-dir ./docs/prds    # Scan specific directory
    ralph-plan --ai                     # Use AI for deep PRD analysis
    ralph-plan --prd-dir ./specs --ai   # AI analysis on specific directory
    ralph-plan --dry-run                # Preview without writing

What it does:
    1. Scans PRD documents (.md, .txt, .json) from configured directory
    2. Scans beads (.beads/) for open tasks
    3. Scans JSON specs (.ralph/specs/) for requirements
    4. Deduplicates and prioritizes all tasks
    5. Builds/updates .ralph/fix_plan.md
    6. Updates .ralph/constitution.md with PRD directory and project context

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
# PRD SCANNING
# =============================================================================

# Scan PRD directory for requirement documents
# Outputs: task lines in markdown checkbox format
scan_prd_directory() {
    local dir=$1
    local all_tasks=""
    local file_count=0

    echo "[SCAN] Scanning PRD directory: $dir" >&2

    # Find PRD files (.md, .txt, .json, .pdf)
    local prd_files
    prd_files=$(find "$dir" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | sort)

    if [[ -z "$prd_files" ]]; then
        echo "[SCAN] No PRD files found in $dir" >&2
        return
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        file_count=$((file_count + 1))
        local basename
        basename=$(basename "$file")
        echo "[SCAN]   Reading: $basename" >&2

        # Extract tasks based on file type
        local extension="${file##*.}"
        local tasks=""

        case "$extension" in
            md|txt)
                tasks=$(extract_prd_tasks "$file" 2>/dev/null || echo "")
                ;;
            json)
                tasks=$(extract_json_tasks "$file" 2>/dev/null || echo "")
                ;;
        esac

        if [[ -n "$tasks" ]]; then
            all_tasks="${all_tasks}
${tasks}"
        fi
    done <<< "$prd_files"

    echo "[SCAN] Scanned $file_count PRD files" >&2

    if [[ -n "$all_tasks" ]]; then
        echo "$all_tasks"
    fi
}

# Extract tasks from JSON files (beads format, custom task format, etc.)
extract_json_tasks() {
    local json_file=$1

    if [[ ! -f "$json_file" ]] || ! command -v jq &>/dev/null; then
        return 0
    fi

    # Validate JSON
    if ! jq empty "$json_file" 2>/dev/null; then
        return 0
    fi

    local tasks=""

    # Try common JSON task formats:

    # Format 1: Array of objects with title/description/name
    local array_tasks
    array_tasks=$(jq -r '
        if type == "array" then
            .[] |
            select(type == "object") |
            "- [ ] " + (.title // .name // .description // .task // empty)
        else
            empty
        end
    ' "$json_file" 2>/dev/null)

    if [[ -n "$array_tasks" ]]; then
        tasks="$array_tasks"
    fi

    # Format 2: Object with tasks/items/stories array
    if [[ -z "$tasks" ]]; then
        local nested_tasks
        nested_tasks=$(jq -r '
            (.tasks // .items // .stories // .requirements // .features // []) |
            if type == "array" then
                .[] |
                if type == "string" then
                    "- [ ] " + .
                elif type == "object" then
                    "- [ ] " + (.title // .name // .description // .task // empty)
                else
                    empty
                end
            else
                empty
            end
        ' "$json_file" 2>/dev/null)

        if [[ -n "$nested_tasks" ]]; then
            tasks="$nested_tasks"
        fi
    fi

    # Format 3: Beads-style with id + title
    if [[ -z "$tasks" ]]; then
        local beads_tasks
        beads_tasks=$(jq -r '
            if type == "array" then
                .[] |
                select(type == "object" and ((.id // "") != "") and ((.title // "") != "")) |
                "- [ ] [\(.id)] \(.title)"
            else
                empty
            end
        ' "$json_file" 2>/dev/null)

        if [[ -n "$beads_tasks" ]]; then
            tasks="$beads_tasks"
        fi
    fi

    if [[ -n "$tasks" ]]; then
        echo "$tasks"
    fi
}

# =============================================================================
# BEADS SCANNING
# =============================================================================

scan_beads() {
    if [[ "$SKIP_BEADS" == "true" ]]; then
        echo "[INFO] Skipping beads scan (--no-beads)" >&2
        return
    fi

    if ! check_beads_available 2>/dev/null; then
        echo "[INFO] No beads found (.beads/ directory or bd command not available)" >&2
        return
    fi

    echo "[SCAN] Scanning beads for open tasks..." >&2

    local beads_tasks
    beads_tasks=$(fetch_beads_tasks "open" 2>/dev/null || echo "")

    if [[ -n "$beads_tasks" ]]; then
        local count
        count=$(echo "$beads_tasks" | grep -c '^\- \[' || echo "0")
        echo "[SCAN] Found $count open beads" >&2
        echo "$beads_tasks"
    else
        echo "[INFO] No open beads found" >&2
    fi
}

# =============================================================================
# JSON SPEC SCANNING
# =============================================================================

scan_json_specs() {
    if [[ "$SKIP_JSON" == "true" ]]; then
        echo "[INFO] Skipping JSON spec scan (--no-json)" >&2
        return
    fi

    local all_tasks=""

    # Scan .ralph/specs/ for JSON files
    if [[ -d "$SPECS_DIR" ]]; then
        local json_files
        json_files=$(find "$SPECS_DIR" -maxdepth 2 -name "*.json" -type f 2>/dev/null)

        if [[ -n "$json_files" ]]; then
            echo "[SCAN] Scanning JSON specs in $SPECS_DIR..." >&2
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                local basename
                basename=$(basename "$file")
                echo "[SCAN]   Reading: $basename" >&2

                local tasks
                tasks=$(extract_json_tasks "$file" 2>/dev/null || echo "")
                if [[ -n "$tasks" ]]; then
                    all_tasks="${all_tasks}
${tasks}"
                fi
            done <<< "$json_files"
        fi
    fi

    # Also check for prd.json or tasks.json in project root
    for root_json in "prd.json" "tasks.json" "requirements.json" "stories.json" "backlog.json"; do
        if [[ -f "$root_json" ]]; then
            echo "[SCAN] Found $root_json in project root" >&2
            local tasks
            tasks=$(extract_json_tasks "$root_json" 2>/dev/null || echo "")
            if [[ -n "$tasks" ]]; then
                all_tasks="${all_tasks}
${tasks}"
            fi
        fi
    done

    if [[ -n "$all_tasks" ]]; then
        echo "$all_tasks"
    fi
}

# =============================================================================
# FIX PLAN GENERATION
# =============================================================================

# Deduplicate tasks by content similarity
deduplicate_tasks() {
    local tasks=$1

    if [[ -z "$tasks" ]]; then
        return
    fi

    # Simple dedup: normalize and remove exact duplicates
    echo "$tasks" | grep -v '^$' | sort -u
}

# Merge new tasks with existing fix_plan.md (preserve completed items)
merge_with_existing_plan() {
    local new_tasks=$1
    local timestamp
    timestamp=$(get_iso_timestamp)

    # Read existing completed items
    local completed_items=""
    if [[ -f "$FIX_PLAN_FILE" ]]; then
        completed_items=$(grep -E '^\s*- \[[xX]\]' "$FIX_PLAN_FILE" 2>/dev/null || echo "")
    fi

    # Read existing uncompleted items (to avoid duplicating)
    local existing_uncompleted=""
    if [[ -f "$FIX_PLAN_FILE" ]]; then
        existing_uncompleted=$(grep -E '^\s*- \[ \]' "$FIX_PLAN_FILE" 2>/dev/null || echo "")
    fi

    # Filter out tasks that already exist in uncompleted or completed
    local filtered_new=""
    if [[ -n "$new_tasks" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ ! "$line" =~ ^-[[:space:]]*\[ ]] && continue

            # Extract task description (after checkbox and optional [ref])
            local task_text
            task_text=$(echo "$line" | sed 's/^- \[.\] //' | sed 's/^\[[^]]*\] //')

            # Check if similar task exists (case-insensitive substring match)
            local task_lower
            task_lower=$(echo "$task_text" | tr '[:upper:]' '[:lower:]')

            local found=false
            if [[ -n "$existing_uncompleted" ]]; then
                local existing_lower
                existing_lower=$(echo "$existing_uncompleted" | tr '[:upper:]' '[:lower:]')
                if echo "$existing_lower" | grep -qF "$task_lower"; then
                    found=true
                fi
            fi
            if [[ "$found" == "false" ]] && [[ -n "$completed_items" ]]; then
                local completed_lower
                completed_lower=$(echo "$completed_items" | tr '[:upper:]' '[:lower:]')
                if echo "$completed_lower" | grep -qF "$task_lower"; then
                    found=true
                fi
            fi

            if [[ "$found" == "false" ]]; then
                filtered_new="${filtered_new}
${line}"
            fi
        done <<< "$new_tasks"
    fi

    # Combine existing uncompleted + new filtered tasks
    local all_uncompleted=""
    if [[ -n "$existing_uncompleted" ]]; then
        all_uncompleted="$existing_uncompleted"
    fi
    if [[ -n "$filtered_new" ]]; then
        all_uncompleted="${all_uncompleted}
${filtered_new}"
    fi

    # Prioritize all uncompleted tasks
    local prioritized
    prioritized=$(prioritize_tasks "$all_uncompleted" 2>/dev/null || echo "$all_uncompleted")

    echo "$prioritized"
    echo ""
    echo "## Completed"
    if [[ -n "$completed_items" ]]; then
        echo "$completed_items"
    else
        echo "- [x] Project initialization"
    fi
}

# Write the final fix_plan.md
write_fix_plan() {
    local prioritized_content=$1
    local sources_summary=$2
    local timestamp
    timestamp=$(get_iso_timestamp)

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}=== DRY RUN - Would write to $FIX_PLAN_FILE ===${NC}"
        echo ""
        echo "# Ralph Fix Plan"
        echo ""
        echo "> Last planned: $timestamp"
        echo "> Sources: $sources_summary"
        echo ""
        echo "$prioritized_content"
        echo ""
        echo "## Notes"
        echo "- Generated by Ralph Planning Mode"
        echo "- Review and adjust priorities before running ralph"
        return
    fi

    cat > "$FIX_PLAN_FILE" << PLANEOF
# Ralph Fix Plan

> Last planned: $timestamp
> Sources: $sources_summary

$prioritized_content

## Notes
- Generated by Ralph Planning Mode
- Review and adjust priorities before running ralph
- Run \`ralph-plan\` again to refresh from PRDs and beads
PLANEOF

    log "SUCCESS" "Written fix_plan.md with updated plan"
}

# =============================================================================
# AI-ASSISTED PLANNING (optional --ai flag)
# =============================================================================

run_ai_planning() {
    local prd_dir=$1

    if ! command -v "$CLAUDE_CODE_CMD" &>/dev/null 2>&1; then
        log "WARN" "Claude CLI not found, falling back to basic scanning"
        return 1
    fi

    log "PLAN" "Running AI-assisted planning with Claude..."

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
        log "WARN" "Planning prompt template not found, falling back to basic scanning"
        return 1
    fi

    # Build context for Claude
    local context="PRD Directory: $prd_dir"
    context+="\nProject Root: $(pwd)"

    # List PRD files
    local prd_list
    prd_list=$(find "$prd_dir" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | sort)
    if [[ -n "$prd_list" ]]; then
        context+="\n\nPRD Files Found:\n$prd_list"
    fi

    # Check beads
    if [[ "$SKIP_BEADS" != "true" ]] && check_beads_available 2>/dev/null; then
        local beads_count
        beads_count=$(get_beads_count 2>/dev/null || echo "0")
        context+="\n\nBeads: $beads_count open tasks in .beads/"
    fi

    # Build prompt file for Claude (file redirection, not pipe, to avoid hangs)
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

    local stderr_file="$RALPH_DIR/.plan_stderr"
    local output_file="$RALPH_DIR/.plan_output.json"
    local cli_exit_code=0

    # Use file redirection (< file) instead of pipe to prevent interactive hangs
    # Use bash array for --allowedTools (same pattern as ralph_import.sh)
    # --print: Required for non-interactive piped input
    # --strict-mcp-config: Skip loading user MCP servers (faster startup)
    log "PLAN" "Invoking Claude CLI for AI planning..."
    if $CLAUDE_CODE_CMD --print --strict-mcp-config --output-format json \
        --allowedTools "${CLAUDE_ALLOWED_TOOLS[@]}" \
        < "$prompt_file" > "$output_file" 2> "$stderr_file"; then
        cli_exit_code=0
    else
        cli_exit_code=$?
    fi

    # Log stderr if present (for debugging)
    if [[ -s "$stderr_file" ]]; then
        log "WARN" "CLI stderr output detected (see $stderr_file)"
    fi

    # Clean up prompt input
    rm -f "$prompt_file"

    # Check if Claude wrote the files
    if [[ $cli_exit_code -eq 0 ]] && [[ -f "$FIX_PLAN_FILE" ]]; then
        log "SUCCESS" "AI planning completed - fix_plan.md updated"
        rm -f "$output_file" "$stderr_file"
        return 0
    fi

    log "WARN" "AI planning did not produce expected output (exit code: $cli_exit_code), falling back to basic scanning"
    rm -f "$output_file" "$stderr_file"
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
            --no-beads)
                SKIP_BEADS=true
                shift
                ;;
            --no-json)
                SKIP_JSON=true
                shift
                ;;
            --ai)
                USE_AI=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
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
    mkdir -p "$RALPH_DIR" "$SPECS_DIR" "$LOG_DIR"

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

    # Step 2: If --ai flag, try AI-assisted planning first
    if [[ "$USE_AI" == "true" ]]; then
        if run_ai_planning "$PRD_DIR"; then
            # AI handled everything, update constitution and exit
            local prd_count
            prd_count=$(find "$PRD_DIR" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | wc -l | tr -d ' ')
            local beads_count="0"
            if [[ "$SKIP_BEADS" != "true" ]] && check_beads_available 2>/dev/null; then
                beads_count=$(get_beads_count 2>/dev/null || echo "0")
            fi
            update_constitution "$PRD_DIR" "$prd_count files" "$beads_count" "0" "AI-generated"
            echo ""
            log "SUCCESS" "Planning complete (AI-assisted)"
            echo ""
            echo "Next steps:"
            echo "  1. Review .ralph/fix_plan.md"
            echo "  2. Review .ralph/constitution.md"
            echo "  3. Run 'ralph --monitor' to start execution"
            exit 0
        fi
        log "INFO" "Falling back to basic scanning..."
    fi

    # Step 3: Scan all sources
    echo ""
    log "PLAN" "Phase 1: Scanning PRDs..."
    local prd_tasks
    prd_tasks=$(scan_prd_directory "$PRD_DIR" 2>/dev/null || echo "")
    local prd_file_count
    prd_file_count=$(find "$PRD_DIR" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | wc -l | tr -d ' ')

    log "PLAN" "Phase 2: Scanning beads..."
    local beads_tasks
    beads_tasks=$(scan_beads 2>/dev/null || echo "")
    local beads_count="0"
    if [[ -n "$beads_tasks" ]]; then
        beads_count=$(echo "$beads_tasks" | grep -c '^\- \[' 2>/dev/null || echo "0")
    fi

    log "PLAN" "Phase 3: Scanning JSON specs..."
    local json_tasks
    json_tasks=$(scan_json_specs 2>/dev/null || echo "")
    local json_count="0"
    if [[ -n "$json_tasks" ]]; then
        json_count=$(echo "$json_tasks" | grep -c '^\- \[' 2>/dev/null || echo "0")
    fi

    # Step 4: Combine all tasks
    echo ""
    log "PLAN" "Phase 4: Merging and deduplicating tasks..."

    local all_new_tasks=""
    [[ -n "$prd_tasks" ]] && all_new_tasks="${all_new_tasks}${prd_tasks}"
    [[ -n "$beads_tasks" ]] && all_new_tasks="${all_new_tasks}
${beads_tasks}"
    [[ -n "$json_tasks" ]] && all_new_tasks="${all_new_tasks}
${json_tasks}"

    # Normalize tasks
    local normalized
    normalized=$(normalize_tasks "$all_new_tasks" "planning" 2>/dev/null || echo "$all_new_tasks")

    # Deduplicate
    local deduped
    deduped=$(deduplicate_tasks "$normalized")

    # Step 5: Merge with existing plan
    local merged_content
    merged_content=$(merge_with_existing_plan "$deduped")

    # Count total new tasks
    local new_task_count="0"
    if [[ -n "$deduped" ]]; then
        new_task_count=$(echo "$deduped" | grep -c '^\- \[' || echo "0")
    fi

    # Build sources summary
    local sources_summary="$prd_file_count PRD files from $PRD_DIR"
    [[ "$beads_count" != "0" ]] && sources_summary="$sources_summary, $beads_count beads"
    [[ "$json_count" != "0" ]] && sources_summary="$sources_summary, $json_count JSON tasks"

    # Step 6: Write fix_plan.md
    echo ""
    log "PLAN" "Phase 5: Writing fix_plan.md..."
    write_fix_plan "$merged_content" "$sources_summary"

    # Step 7: Update constitution
    if [[ "$DRY_RUN" != "true" ]]; then
        log "PLAN" "Phase 6: Updating constitution.md..."
        update_constitution "$PRD_DIR" "$prd_file_count files" "$beads_count" "$json_count" "$new_task_count"
    fi

    # Summary
    echo ""
    echo -e "${GREEN}=== Planning Summary ===${NC}"
    echo -e "  PRD files scanned:  ${CYAN}$prd_file_count${NC}"
    echo -e "  Beads found:        ${CYAN}$beads_count${NC}"
    echo -e "  JSON tasks found:   ${CYAN}$json_count${NC}"
    echo -e "  New tasks added:    ${CYAN}$new_task_count${NC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}DRY RUN - no files were modified${NC}"
    else
        log "SUCCESS" "Planning complete!"
        echo ""
        echo "Next steps:"
        echo "  1. Review .ralph/fix_plan.md"
        echo "  2. Review .ralph/constitution.md"
        echo "  3. Run 'ralph --monitor' to start execution"
        echo ""
        echo "Re-run planning anytime with: ralph-plan"
    fi
}

main "$@"
