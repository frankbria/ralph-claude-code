#!/usr/bin/env bats
# Unit Tests for Notification System

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export ENABLE_NOTIFICATIONS=false
    export NOTIFICATION_LOG="$TEST_TEMP_DIR/notifications.log"
    mkdir -p "$(dirname "$NOTIFICATION_LOG")"
    # Source the real notifications implementation
    source "${BATS_TEST_DIRNAME}/../../lib/notifications.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "send_notification uses osascript when available" {
    export ENABLE_NOTIFICATIONS=true
    mkdir -p "$TEST_TEMP_DIR/bin"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Stub osascript to log its invocation
    cat > "$TEST_TEMP_DIR/bin/osascript" << 'EOF'
#!/bin/bash
echo "osascript:$*" >> "$NOTIFICATION_LOG"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/osascript"

    send_notification "Test" "Message"
    run grep "osascript:" "$NOTIFICATION_LOG"
    assert_success
    [[ "$output" == *"Test"* ]]
    [[ "$output" == *"Message"* ]]
}

@test "send_notification uses notify-send when osascript unavailable" {
    export ENABLE_NOTIFICATIONS=true
    mkdir -p "$TEST_TEMP_DIR/bin"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Ensure osascript is not available
    rm -f "$TEST_TEMP_DIR/bin/osascript" 2>/dev/null || true

    # Stub notify-send
    cat > "$TEST_TEMP_DIR/bin/notify-send" << 'EOF'
#!/bin/bash
echo "notify-send:$*" >> "$NOTIFICATION_LOG"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/notify-send"

    send_notification "Test" "Message"
    run grep "notify-send:" "$NOTIFICATION_LOG"
    assert_success
    [[ "$output" == *"Test"* ]]
    [[ "$output" == *"Message"* ]]
}

@test "send_notification falls back to terminal bell when no notifiers available" {
    export ENABLE_NOTIFICATIONS=true
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Temporarily restrict PATH so osascript/notify-send are not found
    local original_path="$PATH"
    PATH="$TEST_TEMP_DIR/bin"

    send_notification "Test" "Message"

    PATH="$original_path"

    run grep "BELL" "$NOTIFICATION_LOG"
    assert_success
}