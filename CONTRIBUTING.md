# Contributing to Ralph for Claude Code

Thank you for your interest in contributing to Ralph! This guide will help you get started and ensure your contributions follow our established patterns and quality standards.

**Every contribution matters** - from fixing typos to implementing major features. We appreciate your help in making Ralph better!

## Table of Contents

1. [Getting Started](#getting-started)
2. [Development Workflow](#development-workflow)
3. [Code Style Guidelines](#code-style-guidelines)
4. [Testing Requirements](#testing-requirements)
5. [Pull Request Process](#pull-request-process)
6. [Code Review Guidelines](#code-review-guidelines)
7. [Quality Standards](#quality-standards)
8. [Community Guidelines](#community-guidelines)

---

## Getting Started

### Prerequisites

Before contributing, ensure you have the following installed:

- **Bash 4.0+** - For script execution
- **jq** - JSON processing (required)
- **git** - Version control (required)
- **tmux** - Terminal multiplexer (recommended)
- **Node.js 18+** - For running tests via npm

### Clone the Repository

```bash
# Fork the repository on GitHub first, then clone your fork
git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
cd ralph-claude-code
```

### Install Dependencies

```bash
# Install BATS testing framework and dependencies
npm install

# Verify BATS is available
./node_modules/.bin/bats --version

# Optional: Install Ralph globally for testing
./install.sh
```

### Verify Your Setup

```bash
# Run the test suite to ensure everything works
npm test

# You should see output like:
# ✓ 276 tests passed (100% pass rate)
```

### Project Structure

```
ralph-claude-code/
├── ralph_loop.sh        # Main loop script
├── ralph_monitor.sh     # Live monitoring dashboard
├── setup.sh             # Project initialization
├── ralph_import.sh      # PRD import tool
├── install.sh           # Global installation script
├── lib/                 # Modular library components
│   ├── circuit_breaker.sh
│   ├── response_analyzer.sh
│   └── date_utils.sh
├── templates/           # Project templates
├── tests/               # Test suite
│   ├── unit/            # Unit tests
│   ├── integration/     # Integration tests
│   ├── e2e/             # End-to-end tests
│   └── helpers/         # Test utilities
└── docs/                # Documentation
```

---

## Development Workflow

### Branch Naming Conventions

Always create a feature branch - never work directly on `main`:

| Branch Type | Format | Example |
|-------------|--------|---------|
| New features | `feature/<feature-name>` | `feature/log-rotation` |
| Bug fixes | `fix/<issue-name>` | `fix/rate-limit-reset` |
| Documentation | `docs/<doc-update>` | `docs/api-reference` |
| Tests | `test/<test-area>` | `test/circuit-breaker` |
| Refactoring | `refactor/<area>` | `refactor/response-analyzer` |

```bash
# Create a new feature branch
git checkout -b feature/my-awesome-feature
```

### Commit Message Format

We use [Conventional Commits](https://www.conventionalcommits.org/) for clear, structured commit history:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types:**

| Type | Description | Example |
|------|-------------|---------|
| `feat` | New feature | `feat(loop): add dry-run mode` |
| `fix` | Bug fix | `fix(monitor): correct refresh rate` |
| `docs` | Documentation only | `docs(readme): update installation steps` |
| `test` | Adding/updating tests | `test(setup): add template validation tests` |
| `refactor` | Code change (no features/fixes) | `refactor(analyzer): simplify error detection` |
| `chore` | Maintenance tasks | `chore(deps): update bats-assert` |

**Examples from Recent Commits:**

```bash
# Feature addition
feat(import): add JSON output format support

# Bug fix with scope
fix(loop): replace non-existent --prompt-file with -p flag

# Documentation update
docs(status): update IMPLEMENTATION_STATUS.md with phased structure

# Test addition
test(cli): add 27 comprehensive CLI parsing tests
```

**Writing Good Commit Messages:**

- Use imperative mood ("add" not "added")
- Explain WHAT changed and WHY (not HOW)
- Keep the subject line under 72 characters
- Reference issues when applicable (`fixes #123`)

### Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Contribution Workflow                            │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │  1. Fork │────>│ 2. Clone │────>│ 3. Branch│────>│ 4. Code  │
  └──────────┘     └──────────┘     └──────────┘     └──────────┘
                                                           │
                                                           v
  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ 8. Merge │<────│  7. PR   │<────│ 6. Push  │<────│ 5. Test  │
  └──────────┘     │ Approved │     └──────────┘     │ (100%)   │
                   └──────────┘                      └──────────┘
                        ^
                        │
                   ┌──────────┐
                   │  CI/CD   │
                   │  Passes  │
                   └──────────┘
```

---

## Code Style Guidelines

### Bash Best Practices

Ralph follows consistent bash conventions across all scripts:

**File Structure:**

```bash
#!/bin/bash
# Script description
# Purpose and usage notes

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/lib/date_utils.sh"

# Configuration constants (UPPER_CASE)
# Use env var defaults for user-configurable values
MAX_CALLS_PER_HOUR=100
CB_NO_PROGRESS_THRESHOLD=${CB_NO_PROGRESS_THRESHOLD:-3}
STATUS_FILE="status.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper functions (snake_case)
helper_function() {
    local param1=$1
    local param2=$2
    # Implementation
}

# Main logic
main() {
    # Entry point
}

# Export functions for reuse
export -f helper_function

# Execute main if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

**Naming Conventions:**

| Element | Convention | Example |
|---------|------------|---------|
| Functions | snake_case | `get_circuit_state()` |
| Local variables | snake_case | `local loop_count=0` |
| Constants | UPPER_SNAKE_CASE | `MAX_CALLS_PER_HOUR` |
| File names | snake_case.sh | `circuit_breaker.sh` |
| Control files | @prefix | `@fix_plan.md` |

**Function Documentation:**

```bash
# Get current circuit breaker state
# Returns the state as a string: CLOSED, HALF_OPEN, or OPEN
# Falls back to CLOSED if state file doesn't exist
get_circuit_state() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "$CB_STATE_CLOSED"
        return
    fi

    jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED"
}
```

**Error Handling:**

```bash
# Always validate inputs
if [[ -z "$1" ]]; then
    echo -e "${RED}Error: Missing required argument${NC}" >&2
    exit 1
fi

# Use proper exit codes
# 0 = success, 1 = general error, 2 = invalid usage
```

**Cross-Platform Compatibility:**

```bash
# Use portable date commands
if command -v gdate &> /dev/null; then
    DATE_CMD="gdate"  # macOS with coreutils
else
    DATE_CMD="date"   # Linux
fi
```

**JSON State Management:**

```bash
# Always validate JSON before parsing
if ! jq '.' "$STATE_FILE" > /dev/null 2>&1; then
    echo "Error: Invalid JSON in state file"
    return 1
fi

# Use jq for safe parsing
local state=$(jq -r '.state' "$STATE_FILE" 2>/dev/null || echo "CLOSED")
```

---

## Testing Requirements

### Mandatory Testing Standards

**All new features must include tests. This is non-negotiable.**

| Requirement | Standard | Enforcement |
|-------------|----------|-------------|
| Test Pass Rate | 100% | **Mandatory** - CI blocks merge |
| Test Coverage | 85% | Aspirational - informational only |

> **Note on Coverage:** Bash code coverage with kcov cannot trace subprocess executions. Test pass rate is the enforced quality gate, not coverage percentage.

### Test Organization

```
tests/
├── unit/                       # Fast, isolated tests
│   ├── test_cli_parsing.bats   # CLI argument tests
│   ├── test_json_parsing.bats  # JSON output parsing
│   ├── test_exit_detection.bats
│   ├── test_rate_limiting.bats
│   ├── test_session_continuity.bats
│   └── test_cli_modern.bats
├── integration/                # Multi-component tests
│   ├── test_loop_execution.bats
│   ├── test_edge_cases.bats
│   ├── test_installation.bats
│   ├── test_project_setup.bats
│   └── test_prd_import.bats
├── e2e/                        # End-to-end workflows
└── helpers/
    └── test_helper.bash        # Shared test utilities
```

### Running Tests

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `npm test` | Run all tests | Before committing, before PR |
| `npm run test:unit` | Unit tests only | During development |
| `npm run test:integration` | Integration tests only | Testing interactions |
| `bats tests/unit/test_file.bats` | Single test file | Debugging specific tests |

### Writing Tests

**Test Structure:**

```bash
#!/usr/bin/env bats
# Unit Tests for Feature X

load '../helpers/test_helper'

# Setup runs before each test
setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    # Create isolated test environment
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    # Initialize test state
    echo "0" > ".call_count"
}

# Teardown runs after each test
teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Test: Descriptive name explaining what's being tested
@test "can_make_call returns success when under limit" {
    echo "50" > ".call_count"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test: Failure case
@test "can_make_call returns failure when at limit" {
    echo "100" > ".call_count"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}
```

**Test Best Practices:**

1. **Test both success and failure cases**
2. **Use descriptive test names** that explain the scenario
3. **Isolate tests** - each test should be independent
4. **Mock external dependencies** (Claude CLI, tmux, etc.)
5. **Test edge cases** (empty files, invalid input, boundary values)
6. **Add comments** for complex test scenarios

**Available Test Helpers:**

```bash
# From tests/helpers/test_helper.bash

assert_success      # Check command succeeded (exit 0)
assert_failure      # Check command failed (exit != 0)
assert_equal        # Compare two values
assert_output       # Check command output
assert_file_exists  # Verify file exists
assert_dir_exists   # Verify directory exists
strip_colors        # Remove ANSI color codes
create_mock_prompt  # Create test PROMPT.md
create_mock_fix_plan # Create test @fix_plan.md
create_mock_status  # Create test status.json
```

---

## Pull Request Process

### Before Creating a PR

Run through this checklist:

- [ ] All tests pass locally (`npm test`)
- [ ] New code includes appropriate tests
- [ ] Commits follow conventional format
- [ ] Documentation updated if needed
- [ ] No debug code or console.log statements
- [ ] No secrets or credentials committed

### Creating the PR

1. **Push your branch:**
   ```bash
   git push origin feature/my-feature
   ```

2. **Open a Pull Request** on GitHub with:

**PR Title:** Follow conventional commit format
```
feat(loop): add dry-run mode for testing
```

**PR Description Template:**
```markdown
## Summary

Brief description of what this PR does (1-3 bullet points).

- Adds dry-run mode to preview loop execution
- Includes new CLI flag `--dry-run`
- Logs actions without making actual changes

## Test Plan

- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manual testing completed

## Related Issues

Fixes #123
Related to #456

## Screenshots (if applicable)

[Add screenshots for UI/output changes]

## Breaking Changes

[List any breaking changes, or "None"]
```

### After PR Creation

1. **Wait for CI/CD** - GitHub Actions will run all tests
2. **Address review feedback** - Make requested changes promptly
3. **Keep PR updated** - Rebase if main branch has changed

---

## Code Review Guidelines

### For Contributors

**Responding to Feedback:**

- Thank reviewers for their time
- Ask questions if requirements are unclear
- Make requested changes promptly
- Update PR description as changes evolve
- Don't take feedback personally - it's about the code

**If You Disagree:**

- Explain your reasoning clearly
- Provide context for your decisions
- Be open to alternative approaches
- Defer to maintainer judgment when in doubt

### For Reviewers

**What to Check:**

| Area | Questions to Ask |
|------|------------------|
| **Correctness** | Does the code do what it claims? |
| **Tests** | Are tests comprehensive? Do they pass? |
| **Style** | Does it follow bash conventions? |
| **Documentation** | Are comments and docs updated? |
| **Breaking Changes** | Will this affect existing users? |
| **Performance** | Any obvious performance issues? |

**Review Best Practices:**

1. **Be constructive** - Focus on improvements, not criticism
2. **Be specific** - Point to exact lines when possible
3. **Explain why** - Help contributors learn
4. **Acknowledge good work** - Note well-written code
5. **Approve when ready** - Don't hold PRs hostage

---

## Quality Standards

### Quality Gates

All PRs must pass these automated checks:

| Gate | Requirement | Enforcement |
|------|-------------|-------------|
| Unit Tests | 100% pass | **Blocks merge** |
| Integration Tests | 100% pass | **Blocks merge** |
| Coverage | 85% | Informational only |
| Conventional Commits | Required | Manual review |
| Documentation | Updated | Manual review |

### Documentation Standards

**When to Update Documentation:**

- Adding new CLI flags → Update README.md, CLAUDE.md
- Adding new features → Update README.md "Features" section
- Changing behavior → Update relevant docs
- Adding new patterns → Update CLAUDE.md

**Keep in Sync:**

1. **CLAUDE.md** - Technical specifications, quality standards
2. **README.md** - User-facing documentation, installation
3. **Templates** - Keep template files current
4. **Inline comments** - Update when code changes

### Feature Completion Checklist

Before marking any feature complete:

- [ ] All tests pass (100% pass rate)
- [ ] Script functionality manually tested
- [ ] Commits follow conventional format
- [ ] All commits pushed to remote
- [ ] CI/CD pipeline passes
- [ ] CLAUDE.md updated (if new patterns)
- [ ] README.md updated (if user-facing)
- [ ] Breaking changes documented
- [ ] Installation verified (if applicable)

---

## Community Guidelines

### Priority Contribution Areas

**High Priority - Help Needed!**

1. **Test Implementation** - Expand test coverage
   - See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for specifications

2. **Feature Development**
   - Log rotation functionality
   - Dry-run mode
   - Config file support (.ralphrc)
   - Metrics tracking
   - Desktop notifications
   - Backup/rollback system

3. **Documentation**
   - Usage tutorials and examples
   - Troubleshooting guides
   - Video walkthroughs

4. **Real-World Testing**
   - Use Ralph on your projects
   - Report bugs and edge cases
   - Share your experience

### Communication

**Before Major Changes:**

- Open an issue for discussion
- Check existing issues for planned work
- Join discussions on pull requests

**Getting Help:**

- Review documentation first (README.md, CLAUDE.md)
- Check [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for roadmap
- Open issues for questions
- Reference related issues in discussions

### Code of Conduct

- Be respectful and professional
- Welcome newcomers and help them succeed
- Focus on constructive feedback
- Assume good intentions
- Celebrate diverse perspectives

### Recognition

- All contributors acknowledged in release notes
- Significant contributions noted in README
- Active contributors may become maintainers

---

## Additional Resources

- [README.md](README.md) - Project overview and quick start
- [CLAUDE.md](CLAUDE.md) - Technical specifications
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) - Development roadmap
- [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) - Progress tracking
- [GitHub Issues](https://github.com/frankbria/ralph-claude-code/issues) - Bug reports and feature requests

---

**Thank you for contributing to Ralph!** Your efforts help make autonomous AI development more accessible to everyone.
