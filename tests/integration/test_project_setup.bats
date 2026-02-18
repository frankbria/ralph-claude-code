#!/usr/bin/env bats
# Integration tests for Ralph project setup (setup.sh)
# Tests directory creation, template copying, git initialization, and README creation

load '../helpers/test_helper'
load '../helpers/fixtures'

# Store the path to setup.sh from the project root
SETUP_SCRIPT=""

setup() {
    # Create unique temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Store setup.sh path (relative to test directory)
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../../setup.sh"

    # Set git author info via environment variables (avoids mutating global config)
    export GIT_AUTHOR_NAME="Test User"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test User"
    export GIT_COMMITTER_EMAIL="test@example.com"

    # Create mock templates directory (simulating ../templates relative to project being created)
    mkdir -p templates/specs

    # Create mock template files with minimal but valid content
    cat > templates/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent.

## Current Objectives
1. Follow fix_plan.md for current priorities
2. Implement using best practices
3. Run tests after each implementation
EOF

    cat > templates/fix_plan.md << 'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Initial setup task

## Medium Priority
- [ ] Secondary task

## Notes
- Focus on MVP functionality first
EOF

    cat > templates/AGENT.md << 'EOF'
# Agent Build Instructions

## Project Setup
```bash
npm install
```

## Running Tests
```bash
npm test
```
EOF

    # Create a sample spec file
    cat > templates/specs/sample_spec.md << 'EOF'
# Sample Specification
This is a sample spec file for testing.
EOF
}

teardown() {
    # Clean up test directory
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# Test: Project Directory Creation
# =============================================================================

@test "setup.sh creates project directory" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_dir_exists "test-project"
}

@test "setup.sh handles project name with hyphens" {
    run bash "$SETUP_SCRIPT" my-test-project

    assert_success
    assert_dir_exists "my-test-project"
}

@test "setup.sh handles project name with underscores" {
    run bash "$SETUP_SCRIPT" my_test_project

    assert_success
    assert_dir_exists "my_test_project"
}

# =============================================================================
# Test: Subdirectory Structure (.ralph/ subfolder)
# =============================================================================

@test "setup.sh creates .ralph subdirectory for Ralph-specific files" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_dir_exists "test-project/.ralph"
}

@test "setup.sh creates all required subdirectories in .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    # Ralph-specific directories go inside .ralph/
    assert_dir_exists "test-project/.ralph/specs"
    assert_dir_exists "test-project/.ralph/specs/stdlib"
    assert_dir_exists "test-project/.ralph/examples"
    assert_dir_exists "test-project/.ralph/logs"
    assert_dir_exists "test-project/.ralph/docs"
    assert_dir_exists "test-project/.ralph/docs/generated"
    # src/ stays at root per maintainer decision
    assert_dir_exists "test-project/src"
}

@test "setup.sh keeps src directory at project root (not in .ralph/)" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    # src should be at root, NOT inside .ralph
    assert_dir_exists "test-project/src"
    [[ ! -d "test-project/.ralph/src" ]]
}

@test "setup.sh creates nested docs/generated directory in .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    # Verify the nested structure exists inside .ralph
    [[ -d "test-project/.ralph/docs/generated" ]]
}

@test "setup.sh creates nested specs/stdlib directory in .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    [[ -d "test-project/.ralph/specs/stdlib" ]]
}

# =============================================================================
# Test: Template Copying (to .ralph/ subfolder)
# =============================================================================

@test "setup.sh copies PROMPT.md template to .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/.ralph/PROMPT.md"

    # Verify content matches source
    diff templates/PROMPT.md test-project/.ralph/PROMPT.md
}

@test "setup.sh copies fix_plan.md to .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/.ralph/fix_plan.md"

    # Verify content matches source
    diff templates/fix_plan.md "test-project/.ralph/fix_plan.md"
}

@test "setup.sh copies AGENT.md to .ralph/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/.ralph/AGENT.md"

    # Verify content matches source
    diff templates/AGENT.md "test-project/.ralph/AGENT.md"
}

@test "setup.sh copies specs templates to .ralph/specs/" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    # Verify spec file was copied to .ralph/specs/
    assert_file_exists "test-project/.ralph/specs/sample_spec.md"
}

@test "setup.sh handles empty specs directory gracefully" {
    # Remove spec files
    rm -f templates/specs/*

    run bash "$SETUP_SCRIPT" test-project

    # Should not fail (|| true in script handles this)
    assert_success
    assert_dir_exists "test-project/.ralph/specs"
}

@test "setup.sh handles missing specs directory gracefully" {
    # Remove specs directory entirely
    rm -rf templates/specs

    run bash "$SETUP_SCRIPT" test-project

    # Should not fail due to || true in script
    assert_success
    assert_dir_exists "test-project/.ralph/specs"
}

# =============================================================================
# Test: Git Initialization
# =============================================================================

@test "setup.sh initializes git repository" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_dir_exists "test-project/.git"
}

@test "setup.sh creates valid git repository" {
    bash "$SETUP_SCRIPT" test-project

    cd test-project
    run command git rev-parse --git-dir

    assert_success
    assert_equal "$output" ".git"
}

@test "setup.sh creates initial git commit" {
    bash "$SETUP_SCRIPT" test-project

    cd test-project
    run command git log --oneline

    assert_success
    # Should have at least one commit
    [[ -n "$output" ]]
}

@test "setup.sh uses correct initial commit message" {
    bash "$SETUP_SCRIPT" test-project

    cd test-project
    run command git log -1 --pretty=%B

    assert_success
    # Remove trailing whitespace for comparison
    local commit_msg=$(echo "$output" | tr -d '\n')
    assert_equal "$commit_msg" "Initial Ralph project setup"
}

@test "setup.sh commits all files in initial commit" {
    bash "$SETUP_SCRIPT" test-project

    cd test-project
    run command git status --porcelain

    assert_success
    # Working tree should be clean (no uncommitted changes)
    assert_equal "$output" ""
}

# =============================================================================
# Test: README Creation
# =============================================================================

@test "setup.sh creates README.md" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/README.md"
}

@test "setup.sh README contains project name" {
    bash "$SETUP_SCRIPT" test-project

    # Verify README contains the project name as heading
    grep -q "# test-project" test-project/README.md
}

@test "setup.sh README is not empty" {
    bash "$SETUP_SCRIPT" test-project

    # File should have content
    [[ -s "test-project/README.md" ]]
}

# =============================================================================
# Test: Custom Project Name
# =============================================================================

@test "setup.sh accepts custom project name as argument" {
    run bash "$SETUP_SCRIPT" custom-project-name

    assert_success
    assert_dir_exists "custom-project-name"
}

@test "setup.sh custom project has correct README heading" {
    bash "$SETUP_SCRIPT" custom-project-name

    grep -q "# custom-project-name" custom-project-name/README.md
}

@test "setup.sh custom project has all subdirectories in .ralph/" {
    bash "$SETUP_SCRIPT" my-custom-app

    # Ralph-specific dirs in .ralph/
    assert_dir_exists "my-custom-app/.ralph/specs/stdlib"
    assert_dir_exists "my-custom-app/.ralph/examples"
    assert_dir_exists "my-custom-app/.ralph/logs"
    assert_dir_exists "my-custom-app/.ralph/docs/generated"
    # src stays at root
    assert_dir_exists "my-custom-app/src"
}

@test "setup.sh custom project has all template files in .ralph/" {
    bash "$SETUP_SCRIPT" my-custom-app

    assert_file_exists "my-custom-app/.ralph/PROMPT.md"
    assert_file_exists "my-custom-app/.ralph/fix_plan.md"
    assert_file_exists "my-custom-app/.ralph/AGENT.md"
}

# =============================================================================
# Test: Default Project Name
# =============================================================================

@test "setup.sh uses default project name when none provided" {
    run bash "$SETUP_SCRIPT"

    assert_success
    # Default name is "my-project" per line 6 of setup.sh
    assert_dir_exists "my-project"
}

@test "setup.sh default project has correct README heading" {
    bash "$SETUP_SCRIPT"

    grep -q "# my-project" my-project/README.md
}

@test "setup.sh default project has all required structure in .ralph/" {
    bash "$SETUP_SCRIPT"

    # Verify .ralph directory exists
    assert_dir_exists "my-project/.ralph"

    # Verify all directories in .ralph/
    assert_dir_exists "my-project/.ralph/specs/stdlib"
    assert_dir_exists "my-project/.ralph/examples"
    assert_dir_exists "my-project/.ralph/logs"
    assert_dir_exists "my-project/.ralph/docs/generated"
    # src stays at root
    assert_dir_exists "my-project/src"

    # Verify all files in .ralph/
    assert_file_exists "my-project/.ralph/PROMPT.md"
    assert_file_exists "my-project/.ralph/fix_plan.md"
    assert_file_exists "my-project/.ralph/AGENT.md"
    # README stays at root
    assert_file_exists "my-project/README.md"
}

# =============================================================================
# Test: Working Directory Behavior
# =============================================================================

@test "setup.sh works from nested directory" {
    # Create a separate working area nested inside TEST_DIR
    mkdir -p work-area/subdir1/subdir2

    # setup.sh does: cd $PROJECT_NAME && cp ../templates/PROMPT.md .
    # So templates needs to be in the SAME directory where we run setup.sh
    # (i.e., a sibling of the project directory that gets created)
    cp -r templates work-area/subdir1/subdir2/

    cd work-area/subdir1/subdir2

    run bash "$SETUP_SCRIPT" nested-project

    assert_success
    assert_dir_exists "nested-project"
}

@test "setup.sh creates project in current directory" {
    # Project should be created relative to where script is run, not where script lives
    mkdir -p work-area
    cd work-area

    # Copy templates so they're accessible
    cp -r "$TEST_DIR/templates" .

    run bash "$SETUP_SCRIPT" local-project

    assert_success
    # Project should be in work-area directory
    assert_dir_exists "local-project"
}

# =============================================================================
# Test: Output Messages
# =============================================================================

@test "setup.sh outputs startup message with project name" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    [[ "$output" == *"Setting up Ralph project: test-project"* ]]
}

@test "setup.sh outputs completion message" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    [[ "$output" == *"Project test-project created"* ]]
}

@test "setup.sh outputs next steps guidance with .ralph paths" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    [[ "$output" == *"Next steps:"* ]]
    [[ "$output" == *".ralph/PROMPT.md"* ]]
}

# =============================================================================
# Test: Error Handling
# =============================================================================

@test "setup.sh fails if templates directory missing" {
    # Remove local templates directory
    rm -rf templates

    # Also hide global templates by overriding HOME to a temp location
    local original_home="$HOME"
    export HOME="$(mktemp -d)"

    run bash "$SETUP_SCRIPT" test-project

    # Restore HOME
    export HOME="$original_home"

    assert_failure
}

@test "setup.sh fails if PROMPT.md template missing" {
    # Remove PROMPT.md template
    rm -f templates/PROMPT.md

    run bash "$SETUP_SCRIPT" test-project

    assert_failure
}

# =============================================================================
# Test: Idempotency and Edge Cases
# =============================================================================

@test "setup.sh succeeds when run in an existing directory (idempotent)" {
    # Create project directory first
    mkdir -p existing-project

    run bash "$SETUP_SCRIPT" existing-project

    # The script uses mkdir -p which is idempotent, and git init works in existing dirs
    # Templates will be copied over existing files, so this should succeed
    [[ $status -eq 0 ]]
}

@test "setup.sh handles project name with spaces by creating directory" {
    # Project names with spaces should work since the script uses "$PROJECT_NAME" with quotes
    run bash "$SETUP_SCRIPT" "project with spaces"

    # The script properly quotes variables, so spaces should be handled correctly
    [[ $status -eq 0 ]]
}

# =============================================================================
# Test: .ralphrc Generation (Issue #136)
# =============================================================================

@test "setup.sh creates .ralphrc file" {
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/.ralphrc"
}

@test "setup.sh .ralphrc contains ALLOWED_TOOLS with Edit" {
    bash "$SETUP_SCRIPT" test-project

    # .ralphrc should include Edit tool
    grep -q "Edit" test-project/.ralphrc
}

@test "setup.sh .ralphrc contains ALLOWED_TOOLS with test execution capabilities" {
    bash "$SETUP_SCRIPT" test-project

    # .ralphrc should include Bash(npm *) or Bash(pytest) for test execution
    grep -qE 'Bash\(npm \*\)|Bash\(pytest\)' test-project/.ralphrc
}

@test "setup.sh .ralphrc ALLOWED_TOOLS matches ralph-enable defaults" {
    bash "$SETUP_SCRIPT" test-project

    # The expected ALLOWED_TOOLS value that ralph-enable uses (Issue #149: safe git subcommands)
    local expected_tools='ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pytest)"'

    # Check that .ralphrc contains the expected ALLOWED_TOOLS line
    # Use grep -F for literal string matching (avoids regex interpretation of *)
    grep -qF "$expected_tools" test-project/.ralphrc
}

@test "setup.sh .ralphrc is committed in initial git commit" {
    bash "$SETUP_SCRIPT" test-project

    cd test-project
    # Verify .ralphrc is tracked by git (not in untracked files)
    run command git ls-files .ralphrc

    assert_success
    assert_equal "$output" ".ralphrc"
}

@test "setup.sh .ralphrc contains project name" {
    bash "$SETUP_SCRIPT" my-custom-project

    # .ralphrc should reference the project name
    grep -q "my-custom-project" my-custom-project/.ralphrc
}

# =============================================================================
# Test: .gitignore Generation (Issue #174)
# =============================================================================

@test "setup.sh creates .gitignore file" {
    # Create .gitignore template
    cat > templates/.gitignore << 'EOF'
# Ralph generated files
.ralph/.call_count
.ralph/.last_reset
.ralph/status.json
EOF

    run bash "$SETUP_SCRIPT" test-project

    assert_success
    assert_file_exists "test-project/.gitignore"
}

@test "setup.sh .gitignore contains Ralph runtime patterns" {
    cat > templates/.gitignore << 'EOF'
.ralph/.call_count
.ralph/.last_reset
.ralph/status.json
.ralph/.circuit_breaker_state
EOF

    bash "$SETUP_SCRIPT" test-project

    grep -q ".ralph/.call_count" test-project/.gitignore
    grep -q ".ralph/.circuit_breaker_state" test-project/.gitignore
}

@test "setup.sh .gitignore is committed in initial git commit" {
    cat > templates/.gitignore << 'EOF'
.ralph/.call_count
EOF

    bash "$SETUP_SCRIPT" test-project

    cd test-project
    run command git ls-files .gitignore

    assert_success
    assert_equal "$output" ".gitignore"
}

@test "setup.sh .gitignore content matches template" {
    cat > templates/.gitignore << 'EOF'
# Ralph generated files
.ralph/.call_count
.ralph/.last_reset
EOF

    bash "$SETUP_SCRIPT" test-project

    diff templates/.gitignore test-project/.gitignore
}

@test "setup.sh succeeds when .gitignore template is missing" {
    # Do NOT create templates/.gitignore — should still succeed
    run bash "$SETUP_SCRIPT" test-project

    assert_success
    # .gitignore should not exist since template was missing
    [[ ! -f "test-project/.gitignore" ]]
}

@test "setup.sh preserves existing .gitignore on rerun" {
    echo ".ralph/.call_count" > templates/.gitignore

    # First run creates the project with .gitignore
    bash "$SETUP_SCRIPT" test-project

    # User customizes the .gitignore
    echo "my-custom-pattern" >> test-project/.gitignore

    # Second run (rerun in existing directory) should not overwrite
    bash "$SETUP_SCRIPT" test-project

    grep -q "my-custom-pattern" test-project/.gitignore
}
