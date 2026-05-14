#!/usr/bin/env bats
# TAP-1684 — parallel epic-boundary QA: aggregator + in-flight guard.
#
# Two harness-side surfaces are tested here:
#   1. exec_aggregate_qa_results (lib/exec_helpers.sh) — collapses three
#      sub-agent verdicts to a single PASS / FAIL with the failing agent
#      named in the result. Mirrors the rule the ralph-workflow skill
#      tells Claude to apply in prose.
#   2. on-subagent-done.sh in-flight guard — defers CB updates while
#      >1 agent is still in flight, by maintaining a sidecar file and a
#      defer flag that downstream CB sites read.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    : > "$TEST_TEMP_DIR/.ralph/live.log"
    # exec_helpers.sh is sourceable standalone (its log helpers no-op
    # when log_status is missing); we only need the aggregator.
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/exec_helpers.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# exec_aggregate_qa_results — aggregation rule
# =============================================================================

@test "TAP-1684: all three PASS aggregates to PASS" {
    run exec_aggregate_qa_results \
        ralph-tester PASS \
        ralph-reviewer PASS \
        tapps-validator PASS
    assert_success
    assert_output "PASS"
}

@test "TAP-1684: a single FAIL aggregates to FAIL, names the agent" {
    run exec_aggregate_qa_results \
        ralph-tester PASS \
        ralph-reviewer FAIL \
        tapps-validator PASS
    assert_failure
    [[ "$output" == "FAIL: ralph-reviewer (FAIL)" ]]
}

@test "TAP-1684: TIMEOUT collapses to FAIL with kind=TIMEOUT" {
    run exec_aggregate_qa_results \
        ralph-tester PASS \
        ralph-reviewer PASS \
        tapps-validator TIMEOUT
    assert_failure
    [[ "$output" == "FAIL: tapps-validator (TIMEOUT)" ]]
}

@test "TAP-1684: two failures list both names in argument order" {
    run exec_aggregate_qa_results \
        ralph-tester FAIL \
        ralph-reviewer PASS \
        tapps-validator TIMEOUT
    assert_failure
    [[ "$output" == "FAIL: ralph-tester, tapps-validator (FAIL)" ]]
}

@test "TAP-1684: lowercase verdicts are normalized" {
    run exec_aggregate_qa_results \
        ralph-tester pass \
        ralph-reviewer pass \
        tapps-validator pass
    assert_success
    assert_output "PASS"
}

@test "TAP-1684: unknown verdict is treated as FAIL (defensive)" {
    run exec_aggregate_qa_results \
        ralph-tester PASS \
        ralph-reviewer PASS \
        tapps-validator GIBBERISH
    assert_failure
    [[ "$output" == "FAIL: tapps-validator (FAIL)" ]]
}

@test "TAP-1684: wrong agent count (2 pairs) returns FAIL" {
    run exec_aggregate_qa_results ralph-tester PASS ralph-reviewer PASS
    assert_failure
    [[ "$output" == *"bad-agent-count"* ]]
}

@test "TAP-1684: wrong agent count (4 pairs) returns FAIL" {
    run exec_aggregate_qa_results \
        ralph-tester PASS \
        ralph-reviewer PASS \
        tapps-validator PASS \
        extra-agent PASS
    assert_failure
    [[ "$output" == *"bad-agent-count"* ]]
}

# =============================================================================
# on-subagent-done.sh in-flight guard
# =============================================================================

_hook_input() {
    local id="$1"
    local name="${2:-ralph-tester}"
    local err="${3:-}"
    printf '{"agent_id":"%s","agent_name":"%s","duration_ms":1000,"error":"%s"}' \
        "$id" "$name" "$err"
}

_seed_inflight() {
    local f="$TEST_TEMP_DIR/.ralph/.subagent_in_flight"
    : > "$f"
    for id in "$@"; do
        printf '%s\n' "$id" >> "$f"
    done
}

@test "TAP-1684: first completion leaves 2 agents in flight + sets defer flag" {
    _seed_inflight ag-tester ag-reviewer ag-validator
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-tester ralph-tester)" >/dev/null 2>&1
    run wc -l < "$TEST_TEMP_DIR/.ralph/.subagent_in_flight"
    [[ "$(echo "$output" | tr -d ' ')" == "2" ]]
    [[ -f "$TEST_TEMP_DIR/.ralph/.subagent_defer_cb" ]]
    run grep -q "IN-FLIGHT GUARD" "$TEST_TEMP_DIR/.ralph/live.log"
    assert_success
}

@test "TAP-1684: second completion leaves 1 agent in flight + keeps defer flag" {
    _seed_inflight ag-tester ag-reviewer ag-validator
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-tester ralph-tester)" >/dev/null 2>&1
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-reviewer ralph-reviewer)" >/dev/null 2>&1
    run wc -l < "$TEST_TEMP_DIR/.ralph/.subagent_in_flight"
    [[ "$(echo "$output" | tr -d ' ')" == "1" ]]
    [[ -f "$TEST_TEMP_DIR/.ralph/.subagent_defer_cb" ]]
}

@test "TAP-1684: last completion clears the in-flight set + defer flag" {
    _seed_inflight ag-tester ag-reviewer ag-validator
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-tester ralph-tester)" >/dev/null 2>&1
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-reviewer ralph-reviewer)" >/dev/null 2>&1
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-validator tapps-validator)" >/dev/null 2>&1
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.subagent_in_flight" ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.subagent_defer_cb" ]]
    run grep -q "FAN-OUT COMPLETE" "$TEST_TEMP_DIR/.ralph/live.log"
    assert_success
}

@test "TAP-1684: hook is a no-op when no in-flight sidecar exists (serial mode)" {
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<"$(_hook_input ag-explorer ralph-explorer)" >/dev/null 2>&1
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.subagent_defer_cb" ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.subagent_in_flight" ]]
    run grep -q "SUBAGENT DONE" "$TEST_TEMP_DIR/.ralph/live.log"
    assert_success
}

@test "TAP-1684: completion with unknown agent_id is logged but does not mutate set" {
    _seed_inflight ag-a ag-b ag-c
    bash "$REPO_ROOT/templates/hooks/on-subagent-done.sh" \
        <<<'{"agent_id":"unknown","agent_name":"unknown","duration_ms":0,"error":""}' \
        >/dev/null 2>&1
    run wc -l < "$TEST_TEMP_DIR/.ralph/.subagent_in_flight"
    [[ "$(echo "$output" | tr -d ' ')" == "3" ]]
}

# =============================================================================
# Contract: skill + agent file mention parallel fan-out
# =============================================================================

@test "TAP-1684: ralph-workflow skill mandates parallel Task dispatch with the worked example" {
    local skill="$REPO_ROOT/templates/skills-local/ralph-workflow/SKILL.md"
    run grep -F "Parallel QA fan-out" "$skill"
    assert_success
    run grep -F "TAP-1684" "$skill"
    assert_success
    run grep -F "Task(ralph-tester," "$skill"
    assert_success
    run grep -F "Task(ralph-reviewer," "$skill"
    assert_success
    run grep -F "Task(tapps-validator," "$skill"
    assert_success
    run grep -F "FAIL or TIMEOUT" "$skill"
    assert_success
}

@test "TAP-1684: .claude/agents/ralph.md mirrors the parallel-fan-out directive" {
    local agent="$REPO_ROOT/.claude/agents/ralph.md"
    run grep -F "TAP-1684" "$agent"
    assert_success
    run grep -F "Parallel QA fan-out" "$agent"
    assert_success
    run grep -F "Task(ralph-tester," "$agent"
    assert_success
}
