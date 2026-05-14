#!/usr/bin/env bats
# TAP-1685 — prompt-cache hit-rate panel in ralph-monitor.
#
# Strategy: source ralph_monitor.sh in a sandboxed mode that suppresses
# `main` (which is an infinite loop), then invoke `display_status` with a
# controlled `.ralph/status.json` and grep the dashboard output for the
# panel and the WARN line.
#
# `main` is the last line of the script; we set a sentinel variable that
# the script doesn't otherwise check, then carve the function out via awk
# so the script body never runs `main`. This is more robust than sourcing
# the whole file and relying on `main` being guarded by a `[[ -n
# $BASH_SOURCE ]]` check (which it isn't).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
MONITOR="${REPO_ROOT}/ralph_monitor.sh"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    # Strip terminal-color codes; tests grep on plain text so the panel
    # box characters and labels match regardless of TTY support.
    export NO_COLOR=1
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Render the dashboard once and return stdout. We pull display_status +
# its global colour vars + helper functions out of the monitor script so
# the infinite main loop never starts.
_render() {
    # Source everything UP TO the `# Main monitor loop` comment so
    # display_status, the colour vars, and the helpers are all defined,
    # but `main` and `main()` are not.
    local snippet
    snippet=$(awk '/^# Main monitor loop$/ { exit } { print }' "$MONITOR")
    # Drop the ANSI colour escapes — the grep assertions match on plain text.
    snippet=$(printf '%s\n' "$snippet" | sed -E "s/\\\\033\\[[0-9;]*m//g")
    eval "$snippet"
    display_status
}

_write_status() {
    cat > .ralph/status.json
}

# =============================================================================
# Cold-cache loop: no cache reads, non-trivial cache creates → 0% (NOT NaN)
# =============================================================================

@test "TAP-1685: cold-start loop renders 0% (not NaN) for loop hit rate" {
    _write_status <<'JSON'
{
  "loop_count": 1,
  "status": "RUNNING",
  "loop_cache_read_tokens": 0,
  "loop_cache_create_tokens": 8000,
  "loop_input_tokens": 200,
  "session_cache_read_tokens": 0,
  "session_cache_create_tokens": 8000,
  "session_input_tokens": 200,
  "session_cost_usd": 0.05,
  "loop_cost_usd": 0.05,
  "session_output_tokens": 100,
  "loop_output_tokens": 100
}
JSON
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Prompt cache (TAP-1685)"* ]]
    [[ "$output" == *"Loop:"*"0% hit"* ]]
    [[ "$output" == *"Session:"*"0% hit"* ]]
    # Cold session at 0% < 30% threshold → WARN line fires.
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"investigate prompt-prefix instability"* ]]
}

# =============================================================================
# Warm-cache loop: high cache_read → >=90%
# =============================================================================

@test "TAP-1685: warm-cache loop renders >=90% with no WARN" {
    _write_status <<'JSON'
{
  "loop_count": 12,
  "status": "RUNNING",
  "loop_cache_read_tokens": 90000,
  "loop_cache_create_tokens": 500,
  "loop_input_tokens": 100,
  "session_cache_read_tokens": 950000,
  "session_cache_create_tokens": 8000,
  "session_input_tokens": 1500,
  "session_cost_usd": 0.40,
  "loop_cost_usd": 0.02,
  "session_output_tokens": 5000,
  "loop_output_tokens": 100
}
JSON
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Prompt cache (TAP-1685)"* ]]
    # Loop: 90000 / (90000 + 500 + 100) = 99.something → 99%
    [[ "$output" == *"Loop:"*"99% hit"* ]]
    # Session: 950000 / (950000+8000+1500) = ~99% → 99%
    [[ "$output" == *"Session:"*"99% hit"* ]]
    [[ "$output" != *"WARN"* ]]
}

# =============================================================================
# Missing fields default to 0 (hook write already guards this; monitor
# defends-in-depth via // 0 + numeric clamp).
# =============================================================================

@test "TAP-1685: missing loop_cache_* fields default to 0, no NaN" {
    _write_status <<'JSON'
{
  "loop_count": 5,
  "status": "RUNNING",
  "loop_input_tokens": 100,
  "session_cache_read_tokens": 50000,
  "session_cache_create_tokens": 1000,
  "session_input_tokens": 200,
  "session_cost_usd": 0.10,
  "loop_cost_usd": 0.01,
  "session_output_tokens": 2000,
  "loop_output_tokens": 50
}
JSON
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Prompt cache (TAP-1685)"* ]]
    [[ "$output" != *"nan"* ]]
    [[ "$output" != *"NaN"* ]]
    # Loop is uncached input only: 0 / (0 + 0 + 100) = 0%
    [[ "$output" == *"Loop:"*"0% hit"* ]]
    # Session ~98% → no WARN
    [[ "$output" != *"WARN"* ]]
}

@test "TAP-1685: missing session_cache_* AND loop_cache_* shows 'no data yet' rather than empty panel" {
    _write_status <<'JSON'
{
  "loop_count": 0,
  "status": "RUNNING",
  "loop_input_tokens": 0,
  "session_input_tokens": 0,
  "session_cost_usd": 0,
  "loop_cost_usd": 0,
  "session_output_tokens": 0,
  "loop_output_tokens": 0
}
JSON
    run _render
    [[ "$status" -eq 0 ]]
    # Panel suppressed when both loop AND session have no data.
    [[ "$output" != *"Prompt cache (TAP-1685)"* ]]
}

# =============================================================================
# Threshold WARN
# =============================================================================

@test "TAP-1685: session hit rate below RALPH_CACHE_HIT_RATE_WARN triggers WARN" {
    # Session hit rate = 50000 / (50000 + 30000 + 30000) = 45.5% → 45%
    # Default threshold 30 → no warn. Override to 50 to force warn.
    _write_status <<'JSON'
{
  "loop_count": 3,
  "status": "RUNNING",
  "loop_cache_read_tokens": 1000,
  "loop_cache_create_tokens": 1000,
  "loop_input_tokens": 1000,
  "session_cache_read_tokens": 50000,
  "session_cache_create_tokens": 30000,
  "session_input_tokens": 30000,
  "session_cost_usd": 0.15,
  "loop_cost_usd": 0.05,
  "session_output_tokens": 5000,
  "loop_output_tokens": 100
}
JSON
    export RALPH_CACHE_HIT_RATE_WARN=50
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"investigate prompt-prefix instability"* ]]
}

@test "TAP-1685: session hit rate at or above threshold does NOT trigger WARN" {
    # Same session 45% as above, but default threshold 30.
    _write_status <<'JSON'
{
  "loop_count": 3,
  "status": "RUNNING",
  "loop_cache_read_tokens": 1000,
  "loop_cache_create_tokens": 1000,
  "loop_input_tokens": 1000,
  "session_cache_read_tokens": 50000,
  "session_cache_create_tokens": 30000,
  "session_input_tokens": 30000,
  "session_cost_usd": 0.15,
  "loop_cost_usd": 0.05,
  "session_output_tokens": 5000,
  "loop_output_tokens": 100
}
JSON
    unset RALPH_CACHE_HIT_RATE_WARN
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Prompt cache (TAP-1685)"* ]]
    [[ "$output" != *"WARN"* ]]
}

@test "TAP-1685: panel reports loop tokens (read, create, input) for diagnosability" {
    _write_status <<'JSON'
{
  "loop_count": 4,
  "status": "RUNNING",
  "loop_cache_read_tokens": 1234,
  "loop_cache_create_tokens": 56,
  "loop_input_tokens": 78,
  "session_cache_read_tokens": 100000,
  "session_cache_create_tokens": 1000,
  "session_input_tokens": 1000,
  "session_cost_usd": 0.20,
  "loop_cost_usd": 0.02,
  "session_output_tokens": 2000,
  "loop_output_tokens": 50
}
JSON
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"read=1234"* ]]
    [[ "$output" == *"create=56"* ]]
    [[ "$output" == *"in=78"* ]]
}
