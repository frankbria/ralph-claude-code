#!/usr/bin/env bats
# TAP-656: Validate .claude/settings.json hook entries are well-formed

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
SETTINGS="${PROJECT_ROOT}/.claude/settings.json"

@test "settings.json parses as valid JSON" {
    run jq . "$SETTINGS"
    assert_success
}

@test "all hook matchers are valid regex strings (no trailing backslash)" {
    # grep exits 1 when nothing matches — that's the good case (no corrupt matchers)
    run bash -c "jq -r '.. | objects | .matcher? // empty' \"$SETTINGS\" | grep -E '\\\\\$'"
    assert_failure
}

@test "all hook commands start with 'bash ' or a known binary (not a tool name like Write/Edit)" {
    # Accept three legitimate command forms:
    #   1. `bash <path>`  — Ralph convention (explicit interpreter, portable
    #      across systems where the script's executable bit may be missing).
    #   2. Other known runners: `npx`, `node`, `python`, `sh`.
    #   3. A bare `.sh` path under .claude/hooks/ — tapps-mcp / linear-MCP
    #      plugin convention (Claude Code resolves the script directly when
    #      the executable bit is set; tapps_init guarantees the bit).
    # The point of this test is to catch tool names ("Write", "Edit") or
    # garbage strings landing in a `command` field — not to police which
    # interpreter convention plugins use.
    bad=$(jq -r '.. | objects | .command? // empty' "$SETTINGS" \
        | grep -Ev '^(bash |npx |node |python |sh )' \
        | grep -Ev '^\.claude/hooks/[A-Za-z0-9_./-]+\.sh$' \
        | grep -Ev '^$' || true)
    [ -z "$bad" ] || fail "Unexpected command values: $bad"
}

@test "no statusMessage contains a pipe separator (smell for scrambled fields)" {
    # grep exits 1 when nothing matches — that's the good case (no scrambled statusMessages)
    run bash -c "jq -r '.. | objects | .statusMessage? // empty' \"$SETTINGS\" | grep '|'"
    assert_failure
}

@test "PreToolUse contains the two Ralph safety hooks (Bash + Edit|Write)" {
    # Long-term invariant: Ralph's safety hooks must be present and wired
    # to the right scripts. Additional PreToolUse entries (e.g. tapps-mcp's
    # Linear-write governance, future plugin hooks) are allowed — what the
    # test guards against is *removal or rewiring* of Ralph's two hooks.
    # The original "exactly 2" assertion locked out plugin ecosystems and
    # broke as soon as tapps-mcp registered its Linear MCP hooks.
    bash_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$SETTINGS")
    [[ "$bash_cmd" == *"validate-command.sh"* ]] \
        || fail "PreToolUse Bash hook missing or rewired: '$bash_cmd' (expected validate-command.sh)"

    edit_write_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write") | .hooks[0].command' "$SETTINGS")
    [[ "$edit_write_cmd" == *"protect-ralph-files.sh"* ]] \
        || fail "PreToolUse Edit|Write hook missing or rewired: '$edit_write_cmd' (expected protect-ralph-files.sh)"
}

@test "StopFailure has exactly one entry (rate_limit|server_error)" {
    count=$(jq '[.hooks.StopFailure[].matcher] | length' "$SETTINGS")
    [ "$count" -eq 1 ] || fail "Expected 1 StopFailure entry, got $count"
}
