# Ralph CLI Options Reference

Complete reference for all `ralph` command-line flags and `.ralphrc` configuration patterns.

> **Quick start**: Run `ralph --help` for a summary. This document covers every flag in depth with examples and common `.ralphrc` patterns.

---

## Core Flags

### `-h, --help`
Show the help message and exit.

```bash
ralph --help
```

---

### `-c, --calls NUM`
Maximum API calls per hour before rate-limiting kicks in.

| Default | `.ralphrc` key |
|---------|----------------|
| `100` | `MAX_CALLS_PER_HOUR` |

```bash
ralph --calls 50          # Conservative — slow, careful projects
ralph --calls 200         # Aggressive — large task backlog
```

> **Tip**: Set this low during initial project setup to avoid runaway loops while your `.ralph/PROMPT.md` is still being tuned.

---

### `-p, --prompt FILE`
Path to the prompt file that drives each loop iteration.

| Default | `.ralphrc` key |
|---------|----------------|
| `.ralph/PROMPT.md` | `PROMPT_FILE` |

```bash
ralph --prompt .ralph/PROMPT_experimental.md
```

---

### `-s, --status`
Print the current loop status from `.ralph/status.json` and exit. Does not start a loop.

```bash
ralph --status
```

---

### `-m, --monitor`
Launch an integrated tmux session with the loop in the left pane and the live monitor dashboard in the right pane. Requires `tmux`.

```bash
ralph --monitor
ralph --monitor --calls 50 --prompt my_prompt.md
```

> **Recommended for interactive use.** Gives a real-time view of loop progress, circuit breaker state, and API call counts without a separate terminal.

---

### `-v, --verbose`
Show detailed progress updates during execution (logged to stdout and the log file).

```bash
ralph --verbose
ralph --live --verbose    # Live streaming + verbose logging
```

---

### `-l, --live`
Stream Claude Code output in real time to the terminal. Automatically switches `--output-format` to `json` if it was set to `text`.

```bash
ralph --live
ralph --live --timeout 30
```

> **Note**: Live mode pipes output through a streaming pipeline. The output is verbose — consider `--monitor` for a cleaner view during long runs.

---

### `-t, --timeout MIN`
Maximum time (in minutes) to allow a single Claude Code invocation to run before it is terminated with exit code 124.

| Default | `.ralphrc` key |
|---------|----------------|
| `15` | `CLAUDE_TIMEOUT_MINUTES` |

```bash
ralph --timeout 5     # Fast tasks / tight feedback loop
ralph --timeout 60    # Long refactors or large codebases
```

When a timeout occurs, Ralph checks git for changes made during the run:
- **Files changed** → productive timeout: analysis runs, loop continues
- **No files changed** → idle timeout: counted as a failed iteration

---

## Circuit Breaker Flags

### `--reset-circuit`
Reset the circuit breaker to `CLOSED` (normal) state and exit. Use after resolving the underlying issue that tripped the breaker.

```bash
ralph --reset-circuit
```

---

### `--circuit-status`
Print the current circuit breaker state (`CLOSED`, `HALF_OPEN`, or `OPEN`) and exit.

```bash
ralph --circuit-status
```

---

### `--auto-reset-circuit`
Reset the circuit breaker to `CLOSED` on startup, bypassing the cooldown timer. Applied to a single run only; does not persist.

| `.ralphrc` key | Default |
|----------------|---------|
| `CB_AUTO_RESET` | `false` |

```bash
ralph --auto-reset-circuit    # One-off reset + run
```

> **When to use**: Fully unattended deployments (CI, cron jobs) where a human won't be around to run `--reset-circuit` manually. For interactive use, prefer `--reset-circuit` so you can inspect the cause first.

---

### `--reset-session`
Clear the saved Claude session ID and exit. Forces the next loop to start a fresh conversation without prior context.

```bash
ralph --reset-session
```

> Use when a session has drifted or Claude is stuck in an unproductive pattern. Session state lives in `.ralph/.claude_session_id`.

---

## Modern CLI Flags

### `--output-format FORMAT`
Set the output format for Claude Code responses.

| Value | Behaviour |
|-------|-----------|
| `json` (default) | Structured JSON — enables session continuity, exit signal detection, and token counting |
| `text` | Legacy plain text — heuristic-only exit detection, higher false-positive rate |

| Default | `.ralphrc` key |
|---------|----------------|
| `json` | `CLAUDE_OUTPUT_FORMAT` |

```bash
ralph --output-format json    # Default; recommended
ralph --output-format text    # Legacy fallback
```

> **JSON mode is strongly preferred.** In text mode, heuristic exit detection requires `confidence_score >= 70` AND `has_completion_signal=true` to prevent false-positive exits from documentation keywords. In JSON mode, heuristics are suppressed entirely — only an explicit `EXIT_SIGNAL: true` in a `RALPH_STATUS` block can trigger exit.

---

### `--allowed-tools TOOLS`
Comma-separated list of tools Claude is permitted to use. Overrides the `.ralphrc` default for this run.

| Default | `.ralphrc` key |
|---------|----------------|
| See below | `ALLOWED_TOOLS` |

**Default value:**
```
Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),
Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),
Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),
Bash(npm *),Bash(pytest)
```

```bash
# Restrict to read-only for an audit run
ralph --allowed-tools "Read,Grep,Glob"

# Allow all git commands (less safe — includes git clean, git rm)
ralph --allowed-tools "Write,Read,Edit,Bash(git *),Bash(npm *)"
```

> **Why specific git subcommands?** The default intentionally omits `Bash(git *)` to prevent `git clean`, `git rm`, and `git reset`, which could delete `.ralph/` configuration files. See [File Protection](../CLAUDE.md#file-protection-issue-149).

---

### `--no-continue`
Disable session continuity. Each loop iteration starts a completely fresh Claude conversation with no memory of previous iterations.

| Default | `.ralphrc` key |
|---------|----------------|
| continuity enabled | `SESSION_CONTINUITY=true` |

```bash
ralph --no-continue
```

> Use when a session has accumulated too much context and Claude is making decisions based on stale assumptions. Also useful for isolating a single iteration for debugging.

---

### `--session-expiry HOURS`
Override how many hours a session ID is kept before it is automatically discarded and a new session starts.

| Default | `.ralphrc` key |
|---------|----------------|
| `24` | `SESSION_EXPIRY_HOURS` |

```bash
ralph --session-expiry 48    # Long-running projects with stable context
ralph --session-expiry 4     # Short-lived tasks where fresh context is better
```

---

## Common `.ralphrc` Patterns

The `.ralphrc` file at your project root is sourced before each loop. Environment variables always take precedence over `.ralphrc` values.

### Local workstation (default)

```bash
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"
CLAUDE_AUTO_UPDATE=true
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24
```

---

### Docker container

```bash
# Version is pinned at image build time — skip npm registry check
CLAUDE_AUTO_UPDATE=false

# Containers are ephemeral — no point persisting sessions
SESSION_CONTINUITY=false

# Tighter timeout for predictable CI runtimes
CLAUDE_TIMEOUT_MINUTES=10
```

---

### Air-gapped / offline environment

```bash
# npm registry is unreachable — prevents timeout and warning spam
CLAUDE_AUTO_UPDATE=false

# Use a specific local Claude CLI path if not on PATH
CLAUDE_CODE_CMD="/opt/local/bin/claude"
```

---

### Unattended / cron operation

```bash
# Reduce call rate to avoid runaway spend overnight
MAX_CALLS_PER_HOUR=50

# Token budget per hour (0 = disabled). Blocks calls once budget is exhausted.
# Resets together with the call counter on the hour.
MAX_TOKENS_PER_HOUR=50000

# Longer timeout for batch work
CLAUDE_TIMEOUT_MINUTES=30

# Auto-recover from circuit breaker without human intervention
CB_AUTO_RESET=false           # false = use cooldown (safer)
CB_COOLDOWN_MINUTES=30        # Wait 30 min before retry after OPEN
```

---

### Circuit breaker tuning

```bash
# Open circuit after N loops with no file changes (default: 3)
CB_NO_PROGRESS_THRESHOLD=3

# Open circuit after N loops with the same error repeated (default: 5)
CB_SAME_ERROR_THRESHOLD=5

# Open circuit if output size declines by more than N% (default: 70)
CB_OUTPUT_DECLINE_THRESHOLD=70

# Minutes to wait in OPEN state before transitioning to HALF_OPEN (default: 30)
# Set to 0 for immediate retry
CB_COOLDOWN_MINUTES=30

# Skip cooldown and reset directly to CLOSED on startup (default: false)
# Use with care — reduces circuit breaker safety for unattended runs
CB_AUTO_RESET=false
```

---

### Restricting tool permissions

```bash
# Broad (development): all git subcommands allowed
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"

# Safe (default): specific git subcommands only, no destructive git commands
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git push *),Bash(npm *),Bash(pytest)"

# Read-only audit
ALLOWED_TOOLS="Read,Grep,Glob"
```

---

### Model and effort overrides

```bash
# Use a specific Claude model instead of the CLI default
CLAUDE_MODEL="claude-sonnet-4-6"

# Set effort level (high = more thorough, low = faster/cheaper)
CLAUDE_EFFORT="high"
```

Both can also be set as environment variables, which take precedence over `.ralphrc`:

```bash
CLAUDE_MODEL=claude-opus-4-6 ralph --monitor
```

---

### Custom shell initialization

```bash
# Source a script before each loop (e.g., to activate a virtualenv or set PATH)
RALPH_SHELL_INIT_FILE=".ralph/init.sh"
```

Ralph will warn if the file is set but missing, and skip sourcing if it doesn't exist.

---

## `.ralphrc`-Only Keys

These keys have no CLI flag equivalent — they can only be set in `.ralphrc` or as environment variables.

| Key | Default | Description |
|-----|---------|-------------|
| `CLAUDE_CODE_CMD` | `"claude"` | Claude Code CLI command. Override for non-global installs (e.g., `"npx @anthropic-ai/claude-code"`). |
| `CLAUDE_AUTO_UPDATE` | `true` | Auto-check npm registry and update the Claude CLI at startup. Set `false` for Docker/air-gapped environments. |
| `CLAUDE_MIN_VERSION` | `"2.0.76"` | Minimum Claude CLI version required. Ralph warns and exits if the installed version is older. |
| `MAX_TOKENS_PER_HOUR` | `0` | Hourly token budget (`input + output`). `0` = disabled. Blocks further calls once exhausted; resets with the call counter on the hour. |
| `RALPH_VERBOSE` | `false` | Enable verbose progress logging. Equivalent to running with `--verbose`. |
| `CB_NO_PROGRESS_THRESHOLD` | `3` | Open circuit breaker after N consecutive loops with no file changes. |
| `CB_SAME_ERROR_THRESHOLD` | `5` | Open circuit breaker after N consecutive loops with the same error. |
| `CB_OUTPUT_DECLINE_THRESHOLD` | `70` | Open circuit breaker if output size declines by more than N%. |
| `CB_COOLDOWN_MINUTES` | `30` | Minutes in OPEN state before transitioning to HALF_OPEN for recovery attempt. |
| `CB_AUTO_RESET` | `false` | Skip cooldown on startup and reset directly to CLOSED. Reduces safety; prefer for fully unattended CI runs. |
| `PROJECT_NAME` | `"my-project"` | Used in prompts and log output for identification. |
| `PROJECT_TYPE` | `"unknown"` | Project type hint: `javascript`, `typescript`, `python`, `rust`, `go`, `unknown`. |

---

## Environment Variable Precedence

```
Environment variable   ← highest priority
    ↓
.ralphrc value
    ↓
Ralph default          ← lowest priority
```

All `.ralphrc` keys can be set as environment variables using the same name:

```bash
MAX_CALLS_PER_HOUR=200 ralph --monitor   # Override just for this run
```
