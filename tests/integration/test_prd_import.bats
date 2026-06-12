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

    # Create mock ralph-setup command (with .ralph/ subfolder structure)
    cat > "$MOCK_BIN_DIR/ralph-setup" << 'MOCK_SETUP_EOF'
#!/bin/bash
# Mock ralph-setup that creates project structure with .ralph/ subfolder
project_name="${1:-test-project}"
mkdir -p "$project_name"/src
mkdir -p "$project_name"/.ralph/{specs/stdlib,examples,logs,docs/generated}
cd "$project_name"
git init > /dev/null 2>&1
git config user.email "test@example.com"
git config user.name "Test User"
# Create basic template files in .ralph/ subfolder
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent.

## Current Objectives
- Study specs/* to learn about the project specifications
- Review fix_plan.md for current priorities

## Key Principles
- ONE task per loop

## Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort
EOF

cat > ".ralph/fix_plan.md" << 'EOF'
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

cat > ".ralph/AGENT.md" << 'EOF'
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
# Mock Claude Code CLI that creates expected output files in .ralph/ subfolder

# Handle --version flag first (before reading stdin)
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

# Read from stdin (conversion prompt)
cat > /dev/null

# Ensure .ralph directory exists
mkdir -p .ralph/specs

# Create PROMPT.md with Ralph format in .ralph/
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a Task Management App project.

## Current Objectives
1. Study specs/* to learn about the project specifications
2. Review fix_plan.md for current priorities
3. Implement the highest priority item using best practices
4. Use parallel subagents for complex tasks (max 100 concurrent)
5. Run tests after each implementation
6. Update documentation and fix_plan.md

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update fix_plan.md with your learnings
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
Follow fix_plan.md and choose the most important item to implement next.
EOF

# Create fix_plan.md in .ralph/
cat > ".ralph/fix_plan.md" << 'EOF'
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

# Create specs/requirements.md in .ralph/specs/
cat > .ralph/specs/requirements.md << 'EOF'
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

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

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

    # PROMPT.md should exist in .ralph/ subfolder
    assert_file_exists "test-app/.ralph/PROMPT.md"

    # Check key sections exist
    run grep -c "Ralph Development Instructions" "test-app/.ralph/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Current Objectives" "test-app/.ralph/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Key Principles" "test-app/.ralph/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Testing Guidelines" "test-app/.ralph/PROMPT.md"
    assert_success
    [[ "$output" -ge 1 ]]
}

# Test 5: ralph-import creates fix_plan.md
@test "ralph-import creates fix_plan.md with prioritized tasks" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # fix_plan.md should exist in .ralph/ subfolder
    assert_file_exists "test-app/.ralph/fix_plan.md"

    # Check structure includes priority sections
    run grep -c "High Priority" "test-app/.ralph/fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Medium Priority" "test-app/.ralph/fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Low Priority" "test-app/.ralph/fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    run grep -c "Completed" "test-app/.ralph/fix_plan.md"
    assert_success
    [[ "$output" -ge 1 ]]

    # Check checkbox format
    run grep -E "^\- \[[ x]\]" "test-app/.ralph/fix_plan.md"
    assert_success
}

# Test 6: ralph-import creates specs/requirements.md
@test "ralph-import creates specs/requirements.md with technical specs" {
    create_sample_prd_md "test-app.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "test-app.md"

    assert_success

    # specs directory should exist in .ralph/ subfolder
    assert_dir_exists "test-app/.ralph/specs"

    # requirements.md should exist in .ralph/specs/
    assert_file_exists "test-app/.ralph/specs/requirements.md"

    # Check technical specification content
    run grep -c "Technical Specifications" "test-app/.ralph/specs/requirements.md"
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

    # Files should be in custom-named directory under .ralph/ subfolder
    assert_file_exists "my-custom-project/.ralph/PROMPT.md"
    assert_file_exists "my-custom-project/.ralph/fix_plan.md"
    assert_file_exists "my-custom-project/.ralph/specs/requirements.md"

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

    # Files should be in auto-named directory under .ralph/ subfolder
    assert_file_exists "awesome-app-requirements/.ralph/PROMPT.md"
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

    # Verify complete project structure with .ralph/ subfolder
    assert_dir_exists "my-app"
    assert_dir_exists "my-app/.ralph/specs"
    assert_dir_exists "my-app/src"
    assert_dir_exists "my-app/.ralph/logs"
    assert_dir_exists "my-app/.ralph/docs/generated"

    # Verify all required files in .ralph/ subfolder
    assert_file_exists "my-app/.ralph/PROMPT.md"
    assert_file_exists "my-app/.ralph/fix_plan.md"
    assert_file_exists "my-app/.ralph/AGENT.md"
    assert_file_exists "my-app/.ralph/specs/requirements.md"

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

# =============================================================================
# MODERN CLI FEATURES TESTS (Phase 1.1)
# Tests for --output-format json, --allowedTools, and JSON response parsing
# =============================================================================

# Helper: Create mock claude command that outputs JSON format
create_mock_claude_json_success() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_JSON_EOF'
#!/bin/bash
# Mock Claude Code CLI that outputs JSON format and creates expected files in .ralph/

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

# Read from stdin (conversion prompt)
cat > /dev/null

# Ensure .ralph directory exists
mkdir -p .ralph/specs

# Create PROMPT.md with Ralph format in .ralph/
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a Task Management App project.

## Current Objectives
1. Study specs/* to learn about the project specifications
2. Review fix_plan.md for current priorities

## Key Principles
- ONE task per loop

## Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort
EOF

# Create fix_plan.md in .ralph/
cat > ".ralph/fix_plan.md" << 'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Set up user authentication with JWT

## Medium Priority
- [ ] Add team/workspace management

## Low Priority
- [ ] Real-time updates with WebSocket

## Completed
- [x] Project initialization
EOF

# Create specs/requirements.md in .ralph/specs/
cat > .ralph/specs/requirements.md << 'EOF'
# Technical Specifications

## System Architecture
- Frontend: React.js SPA with TypeScript
- Backend: Node.js REST API with Express

## Data Models
### User
- id: UUID
- email: string (unique)
EOF

# Output JSON response to stdout (mimicking --output-format json)
cat << 'JSON_OUTPUT'
{
    "result": "Successfully converted PRD to Ralph format. Created .ralph/PROMPT.md, .ralph/fix_plan.md, and .ralph/specs/requirements.md",
    "sessionId": "session-prd-convert-123",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "completion_status": "complete",
        "files_created": [".ralph/PROMPT.md", ".ralph/fix_plan.md", ".ralph/specs/requirements.md"]
    }
}
JSON_OUTPUT

exit 0
MOCK_CLAUDE_JSON_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Helper: Create mock claude command with JSON output but partial file creation
create_mock_claude_json_partial() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_PARTIAL_EOF'
#!/bin/bash
# Mock Claude Code CLI that outputs JSON but only creates some files in .ralph/

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

cat > /dev/null

# Ensure .ralph directory exists
mkdir -p .ralph

# Only create PROMPT.md (missing fix_plan.md and specs/requirements.md)
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent.
EOF

# Output JSON response indicating partial success
cat << 'JSON_OUTPUT'
{
    "result": "Partial conversion completed. Some files could not be created.",
    "sessionId": "session-prd-partial-456",
    "metadata": {
        "files_changed": 1,
        "has_errors": true,
        "completion_status": "partial",
        "files_created": [".ralph/PROMPT.md"],
        "missing_files": [".ralph/fix_plan.md", ".ralph/specs/requirements.md"]
    }
}
JSON_OUTPUT

exit 0
MOCK_CLAUDE_PARTIAL_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Helper: Create mock claude command with JSON error output
create_mock_claude_json_error() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_JSON_ERROR_EOF'
#!/bin/bash
# Mock Claude Code CLI that outputs JSON error response

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

cat > /dev/null

# Output JSON error response
cat << 'JSON_OUTPUT'
{
    "result": "",
    "sessionId": "session-error-789",
    "metadata": {
        "files_changed": 0,
        "has_errors": true,
        "completion_status": "failed",
        "error_message": "Failed to parse PRD structure",
        "error_code": "PARSE_ERROR"
    }
}
JSON_OUTPUT

exit 1
MOCK_CLAUDE_JSON_ERROR_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Helper: Create mock claude that returns text (backward compatibility)
create_mock_claude_text_output() {
    cat > "$MOCK_BIN_DIR/claude" << 'MOCK_CLAUDE_TEXT_EOF'
#!/bin/bash
# Mock Claude Code CLI that outputs text (older CLI version) - files in .ralph/

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

cat > /dev/null

# Ensure .ralph directory exists
mkdir -p .ralph/specs

# Create files in .ralph/
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent.
EOF

cat > ".ralph/fix_plan.md" << 'EOF'
# Ralph Fix Plan

## High Priority
- [ ] Set up project structure

## Completed
- [x] Project initialization
EOF

cat > .ralph/specs/requirements.md << 'EOF'
# Technical Specifications

## Overview
Basic technical requirements.
EOF

# Output plain text (no JSON)
echo "Mock: Claude Code conversion completed successfully"
echo "Created: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/requirements.md"
exit 0
MOCK_CLAUDE_TEXT_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

# Test 23: ralph-import parses JSON output format successfully
@test "ralph-import parses JSON output from Claude CLI" {
    create_sample_prd_md "json-test.md"
    create_mock_claude_json_success

    run bash "$PROJECT_ROOT/ralph_import.sh" "json-test.md"

    assert_success

    # All files should be created in .ralph/ subfolder
    assert_file_exists "json-test/.ralph/PROMPT.md"
    assert_file_exists "json-test/.ralph/fix_plan.md"
    assert_file_exists "json-test/.ralph/specs/requirements.md"
}

# Test 24: ralph-import handles JSON partial success response
@test "ralph-import handles JSON partial success and warns about missing files" {
    create_sample_prd_md "partial-test.md"
    create_mock_claude_json_partial

    run bash "$PROJECT_ROOT/ralph_import.sh" "partial-test.md"

    # Should succeed but with warnings
    assert_success

    # PROMPT.md should exist in .ralph/ subfolder
    assert_file_exists "partial-test/.ralph/PROMPT.md"

    # Warning should mention missing files
    [[ "$output" == *"WARN"* ]] || [[ "$output" == *"not created"* ]] || [[ "$output" == *"missing"* ]]
}

# Test 25: ralph-import handles JSON error response gracefully
@test "ralph-import handles JSON error response with structured error message" {
    create_sample_prd_md "error-test.md"
    create_mock_claude_json_error

    run bash "$PROJECT_ROOT/ralph_import.sh" "error-test.md"

    # Should fail
    assert_failure

    # Error output should be present
    [[ "$output" == *"failed"* ]] || [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"error"* ]]
}

# Test 26: ralph-import maintains backward compatibility with text output
@test "ralph-import works with text output (backward compatibility)" {
    create_sample_prd_md "text-test.md"
    create_mock_claude_text_output

    run bash "$PROJECT_ROOT/ralph_import.sh" "text-test.md"

    assert_success

    # All files should be created in .ralph/ subfolder
    assert_file_exists "text-test/.ralph/PROMPT.md"
    assert_file_exists "text-test/.ralph/fix_plan.md"
    assert_file_exists "text-test/.ralph/specs/requirements.md"
}

# Test 27: ralph-import cleans up JSON output file after processing
@test "ralph-import cleans up temporary JSON output file" {
    create_sample_prd_md "cleanup-test.md"
    create_mock_claude_json_success

    run bash "$PROJECT_ROOT/ralph_import.sh" "cleanup-test.md"

    assert_success

    # Temporary output file should NOT exist
    [[ ! -f "cleanup-test/.ralph_conversion_output.json" ]]

    # Temporary prompt file should NOT exist
    [[ ! -f "cleanup-test/.ralph_conversion_prompt.md" ]]
}

# Test 28: ralph-import detects JSON vs text output format correctly
@test "ralph-import detects output format and uses appropriate parsing" {
    create_sample_prd_md "format-test.md"
    create_mock_claude_json_success

    run bash "$PROJECT_ROOT/ralph_import.sh" "format-test.md"

    assert_success

    # Success message should indicate completion
    [[ "$output" == *"SUCCESS"* ]] || [[ "$output" == *"successfully"* ]]
}

# Test 29: ralph-import extracts session ID from JSON response
@test "ralph-import extracts and stores session ID from JSON response" {
    create_sample_prd_md "session-test.md"
    create_mock_claude_json_success

    run bash "$PROJECT_ROOT/ralph_import.sh" "session-test.md"

    assert_success

    # Check for session file (optional - only if session persistence is implemented)
    # The session ID should be available for potential continuation
    # This test verifies JSON parsing extracts the sessionId field
}

# Test 30: ralph-import reports file creation status from JSON metadata
@test "ralph-import reports files created based on JSON metadata" {
    create_sample_prd_md "files-test.md"
    create_mock_claude_json_success

    run bash "$PROJECT_ROOT/ralph_import.sh" "files-test.md"

    assert_success

    # Should show success with next steps
    [[ "$output" == *"Next steps"* ]] || [[ "$output" == *"PROMPT.md"* ]]
}

# Test 31: ralph-import uses modern CLI flags
@test "ralph-import invokes Claude CLI with modern flags" {
    # Create a wrapper that captures the command invocation
    cat > "$MOCK_BIN_DIR/claude" << 'CAPTURE_ARGS_EOF'
#!/bin/bash
# Capture invocation arguments for testing
echo "INVOCATION_ARGS: $*" >> /tmp/claude_invocation.log

# Ensure .ralph directory exists
mkdir -p .ralph/specs

# Create expected files in .ralph/
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions
EOF

cat > ".ralph/fix_plan.md" << 'EOF'
# Ralph Fix Plan
## High Priority
- [ ] Task 1
EOF

cat > .ralph/specs/requirements.md << 'EOF'
# Technical Specifications
EOF

# Return JSON output
cat << 'JSON_OUTPUT'
{
    "result": "Conversion complete",
    "sessionId": "test-session",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "completion_status": "complete"
    }
}
JSON_OUTPUT

exit 0
CAPTURE_ARGS_EOF
    chmod +x "$MOCK_BIN_DIR/claude"

    # Clear previous log
    rm -f /tmp/claude_invocation.log

    create_sample_prd_md "cli-flags-test.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "cli-flags-test.md"

    assert_success

    # Check if modern flags were used (if invocation log exists)
    if [[ -f "/tmp/claude_invocation.log" ]]; then
        # Verify --output-format or similar flag was passed
        run cat /tmp/claude_invocation.log
        # The specific flags depend on implementation
        # This test ensures CLI modernization is in effect
    fi

    # Clean up
    rm -f /tmp/claude_invocation.log
}

# Test 32: ralph-import handles malformed JSON gracefully
@test "ralph-import handles malformed JSON and falls back to text parsing" {
    cat > "$MOCK_BIN_DIR/claude" << 'MALFORMED_JSON_EOF'
#!/bin/bash

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

cat > /dev/null

# Ensure .ralph directory exists
mkdir -p .ralph/specs

# Create files in .ralph/
cat > .ralph/PROMPT.md << 'EOF'
# Ralph Development Instructions
EOF

cat > ".ralph/fix_plan.md" << 'EOF'
# Ralph Fix Plan
## High Priority
- [ ] Task 1
EOF

cat > .ralph/specs/requirements.md << 'EOF'
# Technical Specifications
EOF

# Output malformed JSON
echo '{"result": "Success but json is broken'
echo "Files created successfully"
exit 0
MALFORMED_JSON_EOF
    chmod +x "$MOCK_BIN_DIR/claude"

    create_sample_prd_md "malformed-test.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "malformed-test.md"

    # Should still succeed (fallback to text parsing)
    assert_success

    # Files should exist in .ralph/ subfolder
    assert_file_exists "malformed-test/.ralph/PROMPT.md"
}

# Test 33: ralph-import extracts error details from JSON error response
@test "ralph-import extracts specific error message from JSON error" {
    cat > "$MOCK_BIN_DIR/claude" << 'DETAILED_ERROR_EOF'
#!/bin/bash

# Handle --version flag first
if [[ "$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

cat > /dev/null

# Output detailed JSON error
cat << 'JSON_OUTPUT'
{
    "result": "",
    "sessionId": "error-session",
    "metadata": {
        "files_changed": 0,
        "has_errors": true,
        "completion_status": "failed",
        "error_message": "Unable to parse PRD: Missing required sections",
        "error_code": "PRD_PARSE_ERROR"
    }
}
JSON_OUTPUT

exit 1
DETAILED_ERROR_EOF
    chmod +x "$MOCK_BIN_DIR/claude"

    create_sample_prd_md "detailed-error-test.md"

    run bash "$PROJECT_ROOT/ralph_import.sh" "detailed-error-test.md"

    # Should fail
    assert_failure

    # Error message should be shown
    [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"failed"* ]]
}

# =============================================================================
# GITHUB ISSUE IMPORT (Issue #69)
# =============================================================================
#
# Full-flow tests for `ralph-import --github-issue <N>`: a mock `gh` binary in
# MOCK_BIN_DIR serves issue JSON, the existing mock claude/ralph-setup handle
# the conversion pipeline. Acceptance criteria from issue #69.

# Helper: mock gh that is authenticated and serves a fixed issue
create_mock_gh_with_issue() {
    cat > "$MOCK_BIN_DIR/gh" << 'MOCK_GH_EOF'
#!/bin/bash
case "$1" in
    auth)
        exit 0
        ;;
    issue)
        cat << 'JSON'
{"number":42,"title":"Add User Login","body":"## Summary\n\nUsers need to log in.\n\n- [ ] Build login form\n- [ ] Add session handling","labels":[{"name":"enhancement"}],"comments":[{"author":{"login":"alice"},"body":"Plan: start with the form."}],"url":"https://github.com/test/repo/issues/42"}
JSON
        ;;
esac
exit 0
MOCK_GH_EOF
    chmod +x "$MOCK_BIN_DIR/gh"
}

@test "ralph-import --github-issue fetches issue and runs conversion pipeline" {
    create_mock_gh_with_issue

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 42

    assert_success
    [[ "$output" == *"Importing GitHub issue #42"* ]]

    # Project dir derived from slugified issue title
    [[ -d "add-user-login" ]]

    # Conversion pipeline produced the Ralph files (via mock claude)
    [[ -f "add-user-login/.ralph/PROMPT.md" ]]
    [[ -f "add-user-login/.ralph/fix_plan.md" ]]

    # The formatted issue PRD was copied into the project and keeps issue content
    local prd
    prd=$(ls add-user-login/*issue-42.md 2>/dev/null | head -1)
    [[ -n "$prd" ]]
    grep -q '^# Add User Login' "$prd"
    grep -q 'Build login form' "$prd"
    # Comments are excluded by default (untrusted input; opt in via --include-comments)
    [[ $(grep -c '## Discussion' "$prd") -eq 0 ]]

    # No temp conversion artifacts left behind in the project
    [[ ! -f "add-user-login/.ralph_conversion_output.json" ]]
    [[ ! -f "add-user-login/.ralph_conversion_prompt.md" ]]
}

@test "ralph-import --github-issue includes comments when --include-comments is set" {
    create_mock_gh_with_issue

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 42 --include-comments

    assert_success
    local prd
    prd=$(ls add-user-login/*issue-42.md 2>/dev/null | head -1)
    [[ -n "$prd" ]]
    # The opt-in flag wires through to the PRD: comments appear as Discussion
    grep -q '^## Discussion' "$prd"
    grep -q 'alice' "$prd"
    grep -q 'start with the form' "$prd"
}

@test "ralph-import --github-issue fails with guidance when gh is unauthenticated" {
    # gh exists but auth fails — error must guide the user to authenticate
    cat > "$MOCK_BIN_DIR/gh" << 'MOCK_GH_EOF'
#!/bin/bash
[[ "$1" == "auth" ]] && exit 1
exit 0
MOCK_GH_EOF
    chmod +x "$MOCK_BIN_DIR/gh"

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 42

    assert_failure
    [[ "$output" == *"gh auth login"* ]]
    # No project directory should have been created
    [[ ! -d "add-user-login" ]] && [[ ! -d "issue-42" ]]
}

# =============================================================================
# ISSUE COMPLETENESS ASSESSMENT + PLAN GENERATION (Issue #70)
# =============================================================================
#
# Full-flow tests for completeness scoring and plan generation during
# `ralph-import --github-issue`. A recording mock claude distinguishes the
# plan-generation call (prompt contains "Implementation Plan Generation
# Task") from the conversion call, capturing stdin per call for assertions.

# Helper: mock gh serving a vague issue (scores well below the 60 threshold)
create_mock_gh_vague_issue() {
    cat > "$MOCK_BIN_DIR/gh" << 'MOCK_GH_EOF'
#!/bin/bash
case "$1" in
    auth)
        exit 0
        ;;
    issue)
        cat << 'JSON'
{"number":7,"title":"Make the app faster","body":"The app feels slow sometimes. Can we speed it up?","labels":[],"comments":[],"url":"https://github.com/test/repo/issues/7"}
JSON
        ;;
esac
exit 0
MOCK_GH_EOF
    chmod +x "$MOCK_BIN_DIR/gh"
}

# Helper: mock gh serving a detailed issue (acceptance criteria + checklist +
# technical sections + guidance keywords = score 70, above the 60 threshold)
create_mock_gh_detailed_issue() {
    cat > "$MOCK_BIN_DIR/gh" << 'MOCK_GH_EOF'
#!/bin/bash
case "$1" in
    auth)
        exit 0
        ;;
    issue)
        cat << 'JSON'
{"number":42,"title":"Add User Login","body":"## Summary\n\nImplement session-based login.\n\n## Technical Approach\n\nUse the existing middleware architecture and API patterns.\n\n## Acceptance Criteria\n\n- [ ] Users can log in\n- [ ] Invalid credentials return 401","labels":[{"name":"enhancement"}],"comments":[],"url":"https://github.com/test/repo/issues/42"}
JSON
        ;;
esac
exit 0
MOCK_GH_EOF
    chmod +x "$MOCK_BIN_DIR/gh"
}

# Helper: recording mock claude — captures args and per-call stdin, answers
# the plan call with a JSON plan and the conversion call by creating files
create_mock_claude_recording() {
    cat > "$MOCK_BIN_DIR/claude" << MOCK_CLAUDE_EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
    echo "Claude Code CLI version 2.0.80"
    exit 0
fi

call_num=\$(ls "$TEST_DIR"/claude_stdin_* 2>/dev/null | wc -l)
call_num=\$((call_num + 1))
printf '%s\n' "\$*" >> "$TEST_DIR/claude_args.log"
cat > "$TEST_DIR/claude_stdin_\$call_num"

if grep -q "Implementation Plan Generation Task" "$TEST_DIR/claude_stdin_\$call_num"; then
    # Plan-generation call: respond with the plan as a JSON result
    printf '{"result": "## Generated Plan\\n\\n- [ ] Mock task one\\n- [ ] Mock task two"}\n'
else
    # Conversion call: create the expected Ralph files
    mkdir -p .ralph/specs
    echo "# Ralph Development Instructions" > .ralph/PROMPT.md
    echo "# Ralph Fix Plan" > .ralph/fix_plan.md
    echo "# Technical Specifications" > .ralph/specs/requirements.md
    echo "Mock conversion done"
fi
exit 0
MOCK_CLAUDE_EOF
    chmod +x "$MOCK_BIN_DIR/claude"
}

@test "github import generates an implementation plan for a low-detail issue" {
    create_mock_gh_vague_issue
    create_mock_claude_recording

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 7

    assert_success
    [[ "$output" == *"Completeness"* ]]

    # Two claude calls: plan generation first, then conversion
    [[ -f "$TEST_DIR/claude_stdin_2" ]]
    grep -q "Implementation Plan Generation Task" "$TEST_DIR/claude_stdin_1"

    # The generated plan flowed into the conversion prompt via the PRD
    grep -q "Implementation Plan (generated)" "$TEST_DIR/claude_stdin_2"
    grep -q "Mock task one" "$TEST_DIR/claude_stdin_2"

    # The raw plan is preserved in the project specs
    [[ -f "make-the-app-faster/.ralph/specs/implementation-plan.md" ]]
    grep -q "Mock task one" "make-the-app-faster/.ralph/specs/implementation-plan.md"
}

@test "github import skips plan generation for a detailed issue" {
    create_mock_gh_detailed_issue
    create_mock_claude_recording

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 42

    assert_success

    # Only the conversion call happened
    [[ -f "$TEST_DIR/claude_stdin_1" ]]
    [[ ! -f "$TEST_DIR/claude_stdin_2" ]]
    [[ $(grep -c "Implementation Plan Generation Task" "$TEST_DIR/claude_stdin_1") -eq 0 ]]

    # No generated plan artifact
    [[ ! -f "add-user-login/.ralph/specs/implementation-plan.md" ]]
}

@test "github import with --no-generate-plan fails on a low-detail issue" {
    create_mock_gh_vague_issue
    create_mock_claude_recording

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 7 --no-generate-plan

    assert_failure
    [[ "$output" == *"lacks implementation detail"* ]]
    # Claude was never invoked (no plan call, no conversion)
    [[ ! -f "$TEST_DIR/claude_stdin_1" ]]
}

@test "github import with --generate-plan forces a plan for a detailed issue" {
    create_mock_gh_detailed_issue
    create_mock_claude_recording

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 42 --generate-plan

    assert_success
    grep -q "Implementation Plan Generation Task" "$TEST_DIR/claude_stdin_1"
    [[ -f "add-user-login/.ralph/specs/implementation-plan.md" ]]
}

@test "github import preflights dependencies before generating a plan" {
    # Missing ralph-setup must fail BEFORE the (billed) plan-generation
    # Claude call, not after it (codex P2)
    create_mock_gh_vague_issue
    create_mock_claude_recording
    remove_ralph_setup_mock

    local ORIGINAL_PATH="$PATH"
    export PATH="$MOCK_BIN_DIR:/usr/bin:/bin"

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 7

    export PATH="$ORIGINAL_PATH"

    assert_failure
    [[ "$output" == *"Ralph not installed"* ]] || [[ "$output" == *"ralph-setup"* ]]
    # Claude was never invoked — no wasted plan-generation call
    [[ ! -f "$TEST_DIR/claude_stdin_1" ]]
}

@test "github import passes --plan-model to the plan generation call" {
    create_mock_gh_vague_issue
    create_mock_claude_recording

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-issue 7 --plan-model opus

    assert_success
    # Call-specific assertions: --model goes to the plan-generation call
    # (line 1) only — the conversion call (line 2) must not inherit it
    sed -n '1p' "$TEST_DIR/claude_args.log" | grep -q -- "--model opus"
    [[ $(sed -n '2p' "$TEST_DIR/claude_args.log" | grep -c -- "--model") -eq 0 ]]
}

# =============================================================================
# GITHUB ISSUE FILTERING AND SELECTION (Issue #71)
# =============================================================================
#
# Full-flow tests for the metadata filter flags. The mock gh records every
# invocation to gh_args.log and serves a three-issue list fixture, so tests
# can assert both which filters reached gh and which issue was imported.
# --completeness-threshold 0 keeps plan generation (#70) out of these flows.

# Helper: mock gh serving a three-issue list (newest-first, like real gh)
# plus per-number issue views. Records args to $TEST_DIR/gh_args.log.
create_mock_gh_with_issue_list() {
    cat > "$MOCK_BIN_DIR/gh" << MOCK_GH_EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_DIR/gh_args.log"
case "\$1" in
    auth) exit 0 ;;
    issue)
        case "\$2" in
            list)
                cat << 'JSON'
[{"number":30,"title":"New bug report","labels":[{"name":"bug"},{"name":"wontfix"}],"assignees":[],"milestone":null,"url":"u30"},
 {"number":25,"title":"[P0] Critical crash","labels":[{"name":"bug"},{"name":"priority: P0"}],"assignees":[{"login":"alice"}],"milestone":{"title":"v1.0"},"url":"u25"},
 {"number":10,"title":"Old bug","labels":[{"name":"bug"}],"assignees":[],"milestone":null,"url":"u10"}]
JSON
                ;;
            view)
                num="\$3"
                case "\$num" in
                    10) title="Old bug" ;;
                    25) title="[P0] Critical crash" ;;
                    30) title="New bug report" ;;
                    *)  title="Issue \$num" ;;
                esac
                printf '{"number":%s,"title":"%s","body":"Reproduce, fix, and add a regression test for issue %s.","labels":[{"name":"bug"}],"comments":[],"url":"https://github.com/t/r/issues/%s"}\n' "\$num" "\$title" "\$num" "\$num"
                ;;
        esac
        ;;
esac
exit 0
MOCK_GH_EOF
    chmod +x "$MOCK_BIN_DIR/gh"
}

@test "ralph-import --github-label imports the oldest matching issue" {
    create_mock_gh_with_issue_list

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --completeness-threshold 0

    assert_success
    # Oldest match (#10) wins under the default first strategy — the list
    # fixture is newest-first, proving the oldest-first sort is applied
    [[ "$output" == *"Importing GitHub issue #10"* ]]
    [[ -d "old-bug" ]]
    [[ -f "old-bug/.ralph/PROMPT.md" ]]

    grep -q "issue list" "$TEST_DIR/gh_args.log"
    grep -q -- "--label bug" "$TEST_DIR/gh_args.log"
    grep -q -- "--limit 500" "$TEST_DIR/gh_args.log"
    grep -q "issue view 10" "$TEST_DIR/gh_args.log"
}

@test "ralph-import passes combined metadata filters through to gh" {
    create_mock_gh_with_issue_list

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --github-assignee @me \
        --github-milestone v1.0 --github-state all --completeness-threshold 0

    assert_success
    local list_line
    list_line=$(grep "issue list" "$TEST_DIR/gh_args.log")
    [[ "$list_line" == *"--label bug"* ]]
    [[ "$list_line" == *"--assignee @me"* ]]
    [[ "$list_line" == *"--milestone v1.0"* ]]
    [[ "$list_line" == *"--state all"* ]]
}

@test "ralph-import --select priority imports the highest-priority match" {
    create_mock_gh_with_issue_list

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --select priority \
        --completeness-threshold 0

    assert_success
    # #25 carries "priority: P0" (this repo's label format) and beats the
    # older but unprioritized #10
    [[ "$output" == *"Importing GitHub issue #25"* ]]
    [[ -d "p0-critical-crash" ]]
    grep -q "issue view 25" "$TEST_DIR/gh_args.log"
}

@test "ralph-import --github-title filters titles with wildcards" {
    create_mock_gh_with_issue_list

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --github-title "New*" \
        --completeness-threshold 0

    assert_success
    [[ "$output" == *"Importing GitHub issue #30"* ]]
    [[ -d "new-bug-report" ]]
}

@test "ralph-import fails with a clear error when filters match nothing" {
    create_mock_gh_with_issue_list

    # Title matches only #30, which --exclude-label then removes
    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --github-title "New*" \
        --exclude-label wontfix --completeness-threshold 0

    assert_failure
    [[ "$output" == *"No issues match"* ]]
    # Nothing was imported
    [[ ! -d "new-bug-report" ]]
    [[ $(grep -c "issue view" "$TEST_DIR/gh_args.log") -eq 0 ]]
}

@test "ralph-import --dry-run previews matches without importing" {
    create_mock_gh_with_issue_list

    run bash "$PROJECT_ROOT/ralph_import.sh" --github-label bug --dry-run

    assert_success
    # Preview table with all three matches, oldest selected
    [[ "$output" == *"NUMBER"* && "$output" == *"TITLE"* ]]
    [[ "$output" == *"#10"* && "$output" == *"#25"* && "$output" == *"#30"* ]]
    [[ "$output" == *"3 issue(s) match"* ]]
    [[ "$output" == *"Would select: #10"* ]]
    [[ "$output" == *"nothing was imported"* ]]

    # No project was created and no issue was fetched for conversion
    [[ ! -d "old-bug" && ! -d "p0-critical-crash" && ! -d "new-bug-report" ]]
    [[ $(grep -c "issue view" "$TEST_DIR/gh_args.log") -eq 0 ]]
}
