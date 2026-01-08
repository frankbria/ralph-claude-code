#!/usr/bin/env bats

# Test suite for the CLI adapter system
# Tests adapter loading, interface compliance, and core functionality

load '../helpers/test_helper'

setup() {
    # Source the adapter interface
    source "$BATS_TEST_DIRNAME/../../lib/adapters/adapter_interface.sh"
    
    # Set up test environment
    export RALPH_INSTALL_DIR="$BATS_TEST_DIRNAME/../.."
    export TEST_TEMP_DIR=$(mktemp -d)
}

teardown() {
    # Clean up temp directory
    [[ -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# Adapter Interface Tests
# =============================================================================

@test "adapter_interface: base adapter functions exist" {
    # These are default implementations that should always exist
    run adapter_name
    [ "$status" -eq 0 ]
    
    run adapter_id
    [ "$status" -eq 0 ]
    
    run adapter_version
    [ "$status" -eq 0 ]
    
    run adapter_supports
    [ "$status" -eq 0 ]
}

@test "adapter_interface: list_available_adapters returns adapters" {
    run list_available_adapters
    [ "$status" -eq 0 ]
    
    # Should find at least the claude adapter
    [[ "$output" == *"claude"* ]]
}

@test "adapter_interface: list_available_adapters excludes interface files" {
    run list_available_adapters
    [ "$status" -eq 0 ]
    
    # Should not include adapter_interface.sh or adapter_template.sh
    [[ "$output" != *"adapter_interface"* ]]
    [[ "$output" != *"adapter_template"* ]]
}

# =============================================================================
# Claude Adapter Tests
# =============================================================================

@test "claude_adapter: loads successfully" {
    run load_adapter "claude"
    [ "$status" -eq 0 ]
}

@test "claude_adapter: returns correct name" {
    load_adapter "claude"
    
    run adapter_name
    [ "$status" -eq 0 ]
    [ "$output" = "Claude Code" ]
}

@test "claude_adapter: returns correct id" {
    load_adapter "claude"
    
    run adapter_id
    [ "$status" -eq 0 ]
    [ "$output" = "claude" ]
}

@test "claude_adapter: returns version" {
    load_adapter "claude"
    
    run adapter_version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "claude_adapter: supports expected features" {
    load_adapter "claude"
    
    run adapter_supports
    [ "$status" -eq 0 ]
    [[ "$output" == *"streaming"* ]]
    [[ "$output" == *"tools"* ]]
}

@test "claude_adapter: get_config returns valid JSON" {
    load_adapter "claude"
    
    run adapter_get_config
    [ "$status" -eq 0 ]
    
    # Validate it's valid JSON
    echo "$output" | jq . > /dev/null 2>&1
    [ "$?" -eq 0 ]
}

@test "claude_adapter: get_models returns model list" {
    load_adapter "claude"
    
    run adapter_get_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"* ]]
}

@test "claude_adapter: parse_output detects completion" {
    load_adapter "claude"
    
    run adapter_parse_output "All tasks are complete. Nothing left to do."
    [ "$status" -eq 0 ]
    [ "$output" = "COMPLETE" ]
}

@test "claude_adapter: parse_output detects rate limit" {
    load_adapter "claude"
    
    run adapter_parse_output "Error: Rate limit exceeded. Please try again later."
    [ "$status" -eq 0 ]
    [ "$output" = "RATE_LIMITED" ]
}

@test "claude_adapter: parse_output returns CONTINUE for normal output" {
    load_adapter "claude"
    
    run adapter_parse_output "Working on the implementation..."
    [ "$status" -eq 0 ]
    [ "$output" = "CONTINUE" ]
}

@test "claude_adapter: get_install_command returns npm command" {
    load_adapter "claude"
    
    run adapter_get_install_command
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm install"* ]]
}

# =============================================================================
# Aider Adapter Tests
# =============================================================================

@test "aider_adapter: loads successfully" {
    run load_adapter "aider"
    [ "$status" -eq 0 ]
}

@test "aider_adapter: returns correct name" {
    load_adapter "aider"
    
    run adapter_name
    [ "$status" -eq 0 ]
    [ "$output" = "Aider" ]
}

@test "aider_adapter: returns correct id" {
    load_adapter "aider"
    
    run adapter_id
    [ "$status" -eq 0 ]
    [ "$output" = "aider" ]
}

@test "aider_adapter: supports multi-model" {
    load_adapter "aider"
    
    run adapter_supports
    [ "$status" -eq 0 ]
    [[ "$output" == *"multi-model"* ]]
}

@test "aider_adapter: get_models returns various models" {
    load_adapter "aider"
    
    run adapter_get_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"gpt-4"* ]]
    [[ "$output" == *"claude"* ]]
}

@test "aider_adapter: parse_output detects applied edit" {
    load_adapter "aider"
    
    run adapter_parse_output "Applied edit to main.py. No changes needed for utils.py."
    [ "$status" -eq 0 ]
    [ "$output" = "COMPLETE" ]
}

@test "aider_adapter: get_install_command returns pip command" {
    load_adapter "aider"
    
    run adapter_get_install_command
    [ "$status" -eq 0 ]
    [[ "$output" == *"pip install"* ]]
}

# =============================================================================
# Ollama Adapter Tests
# =============================================================================

@test "ollama_adapter: loads successfully" {
    run load_adapter "ollama"
    [ "$status" -eq 0 ]
}

@test "ollama_adapter: returns correct name" {
    load_adapter "ollama"
    
    run adapter_name
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ollama"* ]]
}

@test "ollama_adapter: returns correct id" {
    load_adapter "ollama"
    
    run adapter_id
    [ "$status" -eq 0 ]
    [ "$output" = "ollama" ]
}

@test "ollama_adapter: supports local and offline" {
    load_adapter "ollama"
    
    run adapter_supports
    [ "$status" -eq 0 ]
    [[ "$output" == *"local"* ]]
    [[ "$output" == *"offline"* ]]
}

@test "ollama_adapter: get_models returns local models" {
    load_adapter "ollama"
    
    run adapter_get_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"codellama"* ]] || [[ "$output" == *"llama"* ]]
}

@test "ollama_adapter: rate_limit_status shows unlimited" {
    load_adapter "ollama"
    
    run adapter_get_rate_limit_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"unlimited"* ]]
}

# =============================================================================
# Adapter Loading and Discovery Tests
# =============================================================================

@test "load_adapter: fails gracefully for nonexistent adapter" {
    run load_adapter "nonexistent_adapter_xyz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "get_adapter_info: returns JSON for valid adapter" {
    run get_adapter_info "claude"
    [ "$status" -eq 0 ]
    
    # Should be valid JSON
    echo "$output" | jq . > /dev/null 2>&1
    [ "$?" -eq 0 ]
    
    # Should contain expected fields
    [[ "$output" == *"name"* ]]
    [[ "$output" == *"version"* ]]
}

@test "get_adapter_info: returns error for invalid adapter" {
    run get_adapter_info "nonexistent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error"* ]]
}

@test "verify_adapter_interface: passes for claude adapter" {
    run verify_adapter_interface "claude"
    [ "$status" -eq 0 ]
}

@test "verify_adapter_interface: passes for aider adapter" {
    run verify_adapter_interface "aider"
    [ "$status" -eq 0 ]
}

@test "verify_adapter_interface: passes for ollama adapter" {
    run verify_adapter_interface "ollama"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Auto-Detection and Fallback Tests
# =============================================================================

@test "detect_available_adapter: returns an adapter or empty" {
    run detect_available_adapter
    # Status is 0 if an adapter is found, 1 if not
    # Either way, it should complete without error
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "load_adapter_with_fallback: tries fallback when primary fails" {
    # This test verifies the fallback mechanism works
    # When loading a nonexistent adapter, it should try fallbacks
    run load_adapter_with_fallback "nonexistent_adapter" "claude,aider"
    
    # If claude or aider is available, should succeed
    # If neither is available, should fail gracefully
    [[ "$output" == *"fallback"* ]] || [[ "$output" == *"auto-detect"* ]] || [ "$status" -eq 0 ]
}

@test "get_adapter_capabilities: returns JSON with capabilities" {
    load_adapter "claude"
    
    run get_adapter_capabilities
    [ "$status" -eq 0 ]
    
    # Should be valid JSON
    echo "$output" | jq . > /dev/null 2>&1
    [ "$?" -eq 0 ]
    
    # Should contain capabilities
    [[ "$output" == *"capabilities"* ]]
    [[ "$output" == *"streaming"* ]]
}

# =============================================================================
# Adapter Switching Tests
# =============================================================================

@test "adapter_switching: can switch between adapters" {
    # Load claude
    load_adapter "claude"
    run adapter_id
    [ "$output" = "claude" ]
    
    # Switch to aider
    load_adapter "aider"
    run adapter_id
    [ "$output" = "aider" ]
    
    # Switch to ollama
    load_adapter "ollama"
    run adapter_id
    [ "$output" = "ollama" ]
}

@test "adapter_switching: preserves adapter state" {
    load_adapter "claude"
    [ "$RALPH_LOADED_ADAPTER" = "claude" ]
    
    load_adapter "aider"
    [ "$RALPH_LOADED_ADAPTER" = "aider" ]
}

# =============================================================================
# Configuration Tests
# =============================================================================

@test "claude_adapter: respects RALPH_CLAUDE_TOOLS env var" {
    export RALPH_CLAUDE_TOOLS="Edit,Write,Read"
    load_adapter "claude"
    
    # The adapter should use this configuration
    [ "$CLAUDE_ALLOWED_TOOLS" = "Edit,Write,Read" ]
}

@test "aider_adapter: respects RALPH_AIDER_MODEL env var" {
    export RALPH_AIDER_MODEL="gpt-4o"
    load_adapter "aider"
    
    [ "$AIDER_MODEL" = "gpt-4o" ]
}

@test "ollama_adapter: respects RALPH_OLLAMA_MODEL env var" {
    export RALPH_OLLAMA_MODEL="deepseek-coder"
    load_adapter "ollama"
    
    [ "$OLLAMA_MODEL" = "deepseek-coder" ]
}

# =============================================================================
# Adapter Error Classification Tests
# =============================================================================

@test "claude_adapter: parse_output returns ERROR for real error messages" {
    load_adapter "claude"

    run adapter_parse_output "Error: Failed to compile src/main.ts"
    [ "$status" -eq 0 ]
    [ "$output" = "ERROR" ]
}

@test "claude_adapter: parse_output ignores JSON error fields without real errors" {
    load_adapter "claude"

    local json_output='{ "status": "ok", "is_error": false, "error": null, "error_count": 0 }'
    run adapter_parse_output "$json_output"
    [ "$status" -eq 0 ]
    [ "$output" = "CONTINUE" ]
}

@test "aider_adapter: parse_output returns ERROR on API errors" {
    load_adapter "aider"

    local output="API error: RateLimitError: You have hit the maximum number of requests"
    run adapter_parse_output "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "ERROR" ]
}

@test "aider_adapter: parse_output returns ERROR on git conflicts" {
    load_adapter "aider"

    local output="Merge conflict detected in main.py. git error: merge failed"
    run adapter_parse_output "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "ERROR" ]
}

@test "ollama_adapter: parse_output returns ERROR for Ollama-specific errors" {
    load_adapter "ollama"

    local output="Error from Ollama: model codellama not found locally"
    run adapter_parse_output "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "ERROR" ]
}
