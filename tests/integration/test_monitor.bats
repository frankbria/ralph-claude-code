#!/usr/bin/env bats
# Integration tests for ralph_monitor.sh dashboard (Issue #15)
#
# Sourcing strategy: `head -n -1` loads all function definitions from
# ralph_monitor.sh without triggering the unconditional `main` call on
# the last line. This mirrors the inline/source pattern used in
# test_tmux_integration.bats and test_loop_execution.bats.

bats_require_minimum_version 1.5.0

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph/logs

    MONITOR_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"

    # Load all monitor functions without calling main().
    # head -n -1 strips the bare `main` call on the final line.
    # The `trap cleanup ...` line is filtered out: sourcing it would REPLACE
    # bats' own EXIT trap, silently swallowing failing tests (the file then
    # reports "Executed N-1 instead of expected N" with no `not ok` line).
    # shellcheck disable=SC1090
    source <(head -n -1 "$MONITOR_SCRIPT" | grep -v '^trap cleanup ')

    # Override clear_screen to suppress terminal-escape side-effects in tests.
    clear_screen() { :; }
    # Override cleanup in case a test invokes it directly.
    cleanup() { :; }
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: run display_status and strip ANSI colour codes.
monitor_output() {
    display_status 2>/dev/null | strip_colors
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: status.json reading
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh reads status.json correctly" {
    create_sample_status_running ".ralph/status.json"

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "Loop Count:" || {
        echo "Missing 'Loop Count:' in output"
        echo "Full output: $output"
        return 1
    }
    echo "$output" | grep -q "42/100" || {
        echo "Missing '42/100' API call ratio"
        echo "Full output: $output"
        return 1
    }
    echo "$output" | grep -q "running" || {
        echo "Missing 'running' status value"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: loop count display
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh displays loop count" {
    cat > .ralph/status.json << 'EOF'
{
    "loop_count": 42,
    "calls_made_this_hour": 0,
    "max_calls_per_hour": 100,
    "status": "running"
}
EOF

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "#42" || {
        echo "Expected '#42' in output"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: API calls/hour display
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh displays API calls/hour" {
    cat > .ralph/status.json << 'EOF'
{
    "loop_count": 1,
    "calls_made_this_hour": 95,
    "max_calls_per_hour": 100,
    "status": "running"
}
EOF

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "95/100" || {
        echo "Expected '95/100' in API calls display"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: recent log entries
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh shows recent log entries" {
    create_sample_status_running ".ralph/status.json"

    # Write 15 log lines; display_status shows the last 8 (tail -n 8)
    for i in $(seq 1 15); do
        echo "Log entry $i"
    done > .ralph/logs/ralph.log

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "Log entry 15" || {
        echo "Expected 'Log entry 15' in output"
        echo "Full output: $output"
        return 1
    }

    local shown_count
    shown_count=$(echo "$output" | grep -c "Log entry" || true)
    [[ "$shown_count" -eq 8 ]] || {
        echo "Expected 8 log entries shown, got: $shown_count"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: missing status.json
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh handles missing status.json file" {
    # No status.json created — the .ralph/ dir exists but the file does not

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "Status file not found" || {
        echo "Expected 'Status file not found' message"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: corrupted JSON
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh handles corrupted JSON" {
    printf '{invalid json content}' > .ralph/status.json

    local output
    # Script must not crash; jq falls back to "0" / "unknown" via `|| echo` guards
    output=$(monitor_output)

    echo "$output" | grep -q "Loop Count:" || {
        echo "Script should still render the status section with corrupted JSON"
        echo "Full output: $output"
        return 1
    }
    # jq -r '.loop_count // "0"' on invalid JSON returns "0"
    echo "$output" | grep -q "#0" || {
        echo "Expected '#0' fallback for loop count on corrupted JSON"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: progress indicator display
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh progress indicator display" {
    create_sample_status_running ".ralph/status.json"
    create_sample_progress_executing ".ralph/progress.json"

    local output
    output=$(monitor_output)

    echo "$output" | grep -q "Claude Code Progress" || {
        echo "Expected 'Claude Code Progress' section"
        echo "Full output: $output"
        return 1
    }
    echo "$output" | grep -q "120s elapsed" || {
        echo "Expected '120s elapsed' from progress.json fixture"
        echo "Full output: $output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 8: cursor hide/show functionality
# ──────────────────────────────────────────────────────────────────────────────

@test "ralph_monitor.sh cursor hide/show functionality" {
    # show_cursor must emit the ANSI cursor-show escape sequence
    local show_seq
    show_seq=$(show_cursor)
    [[ "$show_seq" == $'\033[?25h' ]] || {
        printf 'show_cursor: expected ESC[?25h, got: %s\n' "$(printf '%s' "$show_seq" | cat -v)"
        return 1
    }

    # Verify ralph_monitor.sh registers an EXIT trap that calls cleanup
    local trap_output
    trap_output=$(bash -c "
        source <(head -n -1 '${BATS_TEST_DIRNAME}/../../ralph_monitor.sh')
        trap -p EXIT
    " 2>/dev/null)
    echo "$trap_output" | grep -q "cleanup" || {
        echo "Expected EXIT trap to invoke cleanup; trap output: $trap_output"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Issue queue progress section (Issue #72)
# ──────────────────────────────────────────────────────────────────────────────

# Helper: write a queue.json with the given entries (jq array literal)
_write_queue() {
    mkdir -p .ralph
    jq -n --argjson q "$1" '{version:"1.0", queue:$q}' > .ralph/queue.json
}

@test "ralph_monitor.sh shows queue progress when a queue exists" {
    _write_queue '[
        {"issue_number":1,"title":"A","status":"completed"},
        {"issue_number":2,"title":"B","status":"processing"},
        {"issue_number":3,"title":"C","status":"pending"}
    ]'
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "Issue Queue" || { echo "missing Issue Queue header: $output"; return 1; }
    echo "$output" | grep -q "1/3" || { echo "missing 1/3 progress: $output"; return 1; }
    echo "$output" | grep -q "#2 B" || { echo "missing current item: $output"; return 1; }
}

@test "ralph_monitor.sh hides queue section when no queue file exists" {
    rm -f .ralph/queue.json
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "Issue Queue" && { echo "queue section shown without a queue"; return 1; }
    return 0
}

@test "ralph_monitor.sh hides queue section for an empty queue" {
    _write_queue '[]'
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "Issue Queue" && { echo "queue section shown for empty queue"; return 1; }
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Sandbox section (Issue #75) — driven by status.json's sandbox field
# ──────────────────────────────────────────────────────────────────────────────

_write_status_with_sandbox() {
    mkdir -p .ralph
    cat > .ralph/status.json << JSONEOF
{
    "loop_count": 3,
    "calls_made_this_hour": 5,
    "max_calls_per_hour": 100,
    "status": "running",
    "sandbox": $1
}
JSONEOF
}

@test "ralph_monitor.sh shows e2b sandbox section with estimated cost" {
    _write_status_with_sandbox '{"provider": "e2b", "sandbox_id": "sbx_mon123", "status": "running", "estimated_cost": "0.1234"}'
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "Sandbox" || { echo "missing Sandbox header: $output"; return 1; }
    echo "$output" | grep -q "e2b" || { echo "missing provider: $output"; return 1; }
    echo "$output" | grep -q "sbx_mon123" || { echo "missing sandbox id: $output"; return 1; }
    echo "$output" | grep -q '\$0.1234' || { echo "missing estimated cost: $output"; return 1; }
}

@test "ralph_monitor.sh shows docker sandbox section without cost line" {
    _write_status_with_sandbox '{"provider": "docker", "container_id": "abc123containerid", "status": "running"}'
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "Sandbox" || { echo "missing Sandbox header: $output"; return 1; }
    echo "$output" | grep -q "docker" || { echo "missing provider: $output"; return 1; }
    echo "$output" | grep -q "abc123contai" || { echo "missing container id: $output"; return 1; }
    echo "$output" | grep -q "Est. Cost" && { echo "cost line shown for docker: $output"; return 1; }
    return 0
}

@test "ralph_monitor.sh hides sandbox section when provider is none" {
    _write_status_with_sandbox '{"provider": "none"}'
    local output
    output=$(monitor_output)
    echo "$output" | grep -q "┌─ Sandbox" && { echo "sandbox section shown for provider none"; return 1; }
    return 0
}
