#!/usr/bin/env bats
# Integration Tests for Project Setup

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-setup-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export ORIGINAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    export RALPH_HOME="$HOME/.ralph"
    export INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$HOME" "$INSTALL_DIR"
    export PATH="$INSTALL_DIR:$PATH"
    git config --global user.email "test@example.com"
    git config --global user.name "Test User"
    cd "${BATS_TEST_DIRNAME}/../.."
    bash install.sh install > /dev/null 2>&1
    cd "$TEST_TEMP_DIR"
}

teardown() {
    export HOME="$ORIGINAL_HOME"
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "ralph-setup creates project directory" {
    run "$INSTALL_DIR/ralph-setup" test-project
    assert_success
    assert_dir_exists "test-project"
}

@test "ralph-setup creates all subdirectories" {
    run "$INSTALL_DIR/ralph-setup" test-project
    assert_dir_exists "test-project/specs"
    assert_dir_exists "test-project/logs"
}

@test "ralph-setup copies templates from ~/.ralph" {
    run "$INSTALL_DIR/ralph-setup" test-project
    assert_file_exists "test-project/PROMPT.md"
}

@test "ralph-setup initializes git repository" {
    run "$INSTALL_DIR/ralph-setup" test-project
    assert_dir_exists "test-project/.git"
}

@test "ralph-setup creates README.md" {
    run "$INSTALL_DIR/ralph-setup" test-project
    assert_file_exists "test-project/README.md"
}

@test "ralph-setup with custom project name" {
    run "$INSTALL_DIR/ralph-setup" my-custom-app
    assert_success
    assert_dir_exists "my-custom-app"
}

@test "ralph-setup with default project name uses my-project" {
    run "$INSTALL_DIR/ralph-setup"
    assert_success
    assert_dir_exists "my-project"
}

@test "ralph-setup from various working directories" {
    mkdir -p subdir/nested
    cd subdir/nested
    run "$INSTALL_DIR/ralph-setup" nested-project
    assert_success
    assert_dir_exists "nested-project"
}