# Contributing to Ralph

This guide helps contributors understand the Ralph codebase architecture and development practices. It's designed to help both human developers and AI assistants (like Claude Code) work effectively on Ralph.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

## Core Architecture

The system follows a modular bash architecture with library components:

### Main Scripts

1. **ralph_loop.sh** - Main autonomous loop with rate limiting, timeout handling, and tmux integration
2. **ralph_monitor.sh** - Real-time monitoring dashboard showing loop status, API usage, and logs
3. **setup.sh** - Project initialization (creates PROMPT.md, @fix_plan.md, @AGENT.md, directory structure)
4. **ralph_import.sh** - Converts existing PRDs/specs into Ralph format using Claude Code
5. **install.sh** - Global installation to ~/.local/bin and ~/.ralph/
6. **create_files.sh** - Bootstrap script that creates the entire Ralph system

### Library Components (lib/)

- **response_analyzer.sh** - Analyzes Claude Code output for completion signals, test-only loops, stuck indicators, and progress tracking
- **circuit_breaker.sh** - Implements circuit breaker pattern (CLOSED/HALF_OPEN/OPEN states) to prevent runaway loops and token waste

### Key Design Patterns

- **Circuit Breaker**: Prevents runaway loops by detecting stagnation (no progress threshold: 3 loops, same error threshold: 5 loops)
- **Response Analysis**: Semantic understanding of Claude Code output using keyword detection and heuristics
- **Rate Limiting**: Hourly API call tracking with automatic reset and countdown timers
- **State Management**: JSON-based state files (.call_count, .circuit_breaker_state, status.json) for persistence across restarts

## Key Commands

### Installation

See [README.md](README.md#-quick-start) for installation instructions.

### Setting Up a New Project

```bash
# Create a new Ralph-managed project (run from anywhere)
ralph-setup my-project-name
cd my-project-name

# Or import existing PRD/specs
ralph-import requirements.md my-project-name
```

### Running the Ralph Loop

```bash
# Start with integrated tmux monitoring (recommended)
ralph --monitor

# Start without monitoring
ralph

# With custom parameters and monitoring
ralph --monitor --calls 50 --prompt my_custom_prompt.md --timeout 30 --verbose

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

### Testing

```bash
# Run all tests (75 tests across unit/integration/e2e suites)
bun test

# Run specific test suites
bun run test:unit          # Unit tests for rate limiting, exit detection
bun run test:integration   # Integration tests for loop execution, edge cases
bun run test:e2e          # End-to-end tests (when available)

# Run individual test files
bats tests/unit/test_rate_limiting.bats
bats tests/integration/test_loop_execution.bats
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

- Multiple consecutive "done" signals from Claude Code (threshold: 2)
- Too many test-only loops indicating feature completeness (threshold: 3)
- All items in @fix_plan.md marked as completed
- Strong completion indicators in responses
- EXIT_SIGNAL: true in structured status output

### Structured Status Output

Ralph expects Claude Code to output structured status blocks in the format:

```text
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary>
---END_RALPH_STATUS---
```

This structured output is parsed by `response_analyzer.sh` to make intelligent decisions about loop continuation.

## Project Structure for Ralph-Managed Projects

Each project created with `./setup.sh` follows this structure:

```text
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

- **Commands**: `~/.local/bin/` (ralph, ralph-monitor, ralph-setup)
- **Templates**: `~/.ralph/templates/`
- **Scripts**: `~/.ralph/` (ralph_loop.sh, ralph_monitor.sh, setup.sh)

## Integration Points

Ralph integrates with:

- **Claude Code CLI**: Uses `bunx @anthropic/claude-code` as the execution engine
- **tmux**: Terminal multiplexer for integrated monitoring sessions
- **Git**: Expects projects to be git repositories
- **jq**: For JSON processing of status and exit signals
- **Standard Unix tools**: bash, grep, date, etc.

## Exit Conditions and Thresholds

Located in `ralph_loop.sh`:

- `MAX_CONSECUTIVE_TEST_LOOPS=3` - Exit if too many test-only iterations
- `MAX_CONSECUTIVE_DONE_SIGNALS=2` - Exit on repeated completion signals
- `TEST_PERCENTAGE_THRESHOLD=30%` - Flag if testing dominates recent loops
- Completion detection via @fix_plan.md checklist items

Located in `lib/circuit_breaker.sh`:

- `CB_NO_PROGRESS_THRESHOLD=3` - Open circuit after 3 loops with no progress
- `CB_SAME_ERROR_THRESHOLD=5` - Open circuit after 5 loops with same error
- `CB_OUTPUT_DECLINE_THRESHOLD=70` - Open circuit if output declines by >70%

## Important Behavioral Patterns

### Response Analysis Keywords

The system looks for specific patterns in Claude Code output:

**Completion Keywords**: "done", "complete", "finished", "all tasks complete", "project complete", "ready for review"

**Test-Only Patterns**: "bun test", "bats", "pytest", "jest", "cargo test", "go test", "running tests"

**Stuck Indicators**: "error", "failed", "cannot", "unable to", "blocked"

**No-Work Patterns**: "nothing to do", "no changes", "already implemented", "up to date"

### Circuit Breaker States

- **CLOSED**: Normal operation, Ralph continues looping
- **HALF_OPEN**: Monitoring mode, checking for recovery after issues
- **OPEN**: Execution halted due to detected problems (stagnation, repeated errors)

### State Files and Persistence

All state is stored in hidden JSON files in the project directory:

- `.call_count` - API call tracking for rate limiting
- `.last_reset` - Timestamp of last hourly reset
- `.circuit_breaker_state` - Current circuit breaker state and counters
- `.circuit_breaker_history` - Historical circuit breaker events
- `.exit_signals` - Exit detection signals and confidence scores
- `status.json` - Current loop status (loop number, timestamp, etc.)

## Debugging and Troubleshooting

### Common Issues

**Ralph exits too early**: Check exit detection thresholds, review logs for false completion signals

**Stuck in infinite loop**: Circuit breaker should catch this; check `.circuit_breaker_state` for OPEN status

**Rate limiting issues**: Check `.call_count` file and adjust `--calls` parameter

**tmux session issues**: Use `tmux list-sessions` to find sessions, `tmux attach -t <name>` to reconnect

### Log Files

- `logs/ralph.log` - Main execution log with timestamps
- `logs/loop_<N>.log` - Individual loop iteration logs
- Check recent logs: `tail -f logs/ralph.log`
- Search logs: `grep -i "error" logs/*.log`

### Manual State Reset

If state files become corrupted:

```bash
rm .call_count .last_reset .circuit_breaker_state .exit_signals status.json
# Ralph will recreate them on next run
```

## Feature Development Quality Standards

**CRITICAL**: All new features MUST meet the following mandatory requirements before being considered complete.

### Testing Requirements

- **Minimum Coverage**: 85% code coverage ratio required for all new code
- **Test Pass Rate**: 100% - all tests must pass, no exceptions
- **Test Types Required**:
  - Unit tests for bash script functions (if applicable)
  - Integration tests for Ralph loop behavior
  - End-to-end tests for full development cycles
- **Coverage Validation**: Run coverage reports before marking features complete:

  ```bash
  # For projects with test suites
  ./test.sh --coverage

  # Manual testing of Ralph loop
  ralph --monitor --calls 5
  ```

- **Test Quality**: Tests must validate behavior, not just achieve coverage metrics
- **Test Documentation**: Complex test scenarios must include comments explaining the test strategy

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
