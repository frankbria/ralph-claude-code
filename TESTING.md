# Testing Guide for Ralph Claude Code

This document provides comprehensive guidance for running, writing, and maintaining tests for the Ralph Claude Code project.

## Overview

Ralph uses [Bats (Bash Automated Testing System)](https://github.com/bats-core/bats-core) for testing bash scripts. The test suite covers:

- **Unit tests**: Individual function testing
- **Integration tests**: Multi-component interaction testing
- **Security tests**: Vulnerability prevention testing
- **Log rotation tests**: File management testing

## Test Structure

```
tests/
├── helpers/
│   ├── test_helper.bash    # Common test utilities and assertions
│   └── fixtures.bash       # Test fixtures and mock data
├── unit/
│   ├── test_cli_parsing.bats     # CLI argument parsing (27 tests)
│   ├── test_cli_modern.bats      # Modern CLI features (23 tests)
│   ├── test_json_parsing.bats    # JSON output parsing (20 tests)
│   ├── test_exit_detection.bats  # Exit signal detection (20 tests)
│   ├── test_rate_limiting.bats   # Rate limiting behavior (15 tests)
│   ├── test_security.bats        # Security features (20 tests)
│   └── test_log_rotation.bats    # Log rotation (22 tests)
└── integration/
    ├── test_loop_execution.bats  # Full loop integration (20 tests)
    └── test_edge_cases.bats      # Edge case handling (20 tests)
```

## Running Tests

### Prerequisites

1. **Install Node.js and npm** (for npx/bats)
2. **Install jq** (JSON processing)
3. **Install git** (for git-based tests)

### Run All Tests

```bash
# Using npm
npm test

# Using npx directly
npx bats tests/
```

### Run Specific Test Categories

```bash
# Unit tests only
npm run test:unit
npx bats tests/unit/

# Integration tests only
npm run test:integration
npx bats tests/integration/

# Specific test file
npx bats tests/unit/test_cli_parsing.bats
```

### Run Individual Tests

```bash
# Run a single test by name
npx bats tests/unit/test_security.bats -f "session expiration"
```

### Verbose Output

```bash
# Show detailed output for each test
npx bats tests/ --verbose-run
```

## Writing Tests

### Basic Test Structure

```bash
#!/usr/bin/env bats

# Load test helpers
load '../helpers/test_helper'

# Setup runs before each test
setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
}

# Teardown runs after each test
teardown() {
    cd /
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Test cases
@test "descriptive test name" {
    # Arrange
    local input="test value"

    # Act
    run some_function "$input"

    # Assert
    [ "$status" -eq 0 ]
    [ "$output" == "expected output" ]
}
```

### Available Assertions

The test helper provides these assertion functions:

```bash
assert_success              # Verify $status == 0
assert_failure              # Verify $status != 0
assert_equal "$a" "$b"      # Verify $a == $b
assert_output "expected"    # Verify $output == "expected"
assert_file_exists "$file"  # Verify file exists
assert_dir_exists "$dir"    # Verify directory exists
assert_valid_json "$file"   # Verify file contains valid JSON
```

### Testing Functions

When testing functions from ralph_loop.sh, you often can't source the entire script because it executes `main()`. Instead, define the function inline:

```bash
@test "my function test" {
    # Define the function to test
    my_function() {
        local input=$1
        echo "processed: $input"
    }

    run my_function "test"
    [ "$output" == "processed: test" ]
}
```

### Creating Mock Files

```bash
@test "test with mock files" {
    # Create mock PROMPT.md
    echo "# Test Prompt" > PROMPT.md

    # Create mock @fix_plan.md
    cat > "@fix_plan.md" << 'EOF'
- [ ] Task 1
- [x] Task 2
EOF

    # Create mock circuit breaker state
    cat > ".circuit_breaker_state" << 'EOF'
{
    "state": "CLOSED",
    "consecutive_no_progress": 0
}
EOF
}
```

### Testing with JSON

```bash
@test "JSON parsing test" {
    local json='{"status": "complete", "files": 5}'

    # Parse JSON field
    local status=$(echo "$json" | jq -r '.status')
    [ "$status" == "complete" ]

    # Verify JSON structure
    echo "$json" > test.json
    assert_valid_json "test.json"
}
```

## Test Categories

### Unit Tests

Unit tests focus on individual functions in isolation:

| File | Tests | Focus |
|------|-------|-------|
| test_cli_parsing.bats | 27 | All 12 CLI flags, validation |
| test_cli_modern.bats | 23 | Phase 1.1 modern CLI features |
| test_json_parsing.bats | 20 | JSON output format handling |
| test_exit_detection.bats | 20 | Completion signal detection |
| test_rate_limiting.bats | 15 | API call rate management |
| test_security.bats | 20 | Session, validation, sanitization |
| test_log_rotation.bats | 22 | Log file management |

### Integration Tests

Integration tests verify component interaction:

| File | Tests | Focus |
|------|-------|-------|
| test_loop_execution.bats | 20 | Full loop behavior |
| test_edge_cases.bats | 20 | Boundary conditions, error handling |

### Security Tests

Security tests verify protection mechanisms:

- Session expiration (24-hour TTL)
- Tool whitelist validation
- Shell injection prevention
- Path sanitization
- Version parsing safety

### Log Rotation Tests

Log rotation tests verify file management:

- File size detection
- Rotation triggering
- Backup file management
- Old file cleanup
- Statistics reporting

## Coverage

### Notes on Coverage

Due to kcov subprocess limitations with bats, code coverage measurement is informational only. The test pass rate (100%) is the enforced quality gate.

```bash
# Run with coverage (informational)
kcov --include-path=. coverage/ npx bats tests/
```

### Coverage Goals

- **Test pass rate**: 100% (enforced)
- **Code coverage**: 85%+ (aspirational for bash)
- **Critical paths**: Must have tests

## Best Practices

### 1. Test Isolation

Each test should:
- Use a fresh temporary directory
- Not depend on other tests
- Clean up after itself

```bash
setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}
```

### 2. Descriptive Names

Use clear, descriptive test names:

```bash
# Good
@test "validate_allowed_tools rejects shell injection attempts"

# Bad
@test "test validation"
```

### 3. Arrange-Act-Assert Pattern

Structure tests clearly:

```bash
@test "rate limiter blocks excess calls" {
    # Arrange
    echo "100" > .call_count
    MAX_CALLS_PER_HOUR=100

    # Act
    run can_make_call

    # Assert
    assert_failure
}
```

### 4. Test Edge Cases

Always include tests for:
- Empty inputs
- Invalid inputs
- Boundary values
- Error conditions

```bash
@test "handles empty file gracefully" {
    touch empty_file
    run process_file "empty_file"
    assert_success
}
```

### 5. Mock External Dependencies

When testing functions that call external tools:

```bash
@test "git integration" {
    # Initialize git for test
    git init
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create and stage a file
    echo "test" > test.txt
    git add test.txt

    # Test expects uncommitted changes
    run check_git_status
    [[ "$output" == *"modified"* ]]
}
```

## CI/CD Integration

Tests run automatically on:
- Push to `main` or `develop`
- Pull requests to `main`

See `.github/workflows/test.yml` for configuration.

### Required Checks

- All tests must pass
- No test failures allowed
- Coverage artifacts uploaded (informational)

## Troubleshooting

### Common Issues

**1. "bats: command not found"**
```bash
# Use npx to run bats
npx bats tests/
```

**2. "test_helper not found"**
```bash
# Ensure you're using the correct path
load '../helpers/test_helper'  # Not '../test_helper'
```

**3. Tests hang or timeout**
```bash
# Check for infinite loops in mocked functions
# Ensure setup() completes quickly
```

**4. Permission errors**
```bash
# Ensure test directory is writable
chmod +w "$TEST_DIR"
```

### Debug Mode

```bash
# Run with debug output
DEBUG=1 npx bats tests/unit/test_security.bats

# Show test output even on success
npx bats tests/ --show-output-of-passing-tests
```

## Adding New Tests

When adding new features:

1. Create test file in appropriate directory
2. Follow existing naming conventions
3. Load test_helper
4. Include setup/teardown
5. Write tests before implementation (TDD)
6. Verify all tests pass
7. Update this documentation if needed

## Maintenance

### Regular Tasks

- Keep tests in sync with code changes
- Remove obsolete tests
- Update test fixtures when formats change
- Review and optimize slow tests

### Test Quality Checks

- Tests should run quickly (<1 second each)
- Tests should be deterministic (no flaky tests)
- Tests should be independent
- Tests should have clear assertions
