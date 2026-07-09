# Ralph for Claude Code

[![CI](https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml/badge.svg)](https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-0.11.5-blue)
![Tests](https://img.shields.io/badge/tests-784%20passing-green)
[![GitHub Issues](https://img.shields.io/github/issues/frankbria/ralph-claude-code)](https://github.com/frankbria/ralph-claude-code/issues)
[![Mentioned in Awesome Claude Code](https://awesome.re/mentioned-badge.svg)](https://github.com/hesreallyhim/awesome-claude-code)
[![Follow on X](https://img.shields.io/twitter/follow/FrankBria18044?style=social)](https://x.com/FrankBria18044)

> **Autonomous AI development loop with intelligent exit detection and rate limiting**

Ralph is an implementation of the Geoffrey Huntley's technique for Claude Code that enables continuous autonomous development cycles he named after [Ralph Wiggum](https://ghuntley.com/ralph/). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** - Ralph becomes a global command available in any directory.

## Project Status

**Version**: v0.11.5 - Active Development
**Core Features**: Working and tested
**Test Coverage**: 784 tests, 100% pass rate

### What's Working Now
- Autonomous development loops with intelligent exit detection
- **Dual-condition exit gate**: Requires BOTH completion indicators AND explicit EXIT_SIGNAL
- Rate limiting with hourly reset (100 calls/hour, configurable)
- Circuit breaker with advanced error detection (prevents runaway loops)
- Response analyzer with semantic understanding and two-stage error filtering
- **JSON output format support with automatic fallback to text parsing**
- **Session continuity with `--resume` flag for context preservation (no session hijacking)**
- **Session expiration with configurable timeout (default: 24 hours)**
- **Modern CLI flags: `--output-format`, `--allowed-tools`, `--no-continue`**
- **Interactive project enablement with `ralph-enable` wizard**
- **`.ralphrc` configuration file for project settings**
- **Live streaming output with `--live` flag for real-time Claude Code visibility**
- **Log rotation: `ralph.log` rotates at 10MB, keeping 4 archived files**
- **Dry-run mode (`--dry-run`) to simulate loops without API calls**
- **Metrics tracking with `ralph-stats` analytics command (JSON Lines per-loop metrics)**
- **Desktop notifications (`--notify`) for key loop events (macOS/Linux/terminal-bell)**
- **Automatic git backup branches (`--backup`) with `--rollback` restore**
- Multi-line error matching for accurate stuck loop detection
- 5-hour API limit handling with user prompts
- tmux integration for live monitoring
- PRD import functionality
- **GitHub issue import: `ralph-import --github-issue` plus metadata filters (labels, title, assignee, milestone, state) with first/interactive/priority selection and `--dry-run` preview**
- **CI/CD pipeline with GitHub Actions**
- **Dedicated uninstall script for clean removal**

### Recent Improvements

**v0.11.5 - Community Bug Fixes** (latest)
- Fixed API limit false positive: Timeout (exit code 124) no longer misidentified as API 5-hour limit (#183)
- Three-layer API limit detection: timeout guard → structural JSON (`rate_limit_event`) → filtered text fallback
- Unattended mode: API limit prompt now auto-waits on timeout instead of exiting
- Fixed bash 3.x compatibility: `${,,}` lowercase substitution replaced with POSIX `tr` (#187)
- Added 8 new tests for API limit detection (548 → 566 tests)

**v0.11.4 - Bug Fixes & Compatibility**
- Fixed progress detection: Git commits within a loop now count as progress (#141)
- Fixed checkbox regex: Date entries `[2026-01-29]` no longer counted as checkboxes (#144)
- Fixed session hijacking: Use `--resume <session_id>` instead of `--continue` (#151)
- Fixed EXIT_SIGNAL override: `STATUS: COMPLETE` with `EXIT_SIGNAL: false` now continues working (#146)
- Fixed ralph-import hanging indefinitely (added `--print` flag for non-interactive mode)
- Fixed ralph-import absolute path handling
- Fixed cross-platform date commands for macOS with Homebrew coreutils
- Added configurable circuit breaker thresholds via environment variables (#99)
- Added tmux support for non-zero `base-index` configurations
- Added 13 new regression tests for progress detection and checkbox regex

**v0.11.3 - Live Streaming & Beads Fix**
- Added live streaming output mode with `--live` flag for real-time Claude Code visibility (#125)
- Fixed beads task import using correct `bd list` arguments (#150)
- Applied CodeRabbit review fixes: camelCase variables, status-respecting fallback, jq guards
- Added 12 new tests for live streaming and beads import improvements

**v0.11.2 - Setup Permissions Fix**
- Fixed issue #136: `ralph-setup` now creates `.ralphrc` with consistent tool permissions
- Updated default `ALLOWED_TOOLS` to include `Edit`, `Bash(npm *)`, and `Bash(pytest)`
- Both `ralph-setup` and `ralph-enable` now create identical `.ralphrc` configurations
- Monitor now forwards all CLI parameters to inner ralph loop (#126)
- Added 16 new tests for permissions and parameter forwarding

**v0.11.1 - Completion Indicators Fix**
- Fixed premature exit after exactly 5 loops in JSON output mode
- `completion_indicators` now only accumulates when `EXIT_SIGNAL: true`
- Aligns with documented dual-condition exit gate behavior

**v0.11.0 - Ralph Enable Wizard**
- Added `ralph-enable` interactive wizard for enabling Ralph in existing projects
- 5-phase wizard: Environment Detection → Task Source Selection → Configuration → File Generation → Verification
- Auto-detects project type (TypeScript, Python, Rust, Go) and framework (Next.js, FastAPI, Django)
- Imports tasks from beads, GitHub Issues, or PRD documents
- Added `ralph-enable-ci` non-interactive version for CI/automation
- New library components: `enable_core.sh`, `wizard_utils.sh`, `task_sources.sh`

**v0.10.1 - Bug Fixes & Monitor Path Corrections**
- Fixed `ralph_monitor.sh` hardcoded paths for v0.10.0 compatibility
- Fixed EXIT_SIGNAL parsing in JSON format
- Added safety circuit breaker (force exit after 5 consecutive completion indicators)
- Fixed checkbox parsing for indented markdown

**v0.10.0 - .ralph/ Subfolder Structure (BREAKING CHANGE)**
- **Breaking**: Moved all Ralph-specific files to `.ralph/` subfolder
- Project root stays clean: only `src/`, `README.md`, and user files remain
- Added `ralph-migrate` command for upgrading existing projects

<details>
<summary>Earlier versions (v0.9.x)</summary>

**v0.9.9 - EXIT_SIGNAL Gate & Uninstall Script**
- Fixed premature exit bug: completion indicators now require Claude's explicit `EXIT_SIGNAL: true`
- Added dedicated `uninstall.sh` script for clean Ralph removal

**v0.9.8 - Modern CLI for PRD Import**
- Modernized `ralph_import.sh` to use Claude Code CLI JSON output format
- Enhanced error handling with structured JSON error messages

**v0.9.7 - Session Lifecycle Management**
- Complete session lifecycle management with automatic reset triggers
- Added `--reset-session` CLI flag for manual session reset

**v0.9.6 - JSON Output & Session Management**
- Extended `parse_json_response()` to support Claude Code CLI JSON format
- Added session management functions

**v0.9.5 - v0.9.0** - PRD import tests, project setup tests, installation tests, prompt file fix, modern CLI commands, circuit breaker enhancements

</details>

### In Progress
- Expanding test coverage
- [Automated badge updates](#138)
- [Multi-provider agent abstraction](docs/adr/0001-multi-provider-agent-abstraction.md) — decoupling Ralph from `claude` so any headless coding CLI (Codex, Gemini, OpenCode, Droid, Kilocode, Copilot) can drive the loop ([`multi-provider`](https://github.com/frankbria/ralph-claude-code/labels/multi-provider) epic; see also the [agent adapter contract](docs/adr/0002-agent-adapter-contract.md))

**Timeline to v1.0**: final polish underway | [Full roadmap](IMPLEMENTATION_PLAN.md) | **Contributions welcome!**

## Features

- **Autonomous Development Loop** - Continuously executes Claude Code with your project requirements
- **Intelligent Exit Detection** - Dual-condition check requiring BOTH completion indicators AND explicit EXIT_SIGNAL
- **Session Continuity** - Preserves context across loop iterations with automatic session management
- **Session Expiration** - Configurable timeout (default: 24 hours) with automatic session reset
- **Rate Limiting** - Built-in API call management with hourly limits and countdown timers
- **5-Hour API Limit Handling** - Three-layer detection (timeout guard, JSON parsing, filtered text) with auto-wait for unattended mode
- **Live Monitoring** - Real-time dashboard showing loop status, progress, and logs
- **Task Management** - Structured approach with prioritized task lists and progress tracking
- **Project Templates** - Quick setup for new projects with best-practice structure
- **Interactive Project Setup** - `ralph-enable` wizard for existing projects with task import
- **Configuration Files** - `.ralphrc` for project-specific settings and tool permissions
- **Comprehensive Logging** - Detailed execution logs with timestamps and status tracking
- **Configurable Timeouts** - Set execution timeout for Claude Code operations (1-120 minutes)
- **Verbose Progress Mode** - Optional detailed progress updates during execution
- **Response Analyzer** - AI-powered analysis of Claude Code responses with semantic understanding
- **Circuit Breaker** - Advanced error detection with two-stage filtering, multi-line error matching, and automatic recovery
- **CI/CD Integration** - GitHub Actions workflow with automated testing
- **Clean Uninstall** - Dedicated uninstall script for complete removal
- **Live Streaming Output** - Real-time visibility into Claude Code execution with `--live` flag
- **Docker Sandbox Execution** - Run Claude Code in an isolated container with `--sandbox docker` (resource limits, network policy, secure credential handoff)
- **E2B Cloud Sandbox Execution** - Run Claude Code in an E2B cloud sandbox with `--sandbox e2b` (file sync, session recovery, cost tracking with `--sandbox-max-cost`)

## Quick Start

Ralph has two phases: **one-time installation** and **per-project setup**.

```
INSTALL ONCE              USE MANY TIMES
+-----------------+          +----------------------+
| ./install.sh    |    ->    | ralph-setup project1 |
|                 |          | ralph-enable         |
| Adds global     |          | ralph-import prd.md  |
| commands        |          | ...                  |
+-----------------+          +----------------------+
```

### Phase 1: Install Ralph (One Time Only)

Install Ralph globally on your system:

```bash
git clone https://github.com/frankbria/ralph-claude-code.git
cd ralph-claude-code
./install.sh
```

This adds `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-queue`, `ralph-migrate`, `ralph-enable`, and `ralph-enable-ci` commands to your PATH.

> **Note**: You only need to do this once per system. After installation, you can delete the cloned repository if desired.

### Phase 2: Initialize Projects (Per Project)

#### Option A: Enable Ralph in Existing Project (Recommended)
```bash
cd my-existing-project

# Interactive wizard - auto-detects project type and imports tasks
ralph-enable

# Or with specific task source
ralph-enable --from beads
ralph-enable --from github --label "sprint-1"
ralph-enable --from prd ./docs/requirements.md

# Start autonomous development
ralph --monitor
```

#### Option B: Import Existing PRD/Specifications
```bash
# Convert existing PRD/specs to Ralph format
ralph-import my-requirements.md my-project
cd my-project

# Review and adjust the generated files:
# - .ralph/PROMPT.md (Ralph instructions)
# - .ralph/fix_plan.md (task priorities)
# - .ralph/specs/requirements.md (technical specs)

# Start autonomous development
ralph --monitor
```

#### Option C: Create New Project from Scratch
```bash
# Create blank Ralph project
ralph-setup my-awesome-project
cd my-awesome-project

# Configure your project requirements manually
# Edit .ralph/PROMPT.md with your project goals
# Edit .ralph/specs/ with detailed specifications
# Edit .ralph/fix_plan.md with initial priorities

# Start autonomous development
ralph --monitor
```

### Ongoing Usage (After Setup)

Once Ralph is installed and your project is initialized:

```bash
# Navigate to any Ralph project and run:
ralph --monitor              # Integrated tmux monitoring (recommended)

# Or use separate terminals:
ralph                        # Terminal 1: Ralph loop
ralph-monitor               # Terminal 2: Live monitor dashboard
```

### Uninstalling Ralph

To completely remove Ralph from your system:

```bash
# Run the uninstall script
./uninstall.sh

# Or if you deleted the repo, download and run:
curl -sL https://raw.githubusercontent.com/frankbria/ralph-claude-code/main/uninstall.sh | bash
```

## Understanding Ralph Files

After running `ralph-enable` or `ralph-import`, you'll have a `.ralph/` directory with several files. Here's what each file does and whether you need to edit it:

| File | Auto-Generated? | You Should... |
|------|-----------------|---------------|
| `.ralph/PROMPT.md` | Yes (smart defaults) | **Review & customize** project goals and principles |
| `.ralph/fix_plan.md` | Yes (can import tasks) | **Add/modify** specific implementation tasks |
| `.ralph/AGENT.md` | Yes (detects build commands) | Rarely edit (auto-maintained by Ralph) |
| `.ralph/specs/` | Empty directory | Add files when PROMPT.md isn't detailed enough |
| `.ralph/specs/stdlib/` | Empty directory | Add reusable patterns and conventions |
| `.ralphrc` | Yes (project-aware) | Rarely edit (sensible defaults) |

### Key File Relationships

```
PROMPT.md (high-level goals)
    ↓
specs/ (detailed requirements when needed)
    ↓
fix_plan.md (specific tasks Ralph executes)
    ↓
AGENT.md (build/test commands - auto-maintained)
```

### When to Use specs/

- **Simple projects**: PROMPT.md + fix_plan.md is usually enough
- **Complex features**: Add specs/feature-name.md for detailed requirements
- **Team conventions**: Add specs/stdlib/convention-name.md for reusable patterns

See the [User Guide](docs/user-guide/) for detailed explanations and the [examples/](examples/) directory for realistic project configurations.

## How It Works

Ralph operates on a simple but powerful cycle:

1. **Read Instructions** - Loads `PROMPT.md` with your project requirements
2. **Execute Claude Code** - Runs Claude Code with current context and priorities
3. **Track Progress** - Updates task lists and logs execution results
4. **Evaluate Completion** - Checks for exit conditions and project completion signals
5. **Repeat** - Continues until project is complete or limits are reached

### Intelligent Exit Detection

Ralph uses a **dual-condition check** to prevent premature exits during productive iterations:

**Exit requires BOTH conditions:**
1. `completion_indicators >= 2` (heuristic detection from natural language patterns)
2. Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block

**Example behavior:**
```
Loop 5: Claude outputs "Phase complete, moving to next feature"
        → completion_indicators: 3 (high confidence from patterns)
        → EXIT_SIGNAL: false (Claude says more work needed)
        → Result: CONTINUE (respects Claude's explicit intent)

Loop 8: Claude outputs "All tasks complete, project ready"
        → completion_indicators: 4
        → EXIT_SIGNAL: true (Claude confirms done)
        → Result: EXIT with "project_complete"
```

**Other exit conditions:**
- All tasks in `.ralph/fix_plan.md` marked complete — except unchecked items under **optional sections**
- Multiple consecutive "done" signals from Claude Code
- Too many test-focused loops (indicating feature completeness)
- Claude API 5-hour usage limit reached (with user prompt to wait or exit)

#### Optional / Future sections in fix_plan.md

By default, Ralph keeps looping until **every** `- [ ]` item is checked. To mark work as
genuinely optional so it does not block completion, put it under an optional section:

```markdown
## High Priority
- [x] Core feature

## Optional
- [ ] Frontend integration   # does NOT block exit
- [ ] SMS notifications      # does NOT block exit
```

Unchecked items under `Optional`, `Future`, `Future Enhancements`, or `Nice to Have` headings
(and their subsections) are ignored by the completion check. Customize the section names with
`OPTIONAL_SECTIONS` in `.ralphrc` (comma-separated, case-insensitive). This resolves the
deadlock where Claude treats low-priority items as skippable while Ralph waits for them.

## Enabling Ralph in Existing Projects

The `ralph-enable` command provides an interactive wizard for adding Ralph to existing projects:

```bash
cd my-existing-project
ralph-enable
```

**The wizard:**
1. **Detects Environment** - Identifies project type (TypeScript, Python, etc.) and framework
2. **Selects Task Sources** - Choose from beads, GitHub Issues, or PRD documents
3. **Configures Settings** - Set tool permissions and loop parameters
4. **Generates Files** - Creates `.ralph/` directory and `.ralphrc` configuration
5. **Verifies Setup** - Confirms all files are created correctly

**Non-interactive mode for CI/automation:**
```bash
ralph-enable-ci                              # Sensible defaults
ralph-enable-ci --from github               # Import from GitHub Issues
ralph-enable-ci --project-type typescript   # Override detection
ralph-enable-ci --json                      # Machine-readable output
```

## Importing Existing Requirements

Ralph can convert existing PRDs, specifications, or requirement documents into the proper Ralph format using Claude Code.

### Supported Formats
- **Markdown** (.md) - Product requirements, technical specs
- **Text files** (.txt) - Plain text requirements
- **JSON** (.json) - Structured requirement data
- **Word documents** (.docx) - Business requirements
- **PDFs** (.pdf) - Design documents, specifications
- **Any text-based format** - Ralph will intelligently parse the content

### Usage Examples

```bash
# Convert a markdown PRD
ralph-import product-requirements.md my-app

# Convert a text specification
ralph-import requirements.txt webapp

# Convert a JSON API spec
ralph-import api-spec.json backend-service

# Let Ralph auto-name the project from filename
ralph-import design-doc.pdf
```

### What Gets Generated

Ralph-import creates a complete project with:

- **.ralph/PROMPT.md** - Converted into Ralph development instructions
- **.ralph/fix_plan.md** - Requirements broken down into prioritized tasks
- **.ralph/specs/requirements.md** - Technical specifications extracted from your document
- **.ralphrc** - Project configuration file with tool permissions
- **Standard Ralph structure** - All necessary directories and template files in `.ralph/`

The conversion is intelligent and preserves your original requirements while making them actionable for autonomous development.

## Importing from GitHub Issues

Ralph can also import a development plan directly from a GitHub issue. The issue body and discussion comments are converted into the same Ralph format as a local PRD.

### Prerequisites
- GitHub CLI (`gh`) installed: `brew install gh` or `sudo apt install gh` (see https://cli.github.com)
- Authenticated: `gh auth login`
- `jq` installed (used to parse issue JSON)

### Usage Examples

```bash
# Import a specific issue by number
ralph-import --github-issue 42

# Import the oldest open issue matching a search
ralph-import --github-search "fix login timeout"

# Import the oldest open issue with a label
ralph-import --github-label "sprint-1"

# Fetch from a specific repository (default: repo of the current directory)
ralph-import --github-issue 42 --repo myorg/myrepo

# Override the auto-generated project name (slug of the issue title)
ralph-import --github-issue 42 my-project

# Also import issue comments (e.g. when a plan was posted as a comment)
ralph-import --github-issue 42 --include-comments
```

The issue title becomes the project name (slugified, e.g. `Add User Login` → `add-user-login`) and the issue body becomes the PRD content. `--github-issue` addresses an exact issue and cannot be combined with the filter flags below.

### Filtering and Selecting Issues by Metadata

Instead of an exact issue number, issues can be queried by metadata. Filter flags are freely combinable; matches are sorted oldest-first.

```bash
# Issues carrying ALL listed labels (comma = AND)
ralph-import --github-label "bug,P0"

# High-priority bugs assigned to me
ralph-import --github-label "bug,P0" --github-assignee @me

# Unassigned issues with a label, skipping anything marked wontfix
ralph-import --github-label "good-first-issue" --github-assignee none --exclude-label wontfix

# Title pattern: * matches anything, everything else is literal (case-insensitive)
ralph-import --github-title "[P0]*"

# Milestone, including closed issues
ralph-import --github-milestone "v1.0" --github-state all
```

When several issues match, `--select` picks the winner:

```bash
ralph-import --github-label bug --select first        # oldest issue (default)
ralph-import --github-label bug --select interactive  # numbered menu to choose from
ralph-import --github-label bug --select priority     # highest-priority label
```

The `priority` strategy understands both bare `P0`–`P9` labels and the `priority: P0` form; ties go to the oldest issue, and issues without priority labels fall back to the oldest match. Non-interactive sessions using `--select interactive` fall back to the oldest match with a warning instead of blocking.

`--dry-run` previews the matches and what would be selected without importing anything:

```bash
ralph-import --github-label bug --dry-run
```

> **Security note**: issue comments are **excluded by default** — on public repositories anyone can comment, and comment text flows into the AI conversion prompt. Pass `--include-comments` only when you trust the discussion (e.g. plans posted by maintainers).

### Completeness Assessment and Plan Generation

GitHub issues vary widely in detail. During import, Ralph scores the issue 0–100 for implementation readiness (acceptance criteria, task checklists, code examples, section structure, guidance keywords, length). Issues scoring below the threshold (default: 60) get an implementation plan generated by Claude Code before conversion — the plan is folded into the generated `fix_plan.md` tasks and preserved verbatim at `.ralph/specs/implementation-plan.md`.

```bash
# Default: assess the issue, generate a plan only if it lacks detail
ralph-import --github-issue 42

# Always generate a plan, with a specific model
ralph-import --github-issue 42 --generate-plan --plan-model opus

# Never generate a plan (fails if the issue scores below the threshold)
ralph-import --github-issue 42 --no-generate-plan

# Tune the threshold and skip the approval prompt (automation/CI)
ralph-import --github-issue 42 --completeness-threshold 75 --auto-approve
```

Generated plans are shown for approval before conversion. Non-interactive sessions (and `--auto-approve`) accept the plan automatically, so unattended imports never block on a prompt.

### Troubleshooting
- **"GitHub CLI (gh) is not installed"** — install it from https://cli.github.com
- **"GitHub CLI is not authenticated"** — run `gh auth login`

## GitHub Issue Lifecycle

Once development is underway, Ralph can close the loop on the whole GitHub workflow. Pass
`--github-issue <ref>` (a number `69`, `#69`, `owner/repo#69`, or a full issue URL) to `ralph`
and opt into any of the lifecycle actions below. They all use the `gh` CLI (so the same
`gh auth login` prerequisite applies), and every GitHub operation degrades gracefully — if a
call is denied, Ralph logs a warning and keeps developing rather than crashing the loop.

```bash
# Post a progress comment to the issue every 5 loops while developing
ralph --github-issue 69 --comment-progress --comment-interval 5

# On completion: open a PR linked to the issue, comment a summary, and close it
ralph --github-issue 69 --create-pr --link-issue --close-summary --auto-close

# Add labels when closing, and open a follow-up issue for any TODO/FIXME left in the diff
ralph --github-issue 69 --auto-close --add-label completed \
      --create-followups --followup-label tech-debt

# Open the PR as a draft for manual review before merge
ralph --github-issue 69 --create-pr --draft-pr
```

| Flag | Effect |
|------|--------|
| `--github-issue REF` | Track the issue (required for all lifecycle features) |
| `--comment-progress` | Post progress comments during development |
| `--comment-interval N` | Comment every N loops (default: 5) |
| `--auto-close` | Close the issue on graceful completion |
| `--close-summary` | Post a completion summary comment |
| `--create-pr` | Create a pull request on completion |
| `--link-issue` | Add `Closes #N` to the PR body |
| `--draft-pr` | Create the PR as a draft |
| `--create-followups` | Open a grouped follow-up issue for TODO/FIXME markers added during dev |
| `--followup-label LABEL` | Label for follow-up issues (default: `tech-debt`) |
| `--add-label LABEL` | Label to add on close (repeatable) |

These can also be set in `.ralphrc` (`COMMENT_PROGRESS`, `AUTO_CLOSE`, `CREATE_PR`, etc.).
Lifecycle state is tracked in `.ralph/.github_lifecycle_state`.

## Batch Processing and Issue Queue

For larger efforts, the `ralph-queue` command builds a persistent queue of work items (GitHub issues or local PRD specs) and processes them sequentially, respecting priority and dependencies. The queue is stored at `.ralph/queue.json` and survives restarts, so an interrupted run can be resumed. See [docs/QUEUE_MANAGEMENT.md](docs/QUEUE_MANAGEMENT.md) for the full guide.

### Building a queue

```bash
# Queue issues by metadata filter (reuses the import filter flags)
ralph-queue add --github-label "bug,P0"
ralph-queue add --github-milestone "v1.0"

# Queue specific issues by number
ralph-queue add --github-issues 69,70,71

# Queue a local PRD/spec file
ralph-queue add --prd ./docs/feature.md
```

When a GitHub issue is queued, its priority is read from `P0`–`P9` / `priority: PN` labels and its dependencies are parsed from the body (`depends on #N`, `blocked by #N`, `requires #N`).

### Managing the queue

```bash
ralph-queue status            # Show the queue (counts + items); --json for machine output
ralph-queue next              # Print the id of the next ready item
ralph-queue reorder           # Sort the queue by priority (P0 first)
ralph-queue validate          # Check for circular dependencies
ralph-queue remove 69         # Remove an item by issue number or id
ralph-queue clear             # Empty the queue
```

These are also available through `ralph` itself: `ralph --queue-status`, `ralph --queue-next`, `ralph --queue-clear`, and `ralph --queue-remove <id|N>`.

### Processing the queue

```bash
# Process all ready pending items in priority/dependency order
ralph --process-queue
ralph-queue process

# Stop at the first failure instead of skipping it
ralph --process-queue --halt-on-failure

# Resume after an interruption (only pending items are picked up)
ralph --resume-queue
```

For each ready item the processor stages the project from the issue/spec, runs the Ralph loop, commits the work as `Fix #N: <title>` (one commit per issue when in a git repo), then advances. Failed items are marked `failed` and skipped by default (or halt the run with `--halt-on-failure`); items whose dependencies never complete remain `pending`. Progress is written to `.ralph/logs/queue_processing.log` and shown in the `ralph-monitor` dashboard.

Concurrent (parallel) processing is intentionally out of scope — items are processed one at a time on a single branch.
- **"Could not fetch issue #N"** — check the issue number, your repo access, and the `--repo` value
- **"No issues match the specified filters"** — relax or remove some filters; only open issues are matched unless `--github-state closed|all` is given. `--dry-run` shows what a filter set matches.

## Docker Sandbox Execution

Run Claude Code inside an isolated Docker container instead of directly on your machine (Issue #74). Ralph's loop, rate limiting, and monitoring stay on the host; only Claude's execution — the part that edits files and runs commands autonomously — is containerized. The project directory is bind-mounted read-write at `/workspace`, so changes land on the host directly and `ralph-monitor` works unchanged.

### Setup

```bash
# One time: pull the official image (published on release tags)...
docker pull ghcr.io/frankbria/ralph-sandbox:latest
docker tag ghcr.io/frankbria/ralph-sandbox:latest ralph-sandbox:latest

# ...or build it yourself (from a source checkout, or ~/.ralph after install)
docker build -t ralph-sandbox .
```

### Usage

```bash
ralph --sandbox docker                          # Default image, 4g RAM, 2 CPUs, bridge network
ralph --sandbox docker --sandbox-image node:20  # Any image with `claude` on PATH
ralph --sandbox docker --sandbox-memory 8g --sandbox-cpus 4
ralph --sandbox docker --sandbox-network none   # Full network isolation (blocks the Claude API —
                                                # only for images with their own auth/proxy setup)
ralph --monitor --sandbox docker                # Works with tmux monitoring
```

Equivalent `.ralphrc` settings: `SANDBOX_PROVIDER`, `SANDBOX_DOCKER_IMAGE`, `SANDBOX_DOCKER_MEMORY`, `SANDBOX_DOCKER_CPUS`, `SANDBOX_DOCKER_NETWORK` (CLI flags override).

### How credentials reach the container

- `ANTHROPIC_API_KEY` set → handed off via a `0600` env-file passed to `docker run --env-file` (never logged)
- Otherwise, your `~/.claude/.credentials.json` is **copied** into a container-scoped directory mounted as the container's home — the container never touches your real `~/.claude`
- Both are removed by the automatic cleanup on exit (including Ctrl+C)

A persistent container serves all loop iterations (Claude session state survives between loops); it is stopped and removed when the loop exits. If sandbox setup fails, Ralph refuses to fall back to host execution. See [docs/DOCKER_SANDBOX.md](docs/DOCKER_SANDBOX.md) for details.

## E2B Cloud Sandbox Execution

Run Claude Code inside an [E2B](https://e2b.dev) cloud sandbox instead of on your machine (Issue #75). Like the Docker provider, Ralph's loop, rate limiting, and monitoring stay host-side — but since the cloud has no bind mount, the project is uploaded once at startup and changed files are downloaded back after every iteration.

### Setup

```bash
pip install e2b                       # official E2B Python SDK (the transport)
export E2B_API_KEY="e2b_..."          # or: store in ~/.ralph/e2b_api_key (chmod 600)
```

### Usage

```bash
ralph --sandbox e2b                                   # base template; claude CLI auto-bootstrapped
ralph --sandbox e2b --sandbox-template my-template    # custom template with claude preinstalled
ralph --sandbox e2b --sandbox-timeout 7200            # 2h session timeout (expired sandboxes auto-recreate)
ralph --sandbox e2b --sandbox-max-cost 5.00 --sandbox-cost-alert 2.00   # budget controls
ralph --sandbox e2b --sandbox-keep-alive              # leave it running; reuse with --sandbox-id <id>
ralph --monitor --sandbox e2b                         # works with tmux monitoring (cost shown in the dashboard)

# Sync filtering (Issue #76): control what uploads/downloads
ralph --sandbox e2b --sync-include "src/**,tests/**,*.md" --sync-exclude "*.log,node_modules"
```

Equivalent `.ralphrc` settings: `SANDBOX_E2B_TEMPLATE`, `SANDBOX_E2B_TIMEOUT`, `SANDBOX_E2B_KEEP_ALIVE`, `SANDBOX_E2B_MAX_COST`, `SANDBOX_E2B_COST_ALERT`, `SANDBOX_E2B_COST_PER_HOUR` (CLI flags override; the API key itself never goes in `.ralphrc`).

Claude auth reaches the sandbox via `ANTHROPIC_API_KEY` (passed as a sandbox env var) or a copy of your host `~/.claude/.credentials.json`. Cost is estimated as cumulative runtime × `SANDBOX_E2B_COST_PER_HOUR` (cost accrues across sandbox replacements, so `--sandbox-max-cost` spans the whole run) and surfaced in `status.json`, the monitor, and `.ralph/logs/e2b_cost.log`. File sync includes deletion propagation — files removed or renamed in the sandbox are deleted from the host after each iteration. What syncs is filterable: `--sync-include`/`--sync-exclude` patterns, a `.ralphignore` file (gitignore-like subset), and a large-file policy (`SYNC_MAX_FILE_SIZE`/`SYNC_LARGE_FILE_ACTION`); upload and download log file-count + size summaries. Note: commits made *inside* the sandbox are not synced back — changes arrive as uncommitted modifications on the host (`.git` is excluded from sync in both directions). Docker and E2B are the supported providers; additional providers (Daytona, Cloudflare) are not planned (#79, #80). See [docs/E2B_SANDBOX.md](docs/E2B_SANDBOX.md) and [docs/SANDBOX_SYNC.md](docs/SANDBOX_SYNC.md) for details.

## Configuration

### Project Configuration (.ralphrc)

Each Ralph project can have a `.ralphrc` configuration file:

```bash
# .ralphrc - Ralph project configuration
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"

# Claude Code CLI command (auto-detected, override if needed)
CLAUDE_CODE_CMD="claude"
# CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"  # Alternative: use npx

# Optional Anthropic-compatible API base URL override
# CLAUDE_ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic/v1"

# Shell init file — source before running claude (useful for zsh/fish users
# whose PATH or env vars are only set in their shell's init file)
#RALPH_SHELL_INIT_FILE="~/.zshrc"

# Loop settings
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"
# Token budget per hour (0 = disabled). One Claude call can use 100k+ tokens.
#MAX_TOKENS_PER_HOUR=500000

# Tool permissions
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"

# Session management
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

# Circuit breaker thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
```

### Rate Limiting & Circuit Breaker

Ralph includes intelligent rate limiting and circuit breaker functionality:

```bash
# Default: 100 calls per hour
ralph --calls 50

# With integrated monitoring
ralph --monitor --calls 50

# Check current usage (shows calls and tokens used this hour)
ralph --status
```

Rate limiting supports two independent limits — both reset hourly:

| Setting | Default | Description |
|---------|---------|-------------|
| `MAX_CALLS_PER_HOUR` | `100` | Max Claude invocations per hour |
| `MAX_TOKENS_PER_HOUR` | `0` (disabled) | Max cumulative tokens per hour |

Token tracking extracts `input_tokens + output_tokens` from each Claude response. A single call can consume 100k+ tokens, so `MAX_TOKENS_PER_HOUR` provides cost control that `MAX_CALLS_PER_HOUR` alone cannot.

The circuit breaker automatically:
- Detects API errors and rate limit issues with advanced two-stage filtering
- Opens circuit after 3 loops with no progress or 5 loops with same errors
- Eliminates false positives from JSON fields containing "error"
- Accurately detects stuck loops with multi-line error matching
- Gradually recovers with half-open monitoring state
- **Auto-recovers** after cooldown period (default: 30 minutes) — OPEN → HALF_OPEN → CLOSED
- Provides detailed error tracking and logging with state history

**Auto-recovery options:**
```bash
# Default: 30-minute cooldown before auto-recovery attempt
CB_COOLDOWN_MINUTES=30     # Set in .ralphrc (0 = immediate)

# Auto-reset on startup (for fully unattended operation)
ralph --auto-reset-circuit
# Or set in .ralphrc: CB_AUTO_RESET=true
```

### Claude API 5-Hour Limit

When Claude's 5-hour usage limit is reached, Ralph:
1. Detects the limit using three-layer verification (timeout guard → structural JSON → filtered text fallback)
2. Prompts you to choose:
   - **Option 1**: Wait 60 minutes for the limit to reset (with countdown timer)
   - **Option 2**: Exit gracefully
3. **Unattended mode**: Auto-waits on prompt timeout (30s) instead of exiting
4. Prevents false positives from echoed file content mentioning "5-hour limit"

### Custom Prompts

```bash
# Use custom prompt file
ralph --prompt my_custom_instructions.md

# With integrated monitoring
ralph --monitor --prompt my_custom_instructions.md
```

### Execution Timeouts

```bash
# Set Claude Code execution timeout (default: 15 minutes)
ralph --timeout 30  # 30-minute timeout for complex tasks

# With monitoring and custom timeout
ralph --monitor --timeout 60  # 60-minute timeout

# Short timeout for quick iterations
ralph --verbose --timeout 5  # 5-minute timeout with progress
```

### Verbose Mode

```bash
# Enable detailed progress updates during execution
ralph --verbose

# Combine with other options
ralph --monitor --verbose --timeout 30
```

### Live Streaming Output

```bash
# Enable real-time visibility into Claude Code execution
ralph --live

# Combine with monitoring for best experience
ralph --monitor --live

# Live output is written to .ralph/live.log
tail -f .ralph/live.log  # Watch in another terminal
```

Live streaming mode shows Claude Code's output in real-time as it works, providing visibility into what's happening during each loop iteration.

### Session Continuity

Ralph maintains session context across loop iterations for improved coherence:

```bash
# Sessions are enabled by default with --continue flag
ralph --monitor                 # Uses session continuity

# Start fresh without session context
ralph --no-continue             # Isolated iterations

# Reset session manually (clears context)
ralph --reset-session           # Clears current session

# Check session status
cat .ralph/.ralph_session              # View current session file
cat .ralph/.ralph_session_history      # View session transition history
```

**Session Auto-Reset Triggers:**
- Circuit breaker opens (stagnation detected)
- Manual interrupt (Ctrl+C / SIGINT)
- Project completion (graceful exit)
- Manual circuit breaker reset (`--reset-circuit`)
- Session expiration (default: 24 hours)

Sessions are persisted to `.ralph/.ralph_session` with a configurable expiration (default: 24 hours). The last 50 session transitions are logged to `.ralph/.ralph_session_history` for debugging.

### Exit Thresholds

Modify these variables in `~/.ralph/ralph_loop.sh`:

**Exit Detection Thresholds:**
```bash
MAX_CONSECUTIVE_TEST_LOOPS=3     # Exit after 3 test-only loops
MAX_CONSECUTIVE_DONE_SIGNALS=2   # Exit after 2 "done" signals
TEST_PERCENTAGE_THRESHOLD=30     # Flag if 30%+ loops are test-only
```

**Circuit Breaker Thresholds:**
```bash
CB_NO_PROGRESS_THRESHOLD=3       # Open circuit after 3 loops with no file changes
CB_SAME_ERROR_THRESHOLD=5        # Open circuit after 5 loops with repeated errors
CB_OUTPUT_DECLINE_THRESHOLD=70   # Open circuit if output declines by >70%
CB_COOLDOWN_MINUTES=30           # Minutes before OPEN → HALF_OPEN auto-recovery
CB_AUTO_RESET=false              # true = reset to CLOSED on startup (bypasses cooldown)
```

**Completion Indicators with EXIT_SIGNAL Gate:**

| completion_indicators | EXIT_SIGNAL | Result |
|-----------------------|-------------|--------|
| >= 2 | `true` | **Exit** ("project_complete") |
| >= 2 | `false` | **Continue** (Claude still working) |
| >= 2 | missing | **Continue** (defaults to false) |
| < 2 | `true` | **Continue** (threshold not met) |

## Project Structure

Ralph creates a standardized structure for each project with a `.ralph/` subfolder for configuration:

```
my-project/
├── .ralph/                 # Ralph configuration and state (hidden folder)
│   ├── PROMPT.md           # Main development instructions for Ralph
│   ├── fix_plan.md        # Prioritized task list
│   ├── AGENT.md           # Build and run instructions
│   ├── specs/              # Project specifications and requirements
│   │   └── stdlib/         # Standard library specifications
│   ├── examples/           # Usage examples and test cases
│   ├── logs/               # Ralph execution logs
│   └── docs/generated/     # Auto-generated documentation
├── .ralphrc                # Ralph configuration file (tool permissions, settings)
└── src/                    # Source code implementation (at project root)
```

> **Migration**: If you have existing Ralph projects using the old flat structure, run `ralph-migrate` to automatically move files to the `.ralph/` subfolder.

## Best Practices

### Writing Effective Prompts

1. **Be Specific** - Clear requirements lead to better results
2. **Prioritize** - Use `.ralph/fix_plan.md` to guide Ralph's focus
3. **Set Boundaries** - Define what's in/out of scope
4. **Include Examples** - Show expected inputs/outputs

### Project Specifications

- Place detailed requirements in `.ralph/specs/`
- Use `.ralph/fix_plan.md` for prioritized task tracking
- Keep `.ralph/AGENT.md` updated with build instructions
- Document key decisions and architecture

### Monitoring Progress

- Use `ralph-monitor` for live status updates
- Check logs in `.ralph/logs/` for detailed execution history
- Monitor `.ralph/status.json` for programmatic access
- Watch for exit condition signals

## System Requirements

- **Bash 4.0+** - For script execution
- **Claude Code CLI** - `npm install -g @anthropic-ai/claude-code` (or use npx — set `CLAUDE_CODE_CMD` in `.ralphrc`)
- **tmux** - Terminal multiplexer for integrated monitoring (recommended)
- **jq** - JSON processing for status tracking
- **Git** - Version control (projects are initialized as git repos)
- **GNU coreutils** - For the `timeout` command (execution timeouts)
  - Linux: Pre-installed on most distributions
  - macOS: Install via `brew install coreutils` (provides `gtimeout`)
- **Standard Unix tools** - grep, date, etc.

### Testing Requirements (Development)

See [TESTING.md](TESTING.md) for the comprehensive testing guide.

If you want to run the test suite:

```bash
# Install BATS testing framework
npm install -g bats bats-support bats-assert

# Run unit + integration tests (771 tests)
npm test

# Run end-to-end tests (13 tests; full ralph_loop.sh subprocess runs)
npm run test:e2e

# Run specific test suites
bats tests/unit/test_rate_limiting.bats
bats tests/unit/test_exit_detection.bats
bats tests/unit/test_json_parsing.bats
bats tests/unit/test_cli_modern.bats
bats tests/unit/test_cli_parsing.bats
bats tests/unit/test_session_continuity.bats
bats tests/unit/test_enable_core.bats
bats tests/unit/test_task_sources.bats
bats tests/unit/test_ralph_enable.bats
bats tests/unit/test_wizard_utils.bats
bats tests/unit/test_circuit_breaker_recovery.bats
bats tests/integration/test_loop_execution.bats
bats tests/integration/test_prd_import.bats
bats tests/integration/test_project_setup.bats
bats tests/integration/test_installation.bats

# Run error detection and circuit breaker tests
./tests/test_error_detection.sh
./tests/test_stuck_loop_detection.sh
```

Current test status:
- **784 tests** across 34 test files
- **100% pass rate** (784/784 passing)
- Comprehensive unit, integration, and end-to-end tests
- Specialized tests for JSON parsing, CLI flags, circuit breaker, EXIT_SIGNAL behavior, enable wizard, and installation workflows
- True E2E suite running ralph_loop.sh as a subprocess against a mock Claude CLI (`tests/e2e/`)

> **Note on Coverage**: Bash code coverage measurement with kcov has fundamental limitations when tracing subprocess executions. Test pass rate (100%) is the quality gate. See [bats-core#15](https://github.com/bats-core/bats-core/issues/15) for details.

### Installing tmux

```bash
# Ubuntu/Debian
sudo apt-get install tmux

# macOS
brew install tmux

# CentOS/RHEL
sudo yum install tmux
```

### Installing GNU coreutils (macOS)

Ralph uses the `timeout` command for execution timeouts. On macOS, you need to install GNU coreutils:

```bash
# Install coreutils (provides gtimeout)
brew install coreutils

# Verify installation
gtimeout --version
```

Ralph automatically detects and uses `gtimeout` on macOS. No additional configuration is required after installation.

## Monitoring and Debugging

### Live Dashboard

```bash
# Integrated tmux monitoring (recommended)
ralph --monitor

# Manual monitoring in separate terminal
ralph-monitor
```

Shows real-time:
- Current loop count and status
- API calls used vs. limit
- Recent log entries
- Rate limit countdown

**tmux Controls:**
- `Ctrl+B` then `D` - Detach from session (keeps Ralph running)
- `Ctrl+B` then `←/→` - Switch between panes
- `tmux list-sessions` - View active sessions
- `tmux attach -t <session-name>` - Reattach to session

### Status Checking

```bash
# JSON status output
ralph --status

# Manual log inspection
tail -f .ralph/logs/ralph.log
```

### Common Issues

- **Ralph exits silently on first loop** - Claude Code CLI may not be installed or not in PATH. Ralph validates the command at startup and shows installation instructions. If using npx, add `CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"` to `.ralphrc`
- **Rate Limits** - Ralph automatically waits and displays countdown
- **5-Hour API Limit** - Ralph detects and prompts for user action (wait or exit)
- **Stuck Loops** - Check `fix_plan.md` for unclear or conflicting tasks
- **Early Exit** - Review exit thresholds if Ralph stops too soon
- **Premature Exit** - Check if Claude is setting `EXIT_SIGNAL: false` (Ralph now respects this)
- **Execution Timeouts** - Increase `--timeout` value for complex operations
- **Missing Dependencies** - Ensure Claude Code CLI and tmux are installed
- **tmux Session Lost** - Use `tmux list-sessions` and `tmux attach` to reconnect
- **Session Expired** - Sessions expire after 24 hours by default; use `--reset-session` to start fresh
- **timeout: command not found (macOS)** - Install GNU coreutils: `brew install coreutils`
- **Permission Denied** - Ralph halts when Claude Code is denied permission for commands:
  1. Edit `.ralphrc` and update `ALLOWED_TOOLS` to include required tools
  2. Common patterns: `Bash(npm *)`, `Bash(git *)`, `Bash(pytest)`
  3. Run `ralph --reset-session` after updating `.ralphrc`
  4. Restart with `ralph --monitor`

## Contributing

Ralph is actively seeking contributors! We're working toward v1.0.0 with clear priorities and a detailed roadmap.

**See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete contributor guide** including:
- Getting started and setup instructions
- Development workflow and commit conventions
- Code style guidelines
- Testing requirements (100% pass rate mandatory)
- Pull request process and code review guidelines
- Quality standards and checklists

### Quick Start

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
cd ralph-claude-code

# Install dependencies and run tests
npm install
npm test && npm run test:e2e  # All 784 tests must pass
```

### Priority Contribution Areas

1. **Test Implementation** - Help expand test coverage
2. **Feature Development** - Pick up an [open issue](https://github.com/frankbria/ralph-claude-code/issues)
3. **Documentation** - Tutorials, troubleshooting guides, examples
4. **Real-World Testing** - Use Ralph, report bugs, share feedback

**Every contribution matters** - from fixing typos to implementing major features!

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the [Ralph technique](https://ghuntley.com/ralph/) created by Geoffrey Huntley
- Built for [Claude Code](https://claude.ai/code) by Anthropic
- Community feedback and contributions

## Related Projects

- [Claude Code](https://claude.ai/code) - The AI coding assistant that powers Ralph
- [Aider](https://github.com/paul-gauthier/aider) - Original Ralph technique implementation

---

## Command Reference

### Installation Commands (Run Once)
```bash
./install.sh              # Install Ralph globally
./uninstall.sh            # Remove Ralph from system (dedicated script)
./install.sh uninstall    # Alternative: Remove Ralph from system
./install.sh --help       # Show installation help
ralph-migrate             # Migrate existing project to .ralph/ structure
```

### Ralph Loop Options
```bash
ralph [OPTIONS]
  -h, --help              Show help message
  -c, --calls NUM         Set max calls per hour (default: 100)
  -p, --prompt FILE       Set prompt file (default: .ralph/PROMPT.md)
  -s, --status            Show current status and exit
  -m, --monitor           Start with tmux session and live monitor
  -v, --verbose           Show detailed progress updates during execution
  -l, --live              Enable live streaming output (real-time Claude Code visibility)
  -t, --timeout MIN       Set Claude Code execution timeout in minutes (1-120, default: 15)
  --dry-run               Simulate loop execution without making actual Claude API calls
  -n, --notify            Enable desktop notifications for key events
  -b, --backup            Enable automatic git backup branch before each loop (requires git)
  --rollback [BRANCH]     Roll back to a backup branch (lists available branches if none given)
  --show-tool-args        Show tool arguments (commands, file paths) in live streaming output
  --output-format FORMAT  Set output format: json (default) or text
  --allowed-tools TOOLS   Set allowed Claude tools (default: granular git subcommands + npm/pytest)
  --no-continue           Disable session continuity (start fresh each loop)
  --session-expiry HOURS  Set session expiration time in hours (default: 24)
  --reset-circuit         Reset the circuit breaker
  --circuit-status        Show circuit breaker status
  --auto-reset-circuit    Auto-reset circuit breaker on startup (bypasses cooldown)
  --reset-session         Reset session state manually
  --queue-status          Show the issue queue and exit
  --process-queue         Process pending queued issues sequentially (--halt-on-failure to stop on first failure)
  --resume-queue          Resume processing the remaining pending issues
  --queue-next            Print the id of the next ready queued issue
  --queue-clear           Remove all items from the queue
  --queue-remove <id|N>   Remove one item from the queue
```

> **Full reference**: every flag is documented in depth, with examples and `.ralphrc` patterns, in [docs/CLI_OPTIONS.md](docs/CLI_OPTIONS.md).

### Project Commands (Per Project)
```bash
ralph-setup project-name     # Create new Ralph project
ralph-enable                 # Enable Ralph in existing project (interactive)
ralph-enable-ci              # Enable Ralph in existing project (non-interactive)
ralph-import prd.md project  # Convert PRD/specs to Ralph project
ralph-queue add --github-label bug   # Build a batch queue of issues
ralph-queue status           # Show the issue queue
ralph --process-queue        # Process the queue sequentially
ralph --monitor              # Start with integrated monitoring
ralph --status               # Check current loop status
ralph --verbose              # Enable detailed progress updates
ralph --timeout 30           # Set 30-minute execution timeout
ralph --calls 50             # Limit to 50 API calls per hour
ralph --reset-session        # Reset session state manually
ralph --live                 # Enable live streaming output
ralph --dry-run              # Simulate a loop without API calls
ralph --notify               # Desktop notifications for key events
ralph --backup               # Git backup branch before each loop
ralph-stats                  # Metrics summary from .ralph/logs/metrics.jsonl
ralph-monitor                # Manual monitoring dashboard
```

### tmux Session Management
```bash
tmux list-sessions        # View active Ralph sessions
tmux attach -t <name>     # Reattach to detached session
# Ctrl+B then D           # Detach from session (keeps running)
```

---

## Development Roadmap

Ralph is under active development with a clear path to v1.0.0. See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the complete roadmap.

### Current Status: v0.11.5

**What's Delivered:**
- Core loop functionality with intelligent exit detection
- **Dual-condition exit gate** (completion indicators + EXIT_SIGNAL)
- Rate limiting (100 calls/hour) and circuit breaker pattern
- Response analyzer with semantic understanding
- **784 comprehensive tests** (100% pass rate)
- **Live streaming output mode** for real-time Claude Code visibility
- **Log rotation, dry-run mode, metrics (`ralph-stats`), desktop notifications, and git backup/rollback**
- tmux integration and live monitoring
- PRD import functionality with modern CLI JSON parsing
- Installation system and project templates
- Modern CLI commands with JSON output support
- CI/CD pipeline with GitHub Actions
- **Interactive `ralph-enable` wizard for existing projects**
- **`.ralphrc` configuration file support**
- Session lifecycle management with auto-reset triggers
- Session expiration with configurable timeout
- Dedicated uninstall script

**Test Coverage:**
- **784 tests across 34 test files** — unit, integration, and end-to-end (100% pass rate)
- See [TESTING.md](TESTING.md) for the per-suite breakdown and how to run each category

### Path to v1.0.0

**Completed milestones**: installation/setup workflow tests, tmux integration tests, monitor dashboard tests, end-to-end full-loop tests, log rotation, dry-run mode, metrics (`ralph-stats`), desktop notifications, and git backup/rollback.

**Remaining**
- Final documentation sweep and release prep
- Supply-chain hardening for CI workflows ([#275](https://github.com/frankbria/ralph-claude-code/issues/275))
- Real-world feedback from the [open issues](https://github.com/frankbria/ralph-claude-code/issues) backlog

See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for detailed progress tracking.

### How to Contribute
Ralph is seeking contributors! See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete guide. Priority areas:
1. **Test Implementation** - Help expand test coverage ([see plan](IMPLEMENTATION_PLAN.md))
2. **Feature Development** - Pick up an [open issue](https://github.com/frankbria/ralph-claude-code/issues)
3. **Documentation** - Usage examples, tutorials, troubleshooting guides
4. **Bug Reports** - Real-world usage feedback and edge cases

---

**Ready to let AI build your project?** Start with `./install.sh` and let Ralph take it from there!

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=frankbria/ralph-claude-code&type=date&legend=top-left)](https://www.star-history.com/#frankbria/ralph-claude-code&type=date&legend=top-left)
