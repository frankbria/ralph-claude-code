#!/usr/bin/env bats
# Unit tests for lib/github_lifecycle.sh (Issue #73)
#
# Covers GitHub issue lifecycle management: reference parsing, the gh wrappers
# (comment/close/labels/PR/issue) via a mocked `gh` binary on PATH, content
# generators (progress comment, completion summary, TODO scan), lifecycle state
# read/write, and the orchestration helpers (progress interval gating, the
# completion workflow ordering, and graceful degradation when gh fails).
#
# The `gh` mock records its args to a file so assertions survive `run`'s
# subshell boundary — same pattern as test_github_import.bats.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/ghlifecycle.XXXXXX")"
    cd "$TEST_DIR"

    export RALPH_DIR="$TEST_DIR/.ralph"
    export GITHUB_LIFECYCLE_STATE_FILE="$RALPH_DIR/.github_lifecycle_state"
    mkdir -p "$RALPH_DIR"

    # A clean default config (orchestration reads these globals)
    export COMMENT_PROGRESS=false COMMENT_INTERVAL=5
    export AUTO_CLOSE=false CLOSE_SUMMARY=false CREATE_PR=false LINK_ISSUE=false
    export DRAFT_PR=false CREATE_FOLLOWUPS=false FOLLOWUP_LABEL=tech-debt
    export ADD_COMPLETION_LABELS=""

    source "$PROJECT_ROOT/lib/github_lifecycle.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Build a mock gh that records each invocation's args and the stdin body, and
# can be told to fail. $1 = "ok" | "fail".
_mock_gh() {
    local mode="${1:-ok}"
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/gh" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_DIR/gh_args"
# Capture stdin body (comment/PR/issue use --body-file -)
if [[ " \$* " == *" --body-file - "* ]]; then
    cat >> "$TEST_DIR/gh_stdin"
fi
if [[ "$mode" == "fail" ]]; then
    echo "permission denied" >&2
    exit 1
fi
# pr create / issue create print a URL
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "https://github.com/o/r/pull/100"; fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then echo "https://github.com/o/r/issues/200"; fi
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/gh"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

_gh_args() { cat "$TEST_DIR/gh_args" 2>/dev/null; }

# -----------------------------------------------------------------------------
# parse_issue_reference
# -----------------------------------------------------------------------------

@test "parse_issue_reference: bare number" {
    run parse_issue_reference "42"
    assert_success
    assert_output $'42\t'
}

@test "parse_issue_reference: #N form" {
    run parse_issue_reference "#7"
    assert_success
    assert_output $'7\t'
}

@test "parse_issue_reference: owner/repo#N form" {
    run parse_issue_reference "octo/cat#15"
    assert_success
    assert_output $'15\tocto/cat'
}

@test "parse_issue_reference: full issue URL" {
    run parse_issue_reference "https://github.com/octo/cat/issues/123"
    assert_success
    assert_output $'123\tocto/cat'
}

@test "parse_issue_reference: rejects garbage" {
    run parse_issue_reference "not-an-issue"
    assert_failure
}

# -----------------------------------------------------------------------------
# init / state
# -----------------------------------------------------------------------------

@test "init_github_lifecycle writes state and exports number/repo" {
    init_github_lifecycle "octo/cat#15" "Fix the thing"
    [[ -f "$GITHUB_LIFECYCLE_STATE_FILE" ]]
    assert_equal "$(lifecycle_get '.issue.number')" "15"
    assert_equal "$(lifecycle_get '.issue.repo')" "octo/cat"
    assert_equal "$(lifecycle_get '.issue.title')" "Fix the thing"
    assert_equal "$GITHUB_ISSUE_NUMBER" "15"
    assert_equal "$GITHUB_ISSUE_REPO" "octo/cat"
}

@test "init_github_lifecycle fails on invalid reference and writes no state" {
    run init_github_lifecycle "garbage"
    assert_failure
    [[ ! -f "$GITHUB_LIFECYCLE_STATE_FILE" ]]
}

@test "lifecycle state mutation is atomic and persists" {
    init_github_lifecycle "5"
    _lifecycle_apply '.lifecycle.progress_comments_posted = 3'
    assert_equal "$(lifecycle_get '.lifecycle.progress_comments_posted')" "3"
}

# -----------------------------------------------------------------------------
# gh wrappers
# -----------------------------------------------------------------------------

@test "gh_issue_comment posts body via --body-file and records issue number" {
    _mock_gh ok
    run gh_issue_comment "42" "" "Hello world"
    assert_success
    [[ "$(_gh_args)" == *"issue comment 42 --body-file -"* ]]
    [[ "$(cat "$TEST_DIR/gh_stdin")" == *"Hello world"* ]]
}

@test "gh_issue_comment includes --repo when provided" {
    _mock_gh ok
    gh_issue_comment "42" "octo/cat" "hi"
    [[ "$(_gh_args)" == *"--repo octo/cat"* ]]
}

@test "gh_issue_comment degrades gracefully when gh fails" {
    _mock_gh fail
    run gh_issue_comment "42" "" "hi"
    assert_failure
    [[ "$output" == *"Could not post comment"* ]]
}

@test "gh_close_issue closes the issue" {
    _mock_gh ok
    run gh_close_issue "42" ""
    assert_success
    [[ "$(_gh_args)" == *"issue close 42"* ]]
}

@test "gh_add_labels is a no-op for empty labels" {
    _mock_gh ok
    run gh_add_labels "42" "" ""
    assert_success
    [[ ! -f "$TEST_DIR/gh_args" ]]
}

@test "gh_add_labels passes labels to gh issue edit" {
    _mock_gh ok
    gh_add_labels "42" "" "completed,done"
    [[ "$(_gh_args)" == *"issue edit 42 --add-label completed,done"* ]]
}

@test "gh_create_pr adds --draft only when requested and returns URL" {
    _mock_gh ok
    run gh_create_pr "My title" "body" "true" ""
    assert_success
    [[ "$output" == *"pull/100"* ]]
    [[ "$(_gh_args)" == *"pr create --title My title --body-file - --draft"* ]]
}

@test "gh_create_pr omits --draft when not requested" {
    _mock_gh ok
    gh_create_pr "T" "b" "false" "" >/dev/null
    [[ "$(_gh_args)" != *"--draft"* ]]
}

@test "gh_create_issue passes label and returns URL" {
    _mock_gh ok
    run gh_create_issue "Follow-up" "body" "tech-debt" ""
    assert_success
    [[ "$output" == *"issues/200"* ]]
    [[ "$(_gh_args)" == *"issue create --title Follow-up --body-file - --label tech-debt"* ]]
}

# -----------------------------------------------------------------------------
# content generators
# -----------------------------------------------------------------------------

@test "generate_progress_comment counts completed and remaining tasks" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Plan
- [x] Done one
- [x] Done two
- [ ] Pending one
EOF
    run generate_progress_comment 7
    assert_success
    [[ "$output" == *"loop #7"* ]]
    [[ "$output" == *"2 completed, 1 remaining"* ]]
}

@test "generate_completion_summary lists completed tasks" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Plan
- [x] Implement feature
- [ ] Not done
EOF
    run generate_completion_summary
    assert_success
    [[ "$output" == *"Implement feature"* ]]
    [[ "$output" == *"Completed tasks"* ]]
}

@test "scan_for_todos finds TODO/FIXME markers in added lines" {
    git init -q
    git config user.email t@t.co; git config user.name t
    echo "line" > code.txt
    git add code.txt && git commit -qm init
    printf 'line\n# TODO: wire up the thing\n# FIXME: handle errors\n' > code.txt
    run scan_for_todos
    assert_success
    [[ "$output" == *"TODO: wire up the thing"* ]]
    [[ "$output" == *"FIXME: handle errors"* ]]
}

@test "scan_for_todos covers TODOs across all commits since lifecycle start (codex P2)" {
    git init -q; git config user.email t@t.co; git config user.name t
    echo base > code.txt; git add code.txt; git commit -qm init
    # init captures the start SHA HERE, before the development commits
    init_github_lifecycle "42"
    printf 'base\n# TODO: from first commit\n' > code.txt; git add code.txt; git commit -qm c1
    printf 'base\n# TODO: from first commit\n# FIXME: from second commit\n' > code.txt; git add code.txt; git commit -qm c2
    run scan_for_todos
    assert_success
    # Both the earlier-commit TODO and the later-commit FIXME are found
    [[ "$output" == *"TODO: from first commit"* ]]
    [[ "$output" == *"FIXME: from second commit"* ]]
}

# -----------------------------------------------------------------------------
# orchestration: lifecycle_post_progress
# -----------------------------------------------------------------------------

@test "lifecycle_post_progress is a no-op when COMMENT_PROGRESS is false" {
    _mock_gh ok
    init_github_lifecycle "42"
    COMMENT_PROGRESS=false
    lifecycle_post_progress 5
    [[ ! -f "$TEST_DIR/gh_args" ]]
}

@test "lifecycle_post_progress only posts on the interval boundary" {
    _mock_gh ok
    init_github_lifecycle "42"
    COMMENT_PROGRESS=true COMMENT_INTERVAL=5
    : > "$RALPH_DIR/fix_plan.md"
    lifecycle_post_progress 3   # not a multiple of 5
    [[ ! -f "$TEST_DIR/gh_args" ]]
    lifecycle_post_progress 5   # boundary -> posts
    [[ "$(_gh_args)" == *"issue comment 42"* ]]
    assert_equal "$(lifecycle_get '.lifecycle.progress_comments_posted')" "1"
}

@test "lifecycle_post_progress never fails the loop when gh fails" {
    _mock_gh fail
    init_github_lifecycle "42"
    COMMENT_PROGRESS=true COMMENT_INTERVAL=1
    : > "$RALPH_DIR/fix_plan.md"
    run lifecycle_post_progress 1
    assert_success   # returns 0 despite gh failure
}

# -----------------------------------------------------------------------------
# orchestration: lifecycle_on_completion
# -----------------------------------------------------------------------------

@test "lifecycle_on_completion does nothing when all flags are off" {
    _mock_gh ok
    init_github_lifecycle "42"
    : > "$RALPH_DIR/fix_plan.md"
    lifecycle_on_completion
    # completion_detected_at is stamped, but no gh write operations happen
    [[ ! -f "$TEST_DIR/gh_args" ]]
    [[ -n "$(lifecycle_get '.lifecycle.completion_detected_at')" ]]
}

@test "lifecycle_on_completion closes issue and adds labels with --auto-close" {
    _mock_gh ok
    init_github_lifecycle "42"
    : > "$RALPH_DIR/fix_plan.md"
    AUTO_CLOSE=true ADD_COMPLETION_LABELS="completed"
    lifecycle_on_completion
    [[ "$(_gh_args)" == *"issue edit 42 --add-label completed"* ]]
    [[ "$(_gh_args)" == *"issue close 42"* ]]
    assert_equal "$(lifecycle_get '.lifecycle.issue_closed')" "true"
}

@test "lifecycle_on_completion adds Closes #N to PR body with --create-pr --link-issue" {
    _mock_gh ok
    # PR creation requires a feature branch (not the default/protected branch)
    git init -q; git config user.email t@t.co; git config user.name t
    git checkout -q -b feature/work
    echo a > a.txt; git add a.txt; git commit -qm init
    init_github_lifecycle "42" "Resolve the bug"
    : > "$RALPH_DIR/fix_plan.md"
    CREATE_PR=true LINK_ISSUE=true
    lifecycle_on_completion
    # PR title defaults to the tracked issue title
    [[ "$(_gh_args)" == *"pr create --title Resolve the bug"* ]]
    [[ "$(cat "$TEST_DIR/gh_stdin")" == *"Closes #42"* ]]
    assert_equal "$(lifecycle_get '.lifecycle.pr_created')" "true"
    assert_equal "$(lifecycle_get '.lifecycle.pr_url')" "https://github.com/o/r/pull/100"
}

@test "lifecycle_on_completion skips PR creation on the default branch (codex P1)" {
    _mock_gh ok
    git init -q; git config user.email t@t.co; git config user.name t
    git checkout -q -b main 2>/dev/null || git branch -m main
    echo a > a.txt; git add a.txt; git commit -qm init
    init_github_lifecycle "42"
    : > "$RALPH_DIR/fix_plan.md"
    CREATE_PR=true LINK_ISSUE=true
    lifecycle_on_completion
    [[ "$(_gh_args 2>/dev/null)" != *"pr create"* ]]
    # pr_created stays false (lifecycle_get's `// empty` renders a false boolean as "")
    [[ "$(lifecycle_get '.lifecycle.pr_created')" != "true" ]]
}

@test "lifecycle_on_completion posts a summary comment with --close-summary" {
    _mock_gh ok
    init_github_lifecycle "42"
    : > "$RALPH_DIR/fix_plan.md"
    CLOSE_SUMMARY=true
    lifecycle_on_completion
    [[ "$(_gh_args)" == *"issue comment 42"* ]]
    [[ "$(cat "$TEST_DIR/gh_stdin")" == *"Ralph completed development"* ]]
}

@test "lifecycle_on_completion creates a grouped follow-up issue when TODOs exist" {
    _mock_gh ok
    init_github_lifecycle "42"
    git init -q; git config user.email t@t.co; git config user.name t
    echo base > f.txt; git add f.txt; git commit -qm init
    printf 'base\n// TODO: refactor later\n' > f.txt
    CREATE_FOLLOWUPS=true FOLLOWUP_LABEL=tech-debt
    lifecycle_on_completion
    [[ "$(_gh_args)" == *"issue create --title Follow-up: TODOs from #42"* ]]
    [[ "$(_gh_args)" == *"--label tech-debt"* ]]
    assert_equal "$(lifecycle_get '.lifecycle.followups_created | length')" "1"
}

@test "lifecycle_on_completion skips follow-ups when no TODOs found" {
    _mock_gh ok
    init_github_lifecycle "42"
    git init -q; git config user.email t@t.co; git config user.name t
    echo clean > f.txt; git add f.txt; git commit -qm init
    CREATE_FOLLOWUPS=true
    lifecycle_on_completion
    [[ "$(_gh_args 2>/dev/null)" != *"issue create"* ]]
}
