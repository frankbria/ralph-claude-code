#!/usr/bin/env bats
# TAP-1474: behavior contract for exec_classify_api_error (lib/exec_helpers.sh).
# Asserts the three branches of the unified is_error:true classifier:
#   - not an is_error (or missing file / invalid JSON) → return 0
#   - monthly spend cap → return 4 + MONTHLY_CAP_DATE extracted
#   - generic is_error (incl. tool-use-concurrency) → return 1 + session reset

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    # Stubs for functions called by the classifier. Capture invocations so
    # tests can assert on them without invoking the real implementations.
    log_status() { :; }
    reset_session() { LAST_RESET_SESSION_REASON="${1:-}"; }
    export -f log_status reset_session 2>/dev/null || true

    # Per-test scratch dir for fixture files.
    TMPDIR_TC="$(mktemp -d)"
    PROGRESS_FILE="$TMPDIR_TC/progress.json"
    MONTHLY_CAP_DATE=""
    LAST_RESET_SESSION_REASON=""

    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

@test "TAP-1474: missing output file → return 0 (caller continues)" {
    run exec_classify_api_error "$TMPDIR_TC/does-not-exist" 0
    [[ "$status" -eq 0 ]] || fail "expected return 0, got $status"
}

@test "TAP-1474: not an is_error → return 0" {
    echo '{"is_error":false,"result":"ok"}' > "$TMPDIR_TC/out.json"
    run exec_classify_api_error "$TMPDIR_TC/out.json" 0
    [[ "$status" -eq 0 ]] || fail "expected return 0, got $status"
}

@test "TAP-1474: invalid JSON → return 0 (defensive: jq returns 'false' literal)" {
    echo 'this is not json' > "$TMPDIR_TC/out.json"
    run exec_classify_api_error "$TMPDIR_TC/out.json" 0
    [[ "$status" -eq 0 ]] || fail "expected return 0 on invalid JSON, got $status"
}

@test "TAP-1474: monthly spend cap → return 4, MONTHLY_CAP_DATE extracted" {
    cat > "$TMPDIR_TC/out.json" <<'JSON'
{"is_error":true,"result":"You have reached your specified API usage limits. You will regain access on 2026-05-01 at 00:00 UTC."}
JSON
    local rc=0
    exec_classify_api_error "$TMPDIR_TC/out.json" 0 || rc=$?
    [[ "$rc" -eq 4 ]] || fail "expected return 4, got $rc"
    [[ "$MONTHLY_CAP_DATE" == "2026-05-01" ]] \
        || fail "expected MONTHLY_CAP_DATE=2026-05-01, got '$MONTHLY_CAP_DATE'"
}

@test "TAP-1474: monthly cap detected from 'regain access on' phrase alone" {
    cat > "$TMPDIR_TC/out.json" <<'JSON'
{"is_error":true,"result":"Quota issue. You can regain access on 2026-12-31 at midnight UTC."}
JSON
    local rc=0
    exec_classify_api_error "$TMPDIR_TC/out.json" 0 || rc=$?
    [[ "$rc" -eq 4 ]] || fail "expected return 4, got $rc"
    [[ "$MONTHLY_CAP_DATE" == "2026-12-31" ]] \
        || fail "expected MONTHLY_CAP_DATE=2026-12-31, got '$MONTHLY_CAP_DATE'"
}

@test "TAP-1474: tool-use-concurrency → return 1 + categorized reset reason" {
    cat > "$TMPDIR_TC/out.json" <<'JSON'
{"is_error":true,"result":"tool use concurrency limit exceeded"}
JSON
    local rc=0
    exec_classify_api_error "$TMPDIR_TC/out.json" 1 || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1, got $rc"
    [[ "$LAST_RESET_SESSION_REASON" == "tool_use_concurrency_error" ]] \
        || fail "expected concurrency reset reason, got '$LAST_RESET_SESSION_REASON'"
}

@test "TAP-1474: generic is_error → return 1 + generic reset reason" {
    cat > "$TMPDIR_TC/out.json" <<'JSON'
{"is_error":true,"result":"some other API failure"}
JSON
    local rc=0
    exec_classify_api_error "$TMPDIR_TC/out.json" 0 || rc=$?
    [[ "$rc" -eq 1 ]] || fail "expected return 1, got $rc"
    [[ "$LAST_RESET_SESSION_REASON" == "api_error_is_error_true" ]] \
        || fail "expected generic reset reason, got '$LAST_RESET_SESSION_REASON'"
}

@test "TAP-1474: is_error path writes PROGRESS_FILE" {
    cat > "$TMPDIR_TC/out.json" <<'JSON'
{"is_error":true,"result":"some failure"}
JSON
    local rc=0
    exec_classify_api_error "$TMPDIR_TC/out.json" 0 || rc=$?
    [[ -f "$PROGRESS_FILE" ]] || fail "PROGRESS_FILE not written"
    grep -q '"status": "failed"' "$PROGRESS_FILE" \
        || fail "PROGRESS_FILE missing status:failed"
    grep -q '"error": "is_error:true"' "$PROGRESS_FILE" \
        || fail "PROGRESS_FILE missing error marker"
}

@test "TAP-1474: classifier is callable from a sourced exec_helpers.sh" {
    declare -F exec_classify_api_error >/dev/null \
        || fail "exec_classify_api_error should be defined after sourcing lib/exec_helpers.sh"
}

@test "TAP-1474: ralph_loop.sh dispatches via exec_classify_api_error" {
    grep -qE 'exec_classify_api_error[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_classify_api_error"
}

@test "TAP-1474: inline classifier removed from ralph_loop.sh" {
    # The old inline marker — top-level $(jq -r '.is_error // false') in
    # execute_claude_code — should no longer appear; the classifier owns it.
    ! grep -qE '_ralph_json_is_error=' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the old inline classifier variables"
}
