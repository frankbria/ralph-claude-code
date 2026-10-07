#!/usr/bin/env bats
# Unit tests for lib/int_utils.sh (Issue #371)
# to_int is the only safe way to turn an untrusted value (state files, Claude
# output) into a number: bash arithmetic evaluates a[$(cmd)].

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    source "${BATS_TEST_DIRNAME}/../../lib/int_utils.sh"
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "to_int passes plain non-negative integers through" {
    [ "$(to_int 0)" = "0" ]
    [ "$(to_int 42)" = "42" ]
    [ "$(to_int 1000000)" = "1000000" ]
}

@test "to_int reads leading zeros as base 10, not octal" {
    [ "$(to_int 08)" = "8" ]
    [ "$(to_int 0010)" = "10" ]
}

@test "to_int maps anything that is not a plain integer to 0" {
    local v
    for v in "" "abc" "-3" "1.5" "7 8" $'7\n8' "1e3" "0x10" "null" "a[0]" "PATH"; do
        [ "$(to_int "$v")" = "0" ] || { echo "to_int '$v' -> $(to_int "$v")"; false; }
    done
}

@test "to_int never evaluates its input" {
    [ "$(to_int "a[\$(touch $TEST_DIR/marker)]")" = "0" ]
    [ "$(to_int "\$(touch $TEST_DIR/marker)")" = "0" ]
    [ ! -e "$TEST_DIR/marker" ]
}

@test "to_int strips surrounding whitespace and newlines from file reads" {
    printf '12\n' > "$TEST_DIR/count"
    [ "$(to_int "$(cat "$TEST_DIR/count")")" = "12" ]
    [ "$(to_int $'\t5\n')" = "5" ]
}
