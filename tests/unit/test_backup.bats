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
    # Source the real backup implementation
    source "${BATS_TEST_DIRNAME}/../../lib/backup.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
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

    # Create a file and commit it
    echo "file1" > test.txt
    git add test.txt && git commit -m "Add test.txt" > /dev/null 2>&1

    # Create a backup branch at this point
    create_backup 1
    local backup_branch="$LAST_BACKUP_BRANCH"
    [[ -n "$backup_branch" ]]

    local backup_commit
    backup_commit=$(git rev-parse "$backup_branch")

    # Make another commit
    echo "file2" > test2.txt
    git add test2.txt && git commit -m "Add test2.txt" > /dev/null 2>&1

    # Roll back to the backup branch
    rollback_to_backup

    local current_commit
    current_commit=$(git rev-parse HEAD)

    assert_equal "$backup_commit" "$current_commit"
}

@test "backup is skipped when ENABLE_BACKUP is false" {
    export ENABLE_BACKUP=false
    local branches_before=$(git branch | wc -l)
    create_backup 1
    local branches_after=$(git branch | wc -l)
    assert_equal "$branches_before" "$branches_after"
}