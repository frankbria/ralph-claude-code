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

@test "validate_allowed_tools matches exact patterns" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/claude.sh"
    run validate_allowed_tools "Write,Read,Edit"
    assert_success
}

@test "validate_allowed_tools matches wildcard patterns" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/claude.sh"
    run validate_allowed_tools "Bash(git log),Bash(npm install)"
    assert_success
}

@test "validate_allowed_tools rejects unauthorized Bash tools" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/claude.sh"
    run validate_allowed_tools "Bash(rm -rf /)"
    assert_failure
    [[ "$output" == *"Error: Invalid tool: 'Bash(rm -rf /)'"* ]]
}

@test "validate_allowed_tools rejects unknown tools" {
    source "$BATS_TEST_DIRNAME/../../lib/providers/claude.sh"
    run validate_allowed_tools "EvilTool"
    assert_failure
    [[ "$output" == *"Error: Invalid tool: 'EvilTool'"* ]]
}

@test "load_provider rejects invalid provider names (path traversal)" {
    export RALPH_PROVIDER="../../etc/passwd"
    export RALPH_HOME="$BATS_TEST_DIRNAME/../.."
    source "$BATS_TEST_DIRNAME/../../lib/providers/base.sh"
    
    run load_provider
    assert_failure
    [[ "$output" == *"[ERROR] Invalid AI provider name"* ]]
}

@test "load_provider rejects provider names with special characters" {
    export RALPH_PROVIDER="my;provider"
    export RALPH_HOME="$BATS_TEST_DIRNAME/../.."
    source "$BATS_TEST_DIRNAME/../../lib/providers/base.sh"
    
    run load_provider
    assert_failure
    [[ "$output" == *"[ERROR] Invalid AI provider name"* ]]
}