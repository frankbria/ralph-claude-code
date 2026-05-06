#!/usr/bin/env bats
# TAP-923: dynamic QA / BLOCK injection from coordinator consult responses.
#
# Verifies (a) brief_patch_field does atomic single-field updates that keep
# brief.json schema-valid, and (b) coordinator_rpc.sh applies elevated_qa
# patches and the BLOCK side-channel flag.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."
BRIEF_LIB="${REPO_ROOT_FIXED}/lib/brief.sh"
RPC_SCRIPT="${REPO_ROOT_FIXED}/lib/coordinator_rpc.sh"

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_inject.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph bin
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0

    # shellcheck disable=SC1090
    source "$BRIEF_LIB"

    # Mock claude — emits the verdict from FAKE_VERDICT (must be set per test).
    # Avoid bash ${VAR:-DEFAULT} fallback here: nested braces in the JSON
    # default close the parameter expansion early and corrupt the line.
    cat > "$TEST_TEMP_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"mock-sid-923"}'
verdict="$FAKE_VERDICT"
result_json=$(printf '%s' "$verdict" | jq -Rs .)
printf '{"type":"result","result":%s,"session_id":"mock-sid-923"}\n' "$result_json"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"
    # Default verdict for tests that don't set their own.
    export FAKE_VERDICT='{"verdict":"APPROVE","reason":"ok","alternative":null,"elevated_qa":false}'
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

_write_brief() {
    local risk="${1:-HIGH}"
    local qa="${2:-false}"
    jq -n --arg risk "$risk" --argjson qa "$qa" '{
        schema_version: 1,
        task_id: "TAP-923",
        task_source: "linear",
        task_summary: "test injection",
        risk_level: $risk,
        affected_modules: ["lib/brief.sh"],
        acceptance_criteria: ["patch works", "block flag works"],
        prior_learnings: [],
        qa_required: $qa,
        delegate_to: "ralph",
        coordinator_confidence: 0.8,
        created_at: "2026-05-06T00:00:00Z"
    }' > "$RALPH_DIR/brief.json"
}

# --- brief_patch_field ------------------------------------------------------

@test "TAP-923: brief_patch_field exported by lib/brief.sh" {
    type brief_patch_field
}

@test "TAP-923: brief_patch_field flips qa_required false → true" {
    _write_brief HIGH false
    run brief_patch_field qa_required true
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ "$(jq -r '.qa_required' "$RALPH_DIR/brief.json")" == "true" ]]
}

@test "TAP-923: brief_patch_field preserves schema validity" {
    _write_brief HIGH false
    brief_patch_field qa_required true
    run brief_validate "$RALPH_DIR/brief.json"
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "TAP-923: brief_patch_field accepts numeric values via argjson" {
    _write_brief HIGH false
    run brief_patch_field coordinator_confidence 0.42
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ "$(jq -r '.coordinator_confidence' "$RALPH_DIR/brief.json")" == "0.42" ]]
}

@test "TAP-923: brief_patch_field stores non-bool/non-numeric as string" {
    _write_brief HIGH false
    run brief_patch_field qa_scope tests/unit/test_x.bats
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ "$(jq -r '.qa_scope' "$RALPH_DIR/brief.json")" == "tests/unit/test_x.bats" ]]
}

@test "TAP-923: brief_patch_field fails when brief missing" {
    run brief_patch_field qa_required true
    [[ "$status" -ne 0 ]] || fail "expected non-zero exit when brief missing"
}

@test "TAP-923: brief_patch_field rejects empty field name" {
    _write_brief HIGH false
    run brief_patch_field "" true
    [[ "$status" -eq 2 ]] || fail "expected exit 2 for empty field, got $status"
}

@test "TAP-923: brief_patch_field is atomic (no .tmp.* files left after success)" {
    _write_brief HIGH false
    brief_patch_field qa_required true
    local stragglers
    stragglers=$(find "$RALPH_DIR" -maxdepth 1 -name 'brief.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$stragglers" -eq 0 ]] || fail "found $stragglers leftover tmp files"
}

# --- coordinator_rpc.sh patch application -----------------------------------

@test "TAP-923: elevated_qa=true response patches brief.qa_required to true" {
    _write_brief HIGH false
    export FAKE_VERDICT='{"verdict":"RECONSIDER","reason":"risky","alternative":"split it","elevated_qa":true}'
    run bash "$RPC_SCRIPT" consult "PLAN: refactor everything"
    [[ "$status" -eq 0 ]] || { echo "rpc output: $output"; false; }
    [[ "$(jq -r '.qa_required' "$RALPH_DIR/brief.json")" == "true" ]] \
        || fail "qa_required not patched: $(cat "$RALPH_DIR/brief.json")"
}

@test "TAP-923: elevated_qa=false leaves brief.qa_required unchanged" {
    _write_brief HIGH false
    export FAKE_VERDICT='{"verdict":"APPROVE","reason":"ok","alternative":null,"elevated_qa":false}'
    run bash "$RPC_SCRIPT" consult "PLAN: small fix"
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ "$(jq -r '.qa_required' "$RALPH_DIR/brief.json")" == "false" ]]
}

@test "TAP-923: verdict=BLOCK creates .coordinator_block flag" {
    _write_brief HIGH false
    export FAKE_VERDICT='{"verdict":"BLOCK","reason":"violates AC","alternative":"redesign","elevated_qa":false}'
    run bash "$RPC_SCRIPT" consult "PLAN: dangerous"
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ -f "$RALPH_DIR/.coordinator_block" ]] || fail ".coordinator_block flag not created"
}

@test "TAP-923: verdict=APPROVE does not create .coordinator_block flag" {
    _write_brief HIGH false
    export FAKE_VERDICT='{"verdict":"APPROVE","reason":"fine","alternative":null,"elevated_qa":false}'
    run bash "$RPC_SCRIPT" consult "PLAN: safe"
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    [[ ! -f "$RALPH_DIR/.coordinator_block" ]] || fail ".coordinator_block created on APPROVE"
}

@test "TAP-923: BLOCK verdict still printed to stdout for the caller" {
    _write_brief HIGH false
    export FAKE_VERDICT='{"verdict":"BLOCK","reason":"nope","alternative":"different","elevated_qa":false}'
    run bash "$RPC_SCRIPT" consult "PLAN: dangerous"
    [[ "$status" -eq 0 ]] || { echo "$output"; false; }
    echo "$output" | grep -q '"verdict":"BLOCK"' || fail "verdict line not on stdout"
}
