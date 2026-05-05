#!/usr/bin/env bats

# TAP-1415: ralph-upgrade-project must report Created vs Updated honestly.
#
# Before this fix, every freshly-installed hook or agent file was logged
# as "Updated hook: NAME" and counted toward PROJ_UPDATED, leaving the
# summary's "Created: 0" line a structural lie. During the v2.12.0
# AgentForge sync this misled the operator into believing that
# on-linear-tool.sh had not been installed.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
UPGRADE_SCRIPT="${PROJECT_ROOT}/ralph_upgrade_project.sh"

setup() {
    [[ -f "$UPGRADE_SCRIPT" ]] || skip "ralph_upgrade_project.sh not found"

    TEST_DIR="$(mktemp -d)"
    PROJECT_DIR="$TEST_DIR/proj"
    mkdir -p \
        "$PROJECT_DIR/.ralph/hooks" \
        "$PROJECT_DIR/.claude/agents"
    touch \
        "$PROJECT_DIR/.ralph/PROMPT.md" \
        "$PROJECT_DIR/.ralph/fix_plan.md" \
        "$PROJECT_DIR/.ralph/AGENT.md" \
        "$PROJECT_DIR/.ralphrc"

    # The script reads RALPH_HOME=$HOME/.ralph at startup. CI runners have
    # no Ralph install, so we stage a fake one under a sandbox HOME that
    # mirrors what `bash install.sh` would have produced: hooks/agents/
    # skills_global/ from the source checkout. Symlinks are fine — the
    # script reads, never writes, into RALPH_TEMPLATES.
    FAKE_HOME="$TEST_DIR/home"
    mkdir -p "$FAKE_HOME/.ralph/templates"
    ln -s "$PROJECT_ROOT/templates/hooks"  "$FAKE_HOME/.ralph/templates/hooks"
    ln -s "$PROJECT_ROOT/templates/skills" "$FAKE_HOME/.ralph/templates/skills"
    # Agent files live under .claude/agents/ in the source checkout, not
    # templates/agents/, so stage them explicitly.
    mkdir -p "$FAKE_HOME/.ralph/templates/agents"
    for a in "$PROJECT_ROOT"/.claude/agents/ralph*.md; do
        [[ -f "$a" ]] && ln -s "$a" "$FAKE_HOME/.ralph/templates/agents/$(basename "$a")"
    done
    export HOME="$FAKE_HOME"

    # Count the templates the script will iterate. Anchored to the source
    # checkout so the test follows whatever the repo currently ships.
    HOOK_TEMPLATE_COUNT=$(find "$PROJECT_ROOT/templates/hooks" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d '[:space:]')
    AGENT_TEMPLATE_COUNT=$(find "$PROJECT_ROOT/.claude/agents" -maxdepth 1 -name 'ralph*.md' -type f | wc -l | tr -d '[:space:]')
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Counter accuracy on first install (the bug)
# ---------------------------------------------------------------------------

@test "TAP-1415: first install logs every fresh hook as 'Created' not 'Updated'" {
    # Run the full upgrade (--hooks-only is currently a no-op orchestration
    # flag — the script always runs hooks+agents+merges; that's a separate
    # gap from the counter bug under test here).
    run bash "$UPGRADE_SCRIPT" --yes "$PROJECT_DIR"
    assert_success

    # Per-line log: every hook in templates/ must show as a Created line.
    # The bug pre-fix logged them all as 'Updated hook:' — assert the
    # negative AND the positive so the regression cannot recur silently.
    [[ "$output" == *"Created hook:"* ]] \
        || fail "per-line log missing 'Created hook:' — got: $output"
    [[ "$output" != *"Updated hook:"* ]] \
        || fail "per-line log claimed 'Updated hook:' on a fresh install — got: $output"

    # Summary: Created must be at least HOOK_TEMPLATE_COUNT (it can be
    # higher because the same fix also covers agents + .claude/skills/).
    local created_n
    created_n=$(printf '%s' "$output" | sed -n 's/.*Created: \([0-9][0-9]*\).*/\1/p' | tail -1)
    [ -n "$created_n" ] || fail "couldn't parse Created from summary: $output"
    [ "$created_n" -ge "$HOOK_TEMPLATE_COUNT" ] \
        || fail "expected Created >= $HOOK_TEMPLATE_COUNT (hooks alone), got Created: $created_n"
}

@test "TAP-1415: first --hooks-only install actually writes every hook file" {
    bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR" >/dev/null 2>&1
    local installed
    installed=$(find "$PROJECT_DIR/.ralph/hooks" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d '[:space:]')
    [ "$installed" -eq "$HOOK_TEMPLATE_COUNT" ] \
        || fail "expected $HOOK_TEMPLATE_COUNT hooks installed, found $installed"
}

# ---------------------------------------------------------------------------
# Counter accuracy on no-op re-run (regression guard for over-counting)
# ---------------------------------------------------------------------------

@test "TAP-1415: re-run on current project reports Created=0 and no fresh log lines" {
    bash "$UPGRADE_SCRIPT" --yes "$PROJECT_DIR" >/dev/null 2>&1
    run bash "$UPGRADE_SCRIPT" --yes "$PROJECT_DIR"
    assert_success
    [[ "$output" == *"Created: 0"* ]] \
        || fail "no-op re-run should report Created: 0 — got: $output"
    [[ "$output" != *"Created hook:"* ]] \
        || fail "no-op re-run should not log 'Created hook:' — got: $output"
    [[ "$output" != *"Updated hook:"* ]] \
        || fail "no-op re-run should not log 'Updated hook:' — got: $output"
}

# ---------------------------------------------------------------------------
# Mixed case: one hook drifted, one missing — must split into Updated + Created
# ---------------------------------------------------------------------------

@test "TAP-1415: mixed install (one drift + one missing) splits the counters" {
    # Pre-populate with all hooks but corrupt one and delete another so
    # the next run produces exactly one Update and one Create.
    bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR" >/dev/null 2>&1

    # Pick two hook names deterministically.
    local drifted=$(find "$PROJECT_DIR/.ralph/hooks" -maxdepth 1 -name '*.sh' -type f -printf '%f\n' | sort | head -1)
    local removed=$(find "$PROJECT_DIR/.ralph/hooks" -maxdepth 1 -name '*.sh' -type f -printf '%f\n' | sort | sed -n '2p')

    echo "# drift line" >> "$PROJECT_DIR/.ralph/hooks/$drifted"
    rm -f "$PROJECT_DIR/.ralph/hooks/$removed"

    run bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR"
    assert_success

    [[ "$output" == *"Updated hook: $drifted"* ]] \
        || fail "expected 'Updated hook: $drifted' — got: $output"
    [[ "$output" == *"Created hook: $removed"* ]] \
        || fail "expected 'Created hook: $removed' — got: $output"
    [[ "$output" == *"Updated: 1"* ]] || fail "expected Updated: 1 — got: $output"
    [[ "$output" == *"Created: 1"* ]] || fail "expected Created: 1 — got: $output"
}

# ---------------------------------------------------------------------------
# Same fix on the agent path (upgrade_agents)
# ---------------------------------------------------------------------------

@test "TAP-1415: full upgrade reports agents under Created (not Updated) when missing" {
    [[ "$AGENT_TEMPLATE_COUNT" -gt 0 ]] || skip "no agent templates in repo"

    run bash "$UPGRADE_SCRIPT" --yes "$PROJECT_DIR"
    assert_success

    # The summary should include all the hook + agent + skill creates.
    # Lower bound: at least HOOK_COUNT + AGENT_COUNT entries under Created.
    local expected_min=$((HOOK_TEMPLATE_COUNT + AGENT_TEMPLATE_COUNT))
    local created_n=$(printf '%s' "$output" | sed -n 's/.*Created: \([0-9][0-9]*\).*/\1/p' | tail -1)
    [ -n "$created_n" ] || fail "couldn't parse Created from summary: $output"
    [ "$created_n" -ge "$expected_min" ] \
        || fail "expected Created >= $expected_min (hooks + agents), got Created: $created_n"

    # Per-line log: at least one 'Created agent:' line.
    [[ "$output" == *"Created agent:"* ]] \
        || fail "expected 'Created agent:' lines — got: $output"
    [[ "$output" != *"Updated agent: ralph"* ]] \
        || fail "agents on a fresh install should be Created, not Updated — got: $output"
}

# ---------------------------------------------------------------------------
# Dry-run preview reports the same accurate counters
# ---------------------------------------------------------------------------

@test "TAP-1418: --hooks-only does not touch agents/skills/.ralphrc/PROMPT.md" {
    # Pre-condition: empty agent dir and a known PROMPT.md / .ralphrc body.
    # If the gate is missing the upgrade will populate agents and rewrite
    # the marker section in PROMPT.md, so we check signal in three places.
    local sentinel_prompt='# user-authored content — must survive --hooks-only'
    local sentinel_ralphrc='# user comment — must survive --hooks-only'
    printf '%s\n' "$sentinel_prompt" > "$PROJECT_DIR/.ralph/PROMPT.md"
    printf '%s\n' "$sentinel_ralphrc" > "$PROJECT_DIR/.ralphrc"

    [ ! -d "$PROJECT_DIR/.claude/skills" ] \
        || fail "test setup: .claude/skills should not exist yet"
    local agents_before=$(find "$PROJECT_DIR/.claude/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    [ "$agents_before" -eq 0 ] || fail "test setup: .claude/agents should be empty"

    run bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR"
    assert_success

    # Hooks WERE installed — flag still does its primary job.
    local hooks_n
    hooks_n=$(find "$PROJECT_DIR/.ralph/hooks" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d '[:space:]')
    [ "$hooks_n" -eq "$HOOK_TEMPLATE_COUNT" ] \
        || fail "expected $HOOK_TEMPLATE_COUNT hooks, found $hooks_n"

    # Non-hook surfaces UNCHANGED (the gate's job).
    local agents_after
    agents_after=$(find "$PROJECT_DIR/.claude/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    [ "$agents_after" -eq 0 ] \
        || fail "--hooks-only must not install agents (got $agents_after .md files)"

    [ ! -d "$PROJECT_DIR/.claude/skills" ] \
        || fail "--hooks-only must not create .claude/skills"

    grep -qF "$sentinel_prompt" "$PROJECT_DIR/.ralph/PROMPT.md" \
        || fail "--hooks-only rewrote PROMPT.md (sentinel gone)"
    grep -qF "$sentinel_ralphrc" "$PROJECT_DIR/.ralphrc" \
        || fail "--hooks-only rewrote .ralphrc (sentinel gone)"

    # Per-line log: no agent / skill / merge chatter expected.
    [[ "$output" != *"Created agent:"* && "$output" != *"Updated agent:"* ]] \
        || fail "--hooks-only logged agent activity — got: $output"
    [[ "$output" != *"Updated PROMPT.md"* && "$output" != *"Created PROMPT.md"* ]] \
        || fail "--hooks-only logged PROMPT.md activity — got: $output"
}

@test "TAP-1415: --dry-run on empty project predicts 'Would create hook:' lines" {
    run bash "$UPGRADE_SCRIPT" --dry-run "$PROJECT_DIR"
    assert_success
    [[ "$output" == *"Would create hook:"* ]] \
        || fail "dry-run should preview 'Would create hook:' — got: $output"
    # Pre-fix the dry-run summary still said Created: 0 because it counted
    # under PROJ_UPDATED. Now Created must be >= HOOK_TEMPLATE_COUNT.
    local created_n
    created_n=$(printf '%s' "$output" | sed -n 's/.*Created: \([0-9][0-9]*\).*/\1/p' | tail -1)
    [ "$created_n" -ge "$HOOK_TEMPLATE_COUNT" ] \
        || fail "dry-run summary should project Created >= $HOOK_TEMPLATE_COUNT, got: $created_n"
}

# ---------------------------------------------------------------------------
# TAP-1419: silent first-sync miss (the AgentForge regression).
#
# The original bug: ralph-upgrade-project ran, returned cleanly, and
# claimed success — but on-linear-tool.sh was not in the project's
# .claude/hooks/ when the loop next started. There was no log line, no
# WARN, no error code. The fix has two prongs:
#   (a) per-project upgrade.log audit trail with one line per hook
#   (b) manifest-vs-actual diff at end of upgrade_hooks() that WARNs
#       on any expected hook missing from dest.
#
# These tests simulate the underlying race by handing the upgrade tool a
# partial-template state — what a half-finished install.sh would produce
# if a concurrent ralph-upgrade-project read the templates dir mid-copy.
# ---------------------------------------------------------------------------

# Helper: rebuild FAKE_HOME's hooks dir as a real directory (not a symlink
# into the source checkout) so we can mutate its contents per test.
_partial_hooks_setup() {
    rm "$FAKE_HOME/.ralph/templates/hooks"  # was a symlink in setup()
    mkdir -p "$FAKE_HOME/.ralph/templates/hooks"
    local f
    for f in "$PROJECT_ROOT"/templates/hooks/*.sh; do
        cp "$f" "$FAKE_HOME/.ralph/templates/hooks/$(basename "$f")"
    done
}

@test "TAP-1419: upgrade.log is created with per-hook audit entries" {
    run bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR"
    assert_success

    local audit_log="$PROJECT_DIR/.ralph/upgrade.log"
    [[ -f "$audit_log" ]] || fail "expected upgrade.log at $audit_log"

    # Source manifest line + at least one per-hook decision line.
    grep -q "upgrade_hooks: source manifest count=" "$audit_log" \
        || fail "audit log missing source manifest line: $(cat "$audit_log")"
    grep -q "action=create" "$audit_log" \
        || fail "audit log missing per-hook create action: $(cat "$audit_log")"
    grep -q "manifest-diff: OK" "$audit_log" \
        || fail "audit log missing successful manifest diff: $(cat "$audit_log")"
}

@test "TAP-1419: empty source template (partial install.sh write) is logged loudly" {
    _partial_hooks_setup
    # Simulate the suspected race: install.sh was mid-copy, so on-linear-tool.sh
    # exists in templates/hooks/ as a 0-byte file. The pre-fix code skipped it
    # with a single WARN line and the operator never saw it; the post-fix
    # path also writes an audit-log entry naming the file and the cause.
    : > "$FAKE_HOME/.ralph/templates/hooks/on-linear-tool.sh"

    run bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR"
    assert_success

    [[ "$output" == *"Skipping on-linear-tool.sh"*"empty"* ]] \
        || fail "expected WARN about empty template — got: $output"

    # The hook is missing from dest, so manifest-diff must fire.
    [[ "$output" == *"on-linear-tool.sh expected but missing"* ]] \
        || fail "expected manifest-diff WARN naming the missing hook — got: $output"

    local audit_log="$PROJECT_DIR/.ralph/upgrade.log"
    grep -q "on-linear-tool.sh: action=skip-empty" "$audit_log" \
        || fail "audit log missing skip-empty entry: $(cat "$audit_log")"
    grep -q "manifest-diff: MISSING on-linear-tool.sh" "$audit_log" \
        || fail "audit log missing manifest-diff MISSING entry: $(cat "$audit_log")"
}

@test "TAP-1419: hook absent from source is reported by manifest diff via stale dest" {
    # Different shape of the same class: source is fine, but a transient
    # earlier-state install.sh did not yet copy on-linear-tool.sh into
    # templates/hooks/. Drop it from the staged source AND from a partially
    # populated dest, and confirm the diff fires.
    _partial_hooks_setup
    rm -f "$FAKE_HOME/.ralph/templates/hooks/on-linear-tool.sh"

    run bash "$UPGRADE_SCRIPT" --yes --hooks-only "$PROJECT_DIR"
    assert_success

    # Source had no on-linear-tool.sh, so it's not in expected_hooks and
    # manifest-diff cannot WARN — but the audit log MUST list whatever
    # source DID see, making the partial state diagnosable after the fact.
    local audit_log="$PROJECT_DIR/.ralph/upgrade.log"
    grep -q "upgrade_hooks: source manifest count=" "$audit_log" \
        || fail "audit log missing source manifest line: $(cat "$audit_log")"

    # The source manifest must NOT include on-linear-tool.sh — the file
    # was absent at glob time. This is what makes the partial-source race
    # visible: future log review can spot the discrepancy against a
    # canonical hook list.
    grep "source manifest" "$audit_log" | grep -v "on-linear-tool.sh" \
        || fail "manifest line should NOT contain on-linear-tool.sh in this scenario: $(cat "$audit_log")"
}
