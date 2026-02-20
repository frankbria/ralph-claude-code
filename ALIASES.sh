# ============================================================================
# Ralph for Claude Code (rpc) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpc='ralph-loop'
alias rpc.live='ralph-loop --live'
alias rpc.monitor='ralph-loop --monitor'
alias rpc.verbose='ralph-loop --verbose'
alias rpc.hitl='ralph-loop --live --monitor'

# Session management
alias rpc.continue='ralph-loop --continue'
alias rpc.reset='ralph-loop --reset-session'
alias rpc.status='ralph-loop --status'

# Circuit breaker
alias rpc.cb.reset='ralph-loop --reset-circuit'
alias rpc.cb.status='ralph-loop --circuit-status'
alias rpc.cb.auto='ralph-loop --auto-reset-circuit'

# Configuration variants
alias rpc.fast='ralph-loop --calls 200'
alias rpc.slow='ralph-loop --calls 50'
alias rpc.test='ralph-loop --max-loops 1'
alias rpc.5='ralph-loop --max-loops 5'
alias rpc.10='ralph-loop --max-loops 10'

# Model selection
alias rpc.opus='ralph-loop --model opus'
alias rpc.sonnet='ralph-loop --model sonnet'

# Output formats
alias rpc.json='ralph-loop --output-format json'
alias rpc.text='ralph-loop --output-format text'

# Combined common workflows
alias rpc.dev='ralph-loop --live --monitor --verbose'
alias rpc.prod='ralph-loop --calls 50 --auto-reset-circuit'
alias rpc.debug='ralph-loop --live --verbose --max-loops 1'

# Setup & Management
alias rpc.monitor='ralph-monitor'
alias rpc.install='cd ~/Projects/Tools-Utilities/ai-ralph && ./install.sh'
alias rpc.uninstall='cd ~/Projects/Tools-Utilities/ai-ralph && ./uninstall.sh'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
