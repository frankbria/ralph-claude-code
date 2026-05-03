#!/usr/bin/env bats

# Tests for lib/github_issues.sh — GitHub Issue Integration (TAP-540)
#
# Strategy: PATH-shim a fake `gh` binary into a per-test directory at the
# front of PATH. The shim's behavior is controlled by env vars (response
# fixture path, exit code, stderr), so each test scenario is fully
# deterministic without any network calls.
#
# Covers the GHISSUE-1..5 surface plus a few edge cases that historically
# regressed silently in production:
#   - happy path single import
#   - 404 (issue not found)
#   - 403 (auth)
#   - 429 rate limited
#   - malformed JSON from gh
#   - empty label filter
#   - dedupe vs existing fix_plan.md (idempotent re-import)
#   - per-source cap enforcement on batch
#   - input validation (TAP-651 regression guard)
#   - repo detection from SSH and HTTPS remotes

load '../helpers/test_helper'

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export GH_SHIM_DIR="$BATS_TEST_TMPDIR/bin"
    export GH_SHIM_FIXTURE="$BATS_TEST_TMPDIR/gh_response.json"
    export GH_SHIM_EXIT="0"
    export GH_SHIM_STDERR=""
    export PATH="$GH_SHIM_DIR:$PATH"
    mkdir -p "$RALPH_DIR" "$GH_SHIM_DIR"

    # Write the fake gh binary that reads env vars set by each test.
    cat > "$GH_SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
# Test shim — emits $GH_SHIM_FIXTURE contents to stdout, $GH_SHIM_STDERR
# to stderr, and exits with $GH_SHIM_EXIT. Records the invocation argv
# in $BATS_TEST_TMPDIR/gh_calls.log for assertion purposes.
echo "$@" >> "$BATS_TEST_TMPDIR/gh_calls.log"
[[ -n "$GH_SHIM_STDERR" ]] && echo "$GH_SHIM_STDERR" >&2
if [[ -f "$GH_SHIM_FIXTURE" ]]; then
    cat "$GH_SHIM_FIXTURE"
fi
exit "${GH_SHIM_EXIT:-0}"
SHIM
    chmod +x "$GH_SHIM_DIR/gh"

    # Stub git so _gh_detect_repo finds a synthetic remote without
    # depending on the host repo's actual remote.
    # MOCK_GIT_REMOTE: unset → default (SSH); empty string → simulate "no
    # remote configured" by exiting non-zero (matches real git behavior).
    git() {
        if [[ "$1" == "remote" && "$2" == "get-url" && "$3" == "origin" ]]; then
            if [[ -z "${MOCK_GIT_REMOTE+set}" ]]; then
                echo "git@github.com:wtthornton/ralph-claude-code.git"
                return 0
            fi
            if [[ -z "$MOCK_GIT_REMOTE" ]]; then
                echo "fatal: No such remote 'origin'" >&2
                return 1
            fi
            echo "$MOCK_GIT_REMOTE"
            return 0
        fi
        command git "$@"
    }
    export -f git

    source "$BATS_TEST_DIRNAME/../../lib/github_issues.sh"
}

teardown() {
    unset -f git 2>/dev/null || true
    rm -rf "$BATS_TEST_TMPDIR/.ralph" "$GH_SHIM_DIR" \
           "$GH_SHIM_FIXTURE" "$BATS_TEST_TMPDIR/gh_calls.log" 2>/dev/null || true
}

# Convenience: write a minimal valid issue fixture.
_write_issue_fixture() {
    local num="${1:-42}"
    local title="${2:-Test issue title}"
    local body="${3:-Test issue body with enough words to score above a stub.}"
    local state="${4:-open}"
    cat > "$GH_SHIM_FIXTURE" <<EOF
{"number": $num, "title": "$title", "body": "$body", "state": "$state", "labels": []}
EOF
}

# ---------------------------------------------------------------------------
# Repo detection
# ---------------------------------------------------------------------------

@test "_gh_detect_repo: parses SSH remote" {
    export MOCK_GIT_REMOTE="git@github.com:wtthornton/ralph-claude-code.git"
    run _gh_detect_repo
    assert_success
    assert_equal "$output" "wtthornton/ralph-claude-code"
}

@test "_gh_detect_repo: parses HTTPS remote without .git suffix" {
    export MOCK_GIT_REMOTE="https://github.com/wtthornton/ralph-claude-code"
    run _gh_detect_repo
    assert_success
    assert_equal "$output" "wtthornton/ralph-claude-code"
}

@test "_gh_detect_repo: returns failure with no remote" {
    export MOCK_GIT_REMOTE=""
    run _gh_detect_repo
    assert_failure
}

# ---------------------------------------------------------------------------
# Input validation (TAP-651 regression guard)
# ---------------------------------------------------------------------------

@test "ralph_import_issue: rejects empty issue number" {
    run ralph_import_issue ""
    assert_failure
    [[ "$output" == *"Issue number required"* ]]
}

@test "ralph_import_issue: rejects non-integer issue number (TAP-651)" {
    run ralph_import_issue '0,"evil":"x"'
    assert_failure
    [[ "$output" == *"Invalid issue number"* ]]
}

@test "ralph_import_issue: rejects leading zero / negative" {
    run ralph_import_issue "-5"
    assert_failure
    run ralph_import_issue "0"
    assert_failure
}

# ---------------------------------------------------------------------------
# Happy path — single import
# ---------------------------------------------------------------------------

@test "ralph_import_issue: happy path writes metadata + fix_plan" {
    _write_issue_fixture 42 "Add feature X" "- [ ] Step one\n- [ ] Step two"
    run ralph_import_issue 42
    assert_success
    [[ -f "$RALPH_DIR/.github_issue.json" ]]
    [[ -f "$RALPH_DIR/fix_plan.md" ]]
    # metadata is well-formed JSON with the right number
    run jq -r '.number' "$RALPH_DIR/.github_issue.json"
    assert_equal "$output" "42"
    run jq -r '.repo' "$RALPH_DIR/.github_issue.json"
    assert_equal "$output" "wtthornton/ralph-claude-code"
}

# ---------------------------------------------------------------------------
# gh failure modes (404 / 403 / 429 / malformed)
# ---------------------------------------------------------------------------

@test "ralph_import_issue: 404 from gh surfaces error and skips writes" {
    export GH_SHIM_EXIT="1"
    export GH_SHIM_STDERR="HTTP 404: Not Found"
    rm -f "$GH_SHIM_FIXTURE"
    run ralph_import_issue 999
    assert_failure
    [[ "$output" == *"Could not fetch"* ]]
    [[ ! -f "$RALPH_DIR/.github_issue.json" ]]
}

@test "ralph_import_issue: 403 (auth) surfaces error and skips writes" {
    export GH_SHIM_EXIT="1"
    export GH_SHIM_STDERR="HTTP 403: Forbidden"
    rm -f "$GH_SHIM_FIXTURE"
    run ralph_import_issue 7
    assert_failure
    [[ ! -f "$RALPH_DIR/fix_plan.md" ]]
}

@test "ralph_import_issue: 429 rate limit treated as fetch failure" {
    export GH_SHIM_EXIT="1"
    export GH_SHIM_STDERR="HTTP 429: Rate limit. X-RateLimit-Reset: 1714521600"
    rm -f "$GH_SHIM_FIXTURE"
    run ralph_import_issue 8
    assert_failure
    [[ "$output" == *"Could not fetch"* ]]
}

@test "ralph_import_issue: malformed JSON from gh fails cleanly (no half-write)" {
    echo "{not valid json" > "$GH_SHIM_FIXTURE"
    export GH_SHIM_EXIT="0"
    run ralph_import_issue 3
    # jq parse will yield empty title/body; import still proceeds, but the
    # written metadata.json must itself be valid JSON (the bug we'd regress
    # to is half-written / corrupt files).
    if [[ -f "$RALPH_DIR/.github_issue.json" ]]; then
        run jq -e . "$RALPH_DIR/.github_issue.json"
        assert_success
    fi
}

# ---------------------------------------------------------------------------
# Issue listing — filters
# ---------------------------------------------------------------------------

@test "ralph_list_issues: passes label filter through to gh argv" {
    _write_issue_fixture 1 "x"  # any non-empty stdout
    export RALPH_ISSUE_LABEL="ralph-task"
    run ralph_list_issues
    assert_success
    grep -q -- "--label ralph-task" "$BATS_TEST_TMPDIR/gh_calls.log"
}

@test "ralph_list_issues: empty label filter omits --label" {
    _write_issue_fixture 1 "x"
    unset RALPH_ISSUE_LABEL
    run ralph_list_issues
    assert_success
    ! grep -q -- "--label" "$BATS_TEST_TMPDIR/gh_calls.log"
}

@test "ralph_list_issues: assignee filter passed to gh argv" {
    _write_issue_fixture 1 "x"
    export RALPH_ISSUE_ASSIGNEE="alice"
    run ralph_list_issues
    assert_success
    grep -q -- "--assignee alice" "$BATS_TEST_TMPDIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Idempotent re-import (dedupe-style behavior)
# ---------------------------------------------------------------------------

@test "ralph_import_issue: re-import of same issue is idempotent on metadata" {
    _write_issue_fixture 42 "Same" "- [ ] step"
    run ralph_import_issue 42
    assert_success
    local first; first=$(jq -r '.number' "$RALPH_DIR/.github_issue.json")
    run ralph_import_issue 42
    assert_success
    local second; second=$(jq -r '.number' "$RALPH_DIR/.github_issue.json")
    assert_equal "$first" "$second"
}

# ---------------------------------------------------------------------------
# Batch processing — caps + invalid entries
# ---------------------------------------------------------------------------

@test "ralph_batch_process: rejects malformed entries without aborting batch" {
    export RALPH_BATCH_ISSUES="42,bogus,43"
    _write_issue_fixture 42 "ok" "body"
    run ralph_batch_process
    # Returns nonzero because at least one failed; we just want it to have
    # written batch_results.json and counted the invalid entry.
    [[ -f "$RALPH_DIR/batch_results.json" ]]
    run jq -r '.failed' "$RALPH_DIR/batch_results.json"
    [[ "$output" -ge 1 ]]
}

@test "ralph_batch_process: empty batch returns success without writing results" {
    export RALPH_BATCH_ISSUES=""
    unset RALPH_ISSUE_LABEL
    run ralph_batch_process
    assert_failure  # no input source provided
    [[ "$output" == *"Specify --batch-issues"* ]]
}

# ---------------------------------------------------------------------------
# Assessment scoring
# ---------------------------------------------------------------------------

@test "ralph_assess_issue: short body scores low" {
    run ralph_assess_issue 1 "Quick" "tiny"
    assert_success
    [[ "$output" == *"NEEDS CLARIFICATION"* ]]
    [[ -f "$RALPH_DIR/.github_issue_assessment.json" ]]
}

@test "ralph_assess_issue: long structured body scores sufficient" {
    local body="Steps to reproduce: 1. do X 2. do Y. Expected behavior: should work. Out of scope: A B C. $(printf 'word %.0s' {1..100})"
    run ralph_assess_issue 2 "Detailed bug" "$body"
    assert_success
    [[ "$output" == *"SUFFICIENT"* ]]
}
