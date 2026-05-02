#!/usr/bin/env bats
# TAP-917: coordinator brain integration — brain_recall at task start
# (BRIEF mode populates prior_learnings + coordinator_confidence) and
# brain_learn_success/failure at epic boundary (DEBRIEF mode).
#
# Two surfaces:
#   1. ralph_debrief_coordinator() — shell-side wrapper that spawns the
#      coordinator with MODE=debrief and an outcome flag. Tested with
#      a mocked _coordinator_invoke_claude.
#   2. .claude/agents/ralph-coordinator.md — verified statically to
#      document the recall/confidence rubric and the brief_clear contract.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_brain.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true

    # Source ralph_loop.sh so ralph_debrief_coordinator + helpers are defined.
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

write_valid_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-917",
  "task_source": "linear",
  "task_summary": "Wire coordinator brain integration.",
  "risk_level": "MEDIUM",
  "affected_modules": ["ralph_loop.sh", ".claude/agents/ralph-coordinator.md"],
  "acceptance_criteria": ["debrief_records_outcome"],
  "prior_learnings": [],
  "qa_required": true,
  "qa_scope": "tests/unit/test_coordinator_brain.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.7,
  "created_at": "2026-05-01T20:00:00Z"
}
EOF
}

# -- ralph_debrief_coordinator: shell-side wrapper -----------------------------

@test "TAP-917: ralph_debrief_coordinator function is defined" {
    declare -F ralph_debrief_coordinator >/dev/null \
        || fail "ralph_debrief_coordinator not defined after sourcing ralph_loop.sh"
}

@test "TAP-917: debrief skips when RALPH_COORDINATOR_DISABLED=true" {
    export RALPH_COORDINATOR_DISABLED=true
    _coordinator_invoke_claude() { echo "should-not-run" > "$TEST_TEMP_DIR/.invoked"; return 0; }

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "non-zero exit when disabled, got $status"
    [[ ! -e "$TEST_TEMP_DIR/.invoked" ]] || fail "invoke wrapper called despite disable flag"
}

@test "TAP-917: debrief skips on DRY_RUN" {
    export DRY_RUN=true
    _coordinator_invoke_claude() { echo "ran" > "$TEST_TEMP_DIR/.invoked"; return 0; }

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "non-zero exit on dry-run"
    [[ ! -e "$TEST_TEMP_DIR/.invoked" ]] || fail "invoke wrapper called on dry-run"
}

@test "TAP-917: debrief skips when claude binary missing" {
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/no-such-binary-$$"
    _coordinator_invoke_claude() { echo "ran" > "$TEST_TEMP_DIR/.invoked"; return 0; }

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort)"
    [[ ! -e "$TEST_TEMP_DIR/.invoked" ]] || fail "invoke wrapper called when binary missing"
}

@test "TAP-917: debrief success passes MODE=debrief and OUTCOME=success" {
    write_valid_brief
    _coordinator_invoke_claude() {
        echo "$1" > "$TEST_TEMP_DIR/.input"
        rm -f "$RALPH_DIR/brief.json"   # simulate the agent's brief_clear
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "expected zero exit on success"
    [[ -f "$TEST_TEMP_DIR/.input" ]] || fail "wrapper not invoked"
    grep -q "MODE=debrief" "$TEST_TEMP_DIR/.input" \
        || fail "expected MODE=debrief in input, got: $(cat "$TEST_TEMP_DIR/.input")"
    grep -q "OUTCOME=success" "$TEST_TEMP_DIR/.input" \
        || fail "expected OUTCOME=success, got: $(cat "$TEST_TEMP_DIR/.input")"
    [[ "$output" == *"debrief recorded"* ]] && [[ "$output" == *"outcome=success"* ]] \
        || fail "expected INFO log naming outcome, got: $output"
}

@test "TAP-917: debrief failure passes OUTCOME=failure with detail text" {
    write_valid_brief
    _coordinator_invoke_claude() {
        echo "$1" > "$TEST_TEMP_DIR/.input"
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_debrief_coordinator failure "tests failed: 3 unit tests in lib/foo.sh"
    [[ "$status" -eq 0 ]] || fail "expected zero exit on failure outcome"
    grep -q "OUTCOME=failure" "$TEST_TEMP_DIR/.input" \
        || fail "expected OUTCOME=failure, got: $(cat "$TEST_TEMP_DIR/.input")"
    grep -q "OUTCOME_DETAIL: tests failed" "$TEST_TEMP_DIR/.input" \
        || fail "expected OUTCOME_DETAIL line, got: $(cat "$TEST_TEMP_DIR/.input")"
}

@test "TAP-917: debrief invocation failure is logged but returns 0" {
    _coordinator_invoke_claude() { return 1; }
    export CLAUDE_CODE_CMD=bash

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort) on invoke failure"
    [[ "$output" == *"debrief failed"* ]] \
        || fail "expected WARN about debrief failure, got: $output"
}

@test "TAP-917: brief is cleared after a successful debrief" {
    write_valid_brief
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "fixture should write a brief"
    _coordinator_invoke_claude() {
        # Simulate the coordinator agent calling brief_clear at end of debrief
        rm -f "$RALPH_DIR/brief.json"
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "brief should be cleared after debrief — next loop must start fresh"
}

# -- coordinator agent body: brain rubric ------------------------------------

@test "TAP-917: ralph-coordinator.md documents both BRIEF and DEBRIEF modes" {
    local f="$REPO_ROOT_FIXED/.claude/agents/ralph-coordinator.md"
    grep -q 'MODE=brief' "$f" || fail "missing MODE=brief documentation"
    grep -q 'MODE=debrief' "$f" || fail "missing MODE=debrief documentation"
}

@test "TAP-917: ralph-coordinator.md documents coordinator_confidence rubric" {
    local f="$REPO_ROOT_FIXED/.claude/agents/ralph-coordinator.md"
    grep -q 'coordinator_confidence' "$f" \
        || fail "ralph-coordinator.md must reference coordinator_confidence so the agent populates it"
}

@test "TAP-917: ralph-coordinator.md documents brain_learn calls in debrief" {
    local f="$REPO_ROOT_FIXED/.claude/agents/ralph-coordinator.md"
    grep -q 'brain_learn_success' "$f" \
        || fail "debrief must call brain_learn_success on success"
    grep -q 'brain_learn_failure' "$f" \
        || fail "debrief must call brain_learn_failure on failure"
}

@test "TAP-917: ralph-coordinator.md documents brief_clear after debrief" {
    local f="$REPO_ROOT_FIXED/.claude/agents/ralph-coordinator.md"
    # Accept any of: brief_clear, "clear the brief", "delete .ralph/brief.json"
    grep -qE 'brief_clear|clear the brief|delete.*brief\.json|remove.*brief\.json' "$f" \
        || fail "debrief must clear .ralph/brief.json so next loop starts fresh"
}
