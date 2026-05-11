#!/usr/bin/env bats
# TAP-918: shell-hook brain writes are demoted to fallback once the
# coordinator owns the primary path. Verifies:
#   * brain.jsonl rows carry a `source` field (hook | coordinator-fallback)
#   * pre-this-story rows without `source` parse as `hook` (back-compat)
#   * on-stop.sh skips the brain write when brief.json exists AND
#     coordinator is not disabled (coordinator's debrief will own it)
#   * on-stop.sh falls back to direct write when coordinator is disabled
#     OR brief.json is missing
#   * `ralph_show_brain_stats` splits the display by source

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."
HOOK_TEMPLATE="${REPO_ROOT_FIXED}/templates/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/brain_fallback.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/metrics
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    # Force brain enabled — write functions short-circuit otherwise.
    export TAPPS_BRAIN_ENABLED=true
    export TAPPS_BRAIN_AUTH_TOKEN=test-token
    export TAPPS_BRAIN_URL=http://localhost:65535   # unreachable on purpose
    # on-stop.sh guards against interactive Stop events; tests simulate a
    # ralph_loop.sh invocation.
    export RALPH_LOOP_ACTIVE=1
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# -- brain_client.sh: source field on metrics --------------------------------

@test "TAP-918: brain_client_record_metric writes source field by default 'hook'" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/brain_client.sh"
    brain_client_record_metric "$RALPH_DIR" "success" "200" "42" ""
    [[ -s "$RALPH_DIR/metrics/brain.jsonl" ]] || fail "metric not written"
    local src
    src=$(jq -r '.source' "$RALPH_DIR/metrics/brain.jsonl")
    [[ "$src" == "hook" ]] || fail "expected default source=hook, got: $src"
}

@test "TAP-918: brain_client_record_metric accepts an explicit source" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/brain_client.sh"
    brain_client_record_metric "$RALPH_DIR" "success" "200" "42" "" "coordinator-fallback"
    local src
    src=$(jq -r '.source' "$RALPH_DIR/metrics/brain.jsonl")
    [[ "$src" == "coordinator-fallback" ]] \
        || fail "expected source=coordinator-fallback, got: $src"
}

# -- on-stop.sh: skip path when coordinator owns the write -------------------

# Helper: invoke the brain section of on-stop.sh with controlled inputs.
# We extract the brain-write block and run it in a clean shell with mocked
# brain_client_write_* so we can assert on the calls made.
_run_brain_block() {
    local files_modified="$1"
    local tasks_done="$2"
    local has_pd="$3"
    local cb_state="$4"
    local coord_disabled="$5"
    local brief_present="$6"
    local pd_count="${7:-0}"
    local recommendation="${8:-}"
    local linear_issue="${9:-}"
    local loop_count="${10:-1}"

    if [[ "$brief_present" == "true" ]]; then
        echo '{"task_id":"TAP-918"}' > "$RALPH_DIR/brief.json"
    else
        rm -f "$RALPH_DIR/brief.json"
    fi
    if [[ -n "$cb_state" ]]; then
        echo "{\"state\":\"$cb_state\"}" > "$RALPH_DIR/.circuit_breaker_state"
    else
        rm -f "$RALPH_DIR/.circuit_breaker_state"
    fi

    : > "$RALPH_DIR/.brain_calls"

    bash <<EOF
set -e
export RALPH_DIR='$RALPH_DIR'
export RALPH_COORDINATOR_DISABLED=$coord_disabled
files_modified=$files_modified
tasks_done=$tasks_done
has_permission_denials=$has_pd
permission_denial_count=$pd_count
recommendation='$recommendation'
linear_issue='$linear_issue'
loop_count=$loop_count

# Mock brain_client_* functions to record their calls.
brain_client_write_success() {
    echo "success|src=\$4|desc=\$2" >> '$RALPH_DIR/.brain_calls'
}
brain_client_write_failure() {
    echo "failure|src=\$5|desc=\$2|err=\$3" >> '$RALPH_DIR/.brain_calls'
}

# Mark the brain library as loaded so the block runs.
_brain_lib=mocked

# Inline the brain-write logic from templates/hooks/on-stop.sh (kept in
# sync — see byte-identical drift test for the on-stop.sh template).
if [[ -n "\$_brain_lib" ]]; then
  _brain_skip_hook="false"
  if [[ -f "\$RALPH_DIR/brief.json" ]] && [[ "\${RALPH_COORDINATOR_DISABLED:-false}" != "true" ]]; then
    _brain_skip_hook="true"
  fi

  if [[ "\$_brain_skip_hook" != "true" && "\$files_modified" -gt 0 && "\$tasks_done" -gt 0 ]]; then
    _brain_desc="Loop \$loop_count completed \$tasks_done task(s)"
    brain_client_write_success "\$RALPH_DIR" "\$_brain_desc" "\$linear_issue" "coordinator-fallback"
  fi

  _cb_now="CLOSED"
  if [[ -f "\$RALPH_DIR/.circuit_breaker_state" ]]; then
    _cb_now=\$(jq -r '.state // "CLOSED"' "\$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
  fi
  if [[ "\$_brain_skip_hook" != "true" && ( "\$has_permission_denials" == "true" || "\$_cb_now" == "OPEN" ) ]]; then
    _brain_desc="Loop \$loop_count stalled"
    brain_client_write_failure "\$RALPH_DIR" "\$_brain_desc" "permission_denial" "\$linear_issue" "coordinator-fallback"
  fi
fi
EOF
}

@test "TAP-918: hook write SKIPPED when brief.json exists and coordinator enabled" {
    _run_brain_block 3 1 "false" "" "false" "true" 0 "" "TAP-918"
    [[ ! -s "$RALPH_DIR/.brain_calls" ]] \
        || fail "hook should NOT call brain when coordinator owns the write, got: $(cat "$RALPH_DIR/.brain_calls")"
}

@test "TAP-918: hook FALLBACK fires when brief.json missing (coordinator failed/skipped)" {
    _run_brain_block 3 1 "false" "" "false" "false" 0 "" "TAP-918"
    grep -q "success|src=coordinator-fallback" "$RALPH_DIR/.brain_calls" \
        || fail "expected fallback call with src=coordinator-fallback, got: $(cat "$RALPH_DIR/.brain_calls")"
}

@test "TAP-918: hook FALLBACK fires when coordinator explicitly disabled (even with brief)" {
    _run_brain_block 3 1 "false" "" "true" "true" 0 "" "TAP-918"
    grep -q "success|src=coordinator-fallback" "$RALPH_DIR/.brain_calls" \
        || fail "expected fallback when coordinator disabled, got: $(cat "$RALPH_DIR/.brain_calls")"
}

@test "TAP-918: failure-path fallback also fires (perm denial, no brief)" {
    _run_brain_block 0 0 "true" "" "false" "false" 2
    grep -q "failure|src=coordinator-fallback" "$RALPH_DIR/.brain_calls" \
        || fail "expected failure call with src=coordinator-fallback, got: $(cat "$RALPH_DIR/.brain_calls")"
}

# -- ralph_show_brain_stats: split-by-source display -------------------------

@test "TAP-918: ralph_show_brain_stats splits coordinator-fallback vs hook (legacy)" {
    # Pre-this-story row (no source field) — must bucket as 'hook'.
    echo '{"timestamp":"t1","op":"success","http_code":"200","latency_ms":10,"reason":"","ok":true}' \
        > "$RALPH_DIR/metrics/brain.jsonl"
    # New rows with explicit sources.
    echo '{"timestamp":"t2","op":"success","http_code":"200","latency_ms":20,"reason":"","ok":true,"source":"coordinator-fallback"}' \
        >> "$RALPH_DIR/metrics/brain.jsonl"
    echo '{"timestamp":"t3","op":"failure","http_code":"200","latency_ms":15,"reason":"","ok":true,"source":"coordinator-fallback"}' \
        >> "$RALPH_DIR/metrics/brain.jsonl"
    echo '{"timestamp":"t4","op":"success","http_code":"200","latency_ms":18,"reason":"","ok":true,"source":"coordinator"}' \
        >> "$RALPH_DIR/metrics/brain.jsonl"

    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/metrics.sh"
    run ralph_show_brain_stats human
    [[ "$status" -eq 0 ]] || fail "ralph_show_brain_stats exited non-zero"
    [[ "$output" == *"Coordinator (primary):  1 success / 0 failure"* ]] \
        || fail "expected coordinator line, got: $output"
    [[ "$output" == *"Hook fallback:          1 success / 1 failure"* ]] \
        || fail "expected hook fallback line, got: $output"
    [[ "$output" == *"Hook (legacy):          1 success / 0 failure"* ]] \
        || fail "expected legacy hook line for missing-source row, got: $output"
}

@test "TAP-918: ralph_show_brain_stats backward-compat: rows missing source bucket as hook" {
    # Only legacy rows.
    echo '{"timestamp":"t1","op":"success","http_code":"200","latency_ms":10,"reason":"","ok":true}' \
        > "$RALPH_DIR/metrics/brain.jsonl"
    echo '{"timestamp":"t2","op":"failure","http_code":"500","latency_ms":12,"reason":"","ok":false}' \
        >> "$RALPH_DIR/metrics/brain.jsonl"

    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/metrics.sh"
    run ralph_show_brain_stats human
    [[ "$status" -eq 0 ]] || fail "ralph_show_brain_stats exited non-zero"
    [[ "$output" == *"Hook (legacy):          1 success / 1 failure"* ]] \
        || fail "expected all-legacy bucket, got: $output"
    # Coordinator and fallback lines must NOT appear when their counts are 0.
    [[ "$output" != *"Coordinator (primary):"* ]] \
        || fail "should not show coordinator line with zero count"
    [[ "$output" != *"Hook fallback:"* ]] \
        || fail "should not show hook fallback line with zero count"
}

# -- template hook: assertions on the on-stop.sh source ---------------------

@test "TAP-918: templates/hooks/on-stop.sh has the brief.json skip guard" {
    grep -q '_brain_skip_hook' "$HOOK_TEMPLATE" \
        || fail "on-stop.sh template missing _brain_skip_hook guard"
    grep -q 'brief\.json' "$HOOK_TEMPLATE" \
        || fail "on-stop.sh template must check brief.json presence"
}

@test "TAP-918: templates/hooks/on-stop.sh tags fallback writes with coordinator-fallback" {
    grep -q '"coordinator-fallback"' "$HOOK_TEMPLATE" \
        || fail "on-stop.sh template must mark fallback writes with coordinator-fallback"
}
