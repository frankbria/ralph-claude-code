# Ralph for Codex

Autonomous AI development loop for Codex CLI with intelligent exit detection, rate limiting, and git worktree isolation.

## Features

- **Autonomous Development Loop** - Continuous development cycles with Codex
- **Intelligent Exit Detection** - Dual-condition exit gate (completion indicators + EXIT_SIGNAL)
- **Rate Limiting** - 100 API calls/hour (configurable) with automatic hourly reset
- **Circuit Breaker** - Prevents runaway loops with advanced error detection
- **Git Worktree Isolation** - Each loop iteration runs in isolated worktree
- **Quality Gates** - Automated testing before merge (lint, test, build)
- **Session Continuity** - Resume sessions with `--continue` flag
- **Live Monitoring** - Real-time output streaming with `--live` flag
- **tmux Integration** - Split-screen monitoring with `--monitor` flag

## Installation

```bash
cd ~/.ralph/codex
./install_codex.sh
```

This installs:
- `ralph-loop-codex` - Main autonomous loop
- `ralph-monitor-codex` - Live monitoring dashboard
- `ralph-setup-codex` - Create new Codex projects
- `ralph-enable-codex` - Enable Codex in existing projects
- `ralph-import-codex` - Import PRDs/specifications

## Quick Start

```bash
# Create a new project
ralph-setup-codex my-project
cd my-project

# Start autonomous loop with monitoring
rpx.hitl

# Or with specific configuration
rpx --calls 50 --timeout 30 --model gpt-4
```

## Configuration

Create `.ralphrc.codex` in your project root:

```bash
# API & Rate Limiting
MAX_CALLS_PER_HOUR=100
CODEX_TIMEOUT_MINUTES=30

# Model Selection
CODEX_MODEL="gpt-4"  # gpt-4, gpt-3.5, claude

# Permission Mode
CODEX_PERMISSION_MODE="dangerous"  # auto or dangerous

# Worktree Configuration
WORKTREE_ENABLED=true
WORKTREE_MERGE_STRATEGY="squash"  # squash, merge, rebase
WORKTREE_QUALITY_GATES="auto"     # auto, none, or "cmd1;cmd2"

# Auto-exit Control
CODEX_AUTO_EXIT=true  # true = -p flag (auto-exit), false = interactive

# Circuit Breaker
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false

# Session Management
CODEX_USE_CONTINUE=true
CODEX_SESSION_EXPIRY_HOURS=24

# Logging
VERBOSE_PROGRESS=false
```

## CLI Commands

### Basic Execution
```bash
rpx                    # Start loop
rpx.live              # With live output
rpx.monitor           # With tmux monitoring
rpx.hitl              # Live + monitor (human-in-the-loop)
```

### Session Management
```bash
rpx.continue          # Resume previous session
rpx.reset             # Reset session state
rpx.status            # Show current status
```

### Circuit Breaker
```bash
rpx.cb.reset          # Reset circuit breaker
rpx.cb.status         # Show circuit breaker status
rpx.cb.auto           # Auto-reset on startup
```

### Configuration Variants
```bash
rpx.fast              # 200 calls/hour
rpx.slow              # 50 calls/hour
rpx.test              # Single loop iteration
rpx.5                 # 5 loop iterations
rpx.10                # 10 loop iterations
```

### Model Selection
```bash
rpx.gpt4              # Use GPT-4
rpx.gpt35             # Use GPT-3.5
rpx.claude            # Use Claude
```

### Worktree Management
```bash
rpx.nowt              # Disable worktree
rpx.wt.squash         # Squash merge strategy
rpx.wt.merge          # Merge strategy
rpx.wt.rebase         # Rebase strategy
rpx.wt.nogate         # Disable quality gates
rpx.wt.interactive    # Interactive merge with cleanup prompt
```

### Combined Workflows
```bash
rpx.dev               # Development mode (live + monitor + verbose)
rpx.prod              # Production mode (50 calls + auto-reset + dangerous)
rpx.debug             # Debug mode (live + verbose + 1 loop)
```

## Git Worktree Isolation

Each loop iteration runs in an isolated git worktree:

1. **Create** - New worktree with branch `ralph-codex/loop-N-TIMESTAMP`
2. **Execute** - Codex works in isolated directory
3. **Quality Gates** - Run automated checks (lint, test, build)
4. **Merge Prompt** - Interactive confirmation before merge
5. **Merge** - Squash/merge/rebase into main branch
6. **Cleanup** - Delete worktree and branch

### Worktree Lifecycle

```bash
# Worktree created
/project-name-worktrees/loop-1-1234567890/

# After successful merge
- Changes merged to main
- Worktree deleted
- Branch deleted

# On failure
- Worktree preserved
- Branch preserved for debugging
```

### Quality Gates

**Auto mode** (default):
- Detects project type and runs appropriate checks
- TypeScript/JavaScript: `npm test`, `npm run lint`
- Python: `pytest`, `pylint`
- Rust: `cargo test`, `cargo clippy`
- Go: `go test`, `golangci-lint`

**Custom gates**:
```bash
rpx --quality-gates "npm test;npm run build;npm run e2e"
```

**Disable gates**:
```bash
rpx --quality-gates none
```

## Auto-Exit Control

Control whether Codex auto-exits after completing work:

```bash
# Auto-exit (default) - uses -p flag, Codex exits automatically
rpx --codex-auto-exit

# Interactive mode - Codex waits, cleanup prompt injected
rpx --no-codex-auto-exit
```

When `--no-codex-auto-exit` is used with worktree enabled, Ralph injects a cleanup prompt after the main task:

```
Task complete. Now perform git worktree cleanup:
1. Review all changes in the current worktree
2. Commit any uncommitted changes
3. Run quality checks
4. Merge into main branch (squash strategy)
5. Delete this worktree
6. Clean up stale worktrees
```

## Monitoring

### tmux Integration
```bash
rpx.monitor
```

Creates split-screen layout:
- **Left pane**: Ralph loop execution
- **Right pane**: Live monitoring dashboard

### Manual Monitoring
```bash
# Terminal 1: Start loop
rpx

# Terminal 2: Monitor
ralph-monitor-codex
```

## File Structure

```
project/
├── .ralph/
│   ├── PROMPT.md              # Main development instructions
│   ├── fix_plan.md           # Prioritized task list
│   ├── AGENT.md              # Build/run instructions
│   ├── status.json           # Real-time status
│   ├── progress.json         # Progress tracking
│   ├── live.log              # Live output
│   ├── logs/                 # Execution logs
│   │   └── loop_N.log
│   ├── .codex_session_id     # Session persistence
│   ├── .call_count           # Rate limiting
│   └── .circuit_breaker      # Circuit breaker state
├── .ralphrc.codex            # Codex configuration
└── project-name-worktrees/   # Worktree isolation
    └── loop-N-TIMESTAMP/
```

## Troubleshooting

### Codex CLI Not Found
```bash
# Install Codex CLI
# See: https://docs.codex.ai/

# Authenticate
codex auth login
```

### Circuit Breaker Tripped
```bash
# Check status
rpx.cb.status

# Reset if needed
rpx.cb.reset

# Or auto-reset on startup
rpx.cb.auto
```

### Session Issues
```bash
# Reset session
rpx.reset

# Check session expiry (default: 24 hours)
# Set in .ralphrc.codex:
CODEX_SESSION_EXPIRY_HOURS=48
```

### Worktree Cleanup
```bash
# List worktrees
git worktree list

# Remove stale worktrees
git worktree prune

# Force remove
git worktree remove path/to/worktree --force
```

## Advanced Usage

### Custom Prompt Files
```bash
rpx --prompt custom_prompt.md
```

### Beads Integration
```bash
# Sync tasks from beads
rpx  # Automatically syncs if beads is available
```

### GitHub Issues Integration
```bash
# Import from GitHub
ralph-import-codex --from github --label "sprint-1"
```

### PRD Import
```bash
# Import from PRD document
ralph-import-codex --from prd ./docs/requirements.md
```

## Uninstallation

```bash
cd ~/.ralph/codex
./uninstall_codex.sh
```

Removes:
- All installed commands
- Symlinks from `~/.local/bin`
- Configuration files (optional)

## Version

Ralph for Codex v0.1.0

## License

MIT License - See main Ralph repository for details
