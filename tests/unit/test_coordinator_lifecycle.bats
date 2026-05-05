#!/usr/bin/env bats
# TAP-924: coordinator session lifecycle.
#
# Tests the two helpers added in ralph_loop.sh:
#   * ralph_clear_all_sessions       — wipes main session + coordinator session + brief.
#                                      Used at every site where the main Claude session
#                                      is reset (CB open, is_error, continue-as-new,
#                                      manual reset, expired session age).
#   * ralph_clear_coordinator_artifacts — wipes coordinator session + brief only.
#                                      Used at task boundaries (post-debrief task-complete)
#                                      and on SIGINT/SIGTERM, where the main session is
#                                      preserved so the operator can resume.
#
# Load-bearing correctness invariant: the post-debrief task-complete clear runs
# AFTER ralph_debrief_coordinator. If we cleared in on-stop.sh (which fires
# BEFORE the debrief), the debrief would read an empty brief and write nothing
# meaningful to brain. The tests below pin both the helpers and the ordering.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_lifecycle.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    unset COORDINATOR_SESSION_MAX_AGE_SECONDS || true
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# Write a minimal valid brief.json fixture.
_write_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-924",
  "task_source": "linear",
  "task_summary": "lifecycle test",
  "risk_level": "LOW",
  "affected_modules": ["ralph_loop.sh"],
  "acceptance_criteria": ["clear works"],
  "prior_learnings": [],
  "qa_required": false,
  "qa_scope": "",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.5,
  "created_at": "2026-05-05T12:00:00Z"
}
EOF
}

# -- ralph_clear_all_sessions: full reset path --------------------------------

@test "TAP-924: ralph_clear_all_sessions removes all three artifacts" {
    echo '{"session_id":"main-abc","timestamp":"2026-05-05T12:00:00Z"}' > "$RALPH_DIR/.claude_session_id"
    coordinator_session_write "coord-xyz"
    _write_brief

    ralph_clear_all_sessions

    [[ ! -e "$RALPH_DIR/.claude_session_id" ]] \
        || fail "main session file still present after clear"
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "coordinator session file still present after clear"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "brief.json still present after clear"
}

@test "TAP-924: ralph_clear_all_sessions is idempotent on missing files" {
    [[ ! -e "$RALPH_DIR/.claude_session_id" ]] || fail "fixture leaked"
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] || fail "fixture leaked"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "fixture leaked"

    run ralph_clear_all_sessions
    [[ "$status" -eq 0 ]] \
        || fail "expected exit 0 on missing files, got $status: $output"
}

# -- reset_session: CB open / is_error / continue-as-new path -----------------

@test "TAP-924: reset_session clears coordinator session + brief alongside main" {
    # reset_session is the canonical reset point — it's invoked on CB open,
    # is_error:true, continue-as-new, manual reset, and several other paths.
    # All of them must now wipe the coordinator artifacts too.
    coordinator_session_write "coord-reset-target"
    _write_brief

    reset_session "circuit_breaker_open"

    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "coordinator session NOT cleared by reset_session — CB open path leaks coord state"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "brief NOT cleared by reset_session — debrief on next loop would see stale brief"
    # reset_session writes a fresh empty Ralph session marker — verify it ran.
    [[ -f "$RALPH_SESSION_FILE" ]] \
        || fail "reset_session should write the Ralph session file"
}

# -- expired-session path in init_claude_session ------------------------------

@test "TAP-924: init_claude_session expiry path clears coordinator artifacts too" {
    # When the main session file is older than CLAUDE_SESSION_EXPIRY_HOURS,
    # init_claude_session deletes it. Coordinator + brief must go with it so
    # the next loop's coordinator doesn't resume onto a brief written for a
    # 24+ hour-old task.
    echo '{"session_id":"old-main","timestamp":"2020-01-01T00:00:00Z"}' > "$RALPH_DIR/.claude_session_id"
    # Backdate the main session file well past the 24h expiry.
    touch -d "@$(($(date +%s) - 90000))" "$RALPH_DIR/.claude_session_id" 2>/dev/null \
        || skip "platform lacks portable mtime backdate"
    coordinator_session_write "coord-stale"
    _write_brief

    run init_claude_session
    [[ "$status" -eq 0 ]] || fail "init_claude_session should return 0, got $status"

    [[ ! -e "$RALPH_DIR/.claude_session_id" ]] \
        || fail "main session NOT purged on expiry"
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "coordinator session NOT purged on main-session expiry"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "brief NOT purged on main-session expiry"
}

# -- ralph_clear_coordinator_artifacts: SIGINT / task-complete path -----------

@test "TAP-924: ralph_clear_coordinator_artifacts preserves main Claude session" {
    # Out-of-scope guard from the ticket: do NOT change when the main session
    # is cleared. Task-boundary and signal-trap clears touch coordinator only.
    echo '{"session_id":"main-keep","timestamp":"2026-05-05T12:00:00Z"}' > "$RALPH_DIR/.claude_session_id"
    coordinator_session_write "coord-drop"
    _write_brief

    ralph_clear_coordinator_artifacts

    [[ -f "$RALPH_DIR/.claude_session_id" ]] \
        || fail "main session was wiped by coordinator-only clear — out-of-scope violation"
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "coordinator session still present"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "brief still present"
}

# -- debrief-runs-before-clear ordering invariant -----------------------------

@test "TAP-924: debrief sees non-empty brief + session BEFORE the task-complete clear runs" {
    # This is the load-bearing correctness constraint. The post-debrief
    # task-complete clearing block reads brief + coordinator session, calls
    # ralph_debrief_coordinator, THEN clears. We pin the order by stubbing
    # ralph_debrief_coordinator to assert the artifacts are still present
    # when it's invoked.
    coordinator_session_write "coord-pre-debrief"
    _write_brief

    # Status fixture: tasks_completed=1 triggers the post-debrief clear.
    cat > "$RALPH_DIR/status.json" <<'EOF'
{"exit_signal":"false","tasks_completed":1,"permission_denial_count":0,"recommendation":""}
EOF

    # Capture state at the moment debrief is called.
    export STUB_OBSERVED_BRIEF=""
    export STUB_OBSERVED_COORD=""
    ralph_debrief_coordinator() {
        STUB_OBSERVED_BRIEF=$([[ -s "$RALPH_DIR/brief.json" ]] && echo "present" || echo "missing")
        STUB_OBSERVED_COORD=$([[ -s "$RALPH_DIR/.coordinator_session" ]] && echo "present" || echo "missing")
        echo "$STUB_OBSERVED_BRIEF" > "$RALPH_DIR/.debrief_saw_brief"
        echo "$STUB_OBSERVED_COORD" > "$RALPH_DIR/.debrief_saw_coord"
        return 0
    }
    cb_is_open() { return 1; }

    # Inline the production sequence from ralph_loop.sh's success branch:
    #   debrief → task-complete clear.
    local _debrief_tasks _debrief_pd
    _debrief_tasks=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json")
    _debrief_pd=$(jq -r '.permission_denial_count // 0' "${RALPH_DIR}/status.json")
    if cb_is_open || [[ "${_debrief_pd:-0}" -gt 0 ]]; then
        ralph_debrief_coordinator "failure" ""
    elif [[ "${_debrief_tasks:-0}" -gt 0 ]]; then
        ralph_debrief_coordinator "success" ""
    fi
    local _exit_sig_tc _tasks_done_tc
    _exit_sig_tc=$(jq -r '.exit_signal // "false"' "${RALPH_DIR}/status.json")
    _tasks_done_tc=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json")
    if [[ "$_exit_sig_tc" == "true" ]] || [[ "${_tasks_done_tc:-0}" -gt 0 ]]; then
        ralph_clear_coordinator_artifacts
    fi

    # Debrief must have observed both artifacts BEFORE the clear ran.
    [[ "$(cat "$RALPH_DIR/.debrief_saw_brief")" == "present" ]] \
        || fail "debrief observed brief as MISSING — clear ran before debrief (ordering bug)"
    [[ "$(cat "$RALPH_DIR/.debrief_saw_coord")" == "present" ]] \
        || fail "debrief observed coordinator session as MISSING — clear ran before debrief"

    # And the clear must have run after.
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "task-complete clear did not run after debrief"
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "task-complete clear did not run after debrief"
}

# -- task-complete trigger conditions -----------------------------------------

@test "TAP-924: task-complete clear fires on EXIT_SIGNAL=true (zero tasks completed)" {
    # End-of-campaign loop: Claude said "all done" but the count of
    # tasks_completed_this_loop may legitimately be 0 (e.g. the work landed
    # in an earlier loop and this one is the explicit exit signal).
    coordinator_session_write "coord-exit"
    _write_brief

    cat > "$RALPH_DIR/status.json" <<'EOF'
{"exit_signal":"true","tasks_completed":0,"permission_denial_count":0}
EOF

    local _exit_sig_tc _tasks_done_tc
    _exit_sig_tc=$(jq -r '.exit_signal // "false"' "${RALPH_DIR}/status.json")
    _tasks_done_tc=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json")
    if [[ "$_exit_sig_tc" == "true" ]] || [[ "${_tasks_done_tc:-0}" -gt 0 ]]; then
        ralph_clear_coordinator_artifacts
    fi

    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "EXIT_SIGNAL=true did not trigger task-complete clear"
    [[ ! -e "$RALPH_DIR/brief.json" ]] \
        || fail "EXIT_SIGNAL=true did not clear brief"
}

@test "TAP-924: task-complete clear does NOT fire mid-task (no exit, no completions)" {
    # In-progress loop: nothing finished, no exit signal. Coordinator session
    # and brief must stay so the next loop in the same task can pick up where
    # this one left off.
    coordinator_session_write "coord-keep"
    _write_brief

    cat > "$RALPH_DIR/status.json" <<'EOF'
{"exit_signal":"false","tasks_completed":0,"permission_denial_count":0}
EOF

    local _exit_sig_tc _tasks_done_tc
    _exit_sig_tc=$(jq -r '.exit_signal // "false"' "${RALPH_DIR}/status.json")
    _tasks_done_tc=$(jq -r '.tasks_completed // 0' "${RALPH_DIR}/status.json")
    if [[ "$_exit_sig_tc" == "true" ]] || [[ "${_tasks_done_tc:-0}" -gt 0 ]]; then
        ralph_clear_coordinator_artifacts
    fi

    [[ -s "$RALPH_DIR/.coordinator_session" ]] \
        || fail "coordinator session wiped mid-task — next loop loses resume state"
    [[ -s "$RALPH_DIR/brief.json" ]] \
        || fail "brief wiped mid-task — next loop loses prior_learnings/risk_level"
}

# -- production wiring assertions on ralph_loop.sh ----------------------------

@test "TAP-924: ralph_loop.sh defines ralph_clear_all_sessions" {
    declare -F ralph_clear_all_sessions >/dev/null \
        || fail "ralph_clear_all_sessions not defined after sourcing ralph_loop.sh"
}

@test "TAP-924: ralph_loop.sh defines ralph_clear_coordinator_artifacts" {
    declare -F ralph_clear_coordinator_artifacts >/dev/null \
        || fail "ralph_clear_coordinator_artifacts not defined after sourcing ralph_loop.sh"
}

@test "TAP-924: ralph_loop.sh removed all bare rm of CLAUDE_SESSION_FILE" {
    # All clearing now flows through the helper. A bare rm of CLAUDE_SESSION_FILE
    # would be a regression that bypasses coordinator + brief cleanup.
    run grep -nE 'rm[[:space:]]+-f[[:space:]]+"\$CLAUDE_SESSION_FILE"' "$REPO_ROOT_FIXED/ralph_loop.sh"
    [[ "$status" -ne 0 ]] \
        || fail "found bare rm of CLAUDE_SESSION_FILE — should use ralph_clear_all_sessions: $output"
}
