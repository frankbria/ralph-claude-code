#!/usr/bin/env bats
# Tests for tools/inspect-allowed-tools.sh — the diagnostic helper that
# prints the exact argv ralph_loop.sh would pass to Claude CLI for a
# given ALLOWED_TOOLS config.
#
# Refs issue #154. The point of these tests is to lock in that:
#   * shell metacharacters in patterns (parens, spaces, asterisks)
#     survive the comma-split intact;
#   * empty / missing inputs are handled cleanly.

load '../helpers/test_helper'

INSPECT="${BATS_TEST_DIRNAME}/../../tools/inspect-allowed-tools.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "inspect: env var overrides .ralphrc" {
    cat > .ralphrc <<'EOF'
ALLOWED_TOOLS="ShouldNotAppear"
EOF
    run env ALLOWED_TOOLS="FromEnv,Read" "$INSPECT"
    assert_success
    [[ "$output" == *"env var"* ]]
    [[ "$output" == *"FromEnv"* ]]
    [[ "$output" != *"ShouldNotAppear"* ]]
}

@test "inspect: reads ALLOWED_TOOLS from .ralphrc when no env var set" {
    cat > .ralphrc <<'EOF'
ALLOWED_TOOLS="Write,Read,Bash(git *)"
EOF
    run "$INSPECT"
    assert_success
    [[ "$output" == *".ralphrc"* ]]
    [[ "$output" == *"Write"* ]]
    [[ "$output" == *"Read"* ]]
    [[ "$output" == *"git"* ]]
}

@test "inspect: preserves Bash(git *) pattern literally" {
    run env ALLOWED_TOOLS="Bash(git *)" "$INSPECT"
    assert_success
    # printf %q escapes parens and asterisks for visibility, but the literal
    # base string must be present
    [[ "$output" == *"Bash"* ]]
    [[ "$output" == *"git"* ]]
    [[ "$output" == *"*"* ]]
}

@test "inspect: preserves Bash(*) literal asterisk (no glob expansion)" {
    # Create some files in cwd that would match * if glob expansion fired
    touch sentinel-a sentinel-b
    run env ALLOWED_TOOLS="Bash(*)" "$INSPECT"
    assert_success
    # Output must mention the literal pattern, not the matched files
    [[ "$output" == *"Bash"* ]]
    [[ "$output" != *"sentinel-a"* ]]
    [[ "$output" != *"sentinel-b"* ]]
}

@test "inspect: trims whitespace around comma-separated entries" {
    run env ALLOWED_TOOLS="  Write , Read , Bash(npm *)  " "$INSPECT"
    assert_success
    # Each entry should be present without leading/trailing whitespace
    [[ "$output" =~ \[0\][[:space:]]+Write ]]
    [[ "$output" =~ \[1\][[:space:]]+Read ]]
}

@test "inspect: empty ALLOWED_TOOLS reports the empty case" {
    run env ALLOWED_TOOLS="" "$INSPECT"
    # No .ralphrc + empty env → fall through to missing-file message
    [[ $status -eq 0 || $status -eq 2 ]]
}

@test "inspect: missing .ralphrc with no env var exits non-zero" {
    # No env var, no .ralphrc in cwd
    run env -u ALLOWED_TOOLS -u CLAUDE_ALLOWED_TOOLS "$INSPECT"
    assert_failure
    [[ "$output" == *"not found"* || "$output" == *"Usage"* ]]
}

@test "inspect: accepts custom .ralphrc path as argument" {
    cat > custom.ralphrc <<'EOF'
ALLOWED_TOOLS="Custom,Tools"
EOF
    run env -u ALLOWED_TOOLS -u CLAUDE_ALLOWED_TOOLS "$INSPECT" "custom.ralphrc"
    assert_success
    [[ "$output" == *"custom.ralphrc"* ]]
    [[ "$output" == *"Custom"* ]]
    [[ "$output" == *"Tools"* ]]
}
