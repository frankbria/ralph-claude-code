#!/bin/bash

# Migration script for Ralph projects from flat structure to .ralph/ subfolder
# Version: 1.0.0
#
# This script migrates existing Ralph projects from the old flat structure:
#   PROMPT.md, @fix_plan.md, @AGENT.md, specs/, logs/, docs/generated/
# To the new .ralph/ subfolder structure:
#   .ralph/PROMPT.md, .ralph/@fix_plan.md, .ralph/@AGENT.md, .ralph/specs/, etc.
#
# Usage: ./migrate_to_ralph_folder.sh [project-directory]
#
# If no project directory is specified, the current directory is used.

set -e

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

# Check if project is already migrated
is_already_migrated() {
    local project_dir=$1

    # Check if .ralph/ directory exists with key files
    if [[ -d "$project_dir/.ralph" ]] && \
       [[ -f "$project_dir/.ralph/PROMPT.md" ]] && \
       [[ -f "$project_dir/.ralph/@fix_plan.md" ]]; then
        return 0  # Already migrated
    fi
    return 1  # Not migrated
}

# Check if project needs migration (has old-style structure)
needs_migration() {
    local project_dir=$1

    # Check for old-style structure (files in root)
    if [[ -f "$project_dir/PROMPT.md" ]] || \
       [[ -f "$project_dir/@fix_plan.md" ]] || \
       [[ -f "$project_dir/@AGENT.md" ]] || \
       [[ -d "$project_dir/specs" && ! -d "$project_dir/.ralph/specs" ]] || \
       [[ -d "$project_dir/logs" && ! -d "$project_dir/.ralph/logs" ]]; then
        return 0  # Needs migration
    fi
    return 1  # Doesn't need migration
}

# Backup function
create_backup() {
    local project_dir=$1
    local backup_dir="$project_dir/.ralph_backup_$(date +%Y%m%d_%H%M%S)"

    log "INFO" "Creating backup at $backup_dir"
    mkdir -p "$backup_dir"

    # Backup files that will be moved
    [[ -f "$project_dir/PROMPT.md" ]] && cp "$project_dir/PROMPT.md" "$backup_dir/"
    [[ -f "$project_dir/@fix_plan.md" ]] && cp "$project_dir/@fix_plan.md" "$backup_dir/"
    [[ -f "$project_dir/@AGENT.md" ]] && cp "$project_dir/@AGENT.md" "$backup_dir/"
    [[ -d "$project_dir/specs" ]] && cp -r "$project_dir/specs" "$backup_dir/"
    [[ -d "$project_dir/logs" ]] && cp -r "$project_dir/logs" "$backup_dir/"
    [[ -d "$project_dir/docs/generated" ]] && cp -r "$project_dir/docs/generated" "$backup_dir/docs_generated"

    # Backup hidden state files
    [[ -f "$project_dir/.call_count" ]] && cp "$project_dir/.call_count" "$backup_dir/"
    [[ -f "$project_dir/.last_reset" ]] && cp "$project_dir/.last_reset" "$backup_dir/"
    [[ -f "$project_dir/.exit_signals" ]] && cp "$project_dir/.exit_signals" "$backup_dir/"
    [[ -f "$project_dir/.response_analysis" ]] && cp "$project_dir/.response_analysis" "$backup_dir/"
    [[ -f "$project_dir/.circuit_breaker_state" ]] && cp "$project_dir/.circuit_breaker_state" "$backup_dir/"
    [[ -f "$project_dir/.circuit_breaker_history" ]] && cp "$project_dir/.circuit_breaker_history" "$backup_dir/"
    [[ -f "$project_dir/.claude_session_id" ]] && cp "$project_dir/.claude_session_id" "$backup_dir/"
    [[ -f "$project_dir/.ralph_session" ]] && cp "$project_dir/.ralph_session" "$backup_dir/"
    [[ -f "$project_dir/status.json" ]] && cp "$project_dir/status.json" "$backup_dir/"

    echo "$backup_dir"
}

# Migrate project to new structure
migrate_project() {
    local project_dir=$1
    local backup_dir=$2

    log "INFO" "Starting migration..."

    # Create .ralph directory structure
    mkdir -p "$project_dir/.ralph/specs/stdlib"
    mkdir -p "$project_dir/.ralph/examples"
    mkdir -p "$project_dir/.ralph/logs"
    mkdir -p "$project_dir/.ralph/docs/generated"

    # Move main configuration files
    if [[ -f "$project_dir/PROMPT.md" ]]; then
        log "INFO" "Moving PROMPT.md to .ralph/"
        mv "$project_dir/PROMPT.md" "$project_dir/.ralph/PROMPT.md"
    fi

    if [[ -f "$project_dir/@fix_plan.md" ]]; then
        log "INFO" "Moving @fix_plan.md to .ralph/"
        mv "$project_dir/@fix_plan.md" "$project_dir/.ralph/@fix_plan.md"
    fi

    if [[ -f "$project_dir/@AGENT.md" ]]; then
        log "INFO" "Moving @AGENT.md to .ralph/"
        mv "$project_dir/@AGENT.md" "$project_dir/.ralph/@AGENT.md"
    fi

    # Move specs directory contents
    if [[ -d "$project_dir/specs" ]]; then
        log "INFO" "Moving specs/ to .ralph/specs/"
        # Move contents, not the directory itself (to preserve any existing .ralph/specs structure)
        if [[ "$(ls -A "$project_dir/specs" 2>/dev/null)" ]]; then
            cp -r "$project_dir/specs"/* "$project_dir/.ralph/specs/" 2>/dev/null || true
        fi
        rm -rf "$project_dir/specs"
    fi

    # Move logs directory contents
    if [[ -d "$project_dir/logs" ]]; then
        log "INFO" "Moving logs/ to .ralph/logs/"
        if [[ "$(ls -A "$project_dir/logs" 2>/dev/null)" ]]; then
            cp -r "$project_dir/logs"/* "$project_dir/.ralph/logs/" 2>/dev/null || true
        fi
        rm -rf "$project_dir/logs"
    fi

    # Move docs/generated contents
    if [[ -d "$project_dir/docs/generated" ]]; then
        log "INFO" "Moving docs/generated/ to .ralph/docs/generated/"
        if [[ "$(ls -A "$project_dir/docs/generated" 2>/dev/null)" ]]; then
            cp -r "$project_dir/docs/generated"/* "$project_dir/.ralph/docs/generated/" 2>/dev/null || true
        fi
        rm -rf "$project_dir/docs/generated"
        # Remove docs directory if empty
        rmdir "$project_dir/docs" 2>/dev/null || true
    fi

    # Move hidden state files
    local state_files=(
        ".call_count"
        ".last_reset"
        ".exit_signals"
        ".response_analysis"
        ".circuit_breaker_state"
        ".circuit_breaker_history"
        ".claude_session_id"
        ".ralph_session"
        ".ralph_session_history"
        ".json_parse_result"
        ".last_output_length"
        "status.json"
    )

    for file in "${state_files[@]}"; do
        if [[ -f "$project_dir/$file" ]]; then
            log "INFO" "Moving $file to .ralph/"
            mv "$project_dir/$file" "$project_dir/.ralph/$file"
        fi
    done

    # Move examples if they exist
    if [[ -d "$project_dir/examples" && ! -d "$project_dir/.ralph/examples" ]]; then
        log "INFO" "Moving examples/ to .ralph/examples/"
        mv "$project_dir/examples" "$project_dir/.ralph/examples"
    fi

    log "SUCCESS" "Migration completed successfully!"
}

# Main function
main() {
    local project_dir="${1:-.}"

    # Convert to absolute path
    project_dir=$(cd "$project_dir" && pwd)

    log "INFO" "Checking project directory: $project_dir"

    # Check if already migrated
    if is_already_migrated "$project_dir"; then
        log "SUCCESS" "Project is already using the new .ralph/ structure"
        exit 0
    fi

    # Check if needs migration
    if ! needs_migration "$project_dir"; then
        log "WARN" "No Ralph project files found. Nothing to migrate."
        log "INFO" "Expected files: PROMPT.md, @fix_plan.md, @AGENT.md, specs/, logs/"
        exit 0
    fi

    # Create backup
    backup_dir=$(create_backup "$project_dir")
    log "SUCCESS" "Backup created at: $backup_dir"

    # Perform migration
    migrate_project "$project_dir" "$backup_dir"

    echo ""
    log "INFO" "Migration summary:"
    echo "  - Project files moved to .ralph/ subfolder"
    echo "  - Backup saved at: $backup_dir"
    echo "  - src/ directory preserved at project root"
    echo ""
    log "INFO" "Next steps:"
    echo "  1. Verify the migration by checking .ralph/ contents"
    echo "  2. Run 'ralph --status' to verify Ralph can read the new structure"
    echo "  3. If everything works, you can delete the backup directory"
    echo ""
}

# Show help
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << 'HELPEOF'
Ralph Migration Script - Migrate to .ralph/ subfolder structure

Usage: migrate_to_ralph_folder.sh [project-directory]

Arguments:
    project-directory   Path to the Ralph project to migrate (default: current directory)

Description:
    This script migrates existing Ralph projects from the old flat structure to the
    new .ralph/ subfolder structure. This change keeps source code clean by moving
    Ralph-specific files into a dedicated subfolder.

    Old structure:
        project/
        ├── PROMPT.md
        ├── @fix_plan.md
        ├── @AGENT.md
        ├── specs/
        ├── logs/
        └── src/

    New structure:
        project/
        ├── .ralph/
        │   ├── PROMPT.md
        │   ├── @fix_plan.md
        │   ├── @AGENT.md
        │   ├── specs/
        │   ├── logs/
        │   └── docs/generated/
        └── src/

Features:
    - Automatically detects if migration is needed
    - Creates backup before migration
    - Moves all Ralph-specific files and state
    - Preserves src/ at project root

Examples:
    migrate_to_ralph_folder.sh              # Migrate current directory
    migrate_to_ralph_folder.sh ./my-project # Migrate specific project
HELPEOF
    exit 0
fi

main "$@"
