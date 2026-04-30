#!/usr/bin/env bats
# TAP-915: ralph_spawn_coordinator wires the ralph-coordinator agent into
# the main loop. Verifies guards (disabled / dry-run / no claude binary),
# success path, and failure paths (spawn failure, invalid brief, stale
# brief) all behave as best-effort and never block the main loop.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

# Override the test_helper setup — we want a tmpdir cd plus a sourced
# ralph_loop.sh, not the helper's RALPH_DIR-from-script-pwd defaults.
setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_spawn.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    # Make sure the loop body never runs.
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true

    # Source ralph_loop.sh so ralph_spawn_coordinator + helpers are defined.
    # The script's main() is self-guarded by BASH_SOURCE==0, but its argv
    # parser runs unconditionally at top level — clear positional args
    # first so bats's test-name does not trip the "Unknown option" branch.
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# A canonical valid brief used by the success-path tests.
write_valid_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-915",
  "task_source": "file",
  "task_summary": "Spawn coordinator before main agent.",
  "risk_level": "MEDIUM",
  "affected_modules": ["ralph_loop.sh"],
  "acceptance_criteria": ["spawn_succeeds"],
  "prior_learnings": [],
  "qa_required": true,
  "qa_scope": "tests/unit/test_coordinator_spawn.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.8,
  "created_at": "2026-04-29T22:30:00Z"
}
EOF
}

@test "TAP-915: ralph_spawn_coordinator function is defined" {
    declare -F ralph_spawn_coordinator >/dev/null \
        || fail "ralph_spawn_coordinator not defined after sourcing ralph_loop.sh"
}

@test "TAP-915: skips when RALPH_COORDINATOR_DISABLED=true" {
    export RALPH_COORDINATOR_DISABLED=true
    # Define mock that would set a sentinel if called.
    _coordinator_invoke_claude() { echo "should-not-run" > "$TEST_TEMP_DIR/.invoked"; return 0; }

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "non-zero exit when disabled, got $status"
    [[ ! -e "$TEST_TEMP_DIR/.invoked" ]] || fail "invoke wrapper called despite disable flag"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "brief written despite disable flag"
}

@test "TAP-915: skips on DRY_RUN" {
    export DRY_RUN=true
    _coordinator_invoke_claude() { echo "should-not-run" > "$TEST_TEMP_DIR/.invoked"; return 0; }

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "non-zero exit on dry-run"
    [[ ! -e "$TEST_TEMP_DIR/.invoked" ]] || fail "invoke wrapper called on dry-run"
}

@test "TAP-915: WARN + continue when claude binary missing" {
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/no-such-binary-$$"

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort), got $status"
    [[ "$output" == *"claude CLI not on PATH"* ]] \
        || fail "expected WARN about missing CLI, got: $output"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "brief should not exist when binary missing"
}

@test "TAP-915: success path writes brief and logs INFO with risk_level" {
    # Mock claude — write a valid brief, return 0.
    _coordinator_invoke_claude() {
        write_valid_brief
        return 0
    }
    export CLAUDE_CODE_CMD=bash   # any binary that exists; the wrapper is mocked anyway

    run ralph_spawn_coordinator 5
    [[ "$status" -eq 0 ]] || fail "expected zero exit on success"
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "brief not written"
    jq -e '.risk_level' "$RALPH_DIR/brief.json" >/dev/null
    [[ "$output" == *"brief written"* ]] && [[ "$output" == *"risk=MEDIUM"* ]] \
        || fail "expected INFO log with risk=MEDIUM, got: $output"
}

@test "TAP-915: spawn failure WARNs and leaves no brief" {
    # Mock claude — non-zero exit, NOT 124 (124 = timeout, gets a distinct
    # message — see the COORDINATOR-TIMEOUT regression test below).
    _coordinator_invoke_claude() { return 1; }
    export CLAUDE_CODE_CMD=bash

    # Pre-place a stale brief — spawn should clear it before invocation,
    # so a coordinator failure does not leave yesterday's brief around.
    write_valid_brief

    run ralph_spawn_coordinator 7
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort) on spawn failure"
    [[ "$output" == *"spawn failed (exit 1)"* ]] \
        || fail "expected WARN with exit code, got: $output"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "stale brief should have been cleared before spawn"
}

@test "COORDINATOR-TIMEOUT: rc=124 emits 'timed out' message + names the env var to raise" {
    # Reproduces the NLTlabsPE 2026-04-30 incident — coordinator timed out 3
    # times in 10 loops at the old hardcoded 60s. The fix raised default to
    # 120s and made it configurable via RALPH_COORDINATOR_TIMEOUT_SECONDS.
    # The log message must distinguish timeout (rc=124) from other failures
    # so the operator knows whether to raise the timeout or debug the CLI.
    _coordinator_invoke_claude() { return 124; }
    export CLAUDE_CODE_CMD=bash
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=120

    run ralph_spawn_coordinator 7
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort) on timeout"
    [[ "$output" == *"timed out after 120s"* ]] \
        || fail "expected timeout message naming the duration, got: $output"
    [[ "$output" == *"RALPH_COORDINATOR_TIMEOUT_SECONDS"* ]] \
        || fail "expected message to name the env var to raise, got: $output"
}

@test "TAP-915: invalid brief is cleared and WARNed" {
    # Mock claude — write garbage and return 0.
    _coordinator_invoke_claude() {
        echo '{not valid json' > "$RALPH_DIR/brief.json"
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 3
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort) on invalid brief"
    [[ "$output" == *"missing or invalid"* ]] \
        || fail "expected WARN about invalid brief, got: $output"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "invalid brief should be cleared"
}

@test "TAP-915: missing brief after success is WARNed and noop" {
    # Mock claude — return 0 but write nothing.
    _coordinator_invoke_claude() { return 0; }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 2
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    [[ "$output" == *"missing or invalid"* ]] \
        || fail "expected WARN about missing brief, got: $output"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "no brief expected"
}

@test "TAP-915: file task source reads first unchecked from fix_plan.md" {
    cat > "$RALPH_DIR/fix_plan.md" <<'EOF'
# Plan
- [x] done item
- [ ] first unchecked item
- [ ] second unchecked item
EOF
    export RALPH_TASK_SOURCE=file

    # Capture the task input the coordinator received.
    _coordinator_invoke_claude() {
        echo "$1" > "$TEST_TEMP_DIR/.coord_input"
        write_valid_brief
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got: $output"
    grep -q 'TASK_SOURCE=file' "$TEST_TEMP_DIR/.coord_input" \
        || fail "TASK_SOURCE=file not in coordinator input"
    grep -q 'first unchecked item' "$TEST_TEMP_DIR/.coord_input" \
        || fail "first unchecked task not piped to coordinator"
    # Second item should not be picked — only -m1.
    ! grep -q 'second unchecked item' "$TEST_TEMP_DIR/.coord_input" \
        || fail "coordinator received >1 unchecked item; expected -m1"
}

@test "TAP-915: linear task source uses linear_get_next_task when present" {
    export RALPH_TASK_SOURCE=linear
    # Stub linear_get_next_task — coordinator should call it for linear mode.
    linear_get_next_task() { echo "TAP-915: Spawn coordinator"; return 0; }
    export -f linear_get_next_task

    _coordinator_invoke_claude() {
        echo "$1" > "$TEST_TEMP_DIR/.coord_input"
        write_valid_brief
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 4
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got: $output"
    grep -q 'TASK_SOURCE=linear' "$TEST_TEMP_DIR/.coord_input" \
        || fail "TASK_SOURCE=linear not in coordinator input"
    grep -q 'TAP-915' "$TEST_TEMP_DIR/.coord_input" \
        || fail "linear next-task not piped to coordinator"
}

@test "TAP-915: build_loop_context advertises brief when present and valid" {
    write_valid_brief
    # build_loop_context reads from $RALPH_DIR/brief.json
    run build_loop_context 1
    [[ "$status" -eq 0 ]] || fail "build_loop_context failed: $output"
    [[ "$output" == *".ralph/brief.json available"* ]] \
        || fail "context should advertise brief.json, got: $output"
}

@test "TAP-915: build_loop_context does NOT advertise brief when absent" {
    [[ ! -e "$RALPH_DIR/brief.json" ]]
    run build_loop_context 1
    [[ "$status" -eq 0 ]] || fail "build_loop_context failed: $output"
    [[ "$output" != *".ralph/brief.json available"* ]] \
        || fail "context should not mention brief when missing, got: $output"
}
