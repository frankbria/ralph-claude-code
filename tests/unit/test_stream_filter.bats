#!/usr/bin/env bats
# TAP-1470: behavior contract for lib/stream_filter.awk.
# Feeds synthetic NDJSON fixtures through the extracted awk filter and asserts
# the formatted stdout matches the expected display shape. Time-dependent
# elapsed-time fields are tolerated via regex; everything else is byte-exact.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."
FILTER="${ROOT}/lib/stream_filter.awk"
FIX="${ROOT}/tests/fixtures/stream_filter"

run_filter() {
    local fixture="$1"
    local now
    now=$(date +%s)
    awk -v st="$now" -v tc=0 -v ac=0 -v ec=0 -v it=0 -v ct="" -v ti="" \
        -f "$FILTER" < "$fixture"
}

@test "TAP-1470: lib/stream_filter.awk exists" {
    [[ -f "$FILTER" ]] || fail "missing $FILTER"
}

@test "TAP-1470: tool_use Read renders compact path with last 3 components" {
    local out
    out=$(run_filter "$FIX/tool_use.ndjson")
    [[ "$out" == *'[1] Read(.../src/lib/foo.sh) [0m'*'s]'* ]] \
        || fail "expected '[1] Read(.../src/lib/foo.sh) [...]' in output, got: $out"
}

@test "TAP-1470: tool_use Bash truncates command at 60 chars" {
    local out
    out=$(run_filter "$FIX/bash_long.ndjson")
    [[ "$out" == *'[1] Bash('*'...) [0m'*'s]'* ]] \
        || fail "expected truncated Bash command with '...) [...]', got: $out"
    # Truncated command should not contain the tail of the original
    [[ "$out" != *"sixty_chars_max_for_display"* ]] \
        || fail "command was not truncated"
}

@test "TAP-1470: Grep renders pattern parameter" {
    local out
    out=$(run_filter "$FIX/glob_grep.ndjson")
    [[ "$out" == *'[1] Grep(foo.*bar) [0m'*'s]'* ]] \
        || fail "expected '[1] Grep(foo.*bar) [...]', got: $out"
}

@test "TAP-1470: tool with no recognized parameter renders without parens" {
    local out
    out=$(run_filter "$FIX/no_param_tool.ndjson")
    [[ "$out" == *'[1] WeirdTool [0m'*'s]'* ]] \
        || fail "expected '[1] WeirdTool [...]' (no parens), got: $out"
    [[ "$out" != *'WeirdTool('* ]] \
        || fail "should not have parens for unknown tool"
}

@test "TAP-1470: is_error:true emits ❌ Error: with extracted content" {
    local out
    out=$(run_filter "$FIX/error.ndjson")
    [[ "$out" == *'❌ Error: Permission denied: /etc/passwd'* ]] \
        || fail "expected error line with extracted message, got: $out"
}

@test "TAP-1470: task_started emits >> Agent #N: description" {
    local out
    out=$(run_filter "$FIX/agent.ndjson")
    [[ "$out" == *'>> Agent #1: Searching for X'* ]] \
        || fail "expected agent start line, got: $out"
    [[ "$out" == *'   ...reading files'* ]] \
        || fail "expected agent progress line, got: $out"
}

@test "TAP-1470: text_delta is buffered and emitted with > prefix" {
    local out
    out=$(run_filter "$FIX/text_delta.ndjson")
    [[ "$out" == *'  > Hello world this is a Claude response'* ]] \
        || fail "expected '  > Hello world ...', got: $out"
}

@test "TAP-1470: text_delta containing session_id is suppressed" {
    local out
    out=$(run_filter "$FIX/text_delta_metadata.ndjson")
    [[ "$out" != *'session_id'* ]] \
        || fail "session_id metadata should be suppressed, got: $out"
    [[ "$out" != *'  > '* ]] \
        || fail "no text-block prefix should be emitted, got: $out"
}

@test "TAP-1470: text_delta over 200 chars is truncated to 197+..." {
    local out
    out=$(run_filter "$FIX/text_delta_long.ndjson")
    [[ "$out" == *'...'* ]] || fail "expected truncation marker, got: $out"
    # Find the line with '> ' prefix and verify it's exactly 200 visible chars after the prefix
    local text_line
    text_line=$(printf '%s\n' "$out" | grep '^  > ' | head -1)
    local body="${text_line#  > }"
    [[ "${#body}" -eq 200 ]] \
        || fail "expected truncated body length 200, got ${#body}: $body"
}

@test "TAP-1470: summary line has tool/agent/error counters and total elapsed" {
    local out
    out=$(run_filter "$FIX/agent.ndjson")
    [[ "$out" =~ \─\─\─\ 0\ tools\ \|\ 1\ agents\ \|\ 0\ errors\ \|\ [0-9]+m[0-9]{2}s\ total\ \─\─\─ ]] \
        || fail "expected summary line, got: $out"
}

@test "TAP-1470: stream_filter.awk is invoked via awk -f from exec_run_live" {
    # The live-pipeline awk -f invocation moved to lib/exec_helpers.sh
    # (TAP-1473 extraction); ralph_loop.sh now dispatches via exec_run_live.
    grep -qE 'awk[^|]*-f "\$SCRIPT_DIR/lib/stream_filter\.awk"' \
        "${ROOT}/lib/exec_helpers.sh" \
        || fail "lib/exec_helpers.sh should invoke awk -f \$SCRIPT_DIR/lib/stream_filter.awk"
}

@test "TAP-1470: ralph_loop.sh no longer contains an embedded stream_filter heredoc" {
    ! grep -qE "^[[:space:]]*local stream_filter='" "${ROOT}/ralph_loop.sh" \
        || fail "ralph_loop.sh still contains the old embedded stream_filter heredoc"
}
