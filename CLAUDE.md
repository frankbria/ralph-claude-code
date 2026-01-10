# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

**Version**: v0.9.8 | **Tests**: 276 passing (100% pass rate) | **CI/CD**: GitHub Actions

## Core Architecture

The system consists of four main bash scripts and a modular library system:

### Main Scripts

1. **ralph_loop.sh** - The main autonomous loop that executes Claude Code repeatedly
2. **ralph_monitor.sh** - Live monitoring dashboard for tracking loop status
3. **setup.sh** - Project initialization script for new Ralph projects
4. **create_files.sh** - Bootstrap script that creates the entire Ralph system
5. **ralph_import.sh** - PRD/specification import tool that converts documents to Ralph format
   - Uses modern Claude Code CLI with `--output-format json` for structured responses
   - Implements `detect_response_format()` and `parse_conversion_response()` for JSON parsing
   - Backward compatible with older CLI versions (automatic text fallback)

### Library Components (lib/)

The system uses a modular architecture with reusable components in the `lib/` directory:

1. **lib/circuit_breaker.sh** - Circuit breaker pattern implementation
   - Prevents runaway loops by detecting stagnation
   - Three states: CLOSED (normal), HALF_OPEN (monitoring), OPEN (halted)
   - Configurable thresholds for no-progress and error detection
   - Automatic state transitions and recovery

2. **lib/response_analyzer.sh** - Intelligent response analysis
   - Analyzes Claude Code output for completion signals
   - **JSON output format detection and parsing** (with text fallback)
   - Supports both flat JSON format and Claude CLI format (`result`, `sessionId`, `metadata`)
   - Extracts structured fields: status, exit_signal, work_type, files_modified
   - **Session management**: `store_session_id()`, `get_last_session_id()`, `should_resume_session()`
   - Automatic session persistence to `.claude_session_id` file with 24-hour expiration
   - Session lifecycle: `get_session_id()`, `reset_session()`, `log_session_transition()`, `init_session_tracking()`
   - Session history tracked in `.ralph_session_history` (last 50 transitions)
   - Session auto-reset on: circuit breaker open, manual interrupt, project completion
   - Detects test-only loops and stuck error patterns
   - Two-stage error filtering to eliminate false positives
   - Multi-line error matching for accurate stuck loop detection
   - Confidence scoring for exit decisions

3. **lib/date_utils.sh** - Cross-platform date utilities
   - ISO timestamp generation for logging
   - Epoch time calculations for rate limiting

## Key Commands

### Installation
```bash
# Install Ralph globally (run once)
./install.sh

# Uninstall Ralph
./install.sh uninstall
```

### Setting Up a New Project
```bash
# Create a new Ralph-managed project (run from anywhere)
ralph-setup my-project-name
cd my-project-name
```

### Running the Ralph Loop
```bash
# Start with integrated tmux monitoring (recommended)
ralph --monitor

# Start without monitoring
ralph

# With custom parameters and monitoring
ralph --monitor --calls 50 --prompt my_custom_prompt.md

# Check current status
ralph --status

# Circuit breaker management
ralph --reset-circuit
ralph --circuit-status

# Session management
ralph --reset-session    # Reset session state manually
```

### Monitoring
```bash
# Integrated tmux monitoring (recommended)
ralph --monitor

# Manual monitoring in separate terminal
ralph-monitor

# tmux session management
tmux list-sessions
tmux attach -t <session-name>
```

### Running Tests
```bash
# Run all tests (165 tests)
npm test

# Run specific test suites
npm run test:unit
npm run test:integration

# Run individual test files
bats tests/unit/test_cli_parsing.bats
bats tests/unit/test_json_parsing.bats
bats tests/unit/test_cli_modern.bats
```

## Ralph Loop Configuration

The loop is controlled by several key files and environment variables:

- **PROMPT.md** - Main prompt file that drives each loop iteration
- **@fix_plan.md** - Prioritized task list that Ralph follows
- **@AGENT.md** - Build and run instructions maintained by Ralph
- **status.json** - Real-time status tracking (JSON format)
- **logs/** - Execution logs for each loop iteration

### Rate Limiting
- Default: 100 API calls per hour (configurable via `--calls` flag)
- Automatic hourly reset with countdown display
- Call tracking persists across script restarts

### Modern CLI Configuration (Phase 1.1)

Ralph uses modern Claude Code CLI flags for structured communication:

**Configuration Variables:**
```bash
CLAUDE_OUTPUT_FORMAT="json"           # Output format: json (default) or text
CLAUDE_ALLOWED_TOOLS="Write,Bash(git *),Read"  # Allowed tool permissions
CLAUDE_USE_CONTINUE=true              # Enable session continuity
CLAUDE_MIN_VERSION="2.0.76"           # Minimum Claude CLI version
```

**CLI Options:**
- `--output-format json|text` - Set Claude output format (default: json)
- `--allowed-tools "Write,Read,Bash(git *)"` - Restrict allowed tools
- `--no-continue` - Disable session continuity, start fresh each loop

**Loop Context:**
Each loop iteration injects context via `build_loop_context()`:
- Current loop number
- Remaining tasks from @fix_plan.md
- Circuit breaker state (if not CLOSED)
- Previous loop work summary

**Session Continuity:**
- Sessions are preserved in `.claude_session_id`
- Use `--continue` flag to maintain context across loops
- Disable with `--no-continue` for isolated iterations

### Intelligent Exit Detection
The loop automatically exits when it detects project completion through:
- Multiple consecutive "done" signals from Claude Code
- Too many test-only loops indicating feature completeness
- All items in @fix_plan.md marked as completed
- Strong completion indicators in responses

## CI/CD Pipeline

Ralph uses GitHub Actions for continuous integration:

### Workflows (`.github/workflows/`)

1. **test.yml** - Main test suite
   - Runs on push to `main`/`develop` and PRs to `main`
   - Executes unit, integration, and E2E tests
   - Coverage reporting with kcov (informational only)
   - Uploads coverage artifacts

2. **claude.yml** - Claude Code GitHub Actions integration
   - Automated code review capabilities

3. **claude-code-review.yml** - PR code review workflow
   - Automated review on pull requests

### Coverage Note
Bash code coverage measurement with kcov has fundamental limitations when tracing subprocess executions. The `COVERAGE_THRESHOLD` is set to 0 (disabled) because kcov cannot instrument subprocesses spawned by bats. **Test pass rate (100%) is the quality gate.** See [bats-core#15](https://github.com/bats-core/bats-core/issues/15) for details.

## Project Structure for Ralph-Managed Projects

Each project created with `./setup.sh` follows this structure:
```
project-name/
├── PROMPT.md          # Main development instructions
├── @fix_plan.md       # Prioritized TODO list
├── @AGENT.md          # Build/run instructions
├── specs/             # Project specifications
├── src/               # Source code
├── examples/          # Usage examples
├── logs/              # Loop execution logs
└── docs/generated/    # Auto-generated documentation
```

## Template System

Templates in `templates/` provide starting points for new projects:
- **PROMPT.md** - Instructions for Ralph's autonomous behavior
- **fix_plan.md** - Initial task structure
- **AGENT.md** - Build system template

## File Naming Conventions

- Files prefixed with `@` (e.g., `@fix_plan.md`) are Ralph-specific control files
- Hidden files (e.g., `.call_count`, `.exit_signals`) track loop state
- `logs/` contains timestamped execution logs
- `docs/generated/` for Ralph-created documentation
- `docs/code-review/` for code review reports

## Global Installation

Ralph installs to:
- **Commands**: `~/.local/bin/` (ralph, ralph-monitor, ralph-setup, ralph-import)
- **Templates**: `~/.ralph/templates/`
- **Scripts**: `~/.ralph/` (ralph_loop.sh, ralph_monitor.sh, setup.sh, ralph_import.sh)
- **Libraries**: `~/.ralph/lib/` (circuit_breaker.sh, response_analyzer.sh, date_utils.sh)

After installation, the following global commands are available:
- `ralph` - Start the autonomous development loop
- `ralph-monitor` - Launch the monitoring dashboard
- `ralph-setup` - Create a new Ralph-managed project
- `ralph-import` - Import PRD/specification documents to Ralph format

## Integration Points

Ralph integrates with:
- **Claude Code CLI**: Uses `npx @anthropic/claude-code` as the execution engine
- **tmux**: Terminal multiplexer for integrated monitoring sessions
- **Git**: Expects projects to be git repositories
- **jq**: For JSON processing of status and exit signals
- **GitHub Actions**: CI/CD pipeline for automated testing
- **Standard Unix tools**: bash, grep, date, etc.

## Exit Conditions and Thresholds

Ralph uses multiple mechanisms to detect when to exit:

### Exit Detection Thresholds
- `MAX_CONSECUTIVE_TEST_LOOPS=3` - Exit if too many test-only iterations
- `MAX_CONSECUTIVE_DONE_SIGNALS=2` - Exit on repeated completion signals
- `TEST_PERCENTAGE_THRESHOLD=30%` - Flag if testing dominates recent loops
- Completion detection via @fix_plan.md checklist items

### Circuit Breaker Thresholds
- `CB_NO_PROGRESS_THRESHOLD=3` - Open circuit after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` - Open circuit after 5 loops with repeated errors
- `CB_OUTPUT_DECLINE_THRESHOLD=70%` - Open circuit if output declines by >70%

### Error Detection

Ralph uses advanced error detection with two-stage filtering to eliminate false positives:

**Stage 1: JSON Field Filtering**
- Filters out JSON field patterns like `"is_error": false` that contain the word "error" but aren't actual errors
- Pattern: `grep -v '"[^"]*error[^"]*":'`

**Stage 2: Actual Error Detection**
- Detects real error messages in specific contexts:
  - Error prefixes: `Error:`, `ERROR:`, `error:`
  - Context-specific errors: `]: error`, `Link: error`
  - Error occurrences: `Error occurred`, `failed with error`
  - Exceptions: `Exception`, `Fatal`, `FATAL`
- Pattern: `grep -cE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'`

**Multi-line Error Matching**
- Detects stuck loops by verifying ALL error lines appear in ALL recent history files
- Uses literal fixed-string matching (`grep -qF`) to avoid regex edge cases
- Prevents false negatives when multiple distinct errors occur simultaneously

## Test Suite

### Test Files (265 tests total)

| File | Tests | Description |
|------|-------|-------------|
| `test_cli_parsing.bats` | 27 | CLI argument parsing for all 12 flags |
| `test_cli_modern.bats` | 29 | Modern CLI commands (Phase 1.1) + build_claude_command fix |
| `test_json_parsing.bats` | 36 | JSON output format parsing + Claude CLI format + session management |
| `test_session_continuity.bats` | 26 | Session lifecycle management + circuit breaker integration |
| `test_exit_detection.bats` | 20 | Exit signal detection |
| `test_rate_limiting.bats` | 15 | Rate limiting behavior |
| `test_loop_execution.bats` | 20 | Integration tests |
| `test_edge_cases.bats` | 20 | Edge case handling |
| `test_installation.bats` | 14 | Global installation/uninstall workflows |
| `test_project_setup.bats` | 36 | Project setup (setup.sh) validation |
| `test_prd_import.bats` | 33 | PRD import (ralph_import.sh) workflows + modern CLI tests |

### Running Tests
```bash
# All tests
npm test

# Unit tests only
npm run test:unit

# Specific test file
bats tests/unit/test_cli_parsing.bats
```

## Recent Improvements

### Modern CLI for PRD Import (v0.9.8)
- Modernized `ralph_import.sh` to use Claude Code CLI JSON output format
  - Added `--output-format json` flag for structured responses
  - Implemented `detect_response_format()` for JSON vs text detection
  - Implemented `parse_conversion_response()` for extracting JSON fields
- Enhanced error handling with structured JSON error messages
  - Extracts `error_message` and `error_code` from JSON metadata
  - Provides specific, actionable feedback on conversion failures
- Improved file verification with JSON-derived status information
  - Reports files created vs missing based on JSON metadata
  - Logs session ID for potential conversion continuation
- Backward compatibility with older CLI versions
  - Automatic fallback to text-based parsing when JSON unavailable
  - Version detection with `check_claude_version()` function
- Enhanced logging with modern CLI awareness
  - Reports which CLI mode is being used
  - Detailed file creation status reporting
- Added 11 new tests for modern CLI features (tests 23-33)
- Test count: 276 (up from 265)

### Session Lifecycle Management (v0.9.7)
- Added complete session lifecycle management with automatic reset triggers:
  - `get_session_id()` - Retrieves current session from `.ralph_session`
  - `reset_session(reason)` - Clears session with reason logging
  - `log_session_transition()` - Records transitions to `.ralph_session_history`
  - `init_session_tracking()` - Initializes session file with validation
- Session auto-reset integration points:
  - Circuit breaker open events (stagnation detection)
  - Manual interrupt (Ctrl+C / SIGINT)
  - Project completion (graceful exit)
  - Manual circuit breaker reset (`--reset-circuit`)
- Added `--reset-session` CLI flag for manual session reset
- Session history tracking (last 50 transitions) for debugging
- New configuration constants: `RALPH_SESSION_FILE`, `RALPH_SESSION_HISTORY_FILE`
- Added 26 new tests for session continuity features
- Test count: 265 (up from 239)

### JSON Output & Session Management (v0.9.6)
- Extended `parse_json_response()` to support Claude Code CLI JSON format
  - Supports `result`, `sessionId`, and `metadata` fields alongside existing flat format
  - Extracts `metadata.files_changed`, `metadata.has_errors`, `metadata.completion_status`
  - Parses `metadata.progress_indicators` array for confidence boosting
- Added session management functions for continuity tracking:
  - `store_session_id()` - Persists session with timestamp
  - `get_last_session_id()` - Retrieves stored session ID
  - `should_resume_session()` - Checks session validity (24-hour expiration)
- Added `get_epoch_seconds()` to date_utils.sh for cross-platform epoch time
- Auto-persists sessionId to `.claude_session_id` file during response analysis
- Added 16 new tests covering Claude CLI format and session management
- Test count: 239 (up from 223)

### PRD Import Tests (v0.9.5)
- Added 22 comprehensive tests for `ralph_import.sh` PRD conversion script
- Tests cover: file format support (.md, .txt, .json), output file creation, project naming
- Mock infrastructure for `ralph-setup` and Claude Code CLI isolation
- Output file validation: PROMPT.md, @fix_plan.md, specs/requirements.md creation
- Project naming tests: custom names, auto-detection from filename, path handling
- Error handling tests: missing source file, missing ralph-setup, conversion failures
- Help and usage tests: --help flag, no arguments behavior
- Full workflow integration: complete project structure validation
- Edge cases: hyphens in names, uppercase filenames, subdirectory paths
- Test helper: added `create_sample_prd_txt()` fixture function
- Test count: 223 (up from 201)

### Project Setup Tests (v0.9.4)
- Added 36 comprehensive tests for `setup.sh` project initialization script
- Tests cover: directory creation, subdirectory structure, template copying, git initialization
- Template copying verification for PROMPT.md, @fix_plan.md, @AGENT.md
- Git repository validation: .git exists, valid repo, initial commit, correct message
- README.md creation and content verification
- Custom and default project name handling
- Working directory behavior (nested directories, relative paths)
- Error handling: missing templates, missing PROMPT.md
- Output message validation (startup, completion, next steps)
- Edge cases: spaces in names, existing directories
- Test count: 201 (up from 165)

### Installation Tests (v0.9.3)
- Added 14 comprehensive tests for `install.sh` global installation script
- Tests cover: directory creation, command installation, template copying, lib copying
- Dependency detection tests (jq, git, node) with mocked failures
- PATH detection and warning system tests
- Uninstallation cleanup verification
- Idempotency testing (run twice without errors)
- End-to-end installation workflow validation
- All tests use isolated temp directories (no system modifications)
- Test count: 165 (up from 151)

### Prompt File Fix (v0.9.2)
- Fixed critical bug: replaced non-existent `--prompt-file` CLI flag with `-p` flag
- Modern CLI mode now correctly passes prompt content via `CLAUDE_CMD_ARGS+=("-p" "$prompt_content")`
- Added error handling for missing prompt files in `build_claude_command()`
- Added 6 new TDD tests for `build_claude_command` function
- Maintains shell injection safety through array-based command building
- Test count: 151 (up from 145)

### CLI Parsing Tests (v0.9.1)
- Added 27 comprehensive CLI argument parsing tests
- Covers all 12 CLI flags with both long and short forms
- Boundary value testing for `--timeout` (0, 1, 120, 121)
- Invalid input handling and error message validation
- Code review report: `docs/code-review/2026-01-08-cli-parsing-tests-review.md`

### CI/CD Pipeline (v0.9.1)
- Added GitHub Actions workflow for automated testing
- kcov coverage measurement (informational only due to subprocess limitations)
- Coverage artifacts uploaded for debugging
- Codecov integration (optional)

### Modern CLI Commands (v0.9.1 - Phase 1.1)

**JSON Output Format Support**
- Added `detect_output_format()` function to identify JSON vs text output
- Added `parse_json_response()` to extract structured fields from Claude's JSON output
- Extracts: status, exit_signal, work_type, files_modified, error_count, summary
- Automatic fallback to text parsing on malformed JSON
- Maintains backward compatibility with traditional RALPH_STATUS format

**Session Continuity Management**
- `init_claude_session()` - Resume or start new sessions
- `save_claude_session()` - Persist session ID from Claude output
- `--continue` flag for context preservation across loops
- `--no-continue` option for isolated iterations

**Loop Context Injection**
- `build_loop_context()` - Build contextual information for each loop
- Includes: loop number, remaining tasks, circuit breaker state, previous work summary
- Injected via `--append-system-prompt` for Claude awareness

**Modern CLI Flags**
- `--output-format json|text` - Control Claude output format
- `--allowed-tools` - Restrict tool permissions
- `-p` with content - Pass prompt content (reads from file via command substitution)
- Version checking with `check_claude_version()`

### Circuit Breaker Enhancements (v0.9.0)

**Multi-line Error Matching Fix**
- Fixed critical bug in `detect_stuck_loop` function where only the first error line was checked when multiple distinct errors occurred
- Now verifies ALL error lines appear in ALL recent history files for accurate stuck loop detection
- Uses nested loop checking with `grep -qF` for literal fixed-string matching

**JSON Field False Positive Elimination**
- Implemented two-stage error filtering to avoid counting JSON field names as errors
- Stage 1 filters out patterns like `"is_error": false` that contain "error" as a field name
- Stage 2 detects actual error messages in specific contexts
- Aligned patterns between `response_analyzer.sh` and `ralph_loop.sh` for consistent behavior

### Installation Improvements
- Added `lib/` directory to installation process for modular architecture
- Fixed issue where `response_analyzer.sh` and `circuit_breaker.sh` were not being copied during global installation
- All library components now properly installed to `~/.ralph/lib/`

## Feature Development Quality Standards

**CRITICAL**: All new features MUST meet the following mandatory requirements before being considered complete.

### Testing Requirements

- **Test Pass Rate**: 100% - all tests must pass, no exceptions
- **Test Types Required**:
  - Unit tests for bash script functions (if applicable)
  - Integration tests for Ralph loop behavior
  - End-to-end tests for full development cycles
- **Test Quality**: Tests must validate behavior, not just achieve coverage metrics
- **Test Documentation**: Complex test scenarios must include comments explaining the test strategy

> **Note on Coverage**: The 85% coverage threshold is aspirational for bash scripts. Due to kcov subprocess limitations, test pass rate is the enforced quality gate.

### Git Workflow Requirements

Before moving to the next feature, ALL changes must be:

1. **Committed with Clear Messages**:
   ```bash
   git add .
   git commit -m "feat(module): descriptive message following conventional commits"
   ```
   - Use conventional commit format: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, etc.
   - Include scope when applicable: `feat(loop):`, `fix(monitor):`, `test(setup):`
   - Write descriptive messages that explain WHAT changed and WHY

2. **Pushed to Remote Repository**:
   ```bash
   git push origin <branch-name>
   ```
   - Never leave completed features uncommitted
   - Push regularly to maintain backup and enable collaboration
   - Ensure CI/CD pipelines pass before considering feature complete

3. **Branch Hygiene**:
   - Work on feature branches, never directly on `main`
   - Branch naming convention: `feature/<feature-name>`, `fix/<issue-name>`, `docs/<doc-update>`
   - Create pull requests for all significant changes

4. **Ralph Integration**:
   - Update @fix_plan.md with new tasks before starting work
   - Mark items complete in @fix_plan.md upon completion
   - Update PROMPT.md if Ralph's behavior needs modification
   - Test Ralph loop with new features before completion

### Documentation Requirements

**ALL implementation documentation MUST remain synchronized with the codebase**:

1. **Script Documentation**:
   - Bash: Comments for all functions and complex logic
   - Update inline comments when implementation changes
   - Remove outdated comments immediately

2. **Implementation Documentation**:
   - Update relevant sections in this CLAUDE.md file
   - Keep template files in `templates/` current
   - Update configuration examples when defaults change
   - Document breaking changes prominently

3. **README Updates**:
   - Keep feature lists current
   - Update setup instructions when commands change
   - Maintain accurate command examples
   - Update version compatibility information

4. **Template Maintenance**:
   - Update template files when new patterns are introduced
   - Keep PROMPT.md template current with best practices
   - Update @AGENT.md template with new build patterns
   - Document new Ralph configuration options

5. **CLAUDE.md Maintenance**:
   - Add new commands to "Key Commands" section
   - Update "Exit Conditions and Thresholds" when logic changes
   - Keep installation instructions accurate and tested
   - Document new Ralph loop behaviors or quality gates

### Feature Completion Checklist

Before marking ANY feature as complete, verify:

- [ ] All tests pass (if applicable)
- [ ] Script functionality manually tested
- [ ] All changes committed with conventional commit messages
- [ ] All commits pushed to remote repository
- [ ] CI/CD pipeline passes
- [ ] @fix_plan.md task marked as complete
- [ ] Implementation documentation updated
- [ ] Inline code comments updated or added
- [ ] CLAUDE.md updated (if new patterns introduced)
- [ ] Template files updated (if applicable)
- [ ] Breaking changes documented
- [ ] Ralph loop tested with new features
- [ ] Installation process verified (if applicable)

### Rationale

These standards ensure:
- **Quality**: Thorough testing prevents regressions in Ralph's autonomous behavior
- **Traceability**: Git commits and @fix_plan.md provide clear history of changes
- **Maintainability**: Current documentation reduces onboarding time and prevents knowledge loss
- **Collaboration**: Pushed changes enable team visibility and code review
- **Reliability**: Consistent quality gates maintain Ralph loop stability
- **Automation**: Ralph integration ensures continuous development practices

**Enforcement**: AI agents should automatically apply these standards to all feature development tasks without requiring explicit instruction for each task.
