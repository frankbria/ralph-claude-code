#!/usr/bin/env bats
# Regression tests for _safe_count helper — fixes #255, #251, #260

setup() {
    export RALPH_DIR=$(mktemp -d)
    # Source just the helper definition from ralph_loop.sh
    eval "$(sed -n '/^_safe_count() {/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"
}

teardown() {
    rm -rf "$RALPH_DIR"
}

@test "_safe_count: CRLF line endings (issue #255)" {
    printf -- '- [ ] task1\r\n- [x] task2\r\n- [ ] task3\r\n' > "$RALPH_DIR/fix_plan.md"
    result=$(_safe_count "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md")
    [ "$result" = "2" ]
}

@test "_safe_count: no matches returns clean 0 (issue #260 / #251)" {
    printf 'no checkboxes here\n' > "$RALPH_DIR/fix_plan.md"
    result=$(_safe_count "^- \[ \]" "$RALPH_DIR/fix_plan.md")
    [ "$result" = "0" ]
    # And it must be safe in arithmetic
    total=$((result + 0))
    [ "$total" = "0" ]
}

@test "_safe_count: non-existent file returns 0" {
    result=$(_safe_count "x" "/nonexistent/file/path")
    [ "$result" = "0" ]
}

@test "_safe_count: date entries [2026-01-29] do not count as checkboxes (issue #144 regression)" {
    printf -- '- [ ] real task\n- [2026-01-29] not a checkbox\n' > "$RALPH_DIR/fix_plan.md"
    result=$(_safe_count "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md")
    [ "$result" = "1" ]
}

@test "_safe_count: result is safe in bash arithmetic with both args (issue #255 root cause)" {
    printf -- '- [ ] a\n- [x] b\n' > "$RALPH_DIR/fix_plan.md"
    uncompleted=$(_safe_count "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md")
    completed=$(_safe_count "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md")
    # This is the exact pattern from ralph_loop.sh line ~715 that previously crashed
    total=$((uncompleted + completed))
    [ "$total" = "2" ]
}
