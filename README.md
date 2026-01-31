# Ralph for Claude Code

[![CI](https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml/badge.svg)](https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-0.11.2-blue)
![Tests](https://img.shields.io/badge/tests-440%20passing-green)
[![GitHub Issues](https://img.shields.io/github/issues/frankbria/ralph-claude-code)](https://github.com/frankbria/ralph-claude-code/issues)
[![Mentioned in Awesome Claude Code](https://awesome.re/mentioned-badge.svg)](https://github.com/hesreallyhim/awesome-claude-code)
[![Follow on X](https://img.shields.io/twitter/follow/FrankBria18044?style=social)](https://x.com/FrankBria18044)

> **Autonomous AI development loop with intelligent exit detection and rate limiting**

Ralph is an implementation of the Geoffrey Huntley's technique for Claude Code that enables continuous autonomous development cycles he named after [Ralph Wiggum](https://ghuntley.com/ralph/). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** - Ralph becomes a global command available in any directory.

## Project Status

**Version**: v0.11.2 - Active Development
**Core Features**: Working and tested
**Test Coverage**: 440 tests, 100% pass rate

### What's Working Now
- Autonomous development loops with intelligent exit detection
- **Dual-condition exit gate**: Requires BOTH completion indicators AND explicit EXIT_SIGNAL
- Rate limiting with hourly reset (100 calls/hour, configurable)
- Circuit breaker with advanced error detection (prevents runaway loops)
- Response analyzer with semantic understanding and two-stage error filtering
- **JSON output format support with automatic fallback to text parsing**
- **Live streaming output mode (`--live`) - watch Claude work in real-time**
- **Session continuity with `--continue` flag for context preservation**
- **Session expiration with configurable timeout (default: 24 hours)**
- **Modern CLI flags: `--output-format`, `--allowed-tools`, `--no-continue`, `--live`**
- **Interactive project enablement with `ralph-enable` wizard**
- **`.ralphrc` configuration file for project settings**
- Multi-line error matching for accurate stuck loop detection
- 5-hour API limit handling with user prompts
- tmux integration with 3-pane layout for live monitoring
- PRD import functionality
- **CI/CD pipeline with GitHub Actions**
- **Dedicated uninstall script for clean removal**

### Recent Improvements

**v0.11.2 - Setup Permissions Fix** (latest)
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
- Log rotation functionality
- Dry-run mode
- Metrics and analytics tracking
- Desktop notifications
- Git backup and rollback system
- [Automated badge updates](#138)

**Timeline to v1.0**: ~4 weeks | [Full roadmap](IMPLEMENTATION_PLAN.md) | **Contributions welcome!**

## Features

- **Autonomous Development Loop** - Continuously executes Claude Code with your project requirements
- **Intelligent Exit Detection** - Dual-condition check requiring BOTH completion indicators AND explicit EXIT_SIGNAL
- **Session Continuity** - Preserves context across loop iterations with automatic session management
- **Session Expiration** - Configurable timeout (default: 24 hours) with automatic session reset
- **Rate Limiting** - Built-in API call management with hourly limits and countdown timers
- **5-Hour API Limit Handling** - Detects Claude's 5-hour usage limit and offers wait/exit options
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

This adds `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-migrate`, `ralph-enable`, and `ralph-enable-ci` commands to your PATH.

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

# Or with live streaming output (watch Claude work in real-time)
ralph --live
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
- All tasks in `.ralph/fix_plan.md` marked complete
- Multiple consecutive "done" signals from Claude Code
- Too many test-focused loops (indicating feature completeness)
- Claude API 5-hour usage limit reached (with user prompt to wait or exit)

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

## Configuration

### Project Configuration (.ralphrc)

Each Ralph project can have a `.ralphrc` configuration file:

```bash
# .ralphrc - Ralph project configuration
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"

# Loop settings
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"

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

# Check current usage
ralph --status
```

The circuit breaker automatically:
- Detects API errors and rate limit issues with advanced two-stage filtering
- Opens circuit after 3 loops with no progress or 5 loops with same errors
- Eliminates false positives from JSON fields containing "error"
- Accurately detects stuck loops with multi-line error matching
- Gradually recovers with half-open monitoring state
- Provides detailed error tracking and logging with state history

### Claude API 5-Hour Limit

When Claude's 5-hour usage limit is reached, Ralph:
1. Detects the limit error automatically
2. Prompts you to choose:
   - **Option 1**: Wait 60 minutes for the limit to reset (with countdown timer)
   - **Option 2**: Exit gracefully (or auto-exits after 30-second timeout)
3. Prevents endless retry loops that waste time

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
- **Claude Code CLI** - `npm install -g @anthropic-ai/claude-code`
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

# Run all tests (440 tests)
npm test

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
bats tests/integration/test_loop_execution.bats
bats tests/integration/test_prd_import.bats
bats tests/integration/test_project_setup.bats
bats tests/integration/test_installation.bats

# Run error detection and circuit breaker tests
./tests/test_error_detection.sh
./tests/test_stuck_loop_detection.sh
```

Current test status:
- **440 tests** across 15 test files
- **100% pass rate** (440/440 passing)
- Comprehensive unit and integration tests
- Specialized tests for JSON parsing, CLI flags, circuit breaker, EXIT_SIGNAL behavior, enable wizard, and installation workflows

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
npm test  # All 440 tests must pass
```

### Priority Contribution Areas

1. **Test Implementation** - Help expand test coverage
2. **Feature Development** - Log rotation, dry-run mode, metrics
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
  -p, --prompt FILE       Set prompt file (default: PROMPT.md)
  -s, --status            Show current status and exit
  -m, --monitor           Start with tmux session and live monitor
  -l, --live              Enable live streaming output (watch Claude work in real-time)
  -v, --verbose           Show detailed progress updates during execution
  -t, --timeout MIN       Set Claude Code execution timeout in minutes (1-120, default: 15)
  --output-format FORMAT  Set output format: json (default) or text
  --allowed-tools TOOLS   Set allowed Claude tools (default: Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest))
  --no-continue           Disable session continuity (start fresh each loop)
  --reset-circuit         Reset the circuit breaker
  --circuit-status        Show circuit breaker status
  --reset-session         Reset session state manually
```

### Project Commands (Per Project)
```bash
ralph-setup project-name     # Create new Ralph project
ralph-enable                 # Enable Ralph in existing project (interactive)
ralph-enable-ci              # Enable Ralph in existing project (non-interactive)
ralph-import prd.md project  # Convert PRD/specs to Ralph project
ralph --monitor              # Start with integrated monitoring
ralph --live                 # Enable live streaming output
ralph --monitor --live       # Combined: tmux + live streaming
ralph --status               # Check current loop status
ralph --verbose              # Enable detailed progress updates
ralph --timeout 30           # Set 30-minute execution timeout
ralph --calls 50             # Limit to 50 API calls per hour
ralph --reset-session        # Reset session state manually
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

### Current Status: v0.11.2

**What's Delivered:**
- Core loop functionality with intelligent exit detection
- **Dual-condition exit gate** (completion indicators + EXIT_SIGNAL)
- Rate limiting (100 calls/hour) and circuit breaker pattern
- Response analyzer with semantic understanding
- **440 comprehensive tests** (100% pass rate)
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

**Test Coverage Breakdown:**
- Unit Tests: 296 (CLI parsing, JSON, exit detection, rate limiting, session continuity, enable wizard)
- Integration Tests: 144 (loop execution, edge cases, installation, project setup, PRD import)
- Test Files: 15

### Path to v1.0.0 (~4 weeks)

**Enhanced Testing**
- Installation and setup workflow tests
- tmux integration tests
- Monitor dashboard tests

**Core Features**
- Log rotation functionality
- Dry-run mode

**Advanced Features & Polish**
- Metrics and analytics tracking
- Desktop notifications
- Git backup and rollback system
- End-to-end tests
- Final documentation and release prep

See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for detailed progress tracking.

### How to Contribute
Ralph is seeking contributors! See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete guide. Priority areas:
1. **Test Implementation** - Help expand test coverage ([see plan](IMPLEMENTATION_PLAN.md))
2. **Feature Development** - Log rotation, dry-run mode, metrics
3. **Documentation** - Usage examples, tutorials, troubleshooting guides
4. **Bug Reports** - Real-world usage feedback and edge cases

---

**Ready to let AI build your project?** Start with `./install.sh` and let Ralph take it from there!

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=frankbria/ralph-claude-code&type=date&legend=top-left)](https://www.star-history.com/#frankbria/ralph-claude-code&type=date&legend=top-left)
