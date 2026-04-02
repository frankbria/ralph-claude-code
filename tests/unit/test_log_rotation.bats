#!/usr/bin/env bats
# Unit Tests for Log Rotation (Issue #18)

load '../helpers/test_helper'

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export LOG_DIR="$TEST_TEMP_DIR/logs"
    mkdir -p "$LOG_DIR"

    # Source the real production implementation
    source "$(dirname "$BATS_TEST_FILENAME")/../../lib/log_utils.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "rotate_logs: does not rotate log file under 10MB" {
    dd if=/dev/zero bs=1024 count=1 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ -f "$LOG_DIR/ralph.log" ]
    [ ! -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_logs: rotates log file when it exceeds 10MB" {
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ ! -f "$LOG_DIR/ralph.log" ]
    [ -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_logs: keeps exactly 4 archived files and shifts content correctly" {
    echo "old log 1" > "$LOG_DIR/ralph.log.1"
    echo "old log 2" > "$LOG_DIR/ralph.log.2"
    echo "old log 3" > "$LOG_DIR/ralph.log.3"
    echo "old log 4" > "$LOG_DIR/ralph.log.4"
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    # .log.4 (the oldest) is deleted and replaced by former .log.3
    [ -f "$LOG_DIR/ralph.log.1" ]
    [ -f "$LOG_DIR/ralph.log.2" ]
    [ -f "$LOG_DIR/ralph.log.3" ]
    [ -f "$LOG_DIR/ralph.log.4" ]
    [ ! -f "$LOG_DIR/ralph.log.5" ]

    # Verify shift order
    [ "$(cat "$LOG_DIR/ralph.log.4")" = "old log 3" ]
    [ "$(cat "$LOG_DIR/ralph.log.3")" = "old log 2" ]
    [ "$(cat "$LOG_DIR/ralph.log.2")" = "old log 1" ]
}

@test "rotate_logs: handles missing log file gracefully" {
    run rotate_logs

    [ "$status" -eq 0 ]
}

@test "rotate_logs: falls back to BSD stat when GNU stat -c%s fails" {
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    # Stub stat: fail on -c%s (GNU), succeed on -f%z (BSD) by delegating to real stat -c%s
    local real_stat
    real_stat="$(command -v stat)"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/stat" << STUBEOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP_DIR/stat_calls"
if [[ "\$1" == "-c%s" ]]; then
  exit 1
fi
if [[ "\$1" == "-f%z" ]]; then
  shift
  exec "$real_stat" -c%s "\$@"
fi
exec "$real_stat" "\$@"
STUBEOF
    chmod +x "$TEST_TEMP_DIR/bin/stat"
    PATH="$TEST_TEMP_DIR/bin:$PATH"

    rotate_logs

    [ -f "$LOG_DIR/ralph.log.1" ]
    [ ! -f "$LOG_DIR/ralph.log" ]
    grep -q -- "-c%s" "$TEST_TEMP_DIR/stat_calls"
    grep -q -- "-f%z" "$TEST_TEMP_DIR/stat_calls"
}
