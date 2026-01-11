# Testing Guide for Ralph

This guide provides comprehensive documentation for the Ralph test suite, helping contributors understand how to run, write, and maintain tests.

**Current Status**: 276 tests | 100% pass rate | CI/CD via GitHub Actions

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Test Organization](#test-organization)
3. [Writing Tests](#writing-tests)
4. [Test Helpers](#test-helpers)
5. [Coverage Requirements](#coverage-requirements)
6. [CI/CD Integration](#cicd-integration)
7. [Troubleshooting](#troubleshooting)

---

## Quick Start

### Prerequisites

Ensure you have the following installed:

```bash
# Node.js 18+ and npm
node --version  # Should show v18+
npm --version

# jq for JSON processing
jq --version    # Used by test fixtures

# git for integration tests
git --version
```

### Install Test Dependencies

```bash
npm install
```

This installs:
- **bats** (v1.12.0) - Bash Automated Testing System
- **bats-assert** - Assertion library
- **bats-support** - Support functions

### Run All Tests

```bash
# Run the complete test suite (unit + integration)
npm test

# Expected output:
# 1..276
# ok 1 - ...
# ok 2 - ...
# ...
# 276 tests, 0 failures
```

### Run Tests by Category

```bash
# Unit tests only (fast, isolated function tests)
npm run test:unit

# Integration tests only (component interaction tests)
npm run test:integration

# E2E tests only (full workflow tests)
npm run test:e2e
```

### Run Individual Test Files

```bash
# Run a specific test file
bats tests/unit/test_rate_limiting.bats

# Run with verbose output for debugging
bats --verbose-run tests/unit/test_cli_parsing.bats

# Run a single test by pattern (partial match)
bats tests/unit/test_rate_limiting.bats --filter "can_make_call"
```

---

## Test Organization

### Directory Structure

```
tests/
├── unit/                           # Isolated function tests
│   ├── test_rate_limiting.bats     # Rate limiting behavior (15 tests)
│   ├── test_exit_detection.bats    # Exit signal detection (20 tests)
│   ├── test_cli_parsing.bats       # CLI argument parsing (27 tests)
│   ├── test_cli_modern.bats        # Modern CLI features (29 tests)
│   ├── test_json_parsing.bats      # JSON output parsing (36 tests)
│   └── test_session_continuity.bats # Session lifecycle (26 tests)
│
├── integration/                    # Component interaction tests
│   ├── test_loop_execution.bats    # Main loop behavior (20 tests)
│   ├── test_edge_cases.bats        # Edge case handling (20 tests)
│   ├── test_installation.bats      # Global install workflow (14 tests)
│   ├── test_project_setup.bats     # Project setup (setup.sh) (36 tests)
│   └── test_prd_import.bats        # PRD import workflow (33 tests)
│
├── e2e/                            # End-to-end tests (planned)
│
└── helpers/                        # Shared test utilities
    ├── test_helper.bash            # Assertions and setup functions
    ├── mocks.bash                  # Mock functions for external commands
    └── fixtures.bash               # Sample data generators
```

### Test Categories

| Category | Purpose | Execution Speed | Dependencies |
|----------|---------|-----------------|--------------|
| **Unit** | Test individual functions in isolation | Fast (<1s per file) | None (uses mocks) |
| **Integration** | Test component interactions | Medium (1-5s per file) | Real git, filesystem |
| **E2E** | Test complete workflows | Slow (>5s per file) | Full environment |

### Naming Conventions

- **Test files**: `test_<component_name>.bats`
- **Test functions**: Descriptive sentences: `@test "can_make_call returns success when under limit"`
- **Location**: Place tests in `unit/` or `integration/` based on scope

---

## Writing Tests

### BATS Fundamentals

BATS (Bash Automated Testing System) is our testing framework. Each `.bats` file contains test cases that run in isolated subshells.

#### Basic Test Structure

```bash
#!/usr/bin/env bats
# Description of what this file tests

# Load helper functions (required)
load '../helpers/test_helper'

# Setup runs before EACH test
setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    # Initialize test environment...
}

# Teardown runs after EACH test
teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Test case syntax: @test "description" { commands }
@test "descriptive name of what is being tested" {
    # Arrange: set up test conditions
    echo "50" > "$CALL_COUNT_FILE"

    # Act: run the command being tested
    run my_function

    # Assert: verify the results
    assert_success
    assert_equal "$output" "expected output"
}
```

#### The `run` Command

The `run` command captures output and exit status:

```bash
@test "example using run command" {
    run ls /nonexistent

    # $status contains exit code (0 = success)
    echo "Exit code was: $status"

    # $output contains stdout + stderr
    echo "Output was: $output"

    # Assert on these values
    assert_failure                    # Expect non-zero exit
    [[ "$output" == *"No such"* ]]   # Check output contains text
}
```

### Example: Unit Test

From `tests/unit/test_rate_limiting.bats`:

```bash
#!/usr/bin/env bats
# Unit Tests for Rate Limiting Logic

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    export MAX_CALLS_PER_HOUR=100
    export CALL_COUNT_FILE=".call_count"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    echo "0" > "$CALL_COUNT_FILE"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Define the function being tested (extracted from production code)
can_make_call() {
    local calls_made=0
    [[ -f "$CALL_COUNT_FILE" ]] && calls_made=$(cat "$CALL_COUNT_FILE")
    [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]] && return 1
    return 0
}

@test "can_make_call returns success when under limit" {
    echo "50" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_success
}

@test "can_make_call returns failure when at limit" {
    echo "100" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_failure
}
```

### Example: Integration Test

From `tests/integration/test_project_setup.bats`:

```bash
#!/usr/bin/env bats
# Integration tests for setup.sh project initialization

load '../helpers/test_helper'
load '../helpers/fixtures'

SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../../setup.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.ralph/templates"

    # Copy real templates for integration testing
    cp -r "${BATS_TEST_DIRNAME}/../../templates/"* "$HOME/.ralph/templates/"

    cd "$TEST_TEMP_DIR"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "setup.sh creates project directory with correct structure" {
    run bash "$SETUP_SCRIPT" "test-project"

    assert_success
    assert_dir_exists "$TEST_TEMP_DIR/test-project"
    assert_dir_exists "$TEST_TEMP_DIR/test-project/specs"
    assert_dir_exists "$TEST_TEMP_DIR/test-project/src"
    assert_dir_exists "$TEST_TEMP_DIR/test-project/logs"
}

@test "setup.sh initializes git repository" {
    bash "$SETUP_SCRIPT" "test-project"

    cd "$TEST_TEMP_DIR/test-project"
    [[ -d ".git" ]]

    run git log --oneline -1
    assert_success
    [[ "$output" == *"Initial commit"* ]]
}
```

### Example: Testing with Mocks

When testing functions that call external commands:

```bash
#!/usr/bin/env bats

load '../helpers/test_helper'
load '../helpers/mocks'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/mocks.bash"
    setup_mocks  # Replace git, tmux, etc. with mocks

    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
}

teardown() {
    teardown_mocks  # Restore original commands
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "function handles git unavailable gracefully" {
    # Configure mock to simulate git not installed
    export MOCK_GIT_AVAILABLE=false

    run function_that_uses_git

    assert_failure
    [[ "$output" == *"git: command not found"* ]]
}

@test "function uses Claude Code successfully" {
    # Configure successful mock response
    export MOCK_CLAUDE_SUCCESS=true
    export MOCK_CLAUDE_OUTPUT="Task completed"

    run function_that_calls_claude

    assert_success
    [[ "$output" == *"Task completed"* ]]
}
```

### Best Practices

1. **Test One Thing**: Each test should verify a single behavior
   ```bash
   # Good: focused test
   @test "increment counter increases value by 1" { ... }

   # Bad: multiple behaviors
   @test "counter increments and respects limit and resets hourly" { ... }
   ```

2. **Descriptive Names**: Tests should read as documentation
   ```bash
   # Good: clear intent
   @test "can_make_call returns failure when at limit"

   # Bad: unclear
   @test "test limit"
   ```

3. **Isolate Tests**: Each test should set up its own state
   ```bash
   setup() {
       export TEST_TEMP_DIR="$(mktemp -d)"  # Fresh directory each test
       cd "$TEST_TEMP_DIR"
   }
   ```

4. **Clean Up**: Always restore state in teardown
   ```bash
   teardown() {
       teardown_mocks  # Restore mocked commands
       cd /
       rm -rf "$TEST_TEMP_DIR"  # Clean up files
   }
   ```

5. **Use Helpers**: Don't duplicate setup/assertion code
   ```bash
   # Good: use provided helpers
   assert_file_exists "output.txt"
   assert_valid_json "data.json"

   # Bad: inline checks
   [[ -f "output.txt" ]] || fail "File missing"
   ```

---

## Test Helpers

### test_helper.bash

Located at `tests/helpers/test_helper.bash`, provides core utilities:

#### Assertion Functions

```bash
# Exit status assertions
assert_success              # Assert $status == 0
assert_failure              # Assert $status != 0

# Value assertions
assert_equal "$actual" "$expected"    # Compare two values
assert_output "expected text"         # Compare $output exactly

# File assertions
assert_file_exists "path/to/file"     # File must exist
assert_file_not_exists "path/to/file" # File must NOT exist
assert_dir_exists "path/to/dir"       # Directory must exist

# JSON assertions
assert_valid_json "file.json"         # Validate JSON syntax
get_json_field "file.json" "field"    # Extract field value
```

#### Setup Utilities

```bash
# Provided environment variables (set in setup)
$TEST_TEMP_DIR      # Unique temp directory for this test
$PROMPT_FILE        # "PROMPT.md"
$LOG_DIR            # "logs"
$STATUS_FILE        # "status.json"
$CALL_COUNT_FILE    # ".call_count"
$EXIT_SIGNALS_FILE  # ".exit_signals"

# Mock data creation
create_mock_prompt          # Create sample PROMPT.md
create_mock_fix_plan 5 2    # Create @fix_plan.md (5 total, 2 completed)
create_mock_status 1 42 100 # Create status.json (loop 1, 42 calls, 100 max)
create_mock_exit_signals 0 2 0  # Create exit signals (0 test, 2 done, 0 complete)
```

#### Date Mocking

```bash
# Mock date for deterministic tests
mock_date "2025093012"      # Set fixed date
# ... run tests ...
restore_date                # Restore system date
```

### mocks.bash

Located at `tests/helpers/mocks.bash`, provides mock implementations:

#### Available Mocks

```bash
# Claude Code CLI mock
mock_claude_code()     # Configurable via MOCK_CLAUDE_* vars
  MOCK_CLAUDE_SUCCESS=true|false
  MOCK_CLAUDE_OUTPUT="response text"
  MOCK_CLAUDE_EXIT_CODE=0

# tmux mock (terminal multiplexer)
mock_tmux()            # Configurable via MOCK_TMUX_* vars
  MOCK_TMUX_AVAILABLE=true|false

# git mock
mock_git()             # Configurable via MOCK_GIT_* vars
  MOCK_GIT_AVAILABLE=true|false
  MOCK_GIT_REPO=true|false

# Other mocks
mock_notify_send()     # Desktop notifications
mock_osascript()       # macOS notifications
mock_stat()            # File statistics
mock_timeout()         # Command timeout
```

#### Using Mocks

```bash
setup() {
    source ".../helpers/mocks.bash"
    setup_mocks  # Install all mocks
}

teardown() {
    teardown_mocks  # Remove all mocks
}

@test "example with mock configuration" {
    # Configure mock behavior
    export MOCK_CLAUDE_SUCCESS=true
    export MOCK_CLAUDE_OUTPUT='{"status": "complete"}'

    run my_function_that_calls_claude

    assert_success
}
```

### fixtures.bash

Located at `tests/helpers/fixtures.bash`, provides sample data:

#### PRD Fixtures

```bash
# Create sample PRD documents
create_sample_prd_md "output.md"    # Markdown PRD
create_sample_prd_txt "output.txt"  # Plain text PRD
create_sample_prd_json "output.json" # JSON PRD
```

#### Project Fixtures

```bash
# Create sample Ralph project files
create_sample_prompt "PROMPT.md"
create_sample_fix_plan "@fix_plan.md" 10 3  # 10 tasks, 3 completed
create_sample_agent_md "@AGENT.md"

# Create complete project structure
create_test_project "project-name"
# Creates: PROMPT.md, @fix_plan.md, @AGENT.md, specs/, src/, logs/, etc.
```

#### Output Fixtures

```bash
# Create sample Claude outputs
create_sample_claude_output_success "output.log"  # Successful run
create_sample_claude_output_error "output.log"    # Error response
create_sample_claude_output_limit "output.log"    # Rate limit hit

# Create sample status files
create_sample_status_running "status.json"
create_sample_status_completed "status.json"
create_sample_progress_executing "progress.json"
```

---

## Coverage Requirements

### Quality Gates

| Metric | Requirement | Enforcement |
|--------|-------------|-------------|
| **Test Pass Rate** | 100% | **Blocking** - CI fails on any test failure |
| **Coverage Target** | 85%+ | Informational only |

### Why Coverage Is Informational

Bash code coverage with kcov has fundamental limitations:

> **Technical Limitation**: kcov uses LD_PRELOAD to trace execution, but cannot instrument subprocesses spawned by bats. Each test runs in a subprocess that kcov cannot follow.
>
> Reference: [bats-core/bats-core#15](https://github.com/bats-core/bats-core/issues/15)

**Result**: Reported coverage percentages are lower than actual coverage. **Test pass rate (100%) is the enforced quality gate.**

### Running Coverage Locally

```bash
# Install kcov (Ubuntu/Debian)
sudo apt-get install kcov

# Or build from source
git clone https://github.com/SimonKagstrom/kcov.git
cd kcov && mkdir build && cd build
cmake .. && make && sudo make install

# Run tests with coverage
mkdir -p coverage
kcov --include-path="$(pwd)/ralph_loop.sh,$(pwd)/lib" \
     coverage/ \
     bats tests/unit/

# View report
open coverage/index.html  # macOS
xdg-open coverage/index.html  # Linux
```

### Coverage Best Practices

1. **Prioritize Critical Paths**: Test the main loop, exit detection, circuit breaker
2. **Test Error Conditions**: Verify graceful handling of failures
3. **Don't Chase 100%**: Quality over quantity
4. **New Features Need Tests**: All PRs introducing features must include tests

---

## CI/CD Integration

### GitHub Actions Pipeline

The test workflow is defined in `.github/workflows/test.yml`:

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitHub Actions Pipeline                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Triggers: push (main, develop), PR (main)                      │
│                                                                  │
│  ┌─────────────────┐     ┌─────────────────┐                    │
│  │    test job     │────▶│  coverage job   │                    │
│  └────────┬────────┘     └────────┬────────┘                    │
│           │                       │                              │
│  • Checkout repo         • Build kcov from source               │
│  • Setup Node.js 18      • Run tests with coverage              │
│  • Install deps (jq)     • Parse coverage results               │
│  • Run unit tests        • Check threshold (disabled)           │
│  • Run integration       • Upload artifacts                     │
│  • Generate summary      • Upload to Codecov (optional)         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Workflow Stages

#### 1. Test Job (Required)

```yaml
test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v3
    - uses: actions/setup-node@v3
      with:
        node-version: '18'
    - run: npm install && sudo apt-get install -y jq
    - run: npm run test:unit          # Must pass
    - run: npm run test:integration   # Allowed to fail (|| true)
    - run: npm run test:e2e          # Allowed to fail (|| true)
```

#### 2. Coverage Job (Informational)

```yaml
coverage:
  runs-on: ubuntu-latest
  needs: test  # Only runs after test passes
  env:
    COVERAGE_THRESHOLD: 0  # Disabled
```

### Viewing CI Results

1. **GitHub Actions tab**: See workflow runs and logs
2. **Step Summary**: Test results appear in PR summary
3. **Coverage Artifacts**: Downloadable for 7 days
4. **Codecov** (optional): Interactive coverage reports

### Local vs CI Differences

| Aspect | Local | CI |
|--------|-------|-----|
| Environment | Your machine | ubuntu-latest container |
| Node version | Your installed version | v18 (specified) |
| Dependencies | Cached | Fresh install |
| Coverage | Optional | Automatic |
| Artifacts | Manual | Auto-uploaded |

### Reproducing CI Failures

```bash
# Match CI environment
nvm use 18
npm ci  # Clean install (not npm install)

# Run tests in CI order
npm run test:unit
npm run test:integration
npm run test:e2e

# Check for environment-specific issues
uname -a  # OS differences
bash --version  # Bash version
```

---

## Troubleshooting

### Test Failures

#### Reading BATS Output

```bash
# Verbose output shows each test
bats --verbose-run tests/unit/test_rate_limiting.bats

# TAP format for parsing
bats --tap tests/unit/test_rate_limiting.bats

# Timing information
bats --timing tests/unit/test_rate_limiting.bats
```

#### Understanding Failure Messages

```
not ok 3 - can_make_call returns success when under limit
# (in test file tests/unit/test_rate_limiting.bats, line 58)
#   `assert_success' failed
# Expected success but got status 1
# Output: Error: file not found
```

- **Line 58**: Where the assertion failed
- **assert_success failed**: Exit code wasn't 0
- **status 1**: Actual exit code
- **Output**: What the command printed

#### Debugging Steps

1. **Run single test**:
   ```bash
   bats tests/unit/test_rate_limiting.bats --filter "can_make_call"
   ```

2. **Add debug output**:
   ```bash
   @test "debugging example" {
       echo "Before command" >&3  # Print to stdout during test

       run my_function

       echo "Status: $status" >&3
       echo "Output: $output" >&3

       assert_success
   }
   ```

3. **Use set -x for tracing**:
   ```bash
   @test "trace example" {
       set -x  # Enable bash tracing
       run my_function
       set +x  # Disable tracing
   }
   ```

4. **Preserve temp directory**:
   ```bash
   teardown() {
       echo "Temp dir: $TEST_TEMP_DIR" >&3
       # Comment out cleanup to inspect:
       # rm -rf "$TEST_TEMP_DIR"
   }
   ```

### Mock Issues

#### Mock Not Being Called

```bash
# Verify setup_mocks was called
setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/mocks.bash"
    setup_mocks  # Must call this!
}

# Verify function is exported
type git  # Should show "git is a function"
```

#### Wrong Mock Response

```bash
# Check environment variables
@test "debug mock" {
    echo "MOCK_CLAUDE_SUCCESS: $MOCK_CLAUDE_SUCCESS" >&3
    echo "MOCK_CLAUDE_OUTPUT: $MOCK_CLAUDE_OUTPUT" >&3

    # Set explicitly if needed
    export MOCK_CLAUDE_SUCCESS=true
    export MOCK_CLAUDE_OUTPUT="expected response"
}
```

#### Mock Cleanup Issues

```bash
# Always clean up in teardown
teardown() {
    teardown_mocks  # Restore original commands
    unset MOCK_CLAUDE_SUCCESS
    unset MOCK_CLAUDE_OUTPUT
}
```

### JSON Parsing Errors

#### Invalid JSON in Fixtures

```bash
# Validate fixture output
@test "debug json" {
    create_sample_status_running "status.json"

    # Validate JSON is valid
    run jq empty "status.json"
    assert_success

    # Show content if invalid
    if [[ $status -ne 0 ]]; then
        cat "status.json" >&3
    fi
}
```

#### Missing jq

```bash
# Check jq is available
which jq || echo "jq not installed"

# Install if missing
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq
```

### File Permission Errors

#### Temp Directory Issues

```bash
# Ensure temp dir is writable
setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    [[ -w "$TEST_TEMP_DIR" ]] || fail "Cannot write to temp dir"
}
```

#### Read-Only Filesystem

```bash
# Use system temp location
export BATS_TEST_TMPDIR="${TMPDIR:-/tmp}/bats-ralph-$$"
```

### CI/CD Failures

#### Tests Pass Locally, Fail in CI

1. **Check environment differences**:
   ```bash
   # CI uses ubuntu-latest
   uname -a
   bash --version
   ```

2. **Check for hardcoded paths**:
   ```bash
   # Bad: hardcoded path
   source "/home/user/ralph/lib/utils.sh"

   # Good: relative path
   source "$(dirname "$BATS_TEST_FILENAME")/../../lib/utils.sh"
   ```

3. **Check for timing issues**:
   ```bash
   # Add explicit waits if needed
   sleep 1
   ```

#### Coverage Threshold Failures

```bash
# Check current threshold
grep COVERAGE_THRESHOLD .github/workflows/test.yml

# Threshold is set to 0 (disabled)
# If enabled, review coverage report
```

### Getting Help

1. **Check existing tests**: Look at similar tests in the suite for patterns
2. **BATS documentation**: https://bats-core.readthedocs.io/
3. **GitHub Issues**: Report test infrastructure issues at https://github.com/frankbria/ralph-claude-code/issues

---

## Appendices

### Appendix A: BATS Quick Reference

```bash
# Test file header
#!/usr/bin/env bats
load '../helpers/test_helper'

# Lifecycle hooks
setup() { }      # Before each test
teardown() { }   # After each test
setup_file() { } # Before all tests in file
teardown_file() { } # After all tests in file

# Test definition
@test "description" {
    # Arrange, Act, Assert
}

# The run command
run command arg1 arg2
# Sets: $status (exit code), $output (stdout+stderr)

# Skip tests
@test "skipped test" {
    skip "reason for skipping"
}

# Conditional skip
@test "conditional skip" {
    [[ -z "$CI" ]] || skip "Only runs locally"
}
```

### Appendix B: Common Patterns

#### Testing Exit Codes

```bash
@test "command succeeds" {
    run my_command
    assert_success
}

@test "command fails with specific code" {
    run my_command --invalid
    [[ $status -eq 2 ]]  # Specific exit code
}
```

#### Testing Output Content

```bash
@test "output contains expected text" {
    run my_command
    [[ "$output" == *"expected"* ]]
}

@test "output matches regex" {
    run my_command
    [[ "$output" =~ ^[0-9]+$ ]]  # Matches digits
}
```

#### Testing File Creation

```bash
@test "command creates file" {
    run my_command
    assert_file_exists "output.txt"
}

@test "file contains expected content" {
    run my_command
    [[ "$(cat output.txt)" == "expected content" ]]
}
```

#### Testing JSON Output

```bash
@test "produces valid JSON" {
    run my_command
    echo "$output" | jq empty  # Validates JSON
}

@test "JSON has expected field" {
    run my_command
    value=$(echo "$output" | jq -r '.status')
    [[ "$value" == "success" ]]
}
```

### Appendix C: Contributing Tests

#### Adding New Test Files

1. Create file in appropriate directory:
   ```bash
   touch tests/unit/test_my_feature.bats
   chmod +x tests/unit/test_my_feature.bats
   ```

2. Use standard header:
   ```bash
   #!/usr/bin/env bats
   # Unit tests for my feature

   load '../helpers/test_helper'
   ```

3. Verify tests run:
   ```bash
   bats tests/unit/test_my_feature.bats
   ```

4. Update documentation if needed

#### Test Review Checklist

- [ ] Tests have descriptive names
- [ ] Each test verifies one behavior
- [ ] Tests clean up after themselves
- [ ] Mocks are properly set up and torn down
- [ ] No hardcoded paths
- [ ] Tests pass in isolation
- [ ] Tests pass in CI environment
