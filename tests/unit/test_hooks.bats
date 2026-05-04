#!/usr/bin/env bats
# Unit tests for Hooks + Agent Definition (Phase 1)
# Tests HOOKS-1 through HOOKS-6 acceptance criteria

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
RALPH_LOOP="${PROJECT_ROOT}/ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph/hooks .ralph/logs
    export RALPH_DIR=".ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HOOKS-1: ralph.md agent definition
# =============================================================================

@test "HOOKS-1: ralph.md exists" {
    [[ -f "$PROJECT_ROOT/.claude/agents/ralph.md" ]]
}

@test "HOOKS-1: ralph.md has name: ralph" {
    grep -q "name: ralph" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has model: opus" {
    # Agent runs on sonnet since v1.8.4 speed optimizations
    grep -q "model: sonnet" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has maxTurns" {
    grep -q "maxTurns:" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has permissionMode: bypassPermissions" {
    # Changed from acceptEdits since v1.8.4 speed optimizations
    grep -q "permissionMode: bypassPermissions" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md includes RALPH_STATUS template" {
    grep -q "RALPH_STATUS" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "EXIT_SIGNAL" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md disallows destructive commands" {
    grep -q "git clean" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "git reset --hard" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "rm -rf" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has STOP instruction" {
    grep -q "STOP" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

# =============================================================================
# HOOKS-2: settings.json hook configuration
# =============================================================================

@test "HOOKS-2: settings.json is valid JSON" {
    jq empty "$PROJECT_ROOT/.claude/settings.json"
}

@test "HOOKS-2: settings.json declares SessionStart hook" {
    jq -e '.hooks.SessionStart' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares Stop hook" {
    jq -e '.hooks.Stop' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares PreToolUse hooks" {
    local count
    count=$(jq '.hooks.PreToolUse | length' "$PROJECT_ROOT/.claude/settings.json")
    [[ "$count" -ge 2 ]]
}

@test "HOOKS-2: settings.json declares PostToolUse hooks" {
    # PostToolUse hooks disabled since v1.8.4 (speed optimization); array exists but is empty
    jq -e '.hooks.PostToolUse' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares SubagentStop hook" {
    jq -e '.hooks.SubagentStop' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares StopFailure hook" {
    jq -e '.hooks.StopFailure' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: hook scripts reference a known hook directory" {
    # All bash hook commands must reference a legitimate hook root:
    #   - .ralph/hooks/   (Ralph's own hooks, protected layer)
    #   - .claude/hooks/  (tapps-mcp / linear / other Claude-Code plugins
    #                      that ship hook scripts under .claude/hooks/)
    # Catches garbage paths or stray script references being injected
    # into settings.json — not policing which hook directory a plugin
    # chooses to live in. The original test rejected .claude/hooks/
    # entries and broke as soon as tapps-mcp registered its hooks there.
    local stray
    stray=$(jq -r '.. | .command? // empty' "$PROJECT_ROOT/.claude/settings.json" \
        | grep -E '^bash ' \
        | grep -Ev '(\.ralph/hooks/|\.claude/hooks/)' \
        | wc -l | tr -d '[:space:]')
    [[ "$stray" -eq 0 ]] || {
        echo "Stray bash hook commands not under .ralph/hooks/ or .claude/hooks/:" >&2
        jq -r '.. | .command? // empty' "$PROJECT_ROOT/.claude/settings.json" \
            | grep -E '^bash ' | grep -Ev '(\.ralph/hooks/|\.claude/hooks/)' >&2
        return 1
    }
}

# =============================================================================
# HOOKS-3: on-session-start.sh
# =============================================================================

@test "HOOKS-3: on-session-start.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-session-start.sh" ]]
}

@test "HOOKS-3: on-session-start.sh exits 0 without .ralph dir" {
    CLAUDE_PROJECT_DIR="/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh"
    assert_success
}

@test "HOOKS-3: on-session-start.sh emits loop context to stderr" {
    echo '{"loop_count": 5}' > .ralph/status.json
    printf -- '- [x] task 1\n- [ ] task 2\n- [ ] task 3\n' > .ralph/fix_plan.md
    echo '{"state": "CLOSED"}' > .ralph/.circuit_breaker_state

    local stderr_output
    stderr_output=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>&1 >/dev/null)

    echo "$stderr_output" | grep -q "Ralph loop #6"
    echo "$stderr_output" | grep -q "1/3 complete"
    echo "$stderr_output" | grep -q "2 remaining"
    echo "$stderr_output" | grep -q "CLOSED"
    echo "$stderr_output" | grep -q "Only run tests at epic boundaries"
}

@test "HOOKS-3: on-session-start.sh short-circuits when 0 tasks remaining" {
    echo '{"loop_count": 10}' > .ralph/status.json
    printf -- '- [x] task 1\n- [x] task 2\n- [x] task 3\n' > .ralph/fix_plan.md
    echo '{"state": "CLOSED"}' > .ralph/.circuit_breaker_state

    local stderr_output
    stderr_output=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>&1 >/dev/null)

    echo "$stderr_output" | grep -q "ALL TASKS COMPLETE"
    echo "$stderr_output" | grep -q "Do NOT run tests"
    echo "$stderr_output" | grep -q "EXIT_SIGNAL: true"
    # Should NOT contain the "read fix_plan" instruction
    ! echo "$stderr_output" | grep -q "FIRST unchecked item"
}

@test "HOOKS-3: on-session-start.sh clears per-loop file tracking" {
    echo "src/foo.py" > .ralph/.files_modified_this_loop
    echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>/dev/null
    [[ ! -s .ralph/.files_modified_this_loop ]]
}

@test "HOOKS-3: on-session-start.sh uses set -euo pipefail" {
    grep -q "set -euo pipefail" "$PROJECT_ROOT/templates/hooks/on-session-start.sh"
}

# =============================================================================
# HOOKS-4: on-stop.sh
# =============================================================================

@test "HOOKS-4: on-stop.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop.sh" ]]
}

@test "HOOKS-4: on-stop.sh exits 0 without .ralph dir" {
    echo '{}' | CLAUDE_PROJECT_DIR="/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"
    assert_success
}

@test "HOOKS-4: on-stop.sh parses RALPH_STATUS and writes status.json" {
    echo '{"loop_count": 0}' > .ralph/status.json
    echo '{"state": "CLOSED", "consecutive_no_progress": 0}' > .ralph/.circuit_breaker_state

    printf '{"result": "Done.\\n---RALPH_STATUS---\\nSTATUS: IN_PROGRESS\\nTASKS_COMPLETED_THIS_LOOP: 1\\nFILES_MODIFIED: 3\\nWORK_TYPE: IMPLEMENTATION\\nEXIT_SIGNAL: false\\nRECOMMENDATION: Implemented auth\\n---END_RALPH_STATUS---"}' \
      | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"

    [[ "$(jq -r '.status' .ralph/status.json)" == "IN_PROGRESS" ]]
    [[ "$(jq -r '.loop_count' .ralph/status.json)" == "1" ]]
}

@test "HOOKS-4: on-stop.sh logs to live.log" {
    echo '{"loop_count": 0}' > .ralph/status.json
    echo '{"state": "CLOSED", "consecutive_no_progress": 0}' > .ralph/.circuit_breaker_state

    printf '{"result": "---RALPH_STATUS---\\nSTATUS: IN_PROGRESS\\nEXIT_SIGNAL: false\\n---END_RALPH_STATUS---"}' \
      | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"

    [[ -f .ralph/live.log ]]
    grep -q "Loop 1" .ralph/live.log
}

@test "HOOKS-4: on-stop.sh uses set -euo pipefail" {
    grep -q "set -euo pipefail" "$PROJECT_ROOT/templates/hooks/on-stop.sh"
}

# =============================================================================
# HOOKS-5: PreToolUse hooks
# =============================================================================

@test "HOOKS-5: validate-command.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/validate-command.sh" ]]
}

@test "HOOKS-5: validate-command.sh blocks git clean" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git clean -fd\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks rm -rf" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"rm -rf src/\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git push --force" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git push --force origin main\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh allows git add" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git add src/main.py\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh allows normal commands" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"npm test\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh exits 0 without .ralph dir" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"rm -rf /\"}}" | CLAUDE_PROJECT_DIR="/nonexistent" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh blocks git commit --no-verify" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit --no-verify -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git push --no-verify" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git push --no-verify origin main\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git commit -n (short form)" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit -n -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks --no-gpg-sign" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit --no-gpg-sign -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

# TAP-624: Bypass regressions — each of these MUST block (was allowed pre-fix).
# Use jq to build the stdin JSON so test strings don't fight bash quoting.
_tap624_run() {
    local cmd="$1"
    local payload
    payload=$(jq -cn --arg c "$cmd" '{tool_input: {command: $c}}')
    CLAUDE_PROJECT_DIR="$TEST_DIR" run bash "$PROJECT_ROOT/templates/hooks/validate-command.sh" <<< "$payload"
}

@test "TAP-624: blocks 'rm --recursive /tmp/x' (long flag)" {
    _tap624_run "rm --recursive /tmp/x"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'rm  -rf /tmp/x' (double space)" {
    _tap624_run "rm  -rf /tmp/x"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'rm -fR /tmp/x' (capital-R cluster)" {
    _tap624_run "rm -fR /tmp/x"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'rm -Rf /tmp/x'" {
    _tap624_run "rm -Rf /tmp/x"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'find / -delete'" {
    _tap624_run "find / -delete"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'truncate -s 0 .ralph/fix_plan.md'" {
    _tap624_run "truncate -s 0 .ralph/fix_plan.md"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'ln -sf / .ralph/shortcut'" {
    _tap624_run "ln -sf / .ralph/shortcut"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'chmod -x .ralph/hooks/on-stop.sh'" {
    _tap624_run "chmod -x .ralph/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks plain 'cp foo .ralph/PROMPT.md'" {
    _tap624_run "cp foo .ralph/PROMPT.md"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks plain 'mv foo .claude/settings.json'" {
    _tap624_run "mv foo .claude/settings.json"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'python3 -c ...'" {
    _tap624_run "python3 -c \"import os\""
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'perl -e ...'" {
    _tap624_run "perl -e \"print 1\""
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'git commit --amend'" {
    _tap624_run "git commit --amend"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'git commit --fixup=abc'" {
    _tap624_run "git commit --fixup=abc123"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'git push origin HEAD:main -f' (flag after refspec)" {
    _tap624_run "git push origin HEAD:main -f"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: still allows 'git push --force-with-lease'" {
    _tap624_run "git push --force-with-lease"
    assert_success
}

@test "TAP-624: blocks 'tee .ralph/PROMPT.md'" {
    _tap624_run "tee .ralph/PROMPT.md"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: blocks 'sed -i s/x/y/ .ralph/fix_plan.md' (write to protected path)" {
    _tap624_run "sed -i s/x/y/ .ralph/fix_plan.md"
    [[ "$status" -eq 2 ]]
}

@test "TAP-624: still allows 'rm /tmp/file.txt' (non-recursive, non-protected)" {
    _tap624_run "rm /tmp/file.txt"
    assert_success
}

@test "TAP-624: still allows 'git status'" {
    _tap624_run "git status"
    assert_success
}

@test "TAP-624: still allows 'python3 script.py' (no -c flag)" {
    _tap624_run "python3 script.py"
    assert_success
}

@test "TAP-624: .ralph/hooks/validate-command.sh is byte-identical to template" {
    diff "$PROJECT_ROOT/templates/hooks/validate-command.sh" \
         "$PROJECT_ROOT/.ralph/hooks/validate-command.sh"
}

@test "HOOKS-5: protect-ralph-files.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" ]]
}

@test "HOOKS-5: protect-ralph-files.sh allows fix_plan.md edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/fix_plan.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "HOOKS-5: protect-ralph-files.sh blocks PROMPT.md edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/PROMPT.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: protect-ralph-files.sh blocks .ralphrc edits when file exists" {
    touch "$TEST_DIR/.ralphrc"
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"'"$TEST_DIR"'/.ralphrc\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: protect-ralph-files.sh allows creating a new .ralphrc when absent" {
    # Initial-bootstrap case: a fresh project must be able to create .ralphrc.
    # Existing .ralphrc files stay protected (see test above).
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"'"$TEST_DIR"'/.ralphrc\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "HOOKS-5: protect-ralph-files.sh allows normal file edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"src/main.py\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "HOOKS-5: protect-ralph-files.sh allows status.json updates" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/status.json\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

# TAP-623: .claude/ control-plane guard
@test "TAP-623: protect-ralph-files.sh blocks .claude/settings.json" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".claude/settings.json\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "TAP-623: protect-ralph-files.sh blocks .claude/settings.local.json" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"/tmp/proj/.claude/settings.local.json\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "TAP-623: protect-ralph-files.sh blocks .claude/agents/ralph.md" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".claude/agents/ralph.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "TAP-623: protect-ralph-files.sh blocks .claude/hooks/on-stop.sh" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".claude/hooks/on-stop.sh\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "TAP-623: protect-ralph-files.sh blocks .claude/commands/foo.md" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".claude/commands/foo.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "TAP-623: protect-ralph-files.sh does not block unrelated 'myclaude/settings.json'" {
    # Must anchor on /.claude/ — not match any directory ending with claude.
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"src/myclaude/settings.json\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "TAP-623: protect-ralph-files.sh does not block unrelated 'notralph/fix_plan.md'" {
    # fix_plan.md allow must anchor on /.ralph/ — not match the suffix alone.
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"src/notralph/fix_plan.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "TAP-623: .ralph/hooks/protect-ralph-files.sh is byte-identical to template" {
    # TAP-538 template-parity rule: repo's runtime hook must not drift from template.
    diff "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" \
         "$PROJECT_ROOT/.ralph/hooks/protect-ralph-files.sh"
}

# =============================================================================
# HOOKS-6: --agent ralph in build_claude_command()
# =============================================================================

@test "HOOKS-6: check_agent_support function exists" {
    grep -q "check_agent_support()" "$RALPH_LOOP"
}

@test "HOOKS-6: build_claude_command supports --agent flag" {
    grep -q '"--agent"' "$RALPH_LOOP"
}

@test "HOOKS-6: RALPH_AGENT_NAME in ralphrc template" {
    grep -q "RALPH_AGENT_NAME" "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "HOOKS-6: build_claude_command hard-fails when --agent unsupported" {
    # After legacy-mode deletion (2026-04 ADR 0006) there is no fallback —
    # an old CLI must surface a clear error rather than silently bypass
    # the agent's model/permissions.
    grep -q "Claude CLI does not support --agent" "$RALPH_LOOP"
}

# =============================================================================
# All hook scripts exist in templates
# =============================================================================

@test "all hook scripts exist in templates/hooks/" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-session-start.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/validate-command.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-file-change.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-bash-command.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-subagent-done.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop-failure.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-task-completed.sh" ]]
}

@test "all hook scripts use set -euo pipefail" {
    for script in "$PROJECT_ROOT"/templates/hooks/*.sh; do
        grep -q "set -euo pipefail" "$script"
    done
}
