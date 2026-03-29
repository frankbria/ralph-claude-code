#!/usr/bin/env bats
# Unit tests for ralph_release_notes.sh
# Tests: argument parsing, commit categorization, PR extraction, output format

load '../helpers/test_helper'

# Path to the release notes script
RELEASE_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_release_notes.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize a git repo with conventional commits
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit
    echo "init" > README.md
    git add README.md
    git commit -m "chore: initial commit" > /dev/null 2>&1
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# --- Helper: add a commit with a given message ---
add_commit() {
    local msg="$1"
    echo "$msg" >> history.txt
    git add history.txt
    git commit -m "$msg" > /dev/null 2>&1
}

# ============================
# Help / usage
# ============================

@test "release-notes: --help prints usage and exits 0" {
    run bash "$RELEASE_SCRIPT" --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--from"* ]]
    [[ "$output" == *"--to"* ]]
}

@test "release-notes: unknown flag exits with error" {
    run bash "$RELEASE_SCRIPT" --bad-flag
    assert_failure
    [[ "$output" == *"Unknown option"* ]]
}

# ============================
# Default tag detection (--from)
# ============================

@test "release-notes: defaults to last tag when no --from given" {
    add_commit "feat: first feature"
    git tag v1.0.0
    add_commit "feat: second feature"

    run bash "$RELEASE_SCRIPT"
    assert_success
    # Should only show commits after v1.0.0
    [[ "$output" == *"second feature"* ]]
    [[ "$output" != *"first feature"* ]]
}

@test "release-notes: falls back to root commit when no tags exist" {
    add_commit "feat: a feature"

    run bash "$RELEASE_SCRIPT"
    assert_success
    # Should include commits (initial + the feature)
    [[ "$output" == *"a feature"* ]]
}

@test "release-notes: picks latest tag when multiple tags exist" {
    add_commit "feat: old feature"
    git tag v0.1.0
    add_commit "fix: a bugfix"
    git tag v0.2.0
    add_commit "feat: new feature"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"new feature"* ]]
    [[ "$output" != *"old feature"* ]]
    [[ "$output" != *"a bugfix"* ]]
}

# ============================
# --from / --to argument parsing
# ============================

@test "release-notes: --from overrides default tag" {
    add_commit "feat: first"
    local from_hash
    from_hash=$(git rev-parse HEAD)
    add_commit "feat: second"
    add_commit "fix: third"

    run bash "$RELEASE_SCRIPT" --from "$from_hash"
    assert_success
    [[ "$output" == *"second"* ]]
    [[ "$output" == *"third"* ]]
    [[ "$output" != *"first"* ]]
}

@test "release-notes: --to limits the end ref" {
    add_commit "feat: first"
    local to_hash
    to_hash=$(git rev-parse HEAD)
    add_commit "feat: second"

    run bash "$RELEASE_SCRIPT" --from "$(git rev-list --max-parents=0 HEAD)" --to "$to_hash"
    assert_success
    [[ "$output" == *"first"* ]]
    [[ "$output" != *"second"* ]]
}

@test "release-notes: --version sets custom header label" {
    add_commit "feat: something"

    run bash "$RELEASE_SCRIPT" --version "v2.0.0"
    assert_success
    [[ "$output" == *"# v2.0.0"* ]]
}

@test "release-notes: defaults to 'Unreleased' when --to is HEAD" {
    add_commit "feat: something"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"# Unreleased"* ]]
}

@test "release-notes: --to non-HEAD uses ref as version label" {
    add_commit "feat: first"
    git tag v3.0.0
    add_commit "feat: second"
    git tag v4.0.0

    run bash "$RELEASE_SCRIPT" --from v3.0.0 --to v4.0.0
    assert_success
    [[ "$output" == *"# v4.0.0"* ]]
}

# ============================
# Commit categorization
# ============================

@test "release-notes: feat commits appear under Features" {
    add_commit "feat: add login page"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Features"* ]]
    [[ "$output" == *"add login page"* ]]
}

@test "release-notes: fix commits appear under Bug Fixes" {
    add_commit "fix: resolve null pointer"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Bug Fixes"* ]]
    [[ "$output" == *"resolve null pointer"* ]]
}

@test "release-notes: refactor commits appear under Refactoring" {
    add_commit "refactor: simplify auth module"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Refactoring"* ]]
    [[ "$output" == *"simplify auth module"* ]]
}

@test "release-notes: ci commits appear under CI/CD" {
    add_commit "ci: add GitHub Actions workflow"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## CI/CD"* ]]
    [[ "$output" == *"add GitHub Actions workflow"* ]]
}

@test "release-notes: chore commits appear under Chores" {
    add_commit "chore: update dependencies"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Chores"* ]]
    [[ "$output" == *"update dependencies"* ]]
}

@test "release-notes: docs commits appear under Documentation" {
    add_commit "docs: add API reference"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Documentation"* ]]
    [[ "$output" == *"add API reference"* ]]
}

@test "release-notes: test commits categorized under Chores" {
    add_commit "test: add unit tests for auth"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Chores"* ]]
    [[ "$output" == *"add unit tests for auth"* ]]
}

@test "release-notes: non-conventional commits appear under Other" {
    add_commit "random message without prefix"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Other"* ]]
    [[ "$output" == *"random message without prefix"* ]]
}

@test "release-notes: scoped conventional commits are categorized correctly" {
    add_commit "feat(auth): implement OAuth2"
    add_commit "fix(db): connection pool leak"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Features"* ]]
    [[ "$output" == *"implement OAuth2"* ]]
    [[ "$output" == *"## Bug Fixes"* ]]
    [[ "$output" == *"connection pool leak"* ]]
}

@test "release-notes: perf commits categorized under Features" {
    add_commit "perf: optimize query execution"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Features"* ]]
    [[ "$output" == *"optimize query execution"* ]]
}

# ============================
# PR number extraction
# ============================

@test "release-notes: extracts PR number from commit message" {
    add_commit "feat: add search (#42)"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"(#42)"* ]]
}

@test "release-notes: handles commit without PR number" {
    add_commit "feat: add search"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"add search"* ]]
    [[ "$output" != *"(#"* ]]
}

@test "release-notes: PR number appears once not duplicated" {
    add_commit "fix(api): handle timeout (#99)"

    run bash "$RELEASE_SCRIPT"
    assert_success
    # Count occurrences of (#99) — should be exactly 1
    local count
    count=$(echo "$output" | grep -o "(#99)" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
}

# ============================
# Merge commit filtering
# ============================

@test "release-notes: merge commits are excluded" {
    add_commit "feat: real work"
    # Simulate a merge commit message
    echo "merge" >> history.txt
    git add history.txt
    git commit -m "Merge PR #100: feat: some merged feature" > /dev/null 2>&1

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"real work"* ]]
    [[ "$output" != *"some merged feature"* ]]
}

# ============================
# Empty range handling
# ============================

@test "release-notes: empty range outputs message to stderr" {
    # HEAD..HEAD has no commits
    run bash "$RELEASE_SCRIPT" --from HEAD --to HEAD
    # Should exit 0 with stderr message
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No commits found"* ]]
}

# ============================
# Markdown output format
# ============================

@test "release-notes: output starts with H1 version header" {
    add_commit "feat: something"

    run bash "$RELEASE_SCRIPT" --version "v1.0.0"
    assert_success
    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" == "# v1.0.0"* ]]
}

@test "release-notes: output includes date in header" {
    add_commit "feat: something"
    local today
    today=$(date +%Y-%m-%d)

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"$today"* ]]
}

@test "release-notes: output includes range description" {
    add_commit "feat: something"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"Changes from"* ]]
    [[ "$output" == *"to \`HEAD\`"* ]]
}

@test "release-notes: each entry includes short hash" {
    add_commit "feat: add feature X"
    local short_hash
    short_hash=$(git log --pretty=format:"%h" -1)

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"$short_hash"* ]]
}

@test "release-notes: entries formatted as markdown list items" {
    add_commit "feat: list item test"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"- list item test"* ]]
}

# ============================
# Multiple categories in one run
# ============================

@test "release-notes: multiple categories grouped correctly" {
    add_commit "feat: new feature"
    add_commit "fix: bug fix"
    add_commit "docs: update readme"
    add_commit "ci: add workflow"

    run bash "$RELEASE_SCRIPT"
    assert_success
    [[ "$output" == *"## Features"* ]]
    [[ "$output" == *"## Bug Fixes"* ]]
    [[ "$output" == *"## Documentation"* ]]
    [[ "$output" == *"## CI/CD"* ]]
}

@test "release-notes: sections appear in correct order" {
    add_commit "ci: workflow"
    add_commit "docs: readme"
    add_commit "fix: bugfix"
    add_commit "feat: feature"

    run bash "$RELEASE_SCRIPT"
    assert_success
    # Features should appear before Bug Fixes, etc.
    local feat_pos fix_pos docs_pos ci_pos
    feat_pos=$(echo "$output" | grep -n "## Features" | head -1 | cut -d: -f1)
    fix_pos=$(echo "$output" | grep -n "## Bug Fixes" | head -1 | cut -d: -f1)
    docs_pos=$(echo "$output" | grep -n "## Documentation" | head -1 | cut -d: -f1)
    ci_pos=$(echo "$output" | grep -n "## CI/CD" | head -1 | cut -d: -f1)
    [[ "$feat_pos" -lt "$fix_pos" ]]
    [[ "$fix_pos" -lt "$ci_pos" ]]
    [[ "$ci_pos" -lt "$docs_pos" ]]
}
