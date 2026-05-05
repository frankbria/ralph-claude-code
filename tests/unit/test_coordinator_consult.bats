#!/usr/bin/env bats
# TAP-922: coordinator_rpc.sh consult — unit tests for the HIGH-risk
# consultation gate.
#
# Mocks the `claude` binary with a tiny shell script so tests run without
# a real Claude process. The mock records argv, emits a fake stream-json
# session_id line, and optionally emits a verdict JSON in the result field.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."
RPC_SCRIPT="${REPO_ROOT_FIXED}/lib/coordinator_rpc.sh"

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_consult.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph bin

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    unset COORDINATOR_SESSION_MAX_AGE_SECONDS || true
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0

    # Fake claude that records argv and emits a valid APPROVE verdict.
    _write_mock_claude() {
        local verdict_line="${1:-{\"verdict\":\"APPROVE\",\"reason\":\"looks good\",\"alternative\":null,\"elevated_qa\":false}}"
        cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv"
echo '{"type":"system","subtype":"init","session_id":"mock-sid-0001"}'
echo '{"type":"result","result":"${verdict_line}","session_id":"mock-sid-0001"}'
exit 0
EOF
        chmod +x "$TEST_TEMP_DIR/bin/claude"
    }
    _write_mock_claude
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# Helper: write a minimal valid brief.json.
_write_brief() {
    local risk="${1:-HIGH}"
    jq -n \
        --arg risk "$risk" \
        '{
            schema_version: 1,
            task_id: "TAP-922",
            task_source: "linear",
            task_summary: "add consult gate",
            risk_level: $risk,
            affected_modules: ["lib/coordinator_rpc.sh"],
            acceptance_criteria: ["consult runs on HIGH", "skips on LOW/MEDIUM"],
            prior_learnings: [],
            qa_required: false,
            delegate_to: "ralph",
            coordinator_confidence: 0.8,
            created_at: "2026-05-05T00:00:00Z"
        }' > "$RALPH_DIR/brief.json"
}

# --- guards -----------------------------------------------------------------

@test "TAP-922: script exists and is executable" {
    [[ -x "$RPC_SCRIPT" ]] || fail "coordinator_rpc.sh is not executable at $RPC_SCRIPT"
}

@test "TAP-922: wrong subcommand prints usage and exits 1" {
    run bash "$RPC_SCRIPT" badcmd "plan text"
    [[ "$status" -eq 1 ]] || fail "expected exit 1 for unknown subcommand, got $status"
}

@test "TAP-922: skips when RALPH_COORDINATOR_DISABLED=true" {
    export RALPH_COORDINATOR_DISABLED=true
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
    [[ ! -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude should NOT be invoked when disabled"
}

@test "TAP-922: skips when DRY_RUN=true" {
    export DRY_RUN=true
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
    [[ ! -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude should NOT be invoked on dry run"
}

@test "TAP-922: skips when claude CLI not on PATH" {
    _write_brief HIGH
    export CLAUDE_CODE_CMD="/nonexistent/claude"
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
}

@test "TAP-922: skips when brief.json is missing" {
    rm -f "$RALPH_DIR/brief.json"
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
    [[ ! -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude should NOT be invoked with no brief"
}

@test "TAP-922: skips when risk_level is LOW" {
    _write_brief LOW
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
    [[ ! -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude should NOT be invoked for LOW risk"
}

@test "TAP-922: skips when risk_level is MEDIUM" {
    _write_brief MEDIUM
    run bash "$RPC_SCRIPT" consult "PLAN: do something"
    [[ "$status" -eq 0 ]]        || fail "expected exit 0, got $status"
    echo "$output" | grep -q '"skipped"' || fail "expected skipped JSON, got: $output"
    [[ ! -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude should NOT be invoked for MEDIUM risk"
}

# --- consult invocation (HIGH-risk path) ------------------------------------

@test "TAP-922: invokes coordinator when risk_level is HIGH" {
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: refactor exit gate"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status (output: $output)"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude was NOT invoked for HIGH risk"
}

@test "TAP-922: passes MODE=consult in the prompt body" {
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: touch circuit breaker"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude was NOT invoked"
    grep -q 'MODE=consult' "$TEST_TEMP_DIR/.last_argv" \
        || fail "argv must contain MODE=consult, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
}

@test "TAP-922: passes plan text in prompt body" {
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: rewrite the rate limiter"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude was NOT invoked"
    grep -q 'rewrite the rate limiter' "$TEST_TEMP_DIR/.last_argv" \
        || fail "plan text not found in argv, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
}

@test "TAP-922: returns APPROVE verdict JSON on stdout" {
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: add a test helper"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status"
    echo "$output" | jq -e '.verdict == "APPROVE"' >/dev/null \
        || fail "expected APPROVE verdict in output: $output"
}

@test "TAP-922: returns BLOCK verdict when coordinator emits BLOCK" {
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv"
echo '{"type":"system","subtype":"init","session_id":"mock-sid-0002"}'
echo '{"type":"result","result":"{\"verdict\":\"BLOCK\",\"reason\":\"breaks API contract\",\"alternative\":\"use existing helper\",\"elevated_qa\":true}","session_id":"mock-sid-0002"}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: remove a public function"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status"
    echo "$output" | jq -e '.verdict == "BLOCK"' >/dev/null \
        || fail "expected BLOCK verdict in output: $output"
    echo "$output" | jq -e '.elevated_qa == true' >/dev/null \
        || fail "expected elevated_qa=true in BLOCK output: $output"
}

@test "TAP-922: defaults to APPROVE when coordinator output has no verdict JSON" {
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv"
echo '{"type":"system","subtype":"init","session_id":"mock-sid-0003"}'
echo '{"type":"result","result":"I think you should proceed with caution.","session_id":"mock-sid-0003"}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: something"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status"
    echo "$output" | jq -e '.verdict == "APPROVE"' >/dev/null \
        || fail "expected fallback APPROVE, got: $output"
    echo "$output" | grep -q 'defaulting to APPROVE' \
        || fail "expected 'defaulting to APPROVE' in fallback reason: $output"
}

@test "TAP-922: defaults to APPROVE when coordinator exits non-zero" {
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: something risky"
    [[ "$status" -eq 0 ]] || fail "expected exit 0 even on claude failure, got $status"
    echo "$output" | jq -e '.verdict == "APPROVE"' >/dev/null \
        || fail "expected fallback APPROVE, got: $output"
}

@test "TAP-922: passes --resume when coordinator session exists" {
    # Pre-seed a fresh session file by sourcing coordinator_session.sh.
    # Use a temp coordinator_session.sh approach: write the session file directly.
    printf '%s\n' "pre-seeded-sid-9999" > "$RALPH_DIR/.coordinator_session"
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: do something HIGH"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status"
    [[ -f "$TEST_TEMP_DIR/.last_argv" ]] || fail "claude was NOT invoked"
    grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv" \
        || fail "expected --resume in argv when session exists, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
    grep -q '^pre-seeded-sid-9999$' "$TEST_TEMP_DIR/.last_argv" \
        || fail "expected session_id in argv, got:\n$(cat "$TEST_TEMP_DIR/.last_argv")"
}

@test "TAP-922: captures and persists session_id from coordinator output" {
    _write_brief HIGH
    run bash "$RPC_SCRIPT" consult "PLAN: something new"
    [[ "$status" -eq 0 ]] || fail "expected exit 0, got $status"
    local sid_file="$RALPH_DIR/.coordinator_session"
    [[ -s "$sid_file" ]] || fail "coordinator_session file not written"
    local sid
    sid=$(cat "$sid_file")
    [[ "$sid" == "mock-sid-0001" ]] \
        || fail "expected session_id 'mock-sid-0001', got: '$sid'"
}
