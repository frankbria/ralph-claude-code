#!/usr/bin/env bats
# Unit Tests for Backup and Rollback System (Issue #23)
# Tests create_backup() and rollback_to_backup() functions

bats_require_minimum_version 1.5.0

load '../helpers/test_helper'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR/logs"

    export ENABLE_BACKUP=false
    export VERBOSE_PROGRESS=false

    # Initialise a real git repo for tests that exercise git behaviour
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    # Create an initial commit so HEAD is valid
    echo "initial" > README.md
    git add README.md
    git commit -q -m "Initial commit"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# ── Inline function under test ────────────────────────────────────────────────
# These mirror the implementations in ralph_loop.sh.
# IMPORTANT: Keep in sync if ralph_loop.sh changes.

log_status() {
    local level="$1"
    local message="$2"
    echo "[$level] $message" >&2
}

create_backup() {
    local loop_count="${1:-0}"

    [[ "$ENABLE_BACKUP" == "true" ]] || return 0

    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null 2>&1; then
        log_status "WARN" "Backup skipped: not a git repository"
        return 0
    fi

    local timestamp
    timestamp=$(date +%s)
    local branch_name="ralph-backup-loop-${loop_count}-${timestamp}"
    local stash_msg="Ralph backup before loop #${loop_count}"

    local stashed=false
    if ! git stash push -u -m "$stash_msg" 2>/dev/null; then
        log_status "WARN" "Backup failed: could not stash local changes for loop #${loop_count}"
        return 0
    fi
    stashed=true

    if ! git checkout -b "$branch_name" -q 2>/dev/null; then
        log_status "WARN" "Backup failed: could not create branch $branch_name"
        git stash pop 2>/dev/null || true
        return 0
    fi

    if ! git add -A 2>/dev/null; then
        log_status "WARN" "Backup failed: could not stage files for loop #${loop_count}"
        git checkout - -q 2>/dev/null || true
        git stash pop 2>/dev/null || true
        return 0
    fi

    if ! git commit --allow-empty -q -m "$stash_msg" 2>/dev/null; then
        log_status "WARN" "Backup failed: commit failed for loop #${loop_count}"
        git checkout - -q 2>/dev/null || true
        git stash pop 2>/dev/null || true
        return 0
    fi

    if ! git checkout - -q 2>/dev/null; then
        log_status "WARN" "Backup: could not switch back from $branch_name — manual cleanup may be needed"
    fi

    if [[ "$stashed" == "true" ]]; then
        git stash pop 2>/dev/null || log_status "WARN" "Backup: stash pop failed — run 'git stash pop' to restore your changes"
    fi

    log_status "INFO" "Backup created: $branch_name"
    return 0
}

rollback_to_backup() {
    local branch="${1:-}"

    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null 2>&1; then
        log_status "ERROR" "Rollback failed: not a git repository"
        return 1
    fi

    if [[ -z "$branch" ]]; then
        local backups
        backups=$(git branch --list "ralph-backup-loop-*" 2>/dev/null | sed 's/^[* ]*//' | sort -t- -k5,5 -rn)
        if [[ -z "$backups" ]]; then
            log_status "WARN" "No backup branches found"
            return 1
        fi
        echo "Available backups (newest first):"
        echo "$backups"
        return 0
    fi

    if ! git rev-parse --verify "$branch" &>/dev/null 2>&1; then
        log_status "ERROR" "Rollback failed: branch '$branch' not found"
        return 1
    fi

    git checkout "$branch" -q 2>/dev/null || {
        log_status "ERROR" "Rollback failed: could not checkout $branch"
        return 1
    }

    log_status "INFO" "Rolled back to: $branch"
    return 0
}

# =============================================================================
# TEST 1: create_backup creates branch with correct naming pattern
# =============================================================================

@test "create_backup creates branch with correct naming pattern" {
    export ENABLE_BACKUP=true

    create_backup 5

    # Branch matching ralph-backup-loop-5-<timestamp> must exist
    local found_branch
    found_branch=$(git branch --list "ralph-backup-loop-5-*" | sed 's/^[* ]*//')

    [[ -n "$found_branch" ]]
    [[ "$found_branch" == ralph-backup-loop-5-* ]]
}

# =============================================================================
# TEST 2: create_backup does nothing when ENABLE_BACKUP=false
# =============================================================================

@test "create_backup does nothing when ENABLE_BACKUP=false" {
    export ENABLE_BACKUP=false

    create_backup 3

    # No backup branches should exist
    local branches
    branches=$(git branch --list "ralph-backup-loop-*" | sed 's/^[* ]*//')
    [[ -z "$branches" ]]
}

# =============================================================================
# TEST 3: create_backup is graceful when not in git repo
# =============================================================================

@test "create_backup is graceful when not in git repo" {
    export ENABLE_BACKUP=true

    # Move to a non-git directory
    local non_git_dir
    non_git_dir=$(mktemp -d)
    cd "$non_git_dir"

    # Must complete without error (return 0)
    run create_backup 1
    [ "$status" -eq 0 ]

    cd "$TEST_TEMP_DIR"
    rm -rf "$non_git_dir"
}

# =============================================================================
# TEST 4: create_backup creates commit with correct message
# =============================================================================

@test "create_backup creates commit with correct message" {
    export ENABLE_BACKUP=true

    create_backup 7

    # Find the backup branch
    local branch
    branch=$(git branch --list "ralph-backup-loop-7-*" | sed 's/^[* ]*//')
    [[ -n "$branch" ]]

    # Inspect the commit message on that branch
    local commit_msg
    commit_msg=$(git log "$branch" -1 --pretty=format:"%s")
    [[ "$commit_msg" == "Ralph backup before loop #7" ]]
}

# =============================================================================
# TEST 5: --backup flag appears in help output
# =============================================================================

@test "--backup flag appears in help output" {
    # Stub lib/ so the script parses flags without sourcing real deps
    mkdir -p lib
    for stub in circuit_breaker response_analyzer date_utils timeout_utils file_protection log_utils; do
        cat > "lib/${stub}.sh" << 'STUB'
reset_circuit_breaker() { :; }
show_circuit_status() { :; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
analyze_response() { :; }
detect_output_format() { echo "text"; }
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
get_epoch_seconds() { date +%s; }
get_next_hour_time() { echo "next-hour"; }
portable_timeout() { shift; "$@"; }
detect_timeout_cmd() { :; }
validate_ralph_integrity() { return 0; }
get_integrity_report() { echo "OK"; }
rotate_logs() { :; }
log_status() { :; }
STUB
    done
    mkdir -p "$RALPH_DIR/logs"
    echo "# prompt" > "$RALPH_DIR/PROMPT.md"

    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--backup"* ]]
}

# =============================================================================
# TEST 6: rollback_to_backup checks out specified backup branch
# =============================================================================

@test "rollback_to_backup checks out specified backup branch" {
    export ENABLE_BACKUP=true

    # Create a backup branch
    create_backup 2

    local branch
    branch=$(git branch --list "ralph-backup-loop-2-*" | sed 's/^[* ]*//')
    [[ -n "$branch" ]]

    # Roll back to it — should succeed
    run rollback_to_backup "$branch"
    [ "$status" -eq 0 ]

    # Confirm we are now on the backup branch
    local current
    current=$(git rev-parse --abbrev-ref HEAD)
    [[ "$current" == "$branch" ]]
}

# =============================================================================
# TEST 7: rollback_to_backup with no args lists available backups
# =============================================================================

@test "rollback_to_backup with no args lists available backup branches" {
    export ENABLE_BACKUP=true

    # Create two backups at different loop counts
    create_backup 1
    sleep 1  # ensure distinct timestamps
    create_backup 2

    # With no args it should print the list and exit 0
    run rollback_to_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available backups"* ]]
    [[ "$output" == *"ralph-backup-loop-"* ]]
}

# =============================================================================
# TEST 8: rollback_to_backup with non-existent branch fails cleanly
# =============================================================================

@test "rollback_to_backup with non-existent branch fails cleanly" {
    run --separate-stderr rollback_to_backup "ralph-backup-loop-99-0000000000"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"not found"* ]]
}
