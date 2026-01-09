#!/usr/bin/env bats
# Integration tests for ralph-import command functionality
# Tests PRD to Ralph format conversion with mocked Claude Code CLI

load '../helpers/test_helper'
load '../helpers/mocks'
load '../helpers/fixtures'

# Root directory of the project (for accessing ralph_import.sh)
PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    ORIGINAL_DIR="$(pwd)"
    cd "$TEST_DIR"

    # Initialize git repo (required by ralph_import.sh)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up mock command directory (prepend to PATH)
    MOCK_BIN_DIR="$TEST_DIR/.mock_bin"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    # Create mock ralph-setup command
    cat > "$MOCK_BIN_DIR/ralph-setup" << 'MOCK_SETUP_EOF'
#!/bin/bash
# Mock ralph-setup that creates project structure
project_name="${1:-test-project}"
mkdir -p "$project_name"/{specs,src,logs,docs/generated}
cd "$project_name"
git init > /dev/null 2>&1
git config user.email "test@example.com"
git config user.name "Test User"
# Create basic template files
cat > PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent.

## Current Objectives
- Study specs/* to learn about the project specifications
- Review @fix_plan.md for current priorities

## Key Principles
- ONE task per loop

## Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort
EOF

cat > "@fix_plan.md" << 'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Task 1

## Medium Priority
- [ ] Task 2

## Low Priority
- [ ] Task 3

## Completed
- [x] Project initialization
EOF

cat > "@AGENT.md" << 'EOF'
# Agent Build Instructions

## Project Setup
npm install
EOF

git add -A > /dev/null 2>&1
git commit -m "Initial project setup" > /dev/null 2>&1
echo "Created Ralph project: $project_name"
MOCK_SETUP_EOF
    chmod +x "$MOCK_BIN_DIR/ralph-setup"

    # Create mock claude command for PRD conversion
    # Default behavior: create the expected output files
    create_mock_claude_success

    # Export environment variables
    export CLAUDE_CODE_CMD="claude"
}

teardown() {
    # Return to original directory
    cd "$ORIGINAL_DIR" 2>/dev/null || cd /

    # Clean up test directory
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# Helper: Create mock claude command that succeeds
create_mock_claude_success() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_EOF'
#!/bin/bash
# Mock Claude Code CLI that creates expected output files
# Read from stdin (conversion prompt)
cat > /dev/null

# Create PROMPT.md with Ralph format
cat > PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a Task Management App project.

## Current Objectives
1. Study specs/* to learn about the project specifications
2. Review @fix_plan.md for current priorities
3. Implement the highest priority item using best practices
4. Use parallel subagents for complex tasks (max 100 concurrent)
5. Run tests after each implementation
6. Update documentation and fix_plan.md

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update @fix_plan.md with your learnings
- Commit working changes with descriptive messages

## Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop
- PRIORITIZE: Implementation > Documentation > Tests
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Focus on CORE functionality first, comprehensive testing later

## Project Requirements
- User authentication and authorization
- Task CRUD operations
- Team collaboration features
- Real-time updates

## Technical Constraints
- Frontend: React.js with TypeScript
- Backend: Node.js with Express
- Database: PostgreSQL

## Success Criteria
- Users can create and manage tasks efficiently
- Team collaboration features work seamlessly
- App loads quickly (<2s initial load)

## Current Task
Follow @fix_plan.md and choose the most important item to implement next.
EOF

# Create @fix_plan.md
cat > "@fix_plan.md" << 'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Set up user authentication with JWT
- [ ] Implement task CRUD API endpoints
- [ ] Create task list UI component

## Medium Priority
- [ ] Add team/workspace management
- [ ] Implement task assignment features
- [ ] Add due date and reminder functionality

## Low Priority
- [ ] Real-time updates with WebSocket
- [ ] Task comments and attachments
- [ ] Mobile PWA support

## Completed
- [x] Project initialization

## Notes
- Focus on MVP functionality first
- Ensure each feature is properly tested
- Update this file after each major milestone
EOF

# Create specs/requirements.md
mkdir -p specs
cat > specs/requirements.md << 'EOF'
# Technical Specifications

## System Architecture
- Frontend: React.js SPA with TypeScript
- Backend: Node.js REST API with Express
- Database: PostgreSQL with Prisma ORM
- Authentication: JWT with refresh tokens

## Data Models

### User
- id: UUID
- email: string (unique)
- password_hash: string
- name: string
- avatar_url: string (optional)
- created_at: timestamp

### Task
- id: UUID
- title: string
- description: text (optional)
- priority: enum (high, medium, low)
- due_date: timestamp (optional)
- completed: boolean
- user_id: UUID (foreign key)
- created_at: timestamp

## API Specifications

### Authentication
- POST /api/auth/register - User registration
- POST /api/auth/login - User login
- POST /api/auth/refresh - Refresh token
- POST /api/auth/logout - User logout

### Tasks
- GET /api/tasks - List user's tasks
- POST /api/tasks - Create task
- GET /api/tasks/:id - Get task details
- PUT /api/tasks/:id - Update task
- DELETE /api/tasks/:id - Delete task

## Performance Requirements
- Initial page load: <2 seconds
- API response time: <200ms
- Support 100 concurrent users

## Security Considerations
- Password hashing with bcrypt
- HTTPS required in production
- Rate limiting on auth endpoints
- Input validation on all endpoints
EOF

echo "Mock: Claude Code conversion completed successfully"
exit 0
MOCK_CLAUDE_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Helper: Create mock claude command that fails
create_mock_claude_failure() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_FAIL_EOF'
#!/bin/bash
# Mock Claude Code CLI that fails
echo "Error: Mock Claude Code failed"
exit 1
MOCK_CLAUDE_FAIL_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Helper: Remove ralph-setup from mock bin (simulate not installed)
remove_ralph_setup_mock() {
    rm -f "$MOCK_BIN_DIR/ralph-setup"
}

# =============================================================================
# FILE FORMAT SUPPORT TESTS
# =============================================================================

# Test 1: ralph-import with .md file
@test "ralph-import accepts and processes .md file format" {
    # Create sample PRD markdown file
    create_sample_prd_md "my-project-prd.md"

    # Run import
    run bash "$PROJECT_ROOT/ralph_import.sh" "my-project-prd.md"

    # Should succeed
    assert_success

    # Project directory should be created
    assert_dir_exists "my-project-prd"

    # Source file should be copied to project
    assert_file_exists "my-project-prd/my-project-prd.md"
}

# Test 2: ralph-import with .txt file
@test "ralph-import accepts and processes .txt file format" {
    # Create sample .txt PRD
    create_sample_prd_txt "requirements.txt"

    # Run import
    run bash "$PROJECT_ROOT/ralph_import.sh" "requirements.txt"

    # Should succeed
    assert_success

    # Project directory should be created (name from filename)
    assert_dir_exists "requirements"

    # Source file should be copied
    assert_file_exists "requirements/requirements.txt"
}

# Test 3: ralph-import with .json file
@test "ralph-import accepts and processes .json file format" {
    # Create sample JSON PRD
    create_sample_prd_json "project-spec.json"

    # Run import
    run bash "$PROJECT_ROOT/ralph_import.sh" "project-spec.json"

    # Should succeed
    assert_success

    # Project directory should be created
    assert_dir_exists "project-spec"

    # Source file should be copied
    assert_file_exists "project-spec/project-spec.json"
}

# =============================================================================
# OUTPUT FILE CREATION TESTS
# =============================================================================

# Test 4: ralph-import creates PROMPT.md
@test "ralph-import creates PROMPT.md with Ralph instructions" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # PROMPT.md should exist
    assert_file_exists "test-app/PROMPT.md"

    # Check key sections exist
    run grep -c "Ralph Development Instructions" "test-app/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Current Objectives" "test-app/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Key Principles" "test-app/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Testing Guidelines" "test-app/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]
}

# Test 5: ralph-import creates @fix_plan.md
@test "ralph-import creates @fix_plan.md with prioritized tasks" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # @fix_plan.md should exist
    assert_file_exists "test-app/@fix_plan.md"

    # Check structure includes priority sections
    run grep -c "High Priority" "test-app/@fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Medium Priority" "test-app/@fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Low Priority" "test-app/@fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Completed" "test-app/@fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    # Check checkbox format
    run grep -E "^\- \[[ x]\]" "test-app/@fix_plan.md"
    assert_success
}

# Test 6: ralph-import creates specs/requirements.md
@test "ralph-import creates specs/requirements.md with technical specs" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # specs directory should exist
    assert_dir_exists "test-app/specs"

    # requirements.md should exist
    assert_file_exists "test-app/specs/requirements.md"

    # Check technical specification content
    run grep -c "Technical Specifications" "test-app/specs/requirements.md"
    assert_success
    [[ "$output" -ge 1 ]]
}

# =============================================================================
# PROJECT NAMING TESTS
# =============================================================================

# Test 7: ralph-import with custom project name
@test "ralph-import uses custom project name when provided" {
    create_sample_prd_md "generic-prd.md"

    # Run with custom project name
    run bash "$PROJECT_ROOT/ralph_import.sh" "generic-prd.md" "my-custom-project"

    assert_success

    # Custom project directory should be created
    assert_dir_exists "my-custom-project"

    # Files should be in custom-named directory
    assert_file_exists "my-custom-project/PROMPT.md"
    assert_file_exists "my-custom-project/@fix_plan.md"
    assert_file_exists "my-custom-project/specs/requirements.md"

    # Default name directory should NOT exist
    [[ ! -d "generic-prd" ]]
}

# Test 8: ralph-import auto-detects name from filename
@test "ralph-import extracts project name from filename when not provided" {
    create_sample_prd_md "awesome-app-requirements.md"

    # Run without custom name
    run bash "$PROJECT_ROOT/ralph_import.sh" "awesome-app-requirements.md"

    assert_success

    # Project name should be extracted from filename (without extension)
    assert_dir_exists "awesome-app-requirements"

    # Files should be in auto-named directory
    assert_file_exists "awesome-app-requirements/PROMPT.md"
}

# =============================================================================
# ERROR HANDLING TESTS
# =============================================================================

# Test 9: ralph-import missing source file error
@test "ralph-import fails gracefully when source file does not exist" {
    run bash "$PROJECT_ROOT/ralph_import.sh" "nonexistent-file.md"

    # Should fail with error code 1
    assert_failure

    # Error message should mention missing file
    [[ "$output" == *"Source file does not exist"* ]]

    # No project directory should be created
    [[ ! -d "nonexistent-file" ]]
}

# Test 10: ralph-import dependency check (ralph not installed)
@test "ralph-import fails when ralph-setup is not installed" {
    create_sample_prd_md "test-app.md"

    # Remove ralph-setup from mock path AND isolate from system PATH
    # Use a completely isolated PATH with only essential system tools
    remove_ralph_setup_mock

    # Save original PATH and use restricted PATH that excludes ralph-setup
    local ORIGINAL_PATH="$PATH"
    export PATH="$MOCK_BIN_DIR:/usr/bin:/bin"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    # Restore original PATH
    export PATH="$ORIGINAL_PATH"

    # Should fail
    assert_failure

    # Error message should mention Ralph not installed
    [[ "$output" == *"Ralph not installed"* ]] || [[ "$output" == *"ralph-setup"* ]]
}

# Test 11: ralph-import conversion failure handling
@test "ralph-import handles Claude Code conversion failure gracefully" {
    create_sample_prd_md "test-app.md"

    # Set up mock to fail
    create_mock_claude_failure

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    # Should fail
    assert_failure

    # Error message should mention conversion failure
    [[ "$output" == *"PRD conversion failed"* ]] || [[ "$output" == *"failed"* ]]
}

# =============================================================================
# HELP AND USAGE TESTS
# =============================================================================

# Test 12: ralph-import with no arguments shows help
@test "ralph-import shows help when called with no arguments" {
    run bash "$PROJECT_ROOT/ralph_import.sh"

    # Should succeed (help is not an error)
    assert_success

    # Should display usage information
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"source-file"* ]]
}

# Test 13: ralph-import --help shows full help
@test "ralph-import --help shows full help with examples" {
    run bash "$PROJECT_ROOT/ralph_import.sh" --help

    # Should succeed
    assert_success

    # Should display help sections
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"Arguments"* ]]
    [[ "$output" == *"Examples"* ]]
    [[ "$output" == *"Supported formats"* ]]
}

# Test 14: ralph-import -h shows help (short form)
@test "ralph-import -h shows help" {
    run bash "$PROJECT_ROOT/ralph_import.sh" -h

    assert_success
    [[ "$output" == *"Usage"* ]]
}

# =============================================================================
# CONVERSION PROMPT TESTS
# =============================================================================

# Test 15: ralph-import cleans up temporary conversion prompt
@test "ralph-import cleans up .ralph_conversion_prompt.md after conversion" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # Temporary prompt file should NOT exist in project directory
    [[ ! -f "test-app/.ralph_conversion_prompt.md" ]]
}

# Test 16: ralph-import outputs completion message with next steps
@test "ralph-import shows success message with next steps" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # Should show success message
    [[ "$output" == *"successfully"* ]] || [[ "$output" == *"SUCCESS"* ]]

    # Should show next steps
    [[ "$output" == *"Next steps"* ]] || [[ "$output" == *"ralph --monitor"* ]]
}

# =============================================================================
# FULL WORKFLOW INTEGRATION TESTS
# =============================================================================

# Test 17: Complete import workflow creates valid Ralph project
@test "full workflow creates complete Ralph project structure" {
    create_sample_prd_md "my-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "my-app.md"

    assert_success

    # Verify complete project structure
    assert_dir_exists "my-app"
    assert_dir_exists "my-app/specs"
    assert_dir_exists "my-app/src"
    assert_dir_exists "my-app/logs"
    assert_dir_exists "my-app/docs/generated"

    # Verify all required files
    assert_file_exists "my-app/PROMPT.md"
    assert_file_exists "my-app/@fix_plan.md"
    assert_file_exists "my-app/@AGENT.md"
    assert_file_exists "my-app/specs/requirements.md"

    # Verify source PRD was copied
    assert_file_exists "my-app/my-app.md"
}

# Test 18: Imported project is a valid git repository
@test "imported project is initialized as git repository" {
    create_sample_prd_md "git-test.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "git-test.md"

    assert_success

    # Project should have .git directory
    assert_dir_exists "git-test/.git"

    # Should be a valid git repo
    cd "git-test"
    run git rev-parse --is-inside-work-tree
    assert_success
    assert_equal "$output" "true"
}

# =============================================================================
# EDGE CASE TESTS
# =============================================================================

# Test 19: ralph-import handles project names with hyphens
@test "ralph-import handles project names with hyphens correctly" {
    create_sample_prd_md "my-awesome-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "my-awesome-app.md"

    assert_success
    assert_dir_exists "my-awesome-app"
}

# Test 20: ralph-import handles uppercase filenames
@test "ralph-import handles uppercase in filename" {
    create_sample_prd_md "MyProject.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "MyProject.md"

    assert_success
    assert_dir_exists "MyProject"
}

# Test 21: ralph-import handles path with directories
@test "ralph-import handles source file in subdirectory" {
    mkdir -p "docs/specs"
    create_sample_prd_md "docs/specs/project-prd.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "docs/specs/project-prd.md"

    assert_success

    # Project should be created with basename (without path)
    assert_dir_exists "project-prd"
}

# Test 22: ralph-import preserves original PRD content
@test "ralph-import preserves original PRD content in project" {
    # Create PRD with unique content
    cat > "unique-prd.md" << 'EOF'
# Unique Test PRD

## Unique Identifier: XYZ-12345

This is a unique test PRD with identifiable content.

## Requirements
- Unique requirement A
- Unique requirement B
EOF

    run bash "$PROJECT_ROOT/ralph_import.sh" "unique-prd.md"

    assert_success

    # Original content should be preserved
    run grep "Unique Identifier: XYZ-12345" "unique-prd/unique-prd.md"
    assert_success

    run grep "Unique requirement A" "unique-prd/unique-prd.md"
    assert_success
}
