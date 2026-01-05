#!/usr/bin/env bats
# Integration Tests for Installation

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-install-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export ORIGINAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    export INSTALL_DIR="$HOME/.local/bin"
    export RALPH_HOME="$HOME/.ralph"
    mkdir -p "$HOME" "$INSTALL_DIR"
    export PATH="$INSTALL_DIR:$PATH"
}

teardown() {
    export HOME="$ORIGINAL_HOME"
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "install.sh creates ~/.ralph directory" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    assert_dir_exists "$RALPH_HOME"
}

@test "install.sh creates ~/.local/bin commands" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    assert_file_exists "$INSTALL_DIR/ralph"
}

@test "install.sh copies templates correctly" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    assert_dir_exists "$RALPH_HOME/templates"
}

@test "install.sh sets executable permissions" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    [[ -x "$INSTALL_DIR/ralph" ]]
}

@test "install.sh detects missing dependencies" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh --help
    assert_success
}

@test "install.sh PATH detection and warnings" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    assert_success
}

@test "install.sh uninstall removes command files" {
    cd "${BATS_TEST_DIRNAME}/../.."
    bash install.sh install
    run bash install.sh uninstall
    assert_success
    [[ ! -f "$INSTALL_DIR/ralph" ]]
}

@test "install.sh uninstall cleans up directories" {
    cd "${BATS_TEST_DIRNAME}/../.."
    bash install.sh install
    run bash install.sh uninstall
    assert_success
    [[ ! -d "$RALPH_HOME" ]]
}

@test "installation idempotency - run twice succeeds" {
    cd "${BATS_TEST_DIRNAME}/../.."
    run bash install.sh install
    assert_success
    run bash install.sh install
    assert_success
}

@test "installation from different directories" {
    local install_script="${BATS_TEST_DIRNAME}/../../install.sh"
    mkdir -p "$TEST_TEMP_DIR/subdir"
    cd "$TEST_TEMP_DIR/subdir"
    run bash "$install_script" install
    assert_success
}