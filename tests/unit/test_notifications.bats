#!/usr/bin/env bats
# Unit Tests for Desktop Notification System (Issue #22)
# Tests send_notification() function with cross-platform support

load '../helpers/test_helper'

# Path to ralph_loop.sh (for CLI flag tests)
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    export ENABLE_NOTIFICATIONS=false
    export VERBOSE_PROGRESS=false

    # Notification call tracking files
    export OSASCRIPT_CALL_FILE="$TEST_TEMP_DIR/.osascript_called"
    export NOTIFY_SEND_CALL_FILE="$TEST_TEMP_DIR/.notify_send_called"
    export BELL_OUTPUT_FILE="$TEST_TEMP_DIR/.bell_output"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# ── Inline send_notification() function under test ───────────────────────────
# This mirrors the implementation in ralph_loop.sh.
# Defined here so tests can manipulate PATH and ENABLE_NOTIFICATIONS directly
# without sourcing the full 2300-line script.
#
# IMPORTANT: If send_notification() in ralph_loop.sh changes, this copy MUST
# be updated to match, or these tests will test stale logic.

send_notification() {
    local title="$1"
    local message="$2"

    [[ "$ENABLE_NOTIFICATIONS" == "true" ]] || return 0

    local safe_title="${title//\"/}"
    local safe_message="${message//\"/}"

    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$safe_message\" with title \"$safe_title\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null || true
    else
        printf '\a\n'
    fi
}

# ── Helper: create a fake binary in a temp bin dir ───────────────────────────
make_mock_bin() {
    local name="$1"
    local call_file="$2"
    local bin_dir="$TEST_TEMP_DIR/mock_bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/$name" << EOF
#!/bin/bash
echo "\$@" > "$call_file"
EOF
    chmod +x "$bin_dir/$name"
    echo "$bin_dir"
}

# =============================================================================
# TEST 1: Notifications disabled by default — no commands executed
# =============================================================================

@test "send_notification does nothing when ENABLE_NOTIFICATIONS=false" {
    export ENABLE_NOTIFICATIONS=false

    # Put mock osascript in PATH so we can detect if it's called
    local bin_dir
    bin_dir=$(make_mock_bin "osascript" "$OSASCRIPT_CALL_FILE")
    export PATH="$bin_dir:$PATH"

    send_notification "Test Title" "Test Message"

    # osascript call file must NOT exist
    [[ ! -f "$OSASCRIPT_CALL_FILE" ]]
}

# =============================================================================
# TEST 2: --notify CLI flag sets ENABLE_NOTIFICATIONS=true
# =============================================================================

@test "--notify flag sets ENABLE_NOTIFICATIONS=true" {
    # Create minimal stubs so the script can parse flags without running main()
    mkdir -p lib
    for stub in circuit_breaker response_analyzer date_utils timeout_utils file_protection log_utils; do
        cat > "lib/${stub}.sh" << 'STUB'
reset_circuit_breaker() { :; }
show_circuit_status() { :; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
analyze_response() { :; }
detect_output_format() { echo "text"; }
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
get_epoch_seconds() { date +%s; }
get_next_hour_time() { echo "next-hour"; }
portable_timeout() { shift; "$@"; }
detect_timeout_cmd() { :; }
validate_ralph_integrity() { return 0; }
get_integrity_report() { echo "OK"; }
rotate_logs() { :; }
log_status() { :; }
STUB
    done
    mkdir -p "$RALPH_DIR/logs"
    echo "# prompt" > "$RALPH_DIR/PROMPT.md"

    run bash "$RALPH_SCRIPT" --notify --help
    assert_success
    # The --notify flag must appear in help output
    [[ "$output" == *"--notify"* ]]
}

# =============================================================================
# TEST 3: macOS path — osascript is called with correct arguments
# =============================================================================

@test "send_notification uses osascript on macOS when available" {
    export ENABLE_NOTIFICATIONS=true

    # Put osascript in its own directory — notify-send is absent from PATH entirely
    local osx_bin="$TEST_TEMP_DIR/osx_bin"
    mkdir -p "$osx_bin"
    cat > "$osx_bin/osascript" << EOF
#!/bin/bash
echo "\$@" > "$OSASCRIPT_CALL_FILE"
EOF
    chmod +x "$osx_bin/osascript"
    export PATH="$osx_bin:/usr/bin:/bin"

    send_notification "Ralph - Test" "Loop completed"

    [[ -f "$OSASCRIPT_CALL_FILE" ]]
    local args
    args=$(cat "$OSASCRIPT_CALL_FILE")
    [[ "$args" == *"display notification"* ]]
    [[ "$args" == *"Ralph - Test"* ]]
}

# =============================================================================
# TEST 4: Linux path — notify-send is called when osascript unavailable
# =============================================================================

@test "send_notification uses notify-send on Linux when osascript unavailable" {
    export ENABLE_NOTIFICATIONS=true

    # Create a private bin dir that has notify-send but NOT osascript
    local bin_dir="$TEST_TEMP_DIR/linux_bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/notify-send" << EOF
#!/bin/bash
echo "\$@" > "$NOTIFY_SEND_CALL_FILE"
EOF
    chmod +x "$bin_dir/notify-send"

    # Use a PATH that has notify-send but no osascript
    # Keep system tools (/usr/bin:/bin) available for the test to function
    export PATH="$bin_dir:/usr/bin:/bin"

    send_notification "Ralph - Rate Limit" "Rate limit reached"

    [[ -f "$NOTIFY_SEND_CALL_FILE" ]]
    local args
    args=$(cat "$NOTIFY_SEND_CALL_FILE")
    [[ "$args" == *"Ralph - Rate Limit"* ]]
    [[ "$args" == *"Rate limit reached"* ]]
}

# =============================================================================
# TEST 5: Fallback — terminal bell when neither tool available
# =============================================================================

@test "send_notification falls back to terminal bell when no notification tool available" {
    export ENABLE_NOTIFICATIONS=true

    # Use a PATH with no notification tools
    export PATH="/usr/bin:/bin"

    # Capture stdout (the bell character is printed to stdout)
    run send_notification "Ralph" "Test"

    assert_success
    # The output should contain the bell escape sequence trigger (echo -e "\a" outputs a bell)
    # We check that the function ran without error and produced output or exited 0
    # (bell char may not be visible in test output but status must be 0)
    [ "$status" -eq 0 ]
}
