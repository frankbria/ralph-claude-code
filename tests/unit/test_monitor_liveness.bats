#!/usr/bin/env bats

# Tests for ralph_monitor.sh liveness classification (TAP-1201).
#
# The April-2026 NLTlabsPE Loop 1 incident triggered "LIKELY DEAD" for 3+
# minutes while Claude was actively committing to main. Root cause: the
# monitor only looked at status.json mtime, which on-stop.sh writes after
# Claude returns. Long Claude calls left status.json artificially old.
#
# These tests pin the new four-way classifier (HEALTHY / STALE / DEAD /
# UNKNOWN) so the regression cannot recur silently.

load '../helpers/test_helper'

setup() {
    export TEST_HOME="$BATS_TEST_TMPDIR"
    cd "$TEST_HOME"
    export RALPH_DIR=".ralph"
    export LIVE_LOG=".ralph/live.log"
    export STALE_WARN_SECS=600
    export STALE_DEAD_SECS=1800
    export LIVE_LOG_FRESH_SECS=60
    mkdir -p "$RALPH_DIR"

    # Source just the helpers we need by stubbing the hostile init lines.
    # ralph_monitor.sh runs an interactive loop on source — we extract only
    # the helper functions via a shimmed copy.
    cp "$BATS_TEST_DIRNAME/../../ralph_monitor.sh" "$TEST_HOME/monitor_under_test.sh"
    # Strip the trailing display loop so sourcing is safe.
    awk '
        /^display_status\(\)/ { skip=1 }
        !skip { print }
    ' "$TEST_HOME/monitor_under_test.sh" > "$TEST_HOME/helpers_only.sh"
    # Trap the EXIT cleanup the source script registers.
    sed -i 's/^trap cleanup.*$/# trap removed for test/' "$TEST_HOME/helpers_only.sh" || true

    # shellcheck disable=SC1091
    source "$TEST_HOME/helpers_only.sh"
}

teardown() {
    rm -rf "$TEST_HOME/.ralph"
}

# Stub _ralph_loop_alive deterministically per-test by re-defining it
# AFTER sourcing the helper file (bash function shadowing).
_set_loop_alive() {
    if [[ "$1" == "true" ]]; then
        eval '_ralph_loop_alive() { return 0; }'
    else
        eval '_ralph_loop_alive() { return 1; }'
    fi
}

# Helper to write a live.log of a given age (seconds in the past).
_write_live_log_age() {
    local age_secs="$1"
    touch "$LIVE_LOG"
    local target_epoch
    target_epoch=$(( $(date -u +%s) - age_secs ))
    # Cross-platform: try GNU touch first, then BSD form.
    touch -d "@${target_epoch}" "$LIVE_LOG" 2>/dev/null \
      || touch -t "$(date -r "${target_epoch}" '+%Y%m%d%H%M.%S')" "$LIVE_LOG"
}

# ---------------------------------------------------------------------------
# Healthy: loop alive + recent live.log → HEALTHY regardless of status_age
# ---------------------------------------------------------------------------

@test "HEALTHY when loop alive and live.log fresh, even if status.json old" {
    _set_loop_alive true
    _write_live_log_age 5
    run _classify_liveness 2400  # status_age way past STALE_DEAD_SECS
    assert_success
    assert_equal "$output" "HEALTHY"
}

@test "HEALTHY when loop alive and live.log fresh and status fresh" {
    _set_loop_alive true
    _write_live_log_age 5
    run _classify_liveness 30
    assert_success
    assert_equal "$output" "HEALTHY"
}

# ---------------------------------------------------------------------------
# DEAD: stale status AND no live process — the only path to DEAD
# ---------------------------------------------------------------------------

@test "DEAD when status_age>STALE_DEAD_SECS AND loop process gone" {
    _set_loop_alive false
    _write_live_log_age 5000  # ancient log too
    run _classify_liveness 2400
    assert_success
    assert_equal "$output" "DEAD"
}

@test "NOT DEAD when status stale but loop process alive" {
    _set_loop_alive true
    _write_live_log_age 200  # stale live.log
    run _classify_liveness 2400
    assert_success
    [[ "$output" != "DEAD" ]]
}

@test "NOT DEAD when loop process gone but status fresh" {
    _set_loop_alive false
    _write_live_log_age 5000
    run _classify_liveness 30
    assert_success
    [[ "$output" != "DEAD" ]]
}

# ---------------------------------------------------------------------------
# STALE: loop alive but no recent activity, OR process gone but status
# still within DEAD threshold
# ---------------------------------------------------------------------------

@test "STALE when loop alive but live.log old" {
    _set_loop_alive true
    _write_live_log_age 5000
    run _classify_liveness 700  # past warn, before dead
    assert_success
    assert_equal "$output" "STALE"
}

@test "STALE when process gone but status within dead threshold" {
    _set_loop_alive false
    _write_live_log_age 5000
    run _classify_liveness 1000
    assert_success
    assert_equal "$output" "STALE"
}

# ---------------------------------------------------------------------------
# UNKNOWN: no signal at all
# ---------------------------------------------------------------------------

@test "UNKNOWN when no status, no live.log, no process" {
    _set_loop_alive false
    rm -f "$LIVE_LOG"
    run _classify_liveness -1
    assert_success
    assert_equal "$output" "UNKNOWN"
}
