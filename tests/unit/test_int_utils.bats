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

@test "to_int maps a 19-digit value to 0 (beyond the 18-digit cap)" {
    [ "$(to_int 1234567890123456789)" = "0" ]
}

@test "real should_exit_gracefully: fractional .exit_signals lengths raise no arithmetic errors (#371)" {
    # jq `length` of a number is its absolute value; 0.5 in [[ -ge ]] is a
    # syntax error that silently disables the exit checks
    cd "$TEST_DIR"
    run bash -c '
        root="$1"; set --   # ralph_loop.sh parses "$@" at source time
        source "$root/ralph_loop.sh"
        RALPH_DIR=.ralph; EXIT_SIGNALS_FILE=.ralph/.exit_signals
        RESPONSE_ANALYSIS_FILE=.ralph/.response_analysis; mkdir -p .ralph
        log_status() { :; }
        echo "{\"test_only_loops\": 0.5, \"done_signals\": 2.5, \"completion_indicators\": 1.5}" > "$EXIT_SIGNALS_FILE"
        should_exit_gracefully > /dev/null' _ "${BATS_TEST_DIRNAME}/../.."
    [[ "$output" != *"syntax error"* ]] || { echo "$output"; false; }
}
