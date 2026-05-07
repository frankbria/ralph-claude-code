#!/usr/bin/env bats
# TAP-1530 follow-up: coordinator_rpc.sh must export
# RALPH_COORDINATOR_INVOCATION=1 before spawning the claude CLI so the
# project's on-stop hook skips RALPH_STATUS accounting for the coordinator
# response. Without this, every HIGH-risk consult would increment
# .no_status_block_count and trip no_status_block_3x within 1–2 main loops.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."
RPC_SCRIPT="${REPO_ROOT_FIXED}/lib/coordinator_rpc.sh"

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_rpc.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph bin

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0
    unset RALPH_COORDINATOR_INVOCATION || true

    # Mock claude that records the env var value at spawn time.
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
echo "RALPH_COORDINATOR_INVOCATION=\${RALPH_COORDINATOR_INVOCATION:-UNSET}" \\
    > "$TEST_TEMP_DIR/.spawn_env"
echo '{"type":"system","subtype":"init","session_id":"mock-sid-0001"}'
echo '{"type":"result","result":"{\"verdict\":\"APPROVE\",\"reason\":\"ok\",\"alternative\":null,\"elevated_qa\":false}","session_id":"mock-sid-0001"}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"

    jq -n --arg risk HIGH '{risk_level:$risk, acceptance_criteria:[], prior_learnings:[]}' \
        > "$RALPH_DIR/brief.json"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

@test "coordinator_rpc.sh exports RALPH_COORDINATOR_INVOCATION=1 to claude (timeout=0 path)" {
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0
    run bash "$RPC_SCRIPT" consult "PLAN: refactor X"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/.spawn_env" ]
    run cat "$TEST_TEMP_DIR/.spawn_env"
    [[ "$output" == "RALPH_COORDINATOR_INVOCATION=1" ]]
}

@test "coordinator_rpc.sh exports RALPH_COORDINATOR_INVOCATION=1 to claude (timeout path)" {
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=30
    run bash "$RPC_SCRIPT" consult "PLAN: refactor X"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/.spawn_env" ]
    run cat "$TEST_TEMP_DIR/.spawn_env"
    [[ "$output" == "RALPH_COORDINATOR_INVOCATION=1" ]]
}

@test "coordinator_rpc.sh source has the TAP-1530 export ahead of the claude invocations" {
    # Static guard: the export must precede both the timeout==0 and the
    # `timeout "$_TIMEOUT"` claude calls so neither path can spawn claude
    # without the marker.
    local export_line zero_line timeout_line
    export_line=$(grep -n 'export RALPH_COORDINATOR_INVOCATION=1' "$RPC_SCRIPT" | head -1 | cut -d: -f1)
    zero_line=$(grep -n '"\$_TIMEOUT" == "0"' "$RPC_SCRIPT" | head -1 | cut -d: -f1)
    timeout_line=$(grep -n '^[[:space:]]*timeout "\$_TIMEOUT" "\$_CLAUDE_CMD"' "$RPC_SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$export_line" ]
    [ -n "$zero_line" ]
    [ -n "$timeout_line" ]
    [ "$export_line" -lt "$zero_line" ]
    [ "$export_line" -lt "$timeout_line" ]
}
