#!/usr/bin/env bats
# Unit tests for lib/task_sources.sh
# Tests beads integration, GitHub integration, PRD extraction, and task normalization

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to task_sources.sh
TASK_SOURCES="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library
    source "$TASK_SOURCES"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# BEADS DETECTION (3 tests)
# =============================================================================

@test "check_beads_available returns false when no .beads directory" {
    run check_beads_available
    assert_failure
}

@test "check_beads_available returns false when bd command not found" {
    mkdir -p .beads
    # bd command likely won't exist in test environment
    if command -v bd &>/dev/null; then
        skip "bd command is available"
    fi
    run check_beads_available
    assert_failure
}

@test "get_beads_count returns 0 when beads unavailable" {
    run get_beads_count
    assert_output "0"
}

# =============================================================================
# GITHUB DETECTION (3 tests)
# =============================================================================

@test "check_github_available returns false when no gh command" {
    # gh command may not exist in test environment
    if ! command -v gh &>/dev/null; then
        run check_github_available
        assert_failure
    else
        skip "gh command is available"
    fi
}

@test "check_github_available returns false when not in git repo" {
    run check_github_available
    assert_failure
}

@test "get_github_issue_count returns 0 when GitHub unavailable" {
    run get_github_issue_count
    assert_output "0"
}

# =============================================================================
# PRD EXTRACTION (6 tests)
# =============================================================================

@test "extract_prd_tasks extracts checkbox items" {
    cat > prd.md << 'EOF'
# Requirements

- [ ] Implement user authentication
- [x] Set up database
- [ ] Add API endpoints
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "Implement user authentication" ]]
    [[ "$output" =~ "Add API endpoints" ]]
}

@test "extract_prd_tasks extracts numbered list items" {
    cat > prd.md << 'EOF'
# Requirements

1. Implement user authentication
2. Set up database
3. Add API endpoints
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "Implement user authentication" ]]
}

@test "extract_prd_tasks returns empty for file without tasks" {
    cat > prd.md << 'EOF'
# Empty Document

This document has no tasks.
EOF

    run extract_prd_tasks "prd.md"

    assert_success
}

@test "extract_prd_tasks returns error for missing file" {
    run extract_prd_tasks "nonexistent.md"
    assert_failure
}

@test "extract_prd_tasks normalizes checked items to unchecked" {
    cat > prd.md << 'EOF'
- [x] Completed task
- [X] Another completed
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "[ ]" ]]
    [[ ! "$output" =~ "[x]" ]]
    [[ ! "$output" =~ "[X]" ]]
}

@test "extract_prd_tasks limits output to 30 tasks" {
    # Create PRD with 40 tasks
    {
        echo "# Tasks"
        for i in {1..40}; do
            echo "- [ ] Task $i"
        done
    } > prd.md

    run extract_prd_tasks "prd.md"

    # Count the number of task lines
    task_count=$(echo "$output" | grep -c '^\- \[' || echo "0")
    [[ "$task_count" -le 30 ]]
}

# =============================================================================
# TASK NORMALIZATION (5 tests)
# =============================================================================

@test "normalize_tasks converts bullet points to checkboxes" {
    input="- First task
* Second task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] First task" ]]
    [[ "$output" =~ "- [ ] Second task" ]]
}

@test "normalize_tasks converts numbered items to checkboxes" {
    input="1. First task
2. Second task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ]" ]]
}

@test "normalize_tasks preserves existing checkboxes" {
    input="- [ ] Already a task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] Already a task" ]]
}

@test "normalize_tasks handles plain text lines" {
    input="Plain text task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] Plain text task" ]]
}

@test "normalize_tasks handles empty input" {
    run normalize_tasks ""
    assert_success
}

# =============================================================================
# TASK PRIORITIZATION (3 tests)
# =============================================================================

@test "prioritize_tasks puts critical tasks in High Priority" {
    input="- [ ] Critical bug fix
- [ ] Normal task"

    output=$(prioritize_tasks "$input" || true)

    [[ "$output" =~ "## High Priority" ]]
    # Critical should be before Medium
    high_section="${output%%## Medium*}"
    [[ "$high_section" =~ "Critical bug fix" ]]
}

@test "prioritize_tasks puts optional tasks in Low Priority" {
    input="- [ ] Nice to have feature
- [ ] Normal task"

    run prioritize_tasks "$input"

    assert_success
    [[ "$output" =~ "## Low Priority" ]]
    low_section="${output##*## Low Priority}"
    [[ "$low_section" =~ "Nice to have" ]]
}

@test "prioritize_tasks puts regular tasks in Medium Priority" {
    input="- [ ] Regular task"

    output=$(prioritize_tasks "$input" || true)

    [[ "$output" =~ "## Medium Priority" ]]
}

# =============================================================================
# COMBINED IMPORT (3 tests)
# =============================================================================

@test "import_tasks_from_sources handles prd source" {
    mkdir -p docs
    cat > docs/prd.md << 'EOF'
# Requirements
- [ ] Test task
EOF

    run import_tasks_from_sources "prd" "docs/prd.md" ""

    assert_success
    [[ "$output" =~ "Test task" ]]
}

@test "import_tasks_from_sources handles empty sources" {
    run import_tasks_from_sources "" "" ""

    assert_failure
}

@test "import_tasks_from_sources handles none source" {
    run import_tasks_from_sources "none" "" ""

    # 'none' doesn't import anything, so fails
    assert_failure
}

# =============================================================================
# GITHUB FETCH — limit and pagination (4 tests)
# =============================================================================
#
# These tests mock the `gh` CLI with a fake binary on PATH that records its
# args to a file and writes fixture JSON based on subcommand. They also set
# up a minimal git repo with a github.com remote so check_github_available
# returns success.

# Helper: build a mock gh binary that records args and emits fixture JSON
_mock_gh_with_fixture() {
    local api_fixture="$1"
    local list_fixture="$2"
    local args_file="$TEST_DIR/gh_args"

    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/gh" << EOF
#!/bin/bash
# Record each invocation's args on its own line (append)
printf '%s\n' "\$*" >> "$args_file"
case "\$1" in
    api)
        cat <<'JSON'
$api_fixture
JSON
        ;;
    issue)
        cat <<'JSON'
$list_fixture
JSON
        ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/gh"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

# Helper: fake a git repo with github.com remote so check_github_available passes
_fake_github_repo() {
    git init -q . >/dev/null 2>&1
    git remote add origin https://github.com/fake/repo.git >/dev/null 2>&1
}

@test "fetch_github_tasks with limit=0 uses gh api with --paginate" {
    _fake_github_repo
    _mock_gh_with_fixture \
        '[{"number":1,"title":"issue one"},{"number":2,"title":"issue two"}]' \
        '[]'

    run fetch_github_tasks "" "0"
    assert_success

    # Verify gh api was invoked with --paginate and expected form fields
    local args
    args=$(cat "$TEST_DIR/gh_args")
    [[ "$args" == *"api"* ]]
    [[ "$args" == *"--paginate"* ]]
    [[ "$args" == *"repos/{owner}/{repo}/issues"* ]]
    [[ "$args" == *"state=open"* ]]
    [[ "$args" == *"per_page=100"* ]]
    # Must NOT fall back to the bounded `issue list` path
    [[ "$args" != *"issue list"* ]]
}

@test "fetch_github_tasks with limit=0 filters out pull requests" {
    _fake_github_repo
    # Mixed response: two issues and one PR (PRs have a .pull_request field)
    _mock_gh_with_fixture \
        '[{"number":1,"title":"real issue"},{"number":2,"title":"a pull request","pull_request":{"url":"x"}},{"number":3,"title":"another issue"}]' \
        '[]'

    run fetch_github_tasks "" "0"
    assert_success

    [[ "$output" == *"#1"* ]]
    [[ "$output" == *"real issue"* ]]
    [[ "$output" == *"#3"* ]]
    [[ "$output" == *"another issue"* ]]
    # The PR must be filtered out
    [[ "$output" != *"#2"* ]]
    [[ "$output" != *"pull request"* ]]
}

@test "fetch_github_tasks with positive limit uses gh issue list" {
    _fake_github_repo
    _mock_gh_with_fixture \
        '[]' \
        '[{"number":42,"title":"bounded fetch"}]'

    run fetch_github_tasks "" "5"
    assert_success

    local args
    args=$(cat "$TEST_DIR/gh_args")
    # Must use the bounded list path, not the paginated api path
    [[ "$args" == *"issue list"* ]]
    [[ "$args" == *"--limit 5"* ]]
    [[ "$args" != *"--paginate"* ]]
    [[ "$output" == *"#42"* ]]
}

@test "fetch_github_tasks with limit=0 plumbs label as URL-encoded field" {
    _fake_github_repo
    _mock_gh_with_fixture '[]' '[]'

    run fetch_github_tasks "needs-triage" "0"
    assert_success

    local args
    args=$(cat "$TEST_DIR/gh_args")
    # -f labels=needs-triage ensures gh URL-encodes values with spaces/specials
    [[ "$args" == *"labels=needs-triage"* ]]
}
