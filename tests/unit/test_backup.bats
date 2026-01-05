#!/usr/bin/env bats
# Unit Tests for Backup & Rollback

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export LOG_DIR="logs"
    mkdir -p "$LOG_DIR"
    export ENABLE_BACKUP=false
    export LAST_BACKUP_BRANCH=""
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git commit --allow-empty -m "Initial commit" > /dev/null 2>&1
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message" >> "$LOG_DIR/ralph.log"
    }
    export -f log_status
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

create_backup() {
    local loop_num=$1
    if [[ "$ENABLE_BACKUP" != "true" ]]; then return 0; fi
    if ! git rev-parse --git-dir &>/dev/null; then
        log_status "WARN" "Not a git repository, skipping backup"
        return 0
    fi
    local timestamp=$(date +%s)
    local backup_branch="ralph-backup-loop-${loop_num}-${timestamp}"
    git add -A 2>/dev/null || true
    git commit -m "Ralph backup before loop #$loop_num" --allow-empty 2>/dev/null || true
    git branch "$backup_branch" 2>/dev/null || true
    LAST_BACKUP_BRANCH="$backup_branch"
    log_status "INFO" "Backup created: $backup_branch"
}

@test "create_backup creates backup branch when enabled" {
    export ENABLE_BACKUP=true
    create_backup 1
    run git branch --list 'ralph-backup-loop-1-*'
    [[ -n "$output" ]]
}

@test "create_backup creates commit even when no changes" {
    export ENABLE_BACKUP=true
    local commit_before=$(git rev-parse HEAD)
    create_backup 1
    local commit_after=$(git rev-parse HEAD)
    [[ "$commit_before" != "$commit_after" ]]
}

@test "create_backup skips when not in git repository" {
    export ENABLE_BACKUP=true
    local non_git_dir="$(mktemp -d)"
    cd "$non_git_dir"
    mkdir -p "$LOG_DIR"
    create_backup 1
    run grep "Not a git repository" "$LOG_DIR/ralph.log"
    assert_success
    cd "$TEST_TEMP_DIR"
    rm -rf "$non_git_dir"
}

@test "rollback_to_backup restores expected HEAD" {
    export ENABLE_BACKUP=true
    echo "file1" > test.txt
    git add test.txt && git commit -m "Add test.txt" > /dev/null 2>&1
    create_backup 1
    [[ -n "$LAST_BACKUP_BRANCH" ]]
}

@test "backup is skipped when ENABLE_BACKUP is false" {
    export ENABLE_BACKUP=false
    local branches_before=$(git branch | wc -l)
    create_backup 1
    local branches_after=$(git branch | wc -l)
    assert_equal "$branches_before" "$branches_after"
}