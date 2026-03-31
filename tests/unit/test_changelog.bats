#!/usr/bin/env bats
# Unit tests for ralph_changelog.sh
# Tests: full multi-tag changelog, unreleased-only, --output, --dry-run,
#        empty history, no tags, single-tag, merge filtering, section ordering

load '../helpers/test_helper'

CHANGELOG_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_changelog.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    echo "init" > README.md
    git add README.md
    git commit -m "chore: initial commit" > /dev/null 2>&1
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

add_commit() {
    local msg="$1"
    echo "$msg" >> history.txt
    git add history.txt
    git commit -m "$msg" > /dev/null 2>&1
}

# ============================
# Help / usage
# ============================

@test "changelog: --help prints usage and exits 0" {
    run bash "$CHANGELOG_SCRIPT" --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--output"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--unreleased-only"* ]]
}

@test "changelog: unknown flag exits with error" {
    run bash "$CHANGELOG_SCRIPT" --bad-flag
    assert_failure
    [[ "$output" == *"Unknown option"* ]]
}

@test "changelog: unsupported format exits with error" {
    run bash "$CHANGELOG_SCRIPT" --format json --dry-run
    assert_failure
    [[ "$output" == *"Unsupported format"* ]]
}

# ============================
# Full multi-tag changelog
# ============================

@test "changelog: generates sections for multiple tags" {
    add_commit "feat: feature for v1"
    git tag v1.0.0
    add_commit "fix: bugfix for v2"
    git tag v2.0.0
    add_commit "feat: new unreleased feature"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"# Unreleased"* ]]
    [[ "$output" == *"# v2.0.0"* ]]
    [[ "$output" == *"# v1.0.0"* ]]
    [[ "$output" == *"new unreleased feature"* ]]
    [[ "$output" == *"bugfix for v2"* ]]
    [[ "$output" == *"feature for v1"* ]]
}

@test "changelog: tags appear in newest-first order" {
    add_commit "feat: alpha"
    git tag v1.0.0
    add_commit "feat: beta"
    git tag v2.0.0
    add_commit "feat: gamma"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success

    local unreleased_pos v2_pos v1_pos
    unreleased_pos=$(echo "$output" | grep -n "# Unreleased" | head -1 | cut -d: -f1)
    v2_pos=$(echo "$output" | grep -n "# v2.0.0" | head -1 | cut -d: -f1)
    v1_pos=$(echo "$output" | grep -n "# v1.0.0" | head -1 | cut -d: -f1)
    [[ "$unreleased_pos" -lt "$v2_pos" ]]
    [[ "$v2_pos" -lt "$v1_pos" ]]
}

@test "changelog: three tags produce four sections (unreleased + 3 tags)" {
    add_commit "feat: one"
    git tag v1.0.0
    add_commit "feat: two"
    git tag v2.0.0
    add_commit "feat: three"
    git tag v3.0.0
    add_commit "feat: four"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success

    local count
    count=$(echo "$output" | grep -c "^# " || true)
    [[ "$count" -eq 4 ]]
}

# ============================
# Unreleased-only mode
# ============================

@test "changelog: --unreleased-only shows only unreleased section" {
    add_commit "feat: tagged feature"
    git tag v1.0.0
    add_commit "feat: unreleased feature"

    run bash "$CHANGELOG_SCRIPT" --unreleased-only --dry-run
    assert_success
    [[ "$output" == *"# Unreleased"* ]]
    [[ "$output" == *"unreleased feature"* ]]
    [[ "$output" != *"# v1.0.0"* ]]
    [[ "$output" != *"tagged feature"* ]]
}

@test "changelog: --unreleased-only with no new commits prints stderr message" {
    add_commit "feat: tagged"
    git tag v1.0.0

    run bash "$CHANGELOG_SCRIPT" --unreleased-only --dry-run
    [[ "$output" == *"No unreleased changes found"* ]]
}

# ============================
# --output flag
# ============================

@test "changelog: --output writes to specified file" {
    add_commit "feat: a feature"
    git tag v1.0.0
    add_commit "fix: a fix"

    run bash "$CHANGELOG_SCRIPT" --output custom_changelog.md
    assert_success
    [[ -f "custom_changelog.md" ]]
    local content
    content=$(cat custom_changelog.md)
    [[ "$content" == *"# Unreleased"* ]]
    [[ "$content" == *"a fix"* ]]
}

@test "changelog: default output writes to CHANGELOG.md" {
    add_commit "feat: something"

    run bash "$CHANGELOG_SCRIPT"
    assert_success
    [[ -f "CHANGELOG.md" ]]
}

# ============================
# --dry-run flag
# ============================

@test "changelog: --dry-run prints to stdout and does not create file" {
    add_commit "feat: dry run test"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"dry run test"* ]]
    [[ ! -f "CHANGELOG.md" ]]
}

@test "changelog: --dry-run combined with --output does not create file" {
    add_commit "feat: test"

    run bash "$CHANGELOG_SCRIPT" --dry-run --output custom.md
    assert_success
    [[ ! -f "custom.md" ]]
}

# ============================
# No tags (repo with no tags)
# ============================

@test "changelog: repo with no tags generates unreleased section from root" {
    add_commit "feat: first feature"
    add_commit "fix: first fix"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"# Unreleased"* ]]
    [[ "$output" == *"first feature"* ]]
    [[ "$output" == *"first fix"* ]]
}

@test "changelog: repo with no tags has no versioned sections" {
    add_commit "feat: solo"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success

    local h1_count
    h1_count=$(echo "$output" | grep -c "^# " || true)
    [[ "$h1_count" -eq 1 ]]
}

# ============================
# Single tag
# ============================

@test "changelog: single tag repo has unreleased + one tag section" {
    add_commit "feat: tagged feature"
    git tag v1.0.0
    add_commit "feat: unreleased"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"# Unreleased"* ]]
    [[ "$output" == *"# v1.0.0"* ]]
}

@test "changelog: single tag with no unreleased commits" {
    add_commit "feat: tagged only"
    git tag v1.0.0

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"# v1.0.0"* ]]
    [[ "$output" == *"tagged only"* ]]
}

# ============================
# Empty history edge case
# ============================

@test "changelog: empty range (HEAD..HEAD) produces stderr message" {
    # Only the initial commit, tagged at HEAD, no unreleased
    git tag v1.0.0

    run bash "$CHANGELOG_SCRIPT" --unreleased-only --dry-run
    [[ "$output" == *"No unreleased changes found"* ]]
}

# ============================
# Merge commit filtering
# ============================

@test "changelog: merge commits are excluded from changelog" {
    add_commit "feat: real work"
    git tag v1.0.0
    add_commit "feat: more work"
    echo "merge" >> history.txt
    git add history.txt
    git commit -m "Merge PR #50: feat: merged feature" > /dev/null 2>&1

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"more work"* ]]
    [[ "$output" != *"merged feature"* ]]
}

# ============================
# Section ordering
# ============================

@test "changelog: sections within a version follow canonical order" {
    add_commit "ci: pipeline"
    add_commit "docs: readme"
    add_commit "fix: bugfix"
    add_commit "feat: feature"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success

    local feat_pos fix_pos ci_pos docs_pos
    feat_pos=$(echo "$output" | grep -n "## Features" | head -1 | cut -d: -f1)
    fix_pos=$(echo "$output" | grep -n "## Bug Fixes" | head -1 | cut -d: -f1)
    ci_pos=$(echo "$output" | grep -n "## CI/CD" | head -1 | cut -d: -f1)
    docs_pos=$(echo "$output" | grep -n "## Documentation" | head -1 | cut -d: -f1)
    [[ "$feat_pos" -lt "$fix_pos" ]]
    [[ "$fix_pos" -lt "$ci_pos" ]]
    [[ "$ci_pos" -lt "$docs_pos" ]]
}

# ============================
# --from-tag flag
# ============================

@test "changelog: --from-tag limits changelog to tags from that point" {
    add_commit "feat: old feature"
    git tag v1.0.0
    add_commit "feat: mid feature"
    git tag v2.0.0
    add_commit "feat: new feature"
    git tag v3.0.0
    add_commit "feat: unreleased"

    run bash "$CHANGELOG_SCRIPT" --from-tag v2.0.0 --dry-run
    assert_success
    [[ "$output" == *"# v2.0.0"* ]]
    [[ "$output" == *"# v3.0.0"* ]]
    [[ "$output" != *"# v1.0.0"* ]]
    [[ "$output" != *"old feature"* ]]
}

@test "changelog: --from-tag with nonexistent tag warns and generates full changelog" {
    add_commit "feat: feature"
    git tag v1.0.0
    add_commit "feat: unreleased"

    run bash "$CHANGELOG_SCRIPT" --from-tag v99.0.0 --dry-run
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"# v1.0.0"* ]]
}

# ============================
# Commit categorization across tags
# ============================

@test "changelog: commits are categorized correctly in each tag section" {
    add_commit "feat: v1 feature"
    add_commit "fix: v1 fix"
    git tag v1.0.0
    add_commit "refactor: v2 refactor"
    add_commit "ci: v2 ci"
    git tag v2.0.0

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"## Features"* ]]
    [[ "$output" == *"v1 feature"* ]]
    [[ "$output" == *"## Bug Fixes"* ]]
    [[ "$output" == *"v1 fix"* ]]
    [[ "$output" == *"## Refactoring"* ]]
    [[ "$output" == *"v2 refactor"* ]]
    [[ "$output" == *"## CI/CD"* ]]
    [[ "$output" == *"v2 ci"* ]]
}

@test "changelog: PR numbers are preserved in changelog entries" {
    add_commit "feat: add search (#42)"
    git tag v1.0.0
    add_commit "fix: handle timeout (#99)"

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"(#42)"* ]]
    [[ "$output" == *"(#99)"* ]]
}

@test "changelog: each entry includes short commit hash" {
    add_commit "feat: hash test"
    local short_hash
    short_hash=$(git log --pretty=format:"%h" -1)

    run bash "$CHANGELOG_SCRIPT" --dry-run
    assert_success
    [[ "$output" == *"$short_hash"* ]]
}

# ============================
# Stderr messages
# ============================

@test "changelog: writes confirmation message to stderr when writing file" {
    add_commit "feat: something"

    run bash "$CHANGELOG_SCRIPT" --output test_cl.md
    assert_success
    [[ "$output" == *"Changelog written to test_cl.md"* ]]
}

@test "changelog: no changes produces stderr message" {
    # Only initial commit, tag it, nothing else
    git tag v1.0.0

    run bash "$CHANGELOG_SCRIPT" --dry-run
    [[ "$output" == *"No changes found"* ]] || [[ "$output" == *"# v1.0.0"* ]]
}
