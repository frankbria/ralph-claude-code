#!/usr/bin/env bats
# Integration tests for ralph_enable.sh and ralph_enable_ci.sh
# Tests the full enable wizard flow and CI version

load '../helpers/test_helper'
load '../helpers/fixtures'

# Paths to scripts
RALPH_ENABLE="${BATS_TEST_DIRNAME}/../../ralph_enable.sh"
RALPH_ENABLE_CI="${BATS_TEST_DIRNAME}/../../ralph_enable_ci.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo (required by some detection)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HELP AND VERSION (4 tests)
# =============================================================================

@test "ralph enable --help shows usage information" {
    run bash "$RALPH_ENABLE" --help

    assert_success
    [[ "$output" =~ "Usage:" ]]
    [[ "$output" =~ "--from" ]]
    [[ "$output" =~ "--force" ]]
}

@test "ralph enable --version shows version" {
    run bash "$RALPH_ENABLE" --version

    assert_success
    [[ "$output" =~ "version" ]]
}

@test "ralph enable-ci --help shows usage information" {
    run bash "$RALPH_ENABLE_CI" --help

    assert_success
    [[ "$output" =~ "Usage:" ]]
    [[ "$output" =~ "Exit Codes:" ]]
}

@test "ralph enable-ci --version shows version" {
    run bash "$RALPH_ENABLE_CI" --version

    assert_success
    [[ "$output" =~ "version" ]]
}

# =============================================================================
# CI VERSION TESTS (8 tests)
# =============================================================================

@test "ralph enable-ci creates .ralph structure in empty directory" {
    run bash "$RALPH_ENABLE_CI" --from none

    assert_success
    [[ -d ".ralph" ]]
    [[ -f ".ralph/PROMPT.md" ]]
    [[ -f ".ralph/@fix_plan.md" ]]
    [[ -f ".ralph/@AGENT.md" ]]
}

@test "ralph enable-ci creates .ralphrc configuration" {
    run bash "$RALPH_ENABLE_CI" --from none

    assert_success
    [[ -f ".ralphrc" ]]
}

@test "ralph enable-ci detects TypeScript project" {
    cat > package.json << 'EOF'
{
    "name": "test-ts-project",
    "devDependencies": {
        "typescript": "^5.0.0"
    }
}
EOF

    run bash "$RALPH_ENABLE_CI" --from none

    assert_success
    grep -q "PROJECT_TYPE=\"typescript\"" .ralphrc
}

@test "ralph enable-ci detects Python project" {
    cat > pyproject.toml << 'EOF'
[project]
name = "test-python-project"
EOF

    run bash "$RALPH_ENABLE_CI" --from none

    assert_success
    grep -q "PROJECT_TYPE=\"python\"" .ralphrc
}

@test "ralph enable-ci respects --project-name override" {
    run bash "$RALPH_ENABLE_CI" --from none --project-name "custom-name"

    assert_success
    grep -q "PROJECT_NAME=\"custom-name\"" .ralphrc
}

@test "ralph enable-ci respects --project-type override" {
    run bash "$RALPH_ENABLE_CI" --from none --project-type "rust"

    assert_success
    grep -q "PROJECT_TYPE=\"rust\"" .ralphrc
}

@test "ralph enable-ci returns exit code 2 when already enabled" {
    # First enable
    bash "$RALPH_ENABLE_CI" --from none >/dev/null 2>&1

    # Second enable without force
    run bash "$RALPH_ENABLE_CI" --from none

    assert_equal "$status" 2
}

@test "ralph enable-ci --force overwrites existing configuration" {
    # First enable
    bash "$RALPH_ENABLE_CI" --from none --project-name "old-name" >/dev/null 2>&1

    # Second enable with force
    run bash "$RALPH_ENABLE_CI" --from none --force --project-name "new-name"

    assert_success
}

# =============================================================================
# JSON OUTPUT TESTS (3 tests)
# =============================================================================

@test "ralph enable-ci --json outputs valid JSON on success" {
    run bash "$RALPH_ENABLE_CI" --from none --json

    assert_success
    # Validate JSON structure
    echo "$output" | jq -e '.success == true'
    echo "$output" | jq -e '.project_name'
    echo "$output" | jq -e '.files_created'
}

@test "ralph enable-ci --json includes project info" {
    cat > package.json << 'EOF'
{"name": "json-test"}
EOF

    run bash "$RALPH_ENABLE_CI" --from none --json

    assert_success
    echo "$output" | jq -e '.project_name == "json-test"'
}

@test "ralph enable-ci --json returns proper structure when already enabled" {
    bash "$RALPH_ENABLE_CI" --from none >/dev/null 2>&1

    run bash "$RALPH_ENABLE_CI" --from none --json

    assert_equal "$status" 2
    echo "$output" | jq -e '.code == 2'
}

# =============================================================================
# PRD IMPORT TESTS (2 tests)
# =============================================================================

@test "ralph enable-ci imports tasks from PRD file" {
    mkdir -p docs
    cat > docs/requirements.md << 'EOF'
# Project Requirements

- [ ] Implement user authentication
- [ ] Add API endpoints
- [ ] Create database schema
EOF

    run bash "$RALPH_ENABLE_CI" --from prd --prd docs/requirements.md

    assert_success
    # Check that tasks were imported
    grep -q "authentication\|API\|database" .ralph/@fix_plan.md
}

@test "ralph enable-ci fails gracefully with missing PRD file" {
    run bash "$RALPH_ENABLE_CI" --from prd --prd nonexistent.md

    assert_failure
}

# =============================================================================
# IDEMPOTENCY TESTS (3 tests)
# =============================================================================

@test "ralph enable-ci is idempotent with force flag" {
    bash "$RALPH_ENABLE_CI" --from none >/dev/null 2>&1

    # Add a file to .ralph
    echo "custom file" > .ralph/custom.txt

    run bash "$RALPH_ENABLE_CI" --from none --force

    assert_success
    # Custom file should still exist (we don't delete extra files)
    [[ -f ".ralph/custom.txt" ]]
}

@test "ralph enable-ci preserves existing .ralph subdirectories" {
    bash "$RALPH_ENABLE_CI" --from none >/dev/null 2>&1

    # Add custom content
    echo "spec content" > .ralph/specs/custom_spec.md

    run bash "$RALPH_ENABLE_CI" --from none --force

    assert_success
    [[ -f ".ralph/specs/custom_spec.md" ]]
}

@test "ralph enable-ci does not overwrite existing files without force" {
    mkdir -p .ralph
    echo "original prompt" > .ralph/PROMPT.md
    echo "original fix plan" > .ralph/@fix_plan.md
    echo "original agent" > .ralph/@AGENT.md

    run bash "$RALPH_ENABLE_CI" --from none

    assert_equal "$status" 2
    # Verify original content preserved
    assert_equal "$(cat .ralph/PROMPT.md)" "original prompt"
}

# =============================================================================
# QUIET MODE TESTS (2 tests)
# =============================================================================

@test "ralph enable-ci --quiet suppresses output" {
    run bash "$RALPH_ENABLE_CI" --from none --quiet

    assert_success
    # Output should be minimal
    [[ -z "$output" ]] || [[ ! "$output" =~ "Detected" ]]
}

@test "ralph enable-ci --quiet still creates files" {
    run bash "$RALPH_ENABLE_CI" --from none --quiet

    assert_success
    [[ -f ".ralph/PROMPT.md" ]]
}
