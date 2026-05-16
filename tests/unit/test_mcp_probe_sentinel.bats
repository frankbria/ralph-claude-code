#!/usr/bin/env bats
# TAP-1838 — MCP probe sentinel cache: skip `claude mcp list` when probe
# inputs (claude version + .mcp.json + ~/.claude.json) are unchanged and
# the sentinel is younger than RALPH_MCP_PROBE_SENTINEL_MAX_AGE seconds.
#
# Covers:
#   * ralph_mcp_compute_probe_hash — produces a stable, non-empty digest
#   * ralph_probe_mcp_servers      — sentinel hit (cached flags loaded)
#   * ralph_probe_mcp_servers      — sentinel miss: no file, expired, hash mismatch
#   * ralph_probe_mcp_servers      — RALPH_MCP_PROBE_SKIP_IF_UNCHANGED=false bypass
#   * ralph_probe_mcp_servers      — sentinel written after a successful live probe
#   * ralph_probe_mcp_servers      — sentinel NOT written when probe output is empty
#   * ralph_probe_mcp_servers      — brain_auth_failed flag round-trips through sentinel

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Slice functions out of ralph_loop.sh and source them into the test env.
_source_slice() {
    local slice="$TEST_TEMP_DIR/_slice.sh"
    {
        # get_cached_claude_version stub (called by ralph_mcp_compute_probe_hash)
        echo 'get_cached_claude_version() { echo "${MOCK_CLAUDE_VERSION:-2.0.0}"; }'
        # log_status stub
        echo 'log_status() { local l="$1"; shift; printf "%s %s\n" "$l" "$*" >> "$LOG_FILE"; }'
        # ralph_diagnose_brain_probe_failure stub
        echo 'ralph_diagnose_brain_probe_failure() { log_status WARN "MCP probe: tapps-brain NOT reachable"; }'
        # Knob defaults (mirror ralph_loop.sh defaults at the var declaration site)
        echo 'RALPH_MCP_PROBE_SKIP_IF_UNCHANGED="${RALPH_MCP_PROBE_SKIP_IF_UNCHANGED:-true}"'
        echo 'RALPH_MCP_PROBE_SENTINEL_FILE="${RALPH_MCP_PROBE_SENTINEL_FILE:-${RALPH_DIR}/.mcp-probe-sentinel}"'
        echo 'RALPH_MCP_PROBE_SENTINEL_MAX_AGE="${RALPH_MCP_PROBE_SENTINEL_MAX_AGE:-86400}"'
        # Extract the two functions
        awk '/^ralph_mcp_compute_probe_hash\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
        awk '/^ralph_probe_mcp_servers\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
    } > "$slice"
    # shellcheck disable=SC1090
    source "$slice"
}

# Write a sentinel file with given field values.
_write_sentinel() {
    local ts="${1:-$(date +%s)}"
    local hash="${2:-deadbeef}"
    local tapps="${3:-false}"
    local docs="${4:-false}"
    local brain="${5:-false}"
    local brain_auth_failed="${6:-false}"
    {
        printf 'ts=%s\n' "$ts"
        printf 'hash=%s\n' "$hash"
        printf 'tapps=%s\n' "$tapps"
        printf 'docs=%s\n' "$docs"
        printf 'brain=%s\n' "$brain"
        printf 'brain_auth_failed=%s\n' "$brain_auth_failed"
    } > "${RALPH_MCP_PROBE_SENTINEL_FILE}"
}

# Write a mock `claude` that prints $MOCK_CLAUDE_MCP_OUTPUT and exits 0.
_make_mock_claude() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "${MOCK_CLAUDE_MCP_OUTPUT:-}"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    export RALPH_MCP_PROBE_SENTINEL_FILE="${RALPH_DIR}/.mcp-probe-sentinel"
    export LOG_FILE="$TEST_TEMP_DIR/log.txt"
    : > "$LOG_FILE"
    _source_slice
}

teardown() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# ---------------------------------------------------------------------------
# ralph_mcp_compute_probe_hash
# ---------------------------------------------------------------------------

@test "TAP-1838: compute_probe_hash returns a non-empty string" {
    run ralph_mcp_compute_probe_hash
    assert_success
    [[ -n "$output" ]]
}

@test "TAP-1838: compute_probe_hash is stable for identical inputs" {
    local h1 h2
    h1=$(ralph_mcp_compute_probe_hash)
    h2=$(ralph_mcp_compute_probe_hash)
    [[ "$h1" == "$h2" ]]
}

@test "TAP-1838: compute_probe_hash changes when .mcp.json changes" {
    local h1 h2
    h1=$(ralph_mcp_compute_probe_hash)
    echo '{"mcpServers":{}}' > "$TEST_TEMP_DIR/.ralph/../.mcp.json"
    cd "$TEST_TEMP_DIR"
    h2=$(ralph_mcp_compute_probe_hash)
    cd - >/dev/null
    [[ "$h1" != "$h2" ]]
}

@test "TAP-1838: compute_probe_hash changes when MOCK_CLAUDE_VERSION changes" {
    local h1 h2
    export MOCK_CLAUDE_VERSION="1.0.0"
    h1=$(ralph_mcp_compute_probe_hash)
    export MOCK_CLAUDE_VERSION="2.0.0"
    h2=$(ralph_mcp_compute_probe_hash)
    [[ "$h1" != "$h2" ]]
}

# ---------------------------------------------------------------------------
# Sentinel hit — cached flags loaded, probe skipped
# ---------------------------------------------------------------------------

@test "TAP-1838: sentinel hit loads cached flags without calling claude" {
    _make_mock_claude
    # Compute hash matching the current env so sentinel matches
    local live_hash
    live_hash=$(ralph_mcp_compute_probe_hash)

    _write_sentinel "$(date +%s)" "$live_hash" "true" "true" "true" "false"

    # If probe runs, our mock would print nothing → flags stay false; but
    # sentinel hit should restore the cached true values.
    ralph_probe_mcp_servers

    [[ "$RALPH_MCP_TAPPS_AVAILABLE" == "true" ]]
    [[ "$RALPH_MCP_DOCS_AVAILABLE" == "true" ]]
    [[ "$RALPH_MCP_BRAIN_AVAILABLE" == "true" ]]
}

@test "TAP-1838: sentinel hit logs 'MCP probe cached'" {
    _make_mock_claude
    local live_hash
    live_hash=$(ralph_mcp_compute_probe_hash)
    _write_sentinel "$(date +%s)" "$live_hash" "false" "false" "false" "false"

    ralph_probe_mcp_servers
    grep -q "MCP probe cached" "$LOG_FILE"
}

@test "TAP-1838: sentinel hit restores brain_auth_failed flag" {
    _make_mock_claude
    local live_hash
    live_hash=$(ralph_mcp_compute_probe_hash)
    _write_sentinel "$(date +%s)" "$live_hash" "false" "false" "false" "true"

    ralph_probe_mcp_servers
    [[ "$RALPH_MCP_BRAIN_AUTH_FAILED" == "true" ]]
}

# ---------------------------------------------------------------------------
# Sentinel miss paths — probe must run
# ---------------------------------------------------------------------------

@test "TAP-1838: no sentinel file → probe runs" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"
    # No sentinel file written

    ralph_probe_mcp_servers
    grep -q "MCP probe: tapps-mcp reachable" "$LOG_FILE"
}

@test "TAP-1838: expired sentinel → probe runs" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"
    local live_hash
    live_hash=$(ralph_mcp_compute_probe_hash)
    # Write sentinel with ts 90000s in the past (> 86400 default)
    local old_ts=$(( $(date +%s) - 90000 ))
    _write_sentinel "$old_ts" "$live_hash" "false" "false" "false" "false"
    export RALPH_MCP_PROBE_SENTINEL_MAX_AGE=86400

    ralph_probe_mcp_servers
    grep -q "MCP probe: tapps-mcp reachable" "$LOG_FILE"
}

@test "TAP-1838: hash mismatch → probe runs" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"
    # Write sentinel with a wrong hash
    _write_sentinel "$(date +%s)" "wronghash000" "true" "true" "true" "false"

    ralph_probe_mcp_servers
    # Probe ran → log should show the live result
    grep -q "MCP probe: tapps-mcp reachable" "$LOG_FILE"
}

@test "TAP-1838: RALPH_MCP_PROBE_SKIP_IF_UNCHANGED=false bypasses cache" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"
    local live_hash
    live_hash=$(ralph_mcp_compute_probe_hash)
    _write_sentinel "$(date +%s)" "$live_hash" "false" "false" "false" "false"
    export RALPH_MCP_PROBE_SKIP_IF_UNCHANGED="false"

    ralph_probe_mcp_servers
    grep -q "MCP probe: tapps-mcp reachable" "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Sentinel write after successful live probe
# ---------------------------------------------------------------------------

@test "TAP-1838: sentinel written after successful live probe" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected
docs-mcp connected"

    ralph_probe_mcp_servers
    [[ -f "$RALPH_MCP_PROBE_SENTINEL_FILE" ]]
}

@test "TAP-1838: sentinel records correct flag values" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"

    ralph_probe_mcp_servers

    grep -q "^tapps=true$" "$RALPH_MCP_PROBE_SENTINEL_FILE"
    grep -q "^docs=false$" "$RALPH_MCP_PROBE_SENTINEL_FILE"
}

@test "TAP-1838: sentinel NOT written when probe output is empty" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT=""

    ralph_probe_mcp_servers
    [[ ! -f "$RALPH_MCP_PROBE_SENTINEL_FILE" ]]
}

@test "TAP-1838: sentinel contains a non-empty hash" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"

    ralph_probe_mcp_servers
    local stored_hash
    stored_hash=$(awk -F= '/^hash=/{print $2}' "$RALPH_MCP_PROBE_SENTINEL_FILE" 2>/dev/null || echo "")
    [[ -n "$stored_hash" ]]
}

@test "TAP-1838: sentinel written even when servers unreachable" {
    _make_mock_claude
    # Non-empty output but nothing matches the connected/ok/ready/running pattern.
    # Use "failed" — does not contain "connected" as a substring, unlike "disconnected".
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp failed
docs-mcp timeout"

    ralph_probe_mcp_servers
    [[ -f "$RALPH_MCP_PROBE_SENTINEL_FILE" ]]
    grep -q "^tapps=false$" "$RALPH_MCP_PROBE_SENTINEL_FILE"
}

# ---------------------------------------------------------------------------
# Round-trip: write sentinel → hit on next call
# ---------------------------------------------------------------------------

@test "TAP-1838: round-trip — probe writes sentinel; second call uses cache" {
    _make_mock_claude
    export MOCK_CLAUDE_MCP_OUTPUT="tapps-mcp connected"

    # First call: live probe, writes sentinel
    ralph_probe_mcp_servers
    [[ "$RALPH_MCP_TAPPS_AVAILABLE" == "true" ]]

    # Reset flags to false; if sentinel hit, they'll be restored to true
    export RALPH_MCP_TAPPS_AVAILABLE="false"
    export RALPH_MCP_DOCS_AVAILABLE="false"
    export RALPH_MCP_BRAIN_AVAILABLE="false"
    : > "$LOG_FILE"

    # Second call: should hit sentinel
    ralph_probe_mcp_servers
    [[ "$RALPH_MCP_TAPPS_AVAILABLE" == "true" ]]
    grep -q "MCP probe cached" "$LOG_FILE"
}
