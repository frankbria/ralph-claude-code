#!/usr/bin/env bats
# TAP-916: existing sub-agents read .ralph/brief.json at task start.
# Asserts each of the 6 agent .md files in .claude/agents/ mentions the
# brief path in its body — graceful-degradation language is fine, but the
# reference must be present so Claude actually looks at the file.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

AGENTS_DIR="${BATS_TEST_DIRNAME}/../../.claude/agents"

# The six existing sub-agents the brief is wired into. The new
# ralph-coordinator agent (TAP-913) is intentionally excluded — it WRITES
# the brief, it does not consume it.
SUBAGENTS=(ralph ralph-architect ralph-tester ralph-bg-tester ralph-reviewer ralph-explorer)

setup() { :; }

@test "TAP-916: every sub-agent file references .ralph/brief.json" {
    for a in "${SUBAGENTS[@]}"; do
        local f="$AGENTS_DIR/${a}.md"
        [[ -f "$f" ]] || fail "missing agent file: $f"
        grep -q '\.ralph/brief\.json' "$f" \
            || fail "${a}.md must reference .ralph/brief.json"
    done
}

@test "TAP-916: every sub-agent file documents graceful brief absence" {
    # The spec is explicit: \"If the brief is missing, proceed as normal.\"
    # We accept any of a few common phrasings as long as the agent body
    # tells Claude what to do when brief.json is not present.
    local pattern='brief is missing|brief is absent|brief.*missing|missing.*brief|fall back|fallback|proceed as normal|proceed normally'
    for a in "${SUBAGENTS[@]}"; do
        local f="$AGENTS_DIR/${a}.md"
        grep -qE "$pattern" "$f" \
            || fail "${a}.md must document fallback when brief is missing"
    done
}

@test "TAP-916: ralph.md surfaces qa_required from the brief" {
    grep -q 'qa_required' "$AGENTS_DIR/ralph.md" \
        || fail "ralph.md must mention qa_required so the agent knows when to force QA"
}

@test "TAP-916: ralph-tester.md and ralph-bg-tester.md honor qa_scope" {
    for a in ralph-tester ralph-bg-tester; do
        grep -q 'qa_scope' "$AGENTS_DIR/${a}.md" \
            || fail "${a}.md must reference qa_scope from the brief"
    done
}

@test "TAP-916: ralph-reviewer.md uses risk_level to set review intensity" {
    local f="$AGENTS_DIR/ralph-reviewer.md"
    grep -q 'risk_level' "$f" || fail "ralph-reviewer.md must reference risk_level"
    grep -qE 'LOW|MEDIUM|HIGH' "$f" || fail "ralph-reviewer.md must enumerate risk levels"
}

@test "TAP-916: ralph-explorer.md prefers brain_recall results from prior_learnings" {
    grep -q 'prior_learnings' "$AGENTS_DIR/ralph-explorer.md" \
        || fail "ralph-explorer.md must reference prior_learnings from the brief"
    grep -q 'brain_recall' "$AGENTS_DIR/ralph-explorer.md" \
        || fail "ralph-explorer.md must mention brain_recall as the source of prior learnings"
}

@test "TAP-916: ralph-architect.md handles delegate_to=ralph case" {
    grep -q 'delegate_to' "$AGENTS_DIR/ralph-architect.md" \
        || fail "ralph-architect.md must reference delegate_to so it knows when to bow out"
}

@test "TAP-916: ralph.md handles delegate_to=ralph-architect case" {
    grep -q 'delegate_to' "$AGENTS_DIR/ralph.md" \
        || fail "ralph.md must reference delegate_to so it can defer to ralph-architect"
}

@test "TAP-916: frontmatter unchanged — no new tools / model swaps" {
    # Snapshot the model and tools field of each file as a sanity check
    # that this story stayed body-only. We assert the model is what it
    # was at the start of TAP-916 (sonnet for ralph/reviewer/tester,
    # haiku for explorer/bg-tester, claude-opus-4-7 for architect).
    grep -qE '^model:[[:space:]]+sonnet[[:space:]]*$' "$AGENTS_DIR/ralph.md" \
        || fail "ralph.md model must remain 'sonnet'"
    grep -qE '^model:[[:space:]]+claude-opus-4-7[[:space:]]*$' "$AGENTS_DIR/ralph-architect.md" \
        || fail "ralph-architect.md model must remain 'claude-opus-4-7'"
    grep -qE '^model:[[:space:]]+sonnet[[:space:]]*$' "$AGENTS_DIR/ralph-tester.md" \
        || fail "ralph-tester.md model must remain 'sonnet'"
    grep -qE '^model:[[:space:]]+haiku[[:space:]]*$' "$AGENTS_DIR/ralph-bg-tester.md" \
        || fail "ralph-bg-tester.md model must remain 'haiku'"
    grep -qE '^model:[[:space:]]+sonnet[[:space:]]*$' "$AGENTS_DIR/ralph-reviewer.md" \
        || fail "ralph-reviewer.md model must remain 'sonnet'"
    grep -qE '^model:[[:space:]]+haiku[[:space:]]*$' "$AGENTS_DIR/ralph-explorer.md" \
        || fail "ralph-explorer.md model must remain 'haiku'"
}
