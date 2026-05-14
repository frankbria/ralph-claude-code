#!/usr/bin/env bats
# TAP-1681 — ralph-doctor must detect Linear-mode projects whose PROMPT.md
# or .claude/agents/ralph.md still carry file-mode wording. The drift is
# what causes AgentForge-style "Read .ralph/fix_plan.md ❌ File does not
# exist" loops in Linear-mode installs that were templated before they
# switched task sources.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

# Extract the ralph-doctor heredoc body out of install.sh once per test
# session and stash it in $DOCTOR_BIN so each test can invoke it directly.
_extract_ralph_doctor() {
    local install_sh="${BATS_TEST_DIRNAME}/../../install.sh"
    awk '
      /cat > "\$INSTALL_DIR\/ralph-doctor" << '"'"'DOCTOREOF'"'"'/ { capture=1; next }
      /^DOCTOREOF$/ { if (capture) { capture=0 } }
      capture { print }
    ' "$install_sh" > "$DOCTOR_BIN"
    chmod +x "$DOCTOR_BIN"
}

setup() {
    PROJ="$(mktemp -d)"
    DOCTOR_BIN="$(mktemp)"
    _extract_ralph_doctor
    cd "$PROJ"
    mkdir -p .ralph .claude/agents
}

teardown() {
    cd /
    rm -rf "$PROJ" "$DOCTOR_BIN"
}

_write_linear_ralphrc() {
    printf 'RALPH_TASK_SOURCE="linear"\n' > .ralphrc
}

_write_file_ralphrc() {
    printf 'RALPH_TASK_SOURCE="file"\n' > .ralphrc
}

@test "TAP-1681: emits WARN when Linear-mode project's PROMPT.md still says Read .ralph/fix_plan.md" {
    _write_linear_ralphrc
    {
      echo "# Ralph Instructions"
      echo "Read .ralph/fix_plan.md and do the FIRST unchecked item."
    } > .ralph/PROMPT.md
    {
      echo "# ralph agent"
      echo "Linear is the single source of truth in linear mode."
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"Linear-mode template drift (TAP-1681):"* ]]
    [[ "$output" == *"[WARN] .ralph/PROMPT.md still carries file-mode wording"* ]]
    [[ "$output" != *"[WARN] .claude/agents/ralph.md still carries"* ]]
    [[ "$output" == *"ralph-upgrade-project --resync-templates"* ]]
}

@test "TAP-1681: emits WARN when Linear-mode project's ralph.md says 'fix_plan.md is the single source of truth'" {
    _write_linear_ralphrc
    {
      echo "# Ralph Instructions"
      echo "List open Linear issues via mcp__plugin_linear_linear__list_issues."
    } > .ralph/PROMPT.md
    {
      echo "# ralph agent"
      echo "fix_plan.md is the single source of truth."
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[WARN] .claude/agents/ralph.md still carries file-mode wording"* ]]
    [[ "$output" == *"ralph-upgrade-project --resync-templates"* ]]
}

@test "TAP-1681: emits two WARNs when both files drift in Linear mode" {
    _write_linear_ralphrc
    {
      echo "Read .ralph/fix_plan.md"
    } > .ralph/PROMPT.md
    {
      echo "fix_plan.md is the single source of truth"
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[WARN] .ralph/PROMPT.md still carries file-mode wording"* ]]
    [[ "$output" == *"[WARN] .claude/agents/ralph.md still carries file-mode wording"* ]]
}

@test "TAP-1681: emits OK when Linear-mode project's PROMPT.md and ralph.md align" {
    _write_linear_ralphrc
    {
      echo "# Ralph Instructions"
      echo "List open Linear issues via mcp__plugin_linear_linear__list_issues."
    } > .ralph/PROMPT.md
    {
      echo "# ralph agent"
      echo "Linear is the single source of truth in linear mode."
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[OK] PROMPT.md and ralph.md align with linear-mode templates"* ]]
    [[ "$output" != *"[WARN] "*"file-mode wording"* ]]
}

@test "TAP-1681: file-mode phrase contained inside a TASK_SOURCE:linear block does not trigger a WARN" {
    # This proves the awk anchor filter is scoped — file-mode words can
    # legitimately appear inside a linear-only block (e.g. a comparison
    # like 'unlike file mode, you do not Read .ralph/fix_plan.md').
    _write_linear_ralphrc
    {
      echo "<!--TASK_SOURCE:linear:start-->"
      echo "Unlike file mode, you do NOT Read .ralph/fix_plan.md in Linear mode."
      echo "<!--TASK_SOURCE:linear:end-->"
    } > .ralph/PROMPT.md
    {
      echo "# ralph agent"
      echo "Linear is the single source of truth in linear mode."
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[OK] PROMPT.md and ralph.md align with linear-mode templates"* ]]
}

@test "TAP-1681: SKIPs the check on file-mode projects" {
    _write_file_ralphrc
    {
      echo "Read .ralph/fix_plan.md"
    } > .ralph/PROMPT.md
    {
      echo "fix_plan.md is the single source of truth"
    } > .claude/agents/ralph.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[SKIP] RALPH_TASK_SOURCE is not linear — drift check N/A"* ]]
    [[ "$output" != *"[WARN] "*"file-mode wording"* ]]
}

@test "TAP-1681: SKIPs the check when .ralphrc is absent" {
    rm -f .ralphrc
    {
      echo "Read .ralph/fix_plan.md"
    } > .ralph/PROMPT.md

    run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[SKIP] no .ralphrc in CWD"* ]]
}

@test "TAP-1681: ralph_upgrade_project resolver picks the linear branch for Linear-mode projects" {
    # The doctor surfaces drift; the resolver is what fixes it. This test
    # exercises resolve_task_source_blocks() through the same path that
    # `ralph-upgrade-project --resync-templates` will take.
    local upgrade_sh="${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    [[ -f "$upgrade_sh" ]]

    local sample
    sample="$(mktemp)"
    {
      echo "before"
      echo "<!--TASK_SOURCE:file:start-->"
      echo "Read .ralph/fix_plan.md and do the FIRST unchecked item."
      echo "<!--TASK_SOURCE:file:end-->"
      echo "<!--TASK_SOURCE:linear:start-->"
      echo "List open Linear issues via the Linear MCP."
      echo "<!--TASK_SOURCE:linear:end-->"
      echo "after"
    } > "$sample"

    # Source only the resolver function.
    source <(sed -n '/^resolve_task_source_blocks() {$/,/^}$/p' "$upgrade_sh")

    run resolve_task_source_blocks "$sample" "linear"
    assert_success
    [[ "$output" == *"before"* ]]
    [[ "$output" == *"List open Linear issues via the Linear MCP."* ]]
    [[ "$output" != *"Read .ralph/fix_plan.md"* ]]
    [[ "$output" != *"<!--TASK_SOURCE:"* ]]
    [[ "$output" == *"after"* ]]
    rm -f "$sample"
}

@test "TAP-1681: ralph_upgrade_project resolver picks the file branch by default" {
    local upgrade_sh="${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    local sample
    sample="$(mktemp)"
    {
      echo "<!--TASK_SOURCE:file:start-->"
      echo "FILE BRANCH"
      echo "<!--TASK_SOURCE:file:end-->"
      echo "<!--TASK_SOURCE:linear:start-->"
      echo "LINEAR BRANCH"
      echo "<!--TASK_SOURCE:linear:end-->"
    } > "$sample"

    source <(sed -n '/^resolve_task_source_blocks() {$/,/^}$/p' "$upgrade_sh")

    run resolve_task_source_blocks "$sample" "file"
    assert_success
    [[ "$output" == *"FILE BRANCH"* ]]
    [[ "$output" != *"LINEAR BRANCH"* ]]
    rm -f "$sample"
}

@test "TAP-1681: ralph_upgrade_project resolver passes marker-less files through unchanged" {
    local upgrade_sh="${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    local sample
    sample="$(mktemp)"
    {
      echo "no markers here"
      echo "just plain content"
    } > "$sample"

    source <(sed -n '/^resolve_task_source_blocks() {$/,/^}$/p' "$upgrade_sh")

    run resolve_task_source_blocks "$sample" "linear"
    assert_success
    [[ "$output" == *"no markers here"* ]]
    [[ "$output" == *"just plain content"* ]]
    rm -f "$sample"
}

@test "TAP-1681: ralph_upgrade_project accepts --resync-templates flag" {
    local upgrade_sh="${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    run grep -F -- "--resync-templates" "$upgrade_sh"
    assert_success
}

@test "TAP-1681: templates/PROMPT.md ships both task-source branches" {
    local prompt="${BATS_TEST_DIRNAME}/../../templates/PROMPT.md"
    run grep -F "<!--TASK_SOURCE:file:start-->" "$prompt"
    assert_success
    run grep -F "<!--TASK_SOURCE:linear:start-->" "$prompt"
    assert_success
}

@test "TAP-1681: .claude/agents/ralph.md ships both task-source branches" {
    local agent="${BATS_TEST_DIRNAME}/../../.claude/agents/ralph.md"
    run grep -F "<!--TASK_SOURCE:file:start-->" "$agent"
    assert_success
    run grep -F "<!--TASK_SOURCE:linear:start-->" "$agent"
    assert_success
}
