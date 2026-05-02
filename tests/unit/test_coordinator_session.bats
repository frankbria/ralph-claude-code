#!/usr/bin/env bats
# TAP-920: persist coordinator session_id across loops.
# Tests the helpers in lib/coordinator_session.sh + the capture step
# wired into ralph_spawn_coordinator. Resume logic is story 2.2 (TAP-921)
# and is NOT covered here.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_sess.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    unset COORDINATOR_SESSION_MAX_AGE_SECONDS || true
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# -- helpers in isolation ----------------------------------------------------

@test "TAP-920: session_path honors RALPH_DIR" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local p
    p=$(coordinator_session_path)
    [[ "$p" == "$RALPH_DIR/.coordinator_session" ]] \
        || fail "expected RALPH_DIR-relative path, got: $p"
}

@test "TAP-920: write then read returns the same id" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local sid="abcd1234-ef56-7890-abcd-ef1234567890"
    coordinator_session_write "$sid"
    local got
    got=$(coordinator_session_read)
    [[ "$got" == "$sid" ]] || fail "read mismatch — wrote '$sid', got '$got'"
}

@test "TAP-920: read returns empty when file missing" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local got
    got=$(coordinator_session_read)
    [[ -z "$got" ]] || fail "expected empty, got: '$got'"
}

@test "TAP-920: clear removes the file" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    coordinator_session_write "deadbeef-1234"
    [[ -f "$RALPH_DIR/.coordinator_session" ]] || fail "fixture write failed"
    coordinator_session_clear
    [[ ! -e "$RALPH_DIR/.coordinator_session" ]] \
        || fail "session file still present after clear"
}

@test "TAP-920: age_seconds returns 999999 when file missing" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local age
    age=$(coordinator_session_age_seconds)
    [[ "$age" == "999999" ]] || fail "expected 999999 for missing file, got: $age"
}

@test "TAP-920: age_seconds reflects mtime of an aged file" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    coordinator_session_write "x"
    # Backdate by ~10 seconds.
    touch -d "@$(($(date +%s) - 10))" "$RALPH_DIR/.coordinator_session" 2>/dev/null \
        || touch -t "$(date -d '@'"$(($(date +%s) - 10))" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
                 "$RALPH_DIR/.coordinator_session" 2>/dev/null \
        || skip "platform lacks portable mtime backdate"
    local age
    age=$(coordinator_session_age_seconds)
    [[ "$age" -ge 9 && "$age" -le 30 ]] \
        || fail "expected age ~10s, got: $age"
}

@test "TAP-920: read returns empty for STALE file (over MAX_AGE)" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    coordinator_session_write "stale-xyz"
    export COORDINATOR_SESSION_MAX_AGE_SECONDS=1
    # Backdate 5s — comfortably past the 1s max.
    touch -d "@$(($(date +%s) - 5))" "$RALPH_DIR/.coordinator_session" 2>/dev/null \
        || skip "platform lacks portable mtime backdate"
    local got
    got=$(coordinator_session_read)
    [[ -z "$got" ]] || fail "stale session should read as empty, got: '$got'"
    # File is NOT auto-deleted — story 2.5 owns lifecycle.
    [[ -f "$RALPH_DIR/.coordinator_session" ]] \
        || fail "read should NOT delete a stale file (lifecycle owned by story 2.5)"
}

@test "TAP-920: write is atomic (no partial files left behind)" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    coordinator_session_write "atomic-test-id"
    # No leftover .tmp.* siblings.
    local leftover
    leftover=$(find "$RALPH_DIR" -maxdepth 1 -name '.coordinator_session.tmp.*' 2>/dev/null | head -1)
    [[ -z "$leftover" ]] || fail "atomic_write leaked a temp file: $leftover"
}

@test "TAP-920: extract_from_stream parses session_id from JSONL stream" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local stream="$TEST_TEMP_DIR/sample.jsonl"
    cat > "$stream" <<'EOF'
{"type":"system","subtype":"init","session_id":"f00ba455-1111-2222-3333-444455556666"}
{"type":"assistant","content":[{"type":"text","text":"working"}]}
{"type":"result","session_id":"f00ba455-1111-2222-3333-444455556666","success":true}
EOF
    local sid
    sid=$(coordinator_session_extract_from_stream "$stream")
    [[ "$sid" == "f00ba455-1111-2222-3333-444455556666" ]] \
        || fail "expected first session_id, got: '$sid'"
}

@test "TAP-920: extract_from_stream returns empty for stream without session_id" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
    local stream="$TEST_TEMP_DIR/no_sid.jsonl"
    echo '{"type":"assistant","content":[{"type":"text","text":"nope"}]}' > "$stream"
    local sid
    sid=$(coordinator_session_extract_from_stream "$stream")
    [[ -z "$sid" ]] || fail "expected empty for streamless of session_id, got: '$sid'"
}

# -- integration with ralph_spawn_coordinator -------------------------------

@test "TAP-920: ralph_spawn_coordinator captures session_id from spawn output" {
    # Source ralph_loop.sh so spawn + helpers are defined.
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    # Mock _coordinator_invoke_claude — write a JSONL line carrying a
    # session_id to the out_file (arg $2), and a valid brief.
    _coordinator_invoke_claude() {
        local _input="$1"
        local _out="$2"
        cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-920",
  "task_source": "linear",
  "task_summary": "capture session id",
  "risk_level": "LOW",
  "affected_modules": ["lib/coordinator_session.sh"],
  "acceptance_criteria": ["spawn_captures_session"],
  "prior_learnings": [],
  "qa_required": false,
  "qa_scope": "",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.5,
  "created_at": "2026-05-02T14:00:00Z"
}
EOF
        if [[ -n "$_out" ]]; then
            cat > "$_out" <<'STREAM'
{"type":"system","subtype":"init","session_id":"cafef00d-1234-5678-9abc-def012345678"}
{"type":"result","session_id":"cafef00d-1234-5678-9abc-def012345678","success":true}
STREAM
        fi
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "spawn returned non-zero: $output"
    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "cafef00d-1234-5678-9abc-def012345678" ]] \
        || fail "expected captured session_id, got: '$sid'"
    [[ "$output" == *"session captured"* ]] \
        || fail "expected INFO log on capture, got: $output"
}

@test "TAP-920: capture works even when spawn returns non-zero (timeout)" {
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    # Mock — write a partial stream with session_id, then return 124 (timeout).
    _coordinator_invoke_claude() {
        local _out="$2"
        if [[ -n "$_out" ]]; then
            echo '{"type":"system","subtype":"init","session_id":"timeout-sid-9999"}' > "$_out"
        fi
        return 124
    }
    export CLAUDE_CODE_CMD=bash
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=1

    run ralph_spawn_coordinator 2
    [[ "$status" -eq 0 ]] || fail "spawn helper should return 0 (best-effort)"
    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "timeout-sid-9999" ]] \
        || fail "should still capture session_id from partial output on timeout, got: '$sid'"
}
