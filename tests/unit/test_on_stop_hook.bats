#!/usr/bin/env bats
# TAP-538: Tests for templates/hooks/on-stop.sh resilience and parity.
#
# Focus:
#   * Corrupt .circuit_breaker_state must be auto-repaired with a WARN, not a
#     hook crash that blocks the loop.
#   * .ralph/hooks/on-stop.sh must stay byte-identical to the template (drift
#     means a stale, less-hardened hook ships with the project).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
TEMPLATE_HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"
RUNTIME_HOOK="${REPO_ROOT}/.ralph/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    # Hook keys off CLAUDE_PROJECT_DIR for the .ralph location.
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Minimal valid CLI response payload the hook can parse.
_valid_input() {
    cat <<'JSON'
{"result":"Did some work.\n\n```json\n{\"RALPH_STATUS\":{\"EXIT_SIGNAL\":false,\"FILES_MODIFIED\":0,\"TASKS_COMPLETED\":0,\"WORK_TYPE\":\"IMPLEMENTATION\"}}\n```"}
JSON
}

# =============================================================================
# Drift parity — TAP-538 root cause was the runtime hook losing template fixes
# =============================================================================

@test "TAP-538: .ralph/hooks/on-stop.sh is byte-identical to templates/hooks/on-stop.sh" {
    [[ -f "$TEMPLATE_HOOK" ]] || skip "template hook missing: $TEMPLATE_HOOK"
    [[ -f "$RUNTIME_HOOK" ]] || skip "runtime hook missing: $RUNTIME_HOOK"
    run diff -q "$RUNTIME_HOOK" "$TEMPLATE_HOOK"
    assert_success
}

@test "TAP-538: .ralph/hooks/on-session-start.sh is byte-identical to template" {
    local tpl="${REPO_ROOT}/templates/hooks/on-session-start.sh"
    local rt="${REPO_ROOT}/.ralph/hooks/on-session-start.sh"
    [[ -f "$tpl" && -f "$rt" ]] || skip "on-session-start.sh missing in tpl or runtime"
    run diff -q "$rt" "$tpl"
    assert_success
}

# =============================================================================
# CB state recovery — corrupt input must NOT crash the hook
# =============================================================================

@test "TAP-538: corrupt .circuit_breaker_state is auto-repaired, hook exits 0" {
    # Seed a deliberately corrupt file (not valid JSON).
    printf 'this is not json {{{ broken' > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    # Run the hook with a valid payload; the corrupt CB state must be repaired
    # rather than crash the hook.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # WARN must be logged on stderr.
    [[ "$stderr" == *"corrupt"* && "$stderr" == *"reinitializing"* ]] || \
        fail "expected reinit WARN on stderr, got: $stderr"

    # File must now be valid JSON.
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success

    # Re-init must produce a CB-state object with the expected shape. The
    # hook's normal logic runs immediately after repair, so the no-progress
    # counter may have been incremented to 1 by this same invocation — that's
    # fine; what we assert is that the schema is restored.
    run jq -e '
        (.state | type == "string") and
        (.consecutive_no_progress | type == "number") and
        (.consecutive_permission_denials | type == "number") and
        (.total_opens | type == "number")
    ' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: empty .circuit_breaker_state is treated as corrupt and repaired" {
    : > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: valid .circuit_breaker_state is preserved (no spurious reinit)" {
    # Seed a valid CB state with non-default counters.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":1,"total_opens":3}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # No reinit WARN should fire on a healthy state.
    [[ "$stderr" != *"corrupt"* ]] || \
        fail "valid state should not be reported as corrupt: $stderr"

    # The hook IS allowed to mutate counters per its progress rules; we only
    # assert the file is still valid JSON of the right shape after the run.
    run jq -e '(.state | type == "string") and (.consecutive_no_progress | type == "number")' \
        "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

# =============================================================================
# EXIT-CLEAN: Claude's `EXIT_SIGNAL: true + STATUS: COMPLETE` with 0/0 changes
# is a legitimate clean-exit signal, not stagnation. The hook must not increment
# consecutive_no_progress in that case (otherwise empty-plan launches burn 3
# Claude calls before the no-progress CB trips).
# =============================================================================

# Helper: build a Claude response payload with a RALPH_STATUS block.
_status_block_input() {
    local exit_signal="$1" status="$2" tasks="$3" files="$4"
    local body="Result.

---RALPH_STATUS---
STATUS: ${status}
TASKS_COMPLETED_THIS_LOOP: ${tasks}
FILES_MODIFIED: ${files}
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: ${exit_signal}
RECOMMENDATION: Test payload.
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "EXIT-CLEAN: EXIT_SIGNAL=true + STATUS=COMPLETE + 0/0 RESETS no-progress (does NOT increment)" {
    # Pre-seed: no-progress already at 2 (one more 'no progress' would trip on threshold=3).
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # Counter must be reset to 0, state must remain CLOSED — exit_signal is a
    # request for clean shutdown, not a stagnation indicator.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=false + 0/0 STILL increments no-progress (regression guard)" {
    # Same seed; this time EXIT_SIGNAL=false (no clean-exit request).
    # Hook must STILL count this as no-progress and trip the CB at threshold=3.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
    assert_success

    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "OPEN"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=true but STATUS!=COMPLETE/BLOCKED does NOT bypass no-progress" {
    # Defensive: only honor exit-clean when BOTH signals agree. EXIT_SIGNAL=true
    # paired with STATUS=COMPLETE (Grounds 1: plan done) or STATUS=BLOCKED
    # (Grounds 2: queue fully blocked) is honored. Any other status (PARTIAL,
    # IN_PROGRESS, etc.) is ambiguous — fall through to normal classification.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true PARTIAL 0 0)"
    assert_success

    # Should be treated as no-progress and trip.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
}

@test "EXIT-CLEAN: EXIT_SIGNAL=true + STATUS=BLOCKED + 0/0 RESETS no-progress (Grounds 2: queue fully blocked)" {
    # The "whole queue blocked — clean exit" scenario from the ralph-workflow
    # skill. When every open issue is blocked on external action and Claude
    # signals EXIT_SIGNAL=true + STATUS=BLOCKED, the harness should exit
    # cleanly the same way it does for STATUS=COMPLETE — not trip the CB on
    # consecutive blocked-queue loops.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true BLOCKED 0 0)"
    assert_success

    # Counter must be reset to 0, state must remain CLOSED.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=false + STATUS=BLOCKED STILL increments (single-task block, not queue-wide)" {
    # The "single task blocked" scenario — Claude reports STATUS=BLOCKED on
    # one task but EXIT_SIGNAL=false because other tasks may still be
    # actionable. The hook must NOT bypass no-progress in this case;
    # consecutive single-task blocks should still trip the CB so the operator
    # gets surfaced visibility.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false BLOCKED 0 0)"
    assert_success

    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "OPEN"
}

@test "EXIT-CLEAN: status.json after EXIT_SIGNAL=true is valid JSON (Bug 1 regression guard)" {
    # The grep -c || echo 0 pattern previously injected a stray '0\n' into status.json,
    # which broke ralph_loop.sh's downstream jq reads. Template was fixed via tr -cd '0-9'.
    # This test asserts status.json stays valid JSON across the EXIT_SIGNAL=true path.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    printf '{"loop_count": 5}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # status.json must be valid JSON with exit_signal field intact.
    run jq -e 'type == "object" and .exit_signal == "true"' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_success
}

# =============================================================================
# COST-EXTRACT: total_cost_usd and token usage live in the live stream-json file
# under .ralph/logs/, NOT in the official ~/.claude/projects/<proj>/<sess>.jsonl
# transcript. The hook must fall through to the stream file so loop_cost_usd and
# loop_input_tokens / loop_output_tokens are non-zero on real loops.
# Regression: tapps-brain status.json showed loop_cost_usd=0 across all loops
# despite cache token counts being populated correctly (3.1M read / 180K create
# per loop), because both INPUT and transcript_path lacked a "type":"result" line.
# =============================================================================

@test "COST-EXTRACT: hook reads total_cost_usd from .ralph/logs/ stream when transcript lacks result line" {
    # Set up a minimal stream-json log mirroring what `claude --output-format stream-json`
    # writes during a real loop. Only the result line carries cost.
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2099-01-01_00-00-00.log" <<'STREAM'
{"type":"system","subtype":"init","session_id":"abc123"}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":1.234567,"usage":{"input_tokens":42,"output_tokens":99,"cache_read_input_tokens":3136400,"cache_creation_input_tokens":180230}}
STREAM

    # Provide INPUT with a transcript_path that has NO result line — matches what
    # ~/.claude/projects/<proj>/<sess>.jsonl actually looks like in agent mode.
    local transcript="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    cat > "$transcript" <<'JSONL'
{"type":"user","message":{"content":"go"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":42,"output_tokens":99,"cache_read_input_tokens":3136400,"cache_creation_input_tokens":180230}}}
JSONL

    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    local input
    input=$(jq -n --arg tp "$transcript" \
        '{transcript_path: $tp, result: "Did work.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 3\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}')

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # Cost and token counts must reflect the stream's result line, not zero.
    run jq -r '.loop_cost_usd' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "1.234567"
    run jq -r '.loop_input_tokens' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "42"
    run jq -r '.loop_output_tokens' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "99"
}

@test "COST-EXTRACT: hook prefers _stream.log-suffixed sibling's NON-suffixed live file" {
    # ralph_loop.sh post-processing creates *_stream.log as a backup AFTER the
    # hook fires, then overwrites the original .log with just the result line.
    # Pre-existing _stream.log files from prior loops must not shadow the current
    # loop's live stream when picking newest-by-mtime.
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"

    # Older _stream.log backup from a previous loop ($1.99 — wrong answer).
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2098-01-01_00-00-00_stream.log" <<'OLD'
{"type":"result","total_cost_usd":1.99,"usage":{"input_tokens":1,"output_tokens":1}}
OLD
    # Make sure mtime is older.
    touch -t 209801010000 "$TEST_TEMP_DIR/.ralph/logs/claude_output_2098-01-01_00-00-00_stream.log"

    # Current live stream — newer mtime, lower cost — this is the correct source.
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2099-01-01_00-00-00.log" <<'NEW'
{"type":"result","total_cost_usd":0.42,"usage":{"input_tokens":7,"output_tokens":13}}
NEW

    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 1 1)"
    assert_success

    # Must read the non-suffixed .log (the live stream), not the older _stream.log backup.
    run jq -r '.loop_cost_usd' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0.42"
}

# =============================================================================
# TAP-741: push-mode Linear counts — hook extracts LINEAR_OPEN_COUNT /
# LINEAR_DONE_COUNT from RALPH_STATUS and writes them to status.json with a
# linear_counts_at timestamp so lib/linear_backend.sh can read them without an
# API key.
# =============================================================================

# Helper: build a Claude response with the given Linear push-mode counts.
_status_block_with_linear_counts() {
    local open="$1" done_c="$2"
    local body="Worked on TAP-741.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Test push-mode counts.
LINEAR_OPEN_COUNT: ${open}
LINEAR_DONE_COUNT: ${done_c}
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "TAP-741 hook: extracts LINEAR_OPEN_COUNT / LINEAR_DONE_COUNT into status.json" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 12 5)"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "12"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "5"
}

@test "TAP-741 hook: stamps linear_counts_at with an ISO-8601 UTC timestamp" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 3 7)"
    assert_success

    run jq -r '.linear_counts_at' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_success
    # Shape: YYYY-MM-DDTHH:MM:SSZ
    [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
        fail "linear_counts_at not ISO-8601 UTC: $output"
}

@test "TAP-741 hook: accepts zero counts (empty-project done signal)" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 0 0)"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0"
}

@test "TAP-741 hook: absent LINEAR_OPEN_COUNT / _DONE_COUNT → null fields, null timestamp" {
    # file-mode projects never emit these fields; status.json must leave them null
    # instead of poisoning the backend's staleness check with stale data.
    local body="---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: No Linear fields.
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_counts_at' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
}

@test "PARSER-HARDENING: RECOMMENDATION prose containing 'STATUS:BLOCKED' does NOT poison the STATUS field" {
    # Reproduces the NLTlabsPE 2026-04-30 incident. Claude correctly emitted
    # STATUS: BLOCKED + EXIT_SIGNAL: true after detecting every Linear issue
    # carried a blocked:* label, but added a parenthetical to RECOMMENDATION
    # that mentioned "STATUS:BLOCKED" in prose. The unanchored grep "STATUS:"
    # picked the recommendation line via tail -1, sed stripped up to the LAST
    # "STATUS:" occurrence, and the captured value was "BLOCKED)" — failing
    # the EXIT-CLEAN equality check at on-stop.sh:607 and forcing the hook to
    # increment consecutive_no_progress instead of recognising clean exit.
    # 10 wasted loops + CB trip ensued before the operator killed the run.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    local body="Walked the queue.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: true
RECOMMENDATION: Every NLT Engine issue is blocked:agentforge or blocked:nltweb — run \`ralph stop\` (exit-gate bug doesn't halt on STATUS:BLOCKED)
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # status.json must show parsed STATUS=BLOCKED, NOT "BLOCKED)" with stray paren.
    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "BLOCKED"

    # And EXIT-CLEAN Grounds 2 must have fired: counter reset to 0, state CLOSED.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "PARSER-HARDENING: lowercase linear_open_count / linear_done_count (PROMPT.md drift) parses correctly" {
    # Reproduces the second half of the NLTlabsPE 2026-04-30 incident. The
    # project's PROMPT.md emits the canonical schema with lowercase field
    # names (`linear_open_count: 0`) but the hook used to grep case-sensitive
    # for "LINEAR_OPEN_COUNT:" and silently dropped the value. Result: every
    # loop wrote `linear_open_count: null` to status.json, the harness's
    # exit gate skipped on every iteration, and Claude could never signal a
    # clean empty-backlog exit.
    local body="---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
linear_open_count: 0
linear_done_count: 142
linear_current_issue: none
EXIT_SIGNAL: true
RECOMMENDATION: All issues blocked.
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "142"
    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "BLOCKED"
    run jq -r '.exit_signal' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "true"
}

@test "PARSER-HARDENING: TESTS_STATUS does NOT bleed into STATUS field via unanchored grep" {
    # Defense regression. Even with the awk pre-pass + line-anchored greps,
    # confirm that TESTS_STATUS: PASSING does not get picked up as
    # status=PASSING (the original code worked around this with a brittle
    # `grep -v "TESTS_STATUS\|END_RALPH"` filter; the new line-anchor makes
    # that filter redundant — this test is the regression guard).
    local body="---RALPH_STATUS---
STATUS: COMPLETE
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 1
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Done.
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # Crucial: status must be "COMPLETE" not "PASSING" — i.e. the anchored
    # grep correctly distinguishes the STATUS line from the TESTS_STATUS line.
    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "COMPLETE"
}

@test "TAP-741 hook: non-numeric LINEAR_OPEN_COUNT is coerced to null" {
    local body="---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Bad input.
LINEAR_OPEN_COUNT: many
LINEAR_DONE_COUNT: 4
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # Malformed open_count → null; valid done_count passes through.
    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "4"
}

# =============================================================================
# TAP-590 (epic TAP-589 LINOPT): on-stop.sh captures this loop's edited file set
# into .ralph/.last_completed_files for cache-locality scoring downstream in
# lib/linear_optimizer.sh. Walks the transcript JSONL for Edit/Write/MultiEdit/
# NotebookEdit tool_use records.
# =============================================================================

# Helper: build a transcript JSONL with the given assistant tool_use records,
# then construct the INPUT envelope the hook reads from stdin.
_input_with_transcript() {
    local transcript="$1"
    jq -n --arg tp "$transcript" '
        {transcript_path: $tp,
         result: "Did work.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: x\n---END_RALPH_STATUS---"}'
}

# Helper: emit a single assistant message JSONL line carrying a tool_use record.
_assistant_tool_use() {
    local tool="$1" path_key="$2" path_val="$3"
    jq -nc --arg tool "$tool" --arg pk "$path_key" --arg pv "$path_val" '
        {type: "assistant",
         message: {content: [{type: "tool_use", name: $tool, input: {($pk): $pv}}]}}'
}

@test "TAP-590: 3 Edits to same path collapse to 1 line" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    {
        _assistant_tool_use Edit file_path "src/foo.py"
        _assistant_tool_use Edit file_path "src/foo.py"
        _assistant_tool_use Edit file_path "src/foo.py"
    } > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    [[ -f "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || fail ".last_completed_files missing"
    run wc -l < "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    [[ "${output// /}" == "1" ]] || fail "expected 1 line, got '$output'"
    run cat "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    assert_output "src/foo.py"
}

@test "TAP-590: Edit + Write to different paths produce 2 sorted lines" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    {
        _assistant_tool_use Write file_path "z/last.sh"
        _assistant_tool_use Edit  file_path "a/first.py"
    } > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    run cat "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    # `unique` in jq sorts as a side effect.
    [[ "${lines[0]}" == "a/first.py" ]] || fail "first line: ${lines[0]}"
    [[ "${lines[1]}" == "z/last.sh" ]] || fail "second line: ${lines[1]}"
}

@test "TAP-590: MultiEdit + NotebookEdit are recognized" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    {
        _assistant_tool_use MultiEdit    file_path     "lib/multi.sh"
        _assistant_tool_use NotebookEdit notebook_path "notebooks/x.ipynb"
    } > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    run cat "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    [[ "$output" == *"lib/multi.sh"* ]] || fail "missing MultiEdit path: $output"
    [[ "$output" == *"notebooks/x.ipynb"* ]] || fail "missing NotebookEdit path: $output"
}

@test "TAP-590: no edit-class tools → empty file (not missing)" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    # Only Read + Bash (non-edit-class) — should produce empty file, not absence.
    jq -nc '{type: "assistant", message: {content: [{type: "tool_use", name: "Read", input: {file_path: "x.txt"}}]}}' > "$t"
    jq -nc '{type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: "ls"}}]}}' >> "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    [[ -f "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || fail ".last_completed_files should exist"
    [[ ! -s "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || \
        fail "expected empty, got: $(cat "$TEST_TEMP_DIR/.ralph/.last_completed_files")"
}

@test "TAP-590: 150 unique edits → cap at 100 lines" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    : > "$t"
    local i
    for i in $(seq 1 150); do
        _assistant_tool_use Edit file_path "src/file_$i.py" >> "$t"
    done

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    run wc -l < "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    [[ "${output// /}" == "100" ]] || fail "expected 100 lines, got '$output'"
}

@test "TAP-590: CLAUDE_PROJECT_DIR prefix is stripped to repo-relative" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    # Write absolute path that includes CLAUDE_PROJECT_DIR.
    _assistant_tool_use Edit file_path "$TEST_TEMP_DIR/src/abs.py" > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    run cat "$TEST_TEMP_DIR/.ralph/.last_completed_files"
    assert_output "src/abs.py"
}

@test "TAP-590: stale .last_completed_files is overwritten when current loop has no edits" {
    # Pre-seed a stale list from a prior loop.
    printf 'old/stale.py\n' > "$TEST_TEMP_DIR/.ralph/.last_completed_files"

    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    # Empty transcript (no assistant messages with edit-class tools).
    : > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_input_with_transcript "$t")"
    assert_success

    [[ -f "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || fail "file missing"
    [[ ! -s "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || \
        fail "expected empty (stale cleared), got: $(cat "$TEST_TEMP_DIR/.ralph/.last_completed_files")"
}

@test "TAP-590: missing transcript → empty .last_completed_files (graceful, no crash)" {
    local input
    input=$(jq -n '{result: "no transcript path here", transcript_path: ""}')

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    [[ -f "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || fail "file missing"
    [[ ! -s "$TEST_TEMP_DIR/.ralph/.last_completed_files" ]] || fail "expected empty"
}

# =============================================================================
# QA failure tracking — TESTS_STATUS=FAILING increments .qa_failures.json,
# PASSING resets it. Feeds the type-aware router's Opus escalation path.
# =============================================================================

# Helper: Claude payload with LINEAR_ISSUE + TESTS_STATUS in the RALPH_STATUS block.
_qa_input() {
    local linear_issue="$1" tests_status="$2"
    local body="Did some work.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: ${tests_status}
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
LINEAR_ISSUE: ${linear_issue}
RECOMMENDATION: Test payload.
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "QA-FAIL: TESTS_STATUS=FAILING with LINEAR_ISSUE increments .qa_failures.json" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)"
    assert_success

    [[ -f "$TEST_TEMP_DIR/.ralph/.qa_failures.json" ]] || fail ".qa_failures.json missing"
    run jq -r '."TAP-123"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "1"
}

@test "QA-FAIL: consecutive FAILING loops accumulate per-issue count" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1

    run jq -r '."TAP-123"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "3"
}

@test "QA-PASS: TESTS_STATUS=PASSING clears the count for that issue" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 PASSING)" >/dev/null 2>&1

    # Issue should be removed from the map (qa_failures_get returns 0 for missing).
    run jq -r '."TAP-123" // 0' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "0"
}

@test "QA-FAIL: PASSING for one issue does not reset another" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-456 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 PASSING)" >/dev/null 2>&1

    run jq -r '."TAP-456"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "1"
}

@test "QA-FAIL: TESTS_STATUS=DEFERRED is ignored (does not increment)" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 DEFERRED)" >/dev/null 2>&1

    run jq -r '."TAP-123"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "1"
}

@test "QA-FAIL: TESTS_STATUS=DEFERRED does not reset accumulated failures" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 DEFERRED)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1

    run jq -r '."TAP-123"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "3"
}

@test "QA-FAIL: TESTS_STATUS=NOT_RUN is ignored" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 FAILING)" >/dev/null 2>&1
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input TAP-123 NOT_RUN)" >/dev/null 2>&1

    run jq -r '."TAP-123"' "$TEST_TEMP_DIR/.ralph/.qa_failures.json"
    assert_output "1"
}

@test "QA-FAIL: missing LINEAR_ISSUE → no qa_failures write (file-mode projects)" {
    bash "$TEMPLATE_HOOK" <<<"$(_qa_input '' FAILING)" >/dev/null 2>&1

    # Hook should not have created the file when there's no issue to key on.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.qa_failures.json" ]] || \
        fail ".qa_failures.json should not exist for file-mode (no LINEAR_ISSUE)"
}

# =============================================================================
# TRANSCRIPT-FALLBACK — Claude Code 2.1.x removed "type":"result" from hook payload
# =============================================================================

# Build hook INPUT that only has transcript_path (no .result field) — the 2.1.x shape.
_transcript_only_input() {
    local transcript="$1"
    jq -n --arg tp "$transcript" '{transcript_path: $tp}'
}

@test "TRANSCRIPT-FALLBACK: status parsed from transcript when hook payload has no .result (2.1.x)" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    printf '%s\n' \
        '{"type":"system","session_id":"test-sess"}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Did work.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 2\nFILES_MODIFIED: 3\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}],"usage":{"input_tokens":100,"output_tokens":50}}}' \
        > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_transcript_only_input "$t")"
    assert_success

    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "IN_PROGRESS"

    run jq -r '.tasks_completed' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "2"

    run jq -r '.files_modified' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "3"
}

@test "TRANSCRIPT-FALLBACK: LINEAR_ISSUE extracted from transcript (2.1.x)" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    printf '%s\n' \
        '{"type":"system","session_id":"test-sess"}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on TAP-999.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 1\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nLINEAR_ISSUE: TAP-999\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}],"usage":{"input_tokens":50,"output_tokens":30}}}' \
        > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_transcript_only_input "$t")"
    assert_success

    run jq -r '.linear_issue' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "TAP-999"
}

@test "TRANSCRIPT-FALLBACK: UNKNOWN status when transcript has no RALPH_STATUS block (2.1.x)" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    printf '%s\n' \
        '{"type":"system","session_id":"test-sess"}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"I did some research but got no structured output."}],"usage":{"input_tokens":50,"output_tokens":10}}}' \
        > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_transcript_only_input "$t")"
    assert_success

    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "UNKNOWN"
}

# tapps-brain incident, 2026-05-07: with num_turns=46, sub-agent invocations
# emit assistant messages AFTER the one carrying RALPH_STATUS. Original
# fallback used `last` and missed the block, tripping TAP-1528 halt 3x in a row.
# Fix: scan all assistant messages for one containing the markers.
@test "TRANSCRIPT-FALLBACK: status parsed when later sub-agent message has no block (tapps-brain incident)" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    printf '%s\n' \
        '{"type":"system","session_id":"test-sess"}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 2\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nLINEAR_ISSUE: TAP-1491\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}],"usage":{"input_tokens":100,"output_tokens":50}}}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Sub-agent reports: tests passing."}],"usage":{"input_tokens":50,"output_tokens":10}}}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"All clear."}],"usage":{"input_tokens":20,"output_tokens":5}}}' \
        > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_transcript_only_input "$t")"
    assert_success

    run jq -r '.status' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "IN_PROGRESS"

    run jq -r '.linear_issue' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "TAP-1491"

    run jq -r '.tasks_completed' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "1"

    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail ".no_status_block_count should not be created when block is found"
}

# When multiple loops have run, transcript carries history. The most recent
# block (last in transcript order) is the one for this loop.
@test "TRANSCRIPT-FALLBACK: most recent RALPH_STATUS block wins when transcript has prior loops" {
    local t="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    printf '%s\n' \
        '{"type":"system","session_id":"test-sess"}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Old loop.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 1\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nLINEAR_ISSUE: TAP-100\nRECOMMENDATION: old\n---END_RALPH_STATUS---"}]}}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"New loop.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 2\nFILES_MODIFIED: 5\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nLINEAR_ISSUE: TAP-200\nRECOMMENDATION: new\n---END_RALPH_STATUS---"}]}}' \
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Trailing sub-agent chatter."}]}}' \
        > "$t"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_transcript_only_input "$t")"
    assert_success

    run jq -r '.linear_issue' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "TAP-200"

    run jq -r '.files_modified' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "5"
}

# =============================================================================
# TAP-1528: Halt detector — consecutive 'No RALPH_STATUS block' iterations
# =============================================================================

# Response with no RALPH_STATUS block at all (the bug seen on tapps-brain).
_no_status_block_input() {
    local body='Some prose response with no structured block at all. Just text.'
    jq -Rs '{result: .}' <<<"$body"
}

@test "TAP-1528: first no-status-block response increments counter, no halt" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    [[ -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "expected .no_status_block_count file to be created"
    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "1"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel should not exist yet (count=1, threshold=3)"
}

@test "TAP-1528: 3 consecutive no-status-block responses write halt sentinel" {
    # Iteration 1
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    # Iteration 2
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    # Iteration 3 — should trip the halt
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success

    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "3"
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel must exist after 3 consecutive no-status-block iterations"
    run cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason"
    [[ "$output" == *"no_status_block_3x"* ]] || \
        fail "halt reason must reference no_status_block_3x; got: $output"
}

@test "TAP-1528: successful RALPH_STATUS parse resets the counter" {
    # Two no-status-block iterations
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "2"

    # Now a successful response — counter must be cleared.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
    assert_success
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail ".no_status_block_count should be removed after a successful parse"
}

@test "TAP-1528: threshold is overridable via RALPH_HALT_NO_STATUS_BLOCK_THRESHOLD" {
    export RALPH_HALT_NO_STATUS_BLOCK_THRESHOLD=2
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel must exist after 2 iterations when threshold=2"
}

# =============================================================================
# TAP-1529: Halt detector — CB OPEN state thrashing
# =============================================================================

@test "TAP-1529: CB OPEN for 3 consecutive iterations writes halt sentinel" {
    # Seed CB state already OPEN — simulate the thrashing pattern.
    printf '%s\n' \
        '{"state":"OPEN","consecutive_no_progress":3,"consecutive_permission_denials":0,"total_opens":1,"reason":"Fresh start (clean restart)"}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    # Three iterations with CB still OPEN and no progress.
    for _ in 1 2 3; do
        run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
        assert_success
    done

    [[ -f "$TEST_TEMP_DIR/.ralph/.cb_open_thrash_count" ]] || \
        fail "expected .cb_open_thrash_count file"
    run cat "$TEST_TEMP_DIR/.ralph/.cb_open_thrash_count"
    assert_output "3"
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel must exist after 3 consecutive CB-OPEN iterations"
    run cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason"
    [[ "$output" == *"cb_open_thrash"* ]] || \
        fail "halt reason must reference cb_open_thrash; got: $output"
}

@test "TAP-1530: RALPH_COORDINATOR_INVOCATION=1 makes the hook a no-op" {
    # Coordinator brief/debrief responses never carry a RALPH_STATUS block by
    # design. Without this guard, every coordinator invocation increments
    # .no_status_block_count and trips the no_status_block_3x halt detector
    # within 1–2 main loops.
    run --separate-stderr env RALPH_COORDINATOR_INVOCATION=1 \
        bash "$TEMPLATE_HOOK" <<<'{"result":"coordinator brief written, no ralph status"}'
    assert_success
    # Counter must not exist — hook short-circuited before any state writes.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "no_status_block_count must not be written for coordinator invocations"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/status.json" ]] || \
        fail "status.json must not be overwritten by coordinator invocations"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel must not be written for coordinator invocations"
}

@test "TAP-1530: 5 coordinator invocations do not trip no_status_block_3x" {
    # Regression guard for the tapps-brain halt: per loop, ralph_loop.sh
    # spawns the coordinator twice (brief + debrief). Three loops = 6
    # coordinator stops. None must increment the counter.
    for _ in 1 2 3 4 5; do
        run --separate-stderr env RALPH_COORDINATOR_INVOCATION=1 \
            bash "$TEMPLATE_HOOK" <<<'{"result":"coordinator update"}'
        assert_success
    done
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "counter must stay absent across 5 coordinator invocations"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt must not trip on coordinator-only stops"
}

@test "TAP-1529: progress event resets the CB-thrash counter" {
    # Seed CB OPEN.
    printf '%s\n' \
        '{"state":"OPEN","consecutive_no_progress":3,"consecutive_permission_denials":0,"total_opens":1,"reason":"test"}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    # Two no-progress iterations.
    for _ in 1 2; do
        run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
        assert_success
    done
    run cat "$TEST_TEMP_DIR/.ralph/.cb_open_thrash_count"
    assert_output "2"

    # Now a progress event (files_modified=1) — counter must be cleared.
    # NOTE: progress also closes the CB via the existing on-stop logic.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 1 1)"
    assert_success
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.cb_open_thrash_count" ]] || \
        fail "thrash counter should be removed after progress"
}

# =============================================================================
# Session guard — on-stop.sh must be a no-op for interactive Claude Code
# sessions in ralph-managed repos. Only ralph_loop.sh's main() exports
# RALPH_LOOP_ACTIVE=1. Without this guard, every interactive Stop event
# pollutes status.json and trips the no_status_block_3x halt detector.
# Observed in ralph-claude-code (May 2026): 885 interactive Stop events
# tallied $16,489 against zero ralph iterations.
# =============================================================================

@test "session guard: hook exits 0 without touching state when RALPH_LOOP_ACTIVE is unset" {
    # Seed pre-existing state so we can prove nothing mutates it.
    printf '%s' '{"loop_count":42,"status":"PASSING"}' > "$TEST_TEMP_DIR/.ralph/status.json"
    local pre_status_mtime
    pre_status_mtime=$(stat -c '%Y' "$TEST_TEMP_DIR/.ralph/status.json")

    # Bare response with NO RALPH_STATUS block — the worst-case interactive
    # payload that would otherwise increment .no_status_block_count.
    unset RALPH_LOOP_ACTIVE
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<'{"result":"Just answering a question."}'
    assert_success

    # No counter file should be created.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "guard breached: .no_status_block_count was written"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "guard breached: .harness_halt_reason was written"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state" ]] || \
        fail "guard breached: .circuit_breaker_state was written"

    # status.json must be byte-identical to the seed.
    local post_status_mtime
    post_status_mtime=$(stat -c '%Y' "$TEST_TEMP_DIR/.ralph/status.json")
    [[ "$pre_status_mtime" == "$post_status_mtime" ]] || \
        fail "guard breached: status.json mtime changed ($pre_status_mtime -> $post_status_mtime)"
    run jq -r '.loop_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "42"
}

@test "session guard: 5x bare responses with guard off leave state pristine" {
    unset RALPH_LOOP_ACTIVE
    for _ in 1 2 3 4 5; do
        run --separate-stderr bash "$TEMPLATE_HOOK" <<<'{"result":"Interactive reply."}'
        assert_success
    done
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "guard breached: counter incremented across 5 interactive stops"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "guard breached: halt sentinel tripped on interactive stops"
}

@test "session guard: hook runs full body when RALPH_LOOP_ACTIVE=1" {
    # Dual of the negative test: with the guard ON, a bare response (no
    # RALPH_STATUS block) MUST increment .no_status_block_count to 1.
    export RALPH_LOOP_ACTIVE=1
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<'{"result":"Bare response."}'
    assert_success
    [[ -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "expected .no_status_block_count to be written when guard is on"
    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "1"
}
