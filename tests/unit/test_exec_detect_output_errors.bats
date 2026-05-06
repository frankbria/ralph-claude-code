#!/usr/bin/env bats
# TAP-1484: behavior contract for exec_detect_output_errors (lib/exec_helpers.sh).
#
# Tests the 2-stage error pattern detection — Stage 1 JSON field-name filter
# followed by Stage 2 error-marker grep. The 2 stages prevent legitimate JSON
# fields like `"is_error":false` from false-positiving as actual errors.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TMPDIR_TC="$(mktemp -d)"
    OUT="$TMPDIR_TC/out.log"
    LOG_FILE="$TMPDIR_TC/log.out"
    : > "$LOG_FILE"

    # Use a tmpfile so log lines emitted from subshell pipelines (e.g. inside
    # `... | while ...; done`) survive the subshell and remain inspectable.
    LAST_LOG_LEVEL=""
    LAST_LOG_MSG=""
    log_status() {
        LAST_LOG_LEVEL="$1"
        LAST_LOG_MSG="$2"
        printf '%s: %s\n' "$1" "$2" >> "$LOG_FILE"
    }
    export -f log_status

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

@test "TAP-1484: clean output → return 1, no detection" {
    cat > "$OUT" <<'OUT'
{"type":"system","subtype":"init"}
{"type":"assistant","content":"normal Claude response"}
{"type":"result","is_error":false,"result":"ok"}
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1 for clean output, got $rc"
    [[ "$LAST_LOG_LEVEL" == "" ]] || fail "should not log on clean output, got '$LAST_LOG_LEVEL'"
}

@test "TAP-1484: leading 'Error:' → detected" {
    cat > "$OUT" <<'OUT'
Error: failed to compile foo.rs
something else
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 on Error: detection, got $rc"
    [[ "$LAST_LOG_LEVEL" == "WARN" ]] || fail "expected WARN log, got '$LAST_LOG_LEVEL'"
}

@test "TAP-1484: 'Exception' marker → detected" {
    cat > "$OUT" <<'OUT'
Traceback (most recent call last):
  Exception: something went wrong
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected detection on Exception marker, got $rc"
}

@test "TAP-1484: 'Fatal:' marker → detected" {
    cat > "$OUT" <<'OUT'
Fatal: process killed
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected detection on Fatal: marker, got $rc"
}

@test "TAP-1484: 'FATAL' all-caps → detected" {
    cat > "$OUT" <<'OUT'
[2026-05-06] FATAL out of memory
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected detection on FATAL marker, got $rc"
}

@test "TAP-1484: JSON '\"is_error\": false' → NO false positive (Stage 1 filter)" {
    cat > "$OUT" <<'OUT'
{"type":"result","is_error":false,"content":"normal response"}
{"type":"system","data":{"is_error":false}}
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "Stage 1 filter should skip JSON is_error fields, got rc=$rc"
}

@test "TAP-1484: JSON '\"error_count\": 0' → NO false positive" {
    cat > "$OUT" <<'OUT'
{"type":"result","error_count":0,"warning_count":1}
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "JSON error_count field should not match, got rc=$rc"
}

@test "TAP-1484: JSON '\"errors\": []' → NO false positive" {
    cat > "$OUT" <<'OUT'
{"type":"result","errors":[],"diagnostics":[]}
OUT
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "JSON errors:[] field should not match, got rc=$rc"
}

@test "TAP-1484: missing output file → return 1 (defensive)" {
    local rc=0
    exec_detect_output_errors "$TMPDIR_TC/does-not-exist" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1 on missing file, got $rc"
}

@test "TAP-1484: VERBOSE_PROGRESS=true emits DEBUG lines for matches" {
    cat > "$OUT" <<'OUT'
Error: thing one
Error: thing two
Error: thing three
Error: thing four (should not appear in DEBUG output — head -3)
OUT
    VERBOSE_PROGRESS="true"
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected detection, got $rc"

    # Read DEBUG lines from the log tmpfile (survives the subshell pipeline).
    local debug_count
    debug_count=$(grep -c '^DEBUG: ' "$LOG_FILE" 2>/dev/null | tr -cd '0-9')
    debug_count=${debug_count:-0}
    # Expected: 1 "Error patterns found:" header + 3 match lines = 4 DEBUG entries.
    [[ "$debug_count" -eq 4 ]] \
        || fail "expected 4 DEBUG log lines (header + 3 matches), got $debug_count: $(cat $LOG_FILE)"

    # And should NOT see "thing four" in DEBUG (head -3 truncation).
    ! grep -q "thing four" "$LOG_FILE" \
        || fail "head -3 should suppress 4th match, got: $(cat $LOG_FILE)"
}

@test "TAP-1484: VERBOSE_PROGRESS=false (default) → no DEBUG lines" {
    cat > "$OUT" <<'OUT'
Error: thing one
OUT
    VERBOSE_PROGRESS="false"
    local rc=0
    exec_detect_output_errors "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected detection, got $rc"

    local debug_count
    debug_count=$(grep -c '^DEBUG: ' "$LOG_FILE" 2>/dev/null | tr -cd '0-9')
    debug_count=${debug_count:-0}
    [[ "$debug_count" -eq 0 ]] \
        || fail "expected 0 DEBUG lines without VERBOSE_PROGRESS, got $debug_count"
}

@test "TAP-1484: ralph_loop.sh dispatches via exec_detect_output_errors" {
    grep -qE 'exec_detect_output_errors[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_detect_output_errors"
}

@test "TAP-1484: dead has_errors / output_length locals removed from ralph_loop.sh" {
    ! grep -qE 'local has_errors=' "$ROOT/ralph_loop.sh" \
        || fail "dead 'has_errors' local should be removed"
    ! grep -qE 'local output_length=' "$ROOT/ralph_loop.sh" \
        || fail "dead 'output_length' local should be removed"
}
