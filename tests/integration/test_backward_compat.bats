#!/usr/bin/env bats
# Integration tests for backward compatibility (GitHub Issue #41)
#
# Ensures Phase 1-4 enhancements don't break existing Ralph installations or
# upgrade paths. Unit-level CLI flag compatibility is already covered by
# test_cli_modern.bats / test_cli_parsing.bats; this file focuses on
# INTEGRATION-level concerns those unit tests don't catch:
#   - old flat-structure projects (pre-.ralph/ subfolder)
#   - .ralphrc files missing optional / Phase-3 fields
#   - missing optional state files (status.json, circuit breaker state)
#   - the bare CLI surface staying backward compatible
#
# Pattern note: most tests `source ralph_loop.sh` (the BASH_SOURCE guard keeps
# main() from running) and exercise individual functions, mirroring
# test_dry_run.bats / test_loop_execution.bats. The migration-message test runs
# the script as a subprocess because it asserts main()'s startup gate.

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
CB_LIB="${BATS_TEST_DIRNAME}/../../lib/circuit_breaker.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Clear any ambient config so sourcing ralph_loop.sh exercises the real
    # default-resolution logic instead of values inherited from the outer shell
    # (e.g. CLAUDE_EFFORT may be set by the surrounding environment).
    unset CLAUDE_EFFORT CLAUDE_MODEL CLAUDE_ALLOWED_TOOLS CLAUDE_OUTPUT_FORMAT \
          CLAUDE_USE_CONTINUE VERBOSE_PROGRESS MAX_CALLS_PER_HOUR MAX_TOKENS_PER_HOUR
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# Existing project compatibility (5 tests)
# =============================================================================

@test "old flat structure (root PROMPT.md, no .ralph/) reports migration message" {
    # Pre-v0.10 projects kept PROMPT.md at the project root. Running current ralph
    # there must surface clear migration guidance and exit non-zero WITHOUT silently
    # creating a .ralph/ directory (which would mask the old layout).
    echo "# Legacy prompt" > PROMPT.md

    run bash "$RALPH_SCRIPT"

    assert_failure
    [[ "$output" == *"old flat structure"* ]]
    [[ "$output" == *"ralph-migrate"* ]]

    # The migration gate must not have silently initialised the new structure.
    assert_file_not_exists ".ralph"

    # Regression guard: the migration exit path runs without $LOG_DIR, so
    # log_status must not leak a shell redirection error to stderr (Issue #41).
    local err
    # `|| true`: the script exits 1 (migration gate); we only care about stderr.
    err=$(bash "$RALPH_SCRIPT" 2>&1 >/dev/null) || true
    [[ "$err" != *"No such file or directory"* ]]
}

@test ".ralphrc missing optional fields still loads with safe defaults" {
    # A user-authored .ralphrc that only sets a couple of values must not break;
    # everything it omits falls back to the documented defaults.
    cat > .ralphrc <<'EOF'
MAX_CALLS_PER_HOUR=50
EOF

    source "$RALPH_SCRIPT"
    load_ralphrc

    # Explicitly-set field is honoured.
    assert_equal "$MAX_CALLS_PER_HOUR" "50"
    # Omitted fields fall back to defaults.
    assert_equal "$CLAUDE_OUTPUT_FORMAT" "json"
    assert_equal "$CLAUDE_USE_CONTINUE" "true"
    # Optional overrides remain empty (use CLI default) when not specified.
    assert_equal "$CLAUDE_MODEL" ""
    assert_equal "$CLAUDE_EFFORT" ""
    # The hardened tool allowlist must still be populated from defaults.
    [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]
    [[ "$CLAUDE_ALLOWED_TOOLS" == *"Bash(git commit *)"* ]]
}

@test "v0.9-style .ralphrc (legacy var names) loads without errors" {
    # v0.9 .ralphrc files predate Phase-3 fields and used the legacy ALLOWED_TOOLS
    # / RALPH_VERBOSE names. They must load cleanly and map to internal names.
    cat > .ralphrc <<'EOF'
MAX_CALLS_PER_HOUR=75
ALLOWED_TOOLS="Write,Read,Bash(git commit)"
RALPH_VERBOSE=true
EOF

    source "$RALPH_SCRIPT"
    load_ralphrc

    assert_equal "$MAX_CALLS_PER_HOUR" "75"
    # Legacy ALLOWED_TOOLS maps onto the internal CLAUDE_ALLOWED_TOOLS name.
    assert_equal "$CLAUDE_ALLOWED_TOOLS" "Write,Read,Bash(git commit)"
    # Legacy RALPH_VERBOSE maps onto VERBOSE_PROGRESS.
    assert_equal "$VERBOSE_PROGRESS" "true"
}

@test "loop still functions when status.json is absent" {
    # status.json is an optional output file; update_status must create it on demand.
    source "$RALPH_SCRIPT"
    export RALPH_DIR=".ralph"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
    mkdir -p "$RALPH_DIR"

    assert_file_not_exists "$STATUS_FILE"

    update_status 1 0 "executing" "running"

    assert_file_exists "$STATUS_FILE"
    assert_valid_json "$STATUS_FILE"
    assert_equal "$(get_json_field "$STATUS_FILE" 'loop_count')" "1"
    assert_equal "$(get_json_field "$STATUS_FILE" 'status')" "running"
}

@test "loop still functions when .circuit_breaker_state is absent" {
    # The circuit breaker state file is optional; init must create a CLOSED state.
    export RALPH_DIR=".ralph"
    export CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    mkdir -p "$RALPH_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "$CB_LIB"

    assert_file_not_exists "$CB_STATE_FILE"

    init_circuit_breaker

    assert_file_exists "$CB_STATE_FILE"
    assert_valid_json "$CB_STATE_FILE"
    assert_equal "$(get_json_field "$CB_STATE_FILE" 'state')" "CLOSED"
}

# =============================================================================
# CLI upgrade path (2 tests)
# =============================================================================

@test "bare ralph (no new flags) keeps pre-Phase-3 defaults" {
    # Sourcing with a clean environment must yield the long-standing defaults so
    # existing invocations behave identically after upgrading.
    source "$RALPH_SCRIPT"

    assert_equal "$MAX_CALLS_PER_HOUR" "100"
    assert_equal "$PROMPT_FILE" ".ralph/PROMPT.md"
    assert_equal "$SLEEP_DURATION" "3600"

    # Legacy flags remain documented in --help.
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--calls"* ]]
    [[ "$output" == *"--prompt"* ]]
    [[ "$output" == *"--status"* ]]
}

@test "old-style prompt file path via --prompt / -p is still accepted" {
    # Pre-Phase-3 users passed a custom prompt path. Both the long and short flags
    # must still parse alongside other options without error.
    run bash "$RALPH_SCRIPT" --prompt custom_prompt.md --help
    assert_success
    [[ "$output" == *"Usage:"* ]]

    run bash "$RALPH_SCRIPT" -p custom_prompt.md --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}
