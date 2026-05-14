#!/usr/bin/env bats
# TAP-1682 — coordinator brief cache + adaptive timeout.
#
# Covers:
#   * exec_load_cached_brief — miss / hit / stale / expired / malformed
#   * exec_save_brief_cache  — round-trip; absent brief.json; atomic write
#   * ralph_compute_coordinator_timeout — fallback / P95×2 / clamping /
#     RALPH_COORDINATOR_TIMEOUT_SECONDS override
#   * ralph_record_coordinator_timing  — appends JSONL; trims to 30 samples

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TMP="$(mktemp -d)"

    # Sandbox state: caller (and module) read RALPH_DIR for the brief path
    # and the cache dir. Override both — keeps the test fully isolated from
    # the repo's own .ralph/ state.
    export RALPH_DIR="$TMP/.ralph"
    export RALPH_BRIEF_CACHE_DIR="$RALPH_DIR/.brief_cache"
    mkdir -p "$RALPH_DIR"

    # Source the brief helpers (brief_path, brief_clear) so the cache helpers
    # can compute the brief target the same way ralph_loop.sh does.
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/brief.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/exec_helpers.sh"

    # log_status is defined in ralph_loop.sh; the cache helpers no-op when
    # it is missing, which is exactly what we want under bats.
}

teardown() {
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
}

_write_brief() {
    local risk="${1:-LOW}"
    cat > "$RALPH_DIR/brief.json" <<EOF
{
  "task_summary": "do the thing",
  "risk_level": "$risk",
  "affected_modules": ["lib/exec_helpers.sh"],
  "acceptance_criteria": ["AC1"],
  "prior_learnings": [],
  "qa_required": false,
  "linear_issue_updated_at": "2026-05-14T02:00:00Z"
}
EOF
}

# =============================================================================
# exec_load_cached_brief — eviction paths
# =============================================================================

@test "TAP-1682: cache miss when no cache file exists" {
    run exec_load_cached_brief "TAP-1681"
    assert_failure
}

@test "TAP-1682: cache miss leaves brief.json untouched" {
    _write_brief HIGH
    local before_hash
    before_hash=$(sha256sum "$RALPH_DIR/brief.json" | cut -d' ' -f1)
    run exec_load_cached_brief "TAP-9999"
    assert_failure
    local after_hash
    after_hash=$(sha256sum "$RALPH_DIR/brief.json" | cut -d' ' -f1)
    [[ "$before_hash" == "$after_hash" ]]
}

@test "TAP-1682: cache hit replaces brief.json with cached payload" {
    _write_brief LOW
    # Save the LOW brief to cache.
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    # Now mutate brief.json so we can prove the hit overwrote it.
    _write_brief HIGH

    run exec_load_cached_brief "TAP-1681"
    assert_success
    [[ -s "$RALPH_DIR/brief.json" ]]
    run jq -r '.risk_level' "$RALPH_DIR/brief.json"
    assert_success
    assert_output "LOW"
}

@test "TAP-1682: cache stale when current updatedAt differs from cached" {
    _write_brief LOW
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    run exec_load_cached_brief "TAP-1681" "2026-05-14T03:00:00Z"
    assert_failure
}

@test "TAP-1682: cache fresh when current updatedAt matches cached" {
    _write_brief LOW
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    run exec_load_cached_brief "TAP-1681" "2026-05-14T02:00:00Z"
    assert_success
}

@test "TAP-1682: cache expired by age" {
    _write_brief LOW
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    # Backdate cached_at by 2 hours.
    local cache_file="$RALPH_BRIEF_CACHE_DIR/TAP-1681.json"
    jq '.cached_at -= 7200' "$cache_file" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"

    # Default max age 1800s — should expire.
    run exec_load_cached_brief "TAP-1681"
    assert_failure
}

@test "TAP-1682: cache honored under an explicit max-age override" {
    _write_brief LOW
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    # Backdate by 2 hours, but the timeout-fallback path passes 24h.
    local cache_file="$RALPH_BRIEF_CACHE_DIR/TAP-1681.json"
    jq '.cached_at -= 7200' "$cache_file" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"

    run exec_load_cached_brief "TAP-1681" "" 86400
    assert_success
}

@test "TAP-1682: malformed cache file (no .brief payload) treated as miss" {
    mkdir -p "$RALPH_BRIEF_CACHE_DIR"
    cat > "$RALPH_BRIEF_CACHE_DIR/TAP-1681.json" <<'EOF'
{ "linear_issue_id": "TAP-1681", "cached_at": 9999999999 }
EOF
    run exec_load_cached_brief "TAP-1681"
    assert_failure
}

@test "TAP-1682: cache directory absent does not crash the loader" {
    [[ ! -d "$RALPH_BRIEF_CACHE_DIR" ]]
    run exec_load_cached_brief "TAP-1681"
    assert_failure
}

# =============================================================================
# exec_save_brief_cache — round-trip + edge cases
# =============================================================================

@test "TAP-1682: save creates cache dir if absent" {
    _write_brief MEDIUM
    [[ ! -d "$RALPH_BRIEF_CACHE_DIR" ]]
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"
    [[ -s "$RALPH_BRIEF_CACHE_DIR/TAP-1681.json" ]]
}

@test "TAP-1682: save embeds full brief content with metadata" {
    _write_brief MEDIUM
    exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"

    local cache_file="$RALPH_BRIEF_CACHE_DIR/TAP-1681.json"
    run jq -r '.linear_issue_id' "$cache_file"
    assert_output "TAP-1681"
    run jq -r '.issue_updated_at' "$cache_file"
    assert_output "2026-05-14T02:00:00Z"
    run jq -r '.brief.risk_level' "$cache_file"
    assert_output "MEDIUM"
    run jq 'has("cached_at")' "$cache_file"
    assert_output "true"
}

@test "TAP-1682: save returns non-zero when brief.json is missing" {
    rm -f "$RALPH_DIR/brief.json"
    run exec_save_brief_cache "TAP-1681" "2026-05-14T02:00:00Z"
    assert_failure
}

@test "TAP-1682: save returns non-zero with empty issue_id" {
    _write_brief LOW
    run exec_save_brief_cache "" "2026-05-14T02:00:00Z"
    assert_failure
}

# =============================================================================
# ralph_compute_coordinator_timeout — adaptive sizing
# =============================================================================

# These tests source ralph_loop.sh's helpers in isolation. Source-only mode
# is gated by RALPH_TEST_LOAD_HELPERS_ONLY (see ralph_loop.sh top) when
# present; otherwise we extract the two functions surgically.
_source_coord_timeout_helpers() {
    # Pull just the two function bodies + the COORDINATOR_TIMINGS_LOG
    # variable so we don't run the entire script.
    local sh="$REPO_ROOT/ralph_loop.sh"
    eval "$(awk '
        /^COORDINATOR_TIMINGS_LOG=/                                { print; next }
        /^COORDINATOR_TIMING_SAMPLE_CAP=/                          { print; next }
        /^ralph_record_coordinator_timing\(\) \{$/,/^\}$/          { print; next }
        /^ralph_compute_coordinator_timeout\(\) \{$/,/^\}$/        { print; next }
    ' "$sh")"
}

@test "TAP-1682: adaptive timeout falls back to 120s with no samples" {
    _source_coord_timeout_helpers
    [[ ! -f "$COORDINATOR_TIMINGS_LOG" ]]
    run ralph_compute_coordinator_timeout
    assert_success
    assert_output "120"
}

@test "TAP-1682: adaptive timeout honors RALPH_COORDINATOR_TIMEOUT_SECONDS override" {
    _source_coord_timeout_helpers
    RALPH_COORDINATOR_TIMEOUT_SECONDS=42 run ralph_compute_coordinator_timeout
    assert_success
    assert_output "42"
}

@test "TAP-1682: record_timing creates the timings log and writes JSONL" {
    _source_coord_timeout_helpers
    ralph_record_coordinator_timing 10 0
    ralph_record_coordinator_timing 12 0
    ralph_record_coordinator_timing 15 0
    [[ -s "$COORDINATOR_TIMINGS_LOG" ]]
    run wc -l < "$COORDINATOR_TIMINGS_LOG"
    [[ "$(echo "$output" | tr -d ' ')" == "3" ]]
    # Each line is parseable JSON with the documented schema.
    run jq -s 'all(.[]; has("ts") and has("duration_seconds") and has("exit_code"))' "$COORDINATOR_TIMINGS_LOG"
    assert_output "true"
}

@test "TAP-1682: adaptive timeout returns P95x2 clamped to [30,600] with enough samples" {
    _source_coord_timeout_helpers
    # Seed durations 10..100 (P95 of 91 samples is the 86th sorted value = 86).
    local i
    for i in $(seq 10 100); do
        ralph_record_coordinator_timing "$i" 0
    done
    # The CAP=30 means only the last 30 (durations 71..100) survive. P95
    # index = (30*95)/100 = 28. 28th sorted value of {71..100} is 98. ×2=196.
    run ralph_compute_coordinator_timeout
    assert_success
    [[ "$output" -ge 30 ]]
    [[ "$output" -le 600 ]]
    # 28th of 71..100 is 98, ×2 = 196.
    assert_output "196"
}

@test "TAP-1682: adaptive timeout clamps to upper bound (600s) on huge P95" {
    _source_coord_timeout_helpers
    local i
    for i in $(seq 1 30); do
        ralph_record_coordinator_timing 1000 0
    done
    run ralph_compute_coordinator_timeout
    assert_success
    assert_output "600"
}

@test "TAP-1682: adaptive timeout clamps to lower bound (30s) on tiny P95" {
    _source_coord_timeout_helpers
    local i
    for i in $(seq 1 30); do
        ralph_record_coordinator_timing 5 0
    done
    run ralph_compute_coordinator_timeout
    assert_success
    assert_output "30"
}

@test "TAP-1682: record_timing caps the file to 30 most recent samples" {
    _source_coord_timeout_helpers
    local i
    for i in $(seq 1 100); do
        ralph_record_coordinator_timing "$i" 0
    done
    run wc -l < "$COORDINATOR_TIMINGS_LOG"
    [[ "$(echo "$output" | tr -d ' ')" == "30" ]]
    # The earliest survivor should be 71, the youngest 100.
    run jq -r '.duration_seconds' "$COORDINATOR_TIMINGS_LOG"
    assert_success
    local first last
    first=$(echo "$output" | head -1)
    last=$(echo "$output" | tail -1)
    [[ "$first" == "71" ]]
    [[ "$last"  == "100" ]]
}
