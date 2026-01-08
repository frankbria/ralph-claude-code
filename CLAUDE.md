# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

## Core Architecture

The system consists of four main bash scripts and a modular library system:

### Main Scripts

1. **ralph_loop.sh** - The main autonomous loop that executes Claude Code repeatedly
2. **ralph_monitor.sh** - Live monitoring dashboard for tracking loop status
3. **setup.sh** - Project initialization script for new Ralph projects
4. **create_files.sh** - Bootstrap script that creates the entire Ralph system
5. **ralph_import.sh** - PRD/specification import tool that converts documents to Ralph format

### Library Components (lib/)

The system uses a modular architecture with reusable components in the `lib/` directory:

1. **lib/circuit_breaker.sh** - Circuit breaker pattern implementation
   - Prevents runaway loops by detecting stagnation
   - Three states: CLOSED (normal), HALF_OPEN (monitoring), OPEN (halted)
   - Configurable thresholds for no-progress and error detection
   - Automatic state transitions and recovery

2. **lib/response_analyzer.sh** - Intelligent response analysis
   - Analyzes Claude Code output for completion signals
   - Detects test-only loops and stuck error patterns
   - Two-stage error filtering to eliminate false positives
   - Multi-line error matching for accurate stuck loop detection
   - Confidence scoring for exit decisions

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

### Intelligent Exit Detection
The loop automatically exits when it detects project completion through:
- Multiple consecutive "done" signals from Claude Code
- Too many test-only loops indicating feature completeness
- All items in @fix_plan.md marked as completed
- Strong completion indicators in responses

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

## Global Installation

Ralph installs to:
- **Commands**: `~/.local/bin/` (ralph, ralph-monitor, ralph-setup, ralph-import)
- **Templates**: `~/.ralph/templates/`
- **Scripts**: `~/.ralph/` (ralph_loop.sh, ralph_monitor.sh, setup.sh, ralph_import.sh)
- **Libraries**: `~/.ralph/lib/` (circuit_breaker.sh, response_analyzer.sh)

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

## Recent Improvements

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

**Test Coverage**
- Added comprehensive test suite for error detection and stuck loop scenarios
- 13/13 error detection tests passing
- 9/9 stuck loop detection tests passing (including multi-error scenarios)
- Tests validate both single and multiple simultaneous recurring errors

### Installation Improvements
- Added `lib/` directory to installation process for modular architecture
- Fixed issue where `response_analyzer.sh` and `circuit_breaker.sh` were not being copied during global installation
- All library components now properly installed to `~/.ralph/lib/`

## Feature Development Quality Standards

**CRITICAL**: All new features MUST meet the following mandatory requirements before being considered complete.

### Testing Requirements

- **Coverage Target**: Aim for ~85%+ code coverage for new code where practical; do not reduce existing coverage.
- **Test Pass Rate**: 100% – all tests must pass, no exceptions
- **Test Types Required**:
  - Unit tests for bash script functions (if applicable)
  - Integration tests for Ralph loop behavior
  - End-to-end tests for full development cycles
- **Coverage Validation**:
  - For this repository, there is currently no automated coverage tool; coverage is estimated from the breadth and depth of the BATS suites. Run:
    ```bash
    npm test
    npm run test:unit
    npm run test:integration
    npm run test:e2e
    ```
  - For language-specific projects inside a Ralph-managed repo, use their own coverage commands (examples: `npm run test:coverage`, `pytest --cov=src tests/`, `cargo tarpaulin`) if those are configured.
- **Test Quality**: Tests must validate behavior, not just achieve coverage metrics
- **Test Documentation**: Complex test scenarios must include comments explaining the test strategy

For current test counts and estimated coverage in this repo, see `IMPLEMENTATION_STATUS.md`.

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
- [ ] Code coverage meets 85% minimum threshold (if applicable)
- [ ] Script functionality manually tested
- [ ] All changes committed with conventional commit messages
- [ ] All commits pushed to remote repository
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
