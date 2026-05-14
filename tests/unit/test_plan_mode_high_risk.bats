#!/usr/bin/env bats
# TAP-1686 — Plan Mode for HIGH-risk coordinator verdicts.
#
# Three surfaces:
#   1. build_claude_command (ralph_loop.sh) honors RALPH_PERMISSION_MODE
#      and appends `--permission-mode <mode>` to CLAUDE_CMD_ARGS.
#   2. build_loop_context (ralph_loop.sh) sets RALPH_PERMISSION_MODE=plan
#      when .ralph/brief.json has risk_level=HIGH (and respects an
#      operator-set override).
#   3. on-stop.sh treats WORK_TYPE: PLANNING with a valid status block as
#      productive — no consecutive_no_progress increment.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    export RALPH_LOOP_ACTIVE=1     # bypass TAP-1531 session guard
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    : > "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
    # Seed a closed CB so the on-stop branch under test mutates a real file.
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LOOP_ACTIVE
    unset RALPH_PERMISSION_MODE
}

_write_brief() {
    local risk="${1:-HIGH}"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    cat > "$TEST_TEMP_DIR/.ralph/brief.json" <<EOF
{
  "task_summary": "do the thing",
  "risk_level": "$risk",
  "affected_modules": ["lib/foo.sh"],
  "acceptance_criteria": ["AC1"],
  "prior_learnings": [],
  "qa_required": false
}
EOF
}

# =============================================================================
# build_claude_command — RALPH_PERMISSION_MODE wires --permission-mode
# =============================================================================

_source_build_claude_command() {
    # Stub everything build_claude_command touches that we don't need to
    # exercise for the permission-mode assertion, then pull just the
    # function body.
    log_status() { :; }
    ralph_scope_prompt_for_service() { cat; }
    ralph_build_progressive_context() { echo ""; }
    ralph_classify_task_type() { echo "code"; }
    ralph_select_model() { echo "sonnet"; }
    ralph_should_skip_resume() { return 1; }
    portable_timeout() { :; }
    check_agent_support() { return 0; }
    export -f log_status ralph_scope_prompt_for_service \
              ralph_build_progressive_context ralph_classify_task_type \
              ralph_select_model ralph_should_skip_resume portable_timeout \
              check_agent_support

    eval "$(awk '/^build_claude_command\(\) \{$/,/^}$/' "$REPO_ROOT/ralph_loop.sh")"

    # Globals build_claude_command reads.
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    export RALPH_AGENT_NAME="ralph"
    declare -ga CLAUDE_CMD_ARGS=()
    # Minimum viable prompt file.
    echo "do work" > "$TEST_TEMP_DIR/PROMPT.md"
}

@test "TAP-1686: build_claude_command appends --permission-mode when RALPH_PERMISSION_MODE=plan" {
    _source_build_claude_command
    export RALPH_PERMISSION_MODE="plan"
    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true
    # Stringify the args array so we can grep.
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" == *"--permission-mode plan"* ]]
}

@test "TAP-1686: build_claude_command omits --permission-mode when RALPH_PERMISSION_MODE is unset" {
    _source_build_claude_command
    unset RALPH_PERMISSION_MODE
    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" != *"--permission-mode"* ]]
}

@test "TAP-1686: build_claude_command pass-through for non-plan modes (e.g. acceptEdits)" {
    _source_build_claude_command
    export RALPH_PERMISSION_MODE="acceptEdits"
    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" == *"--permission-mode acceptEdits"* ]]
}

# =============================================================================
# build_loop_context — risk_level=HIGH → RALPH_PERMISSION_MODE=plan
# =============================================================================

_source_build_loop_context() {
    log_status() { :; }
    ralph_sanitize_prompt_text() { local n="${1:-300}"; tr -d '\0' | head -c "$n"; }
    linear_get_open_count()        { return 1; }
    linear_get_in_progress_task()  { echo ""; }
    linear_get_next_task()         { echo ""; }
    ralph_inject_continue_state()  { echo ""; }
    ralph_probe_mcp_servers()      { :; }
    ralph_task_is_docs_related()   { return 1; }
    export -f log_status ralph_sanitize_prompt_text \
              linear_get_open_count linear_get_in_progress_task \
              linear_get_next_task ralph_inject_continue_state \
              ralph_probe_mcp_servers ralph_task_is_docs_related

    eval "$(awk '/^build_loop_context\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_CONTINUE_STATE_FILE="$TEST_TEMP_DIR/.ralph/.nonexistent"
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    export SCRIPT_DIR="$REPO_ROOT"
}

@test "TAP-1686: build_loop_context exports RALPH_PERMISSION_MODE=plan on HIGH-risk brief" {
    _source_build_loop_context
    _write_brief HIGH
    unset RALPH_PERMISSION_MODE
    # Brief becomes visible only if it exists AND is non-empty.
    [[ -s "$TEST_TEMP_DIR/.ralph/brief.json" ]]
    build_loop_context 7 >/dev/null
    [[ "${RALPH_PERMISSION_MODE:-}" == "plan" ]]
}

@test "TAP-1686: build_loop_context leaves RALPH_PERMISSION_MODE unset on LOW-risk brief" {
    _source_build_loop_context
    _write_brief LOW
    unset RALPH_PERMISSION_MODE
    build_loop_context 7 >/dev/null
    [[ -z "${RALPH_PERMISSION_MODE:-}" ]]
}

@test "TAP-1686: build_loop_context leaves RALPH_PERMISSION_MODE unset on MEDIUM-risk brief" {
    _source_build_loop_context
    _write_brief MEDIUM
    unset RALPH_PERMISSION_MODE
    build_loop_context 7 >/dev/null
    [[ -z "${RALPH_PERMISSION_MODE:-}" ]]
}

@test "TAP-1686: build_loop_context leaves RALPH_PERMISSION_MODE unset when brief.json missing" {
    _source_build_loop_context
    rm -f "$TEST_TEMP_DIR/.ralph/brief.json"
    unset RALPH_PERMISSION_MODE
    build_loop_context 7 >/dev/null
    [[ -z "${RALPH_PERMISSION_MODE:-}" ]]
}

@test "TAP-1686: build_loop_context preserves operator-set override (does not clobber)" {
    _source_build_loop_context
    _write_brief HIGH
    export RALPH_PERMISSION_MODE="bypassPermissions"
    build_loop_context 7 >/dev/null
    # Operator's pin survives.
    [[ "$RALPH_PERMISSION_MODE" == "bypassPermissions" ]]
}

@test "TAP-1686: build_loop_context HIGH-risk injects PLAN MODE ACTIVE directive into context" {
    _source_build_loop_context
    _write_brief HIGH
    unset RALPH_PERMISSION_MODE
    run build_loop_context 7
    assert_success
    [[ "$output" == *"PLAN MODE ACTIVE (TAP-1686)"* ]]
    [[ "$output" == *"WORK_TYPE: PLANNING"* ]]
}

# =============================================================================
# on-stop.sh — WORK_TYPE: PLANNING is productive
# =============================================================================

_planning_input() {
    cat <<'JSON'
{"result":"I will:\n1. add X to lib/foo.sh\n2. update tests\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: PLANNING\nEXIT_SIGNAL: false\nRECOMMENDATION: Plan posted; next loop should execute.\n---END_RALPH_STATUS---"}
JSON
}

_no_progress_input() {
    cat <<'JSON'
{"result":"---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: still working\n---END_RALPH_STATUS---"}
JSON
}

@test "TAP-1686: on-stop.sh treats WORK_TYPE: PLANNING as productive (no_progress=0)" {
    bash "$HOOK" <<<"$(_planning_input)" >/dev/null 2>&1
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "TAP-1686: on-stop.sh does increment no_progress for non-PLANNING zero-file loops" {
    bash "$HOOK" <<<"$(_no_progress_input)" >/dev/null 2>&1
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "1"
}

@test "TAP-1686: on-stop.sh PLANNING branch logs the TAP-1686 marker for grep-ability" {
    bash "$HOOK" <<<"$(_planning_input)" >/dev/null 2>&1
    run grep -F "TAP-1686 Plan Mode loop" "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
    assert_success
}

@test "TAP-1686: on-stop.sh PLANNING WITHOUT a status block still falls through to no-progress" {
    # Plan Mode legitimacy requires both WORK_TYPE: PLANNING AND a parseable
    # RALPH_STATUS block. A bare planning-flavored response without the block
    # should still increment no_progress so the CB catches a stuck planner.
    bash "$HOOK" <<<'{"result":"I will plan it but did not emit a status block."}' >/dev/null 2>&1
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "1"
}
