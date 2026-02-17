#!/usr/bin/env bash

# file_protection.sh - File integrity validation for Ralph projects
# Validates that critical Ralph configuration files exist before loop execution

# Required paths for a functioning Ralph project
# Only includes files critical for the loop to run — not optional state files
RALPH_REQUIRED_PATHS=(
    ".ralph"
    ".ralph/PROMPT.md"
    ".ralph/fix_plan.md"
    ".ralph/AGENT.md"
    ".ralphrc"
)

# Tracks missing files after validation (populated by validate_ralph_integrity)
RALPH_MISSING_FILES=()

# Validate that all required Ralph files and directories exist
# Sets RALPH_MISSING_FILES with the list of missing items
# Returns: 0 if all required paths exist, 1 if any are missing
validate_ralph_integrity() {
    RALPH_MISSING_FILES=()

    for path in "${RALPH_REQUIRED_PATHS[@]}"; do
        if [[ ! -e "$path" ]]; then
            RALPH_MISSING_FILES+=("$path")
        fi
    done

    if [[ ${#RALPH_MISSING_FILES[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Generate a human-readable integrity report
# Must be called after validate_ralph_integrity
# Returns: Report text on stdout
get_integrity_report() {
    if [[ ${#RALPH_MISSING_FILES[@]} -eq 0 ]]; then
        echo "All required Ralph files are intact."
        return 0
    fi

    echo "Ralph integrity check failed. Missing files:"
    for path in "${RALPH_MISSING_FILES[@]}"; do
        echo "  - $path"
    done
    echo ""
    echo "To restore, run: ralph-enable --force"
    return 0
}

# Export functions for use in other scripts
export -f validate_ralph_integrity
export -f get_integrity_report
