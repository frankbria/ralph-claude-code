#!/bin/bash

# Ralph Enable - Interactive Wizard for Existing Projects
# Adds Ralph configuration to an existing codebase
#
# Usage:
#   ralph enable              # Interactive wizard
#   ralph enable --from beads # With specific task source
#   ralph enable --force      # Overwrite existing .ralph/
#   ralph enable --skip-tasks # Skip task import
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
    echo "Error: Cannot find Ralph libraries"
    echo "Please run ./install.sh first or ensure RALPH_HOME is set correctly"
    exit 1
fi

# Source libraries
source "$LIB_DIR/enable_core.sh"
source "$LIB_DIR/wizard_utils.sh"
source "$LIB_DIR/task_sources.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Command line options
FORCE_OVERWRITE=false
SKIP_TASKS=false
TASK_SOURCE=""
PRD_FILE=""
GITHUB_LABEL=""
NON_INTERACTIVE=false
SHOW_HELP=false

# Version
VERSION="0.11.0"

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
Ralph Enable - Add Ralph to Existing Projects

Usage: ralph enable [OPTIONS]

Options:
    --from <source>     Import tasks from: beads, github, prd
    --prd <file>        PRD file to convert (when --from prd)
    --label <label>     GitHub label filter (when --from github)
    --force             Overwrite existing .ralph/ configuration
    --skip-tasks        Skip task import, use default templates
    --non-interactive   Run with defaults (no prompts)
    -h, --help          Show this help message
    -v, --version       Show version

Examples:
    # Interactive wizard (recommended)
    cd my-existing-project
    ralph enable

    # Import tasks from beads
    ralph enable --from beads

    # Import from GitHub issues with label
    ralph enable --from github --label "ralph-task"

    # Convert a PRD document
    ralph enable --from prd --prd ./docs/requirements.md

    # Skip task import
    ralph enable --skip-tasks

    # Force overwrite existing configuration
    ralph enable --force

What this command does:
    1. Detects your project type (TypeScript, Python, etc.)
    2. Identifies available task sources (beads, GitHub, PRDs)
    3. Imports tasks from selected sources
    4. Creates .ralph/ configuration directory
    5. Generates PROMPT.md, fix_plan.md, AGENT.md
    6. Creates .ralphrc for project-specific settings

This command is:
    - Idempotent: Safe to run multiple times
    - Non-destructive: Never overwrites existing files (unless --force)
    - Project-aware: Detects your language, framework, and build tools

For new projects, use: ralph-setup <project-name>
For migrating old structure, use: ralph-migrate

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
                    echo "Error: --from requires a source (beads, github, prd)" >&2
                    exit $ENABLE_INVALID_ARGS
                fi
                ;;
            --prd)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    PRD_FILE="$2"
                    shift 2
                else
                    echo "Error: --prd requires a file path" >&2
                    exit $ENABLE_INVALID_ARGS
                fi
                ;;
            --label)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    GITHUB_LABEL="$2"
                    shift 2
                else
                    echo "Error: --label requires a label name" >&2
                    exit $ENABLE_INVALID_ARGS
                fi
                ;;
            --force)
                FORCE_OVERWRITE=true
                shift
                ;;
            --skip-tasks)
                SKIP_TASKS=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            -v|--version)
                echo "ralph enable version $VERSION"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use --help for usage information" >&2
                exit $ENABLE_INVALID_ARGS
                ;;
        esac
    done
}

# =============================================================================
# PHASE 1: ENVIRONMENT DETECTION
# =============================================================================

phase_environment_detection() {
    print_header "Environment Detection" "Phase 1 of 5"

    echo "Analyzing your project..."
    echo ""

    # Check for existing Ralph setup (use || true to prevent set -e from exiting)
    check_existing_ralph || true
    case "$RALPH_STATE" in
        "complete")
            print_detection_result "Ralph status" "Already enabled" "true"
            if [[ "$FORCE_OVERWRITE" != "true" ]]; then
                echo ""
                print_warning "Ralph is already enabled in this project."
                echo ""
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    if ! confirm "Do you want to continue anyway?" "n"; then
                        echo "Exiting. Use --force to overwrite."
                        exit $ENABLE_ALREADY_ENABLED
                    fi
                else
                    echo "Use --force to overwrite existing configuration."
                    exit $ENABLE_ALREADY_ENABLED
                fi
            fi
            ;;
        "partial")
            print_detection_result "Ralph status" "Partially configured" "false"
            echo ""
            print_info "Missing files: ${RALPH_MISSING_FILES[*]}"
            echo ""
            ;;
        "none")
            print_detection_result "Ralph status" "Not configured" "false"
            ;;
    esac

    # Detect project context
    detect_project_context
    print_detection_result "Project name" "$DETECTED_PROJECT_NAME" "true"
    print_detection_result "Project type" "$DETECTED_PROJECT_TYPE" "true"
    if [[ -n "$DETECTED_FRAMEWORK" ]]; then
        print_detection_result "Framework" "$DETECTED_FRAMEWORK" "true"
    fi

    # Detect git info
    detect_git_info
    if [[ "$DETECTED_GIT_REPO" == "true" ]]; then
        print_detection_result "Git repository" "Yes" "true"
        if [[ "$DETECTED_GIT_GITHUB" == "true" ]]; then
            print_detection_result "GitHub remote" "Yes" "true"
        fi
    else
        print_detection_result "Git repository" "No" "false"
    fi

    # Detect task sources
    detect_task_sources
    echo ""
    echo "Available task sources:"
    if [[ "$DETECTED_BEADS_AVAILABLE" == "true" ]]; then
        local beads_count
        beads_count=$(get_beads_count)
        print_detection_result "beads" "$beads_count open issues" "true"
    fi
    if [[ "$DETECTED_GITHUB_AVAILABLE" == "true" ]]; then
        local gh_count
        gh_count=$(get_github_issue_count)
        print_detection_result "GitHub Issues" "$gh_count open issues" "true"
    fi
    if [[ ${#DETECTED_PRD_FILES[@]} -gt 0 ]]; then
        print_detection_result "PRD files" "${#DETECTED_PRD_FILES[@]} found" "true"
    fi

    echo ""
}

# =============================================================================
# PHASE 2: TASK SOURCE SELECTION
# =============================================================================

phase_task_source_selection() {
    print_header "Task Source Selection" "Phase 2 of 5"

    # If task source specified via CLI, use it
    if [[ -n "$TASK_SOURCE" ]]; then
        echo "Using task source from command line: $TASK_SOURCE"
        SELECTED_SOURCES="$TASK_SOURCE"
        return 0
    fi

    # If skip tasks, use empty
    if [[ "$SKIP_TASKS" == "true" ]]; then
        echo "Skipping task import (--skip-tasks)"
        SELECTED_SOURCES=""
        return 0
    fi

    # Non-interactive mode: auto-select available sources
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        local auto_sources=""
        [[ "$DETECTED_BEADS_AVAILABLE" == "true" ]] && auto_sources="beads"
        [[ "$DETECTED_GITHUB_AVAILABLE" == "true" ]] && auto_sources="${auto_sources:+$auto_sources }github"
        SELECTED_SOURCES="$auto_sources"
        echo "Auto-selected sources: ${SELECTED_SOURCES:-none}"
        return 0
    fi

    # Build options list
    local options=()
    local option_keys=()

    if [[ "$DETECTED_BEADS_AVAILABLE" == "true" ]]; then
        local beads_count
        beads_count=$(get_beads_count)
        options+=("Import from beads ($beads_count issues)")
        option_keys+=("beads")
    fi

    if [[ "$DETECTED_GITHUB_AVAILABLE" == "true" ]]; then
        local gh_count
        gh_count=$(get_github_issue_count)
        options+=("Import from GitHub Issues ($gh_count issues)")
        option_keys+=("github")
    fi

    if [[ ${#DETECTED_PRD_FILES[@]} -gt 0 ]]; then
        options+=("Convert PRD/spec document (${#DETECTED_PRD_FILES[@]} found)")
        option_keys+=("prd")
    fi

    options+=("Start with empty task list")
    option_keys+=("none")

    # Interactive selection
    if [[ ${#options[@]} -gt 1 ]]; then
        echo "Where would you like to import tasks from?"
        echo ""

        local selected_indices
        selected_indices=$(select_multiple "Select task sources" "${options[@]}")

        # Parse selected indices (comma-separated)
        SELECTED_SOURCES=""
        if [[ -n "$selected_indices" ]]; then
            IFS=',' read -ra indices <<< "$selected_indices"
            for idx in "${indices[@]}"; do
                if [[ "${option_keys[$idx]}" != "none" ]]; then
                    SELECTED_SOURCES="${SELECTED_SOURCES:+$SELECTED_SOURCES }${option_keys[$idx]}"
                fi
            done
        fi
    else
        SELECTED_SOURCES=""
    fi

    echo ""
    echo "Selected sources: ${SELECTED_SOURCES:-none}"
}

# =============================================================================
# PHASE 3: AI PROVIDER SELECTION
# =============================================================================

phase_provider_selection() {
    print_header "AI Provider Selection" "Phase 3 of 6"

    # Default provider
    CONFIG_PROVIDER="claude"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo "Using default provider: $CONFIG_PROVIDER"
        return 0
    fi

    echo "Select the AI provider to use:"
    echo ""

    local options=("Claude Code (Anthropic)" "Google Gemini" "GitHub Copilot (Coming Soon)")
    local selection
    selection=$(select_option "Select provider" "${options[@]}")

    case "$selection" in
        "Claude Code (Anthropic)")
            CONFIG_PROVIDER="claude"
            ;;
        "Google Gemini")
            CONFIG_PROVIDER="gemini"
            if [[ -z "$GEMINI_API_KEY" ]]; then
                echo ""
                print_warning "GEMINI_API_KEY is not set in your environment."
                echo "Please ensure it is set before running Ralph."
            fi
            ;;
        "GitHub Copilot (Coming Soon)")
            CONFIG_PROVIDER="copilot"
            print_warning "Copilot support is experimental."
            ;;
    esac

    echo ""
    echo "Selected provider: $CONFIG_PROVIDER"
}

# =============================================================================
# PHASE 4: CONFIGURATION
# =============================================================================

phase_configuration() {
    print_header "Configuration" "Phase 4 of 6"

    # Project name
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        CONFIG_PROJECT_NAME=$(prompt_text "Project name" "$DETECTED_PROJECT_NAME")
    else
        CONFIG_PROJECT_NAME="$DETECTED_PROJECT_NAME"
    fi

    # API call limit
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        CONFIG_MAX_CALLS=$(prompt_number "Max API calls per hour" "100" "10" "500")
    else
        CONFIG_MAX_CALLS=100
    fi

    # GitHub label (if GitHub selected)
    if echo "$SELECTED_SOURCES" | grep -qw "github"; then
        if [[ -n "$GITHUB_LABEL" ]]; then
            CONFIG_GITHUB_LABEL="$GITHUB_LABEL"
        elif [[ "$NON_INTERACTIVE" != "true" ]]; then
            CONFIG_GITHUB_LABEL=$(prompt_text "GitHub issue label filter" "ralph-task")
        else
            CONFIG_GITHUB_LABEL="ralph-task"
        fi
    fi

    # PRD file selection (if PRD selected)
    if echo "$SELECTED_SOURCES" | grep -qw "prd"; then
        if [[ -n "$PRD_FILE" ]]; then
            CONFIG_PRD_FILE="$PRD_FILE"
        elif [[ "$NON_INTERACTIVE" != "true" && ${#DETECTED_PRD_FILES[@]} -gt 0 ]]; then
            echo ""
            echo "Found PRD files:"
            CONFIG_PRD_FILE=$(select_option "Select PRD file to convert" "${DETECTED_PRD_FILES[@]}")
        else
            CONFIG_PRD_FILE="${DETECTED_PRD_FILES[0]:-}"
        fi
    fi

    # Show configuration summary
    echo ""
    print_summary "Configuration" \
        "Project=$CONFIG_PROJECT_NAME" \
        "Type=$DETECTED_PROJECT_TYPE" \
        "Provider=$CONFIG_PROVIDER" \
        "Max calls/hour=$CONFIG_MAX_CALLS" \
        "Task sources=${SELECTED_SOURCES:-none}"
}

# =============================================================================
# PHASE 5: FILE GENERATION
# =============================================================================

phase_file_generation() {
    print_header "File Generation" "Phase 5 of 6"

    # Import tasks if sources selected
    local imported_tasks=""
    if [[ -n "$SELECTED_SOURCES" ]]; then
        echo "Importing tasks..."

        if echo "$SELECTED_SOURCES" | grep -qw "beads"; then
            local beads_tasks
            if beads_tasks=$(fetch_beads_tasks); then
                imported_tasks="${imported_tasks}${beads_tasks}
"
                print_success "Imported tasks from beads"
            fi
        fi

        if echo "$SELECTED_SOURCES" | grep -qw "github"; then
            local github_tasks
            if github_tasks=$(fetch_github_tasks "$CONFIG_GITHUB_LABEL"); then
                imported_tasks="${imported_tasks}${github_tasks}
"
                print_success "Imported tasks from GitHub"
            fi
        fi

        if echo "$SELECTED_SOURCES" | grep -qw "prd"; then
            if [[ -n "$CONFIG_PRD_FILE" && -f "$CONFIG_PRD_FILE" ]]; then
                local prd_tasks
                if prd_tasks=$(extract_prd_tasks "$CONFIG_PRD_FILE"); then
                    imported_tasks="${imported_tasks}${prd_tasks}
"
                    print_success "Extracted tasks from PRD: $CONFIG_PRD_FILE"
                fi
            fi
        fi

        echo ""
    fi

    # Set up enable environment
    export ENABLE_FORCE="$FORCE_OVERWRITE"
    export ENABLE_SKIP_TASKS="$SKIP_TASKS"
    export ENABLE_PROJECT_NAME="$CONFIG_PROJECT_NAME"
    export ENABLE_TASK_CONTENT="$imported_tasks"
    export ENABLE_PROVIDER="$CONFIG_PROVIDER"

    # Run core enable logic
    echo "Creating Ralph configuration..."
    echo ""

    if ! enable_ralph_in_directory; then
        print_error "Failed to enable Ralph"
        exit $ENABLE_ERROR
    fi

    # Update .ralphrc with specific settings
    # Using awk instead of sed to avoid command injection from user input
    if [[ -f ".ralphrc" ]]; then
        # Update max calls (awk safely handles the value without shell interpretation)
        awk -v val="$CONFIG_MAX_CALLS" '/^MAX_CALLS_PER_HOUR=/{$0="MAX_CALLS_PER_HOUR="val}1' .ralphrc > .ralphrc.tmp && mv .ralphrc.tmp .ralphrc

        # Update GitHub label if set
        if [[ -n "$CONFIG_GITHUB_LABEL" ]]; then
            awk -v val="$CONFIG_GITHUB_LABEL" '/^GITHUB_TASK_LABEL=/{$0="GITHUB_TASK_LABEL=\""val"\""}1' .ralphrc > .ralphrc.tmp && mv .ralphrc.tmp .ralphrc
        fi
    fi

    echo ""
}

# =============================================================================
# PHASE 5: VERIFICATION
# =============================================================================

phase_verification() {
    print_header "Verification" "Phase 5 of 5"

    echo "Checking created files..."
    echo ""

    # Verify required files
    local all_good=true

    if [[ -f ".ralph/PROMPT.md" ]]; then
        print_success ".ralph/PROMPT.md"
    else
        print_error ".ralph/PROMPT.md - MISSING"
        all_good=false
    fi

    if [[ -f ".ralph/fix_plan.md" ]]; then
        print_success ".ralph/fix_plan.md"
    else
        print_error ".ralph/fix_plan.md - MISSING"
        all_good=false
    fi

    if [[ -f ".ralph/AGENT.md" ]]; then
        print_success ".ralph/AGENT.md"
    else
        print_error ".ralph/AGENT.md - MISSING"
        all_good=false
    fi

    if [[ -f ".ralphrc" ]]; then
        print_success ".ralphrc"
    else
        print_warning ".ralphrc - MISSING (optional)"
    fi

    if [[ -d ".ralph/specs" ]]; then
        print_success ".ralph/specs/"
    fi

    if [[ -d ".ralph/logs" ]]; then
        print_success ".ralph/logs/"
    fi

    echo ""

    if [[ "$all_good" == "true" ]]; then
        print_success "Ralph enabled successfully!"
        echo ""
        echo "Next steps:"
        echo ""
        print_bullet "Review and customize .ralph/PROMPT.md" "1."
        print_bullet "Edit tasks in .ralph/fix_plan.md" "2."
        print_bullet "Update build commands in .ralph/AGENT.md" "3."
        print_bullet "Start Ralph: ralph --monitor" "4."
        echo ""

        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            if confirm "Show current status?" "y"; then
                echo ""
                ralph --status 2>/dev/null || echo "(ralph --status not available)"
            fi
        fi
    else
        print_error "Some files were not created. Please check the errors above."
        exit $ENABLE_ERROR
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"

    # Show help if requested
    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    # Welcome banner
    echo ""
    echo -e "\033[1m╔════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1m║          Ralph Enable - Existing Project Wizard            ║\033[0m"
    echo -e "\033[1m╚════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # Run phases
    phase_environment_detection
    phase_task_source_selection
    phase_configuration
    phase_file_generation
    phase_verification

    exit $ENABLE_SUCCESS
}

# Run main
main "$@"
