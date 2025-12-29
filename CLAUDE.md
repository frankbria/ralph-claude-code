# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Ralph is an autonomous AI development loop orchestrator that runs Claude Code iteratively until project completion. It implements intelligent safeguards (circuit breaker, rate limiting, exit detection) to prevent infinite loops and API waste.

**Core Goal**: Complete software projects with minimal human intervention while preventing token waste and runaway execution.

## Testing Commands

```bash
# Run all tests (75 tests across unit/integration suites)
bun test

# Run specific test suites
bun run test:unit          # Unit tests: rate limiting, exit detection (35 tests)
bun run test:integration   # Integration tests: loop execution, edge cases (40 tests)

# Run individual test files
bats tests/unit/test_rate_limiting.bats
bats tests/unit/test_exit_detection.bats
bats tests/integration/test_loop_execution.bats
bats tests/integration/test_edge_cases.bats
```

**Test Framework**: BATS (Bash Automated Testing System)

- Helper utilities in `tests/helpers/`
- Fixtures for creating test environments
- Mock functions for Claude Code execution
- All tests must pass at 100% before commits

## Architecture Overview

### Main Loop Flow (ralph_loop.sh)

```text
1. init_call_tracking() → Initialize rate limiting state
2. Circuit Breaker Check → CLOSED/HALF_OPEN/OPEN
3. Rate Limit Check → can_make_call()
4. execute_claude_code() → Run Claude with timeout (default: 15min)
5. Response Analysis → analyze_response() in lib/response_analyzer.sh
6. Update Exit Signals → update_exit_signals()
7. Circuit Breaker Update → record_loop_result()
8. Exit Check → should_exit_gracefully() or should_halt_execution()
9. Loop continues or exits based on conditions
```

### State Management (Persistent Files)

**Rate Limiting State:**

- `.call_count` - API calls made this hour
- `.last_reset` - Timestamp of last hourly reset

**Exit Detection State:**

- `.exit_signals` - JSON with rolling window arrays:
  - `test_only_loops` - Last 5 loops that only ran tests
  - `done_signals` - Last 5 loops with completion keywords
  - `completion_indicators` - Last 5 loops with high confidence scores
- `.response_analysis` - Latest loop analysis results
- `.last_output_length` - Track output size trends

**Circuit Breaker State:**

- `.circuit_breaker_state` - Current state (CLOSED/HALF_OPEN/OPEN) and counters
- `.circuit_breaker_history` - Historical events log

**Runtime State:**

- `status.json` - Current loop status (loop count, calls made, status)
- `progress.json` - Real-time progress for monitor dashboard

### Library Components (lib/)

**response_analyzer.sh** - Semantic analysis of Claude Code output

- Detects structured `---RALPH_STATUS---` blocks (preferred)
- Falls back to keyword detection for natural language
- Calculates confidence scores (0-100+)
- Identifies test-only loops vs implementation work
- Tracks file changes via git integration
- Exported functions: `analyze_response()`, `update_exit_signals()`, `detect_stuck_loop()`

**circuit_breaker.sh** - Prevents runaway loops

- Three states: CLOSED (normal), HALF_OPEN (recovery), OPEN (halted)
- Opens after 3 loops with no progress OR 5 loops with same error
- Tracks files changed, errors, output length per loop
- Exported functions: `init_circuit_breaker()`, `record_loop_result()`, `should_halt_execution()`, `reset_circuit_breaker()`

### Key Thresholds and Configuration

**Exit Detection** (ralph_loop.sh):

```bash
MAX_CONSECUTIVE_TEST_LOOPS=3      # Exit if 3+ consecutive test-only loops
MAX_CONSECUTIVE_DONE_SIGNALS=2    # Exit if 2+ "done" signals
TEST_PERCENTAGE_THRESHOLD=30      # Flag if 30%+ of loops are test-only
```

**Circuit Breaker** (lib/circuit_breaker.sh):

```bash
CB_NO_PROGRESS_THRESHOLD=3        # Open after 3 loops with 0 files changed
CB_SAME_ERROR_THRESHOLD=5         # Open after 5 loops with identical error
CB_OUTPUT_DECLINE_THRESHOLD=70    # Open if output declines >70%
```

**Rate Limiting** (ralph_loop.sh):

```bash
MAX_CALLS_PER_HOUR=100           # Default hourly limit (configurable via --calls)
CLAUDE_TIMEOUT_MINUTES=15        # Default timeout per loop (configurable via --timeout)
```

## Response Analysis Patterns

When Ralph analyzes Claude Code output, it looks for these patterns:

**Structured Output**: Ralph expects Claude Code to emit structured status blocks. See [CONTRIBUTING.md](CONTRIBUTING.md#structured-status-output) for the full format specification.

**Natural Language Patterns** (fallback):

- Completion keywords: "done", "complete", "finished", "all tasks complete", "project complete"
- Test patterns: "bun test", "bats", "pytest", "jest", "running tests"
- Stuck indicators: "error", "failed", "cannot", "unable to", "blocked"
- No-work patterns: "nothing to do", "no changes", "already implemented", "up to date"

## Template System

Ralph projects created with `ralph-setup` or `ralph-import` follow this structure:

**Control Files** (prefixed with @):

- `PROMPT.md` - Main development instructions for Ralph
- `@fix_plan.md` - Prioritized task list (markdown checkboxes)
- `@AGENT.md` - Build and run instructions

**Generated Directories** (created automatically by scripts):

- `logs/` - Execution logs (ignored by git)
- `docs/generated/` - Auto-generated docs (ignored by git)
- `specs/` - Project specifications
- `src/` - Source code
- `examples/` - Usage examples

## File Naming Conventions

- Scripts use bash with `.sh` extension
- Library components in `lib/` are sourced, not executed
- State files use `.` prefix (`.call_count`, `.exit_signals`)
- Templates in `templates/` directory
- Test files use `.bats` extension (BATS framework)
- Test helpers use `.bash` extension in `tests/helpers/`

## Cross-Platform Compatibility

**Date Command Handling** - Ralph supports both BSD (macOS) and GNU (Linux) date:

```bash
if date -v+1H &>/dev/null 2>&1; then
    # macOS / BSD date
    date -v+1H -Iseconds
else
    # GNU date (Linux)
    date -d '+1 hour' -Iseconds
fi
```

This pattern is used in `get_next_hour_time()` and should be followed for any date calculations.

## Installation Architecture

**Global Installation** (via `./install.sh`):

- Commands installed to `~/.local/bin/`: ralph, ralph-monitor, ralph-setup, ralph-import
- Scripts and templates copied to `~/.ralph/`
- User must add `~/.local/bin` to PATH if not already present

**Per-Project Setup** (via `ralph-setup` or `ralph-import`):

- Creates project directory with templates
- Initializes git repository
- Copies templates from `~/.ralph/templates/`
- Creates standard directory structure

## Important Implementation Details

**Bash Error Handling**: Main scripts use `set -e` (exit on error), so all functions must return 0 on success. Use explicit `return 0` in library functions.

**JSON State Files**: All state files use JSON format and are manipulated with `jq`. Always validate JSON before writing.

**Git Integration**: Response analyzer checks `git diff --name-only` to count files changed. Ralph projects must be git repositories.

**Tmux Integration**: The `--monitor` flag creates a tmux session with split panes (left: ralph loop, right: ralph-monitor). Session naming: `ralph-$(date +%s)`

**Progress Tracking**: During Claude Code execution, `progress.json` is updated every 10 seconds with a spinner indicator and last output line (for monitor display).

## Testing Infrastructure

**Test Helpers** (`tests/helpers/`):

- `test_helper.bash` - Common setup/teardown, assertion helpers
- `mocks.bash` - Mock functions for Claude Code, git, etc.
- `fixtures.bash` - Create sample files (PROMPT.md, @fix_plan.md, etc.)

**Test Isolation**: Each test runs in a temporary directory created by `mktemp -d`, removed in teardown.

**Mocking Strategy**: Tests mock Claude Code execution by creating output files with expected content, not by calling actual API.

## Feature Development Quality Standards

**CRITICAL**: All new features MUST meet mandatory quality requirements. See [CONTRIBUTING.md](CONTRIBUTING.md#feature-development-quality-standards) for complete standards including:

- Testing requirements (85% coverage, 100% pass rate)
- Git workflow (conventional commits, push to remote)
- Documentation requirements (keep all docs synchronized)

## Common Development Patterns

**Adding New Exit Conditions**:

1. Add detection logic in `ralph_loop.sh::should_exit_gracefully()`
2. Return exit reason string (e.g., "custom_marker")
3. Add tests in `tests/unit/test_exit_detection.bats`
4. Update documentation

**Adding Response Analysis Patterns**:

1. Add keyword array in `lib/response_analyzer.sh`
2. Add grep pattern check in `analyze_response()`
3. Adjust confidence score appropriately
4. Add tests in `tests/integration/test_loop_execution.bats`

**State File Management**:

1. Always initialize in `init_*()` functions
2. Use jq for JSON manipulation
3. Validate before writing (check jq exit code)
4. Handle missing/corrupted files gracefully

## References

- **Architecture**: See `docs/ARCHITECTURE.md` for detailed component diagrams
- **Roadmap**: See `docs/ROADMAP.md` for development plan and test specifications
- **Contributing**: See `CONTRIBUTING.md` for full development guidelines
