# Ralph for Claude Code

> **Autonomous AI development loop with intelligent exit detection and rate limiting**

Ralph is an implementation of the [Ralph technique](https://github.com/paul-gauthier/aider/blob/main/docs/more/aider-benchmarks.md#ralph) by Paul Gauthier, specifically adapted for [Claude Code](https://claude.ai/code). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** - Ralph becomes a global command available in any directory.

## 🌟 Features

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
git clone https://github.com/frankbria/ralph-claude-code.git
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

- **PROMPT.md** - Converted into Ralph development instructions
- **@fix_plan.md** - Requirements broken down into prioritized tasks
- **specs/requirements.md** - Technical specifications extracted from your document
- **Standard Ralph structure** - All necessary directories and template files

The conversion is intelligent and preserves your original requirements while making them actionable for autonomous development.

## 🛠️ Configuration

### Rate Limiting

```bash
# Default: 100 calls per hour
ralph --calls 50

# With integrated monitoring
ralph --monitor --calls 50

# Check current usage
ralph --status
```

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
```bash
MAX_CONSECUTIVE_TEST_LOOPS=3     # Exit after 3 test-only loops
MAX_CONSECUTIVE_DONE_SIGNALS=2   # Exit after 2 "done" signals
TEST_PERCENTAGE_THRESHOLD=30     # Flag if 30%+ loops are test-only
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

## 🔧 System Requirements

- **Bash 4.0+** - For script execution
- **Claude Code CLI** - `npm install -g @anthropic-ai/claude-code`
- **tmux** - Terminal multiplexer for integrated monitoring (recommended)
- **jq** - JSON processing for status tracking
- **Git** - Version control (projects are initialized as git repos)
- **Standard Unix tools** - grep, date, etc.

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

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test with `./install.sh` and sample projects
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

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
  -h, --help          Show help message
  -c, --calls NUM     Set max calls per hour (default: 100)
  -p, --prompt FILE   Set prompt file (default: PROMPT.md)
  -s, --status        Show current status and exit
  -m, --monitor       Start with tmux session and live monitor
  -v, --verbose       Show detailed progress updates during execution
  -t, --timeout MIN   Set Claude Code execution timeout in minutes (1-120, default: 15)
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
ralph-monitor                # Manual monitoring dashboard
```

### tmux Session Management
```bash
tmux list-sessions        # View active Ralph sessions
tmux attach -t <name>     # Reattach to detached session
# Ctrl+B then D           # Detach from session (keeps running)
```

---

**Ready to let AI build your project?** Start with `./install.sh` and let Ralph take it from there! 🚀