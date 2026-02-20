# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

See [README.md](README.md) for version info, changelog, and user documentation.

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
   - ISO-to-epoch conversion for cooldown timer comparisons (`parse_iso_to_epoch()`)

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
   - POSIX-compatible: Uses `tr '[:upper:]' '[:lower:]'` instead of `${,,}` for bash 3.x support (Issue #187)

7. **lib/task_sources.sh** - Task import from external sources
   - Beads integration: `check_beads_available()`, `fetch_beads_tasks()`, `get_beads_count()`
   - GitHub integration: `check_github_available()`, `fetch_github_tasks()`, `get_github_issue_count()`
   - PRD extraction: `extract_prd_tasks()`, supports checkbox and numbered list formats
   - Task normalization: `normalize_tasks()`, `prioritize_tasks()`, `import_tasks_from_sources()`

8. **lib/file_protection.sh** - File integrity validation for Ralph projects (Issue #149)
   - `RALPH_REQUIRED_PATHS` array: critical files needed for the loop to function
   - `validate_ralph_integrity()`: checks all required paths exist, sets `RALPH_MISSING_FILES`
   - `get_integrity_report()`: human-readable report with missing files and recovery instructions
   - Lightweight validation that runs every loop iteration

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
ralph --auto-reset-circuit   # Auto-reset OPEN state on startup

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
# Run all tests (566 tests)
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
bats tests/unit/test_circuit_breaker_recovery.bats
bats tests/unit/test_file_protection.bats
bats tests/unit/test_integrity_check.bats
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
CLAUDE_CODE_CMD="claude"              # Claude Code CLI command (configurable via .ralphrc, Issue #97)
CLAUDE_OUTPUT_FORMAT="json"           # Output format: json (default) or text
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),...,Bash(npm *),Bash(pytest)"  # Allowed tool permissions (see File Protection)
CLAUDE_USE_CONTINUE=true              # Enable session continuity
CLAUDE_MIN_VERSION="2.0.76"           # Minimum Claude CLI version
```

**Claude Code CLI Command (Issue #97):**
- `CLAUDE_CODE_CMD` defaults to `"claude"` (global install)
- Configurable via `.ralphrc` for alternative installations (e.g., `"npx @anthropic-ai/claude-code"`)
- Auto-detected during `ralph-enable` and `ralph-setup` (prefers `claude` if available, falls back to npx)
- Validated at startup with `validate_claude_command()` — displays clear error with installation instructions if not found
- Environment variable `CLAUDE_CODE_CMD` takes precedence over `.ralphrc`

**CLI Options:**
- `--output-format json|text` - Set Claude output format (default: json). Note: `--live` mode requires JSON and will auto-switch from text to json.
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
- **Libraries**: `~/.ralph/lib/` (circuit_breaker.sh, response_analyzer.sh, date_utils.sh, timeout_utils.sh, enable_core.sh, wizard_utils.sh, task_sources.sh, file_protection.sh)

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

### Timeout Handling (Issue #175)

When Claude Code exceeds `CLAUDE_TIMEOUT_MINUTES`, `portable_timeout` terminates the process with exit code **124**. The loop handles this differently depending on the execution mode:

**Live mode** (`--live`/`--monitor`): The streaming pipeline uses `set -o pipefail` to capture per-command exit codes via `PIPESTATUS`. Because `set -e` would cause the script to exit silently on the non-zero pipeline status, `set -e` is temporarily disabled (`set +e`) around the pipeline and re-enabled after `PIPESTATUS` is captured. Timeout events are logged as a WARN:

```
[timestamp] [WARN] Claude Code execution timed out after 15 minutes
```

**Background mode** (default): The Claude process runs in a background subshell (`&`), so its exit code does not trigger `set -e`. The exit code is captured via `wait $claude_pid`.

In both modes, a timeout results in `exit_code=124`, which flows into the standard error handling path (logged, circuit breaker updated, loop continues to next iteration).

### API Limit Detection (Issue #183)

The API 5-hour limit detection uses a three-layer approach to avoid false positives. In stream-json mode, output files contain echoed file content from tool results (`"type":"user"` lines). If project files mention "5-hour limit", naive grep patterns match those echoed strings, incorrectly triggering the API limit recovery flow.

**Layer 1 — Timeout guard:**
Exit code 124 (timeout) is checked first. Timeouts return code 1 (generic error), never code 2 (API limit).

**Layer 2 — Structural JSON detection (primary):**
Parses `rate_limit_event` JSON in the output for `"status":"rejected"`. This is the definitive signal from the Claude CLI.

**Layer 3 — Filtered text fallback:**
Only searches `tail -30` of the output file, filtering out `"type":"user"`, `"tool_result"`, and `"tool_use_id"` lines before matching text patterns.

**Unattended mode:** When the API limit prompt times out (no user response within 30s), Ralph auto-waits instead of exiting, supporting unattended operation.

### Circuit Breaker Thresholds
- `CB_NO_PROGRESS_THRESHOLD=3` - Open circuit after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` - Open circuit after 5 loops with repeated errors
- `CB_OUTPUT_DECLINE_THRESHOLD=70%` - Open circuit if output declines by >70%
- `CB_PERMISSION_DENIAL_THRESHOLD=2` - Open circuit after 2 loops with permission denials (Issue #101)

### Circuit Breaker Auto-Recovery (Issue #160)

The OPEN state is no longer terminal. Two recovery mechanisms are available:

**Cooldown Timer (default):** After `CB_COOLDOWN_MINUTES` (default: 30) in OPEN state, the circuit transitions to HALF_OPEN on next `init_circuit_breaker()` call. The existing HALF_OPEN logic handles recovery (progress → CLOSED) or re-trip (no progress → OPEN).

**Auto-Reset:** When `CB_AUTO_RESET=true`, the circuit resets directly to CLOSED on startup, bypassing the cooldown. Use for fully unattended operation.

**Configuration:**
```bash
CB_COOLDOWN_MINUTES=30    # Minutes before OPEN → HALF_OPEN (0 = immediate)
CB_AUTO_RESET=false       # true = bypass cooldown, reset to CLOSED on startup
```

**CLI flag:** `ralph --auto-reset-circuit` sets `CB_AUTO_RESET=true` for a single run.

**State file:** The `opened_at` field tracks when the circuit entered OPEN state. Old state files without this field fall back to `last_change` for backward compatibility.

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

### File Protection (Issue #149)

Ralph uses a multi-layered strategy to prevent Claude from accidentally deleting its own configuration files:

**Layer 1: ALLOWED_TOOLS Restriction**
- The default `CLAUDE_ALLOWED_TOOLS` uses granular `Bash(git add *)`, `Bash(git commit *)` etc. instead of `Bash(git *)`, preventing `git clean`, `git rm`, and other destructive git commands
- Users can override in `.ralphrc` but the defaults are safe

**Layer 2: PROMPT.md Warning**
- The PROMPT.md template includes a "Protected Files (DO NOT MODIFY)" section listing `.ralph/` and `.ralphrc`
- This instructs Claude to never delete, move, rename, or overwrite these files

**Layer 3: Pre-Loop Integrity Check**
- `validate_ralph_integrity()` from `lib/file_protection.sh` runs at startup and before every loop iteration
- Checks for required paths: `.ralph/`, `.ralph/PROMPT.md`, `.ralph/fix_plan.md`, `.ralph/AGENT.md`, `.ralphrc`
- On failure: logs error, displays recovery report, resets session, and halts the loop
- Recovery: `ralph-enable --force` restores missing files

**Required vs Optional Files:**

| Required (validation fails) | Optional (no validation) |
|---|---|
| `.ralph/` directory | `.ralph/logs/` |
| `.ralph/PROMPT.md` | `.ralph/status.json` |
| `.ralph/fix_plan.md` | `.ralph/.call_count` |
| `.ralph/AGENT.md` | `.ralph/.exit_signals` |
| `.ralphrc` | `.ralph/.circuit_breaker_state` |

## Test Suite

### Test Files (566 tests total)

| File | Tests | Description |
|------|-------|-------------|
| `test_circuit_breaker_recovery.bats` | 19 | Cooldown timer, auto-reset, parse_iso_to_epoch, CLI flag (Issue #160) |
| `test_cli_parsing.bats` | 35 | CLI argument parsing for all flags + monitor parameter forwarding |
| `test_cli_modern.bats` | 66 | Modern CLI commands (Phase 1.1) + build_claude_command fix + live mode text format fix (#164) + errexit pipeline guard (#175) + ALLOWED_TOOLS tightening (#149) + API limit false positive detection (#183) + Claude CLI command validation (#97) |
| `test_json_parsing.bats` | 52 | JSON output format parsing + Claude CLI format + session management + array format |
| `test_session_continuity.bats` | 44 | Session lifecycle management + expiration + circuit breaker integration + issue #91 fix |
| `test_exit_detection.bats` | 53 | Exit signal detection + EXIT_SIGNAL-based completion indicators + progress detection |
| `test_rate_limiting.bats` | 15 | Rate limiting behavior |
| `test_loop_execution.bats` | 20 | Integration tests |
| `test_edge_cases.bats` | 25 | Edge case handling |
| `test_installation.bats` | 15 | Global installation/uninstall workflows + dotfile template copying (#174) |
| `test_project_setup.bats` | 50 | Project setup (setup.sh) validation + .ralphrc permissions + .gitignore (#174) |
| `test_prd_import.bats` | 33 | PRD import (ralph_import.sh) workflows + modern CLI tests |
| `test_enable_core.bats` | 38 | Enable core library (idempotency, project detection, template generation, .gitignore #174) |
| `test_task_sources.bats` | 23 | Task sources (beads, GitHub, PRD extraction, normalization) |
| `test_ralph_enable.bats` | 24 | Ralph enable integration tests (wizard, CI version, JSON output, .ralphrc validation #149) |
| `test_wizard_utils.bats` | 20 | Wizard utility functions (stdout/stderr separation, prompt functions) |
| `test_file_protection.bats` | 22 | File integrity validation (RALPH_REQUIRED_PATHS, validate_ralph_integrity, get_integrity_report) (Issue #149) |
| `test_integrity_check.bats` | 12 | Pre-loop integrity check in ralph_loop.sh (startup + in-loop validation) (Issue #149) |

### Running Tests
```bash
# All tests
npm test

# Unit tests only
npm run test:unit

# Specific test file
bats tests/unit/test_cli_parsing.bats
```

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

### E2E Testing Philosophy (v2 UI)

When Ralph introduces a web-based UI (v2), end-to-end testing is the primary quality gate for all frontend work:

- **Framework**: Playwright for all browser automation and E2E tests
- **Real services only**: E2E tests run against real backends — no mocked APIs or stubbed services
- **User journey coverage**: Every user-facing workflow must have at least one E2E test covering the happy path
- **Visual regression**: Use Playwright screenshot comparisons for layout-critical components
- **Accessibility**: Include automated a11y checks (e.g., `@axe-core/playwright`) in E2E runs
- **CI integration**: E2E tests must pass in the GitHub Actions pipeline before merge

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
