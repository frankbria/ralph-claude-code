#!/usr/bin/env bats
# TAP-1476: behavior contract for exec_detect_rate_limit (lib/exec_helpers.sh).
#
# Asserts the 4-layer rate-limit detector returns 0 on clean output and 2 on
# any of the documented limit signals — including the false-positive guard
# against echoed tool_result / tool_use_id lines that contain limit phrasing.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    log_status() { :; }
    export -f log_status

    TMPDIR_TC="$(mktemp -d)"
    OUT="$TMPDIR_TC/out.json"

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

@test "TAP-1476: clean output → return 0" {
    cat > "$OUT" <<'JSON'
{"type":"system","subtype":"init"}
{"type":"assistant","content":"normal response"}
{"type":"result","is_error":false}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 for clean output, got $rc"
}

@test "TAP-1476: rate_limit_event with status:rejected → return 2" {
    cat > "$OUT" <<'JSON'
{"type":"rate_limit_event","status":"rejected","limit":"5h"}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected return 2 on rejected limit, got $rc"
}

@test "TAP-1476: rate_limit_event without rejected status → return 0" {
    cat > "$OUT" <<'JSON'
{"type":"rate_limit_event","status":"warned"}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 for non-rejected event, got $rc"
}

@test "TAP-1476: '5-hour limit' phrasing in tail text → return 2" {
    cat > "$OUT" <<'JSON'
{"type":"system"}
{"type":"assistant","content":"You have hit the 5 hour limit. Please try back later."}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected return 2 on 5-hour limit phrase, got $rc"
}

@test "TAP-1476: 'usage limit reached' phrasing → return 2" {
    cat > "$OUT" <<'JSON'
{"type":"assistant","content":"Your usage limit has been reached for this period."}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected return 2 on usage-limit phrase, got $rc"
}

@test "TAP-1476: 'out of extra usage' (Extra Usage quota) → return 2" {
    cat > "$OUT" <<'JSON'
{"type":"assistant","content":"You're out of extra usage · resets 9pm"}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 2 ]] || fail "expected return 2 on Extra Usage exhaustion, got $rc"
}

@test "TAP-1476: limit phrasing inside tool_result line → return 0 (filtered)" {
    # The user's source code legitimately contains "5 hour limit" as text being
    # read by Claude — the filter must not false-positive on echoed tool output.
    cat > "$OUT" <<'JSON'
{"type":"user","message":{"content":[{"type":"tool_result","content":"function: enforce 5 hour limit on session age"}]}}
{"type":"assistant","content":"normal response"}
{"type":"result","is_error":false}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 (filter must skip tool_result), got $rc"
}

@test "TAP-1476: limit phrasing inside tool_use_id-bearing line → return 0 (filtered)" {
    cat > "$OUT" <<'JSON'
{"type":"user","tool_use_id":"abc","message":{"content":[{"type":"tool_result","content":"old comment about usage limit reached behavior"}]}}
JSON
    local rc=0
    exec_detect_rate_limit "$OUT" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 (filter must skip tool_use_id lines), got $rc"
}

@test "TAP-1476: missing output file → return 0 (defensive)" {
    local rc=0
    exec_detect_rate_limit "$TMPDIR_TC/does-not-exist" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "expected return 0 on missing file, got $rc"
}

@test "TAP-1476: ralph_loop.sh dispatches via exec_detect_rate_limit" {
    grep -qE 'exec_detect_rate_limit[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_detect_rate_limit"
}

@test "TAP-1476: inline rate_limit_event check removed from ralph_loop.sh" {
    # The old inline grep on rate_limit_event lived inside execute_claude_code.
    # After extraction it should only appear in lib/exec_helpers.sh.
    ! grep -qE '"rate_limit_event"' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline rate_limit_event grep"
}
