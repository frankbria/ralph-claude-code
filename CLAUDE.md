# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Ralph for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

## Core Architecture

The system consists of four main bash scripts that work together:

1. **ralph_loop.sh** - The main autonomous loop that executes Claude Code repeatedly
2. **ralph_monitor.sh** - Live monitoring dashboard for tracking loop status
3. **setup.sh** - Project initialization script for new Ralph projects
4. **create_files.sh** - Bootstrap script that creates the entire Ralph system

## Key Commands

### Setting Up a New Project
```bash
# Create a new Ralph-managed project
./setup.sh my-project-name
cd my-project-name
```

### Running the Ralph Loop
```bash
# Start with integrated tmux monitoring (recommended)
../ralph_loop.sh --monitor

# Start without monitoring
../ralph_loop.sh

# With custom parameters and monitoring
../ralph_loop.sh --monitor --calls 50 --prompt my_custom_prompt.md

# Check current status
../ralph_loop.sh --status
```

### Monitoring
```bash
# Integrated tmux monitoring (recommended)
../ralph_loop.sh --monitor

# Manual monitoring in separate terminal
../ralph_monitor.sh

# tmux session management
tmux list-sessions
tmux attach -t <session-name>
```

### System Setup
```bash
# Bootstrap the entire Ralph system (run once)
./create_files.sh
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

## Integration Points

Ralph integrates with:
- **Claude Code CLI**: Uses `npx @anthropic/claude-code` as the execution engine
- **tmux**: Terminal multiplexer for integrated monitoring sessions
- **Git**: Expects projects to be git repositories
- **jq**: For JSON processing of status and exit signals
- **Standard Unix tools**: bash, grep, date, etc.

## Exit Conditions and Thresholds

- `MAX_CONSECUTIVE_TEST_LOOPS=3` - Exit if too many test-only iterations
- `MAX_CONSECUTIVE_DONE_SIGNALS=2` - Exit on repeated completion signals
- `TEST_PERCENTAGE_THRESHOLD=30%` - Flag if testing dominates recent loops
- Completion detection via @fix_plan.md checklist items