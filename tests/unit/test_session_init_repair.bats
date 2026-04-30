#!/usr/bin/env bats
# SESSION-ID-FIX (2026-04-30): ralph_initialize_session used to write
# `session_id: ""` "for lazy init" — but the lazy-init step that was
# supposed to fill it later never existed. save_claude_session writes
# the Claude CLI's session_id to .claude_session_id (a separate file),
# not .ralph_session. Result: every loop fired a chronic
# "Session file exists but session_id is empty — reinitializing"
# warning, then re-wrote empty, then warned again on the next loop.
# These tests pin the fix: ralph_initialize_session must write a real,
# non-empty Ralph-internal session_id (via generate_session_id).

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/session_init.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

@test "SESSION-ID-FIX: ralph_initialize_session writes a non-empty session_id" {
    # The pre-fix behavior wrote `session_id: ""` deliberately; the fix
    # generates a real ID via the existing generate_session_id helper so the
    # chronic "session_id is empty — reinitializing" warning stops.
    ralph_initialize_session
    [[ -f "$RALPH_SESSION_FILE" ]] || fail "session file not written"

    local sid
    sid=$(jq -r '.session_id' "$RALPH_SESSION_FILE")
    [[ -n "$sid" && "$sid" != "null" && "$sid" != '""' ]] \
        || fail "expected non-empty session_id, got: '$sid'"

    # generate_session_id format: ralph-<epoch>-<rand>
    [[ "$sid" =~ ^ralph-[0-9]+-[0-9]+$ ]] \
        || fail "expected ralph-<ts>-<rand> format, got: '$sid'"
}

@test "SESSION-ID-FIX: ralph_validate_session does NOT loop after ralph_initialize_session" {
    # Repro of the chronic-warning loop. Pre-fix: validate sees empty →
    # initialize writes empty → next validate sees empty again → warn forever.
    # Post-fix: validate sees non-empty after initialize → returns 0, no warn.
    export CLAUDE_USE_CONTINUE=true
    ralph_initialize_session

    run ralph_validate_session
    [[ "$status" -eq 0 ]] || fail "validate should return 0 after initialize, got $status"
    [[ "$output" != *"session_id is empty"* ]] \
        || fail "validate emitted the empty-session warning AFTER initialize: $output"
}

@test "SESSION-ID-FIX: log message names the generated id" {
    # Operator-visible signal — the prior message ended with
    # '(awaiting session_id from next Claude invocation)' which was a lie:
    # nothing populated it later. Replaced with the actual generated id so
    # operators can tail .ralph/logs/ralph.log and see the rotation.
    run ralph_initialize_session
    [[ "$output" == *"Session reinitialized"* ]] \
        || fail "expected 'Session reinitialized' in log, got: $output"
    [[ "$output" == *"id: ralph-"* ]] \
        || fail "expected log to name the generated id, got: $output"
    [[ "$output" != *"awaiting session_id"* ]] \
        || fail "old misleading 'awaiting session_id' message must be gone, got: $output"
}
