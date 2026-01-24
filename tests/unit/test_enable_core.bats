#!/usr/bin/env bats
# Unit tests for lib/enable_core.sh
# Tests idempotency, safe file creation, project detection, and template generation

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to enable_core.sh
ENABLE_CORE="${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (disable set -e for testing)
    set +e
    source "$ENABLE_CORE"
    set -e
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# IDEMPOTENCY CHECKS (5 tests)
# =============================================================================

@test "check_existing_ralph returns 'none' when no .ralph directory exists" {
    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "none"
}

@test "check_existing_ralph returns 'complete' when all required files exist" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/@fix_plan.md
    echo "# Agent" > .ralph/@AGENT.md

    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "complete"
}

@test "check_existing_ralph returns 'partial' when some files are missing" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    # Missing @fix_plan.md and @AGENT.md

    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "partial"
    [[ " ${RALPH_MISSING_FILES[*]} " =~ ".ralph/@fix_plan.md" ]]
    [[ " ${RALPH_MISSING_FILES[*]} " =~ ".ralph/@AGENT.md" ]]
}

@test "is_ralph_enabled returns 0 when fully enabled" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/@fix_plan.md
    echo "# Agent" > .ralph/@AGENT.md

    run is_ralph_enabled
    assert_success
}

@test "is_ralph_enabled returns 1 when not enabled" {
    run is_ralph_enabled
    assert_failure
}

# =============================================================================
# SAFE FILE OPERATIONS (5 tests)
# =============================================================================

@test "safe_create_file creates file that doesn't exist" {
    run safe_create_file "test.txt" "test content"

    assert_success
    [[ -f "test.txt" ]]
    [[ "$(cat test.txt)" == "test content" ]]
}

@test "safe_create_file skips existing file" {
    echo "original content" > existing.txt

    run safe_create_file "existing.txt" "new content"

    assert_failure  # Returns 1 for skip
    assert_equal "$(cat existing.txt)" "original content"
    [[ "$output" =~ "SKIP" ]] || [[ "$output" =~ "already exists" ]]
}

@test "safe_create_file creates parent directories" {
    run safe_create_file "nested/dir/file.txt" "nested content"

    assert_success
    [[ -f "nested/dir/file.txt" ]]
    [[ "$(cat nested/dir/file.txt)" == "nested content" ]]
}

@test "safe_create_dir creates directory that doesn't exist" {
    run safe_create_dir "new_dir"

    assert_success
    [[ -d "new_dir" ]]
}

@test "safe_create_dir succeeds when directory already exists" {
    mkdir existing_dir

    run safe_create_dir "existing_dir"

    assert_success
    [[ -d "existing_dir" ]]
}

# =============================================================================
# DIRECTORY STRUCTURE (2 tests)
# =============================================================================

@test "create_ralph_structure creates all required directories" {
    run create_ralph_structure

    assert_success
    [[ -d ".ralph" ]]
    [[ -d ".ralph/specs" ]]
    [[ -d ".ralph/examples" ]]
    [[ -d ".ralph/logs" ]]
    [[ -d ".ralph/docs/generated" ]]
}

@test "create_ralph_structure is idempotent" {
    create_ralph_structure
    echo "test" > .ralph/specs/test.txt

    run create_ralph_structure

    assert_success
    [[ -f ".ralph/specs/test.txt" ]]
}

# =============================================================================
# PROJECT DETECTION (6 tests)
# =============================================================================

@test "detect_project_context identifies TypeScript from package.json" {
    cat > package.json << 'EOF'
{
    "name": "my-ts-project",
    "devDependencies": {
        "typescript": "^5.0.0"
    }
}
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "typescript"
    assert_equal "$DETECTED_PROJECT_NAME" "my-ts-project"
}

@test "detect_project_context identifies JavaScript from package.json" {
    cat > package.json << 'EOF'
{
    "name": "my-js-project"
}
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "javascript"
}

@test "detect_project_context identifies Python from pyproject.toml" {
    cat > pyproject.toml << 'EOF'
[project]
name = "my-python-project"
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "python"
}

@test "detect_project_context identifies Next.js framework" {
    cat > package.json << 'EOF'
{
    "name": "nextjs-app",
    "dependencies": {
        "next": "^14.0.0"
    }
}
EOF

    detect_project_context

    assert_equal "$DETECTED_FRAMEWORK" "nextjs"
}

@test "detect_project_context identifies FastAPI framework" {
    cat > pyproject.toml << 'EOF'
[project]
name = "fastapi-app"
dependencies = ["fastapi>=0.100.0"]
EOF

    detect_project_context

    assert_equal "$DETECTED_FRAMEWORK" "fastapi"
}

@test "detect_project_context falls back to folder name" {
    detect_project_context

    # Should use the temp directory name
    [[ -n "$DETECTED_PROJECT_NAME" ]]
}

# =============================================================================
# GIT DETECTION (3 tests)
# =============================================================================

@test "detect_git_info detects git repository" {
    git init >/dev/null 2>&1

    detect_git_info

    assert_equal "$DETECTED_GIT_REPO" "true"
}

@test "detect_git_info detects non-git directory" {
    detect_git_info

    assert_equal "$DETECTED_GIT_REPO" "false"
}

@test "detect_git_info detects GitHub remote" {
    git init >/dev/null 2>&1
    git remote add origin git@github.com:user/repo.git 2>/dev/null || true

    detect_git_info

    assert_equal "$DETECTED_GIT_GITHUB" "true"
}

# =============================================================================
# TASK SOURCE DETECTION (2 tests)
# =============================================================================

@test "detect_task_sources detects .beads directory" {
    mkdir -p .beads

    detect_task_sources

    assert_equal "$DETECTED_BEADS_AVAILABLE" "true"
}

@test "detect_task_sources finds PRD files" {
    mkdir -p docs
    echo "# Requirements" > docs/requirements.md

    detect_task_sources

    [[ ${#DETECTED_PRD_FILES[@]} -gt 0 ]]
}

# =============================================================================
# TEMPLATE GENERATION (4 tests)
# =============================================================================

@test "generate_prompt_md includes project name" {
    output=$(generate_prompt_md "my-project" "typescript")

    [[ "$output" =~ "my-project" ]]
}

@test "generate_prompt_md includes project type" {
    output=$(generate_prompt_md "my-project" "python")

    [[ "$output" =~ "python" ]]
}

@test "generate_agent_md includes build command" {
    output=$(generate_agent_md "npm run build" "npm test" "npm start")

    [[ "$output" =~ "npm run build" ]]
    [[ "$output" =~ "npm test" ]]
}

@test "generate_ralphrc includes project configuration" {
    output=$(generate_ralphrc "my-project" "typescript" "local,beads")

    [[ "$output" =~ "PROJECT_NAME=\"my-project\"" ]]
    [[ "$output" =~ "PROJECT_TYPE=\"typescript\"" ]]
    [[ "$output" =~ "TASK_SOURCES=\"local,beads\"" ]]
}

# =============================================================================
# FULL ENABLE FLOW (3 tests)
# =============================================================================

@test "enable_ralph_in_directory creates all required files" {
    export ENABLE_FORCE="false"
    export ENABLE_SKIP_TASKS="true"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success
    [[ -f ".ralph/PROMPT.md" ]]
    [[ -f ".ralph/@fix_plan.md" ]]
    [[ -f ".ralph/@AGENT.md" ]]
    [[ -f ".ralphrc" ]]
}

@test "enable_ralph_in_directory returns ALREADY_ENABLED when complete and no force" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/@fix_plan.md
    echo "# Agent" > .ralph/@AGENT.md

    export ENABLE_FORCE="false"

    run enable_ralph_in_directory

    assert_equal "$status" "$ENABLE_ALREADY_ENABLED"
}

@test "enable_ralph_in_directory overwrites with force flag" {
    mkdir -p .ralph
    echo "old content" > .ralph/PROMPT.md
    echo "old fix plan" > .ralph/@fix_plan.md
    echo "old agent" > .ralph/@AGENT.md

    export ENABLE_FORCE="true"
    export ENABLE_PROJECT_NAME="new-project"

    run enable_ralph_in_directory

    assert_success
}
