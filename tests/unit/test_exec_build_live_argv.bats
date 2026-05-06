#!/usr/bin/env bats
# TAP-1473: behavior contract for exec_build_live_argv (lib/exec_helpers.sh).
#
# Tests only the pure transformation — CLAUDE_CMD_ARGS → LIVE_CMD_ARGS — which
# is the one nontrivial piece of logic in the runners that benefits from
# isolated coverage. The runners themselves (exec_run_live, exec_run_background)
# are glue around the Claude CLI subprocess; their components are already
# tested elsewhere (awk filter via TAP-1470, result extraction via
# test_extract_result_from_stream, on-stop processing via test_on_stop_hook).
# Mocking the CLI was rejected — see TAP-1473 description.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    # Stub log_status (referenced by the lib but not by exec_build_live_argv).
    log_status() { :; }
    export -f log_status

    source "$ROOT/lib/exec_helpers.sh"
}

@test "TAP-1473: --output-format json is rewritten to stream-json" {
    CLAUDE_CMD_ARGS=("claude" "--output-format" "json" "-p" "hi")
    exec_build_live_argv
    [[ "${LIVE_CMD_ARGS[1]}" == "--output-format" ]] \
        || fail "expected --output-format at index 1, got: ${LIVE_CMD_ARGS[1]}"
    [[ "${LIVE_CMD_ARGS[2]}" == "stream-json" ]] \
        || fail "expected stream-json at index 2, got: ${LIVE_CMD_ARGS[2]}"
}

@test "TAP-1473: --verbose and --include-partial-messages are appended" {
    CLAUDE_CMD_ARGS=("claude" "--output-format" "json")
    exec_build_live_argv
    local last=$((${#LIVE_CMD_ARGS[@]} - 1))
    local penultimate=$((last - 1))
    [[ "${LIVE_CMD_ARGS[$penultimate]}" == "--verbose" ]] \
        || fail "expected --verbose at index $penultimate, got: ${LIVE_CMD_ARGS[$penultimate]}"
    [[ "${LIVE_CMD_ARGS[$last]}" == "--include-partial-messages" ]] \
        || fail "expected --include-partial-messages at index $last, got: ${LIVE_CMD_ARGS[$last]}"
}

@test "TAP-1473: other flags are preserved verbatim and in order" {
    CLAUDE_CMD_ARGS=("claude" "--agent" "ralph" "--output-format" "json" "-p" "do work" "--max-turns" "50")
    exec_build_live_argv
    [[ "${LIVE_CMD_ARGS[0]}" == "claude" ]] || fail "claude command not preserved"
    [[ "${LIVE_CMD_ARGS[1]}" == "--agent" ]] || fail "--agent not preserved"
    [[ "${LIVE_CMD_ARGS[2]}" == "ralph" ]] || fail "agent value not preserved"
    [[ "${LIVE_CMD_ARGS[3]}" == "--output-format" ]] || fail "--output-format not at index 3"
    [[ "${LIVE_CMD_ARGS[4]}" == "stream-json" ]] || fail "stream-json not at index 4"
    [[ "${LIVE_CMD_ARGS[5]}" == "-p" ]] || fail "-p not preserved"
    [[ "${LIVE_CMD_ARGS[6]}" == "do work" ]] || fail "prompt value not preserved"
    [[ "${LIVE_CMD_ARGS[7]}" == "--max-turns" ]] || fail "--max-turns not preserved"
    [[ "${LIVE_CMD_ARGS[8]}" == "50" ]] || fail "max-turns value not preserved"
}

@test "TAP-1473: input with no --output-format still gets streaming flags" {
    CLAUDE_CMD_ARGS=("claude" "--agent" "ralph")
    exec_build_live_argv
    # No rewrite happened, but --verbose / --include-partial-messages still appended
    local last=$((${#LIVE_CMD_ARGS[@]} - 1))
    [[ "${LIVE_CMD_ARGS[$last]}" == "--include-partial-messages" ]] \
        || fail "streaming flags should be appended even when no --output-format present"
    # Original args preserved
    [[ "${LIVE_CMD_ARGS[0]}" == "claude" ]] || fail "claude command not preserved"
    [[ "${LIVE_CMD_ARGS[1]}" == "--agent" ]] || fail "--agent not preserved"
}

@test "TAP-1473: empty CLAUDE_CMD_ARGS produces just the streaming flags" {
    CLAUDE_CMD_ARGS=()
    exec_build_live_argv
    [[ "${#LIVE_CMD_ARGS[@]}" -eq 2 ]] \
        || fail "expected 2 entries (verbose + include-partial-messages), got ${#LIVE_CMD_ARGS[@]}"
    [[ "${LIVE_CMD_ARGS[0]}" == "--verbose" ]] || fail "first entry should be --verbose"
    [[ "${LIVE_CMD_ARGS[1]}" == "--include-partial-messages" ]] || fail "second entry should be --include-partial-messages"
}

@test "TAP-1473: arguments containing spaces are preserved as a single element" {
    CLAUDE_CMD_ARGS=("claude" "-p" "a prompt with spaces" "--output-format" "json")
    exec_build_live_argv
    [[ "${LIVE_CMD_ARGS[2]}" == "a prompt with spaces" ]] \
        || fail "space-containing argument was split, got: ${LIVE_CMD_ARGS[2]}"
}

@test "TAP-1473: lib/exec_helpers.sh is sourced by ralph_loop.sh" {
    grep -qE 'source[[:space:]]+"\$SCRIPT_DIR/lib/exec_helpers\.sh"' \
        "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should source lib/exec_helpers.sh"
}

@test "TAP-1473: execute_claude_code dispatches via exec_run_live + exec_run_background" {
    grep -qE 'exec_run_live[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_run_live"
    grep -qE 'exec_run_background[[:space:]]+' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_run_background"
}

@test "TAP-1473: ralph_loop.sh no longer contains the old inline LIVE pipeline" {
    # The old inline pipeline used \"$stream_filter\" or constructed LIVE_CMD_ARGS
    # via an inline for-loop. Both should now live only in lib/exec_helpers.sh.
    ! grep -qE '^[[:space:]]*for arg in "\$\{CLAUDE_CMD_ARGS\[@\]\}"' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the inline LIVE_CMD_ARGS construction loop"
}
