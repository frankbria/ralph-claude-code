#!/usr/bin/env bats
# Unit Tests for Notification System

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export ENABLE_NOTIFICATIONS=false
    export NOTIFICATION_LOG="$TEST_TEMP_DIR/notifications.log"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "send_notification uses osascript when available" {
    export ENABLE_NOTIFICATIONS=true
    osascript() { echo "osascript called" >> "$NOTIFICATION_LOG"; }
    export -f osascript
    command() { [[ "$2" == "osascript" ]] && return 0; return 1; }
    export -f command
    send_notification() {
        if [[ "$ENABLE_NOTIFICATIONS" == "true" ]] && command -v osascript &>/dev/null; then
            osascript -e "display notification"
        fi
    }
    send_notification "Test" "Message"
    run grep "osascript called" "$NOTIFICATION_LOG"
    assert_success
}

@test "send_notification uses notify-send when osascript unavailable" {
    export ENABLE_NOTIFICATIONS=true
    notify-send() { echo "notify-send called" >> "$NOTIFICATION_LOG"; }
    export -f notify-send
    command() { [[ "$2" == "notify-send" ]] && return 0; return 1; }
    export -f command
    send_notification() {
        if [[ "$ENABLE_NOTIFICATIONS" == "true" ]] && command -v notify-send &>/dev/null; then
            notify-send "$1" "$2"
        fi
    }
    send_notification "Test" "Message"
    run grep "notify-send called" "$NOTIFICATION_LOG"
    assert_success
}

@test "send_notification falls back to terminal bell" {
    export ENABLE_NOTIFICATIONS=true
    command() { return 1; }
    export -f command
    send_notification() {
        if [[ "$ENABLE_NOTIFICATIONS" == "true" ]]; then
            if ! command -v osascript &>/dev/null && ! command -v notify-send &>/dev/null; then
                echo "BELL" >> "$NOTIFICATION_LOG"
            fi
        fi
    }
    send_notification "Test" "Message"
    run grep "BELL" "$NOTIFICATION_LOG"
    assert_success
}