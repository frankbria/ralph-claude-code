#!/usr/bin/env bats
# tests/evals/deterministic/test_tool_restrictions.bats
# EVALS-2: Verifies tool safety via PreToolUse hooks.
#
# Tests that:
#   - Destructive git commands are blocked by validate-command.sh
#   - .ralph/ file modifications are blocked by protect-ralph-files.sh
#
# These tests simulate the hook execution WITHOUT making any LLM calls.

load '../../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../../.."
VALIDATE_CMD="${PROJECT_ROOT}/templates/hooks/validate-command.sh"
PROTECT_FILES="${PROJECT_ROOT}/templates/hooks/protect-ralph-files.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR=".ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
    mkdir -p "$RALPH_DIR/logs" "$RALPH_DIR/hooks"

    # Ensure hook scripts exist
    [[ -f "$VALIDATE_CMD" ]] || skip "validate-command.sh not found"
    [[ -f "$PROTECT_FILES" ]] || skip "protect-ralph-files.sh not found"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: simulate a Bash tool call to validate-command.sh
# $1 = command string to test
# Returns the hook's exit code (0=allow, 2=block)
run_validate_command() {
    local command="$1"
    local input_json
    input_json=$(jq -n --arg cmd "$command" '{"tool_name": "Bash", "tool_input": {"command": $cmd}}')
    echo "$input_json" | bash "$VALIDATE_CMD"
}

# Helper: simulate an Edit/Write tool call to protect-ralph-files.sh
# $1 = file path to test
# Returns the hook's exit code (0=allow, 2=block)
run_protect_files() {
    local file_path="$1"
    local input_json
    input_json=$(jq -n --arg fp "$file_path" '{"tool_name": "Edit", "tool_input": {"file_path": $fp}}')
    echo "$input_json" | bash "$PROTECT_FILES"
}

# =============================================================================
# DESTRUCTIVE GIT COMMANDS (validate-command.sh)
# =============================================================================

@test "TOOL SAFETY: blocks 'git reset --hard'" {
    run run_validate_command "git reset --hard HEAD~1"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git clean'" {
    run run_validate_command "git clean -fd"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git push --force'" {
    run run_validate_command "git push --force origin main"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git push -f'" {
    run run_validate_command "git push -f origin main"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'rm -rf'" {
    run run_validate_command "rm -rf /some/directory"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git rm'" {
    run run_validate_command "git rm important-file.js"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git commit --no-verify'" {
    run run_validate_command "git commit --no-verify -m 'skip hooks'"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git commit -n' (short for --no-verify)" {
    run run_validate_command "git commit -n -m 'skip hooks'"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks 'git push --no-verify'" {
    run run_validate_command "git push --no-verify origin main"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks '--no-gpg-sign' on commits" {
    run run_validate_command "git commit --no-gpg-sign -m 'unsigned'"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks shell modification of .ralph/ directory" {
    run run_validate_command "rm .ralph/PROMPT.md"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "TOOL SAFETY: blocks shell modification of .claude/ directory" {
    run run_validate_command "rm .claude/settings.json"
    assert_failure
    [[ "$status" -eq 2 ]]
}

# =============================================================================
# ALLOWED COMMANDS (validate-command.sh)
# =============================================================================

@test "TOOL SAFETY: allows normal git commands" {
    run run_validate_command "git status"
    assert_success
}

@test "TOOL SAFETY: allows git add" {
    run run_validate_command "git add ."
    assert_success
}

@test "TOOL SAFETY: allows git commit (without --no-verify)" {
    run run_validate_command "git commit -m 'normal commit'"
    assert_success
}

@test "TOOL SAFETY: allows git push (without --force)" {
    run run_validate_command "git push origin feature-branch"
    assert_success
}

@test "TOOL SAFETY: allows git push --force-with-lease (safer alternative)" {
    run run_validate_command "git push --force-with-lease origin feature-branch"
    assert_success
}

@test "TOOL SAFETY: allows normal shell commands" {
    run run_validate_command "ls -la"
    assert_success
}

@test "TOOL SAFETY: allows npm test" {
    run run_validate_command "npm test"
    assert_success
}

# =============================================================================
# .ralph/ FILE PROTECTION (protect-ralph-files.sh)
# =============================================================================

@test "FILE PROTECTION: blocks edit to .ralph/PROMPT.md" {
    run run_protect_files ".ralph/PROMPT.md"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "FILE PROTECTION: blocks edit to .ralph/AGENT.md" {
    run run_protect_files ".ralph/AGENT.md"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "FILE PROTECTION: blocks edit to .ralph/.call_count" {
    run run_protect_files ".ralph/.call_count"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "FILE PROTECTION: blocks edit to .ralph/.exit_signals" {
    run run_protect_files ".ralph/.exit_signals"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "FILE PROTECTION: blocks edit to existing .ralphrc" {
    # The hook's contract (HOOKS-5 in tests/unit/test_hooks.bats) is:
    # ALLOW creating a new .ralphrc when absent, BLOCK editing once it
    # exists. The previous form of this test prepared no fixture, so it
    # asserted the wrong half of the contract — eval went red the moment
    # the eval suite started running end-to-end (post bats count fix).
    touch .ralphrc
    run run_protect_files ".ralphrc"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "FILE PROTECTION: allows creating new .ralphrc when absent (HOOKS-5)" {
    [[ ! -f .ralphrc ]] || rm -f .ralphrc
    run run_protect_files ".ralphrc"
    assert_success
}

@test "FILE PROTECTION: allows edit to .ralph/fix_plan.md (agent checks off tasks)" {
    run run_protect_files ".ralph/fix_plan.md"
    assert_success
}

@test "FILE PROTECTION: allows edit to .ralph/status.json (hooks write this)" {
    run run_protect_files ".ralph/status.json"
    assert_success
}

@test "FILE PROTECTION: allows edit to normal project files" {
    run run_protect_files "src/index.js"
    assert_success
}

@test "FILE PROTECTION: allows edit to test files" {
    run run_protect_files "tests/unit/test_example.bats"
    assert_success
}
