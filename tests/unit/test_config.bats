#!/usr/bin/env bats
# Unit Tests for Config File Support

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export LOG_DIR="logs"
    export MAX_CALLS_PER_HOUR=100
    mkdir -p "$LOG_DIR"
    export ORIGINAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME"
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message" >> "$LOG_DIR/ralph.log"
    }
    export -f log_status
    # Source the shared config implementation
    source "${BATS_TEST_DIRNAME}/../../lib/config.sh"
}

teardown() {
    export HOME="$ORIGINAL_HOME"
    cd /
    rm -rf "$TEST_TEMP_DIR"
}



@test "load_config loads global config from ~/.ralphrc" {
    echo "MAX_CALLS_PER_HOUR=50" > "$HOME/.ralphrc"
    load_config
    assert_equal "$MAX_CALLS_PER_HOUR" "50"
}

@test "load_config loads project config from ./.ralphrc" {
    echo "MAX_CALLS_PER_HOUR=75" > ".ralphrc"
    load_config
    assert_equal "$MAX_CALLS_PER_HOUR" "75"
}

@test "project config overrides global config" {
    echo "MAX_CALLS_PER_HOUR=50" > "$HOME/.ralphrc"
    echo "MAX_CALLS_PER_HOUR=25" > ".ralphrc"
    load_config
    assert_equal "$MAX_CALLS_PER_HOUR" "25"
}

@test "load_config logs messages for both configs" {
    echo "MAX_CALLS_PER_HOUR=50" > "$HOME/.ralphrc"
    echo "MAX_CALLS_PER_HOUR=25" > ".ralphrc"
    load_config
    run grep -c "Loaded.*config" "$LOG_DIR/ralph.log"
    assert_equal "$output" "2"
}

@test "load_config handles missing config files gracefully" {
    rm -f "$HOME/.ralphrc" ".ralphrc"
    run load_config
    assert_success
}

@test "config values affect MAX_CALLS_PER_HOUR behavior" {
    echo "MAX_CALLS_PER_HOUR=10" > "$HOME/.ralphrc"
    load_config
    assert_equal "$MAX_CALLS_PER_HOUR" "10"
}