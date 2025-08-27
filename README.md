# Ralph for Claude Code

> **Autonomous AI development loop with intelligent exit detection and rate limiting**

Ralph is an implementation of the [Ralph technique](https://github.com/paul-gauthier/aider/blob/main/docs/more/aider-benchmarks.md#ralph) specifically designed for [Claude Code](https://claude.ai/code). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** - Ralph becomes a global command available in any directory.

## 🌟 Features

- **🔄 Autonomous Development Loop** - Continuously executes Claude Code with your project requirements
- **🛡️ Intelligent Exit Detection** - Automatically stops when project objectives are complete
- **⚡ Rate Limiting** - Built-in API call management with hourly limits and countdown timers  
- **📊 Live Monitoring** - Real-time dashboard showing loop status, progress, and logs
- **🎯 Task Management** - Structured approach with prioritized task lists and progress tracking
- **🔧 Project Templates** - Quick setup for new projects with best-practice structure
- **📝 Comprehensive Logging** - Detailed execution logs with timestamps and status tracking

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

```bash
# 1. Create a new Ralph-managed project (run anywhere)
ralph-setup my-awesome-project
cd my-awesome-project

# 2. Configure your project requirements
# Edit PROMPT.md with your project goals
# Edit specs/ with detailed specifications  
# Edit @fix_plan.md with initial priorities

# 3. Start autonomous development
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

### Custom Prompts

```bash
# Use custom prompt file
ralph --prompt my_custom_instructions.md

# With integrated monitoring
ralph --monitor --prompt my_custom_instructions.md
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
- **Claude Code CLI** - `npx @anthropic/claude-code`
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
- **Stuck Loops** - Check `@fix_plan.md` for unclear or conflicting tasks
- **Early Exit** - Review exit thresholds if Ralph stops too soon
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

- Inspired by the [Ralph technique](https://github.com/paul-gauthier/aider/blob/main/docs/more/aider-benchmarks.md#ralph) from the Aider project
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

### Project Commands (Per Project)
```bash
ralph-setup project-name  # Create new Ralph project
ralph --monitor           # Start with integrated monitoring  
ralph --status            # Check current loop status
ralph-monitor             # Manual monitoring dashboard
```

### tmux Session Management
```bash
tmux list-sessions        # View active Ralph sessions
tmux attach -t <name>     # Reattach to detached session
# Ctrl+B then D           # Detach from session (keeps running)
```

---

**Ready to let AI build your project?** Start with `./install.sh` and let Ralph take it from there! 🚀