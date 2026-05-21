#!/usr/bin/env bats
# Regression tests for session_id corruption fix #254

setup() {
    export RALPH_DIR=$(mktemp -d)
    export CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"
    export CLAUDE_SESSION_EXPIRY_HOURS=24
}

teardown() { rm -rf "$RALPH_DIR"; }

@test "load: file with multi-line content returns only first ID (issue #254)" {
    # Simulate corrupted file from previous buggy write
    printf '3617d7ce-03a5-4def-9367-209a4568d324\n3617d7ce-03a5-4def-9367-209a4568d324\n' > "$CLAUDE_SESSION_FILE"

    # Reproduce the load logic from get_claude_session
    local session_id
    session_id=$(head -n 1 "$CLAUDE_SESSION_FILE" 2>/dev/null | tr -d '\r\n[:space:]')

    [ "$session_id" = "3617d7ce-03a5-4def-9367-209a4568d324" ]
    # Verify it's exactly 36 chars (UUID)
    [ "${#session_id}" = "36" ]
}

@test "load: file with trailing CR returns clean ID" {
    printf 'abc123-session-id\r\n' > "$CLAUDE_SESSION_FILE"
    local session_id
    session_id=$(head -n 1 "$CLAUDE_SESSION_FILE" 2>/dev/null | tr -d '\r\n[:space:]')
    [ "$session_id" = "abc123-session-id" ]
}

@test "save: jq returning multiple lines is filtered to first non-empty" {
    # Simulate jq output with multiple matches and empty lines
    local raw="line1-session\n\nline2-session\n"
    local cleaned
    cleaned=$(printf '%b' "$raw" | grep -v '^$' | head -n 1 | tr -d '\r\n[:space:]')
    [ "$cleaned" = "line1-session" ]
}
