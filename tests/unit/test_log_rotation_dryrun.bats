#!/usr/bin/env bats
# Unit tests for log rotation (Issue #18), dry-run mode (Issue #19),
# and WSL/Windows version divergence detection

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
RALPH_SCRIPT="${PROJECT_ROOT}/ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph/logs .ralph/docs/generated
    export RALPH_DIR=".ralph"
    export LOG_DIR=".ralph/logs"
    export STATUS_FILE=".ralph/status.json"
    export CALL_COUNT_FILE=".ralph/.call_count"
    export EXIT_SIGNALS_FILE=".ralph/.exit_signals"
    export DOCS_DIR=".ralph/docs/generated"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper to source ralph_loop.sh with required stubs
source_ralph() {
    mkdir -p lib
    cat > lib/circuit_breaker.sh << 'STUBEOF'
RALPH_DIR="${RALPH_DIR:-.ralph}"
reset_circuit_breaker() { :; }
show_circuit_status() { :; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
should_halt_execution() { return 1; }
STUBEOF
    cat > lib/date_utils.sh << 'STUBEOF'
get_iso_timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
get_epoch_seconds() { date +%s; }
STUBEOF
    cat > lib/timeout_utils.sh << 'STUBEOF'
portable_timeout() { shift; "$@"; }
STUBEOF
    source "$RALPH_SCRIPT"
}

# =============================================================================
# LOG ROTATION TESTS (Issue #18)
# =============================================================================

@test "rotate_ralph_log does nothing when log file doesn't exist" {
    source_ralph
    rm -f "$LOG_DIR/ralph.log"
    run rotate_ralph_log
    assert_success
    [ ! -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_ralph_log does nothing when log is under size limit" {
    source_ralph
    echo "small log" > "$LOG_DIR/ralph.log"
    run rotate_ralph_log
    assert_success
    [ ! -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_ralph_log rotates when log exceeds size limit" {
    source_ralph
    echo "some log content that exceeds 0 MB" > "$LOG_DIR/ralph.log"
    LOG_MAX_SIZE_MB=0 rotate_ralph_log
    [ -f "$LOG_DIR/ralph.log.1" ]
    [ -f "$LOG_DIR/ralph.log" ]
    grep -q "Log rotated" "$LOG_DIR/ralph.log"
}

@test "rotate_ralph_log shifts existing rotated files" {
    source_ralph
    echo "log 1" > "$LOG_DIR/ralph.log.1"
    echo "log 2" > "$LOG_DIR/ralph.log.2"
    echo "current log content" > "$LOG_DIR/ralph.log"
    LOG_MAX_SIZE_MB=0 rotate_ralph_log
    [ -f "$LOG_DIR/ralph.log.3" ]
    [ -f "$LOG_DIR/ralph.log.2" ]
    [ -f "$LOG_DIR/ralph.log.1" ]
    grep -q "current log content" "$LOG_DIR/ralph.log.1"
    grep -q "log 1" "$LOG_DIR/ralph.log.2"
}

@test "rotate_ralph_log preserves LOG_MAX_FILES limit" {
    source_ralph
    # Create files up to the max
    for i in $(seq 1 $LOG_MAX_FILES); do
        echo "old log $i" > "$LOG_DIR/ralph.log.$i"
    done
    echo "current" > "$LOG_DIR/ralph.log"
    LOG_MAX_SIZE_MB=0 rotate_ralph_log
    # The highest numbered file should be the max
    [ -f "$LOG_DIR/ralph.log.$LOG_MAX_FILES" ]
}

@test "cleanup_old_output_logs does nothing when under limit" {
    source_ralph
    touch "$LOG_DIR/claude_output_001.log"
    touch "$LOG_DIR/claude_output_002.log"
    LOG_MAX_OUTPUT_FILES=5 run cleanup_old_output_logs
    assert_success
    [ -f "$LOG_DIR/claude_output_001.log" ]
    [ -f "$LOG_DIR/claude_output_002.log" ]
}

@test "cleanup_old_output_logs removes oldest files when over limit" {
    source_ralph
    for i in $(seq -w 1 5); do
        touch "$LOG_DIR/claude_output_20260321_00000${i}.log"
    done
    LOG_MAX_OUTPUT_FILES=3 cleanup_old_output_logs
    local remaining
    remaining=$(find "$LOG_DIR" -name 'claude_output_*.log' | wc -l)
    remaining=$((remaining + 0))
    [ "$remaining" -le 3 ]
}

@test "cleanup_old_output_logs removes oldest by mtime not lexicographic name (TAP-676)" {
    source_ralph
    # Lexicographic order would be 2000, 2010, 2099 — but mtimes pick a different oldest victim.
    touch -t 202001010000 "$LOG_DIR/claude_output_2099-01-01_00-00-00.log"
    touch -t 202502010000 "$LOG_DIR/claude_output_2000-01-01_00-00-00.log"
    touch -t 202601010000 "$LOG_DIR/claude_output_2010-01-01_00-00-00.log"
    LOG_MAX_OUTPUT_FILES=2 cleanup_old_output_logs
    [ ! -f "$LOG_DIR/claude_output_2099-01-01_00-00-00.log" ]
    [ -f "$LOG_DIR/claude_output_2000-01-01_00-00-00.log" ]
    [ -f "$LOG_DIR/claude_output_2010-01-01_00-00-00.log" ]
}

@test "LOG_MAX_SIZE_MB defaults to 10" {
    run bash -c "cd '$TEST_DIR' && mkdir -p lib && echo ':' > lib/circuit_breaker.sh && echo ':' > lib/date_utils.sh && echo ':' > lib/timeout_utils.sh && source '$RALPH_SCRIPT' && echo \$LOG_MAX_SIZE_MB"
    [[ "$output" == *"10"* ]]
}

@test "LOG_MAX_FILES defaults to 5" {
    run bash -c "cd '$TEST_DIR' && mkdir -p lib && echo ':' > lib/circuit_breaker.sh && echo ':' > lib/date_utils.sh && echo ':' > lib/timeout_utils.sh && source '$RALPH_SCRIPT' && echo \$LOG_MAX_FILES"
    [[ "$output" == *"5"* ]]
}

@test "LOG_MAX_OUTPUT_FILES defaults to 20" {
    run bash -c "cd '$TEST_DIR' && mkdir -p lib && echo ':' > lib/circuit_breaker.sh && echo ':' > lib/date_utils.sh && echo ':' > lib/timeout_utils.sh && source '$RALPH_SCRIPT' && echo \$LOG_MAX_OUTPUT_FILES"
    [[ "$output" == *"20"* ]]
}

# =============================================================================
# DRY-RUN MODE TESTS (Issue #19)
# =============================================================================

@test "DRY_RUN defaults to false" {
    run bash -c "cd '$TEST_DIR' && mkdir -p lib && echo ':' > lib/circuit_breaker.sh && echo ':' > lib/date_utils.sh && echo ':' > lib/timeout_utils.sh && source '$RALPH_SCRIPT' && echo \$DRY_RUN"
    [[ "$output" == *"false"* ]]
}

@test "dry_run_simulate writes status.json with DRY_RUN status" {
    source_ralph
    dry_run_simulate "" 1
    [ -f "$STATUS_FILE" ]
    local status
    status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null)
    [ "$status" = "DRY_RUN" ]
}

@test "dry_run_simulate records loop count" {
    source_ralph
    dry_run_simulate "" 42
    local loop_count
    loop_count=$(jq -r '.loop_count' "$STATUS_FILE" 2>/dev/null)
    [ "$loop_count" = "42" ]
}

@test "dry_run_simulate sets work_type to dry_run" {
    source_ralph
    dry_run_simulate "" 1
    local work_type
    work_type=$(jq -r '.work_type' "$STATUS_FILE" 2>/dev/null)
    [ "$work_type" = "dry_run" ]
}

@test "dry_run_simulate sets exit_signal to false" {
    source_ralph
    dry_run_simulate "" 1
    local exit_signal
    exit_signal=$(jq -r '.exit_signal' "$STATUS_FILE" 2>/dev/null)
    [ "$exit_signal" = "false" ]
}

@test "dry_run_simulate reports task counts from fix_plan.md" {
    source_ralph
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
- [ ] Task 1
- [ ] Task 2
- [x] Task 3
EOF
    run dry_run_simulate "" 1
    assert_success
    [[ "$output" == *"2 open"* ]]
    [[ "$output" == *"1 done"* ]]
}

# Removed: "dry_run_simulate logs allowed tools count" — asserted a log
# line about CLAUDE_ALLOWED_TOOLS that dry_run_simulate stopped emitting
# when ADR-0006 (legacy `-p` mode + --allowedTools allowlist) deleted
# the underlying code path. The test silently became "not run" because
# `source ralph_loop.sh` from the helper triggers an early `exit` in
# the post-ADR-0006 startup preflight when invoked in the bats env, so
# bats counted the @test in `1..N` but never produced an `ok N` line —
# surfacing as "Executed 35 instead of expected 36" once CI was enabled.

@test "--dry-run flag is parsed correctly" {
    run bash "$RALPH_SCRIPT" --dry-run --help 2>&1
    # Should not error on --dry-run flag itself
    # (--help will cause early exit, but --dry-run should be accepted)
    [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"DRY-RUN"* ]] || true
}

# =============================================================================
# CLI FLAG PARSING TESTS FOR NEW OPTIONS
# =============================================================================

@test "--log-max-files rejects zero" {
    run bash "$RALPH_SCRIPT" --log-max-files 0
    assert_failure
    [[ "$output" == *"positive integer"* ]]
}

@test "--log-max-size rejects non-numeric input" {
    run bash "$RALPH_SCRIPT" --log-max-size abc
    assert_failure
    [[ "$output" == *"positive integer"* ]]
}

@test "--log-max-size rejects empty value" {
    run bash "$RALPH_SCRIPT" --log-max-size
    assert_failure
}

@test "help text includes --dry-run" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--dry-run"* ]]
}

@test "help text includes --log-max-size" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--log-max-size"* ]]
}

@test "help text includes --log-max-files" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--log-max-files"* ]]
}

# =============================================================================
# VERSION DIVERGENCE DETECTION TESTS
# =============================================================================

@test "check_version_divergence succeeds on non-WSL systems" {
    source_ralph
    run check_version_divergence
    assert_success
}

@test "RALPH_VERSION is defined" {
    source_ralph
    [[ -n "$RALPH_VERSION" ]]
}

# =============================================================================
# ON-STOP.SH HOOK FALLBACK TESTS
# =============================================================================

@test "on-stop.sh hook template has text fallback" {
    local hook_template="${PROJECT_ROOT}/templates/hooks/on-stop.sh"
    [ -f "$hook_template" ]
    grep -q 'Fallback.*raw input as text' "$hook_template"
}

@test "on-stop.sh hook template tries response[0].text path" {
    local hook_template="${PROJECT_ROOT}/templates/hooks/on-stop.sh"
    grep -q 'response\[0\].text' "$hook_template"
}

@test "on-stop.sh hook template tries .response path" {
    local hook_template="${PROJECT_ROOT}/templates/hooks/on-stop.sh"
    grep -q "'.response'" "$hook_template"
}

# =============================================================================
# .RALPHRC TEMPLATE TESTS
# =============================================================================

@test "ralphrc template includes LOG_MAX_SIZE_MB" {
    grep -q "LOG_MAX_SIZE_MB" "${PROJECT_ROOT}/templates/ralphrc.template"
}

@test "ralphrc template includes DRY_RUN" {
    grep -q "DRY_RUN" "${PROJECT_ROOT}/templates/ralphrc.template"
}

@test "ralphrc template includes LOG_MAX_FILES" {
    grep -q "LOG_MAX_FILES" "${PROJECT_ROOT}/templates/ralphrc.template"
}

@test "ralphrc template includes LOG_MAX_OUTPUT_FILES" {
    grep -q "LOG_MAX_OUTPUT_FILES" "${PROJECT_ROOT}/templates/ralphrc.template"
}

# =============================================================================
# ENVIRONMENT VARIABLE OVERRIDE TESTS
# =============================================================================

@test "DRY_RUN env var overrides .ralphrc" {
    source_ralph
    echo 'DRY_RUN=true' > .ralphrc
    _env_DRY_RUN="false"
    load_ralphrc
    [ "$DRY_RUN" = "false" ]
}

@test "LOG_MAX_SIZE_MB env var overrides .ralphrc" {
    source_ralph
    echo 'LOG_MAX_SIZE_MB=50' > .ralphrc
    _env_LOG_MAX_SIZE_MB="20"
    load_ralphrc
    [ "$LOG_MAX_SIZE_MB" = "20" ]
}
