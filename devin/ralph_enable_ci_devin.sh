#!/bin/bash

# Ralph Enable CI for Devin CLI - Non-Interactive Version for Automation
# Adds Ralph+Devin configuration with sensible defaults, no prompts.
# Parallel to ralph_enable_ci.sh (Claude Code)
#
# Usage:
#   ralph-devin-enable-ci                           # Sensible defaults
#   ralph-devin-enable-ci --from github             # Import from GitHub Issues
#   ralph-devin-enable-ci --project-type typescript  # Override detection
#   ralph-devin-enable-ci --json                     # Machine-readable output
#
# Version: 0.1.0

set -e

# Get script directory for library loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Try to load libraries
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
if [[ -f "$RALPH_HOME/lib/enable_core.sh" ]]; then
    LIB_DIR="$RALPH_HOME/lib"
elif [[ -f "$RALPH_ROOT/lib/enable_core.sh" ]]; then
    LIB_DIR="$RALPH_ROOT/lib"
else
    echo "Error: Cannot find Ralph libraries"
    exit 1
fi

source "$LIB_DIR/enable_core.sh"
source "$LIB_DIR/task_sources.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

TASK_SOURCE="local"
PRD_FILE=""
GITHUB_LABEL="ralph-task"
PROJECT_TYPE_OVERRIDE=""
FORCE_OVERWRITE=true
JSON_OUTPUT=false
VERSION="0.1.0"

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
Ralph Enable CI for Devin CLI - Non-Interactive Setup

Usage: ralph-devin-enable-ci [OPTIONS]

Options:
    --from <source>          Import tasks from: beads, github, prd, local
    --prd <file>             PRD file path (when --from prd)
    --label <label>          GitHub label filter (default: ralph-task)
    --project-type <type>    Override project type detection
    --json                   Output results as JSON
    --no-force               Don't overwrite existing .ralph/
    -h, --help               Show this help message
    -v, --version            Show version

Examples:
    ralph-devin-enable-ci
    ralph-devin-enable-ci --from github
    ralph-devin-enable-ci --project-type typescript --json

EOF
}

# =============================================================================
# PROJECT TYPE DETECTION
# =============================================================================

detect_project_type() {
    if [[ -n "$PROJECT_TYPE_OVERRIDE" ]]; then
        echo "$PROJECT_TYPE_OVERRIDE"
        return
    fi

    if [[ -f "package.json" ]]; then
        echo "typescript"
    elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
        echo "python"
    elif [[ -f "Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "go.mod" ]]; then
        echo "go"
    else
        echo "generic"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

run_ci_enable() {
    local project_name
    project_name=$(basename "$(pwd)")
    local project_type
    project_type=$(detect_project_type)

    # Check for existing .ralph/
    if [[ -d ".ralph" && "$FORCE_OVERWRITE" != "true" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"success": false, "error": "existing_ralph_directory", "message": "Use --force to overwrite"}'
        else
            echo "Error: .ralph/ directory already exists. Use --force or remove it first."
        fi
        exit 1
    fi

    # Track whether fix_plan.md already exists (before creating anything)
    local _fix_plan_existed="false"
    [[ -f ".ralph/fix_plan.md" ]] && _fix_plan_existed="true"

    # Create directory structure
    mkdir -p .ralph/{specs/stdlib,examples,logs,docs/generated}

    # Generate files from templates
    local templates_dir=""
    if [[ -d "$RALPH_HOME/templates" ]]; then
        templates_dir="$RALPH_HOME/templates"
    elif [[ -d "$RALPH_ROOT/templates" ]]; then
        templates_dir="$RALPH_ROOT/templates"
    fi

    # Copy templates only for files that don't exist (preserve existing work)
    if [[ -n "$templates_dir" ]]; then
        [[ ! -f ".ralph/PROMPT.md" ]] && cp "$templates_dir/PROMPT.md" .ralph/PROMPT.md 2>/dev/null || true
        [[ ! -f ".ralph/fix_plan.md" ]] && cp "$templates_dir/fix_plan.md" .ralph/fix_plan.md 2>/dev/null || true
        [[ ! -f ".ralph/AGENT.md" ]] && cp "$templates_dir/AGENT.md" .ralph/AGENT.md 2>/dev/null || true
        cp -r "$templates_dir/specs"/* .ralph/specs/ 2>/dev/null || true
    fi

    # Ensure files exist with fallbacks
    [[ ! -f ".ralph/PROMPT.md" ]] && echo "# $project_name" > .ralph/PROMPT.md
    [[ ! -f ".ralph/fix_plan.md" ]] && echo "# Fix Plan" > .ralph/fix_plan.md
    [[ ! -f ".ralph/AGENT.md" ]] && echo "# Agent Instructions" > .ralph/AGENT.md

    # Import tasks if specified — only overwrite fix_plan.md if it was just created (not pre-existing)
    if [[ "$TASK_SOURCE" != "local" ]]; then
        if type import_tasks_from_source &>/dev/null 2>&1; then
            # Only import into fix_plan.md if it was just created by this run (not pre-existing)
            if [[ "$_fix_plan_existed" != "true" ]]; then
                import_tasks_from_source "$TASK_SOURCE" "$GITHUB_LABEL" "$PRD_FILE" > .ralph/fix_plan.md 2>/dev/null || true
            fi
        fi
    fi

    # Generate Devin-specific .ralphrc.devin (separate from Claude's .ralphrc)
    cat > .ralphrc.devin << RALPHRCEOF
# .ralphrc.devin - Ralph project configuration (Devin CLI)
# Generated by: ralph-devin-enable-ci

PROJECT_NAME="${project_name}"
PROJECT_TYPE="${project_type}"
RALPH_ENGINE="devin"

MAX_CALLS_PER_HOUR=100
DEVIN_TIMEOUT_MINUTES=30

DEVIN_USE_CONTINUE=true
DEVIN_SESSION_EXPIRY_HOURS=24
DEVIN_POLL_INTERVAL=15
DEVIN_MAX_POLL_ATTEMPTS=240

TASK_SOURCES="${TASK_SOURCE}"
GITHUB_TASK_LABEL="${GITHUB_LABEL}"

CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_OUTPUT_DECLINE_THRESHOLD=70
RALPHRCEOF

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local files_created=0
        for f in .ralph/PROMPT.md .ralph/fix_plan.md .ralph/AGENT.md .ralphrc.devin; do
            [[ -f "$f" ]] && files_created=$((files_created + 1))
        done

        jq -n \
            --arg project_name "$project_name" \
            --arg project_type "$project_type" \
            --arg engine "devin" \
            --arg task_source "$TASK_SOURCE" \
            --argjson files_created "$files_created" \
            '{
                success: true,
                project_name: $project_name,
                project_type: $project_type,
                engine: $engine,
                task_source: $task_source,
                files_created: $files_created
            }'
    else
        echo "✅ Ralph+Devin enabled for '$project_name'"
        echo "   Type: $project_type | Engine: devin | Tasks: $TASK_SOURCE"
        echo ""
        echo "Run: ralph-devin --monitor"
    fi
}

# =============================================================================
# CLI PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -v|--version) echo "ralph-devin-enable-ci version $VERSION"; exit 0 ;;
        --from) TASK_SOURCE="$2"; shift 2 ;;
        --prd) PRD_FILE="$2"; shift 2 ;;
        --label) GITHUB_LABEL="$2"; shift 2 ;;
        --project-type) PROJECT_TYPE_OVERRIDE="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --no-force) FORCE_OVERWRITE=false; shift ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

run_ci_enable
