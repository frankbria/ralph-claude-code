#!/usr/bin/env bats
# Unit tests for compound-command permission-denial detection helpers
# (lib/response_analyzer.sh, issue #243).
#
# Covers _extract_base_command and _base_command_in_allowed_tools.

load '../helpers/test_helper'

RESPONSE_ANALYZER="${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    source "$RESPONSE_ANALYZER"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# -----------------------------------------------------------------------------
# _extract_base_command
# -----------------------------------------------------------------------------

@test "_extract_base_command: single command" {
    result="$(_extract_base_command "mvn")"
    assert_equal "$result" "mvn"
}

@test "_extract_base_command: command with arguments" {
    result="$(_extract_base_command "mvn clean compile")"
    assert_equal "$result" "mvn"
}

@test "_extract_base_command: command with pipe (the #243 case)" {
    result="$(_extract_base_command "mvn clean compile 2>&1 | tail -40")"
    assert_equal "$result" "mvn"
}

@test "_extract_base_command: command with leading whitespace" {
    result="$(_extract_base_command "   git status")"
    assert_equal "$result" "git"
}

@test "_extract_base_command: command with redirect immediately after" {
    result="$(_extract_base_command "mvn>output.log")"
    assert_equal "$result" "mvn"
}

@test "_extract_base_command: empty input returns empty" {
    result="$(_extract_base_command "")"
    assert_equal "$result" ""
}

@test "_extract_base_command: pipe-only input returns empty" {
    result="$(_extract_base_command "| tail")"
    assert_equal "$result" ""
}

# -----------------------------------------------------------------------------
# _base_command_in_allowed_tools — positive matches
# -----------------------------------------------------------------------------

@test "_base_command_in_allowed_tools: Bash(mvn *) covers mvn" {
    run _base_command_in_allowed_tools "mvn" "Write,Read,Bash(mvn *)"
    assert_success
}

@test "_base_command_in_allowed_tools: Bash(git *) covers git" {
    run _base_command_in_allowed_tools "git" "Bash(git *),Bash(npm *)"
    assert_success
}

@test "_base_command_in_allowed_tools: Bash(*) covers anything" {
    run _base_command_in_allowed_tools "rm" "Bash(*)"
    assert_success
}

@test "_base_command_in_allowed_tools: literal '*' wildcard entry" {
    run _base_command_in_allowed_tools "ls" "*"
    assert_success
}

@test "_base_command_in_allowed_tools: Bash(npm*) (no space) covers npm" {
    run _base_command_in_allowed_tools "npm" "Bash(npm*)"
    assert_success
}

@test "_base_command_in_allowed_tools: Bash(git diff *) covers git" {
    # Multi-word patterns ending in * also cover the base
    run _base_command_in_allowed_tools "git" "Bash(git diff *)"
    assert_success
}

@test "_base_command_in_allowed_tools: tolerates whitespace around commas" {
    run _base_command_in_allowed_tools "mvn" "Write, Read , Bash(mvn *) , Bash(npm *)"
    assert_success
}

# -----------------------------------------------------------------------------
# _base_command_in_allowed_tools — negative matches (no false positives)
# -----------------------------------------------------------------------------

@test "_base_command_in_allowed_tools: exact Bash(npm install) does NOT cover npm" {
    # Exact-only pattern doesn't grant arbitrary args
    run _base_command_in_allowed_tools "npm" "Bash(npm install)"
    assert_failure
}

@test "_base_command_in_allowed_tools: exact Bash(git status) does NOT cover git" {
    run _base_command_in_allowed_tools "git" "Bash(git status)"
    assert_failure
}

@test "_base_command_in_allowed_tools: pattern for different command does not cover" {
    run _base_command_in_allowed_tools "mvn" "Bash(npm *),Bash(git *)"
    assert_failure
}

@test "_base_command_in_allowed_tools: empty allowed_tools returns failure" {
    run _base_command_in_allowed_tools "mvn" ""
    assert_failure
}

@test "_base_command_in_allowed_tools: empty base_cmd returns failure" {
    run _base_command_in_allowed_tools "" "Bash(*)"
    assert_failure
}

@test "_base_command_in_allowed_tools: non-Bash entries are ignored" {
    run _base_command_in_allowed_tools "mvn" "Write,Read,Edit"
    assert_failure
}

@test "_base_command_in_allowed_tools: prefix collisions don't match (git ≠ gitlab)" {
    # Bash(gitlab *) should NOT cover base "git"
    run _base_command_in_allowed_tools "git" "Bash(gitlab *)"
    assert_failure
}

# -----------------------------------------------------------------------------
# parse_json_response — end-to-end behavior for compound-command denials
# -----------------------------------------------------------------------------

# Helper: minimal Claude Code output JSON with a permission_denials array
_write_denial_output() {
    local file="$1"
    local tool_name="$2"
    local denied_command="$3"
    cat > "$file" <<EOF
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "permission_denials": [
    {"tool_name": "$tool_name", "tool_input": {"command": "$denied_command"}}
  ]
}
EOF
}

@test "parse_json_response: marks compound-command limitation when base is allowed (#243)" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_denial_output "$output_file" "Bash" "mvn clean compile 2>&1 | tail -40"

    export CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(mvn *),Bash(git *)"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "true"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.compound_command_count' "$result_file")" "1"
}

@test "parse_json_response: keeps real denial when base is NOT allowed" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_denial_output "$output_file" "Bash" "curl http://example.com"

    export CLAUDE_ALLOWED_TOOLS="Write,Read,Bash(mvn *),Bash(git *)"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: non-Bash denial keeps halt behavior" {
    # AskUserQuestion denial is never a compound-command issue
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_denial_output "$output_file" "AskUserQuestion" ""

    export CLAUDE_ALLOWED_TOOLS="Write,Read,Bash(*)"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: mixed Bash + non-Bash denials keep halt behavior" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    cat > "$output_file" <<'EOF'
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "permission_denials": [
    {"tool_name": "Bash", "tool_input": {"command": "mvn clean | tail"}},
    {"tool_name": "AskUserQuestion", "tool_input": {}}
  ]
}
EOF
    export CLAUDE_ALLOWED_TOOLS="Bash(mvn *)"
    parse_json_response "$output_file" "$result_file"

    # Compound limitation only applies when ALL denials are Bash-and-covered
    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: empty CLAUDE_ALLOWED_TOOLS does not break detection" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_denial_output "$output_file" "Bash" "mvn install"

    unset CLAUDE_ALLOWED_TOOLS
    parse_json_response "$output_file" "$result_file"

    # No allowed_tools to compare against → cannot mark as compound limitation
    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: no denials → both flags false" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    cat > "$output_file" <<'EOF'
{"status": "COMPLETE", "session_id": "test-session"}
EOF
    export CLAUDE_ALLOWED_TOOLS="Bash(*)"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_compound_command_limitation' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.compound_command_count' "$result_file")" "0"
}
