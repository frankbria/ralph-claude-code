#!/usr/bin/env bats
# TAP-921: resume coordinator via --resume <session_id> (resume-or-spawn).
# Tests the new public ralph_coordinator_invoke entry point and the
# resume-or-spawn behavior inside _coordinator_invoke_claude.
#
# These tests exercise the CLI argv assembly directly by mocking the
# `claude` binary as a tiny shell script that records its argv into a
# file. That lets us assert on whether `--resume <sid>` was passed
# without depending on a real Claude process.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_resume.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs bin
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    unset COORDINATOR_SESSION_MAX_AGE_SECONDS || true

    # Fake `claude` binary that records argv to .last_argv and emits a
    # stream-json line so the session capture runs end-to-end.
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv"
echo '{"type":"system","subtype":"init","session_id":"newly-spawned-sid-0000"}'
echo '{"type":"result","session_id":"newly-spawned-sid-0000","success":true}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"
    # Disable timeout to keep argv predictable across platforms.
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0

    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# -- public entry shape ------------------------------------------------------

@test "TAP-921: ralph_coordinator_invoke is defined" {
    declare -F ralph_coordinator_invoke >/dev/null \
        || fail "ralph_coordinator_invoke not defined after sourcing ralph_loop.sh"
}

@test "TAP-921: ralph_coordinator_invoke skips when RALPH_COORDINATOR_DISABLED=true" {
    export RALPH_COORDINATOR_DISABLED=true
    rm -f "$TEST_TEMP_DIR/.last_argv"
    run ralph_coordinator_invoke brief "hello"
    [[ "$status" -eq 0 ]] || fail "expected zero exit on disabled"
    [[ ! -e "$TEST_TEMP_DIR/.last_argv" ]] \
        || fail "claude should NOT be invoked when disabled"
}

@test "TAP-921: ralph_coordinator_invoke skips on DRY_RUN" {
    export DRY_RUN=true
    rm -f "$TEST_TEMP_DIR/.last_argv"
    run ralph_coordinator_invoke brief "hello"
    [[ "$status" -eq 0 ]] || fail "expected zero exit on dry-run"
    [[ ! -e "$TEST_TEMP_DIR/.last_argv" ]] \
        || fail "claude should NOT be invoked on dry-run"
}

# -- resume-or-spawn argv assembly ------------------------------------------

@test "TAP-921: first invocation spawns FRESH (no --resume in argv)" {
    coordinator_session_clear
    run ralph_coordinator_invoke brief "first body"
    [[ "$status" -eq 0 ]] || fail "expected zero exit on first invoke"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude wasn't invoked"
    grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv" \
        && fail "first invoke must NOT pass --resume, got argv: $(cat "$TEST_TEMP_DIR/.last_argv")"
    # Session captured from the fake stdout.
    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "newly-spawned-sid-0000" ]] \
        || fail "expected captured session_id from spawn, got: '$sid'"
}

@test "TAP-921: second invocation passes --resume with the persisted session_id" {
    # Pre-seed a fresh session.
    coordinator_session_write "persisted-sid-1111"
    run ralph_coordinator_invoke brief "second body"
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude wasn't invoked"
    grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv" \
        || fail "second invoke must pass --resume, got argv:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
    grep -q '^persisted-sid-1111$' "$TEST_TEMP_DIR/.last_argv" \
        || fail "argv must include the persisted session_id, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
}

@test "TAP-921: stale session forces fresh spawn no resume" {
    coordinator_session_write "stale-sid-2222"
    export COORDINATOR_SESSION_MAX_AGE_SECONDS=1
    # Backdate the file ~5s — well past the 1s max.
    if ! touch -d "@$(($(date +%s) - 5))" "$RALPH_DIR/.coordinator_session" 2>/dev/null; then
        skip "platform lacks portable mtime backdate"
    fi
    run ralph_coordinator_invoke brief "stale body"
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    if grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv"; then
        fail "stale session must NOT trigger --resume"
    fi
}

@test "TAP-921: argv includes the MODE= header in the prompt body" {
    coordinator_session_clear
    run ralph_coordinator_invoke debrief "OUTCOME=success"
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    # The -p body is one of the argv lines; check it carries MODE=debrief.
    grep -q 'MODE=debrief' "$TEST_TEMP_DIR/.last_argv" \
        || fail "expected MODE=debrief in argv body, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
}

@test "TAP-921: session_id stays stable on resume (capture writes the same id back)" {
    coordinator_session_write "stable-sid-3333"
    # Re-fake claude so it echoes the SAME session_id (real CLI does this on resume).
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv"
echo '{"type":"system","subtype":"init","session_id":"stable-sid-3333"}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    run ralph_coordinator_invoke brief "resume body"
    [[ "$status" -eq 0 ]] || fail "expected zero exit"
    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "stable-sid-3333" ]] \
        || fail "session_id should remain stable across resume, got: '$sid'"
}

# -- existing wrappers still flow through new path --------------------------

@test "TAP-921: ralph_spawn_coordinator routes through ralph_coordinator_invoke" {
    # Trace by overriding ralph_coordinator_invoke and asserting it was called
    # with mode=brief.
    local trace="$TEST_TEMP_DIR/.invoke_trace"
    : > "$trace"
    ralph_coordinator_invoke() { echo "$1" >> "$trace"; return 0; }

    # Stub out other side effects ralph_spawn_coordinator depends on.
    brief_clear() { :; }
    brief_validate() { return 0; }

    run ralph_spawn_coordinator 5
    [[ "$status" -eq 0 ]] || fail "spawn returned non-zero"
    grep -q '^brief$' "$trace" \
        || fail "spawn must call ralph_coordinator_invoke with mode=brief, got: $(cat "$trace")"
}

@test "TAP-921: ralph_debrief_coordinator routes through ralph_coordinator_invoke" {
    local trace="$TEST_TEMP_DIR/.invoke_trace"
    : > "$trace"
    ralph_coordinator_invoke() { echo "$1" >> "$trace"; return 0; }

    run ralph_debrief_coordinator success ""
    [[ "$status" -eq 0 ]] || fail "debrief returned non-zero"
    grep -q '^debrief$' "$trace" \
        || fail "debrief must call ralph_coordinator_invoke with mode=debrief, got: $(cat "$trace")"
}
