# Ralph Loop

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Status](https://img.shields.io/badge/status-stable-brightgreen)
![Tests](https://img.shields.io/badge/tests-218-blue)
![Coverage](https://img.shields.io/badge/coverage-~70%25-(est.)-yellow)

> **Autonomous AI development loop with intelligent exit detection and rate limiting**

Ralph is an implementation of the Geoffrey Huntley's technique for Claude Code that enables continuous autonomous development cycles he named after [Ralph Wiggam](https://ghuntley.com/ralph/). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** - Ralph becomes a global command available in any directory.

## 📌 Project Status

**Version**: v1.0.0 - Stable Release  
**Core Features**: ✅ Complete and exercised by unit/integration tests  
**Test Coverage**: ~70% (218 tests across unit, integration, and e2e suites – see `IMPLEMENTATION_STATUS.md` for details)

### What's Working Now ✅
- Autonomous development loops with intelligent exit detection
- Rate limiting with hourly reset (100 calls/hour, configurable)
- Circuit breaker with advanced error detection (prevents runaway loops)
- Response analyzer with semantic understanding and two-stage error filtering
- Multi-line error matching for accurate stuck loop detection
- 5-hour API limit handling with user prompts
- tmux integration for live monitoring
- PRD import functionality (deterministic, CLI-free by default)
- **Dry-run mode** – Preview operations without executing
- **Configuration file support** – `~/.ralphrc` and `.ralphrc`
- **Metrics and analytics tracking** – JSONL format logging and `ralph-stats`
- **Desktop notifications** – Cross-platform alerts (macOS, Linux, fallback)
- **Git backup and rollback** – Branch-based project state management
- 218 tests covering all critical paths (unit, integration, and e2e)

### Release Highlights 🎉

**v1.0.0 - Complete Implementation**
- ✅ Dry-run mode (`--dry-run`) for safe operation previews
- ✅ Configuration file support (`~/.ralphrc` and `.ralphrc` with proper override precedence)
- ✅ Metrics tracking with JSONL format and `ralph-stats` summary CLI
- ✅ Cross-platform desktop notifications (`--notify` flag)
- ✅ Git-based backup and rollback system (`--backup` flag)
- ✅ Comprehensive test suite: 218 tests (120 unit + 88 integration + 10 e2e)
- ✅ Solid coverage of core modules (coverage still improving; target 85–90%)
- ✅ Full documentation and examples

**v0.9.0 - Circuit Breaker Enhancements**
- ✅ Fixed multi-line error matching in stuck loop detection
- ✅ Eliminated JSON field false positives (e.g., `"is_error": false`)
- ✅ Added two-stage error filtering for accurate detection
- ✅ Fixed installation to include lib/ directory components

## 🌟 Features

### Core Capabilities
- **🔄 Autonomous Development Loop** - Continuously executes Claude Code with your project requirements
- **🛡️ Intelligent Exit Detection** - Automatically stops when project objectives are complete
- **⚡ Rate Limiting** - Built-in API call management with hourly limits and countdown timers
- **🚫 5-Hour API Limit Handling** - Detects Claude's 5-hour usage limit and offers wait/exit options
- **📊 Live Monitoring** - Real-time dashboard showing loop status, progress, and logs
- **🎯 Task Management** - Structured approach with prioritized task lists and progress tracking
- **🔧 Project Templates** - Quick setup for new projects with best-practice structure
- **📝 Comprehensive Logging** - Detailed execution logs with timestamps and status tracking
- **⏱️ Configurable Timeouts** - Set execution timeout for Claude Code operations (1-120 minutes)
- **🔍 Verbose Progress Mode** - Optional detailed progress updates during execution
- **🧠 Response Analyzer** - AI-powered analysis of Claude Code responses with semantic understanding
- **🔌 Circuit Breaker** - Advanced error detection with two-stage filtering, multi-line error matching, and automatic recovery

### New in v1.0.0
- **🔬 Dry-Run Mode** - Preview what Ralph would do without making any changes
- **⚙️ Configuration Files** - Persistent settings via ~/.ralphrc (global) and .ralphrc (project)
- **📈 Metrics & Analytics** - Track loop performance, API usage, and success rates in JSONL format
- **🔔 Desktop Notifications** - Get alerts for completions, errors, and important events
- **💾 Backup & Rollback** - Git branch-based snapshots for safe recovery

### New in v1.0.0 - Multi-CLI Adapter Support 🔌
- **🔄 Adapter Pattern** – Support for multiple AI CLI tools through a pluggable adapter system
- **🤖 Built-in Adapters** – Claude Code (default), Aider (GPT-4/Claude/local), Ollama (fully offline)
- **🛠️ Custom Adapters** – Easy-to-create adapters for any CLI tool
- **🔀 Auto-Detection** – Automatically detects and uses available adapters
- **📋 Fallback Support** – Graceful fallback when primary adapter unavailable

```bash
# Use different AI CLI tools with Ralph
ralph --adapter claude --monitor     # Claude Code (default)
ralph --adapter aider --monitor      # Aider with GPT-4
ralph --adapter ollama --monitor     # Local LLMs with Ollama
ralph --list-adapters                # See all available adapters
```

### Testing & Quality
- **✅ 218 Tests** – Unit, integration, and end-to-end coverage of core paths
- **📊 ~70% Code Coverage (estimated)** – Critical paths thoroughly exercised; coverage still increasing
- **🔄 CI/CD Ready** – CI runs unit, integration, and E2E suites on each push/PR (see `IMPLEMENTATION_STATUS.md` for current details)

## 🚀 Quick Start

Ralph has two phases: **one-time installation** and **per-project setup**.

```
🔧 INSTALL ONCE              🚀 USE MANY TIMES
┌─────────────────┐          ┌──────────────────────┐
│ ./install.sh    │    →     │ ralph-setup project1 │
│                 │          │ ralph-setup project2 │
│ Adds global     │          │ ralph-setup project3 │
│ commands        │          │ ...                  │
└─────────────────┘          └──────────────────────┘
```

### 📦 Phase 1: Install Ralph (One Time Only)

Install Ralph globally on your system:

```bash
git clone https://github.com/pt-act/ralph-claude-code.git
cd ralph-claude-code
./install.sh
```

This adds `ralph`, `ralph-monitor`, and `ralph-setup` commands to your PATH.

> **Note**: You only need to do this once per system. After installation, you can delete the cloned repository if desired.

### 🎯 Phase 2: Initialize New Projects (Per Project)

For each new project you want Ralph to work on:

#### Option A: Import Existing PRD/Specifications
```bash
# Convert existing PRD/specs to Ralph format (recommended)
ralph-import my-requirements.md my-project
cd my-project

# Review and adjust the generated files:
# - PROMPT.md (Ralph instructions)
# - @fix_plan.md (task priorities) 
# - specs/requirements.md (technical specs)

# Start autonomous development
ralph --monitor
```

#### Option B: Manual Project Setup
```bash
# Create blank Ralph project
ralph-setup my-awesome-project
cd my-awesome-project

# Configure your project requirements manually
# Edit PROMPT.md with your project goals
# Edit specs/ with detailed specifications  
# Edit @fix_plan.md with initial priorities

# Start autonomous development
ralph --monitor
```

### 🔄 Ongoing Usage (After Setup)

Once Ralph is installed and your project is initialized:

```bash
# Navigate to any Ralph project and run:
ralph --monitor              # Integrated tmux monitoring (recommended)

# Or use separate terminals:
ralph                        # Terminal 1: Ralph loop
ralph-monitor               # Terminal 2: Live monitor dashboard
```

## 📖 How It Works

Ralph operates on a simple but powerful cycle:

1. **📋 Read Instructions** - Loads `PROMPT.md` with your project requirements
2. **🤖 Execute Claude Code** - Runs Claude Code with current context and priorities  
3. **📊 Track Progress** - Updates task lists and logs execution results
4. **🔍 Evaluate Completion** - Checks for exit conditions and project completion signals
5. **🔄 Repeat** - Continues until project is complete or limits are reached

### Intelligent Exit Detection

Ralph automatically stops when it detects:
- ✅ All tasks in `@fix_plan.md` marked complete
- 🎯 Multiple consecutive "done" signals from Claude Code
- 🧪 Too many test-focused loops (indicating feature completeness)
- 📋 Strong completion indicators in responses
- 🚫 Claude API 5-hour usage limit reached (with user prompt to wait or exit)

## 📄 Importing Existing Requirements

Ralph can convert existing PRDs, specifications, or requirement documents into the proper Ralph format using a deterministic local converter (no external AI tools).

### Supported Formats
- **Markdown** (.md) - Product requirements, technical specs
- **Text files** (.txt) - Plain text requirements
- **JSON** (.json) - Structured requirement data
- **Other formats via export** – Export Word documents, PDFs, or other binary formats to `.md`, `.txt`, or another text format before running `ralph-import`.
- **Any text-based format** – Ralph will parse the content, extracting bullet points into tasks where possible

### Usage Examples

```bash
# Convert a markdown PRD
ralph-import product-requirements.md my-app

# Convert a text specification  
ralph-import requirements.txt webapp

# Convert a JSON API spec
ralph-import api-spec.json backend-service

# Let Ralph auto-name the project from filename
ralph-import design-doc.md
```

### What Gets Generated

Ralph-import creates a complete project with:

- **PROMPT.md** - Converted into Ralph development instructions
- **@fix_plan.md** - Requirements broken down into prioritized tasks
- **specs/requirements.md** - Technical specifications extracted from your document
- **Standard Ralph structure** - All necessary directories and template files

The conversion is intelligent and preserves your original requirements while making them actionable for autonomous development.

## 🛠️ Configuration

### Configuration Files

Ralph supports configuration files for persistent settings:

```bash
# Global configuration (applies to all projects)
~/.ralphrc

# Project-specific configuration (overrides global)
.ralphrc
```

**Example .ralphrc:**
```bash
# Ralph Configuration File
RALPH_MAX_CALLS=50           # Max API calls per hour
RALPH_TIMEOUT=30             # Execution timeout in minutes
RALPH_VERBOSE=true           # Enable verbose output
RALPH_NOTIFY=true            # Enable desktop notifications
RALPH_BACKUP=true            # Enable automatic backups
RALPH_METRICS=true           # Enable metrics tracking
```

Configuration precedence (highest to lowest):
1. Command-line arguments
2. Project .ralphrc
3. Global ~/.ralphrc
4. Default values

### Dry-Run Mode

Preview what Ralph would do without making any changes:

```bash
# Preview operations without executing
ralph --dry-run

# Combine with other options
ralph --dry-run --verbose

# See what would happen with specific settings
ralph --dry-run --calls 50 --timeout 30
```

Dry-run mode shows:
- Commands that would be executed
- Files that would be modified
- API calls that would be made
- Configuration that would be applied

### Metrics and Analytics

Track loop performance and usage patterns:

```bash
# Metrics are always written to logs/metrics.jsonl by the main loop.
# Use the helper CLI to summarize them:
ralph-stats logs/metrics.jsonl
```

Metrics are stored in JSONL format at `logs/metrics.jsonl` in each project:
- Loop duration and count
- Call counts per loop
- Success/failure flags

### Desktop Notifications

Get alerts for important events:

```bash
# Enable notifications
ralph --notify

# Notifications are sent for:
# - Loop completion
# - Error detection
# - Rate limit warnings
# - Circuit breaker activation
```

Supported platforms:
- **macOS**: Native `osascript` notifications
- **Linux**: `notify-send` (libnotify)
- **Fallback**: Terminal bell and log messages when neither is available

### Backup and Rollback

Protect your project with git-based snapshots:

```bash
# Enable automatic backups before each loop iteration
ralph --backup
```

Backups are stored as git branches named like:

```text
ralph-backup-loop-<loop_number>-<unix_timestamp>
```

Each backup:
- Creates an (allow-empty) commit to capture the current state
- Adds a branch at that commit for easy inspection and comparison
- Allows manual rollback using standard git commands:

```bash
git reset --hard ralph-backup-loop-3-1704643200
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

## 📁 Project Structure

Ralph creates a standardized structure for each project:

```
my-project/
├── PROMPT.md           # Main development instructions for Ralph
├── @fix_plan.md        # Prioritized task list (@ prefix = Ralph control file)
├── @AGENT.md           # Build and run instructions
├── specs/              # Project specifications and requirements
│   └── stdlib/         # Standard library specifications
├── src/                # Source code implementation
├── examples/           # Usage examples and test cases
├── logs/               # Ralph execution logs
└── docs/generated/     # Auto-generated documentation
```

## 🎯 Best Practices

### Writing Effective Prompts

1. **Be Specific** - Clear requirements lead to better results
2. **Prioritize** - Use `@fix_plan.md` to guide Ralph's focus
3. **Set Boundaries** - Define what's in/out of scope
4. **Include Examples** - Show expected inputs/outputs

### Project Specifications

- Place detailed requirements in `specs/`
- Use `@fix_plan.md` for prioritized task tracking
- Keep `@AGENT.md` updated with build instructions
- Document key decisions and architecture

### Monitoring Progress

- Use `ralph-monitor` for live status updates
- Check logs in `logs/` for detailed execution history  
- Monitor `status.json` for programmatic access
- Watch for exit condition signals

### Using New Features

**Dry-Run First**: Before running Ralph on a new project, use `--dry-run` to preview operations.

**Enable Backups**: Use `--backup` for peace of mind, especially on important projects.

**Track Metrics**: Metrics are logged automatically; use `ralph-stats logs/metrics.jsonl` to understand loop patterns and optimize settings.

**Stay Notified**: Use `--notify` to get alerts without constantly watching the terminal.

## 🔧 System Requirements

- **Bash 4.0+** - For script execution
- **Claude Code CLI** - `npm install -g @anthropic-ai/claude-code`
- **tmux** - Terminal multiplexer for integrated monitoring (recommended)
- **jq** - JSON processing for status tracking
- **Git** - Version control (projects are initialized as git repos)
- **Standard Unix tools** - grep, date, etc.

### Optional Dependencies
- **libnotify** (Linux) - For desktop notifications (`notify-send`)

### Testing Requirements (Development)

See **`TESTING.md`** for a full guide to local setup, running tests, CI behavior, and coverage philosophy.

Quick start:

```bash
# Install BATS testing framework
npm install -g bats bats-support bats-assert

# Run all tests via npm scripts
npm test

# Or run specific suites
npm run test:unit
npm run test:integration
npm run test:e2e
```

**Test Status (see `IMPLEMENTATION_STATUS.md` for details):**
- **218 tests** across unit, integration, and e2e suites
- **Unit tests**: 100% pass rate
- **Integration/E2E tests**: run as part of CI; failures will fail the build
- Code coverage is **~70% (estimated)** and continues to improve

### Installing tmux

```bash
# Ubuntu/Debian
sudo apt-get install tmux

# macOS
brew install tmux

# CentOS/RHEL
sudo yum install tmux
```

## 📊 Monitoring and Debugging

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
tail -f logs/ralph.log

# View metrics
ralph-stats logs/metrics.jsonl
```

### Common Issues

- **Rate Limits** - Ralph automatically waits and displays countdown
- **5-Hour API Limit** - Ralph detects and prompts for user action (wait or exit)
- **Stuck Loops** - Check `@fix_plan.md` for unclear or conflicting tasks
- **Early Exit** - Review exit thresholds if Ralph stops too soon
- **Execution Timeouts** - Increase `--timeout` value for complex operations
- **Missing Dependencies** - Ensure Claude Code CLI and tmux are installed
- **tmux Session Lost** - Use `tmux list-sessions` and `tmux attach` to reconnect

## 🤝 Contributing

Ralph welcomes contributions! The project has reached v1.0.0 with strong test coverage (~70% of core paths, still improving).

For detailed contribution guidelines, see **`CONTRIBUTING.md`** and **`TESTING.md`**.

### Quick Start for Contributors

1. **Fork and Clone**
   ```bash
   git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
   cd ralph-claude-code
   ```

2. **Install Dependencies**
   ```bash
   npm install -g bats bats-support bats-assert
   ./install.sh  # Install Ralph globally for testing
   ```

3. **Run Tests**
   ```bash
   npm test                    # Run all tests (currently 218 tests; see IMPLEMENTATION_STATUS.md)
   npm run test:unit           # Run unit tests only
   npm run test:integration    # Run integration tests only
   npm run test:e2e            # Run end-to-end tests only
   ```

### Contribution Areas

**🔧 Maintenance**
- Bug fixes and edge case handling
- Performance optimizations
- Cross-platform compatibility improvements

**📚 Documentation**
- Usage tutorials and examples
- Troubleshooting guides
- Video walkthroughs

**🚀 New Features**
- Integration with other AI coding tools
- Enhanced analytics and reporting
- Plugin/extension system
- Web-based monitoring dashboard

**🧪 Testing**
- Additional edge case coverage
- Performance benchmarks
- Platform-specific tests

### Development Guidelines

- **Tests Required**: All new features must include tests
- **Coverage Goal**: Maintain 90%+ coverage
- **Code Style**: Follow existing bash patterns and conventions
- **Documentation**: Update README and relevant docs for user-facing changes
- **Commit Messages**: Clear, descriptive commit messages
- **Branch Naming**: `feature/feature-name` or `fix/bug-description`

### Pull Request Process

1. Create a feature branch (`git checkout -b feature/amazing-feature`)
2. Make your changes with tests
3. Run full test suite: `npm test` (must pass 100%)
4. Update documentation if needed
5. Commit changes (`git commit -m 'Add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request with:
   - Clear description of changes
   - Link to related issues
   - Test results
   - Screenshots (if UI/output changes)

### Questions or Ideas?

- Open an issue for discussion
- Check existing issues for planned work
- Join discussions on pull requests

**Every contribution matters** - from fixing typos to implementing major features. Thank you for helping make Ralph better! 🙏

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the [Ralph technique](https://github.com/paul-gauthier/aider/blob/main/docs/more/aider-benchmarks.md#ralph) created by Paul Gauthier for the Aider project
- Built for [Claude Code](https://claude.ai/code) by Anthropic
- Community feedback and contributions

## 🔗 Related Projects

- [Claude Code](https://claude.ai/code) - The AI coding assistant that powers Ralph
- [Aider](https://github.com/paul-gauthier/aider) - Original Ralph technique implementation

---

## 📋 Command Reference

### Installation Commands (Run Once)
```bash
./install.sh              # Install Ralph globally
./install.sh uninstall    # Remove Ralph from system
./install.sh --help       # Show installation help
```

### Ralph Loop Options
```bash
ralph [OPTIONS]
  -h, --help              Show help message
  -c, --calls NUM         Set max calls per hour (default: 100)
  -p, --prompt FILE       Set prompt file (default: PROMPT.md)
  -s, --status            Show current status and exit
  -m, --monitor           Start with tmux session and live monitor
  -v, --verbose           Show detailed progress updates during execution
  -t, --timeout MIN       Set execution timeout in minutes (1-120, default: 15)
  -d, --dry-run           Preview operations without executing
  -n, --notify            Enable desktop notifications
  -b, --backup            Enable automatic git backups
  --reset-circuit         Reset the circuit breaker state
  --circuit-status        Show circuit breaker status and exit
```

### Project Commands (Per Project)
```bash
ralph-setup project-name     # Create new Ralph project
ralph-import prd.md project  # Convert PRD/specs to Ralph project
ralph --monitor              # Start with integrated monitoring
ralph --status               # Check current loop status
ralph --verbose              # Enable detailed progress updates
ralph --timeout 30           # Set 30-minute execution timeout
ralph --calls 50             # Limit to 50 API calls per hour
ralph --dry-run              # Preview without executing
ralph --notify               # Enable desktop notifications
ralph --backup               # Enable automatic backups
ralph-monitor                # Manual monitoring dashboard
```

### tmux Session Management
```bash
tmux list-sessions        # View active Ralph sessions
tmux attach -t <name>     # Reattach to detached session
# Ctrl+B then D           # Detach from session (keeps running)
```

---

## 🔄 Migration from pre-1.0.0

If you're upgrading from an earlier Ralph version (≤0.9.x):

- **Configuration loading** – Ralph now automatically loads `~/.ralphrc` and `.ralphrc` *before* parsing CLI flags. CLI options still have highest precedence, but config files can override built-in defaults. Review any scripts that relied on only environment variables or hard-coded defaults.
- **Git backup branches** – Using `--backup` creates extra commits and branches named `ralph-backup-loop-<loop>-<timestamp>`. If you have automation that assumes a strictly linear git history, update it to ignore these branches or disable backups for that workflow.
- **PRD import behaviour** – `ralph-import` now performs a deterministic local transformation instead of calling external AI tools. Results are predictable and CI-safe, but may differ from earlier AI-generated imports.

For more detail, see **`MIGRATION.md`** and the **Breaking Changes** section in `IMPLEMENTATION_STATUS.md`.

## 🏆 Version History

### v1.0.0 (Current) - Complete Implementation
- ✅ Dry-run mode for safe previews
- ✅ Configuration file support (`~/.ralphrc` and `.ralphrc`)
- ✅ Metrics and analytics tracking (`logs/metrics.jsonl` + `ralph-stats`)
- ✅ Desktop notifications (cross-platform)
- ✅ Git backup and rollback system
- ✅ 218 tests across unit, integration, and e2e suites

### v0.9.0 - Circuit Breaker Enhancements
- Fixed multi-line error matching
- Eliminated JSON field false positives
- Added two-stage error filtering
- 97 tests with 60% coverage

### v0.8.0 - Initial Release
- Core loop functionality
- Rate limiting and exit detection
- tmux integration
- PRD import functionality

---

**Ready to let AI build your project?** Start with `./install.sh` and let Ralph take it from there! 🚀

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=pt-act/ralph-claude-code&type=date&legend=top-left)](https://www.star-history.com/#pt-act/ralph-claude-code&type=date&legend=top-left)
