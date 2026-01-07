#!/bin/bash
# =============================================================================
# Ralph Loop - Git Backup & Rollback Utilities
# =============================================================================
# Provides lightweight branch-based backups before each loop iteration and
# an optional rollback helper.
#
# Configuration:
#   ENABLE_BACKUP     - "true" to enable backups, "false" otherwise
#   LAST_BACKUP_BRANCH - name of last backup branch (set by create_backup)
#
# Backups are implemented as:
#   1. Stage all changes (git add -A)
#   2. Create an (allow-empty) commit
#   3. Create a branch: ralph-backup-loop-<loop>-<timestamp>
# =============================================================================

# Create a git backup branch for the current working tree.
#
# Arguments:
#   $1 - loop number (for naming only)
create_backup() {
    local loop_num="$1"

    if [[ "${ENABLE_BACKUP:-false}" != "true" ]]; then
        return 0
    fi

    # Ensure we're in a git repository.
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "WARN" "Not a git repository, skipping backup"
        fi
        return 0
    fi

    local timestamp
    timestamp=$(date +%s)

    local backup_branch="ralph-backup-loop-${loop_num}-${timestamp}"

    # Stage and commit snapshot (allow empty to ensure a new commit exists).
    git add -A || return 1
    git commit -m "Ralph backup before loop #${loop_num}" --allow-empty >/dev/null 2>&1 || return 1

    # Create a named branch at the current HEAD.
    git branch "$backup_branch" >/dev/null 2>&1 || return 1

    LAST_BACKUP_BRANCH="$backup_branch"

    if declare -f log_status >/dev/null 2>&1; then
        log_status "INFO" "Backup created: $backup_branch"
    fi
}

# Roll back the working tree and HEAD to the last backup branch.
#
# Arguments:
#   $1 - optional branch/commit to roll back to
rollback_to_backup() {
    local target="${1:-$LAST_BACKUP_BRANCH}"

    if [[ -z "$target" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "No backup branch configured for rollback"
        fi
        return 1
    fi

    # Verify the branch/commit exists.
    if ! git rev-parse --verify "$target" >/dev/null 2>&1; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Backup branch not found: $target"
        fi
        return 1
    fi

    git reset --hard "$target" >/dev/null 2>&1 || return 1

    if declare -f log_status >/dev/null 2>&1; then
        log_status "INFO" "Rolled back to backup: $target"
    fi
}