# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

**Version**: v0.11.3 | **Tests**: 452 passing (100% pass rate) | **CI/CD**: GitHub Actions

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
6. **ralph_enable.sh** - Interactive wizard for enabling Ralph in existing projects
   - Multi-step wizard with environment detection, task source selection, configuration
   - Imports tasks from beads, GitHub Issues, or PRD documents
   - Generates `.ralphrc` project configuration file
7. **ralph_enable_ci.sh** - Non-interactive version for CI/automation
   - Same functionality as interactive version with CLI flags
   - JSON output mode for machine parsing
   - Exit codes: 0 (success), 1 (error), 2 (already enabled)

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
   - Automatic session persistence to `.ralph/.claude_session_id` file with 24-hour expiration
   - Session lifecycle: `get_session_id()`, `reset_session()`, `log_session_transition()`, `init_session_tracking()`
   - Session history tracked in `.ralph/.ralph_session_history` (last 50 transitions)
   - Session auto-reset on: circuit breaker open, manual interrupt, project completion
   - Detects test-only loops and stuck error patterns
   - Two-stage error filtering to eliminate false positives
   - Multi-line error matching for accurate stuck loop detection
   - Confidence scoring for exit decisions

3. **lib/date_utils.sh** - Cross-platform date utilities
   - ISO timestamp generation for logging
   - Epoch time calculations for rate limiting

4. **lib/timeout_utils.sh** - Cross-platform timeout command utilities
   - Detects and uses appropriate timeout command for the platform
   - Linux: Uses standard `timeout` from GNU coreutils
   - macOS: Uses `gtimeout` from Homebrew coreutils
   - `portable_timeout()` function for seamless cross-platform execution
   - Automatic detection with caching for performance

5. **lib/enable_core.sh** - Shared logic for ralph enable commands
   - Idempotency checks: `check_existing_ralph()`, `is_ralph_enabled()`
   - Safe file operations: `safe_create_file()`, `safe_create_dir()`
   - Project detection: `detect_project_context()`, `detect_git_info()`, `detect_task_sources()`
   - Template generation: `generate_prompt_md()`, `generate_agent_md()`, `generate_fix_plan_md()`, `generate_ralphrc()`

6. **lib/wizard_utils.sh** - Interactive prompt utilities for enable wizard
   - User prompts: `confirm()`, `prompt_text()`, `prompt_number()`
   - Selection utilities: `select_option()`, `select_multiple()`, `select_with_default()`
   - Output formatting: `print_header()`, `print_bullet()`, `print_success/warning/error/info()`

7. **lib/task_sources.sh** - Task import from external sources
   - Beads integration: `check_beads_available()`, `fetch_beads_tasks()`, `get_beads_count()`
   - GitHub integration: `check_github_available()`, `fetch_github_tasks()`, `get_github_issue_count()`
   - PRD extraction: `extract_prd_tasks()`, supports checkbox and numbered list formats
   - Task normalization: `normalize_tasks()`, `prioritize_tasks()`, `import_tasks_from_sources()`

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

### Migrating Existing Projects
```bash
# Migrate from flat structure to .ralph/ subfolder (v0.10.0+)
cd existing-project
ralph-migrate
```

### Enabling Ralph in Existing Projects
```bash
# Interactive wizard (recommended for humans)
cd existing-project
ralph-enable

# With specific task source
ralph-enable --from beads
ralph-enable --from github --label "sprint-1"
ralph-enable --from prd ./docs/requirements.md

# Force overwrite existing .ralph/
ralph-enable --force

# Non-interactive for CI/scripts
ralph-enable-ci                              # Sensible defaults
ralph-enable-ci --from github               # With task source
ralph-enable-ci --project-type typescript   # Override detection
ralph-enable-ci --json                      # Machine-readable output
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
# Run all tests (420 tests)
npm test

# Run specific test suites
npm run test:unit
npm run test:integration

# Run individual test files
bats tests/unit/test_cli_parsing.bats
bats tests/unit/test_json_parsing.bats
bats tests/unit/test_cli_modern.bats
bats tests/unit/test_enable_core.bats
bats tests/unit/test_task_sources.bats
bats tests/unit/test_ralph_enable.bats
```

## Ralph Loop Configuration

The loop is controlled by several key files and environment variables within the `.ralph/` subfolder:

- **.ralph/PROMPT.md** - Main prompt file that drives each loop iteration
- **.ralph/fix_plan.md** - Prioritized task list that Ralph follows
- **.ralph/AGENT.md** - Build and run instructions maintained by Ralph
- **.ralph/status.json** - Real-time status tracking (JSON format)
- **.ralph/logs/** - Execution logs for each loop iteration

### Rate Limiting
- Default: 100 API calls per hour (configurable via `--calls` flag)
- Automatic hourly reset with countdown display
- Call tracking persists across script restarts

### Modern CLI Configuration (Phase 1.1)

Ralph uses modern Claude Code CLI flags for structured communication:

**Configuration Variables:**
```bash
CLAUDE_OUTPUT_FORMAT="json"           # Output format: json (default) or text
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"  # Allowed tool permissions
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
- Remaining tasks from fix_plan.md
- Circuit breaker state (if not CLOSED)
- Previous loop work summary

**Session Continuity:**
- Sessions are preserved in `.ralph/.claude_session_id`
- Use `--continue` flag to maintain context across loops
- Disable with `--no-continue` for isolated iterations

### Intelligent Exit Detection
The loop uses a dual-condition check to prevent premature exits during productive iterations:

**Exit requires BOTH conditions:**
1. `recent_completion_indicators >= 2` (heuristic-based detection from natural language patterns)
2. Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block

The `EXIT_SIGNAL` value is read from `.ralph/.response_analysis` (at `.analysis.exit_signal`) which is populated by `response_analyzer.sh` from Claude's RALPH_STATUS output block.

**Other exit conditions (checked before completion indicators):**
- Multiple consecutive "done" signals from Claude Code (`done_signals >= 2`)
- Too many test-only loops indicating feature completeness (`test_loops >= 3`)
- All items in .ralph/fix_plan.md marked as completed

**Example behavior when EXIT_SIGNAL is false:**
```
Loop 5: Claude outputs "Phase complete, moving to next feature"
        → completion_indicators: 3 (high confidence from patterns)
        → EXIT_SIGNAL: false (Claude explicitly says more work needed)
        → Result: CONTINUE (respects Claude's explicit intent)

Loop 8: Claude outputs "All tasks complete, project ready"
        → completion_indicators: 4
        → EXIT_SIGNAL: true (Claude confirms project is done)
        → Result: EXIT with "project_complete"
```

**Rationale:** Natural language patterns like "done" or "complete" can trigger false positives during productive work (e.g., "feature done, moving to tests"). By requiring Claude's explicit EXIT_SIGNAL confirmation, Ralph avoids exiting mid-iteration when Claude is still working.

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

Each project created with `./setup.sh` follows this structure with a `.ralph/` subfolder:
```
project-name/
├── .ralph/                # Ralph configuration and state (hidden folder)
│   ├── PROMPT.md          # Main development instructions
│   ├── fix_plan.md       # Prioritized TODO list
│   ├── AGENT.md          # Build/run instructions
│   ├── specs/             # Project specifications
│   ├── examples/          # Usage examples
│   ├── logs/              # Loop execution logs
│   └── docs/generated/    # Auto-generated documentation
└── src/                   # Source code (at project root)
```

> **Migration**: Existing projects can be migrated with `ralph-migrate`.

## Template System

Templates in `templates/` provide starting points for new projects:
- **PROMPT.md** - Instructions for Ralph's autonomous behavior
- **fix_plan.md** - Initial task structure
- **AGENT.md** - Build system template

## File Naming Conventions

- Ralph control files (`fix_plan.md`, `AGENT.md`, `PROMPT.md`) reside in the `.ralph/` directory
- Hidden files within `.ralph/` (e.g., `.ralph/.call_count`, `.ralph/.exit_signals`) track loop state
- `.ralph/logs/` contains timestamped execution logs
- `.ralph/docs/generated/` for Ralph-created documentation
- `docs/code-review/` for code review reports (at project root)

## Global Installation

Ralph installs to:
- **Commands**: `~/.local/bin/` (ralph, ralph-monitor, ralph-setup, ralph-import, ralph-migrate, ralph-enable, ralph-enable-ci)
- **Templates**: `~/.ralph/templates/`
- **Scripts**: `~/.ralph/` (ralph_loop.sh, ralph_monitor.sh, setup.sh, ralph_import.sh, migrate_to_ralph_folder.sh, ralph_enable.sh, ralph_enable_ci.sh)
- **Libraries**: `~/.ralph/lib/` (circuit_breaker.sh, response_analyzer.sh, date_utils.sh, timeout_utils.sh, enable_core.sh, wizard_utils.sh, task_sources.sh)

After installation, the following global commands are available:
- `ralph` - Start the autonomous development loop
- `ralph-monitor` - Launch the monitoring dashboard
- `ralph-setup` - Create a new Ralph-managed project
- `ralph-import` - Import PRD/specification documents to Ralph format
- `ralph-migrate` - Migrate existing projects from flat structure to `.ralph/` subfolder
- `ralph-enable` - Interactive wizard to enable Ralph in existing projects
- `ralph-enable-ci` - Non-interactive version for CI/automation

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
- Completion detection via .ralph/fix_plan.md checklist items

### Completion Indicators with EXIT_SIGNAL Gate

The `completion_indicators` exit condition requires dual verification:

| completion_indicators | EXIT_SIGNAL | .response_analysis | Result |
|-----------------------|-------------|-------------------|--------|
| >= 2 | `true` | exists | **Exit** ("project_complete") |
| >= 2 | `false` | exists | **Continue** (Claude still working) |
| >= 2 | N/A | missing | **Continue** (defaults to false) |
| >= 2 | N/A | malformed | **Continue** (defaults to false) |
| < 2 | `true` | exists | **Continue** (threshold not met) |

**Implementation** (`ralph_loop.sh:312-327`):
```bash
local claude_exit_signal="false"
if [[ -f "$RALPH_DIR/.response_analysis" ]]; then
    claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RALPH_DIR/.response_analysis" 2>/dev/null || echo "false")
fi

if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
    echo "project_complete"
    return 0
fi
```

**Conflict Resolution:** When `STATUS: COMPLETE` but `EXIT_SIGNAL: false` in RALPH_STATUS, the explicit EXIT_SIGNAL takes precedence. This allows Claude to mark a phase complete while indicating more phases remain.

### Circuit Breaker Thresholds
- `CB_NO_PROGRESS_THRESHOLD=3` - Open circuit after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` - Open circuit after 5 loops with repeated errors
- `CB_OUTPUT_DECLINE_THRESHOLD=70%` - Open circuit if output declines by >70%
- `CB_PERMISSION_DENIAL_THRESHOLD=2` - Open circuit after 2 loops with permission denials (Issue #101)

### Permission Denial Detection (Issue #101)

When Claude Code is denied permission to execute commands (e.g., `npm install`), Ralph detects this from the `permission_denials` array in the JSON output and halts the loop immediately:

1. **Detection**: The `parse_json_response()` function extracts `permission_denials` from Claude Code output
2. **Fields tracked**:
   - `has_permission_denials` (boolean)
   - `permission_denial_count` (integer)
   - `denied_commands` (array of command strings)
3. **Exit behavior**: When `has_permission_denials=true`, Ralph exits with reason "permission_denied"
4. **User guidance**: Ralph displays instructions to update `ALLOWED_TOOLS` in `.ralphrc`

**Example `.ralphrc` tool patterns:**
```bash
# Broad patterns (recommended for development)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"

# Specific patterns (more restrictive)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git commit),Bash(npm install)"
```

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

### Test Files (420 tests total)

| File | Tests | Description |
|------|-------|-------------|
| `test_cli_parsing.bats` | 27 | CLI argument parsing for all 12 flags |
| `test_cli_modern.bats` | 29 | Modern CLI commands (Phase 1.1) + build_claude_command fix |
| `test_json_parsing.bats` | 45 | JSON output format parsing + Claude CLI format + session management + array format |
| `test_session_continuity.bats` | 28 | Session lifecycle management + circuit breaker integration + issue #91 fix |
| `test_exit_detection.bats` | 35 | Exit signal detection + EXIT_SIGNAL-based completion indicators |
| `test_rate_limiting.bats` | 15 | Rate limiting behavior |
| `test_loop_execution.bats` | 20 | Integration tests |
| `test_edge_cases.bats` | 20 | Edge case handling |
| `test_installation.bats` | 14 | Global installation/uninstall workflows |
| `test_project_setup.bats` | 36 | Project setup (setup.sh) validation |
| `test_prd_import.bats` | 33 | PRD import (ralph_import.sh) workflows + modern CLI tests |
| `test_enable_core.bats` | 30 | Enable core library (idempotency, project detection, template generation) |
| `test_task_sources.bats` | 23 | Task sources (beads, GitHub, PRD extraction, normalization) |
| `test_ralph_enable.bats` | 22 | Ralph enable integration tests (wizard, CI version, JSON output) |
| `test_wizard_utils.bats` | 20 | Wizard utility functions (stdout/stderr separation, prompt functions) |

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

### Live Streaming & Beads Fix (v0.11.3)
- Added live streaming output mode with `--live` flag for real-time Claude Code visibility (#125)
- Fixed beads task import using correct `bd list` arguments (#150)
- Applied CodeRabbit review fixes: camelCase variable naming, status-respecting fallback, jq guards for missing fields
- Test count: 452 (up from 440)

### Setup Permissions Fix (v0.11.2)
- Fixed issue #136: `ralph-setup` now creates `.ralphrc` with consistent tool permissions
- Updated default `ALLOWED_TOOLS` from `Write,Bash(git *),Read` to `Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)`
- Both `ralph-setup` and `ralph-enable` now create identical `.ralphrc` configurations
- Added 8 new TDD tests for `.ralphrc` creation and ALLOWED_TOOLS defaults
- Test count: 440 (up from 424)

### Completion Indicators Fix (v0.11.1)
- Fixed premature exit after exactly 5 loops in JSON output mode
- Root cause: `update_exit_signals()` used confidence threshold (≥60) to populate `completion_indicators`
  - JSON mode always has confidence ≥70 due to deterministic scoring (+50 for JSON format, +20 for result field)
  - This caused every successful JSON response to increment `completion_indicators`
  - After 5 loops, safety circuit breaker triggered even when Claude set `EXIT_SIGNAL: false`
- Fix: Replaced confidence-based heuristic with explicit EXIT_SIGNAL checking
  - `completion_indicators` now only accumulates when `exit_signal == "true"`
  - Aligns with documented behavior in CLAUDE.md and README.md
  - Confidence scoring retained for analysis/logging purposes
- Updated safety circuit breaker documentation in `ralph_loop.sh` to reflect new behavior
- Added 4 new TDD tests (Tests 32-35) for `update_exit_signals()` behavior
- Test count: 424 (up from 420)

### Ralph Enable Command (v0.11.0)
- Added `ralph-enable` interactive wizard for enabling Ralph in existing projects
  - 5-phase wizard: Environment Detection → Task Source Selection → Configuration → File Generation → Verification
  - Auto-detects project type (TypeScript, Python, Rust, Go) and framework (Next.js, FastAPI, Django)
  - Imports tasks from beads, GitHub Issues, or PRD documents
  - Generates `.ralphrc` project configuration file
- Added `ralph-enable-ci` non-interactive version for CI/automation
  - JSON output mode (`--json`) for machine parsing
  - Exit codes: 0 (success), 1 (error), 2 (already enabled)
  - Override flags: `--project-name`, `--project-type`, `--from`, `--force`
- New library components:
  - `lib/enable_core.sh` - Shared enable logic with idempotency checks
  - `lib/wizard_utils.sh` - Interactive prompt utilities
  - `lib/task_sources.sh` - Task import from beads/GitHub/PRD
- Updated `ralph_loop.sh` to load `.ralphrc` configuration at startup
- Added 75 new tests (30 enable_core + 23 task_sources + 22 integration)
- Test count: 396 (up from 321)
- Related issues: #85, #121, #64, #87, #99

### Stale Completion Indicators Fix (v0.10.1) - Issue #91
- Fixed premature exit caused by stale completion indicators persisting across sessions
- Root cause: `.exit_signals` and `.response_analysis` files retained old completion counts
- Enhanced `reset_session()` to clear exit-related state files:
  - Resets `.exit_signals` to empty structure (no completion indicators)
  - Removes `.response_analysis` to prevent stale EXIT_SIGNAL detection
- Session reset now comprehensively clears: session ID, exit signals, and response analysis
- Added 2 new tests validating exit signal clearing behavior
- Test count: 321 (up from 319)

### JSON Array Format Support (v0.10.1)
- Fixed `parse_json_response` to handle Claude CLI JSON array output format (issue #112)
- Claude CLI outputs `[{type: "system", ...}, {type: "assistant", ...}, {type: "result", ...}]`
- Previously expected single JSON object, now supports three formats:
  1. Flat format: `{ status, exit_signal, work_type, ... }`
  2. Claude CLI object format: `{ result, sessionId, metadata: {...} }`
  3. Claude CLI array format: `[ {type: "result", ...}, ... ]`
- Extracts `result` type message from array and normalizes to object format
- Preserves `session_id` from init message for session continuity
- Added 9 new tests for JSON array format handling (including session_id-in-result regression test)
- Review fixes: guard against empty result_obj, prioritize result object's session_id
- Test count: 319 (up from 310)

### .ralph/ Subfolder Structure (v0.10.0) - BREAKING CHANGE
- **Breaking**: Moved all Ralph-specific files to `.ralph/` subfolder
- Project root stays clean: only `src/`, `README.md`, and user files remain
- Added `ralph-migrate` command for upgrading existing projects
- Migration script with fail-safe copy pattern (`cp -a source/. dest/`)
- Auto-detection of old structure with upgrade guidance
- Updated all configuration variables to use `$RALPH_DIR` prefix
- Test count: 310 (up from 308)

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
- Output file validation: PROMPT.md, fix_plan.md, specs/requirements.md creation
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
- Template copying verification for PROMPT.md, fix_plan.md, AGENT.md
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
   - Update .ralph/fix_plan.md with new tasks before starting work
   - Mark items complete in .ralph/fix_plan.md upon completion
   - Update .ralph/PROMPT.md if Ralph's behavior needs modification
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
   - Update AGENT.md template with new build patterns
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
- [ ] .ralph/fix_plan.md task marked as complete
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
- **Traceability**: Git commits and fix_plan.md provide clear history of changes
- **Maintainability**: Current documentation reduces onboarding time and prevents knowledge loss
- **Collaboration**: Pushed changes enable team visibility and code review
- **Reliability**: Consistent quality gates maintain Ralph loop stability
- **Automation**: Ralph integration ensures continuous development practices

**Enforcement**: AI agents should automatically apply these standards to all feature development tasks without requiring explicit instruction for each task.
