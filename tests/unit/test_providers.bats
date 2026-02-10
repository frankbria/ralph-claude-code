#!/usr/bin/env bats

load "../helpers/test_helper"

setup() {
    export RALPH_DIR=".ralph_test"
    mkdir -p "$RALPH_DIR/logs"
    mkdir -p "$RALPH_DIR/specs"
    
    # Mock log_status
    log_status() {
        echo "[$1] $2"
    }
    export -f log_status
}

teardown() {
    rm -rf "$RALPH_DIR"
}

@test "load_provider loads claude by default" {
    export RALPH_HOME="$BATS_TEST_DIRNAME/../.."
    source "$BATS_TEST_DIRNAME/../../lib/providers/base.sh"
    
    run load_provider
    assert_success
    [[ "$output" == *"[INFO] Loaded AI provider: claude"* ]]
}

@test "load_provider loads gemini when specified" {
    export RALPH_PROVIDER="gemini"
    export RALPH_HOME="$BATS_TEST_DIRNAME/../.."
    source "$BATS_TEST_DIRNAME/../../lib/providers/base.sh"
    
    run load_provider
    assert_success
    [[ "$output" == *"[INFO] Loaded AI provider: gemini"* ]]
}

@test "load_provider loads copilot when specified" {
    export RALPH_PROVIDER="copilot"
    export RALPH_HOME="$BATS_TEST_DIRNAME/../.."
    source "$BATS_TEST_DIRNAME/../../lib/providers/base.sh"
    
    run load_provider
    assert_success
    [[ "$output" == *"[INFO] Loaded AI provider: copilot"* ]]
}

@test "claude provider implements required functions" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/claude.sh"
    declare -F provider_init
    declare -F provider_execute
    declare -F validate_allowed_tools
}

@test "gemini provider implements required functions" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/gemini.sh"
    declare -F provider_init
    declare -F provider_execute
    declare -F validate_allowed_tools
}

@test "copilot provider implements required functions" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/copilot.sh"
    declare -F provider_init
    declare -F provider_execute
    declare -F validate_allowed_tools
}