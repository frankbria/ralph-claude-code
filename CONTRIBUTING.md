# Contributing to Ralph Claude Code

Thank you for your interest in contributing to Ralph Claude Code! This document provides guidelines for contributing to the project.

## Code of Conduct

Be respectful, inclusive, and constructive. We welcome contributions from everyone.

## Getting Started

### Prerequisites

- Bash 4.0+
- Node.js 16+ and npm
- jq (JSON processor)
- Git
- tmux (optional, for monitoring)

### Setup Development Environment

```bash
# Clone the repository
git clone https://github.com/yourusername/ralph-claude-code.git
cd ralph-claude-code

# Verify dependencies
./install.sh --help

# Run tests to verify setup
npx bats tests/
```

## Development Workflow

### 1. Create a Branch

```bash
# Feature branch
git checkout -b feature/your-feature-name

# Bug fix branch
git checkout -b fix/issue-description

# Documentation branch
git checkout -b docs/doc-update
```

### 2. Make Changes

Follow the coding standards below when making changes.

### 3. Test Your Changes

```bash
# Run all tests
npm test

# Run specific tests
npx bats tests/unit/test_your_feature.bats

# Verify no regressions
npx bats tests/
```

### 4. Commit Your Changes

Use [Conventional Commits](https://www.conventionalcommits.org/):

```bash
# Feature
git commit -m "feat(loop): add log rotation functionality"

# Bug fix
git commit -m "fix(session): implement 24-hour expiration"

# Documentation
git commit -m "docs: add CONTRIBUTING.md"

# Tests
git commit -m "test(security): add session expiration tests"

# Refactoring
git commit -m "refactor(cli): extract version parsing to function"
```

### 5. Push and Create PR

```bash
git push origin your-branch-name
```

Then create a Pull Request on GitHub.

## Coding Standards

### Bash Style Guide

#### File Headers

```bash
#!/bin/bash
# Component Name for Ralph
# Brief description of what this file does
```

#### Functions

```bash
# Brief description of function
# Arguments:
#   $1 - parameter description
# Returns:
#   0 on success, 1 on failure
function_name() {
    local param=$1

    # Function body
}
```

#### Variables

- Use lowercase for local variables: `local my_var`
- Use UPPERCASE for global/environment: `MY_GLOBAL_VAR`
- Always quote variables: `"$var"` not `$var`
- Use `${var:-default}` for defaults

#### Error Handling

```bash
# Use set -e at script start
set -e

# Handle errors explicitly
if ! command; then
    log_status "ERROR" "Command failed"
    return 1
fi

# Use || for fallback
result=$(some_command 2>/dev/null || echo "default")
```

#### Logging

```bash
# Use log_status function
log_status "INFO" "Starting process"
log_status "WARN" "Non-critical issue"
log_status "ERROR" "Critical failure"
log_status "SUCCESS" "Operation completed"
```

### Test Standards

- 100% test pass rate required
- Write tests before implementation (TDD encouraged)
- Cover edge cases and error conditions
- Use descriptive test names
- Follow Arrange-Act-Assert pattern

See [TESTING.md](TESTING.md) for detailed testing guidelines.

### Security Standards

- Never execute user input directly
- Use arrays for command building (avoid `bash -c`)
- Validate all inputs against whitelists
- Sanitize file paths in error messages
- Implement timeouts for external commands
- Add session expiration for persistent state

### Documentation Standards

- Update CLAUDE.md for new features
- Add inline comments for complex logic
- Document all public functions
- Keep examples current
- Update help text for CLI changes

## Pull Request Process

### Before Submitting

1. **All tests pass**: `npm test`
2. **Code follows standards**: Review style guide
3. **Documentation updated**: CLAUDE.md, help text, etc.
4. **Commit messages follow convention**: feat/fix/docs/test/refactor
5. **No debug code**: Remove DEBUG logs, console.log, etc.

### PR Template

```markdown
## Summary
Brief description of changes

## Changes
- Change 1
- Change 2

## Testing
- [ ] All existing tests pass
- [ ] New tests added for new functionality
- [ ] Manual testing completed

## Documentation
- [ ] CLAUDE.md updated (if applicable)
- [ ] Inline comments added
- [ ] Help text updated (if CLI changed)
```

### Review Process

1. Automated CI checks must pass
2. At least one maintainer review required
3. Address all feedback before merge
4. Squash commits if requested

## Types of Contributions

### Bug Reports

When filing a bug report, include:

1. Ralph version (`ralph --version`)
2. Operating system and version
3. Steps to reproduce
4. Expected behavior
5. Actual behavior
6. Relevant logs (from `logs/ralph.log`)

### Feature Requests

When requesting a feature:

1. Describe the problem you're solving
2. Explain your proposed solution
3. Consider alternatives
4. Note any breaking changes

### Code Contributions

We welcome:

- Bug fixes
- New features
- Performance improvements
- Test coverage improvements
- Documentation updates

### Documentation

Help improve:

- README.md
- CLAUDE.md
- TESTING.md
- Inline code comments
- Example projects

## Architecture Guidelines

### File Organization

```
ralph-claude-code/
├── ralph_loop.sh          # Main entry point
├── ralph_monitor.sh       # Monitoring dashboard
├── setup.sh               # Project initialization
├── install.sh             # Global installation
├── lib/                   # Reusable components
│   ├── circuit_breaker.sh # Circuit breaker pattern
│   ├── response_analyzer.sh # Response analysis
│   ├── date_utils.sh      # Cross-platform dates
│   └── log_rotation.sh    # Log management
├── templates/             # Project templates
├── tests/                 # Test suite
└── docs/                  # Documentation
```

### Adding New Library Components

1. Create file in `lib/` directory
2. Follow existing patterns
3. Export functions at file end
4. Source in ralph_loop.sh
5. Add to install.sh
6. Write comprehensive tests

### Modifying Existing Components

1. Understand existing behavior
2. Write tests for new behavior first
3. Make minimal changes
4. Ensure backward compatibility
5. Update documentation

## Release Process

Releases are managed by maintainers:

1. Update version in relevant files
2. Update CHANGELOG.md
3. Run full test suite
4. Create GitHub release
5. Update documentation

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue
- **Security**: Email maintainers directly

## Recognition

Contributors are recognized in:

- Release notes
- GitHub contributors page
- Project documentation

Thank you for contributing!
