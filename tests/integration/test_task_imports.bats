#!/usr/bin/env bats
# Integration tests for task import functions in lib/task_sources.sh
# Covers beads (bd), GitHub Issues (gh), and combined imports.
# Closes #152 — exercises the parsing/filtering paths that previously had no
# coverage, including the PR #150 fixes (bd list --status flag, jq != → | not,
# jq guards for missing id/title).

load '../helpers/test_helper'
load '../helpers/fixtures'

TASK_SOURCES="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    ORIGINAL_DIR="$(pwd)"
    cd "$TEST_DIR"

    # Git repo with a github.com remote — required by check_github_available
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "https://github.com/test/repo.git"

    # .beads directory — required by check_beads_available
    mkdir -p .beads

    # Mock command directory takes priority over real bd/gh
    MOCK_BIN_DIR="$TEST_DIR/.mock_bin"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    # Default: install passing mocks; individual tests override as needed.
    install_default_mocks

    # Source library AFTER PATH is set so command -v sees the mocks.
    source "$TASK_SOURCES"
}

teardown() {
    cd "$ORIGINAL_DIR" 2>/dev/null || cd /
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Mock builders. Each writes a small shell script into $MOCK_BIN_DIR and makes
# it executable. Tests reach in and rewrite individual mocks to change behavior
# (e.g., return malformed JSON, fail, capture arguments).
# -----------------------------------------------------------------------------

install_default_mocks() {
    install_mock_bd_json "$(create_sample_beads_json)"
    install_mock_gh_json "$(create_sample_github_json)"
    install_mock_gh_auth_ok
}

# bd that returns a fixed JSON payload to any `bd list --json ...` invocation
# and an empty body to other invocations. Args are appended to .bd_args for
# verification.
install_mock_bd_json() {
    local payload="$1"
    local payload_file="$TEST_DIR/.bd_payload"
    printf '%s' "$payload" > "$payload_file"
    cat > "$MOCK_BIN_DIR/bd" <<MOCK_EOF
#!/bin/bash
echo "\$@" >> "$TEST_DIR/.bd_args"
if [[ "\$*" == *"--json"* ]]; then
    cat "$payload_file"
fi
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN_DIR/bd"
}

# bd that fails on --json but returns text on plain `bd list`. Used to exercise
# the text-parsing fallback path in fetch_beads_tasks.
install_mock_bd_text_fallback() {
    local text_payload="$1"
    local text_file="$TEST_DIR/.bd_text"
    printf '%s' "$text_payload" > "$text_file"
    cat > "$MOCK_BIN_DIR/bd" <<MOCK_EOF
#!/bin/bash
echo "\$@" >> "$TEST_DIR/.bd_args"
if [[ "\$*" == *"--json"* ]]; then
    exit 1
fi
cat "$text_file"
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN_DIR/bd"
}

install_mock_gh_json() {
    local payload="$1"
    local payload_file="$TEST_DIR/.gh_payload"
    printf '%s' "$payload" > "$payload_file"
    cat > "$MOCK_BIN_DIR/gh" <<MOCK_EOF
#!/bin/bash
echo "\$@" >> "$TEST_DIR/.gh_args"
case "\$1" in
    auth)
        # auth status — succeed
        exit 0
        ;;
    issue)
        # issue list — return canned JSON
        cat "$payload_file"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
    chmod +x "$MOCK_BIN_DIR/gh"
}

# Distinct helper to keep the auth-status mock decoupled from JSON mocks
install_mock_gh_auth_ok() {
    : # gh mock already handles `auth status` — keep this as a hook
}

# Read the last (or any) recorded command line for a mock
last_bd_args() {
    [[ -f "$TEST_DIR/.bd_args" ]] && tail -n1 "$TEST_DIR/.bd_args" || echo ""
}
last_gh_args() {
    [[ -f "$TEST_DIR/.gh_args" ]] && tail -n1 "$TEST_DIR/.gh_args" || echo ""
}

# -----------------------------------------------------------------------------
# fetch_beads_tasks — JSON parsing (4 tests)
# -----------------------------------------------------------------------------

@test "fetch_beads_tasks parses JSON output and emits markdown tasks" {
    run fetch_beads_tasks
    assert_success
    [[ "$output" == *"- [ ] [proj-001] Fix authentication bug"* ]]
    [[ "$output" == *"- [ ] [proj-002] Add dark mode toggle"* ]]
    [[ "$output" == *"- [ ] [proj-004] Write docs"* ]]
}

@test "fetch_beads_tasks filters closed entries (PR #150 regression: != → | not)" {
    run fetch_beads_tasks
    assert_success
    [[ "$output" != *"proj-003"* ]]
    [[ "$output" != *"Migrate old API"* ]]
}

@test "fetch_beads_tasks handles empty JSON array without error" {
    install_mock_bd_json "$(create_sample_beads_json_empty)"
    run fetch_beads_tasks
    assert_success
    [[ -z "$output" ]]
}

@test "fetch_beads_tasks filters entries with missing id/title (PR #150 jq guards)" {
    install_mock_bd_json "$(create_sample_beads_json_missing_fields)"
    run fetch_beads_tasks
    assert_success
    [[ "$output" == *"proj-001"* ]]
    [[ "$output" == *"Has both fields"* ]]
    # Empty-id and empty-title entries must be dropped
    [[ "$output" != *"Missing id"* ]]
    [[ "$output" != *"No id key"* ]]
    # proj-003 has empty title — drop it
    [[ "$output" != *"proj-003"* ]]
    # proj-005 has no title key at all — drop it
    [[ "$output" != *"proj-005"* ]]
}

# -----------------------------------------------------------------------------
# fetch_beads_tasks — text-fallback path (2 tests)
# -----------------------------------------------------------------------------

@test "fetch_beads_tasks falls back to text parsing when JSON fails" {
    install_mock_bd_text_fallback "$(create_sample_beads_text)"
    run fetch_beads_tasks
    assert_success
    [[ "$output" == *"proj-001"* ]]
    [[ "$output" == *"Fix authentication bug"* ]]
}

@test "fetch_beads_tasks text fallback emits markdown checkbox format" {
    install_mock_bd_text_fallback "$(create_sample_beads_text)"
    run fetch_beads_tasks
    assert_success
    [[ "$output" == *"- [ ] [proj-001]"* ]]
}

# -----------------------------------------------------------------------------
# fetch_beads_tasks — status filter forwarding (3 tests)
# -----------------------------------------------------------------------------

@test "fetch_beads_tasks default filter passes --status open to bd" {
    run fetch_beads_tasks
    assert_success
    [[ "$(last_bd_args)" == *"--status open"* ]]
}

@test "fetch_beads_tasks in_progress filter passes --status in_progress" {
    run fetch_beads_tasks "in_progress"
    assert_success
    [[ "$(last_bd_args)" == *"--status in_progress"* ]]
}

@test "fetch_beads_tasks all filter passes --all and not --status" {
    run fetch_beads_tasks "all"
    assert_success
    [[ "$(last_bd_args)" == *"--all"* ]]
    [[ "$(last_bd_args)" != *"--status"* ]]
}

# -----------------------------------------------------------------------------
# get_beads_count (2 tests)
# -----------------------------------------------------------------------------

@test "get_beads_count returns count of non-closed entries" {
    # Sample fixture has 4 entries, one of which is closed → 3 open
    run get_beads_count
    assert_output "3"
}

@test "get_beads_count returns 0 for empty JSON" {
    install_mock_bd_json "$(create_sample_beads_json_empty)"
    run get_beads_count
    assert_output "0"
}

# -----------------------------------------------------------------------------
# fetch_github_tasks — JSON parsing (3 tests)
# -----------------------------------------------------------------------------

@test "fetch_github_tasks parses issue JSON and emits #-prefixed markdown" {
    run fetch_github_tasks
    assert_success
    [[ "$output" == *"- [ ] [#123] Add feature X"* ]]
    [[ "$output" == *"- [ ] [#124] Fix bug Y"* ]]
    [[ "$output" == *"- [ ] [#125] Refactor Z"* ]]
}

@test "fetch_github_tasks handles empty issue list without error" {
    install_mock_gh_json "$(create_sample_github_json_empty)"
    run fetch_github_tasks
    assert_success
    [[ -z "$output" ]]
}

@test "fetch_github_tasks emits issues regardless of label content" {
    install_mock_gh_json "$(create_sample_github_json_with_labels)"
    run fetch_github_tasks "ralph-task"
    assert_success
    [[ "$output" == *"- [ ] [#201]"* ]]
    [[ "$output" == *"- [ ] [#202]"* ]]
}

# -----------------------------------------------------------------------------
# fetch_github_tasks — argument forwarding (3 tests)
# -----------------------------------------------------------------------------

@test "fetch_github_tasks default limit is 50 and no --label passed" {
    run fetch_github_tasks
    assert_success
    [[ "$(last_gh_args)" == *"--limit 50"* ]]
    [[ "$(last_gh_args)" != *"--label"* ]]
}

@test "fetch_github_tasks forwards --label when provided" {
    run fetch_github_tasks "ralph-task"
    assert_success
    [[ "$(last_gh_args)" == *"--label ralph-task"* ]]
}

@test "fetch_github_tasks forwards custom --limit" {
    run fetch_github_tasks "" "10"
    assert_success
    [[ "$(last_gh_args)" == *"--limit 10"* ]]
}

# -----------------------------------------------------------------------------
# get_github_issue_count (2 tests)
# -----------------------------------------------------------------------------

@test "get_github_issue_count returns length of issue array" {
    run get_github_issue_count
    assert_output "3"
}

@test "get_github_issue_count forwards --label" {
    run get_github_issue_count "bug"
    assert_success
    [[ "$(last_gh_args)" == *"--label bug"* ]]
}

# -----------------------------------------------------------------------------
# import_tasks_from_sources — combined paths (3 tests)
# -----------------------------------------------------------------------------

@test "import_tasks_from_sources imports from beads source only" {
    run import_tasks_from_sources "beads" "" ""
    assert_success
    [[ "$output" == *"proj-001"* ]]
    [[ "$output" != *"Add feature X"* ]]
}

@test "import_tasks_from_sources imports from github source only" {
    run import_tasks_from_sources "github" "" ""
    assert_success
    [[ "$output" == *"#123"* ]]
    [[ "$output" != *"proj-001"* ]]
}

@test "import_tasks_from_sources combines beads + github" {
    run import_tasks_from_sources "beads github" "" ""
    assert_success
    [[ "$output" == *"proj-001"* ]]
    [[ "$output" == *"#123"* ]]
}
