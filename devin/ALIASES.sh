# ============================================================================
# Ralph for Devin (rpd) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpd='ralph-loop-devin'
alias rpd.live='ralph-loop-devin --live'
alias rpd.monitor='ralph-loop-devin --monitor'
alias rpd.verbose='ralph-loop-devin --verbose'
alias rpd.hitl='ralph-loop-devin --live --monitor'

# Session management
alias rpd.continue='ralph-loop-devin --continue'
alias rpd.reset='ralph-loop-devin --reset-session'
alias rpd.status='ralph-loop-devin --status'

# Circuit breaker
alias rpd.cb.reset='ralph-loop-devin --reset-circuit'
alias rpd.cb.status='ralph-loop-devin --circuit-status'
alias rpd.cb.auto='ralph-loop-devin --auto-reset-circuit'

# Configuration variants
alias rpd.fast='ralph-loop-devin --calls 200'
alias rpd.slow='ralph-loop-devin --calls 50'
alias rpd.test='ralph-loop-devin --max-loops 1'
alias rpd.5='ralph-loop-devin --max-loops 5'
alias rpd.10='ralph-loop-devin --max-loops 10'

# Model selection
alias rpd.opus='ralph-loop-devin --model opus'
alias rpd.sonnet='ralph-loop-devin --model sonnet'
alias rpd.swe='ralph-loop-devin --model swe'
alias rpd.gpt='ralph-loop-devin --model gpt'

# Permission modes
alias rpd.safe='ralph-loop-devin --permission-mode auto'
alias rpd.danger='ralph-loop-devin --permission-mode dangerous'

# Worktree management
alias rpd.nowt='ralph-loop-devin --no-worktree'
alias rpd.wt.squash='ralph-loop-devin --merge-strategy squash'
alias rpd.wt.merge='ralph-loop-devin --merge-strategy merge'
alias rpd.wt.rebase='ralph-loop-devin --merge-strategy rebase'
alias rpd.wt.nogate='ralph-loop-devin --quality-gates none'

# Auto-exit control
alias rpd.autoexit='ralph-loop-devin --devin-auto-exit'
alias rpd.int='ralph-loop-devin --no-devin-auto-exit'

# Combined common workflows
alias rpd.dev='ralph-loop-devin --live --monitor --verbose'
alias rpd.prod='ralph-loop-devin --calls 50 --auto-reset-circuit --permission-mode dangerous'
alias rpd.debug='ralph-loop-devin --live --verbose --max-loops 1'
alias rpd.wt.full='ralph-loop-devin --live --monitor --merge-strategy squash --quality-gates auto'
alias rpd.wt.int='ralph-loop-devin --no-devin-auto-exit --live --monitor'

# Setup & Management
alias rpd.monitor='ralph-monitor-devin'
alias rpd.install='cd ~/.ralph/devin && ./install_devin.sh'
alias rpd.uninstall='cd ~/.ralph/devin && ./uninstall_devin.sh'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
