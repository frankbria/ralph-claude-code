# ============================================================================
# Ralph for Claude Code (rpc) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpc='ralph'
alias rpc.live='ralph --live'
alias rpc.monitor='ralph --monitor'
alias rpc.verbose='ralph --verbose'
alias rpc.hitl='ralph --live --monitor'

# Session management
alias rpc.continue='ralph --continue'
alias rpc.reset='ralph --reset-session'
alias rpc.status='ralph --status'

# Circuit breaker
alias rpc.cb.reset='ralph --reset-circuit'
alias rpc.cb.status='ralph --circuit-status'
alias rpc.cb.auto='ralph --auto-reset-circuit'

# Configuration variants
alias rpc.fast='ralph --calls 200'
alias rpc.slow='ralph --calls 50'
alias rpc.test='ralph --max-loops 1'
alias rpc.5='ralph --max-loops 5'
alias rpc.10='ralph --max-loops 10'

# Model selection
alias rpc.opus='ralph --model opus'
alias rpc.sonnet='ralph --model sonnet'

# Output formats
alias rpc.json='ralph --output-format json'
alias rpc.text='ralph --output-format text'

# Combined common workflows
alias rpc.dev='ralph --live --monitor --verbose'
alias rpc.prod='ralph --calls 50 --auto-reset-circuit'
alias rpc.debug='ralph --live --verbose --max-loops 1'

# Setup & Management
alias rpc.monitor='ralph-monitor'
alias rpc.install='(cd ~/Projects/Tools-Utilities/ai-ralph && ./install.sh)'
alias rpc.uninstall='(cd ~/Projects/Tools-Utilities/ai-ralph && ./uninstall.sh)'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
