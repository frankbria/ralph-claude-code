#!/bin/bash

# Ralph Enable CI - Non-Interactive Version for Automation
# Adds Ralph configuration with sensible defaults
#
# Usage:
#   ralph enable-ci                    # Auto-detect and enable
#   ralph enable-ci --from beads       # With specific task source
#   ralph enable-ci --json             # Output JSON result
#
# Exit codes:
#   0 - Success
#   1 - Error
#   2 - Already enabled (use --force to override)
#
# Version: 0.11.0

set -e

# Get script directory for library loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to load libraries from global installation first, then local
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
if [[ -f "$RALPH_HOME/lib/enable_core.sh" ]]; then
    LIB_DIR="$RALPH_HOME/lib"
elif [[ -f "$SCRIPT_DIR/lib/enable_core.sh" ]]; then
    LIB_DIR="$SCRIPT_DIR/lib"
else
    echo '{"error": "Cannot find Ralph libraries", "code": 1}' >&2
    exit 1
fi

# Disable colors for CI
export ENABLE_USE_COLORS="false"

# Source libraries
source "$LIB_DIR/enable_core.sh"
source "$LIB_DIR/task_sources.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Command line options
FORCE_OVERWRITE=false
TASK_SOURCE=""
PRD_FILE=""
GITHUB_LABEL="ralph-task"
PROJECT_NAME=""
PROJECT_TYPE=""
OUTPUT_JSON=false
QUIET=false
SHOW_HELP=false

# Version
VERSION="0.11.0"

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
Ralph Enable CI - Non-Interactive Version for Automation

Usage: ralph enable-ci [OPTIONS]

Options:
    --from <source>       Import tasks from: beads, github, prd, none
    --prd <file>          PRD file to convert (when --from prd)
    --label <label>       GitHub label filter (default: ralph-task)
    --project-name <name> Override detected project name
    --project-type <type> Override detected type (typescript, python, etc.)
    --force               Overwrite existing .ralph/ configuration
    --json                Output result as JSON
    --quiet               Suppress non-error output
    -h, --help            Show this help message
    -v, --version         Show version

Exit Codes:
    0 - Success: Ralph enabled
    1 - Error: Something went wrong
    2 - Already enabled: Use --force to override

Examples:
    # Auto-detect and enable with defaults
    ralph enable-ci

    # Enable with beads tasks
    ralph enable-ci --from beads

    # Enable with GitHub issues
    ralph enable-ci --from github --label "sprint-1"

    # Enable with PRD conversion
    ralph enable-ci --from prd --prd docs/requirements.md

    # Force overwrite and output JSON
    ralph enable-ci --force --json

    # Override project detection
    ralph enable-ci --project-name my-app --project-type typescript

JSON Output Format:
    {
        "success": true,
        "project_name": "my-project",
        "project_type": "typescript",
        "files_created": [".ralph/PROMPT.md", ...],
        "tasks_imported": 15,
        "message": "Ralph enabled successfully"
    }

EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    TASK_SOURCE="$2"
                    shift 2
                else
                    output_error "Error: --from requires a source (beads, github, prd, none)"
                    exit 1
                fi
                ;;
            --prd)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    PRD_FILE="$2"
                    shift 2
                else
                    output_error "Error: --prd requires a file path"
                    exit 1
                fi
                ;;
            --label)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    GITHUB_LABEL="$2"
                    shift 2
                else
                    output_error "Error: --label requires a label name"
                    exit 1
                fi
                ;;
            --project-name)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    PROJECT_NAME="$2"
                    shift 2
                else
                    output_error "Error: --project-name requires a name"
                    exit 1
                fi
                ;;
            --project-type)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    PROJECT_TYPE="$2"
                    shift 2
                else
                    output_error "Error: --project-type requires a type"
                    exit 1
                fi
                ;;
            --force)
                FORCE_OVERWRITE=true
                shift
                ;;
            --json)
                if ! command -v jq &>/dev/null; then
                    echo "Error: --json requires jq to be installed" >&2
                    exit 1
                fi
                OUTPUT_JSON=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            -v|--version)
                if [[ "$OUTPUT_JSON" == "true" ]]; then
                    echo "{\"version\": \"$VERSION\"}"
                else
                    echo "ralph enable-ci version $VERSION"
                fi
                exit 0
                ;;
            *)
                output_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# OUTPUT FUNCTIONS
# =============================================================================

# Track created files for JSON output
declare -a CREATED_FILES=()
TASKS_IMPORTED=0

output_message() {
    if [[ "$QUIET" != "true" && "$OUTPUT_JSON" != "true" ]]; then
        echo "$1"
    fi
}

output_error() {
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        echo "{\"error\": \"$1\", \"code\": 1}" >&2
    else
        echo "Error: $1" >&2
    fi
}

output_success() {
    local project_name="$1"
    local project_type="$2"

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        local files_json
        files_json=$(printf '%s\n' "${CREATED_FILES[@]}" | jq -R . | jq -s .)

        cat << EOF
{
    "success": true,
    "project_name": "$project_name",
    "project_type": "$project_type",
    "files_created": $files_json,
    "tasks_imported": $TASKS_IMPORTED,
    "message": "Ralph enabled successfully"
}
EOF
    else
        echo "Ralph enabled successfully for: $project_name ($project_type)"
        echo "Files created: ${#CREATED_FILES[@]}"
        echo "Tasks imported: $TASKS_IMPORTED"
    fi
}

output_already_enabled() {
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        echo '{"success": false, "code": 2, "message": "Ralph already enabled. Use --force to override."}'
    else
        echo "Ralph is already enabled in this project. Use --force to override."
    fi
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"

    # Show help if requested
    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    output_message "Ralph Enable CI - Non-Interactive Mode"
    output_message ""

    # Check existing state (use || true to prevent set -e from exiting)
    check_existing_ralph || true
    if [[ "$RALPH_STATE" == "complete" && "$FORCE_OVERWRITE" != "true" ]]; then
        output_already_enabled
        exit $ENABLE_ALREADY_ENABLED
    fi

    # Detect project context
    detect_project_context
    output_message "Detected: $DETECTED_PROJECT_NAME ($DETECTED_PROJECT_TYPE)"

    # Override with CLI options if provided
    if [[ -n "$PROJECT_NAME" ]]; then
        DETECTED_PROJECT_NAME="$PROJECT_NAME"
    fi
    if [[ -n "$PROJECT_TYPE" ]]; then
        DETECTED_PROJECT_TYPE="$PROJECT_TYPE"
    fi

    # Auto-detect task source if not specified
    if [[ -z "$TASK_SOURCE" ]]; then
        detect_task_sources

        if [[ "$DETECTED_BEADS_AVAILABLE" == "true" ]]; then
            TASK_SOURCE="beads"
            output_message "Auto-detected task source: beads"
        elif [[ "$DETECTED_GITHUB_AVAILABLE" == "true" ]]; then
            TASK_SOURCE="github"
            output_message "Auto-detected task source: github"
        elif [[ ${#DETECTED_PRD_FILES[@]} -gt 0 ]]; then
            TASK_SOURCE="prd"
            PRD_FILE="${DETECTED_PRD_FILES[0]}"
            output_message "Auto-detected task source: prd ($PRD_FILE)"
        else
            TASK_SOURCE="none"
            output_message "No task sources detected, using defaults"
        fi
    fi

    # Import tasks
    local imported_tasks=""
    case "$TASK_SOURCE" in
        beads)
            if beads_tasks=$(fetch_beads_tasks 2>/dev/null); then
                imported_tasks="$beads_tasks"
                TASKS_IMPORTED=$(echo "$imported_tasks" | grep -c '^\- \[' || echo "0")
                output_message "Imported $TASKS_IMPORTED tasks from beads"
            fi
            ;;
        github)
            if github_tasks=$(fetch_github_tasks "$GITHUB_LABEL" 2>/dev/null); then
                imported_tasks="$github_tasks"
                TASKS_IMPORTED=$(echo "$imported_tasks" | grep -c '^\- \[' || echo "0")
                output_message "Imported $TASKS_IMPORTED tasks from GitHub"
            fi
            ;;
        prd)
            if [[ -n "$PRD_FILE" && -f "$PRD_FILE" ]]; then
                if prd_tasks=$(extract_prd_tasks "$PRD_FILE" 2>/dev/null); then
                    imported_tasks="$prd_tasks"
                    TASKS_IMPORTED=$(echo "$imported_tasks" | grep -c '^\- \[' || echo "0")
                    output_message "Extracted $TASKS_IMPORTED tasks from PRD"
                fi
            else
                output_error "PRD file not found: $PRD_FILE"
                exit $ENABLE_ERROR
            fi
            ;;
        none|"")
            output_message "Skipping task import"
            ;;
        *)
            output_error "Unknown task source: $TASK_SOURCE"
            exit $ENABLE_ERROR
            ;;
    esac

    # Set up enable environment
    export ENABLE_FORCE="$FORCE_OVERWRITE"
    export ENABLE_SKIP_TASKS="false"
    export ENABLE_PROJECT_NAME="$DETECTED_PROJECT_NAME"
    export ENABLE_PROJECT_TYPE="$DETECTED_PROJECT_TYPE"
    export ENABLE_TASK_CONTENT="$imported_tasks"

    # Run core enable logic
    output_message ""
    output_message "Creating Ralph configuration..."

    # Suppress enable_ralph_in_directory output when in JSON mode
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        if ! enable_ralph_in_directory >/dev/null 2>&1; then
            output_error "Failed to enable Ralph"
            exit $ENABLE_ERROR
        fi
    else
        if ! enable_ralph_in_directory; then
            output_error "Failed to enable Ralph"
            exit $ENABLE_ERROR
        fi
    fi

    # Track created files
    [[ -f ".ralph/PROMPT.md" ]] && CREATED_FILES+=(".ralph/PROMPT.md")
    [[ -f ".ralph/@fix_plan.md" ]] && CREATED_FILES+=(".ralph/@fix_plan.md")
    [[ -f ".ralph/@AGENT.md" ]] && CREATED_FILES+=(".ralph/@AGENT.md")
    [[ -f ".ralphrc" ]] && CREATED_FILES+=(".ralphrc")

    # Verify required files exist
    if [[ ! -f ".ralph/PROMPT.md" ]] || [[ ! -f ".ralph/@fix_plan.md" ]]; then
        output_error "Required files were not created"
        exit $ENABLE_ERROR
    fi

    # Output success
    output_message ""
    output_success "$DETECTED_PROJECT_NAME" "$DETECTED_PROJECT_TYPE"

    exit $ENABLE_SUCCESS
}

# Run main
main "$@"
