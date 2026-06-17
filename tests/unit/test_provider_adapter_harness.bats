#!/usr/bin/env bats
# Unit tests for generic provider adapter harness helpers.

load '../helpers/test_helper'
load '../helpers/provider_adapter_harness'

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../fixtures/providers/claude" && pwd)"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "provider adapter harness validates normalized Claude fixture schema" {
    run adapter_harness_assert_normalized_output_schema "$TEST_FIXTURES_DIR/normalized_success.json"

    assert_success
}

@test "provider adapter harness validates Claude capabilities fixture schema" {
    run adapter_harness_assert_capabilities_schema "$TEST_FIXTURES_DIR/capabilities.json"

    assert_success
}

@test "provider adapter harness mock CLI records argv and emits fixture output" {
    local mock_cli="$TEST_TEMP_DIR/mock-claude"
    local argv_capture="$TEST_TEMP_DIR/mock-claude.argv"
    local output_file="$TEST_TEMP_DIR/mock-claude.out"

    adapter_harness_create_mock_cli \
        "$mock_cli" \
        "$TEST_FIXTURES_DIR/normalized_success.json" \
        "$argv_capture"

    run "$mock_cli" --output-format json --model test-model -p "Implement the next task"

    assert_success
    printf '%s\n' "$output" > "$output_file"

    adapter_harness_assert_normalized_output_schema "$output_file"
    adapter_harness_assert_json_value "$output_file" '.provider' "claude"
    adapter_harness_assert_argv_contains "$argv_capture" "--output-format"
    adapter_harness_assert_argv_contains "$argv_capture" "json"
    adapter_harness_assert_argv_contains "$argv_capture" "--model"
    adapter_harness_assert_argv_contains "$argv_capture" "test-model"
    adapter_harness_assert_argv_contains "$argv_capture" "-p"
    adapter_harness_assert_argv_contains "$argv_capture" "Implement the next task"
    adapter_harness_assert_argv_not_contains "$argv_capture" "--resume"
}

@test "provider adapter harness surfaces mock CLI exit codes without real provider calls" {
    local mock_cli="$TEST_TEMP_DIR/mock-claude-failure"
    local argv_capture="$TEST_TEMP_DIR/mock-claude-failure.argv"

    adapter_harness_create_mock_cli \
        "$mock_cli" \
        "$TEST_FIXTURES_DIR/normalized_success.json" \
        "$argv_capture" \
        42

    run "$mock_cli" --output-format json

    assert_equal 42 "$status"
    adapter_harness_assert_argv_contains "$argv_capture" "--output-format"
    adapter_harness_assert_argv_contains "$argv_capture" "json"
}
