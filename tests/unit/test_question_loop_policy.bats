#!/usr/bin/env bats
# TAP-1683 (USYNC-2) — consecutive question-loop policy.
#
# Covers two surfaces wired together by .ralph/.consecutive_questions:
#   1. on-stop.sh  — counter increment / progress reset / advance at threshold+1
#   2. build_loop_context (sourced from ralph_loop.sh) — escalation injection
#      when counter >= threshold, advance directive when .linear_advance_action
#      is present.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    export RALPH_LOOP_ACTIVE=1            # bypass the TAP-1531 session guard
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    : > "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LOOP_ACTIVE
}

# A response payload with `result` text that triggers the USYNC-1 detector
# but ships no RALPH_STATUS block. Multiple question patterns to ensure
# question_count > 0 reliably across grep dialects.
_questions_input() {
    cat <<'JSON'
{"result":"I'm not sure how I should proceed. Should I prefer option A or option B? Could you confirm? What do you think?"}
JSON
}

# A progress response: tasks_completed=2, files_modified=3. Uses the
# real `---RALPH_STATUS---` text block the hook actually parses (the JSON
# pseudo-block is not a parser path — see on-stop.sh:72).
_progress_input() {
    cat <<'JSON'
{"result":"Did some work.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 2\nFILES_MODIFIED: 3\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}
JSON
}

# A progress response that ALSO carries a LINEAR_ISSUE field, so
# status.json gets a sticky .last_linear_issue pointer (TAP-1201). Used
# to seed the issue ID for the Linear-mode advance test.
_progress_input_with_issue() {
    local issue="${1:-TAP-1683}"
    cat <<JSON
{"result":"Working on $issue.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 1\nTESTS_STATUS: DEFERRED\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nLINEAR_ISSUE: $issue\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}
JSON
}

# =============================================================================
# on-stop.sh — counter management
# =============================================================================

@test "TAP-1683: first question-loop increments .consecutive_questions to 1" {
    run --separate-stderr bash "$HOOK" <<<"$(_questions_input)"
    assert_success
    [[ -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
    run cat "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    assert_output "1"
}

@test "TAP-1683: two consecutive question-loops bring counter to 2 (== threshold default)" {
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    run cat "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    assert_output "2"
    # No advance marker yet (== threshold, not >).
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_advance_action" ]]
}

@test "TAP-1683: real progress (tasks_completed>=1) resets the counter to 0" {
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    [[ -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
    bash "$HOOK" <<<"$(_progress_input)" >/dev/null 2>&1
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
}

@test "TAP-1683: counter is only bumped on question + no-status-block" {
    bash "$HOOK" <<<"$(_progress_input)" >/dev/null 2>&1
    # Progress-only loop: counter never created.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
}

@test "TAP-1683: threshold is overridable via RALPH_QUESTION_LOOP_THRESHOLD" {
    # Lower threshold means a single question-loop is already at threshold;
    # the second loop should fire the advance action.
    export RALPH_QUESTION_LOOP_THRESHOLD=1
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    run cat "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    assert_output "1"
    # Second loop pushes counter to 2 > threshold(1) → file-mode advance
    # marks fix_plan.md, resets counter.
    printf '%s\n' '- [ ] do the thing' > "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    run grep -F '<!-- BLOCKED: questions -->' "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    assert_success
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
}

# =============================================================================
# on-stop.sh — advance action at threshold+1 (Linear mode)
# =============================================================================

@test "TAP-1683: linear-mode advance writes .linear_advance_action with issue ID + label" {
    export RALPH_TASK_SOURCE=linear
    export RALPH_QUESTION_LOOP_THRESHOLD=1
    # Seed status.json with .last_linear_issue=TAP-1683 by running a
    # productive loop first (TAP-1201 sets the sticky pointer). This
    # mirrors the real-world flow: a prior productive loop establishes
    # the current issue, then subsequent bare question-loops can advance
    # it without needing the question payload to carry LINEAR_ISSUE.
    bash "$HOOK" <<<"$(_progress_input_with_issue TAP-1683)" >/dev/null 2>&1
    run jq -r '.last_linear_issue // ""' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "TAP-1683"

    # First question-loop: counter -> 1 (at threshold).
    bash "$HOOK" <<<'{"result":"Should I do X or Y? What do you think?"}' >/dev/null 2>&1
    run cat "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    assert_output "1"

    # Second question-loop: counter -> 2 > threshold(1) → advance fires.
    # Seed .linear_next_issue so we can assert it gets cleared.
    printf 'TAP-1683\n' > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    bash "$HOOK" <<<'{"result":"Should I do X or Y? Could you confirm?"}' >/dev/null 2>&1

    [[ -f "$TEST_TEMP_DIR/.ralph/.linear_advance_action" ]]
    run sed -n '1p' "$TEST_TEMP_DIR/.ralph/.linear_advance_action"
    assert_output "TAP-1683"
    run sed -n '2p' "$TEST_TEMP_DIR/.ralph/.linear_advance_action"
    assert_output "blocked:waiting-for-answer"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
}

# =============================================================================
# on-stop.sh — advance action at threshold+1 (file mode)
# =============================================================================

@test "TAP-1683: file-mode advance appends <!-- BLOCKED: questions --> to first unchecked task" {
    export RALPH_TASK_SOURCE=file
    export RALPH_QUESTION_LOOP_THRESHOLD=1
    cat > "$TEST_TEMP_DIR/.ralph/fix_plan.md" <<'EOF'
## section
- [x] already done
- [ ] this one is currently active
- [ ] later task
EOF
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    run grep -nF '<!-- BLOCKED: questions -->' "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    assert_success
    # Must be on the first unchecked line, not the second.
    [[ "$output" == *"this one is currently active"* ]]
    [[ "$output" != *"later task"* ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.consecutive_questions" ]]
}

@test "TAP-1683: file-mode advance is idempotent (existing marker not duplicated)" {
    export RALPH_TASK_SOURCE=file
    export RALPH_QUESTION_LOOP_THRESHOLD=1
    cat > "$TEST_TEMP_DIR/.ralph/fix_plan.md" <<'EOF'
- [ ] active <!-- BLOCKED: questions -->
EOF
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    bash "$HOOK" <<<"$(_questions_input)" >/dev/null 2>&1
    # Marker must remain exactly once.
    run grep -cF '<!-- BLOCKED: questions -->' "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    assert_output "1"
}

# =============================================================================
# build_loop_context — escalation + advance directive injection
# =============================================================================

# Source ONLY the surface of ralph_loop.sh we need:
# build_loop_context + the helpers it calls. The script is gnarly to source
# whole (it has main() side effects); we lift the few functions we need.
_source_context_builder() {
    local sh="$REPO_ROOT/ralph_loop.sh"
    # Stubs for helpers used inside build_loop_context that we don't want to
    # run for real under bats.
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

    # Pull just the build_loop_context function body.
    eval "$(awk '/^build_loop_context\(\) \{$/,/^\}$/' "$sh")"

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_CONTINUE_STATE_FILE="$TEST_TEMP_DIR/.ralph/.nonexistent"
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
}

@test "TAP-1683: build_loop_context injects USYNC-2 escalation when counter >= threshold" {
    _source_context_builder
    # Counter pinned at the default threshold of 2.
    echo "2" > "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    # Stub status.json so the existing soft-nudge does not pollute the test.
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 5
    assert_success
    [[ "$output" == *"ESCALATION (USYNC-2)"* ]]
    [[ "$output" == *"the previous 2 consecutive loops ended with questions"* ]]
    [[ "$output" == *"Stop asking"* ]]
}

@test "TAP-1683: build_loop_context skips the escalation when counter < threshold" {
    _source_context_builder
    echo "1" > "$TEST_TEMP_DIR/.ralph/.consecutive_questions"
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 5
    assert_success
    [[ "$output" != *"ESCALATION (USYNC-2)"* ]]
}

@test "TAP-1683: build_loop_context skips the escalation when counter file is absent" {
    _source_context_builder
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 5
    assert_success
    [[ "$output" != *"ESCALATION (USYNC-2)"* ]]
}

@test "TAP-1683: build_loop_context injects advance directive when .linear_advance_action exists (linear mode)" {
    _source_context_builder
    export RALPH_TASK_SOURCE=linear
    # No counter file — exact reset state after the advance fired.
    {
      echo "TAP-1681"
      echo "blocked:waiting-for-answer"
    } > "$TEST_TEMP_DIR/.ralph/.linear_advance_action"
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 6
    assert_success
    [[ "$output" == *"URGENT (USYNC-2 advance)"* ]]
    [[ "$output" == *"TAP-1681"* ]]
    [[ "$output" == *"blocked:waiting-for-answer"* ]]
    [[ "$output" == *"pick a DIFFERENT open issue"* ]]
}

@test "TAP-1683: build_loop_context does NOT inject advance directive in file mode" {
    _source_context_builder
    export RALPH_TASK_SOURCE=file
    {
      echo "TAP-1681"
      echo "blocked:waiting-for-answer"
    } > "$TEST_TEMP_DIR/.ralph/.linear_advance_action"
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 6
    assert_success
    [[ "$output" != *"URGENT (USYNC-2 advance)"* ]]
}

@test "TAP-1683: build_loop_context removes unparseable advance marker rather than looping on it" {
    _source_context_builder
    export RALPH_TASK_SOURCE=linear
    # Garbage marker — first line strips to empty after the allow-list.
    {
      echo "!!!"
      echo "?#$"
    } > "$TEST_TEMP_DIR/.ralph/.linear_advance_action"
    echo '{}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run build_loop_context 6
    assert_success
    [[ "$output" != *"URGENT (USYNC-2 advance)"* ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_advance_action" ]]
}
