#!/usr/bin/env bats
# Unit tests for opt-in hook-retry-recovery permission-denial detection
# (lib/response_analyzer.sh, TRUST_INTURN_RECOVERY).
#
# Covers a false positive where a PreToolUse hook denies a Write/Edit tool
# call with a corrective message, Claude retries and succeeds within the
# same turn (is_error=false, stop_reason=end_turn), but the next loop still
# halted because the denial appeared somewhere in the transcript. Off by
# default: enabling TRUST_INTURN_RECOVERY trades some of the Issue #101
# silent-loop protection for fewer false-positive halts on this pattern.

load '../helpers/test_helper'

RESPONSE_ANALYZER="${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    source "$RESPONSE_ANALYZER"
    unset TRUST_INTURN_RECOVERY
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# -----------------------------------------------------------------------------
# parse_json_response: flag gating
# -----------------------------------------------------------------------------

_write_clean_turn_denial() {
    local file="$1"
    local tool_name="$2"
    cat > "$file" <<EOF
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "is_error": false,
  "stop_reason": "end_turn",
  "permission_denials": [
    {"tool_name": "$tool_name", "tool_input": {"file_path": "/tmp/x"}}
  ]
}
EOF
}

@test "parse_json_response: flag unset (default) keeps halt on Write denial with clean turn" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_clean_turn_denial "$output_file" "Write"

    unset TRUST_INTURN_RECOVERY
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: flag explicitly false keeps halt on Write denial with clean turn" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_clean_turn_denial "$output_file" "Write"

    export TRUST_INTURN_RECOVERY="false"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: flag ON downgrades Write denial with clean turn to advisory" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    _write_clean_turn_denial "$output_file" "Write"

    export TRUST_INTURN_RECOVERY="true"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "true"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.hook_recovered_denial_count' "$result_file")" "1"
}

@test "parse_json_response: flag ON covers Edit, NotebookEdit, MultiEdit the same as Write" {
    for tool in Edit NotebookEdit MultiEdit; do
        local output_file="$TEST_DIR/output_$tool.json"
        local result_file="$TEST_DIR/result_$tool.json"
        _write_clean_turn_denial "$output_file" "$tool"

        export TRUST_INTURN_RECOVERY="true"
        parse_json_response "$output_file" "$result_file"

        assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "true"
    done
}

# -----------------------------------------------------------------------------
# parse_json_response: flag ON, but the turn did NOT end cleanly (real denial)
# -----------------------------------------------------------------------------

@test "parse_json_response: flag ON keeps halt when is_error is true (turn failed)" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    cat > "$output_file" <<'EOF'
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "is_error": true,
  "stop_reason": "end_turn",
  "permission_denials": [
    {"tool_name": "Write", "tool_input": {"file_path": "/tmp/x"}}
  ]
}
EOF
    export TRUST_INTURN_RECOVERY="true"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

# -----------------------------------------------------------------------------
# parse_json_response: flag ON, but the denial is out of scope for this flag
# -----------------------------------------------------------------------------

@test "parse_json_response: flag ON does not cover Bash denials (Issue #243's own path handles those)" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    cat > "$output_file" <<'EOF'
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "is_error": false,
  "stop_reason": "end_turn",
  "permission_denials": [
    {"tool_name": "Bash", "tool_input": {"command": "rm -rf /tmp/x"}}
  ]
}
EOF
    export TRUST_INTURN_RECOVERY="true"
    export CLAUDE_ALLOWED_TOOLS="Write,Read"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

@test "parse_json_response: flag ON keeps halt on mixed Write + AskUserQuestion denials (real gap)" {
    local output_file="$TEST_DIR/output.json"
    local result_file="$TEST_DIR/result.json"
    cat > "$output_file" <<'EOF'
{
  "status": "IN_PROGRESS",
  "session_id": "test-session",
  "is_error": false,
  "stop_reason": "end_turn",
  "permission_denials": [
    {"tool_name": "Write", "tool_input": {"file_path": "/tmp/x"}},
    {"tool_name": "AskUserQuestion", "tool_input": {}}
  ]
}
EOF
    export TRUST_INTURN_RECOVERY="true"
    parse_json_response "$output_file" "$result_file"

    assert_equal "$(jq -r '.has_hook_recovered_denials' "$result_file")" "false"
    assert_equal "$(jq -r '.has_permission_denials' "$result_file")" "true"
}

# -----------------------------------------------------------------------------
# analyze_response: end-to-end wiring through to .response_analysis
# -----------------------------------------------------------------------------
#
# parse_json_response is called BY analyze_response and its result is
# re-extracted and re-packaged into the final RESPONSE_ANALYSIS_FILE that
# ralph_loop.sh's should_exit_gracefully() actually reads (under .analysis.*).
# These tests exercise that full path so a wiring gap between the two
# jq-construction sites (parse_json_response's own output vs. the
# re-packaged analysis: {...} block inside analyze_response) would fail
# here even if the parse_json_response-only tests above pass.

@test "analyze_response: flag ON propagates has_hook_recovered_denials into .analysis" {
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"

    local output_file="$TEST_DIR/claude_output.json"
    _write_clean_turn_denial "$output_file" "Write"

    export TRUST_INTURN_RECOVERY="true"
    analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"

    assert_equal "$(jq -r '.analysis.has_hook_recovered_denials' "$RALPH_DIR/.response_analysis")" "true"
    assert_equal "$(jq -r '.analysis.has_permission_denials' "$RALPH_DIR/.response_analysis")" "false"
    assert_equal "$(jq -r '.analysis.hook_recovered_denial_count' "$RALPH_DIR/.response_analysis")" "1"
}

@test "analyze_response: flag unset (default) propagates halt-preserving false into .analysis" {
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"

    local output_file="$TEST_DIR/claude_output.json"
    _write_clean_turn_denial "$output_file" "Write"

    unset TRUST_INTURN_RECOVERY
    analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"

    assert_equal "$(jq -r '.analysis.has_hook_recovered_denials' "$RALPH_DIR/.response_analysis")" "false"
    assert_equal "$(jq -r '.analysis.has_permission_denials' "$RALPH_DIR/.response_analysis")" "true"
}
