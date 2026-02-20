# ============================================================================
# Ralph for Codex (rpx) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpx='ralph-loop-codex'
alias rpx.live='ralph-loop-codex --live'
alias rpx.monitor='ralph-loop-codex --monitor'
alias rpx.verbose='ralph-loop-codex --verbose'
alias rpx.hitl='ralph-loop-codex --live --monitor'

# Session management
alias rpx.continue='ralph-loop-codex --continue'
alias rpx.reset='ralph-loop-codex --reset-session'
alias rpx.status='ralph-loop-codex --status'

# Circuit breaker
alias rpx.cb.reset='ralph-loop-codex --reset-circuit'
alias rpx.cb.status='ralph-loop-codex --circuit-status'
alias rpx.cb.auto='ralph-loop-codex --auto-reset-circuit'

# Configuration variants
alias rpx.fast='ralph-loop-codex --calls 200'
alias rpx.slow='ralph-loop-codex --calls 50'
alias rpx.test='ralph-loop-codex --max-loops 1'
alias rpx.5='ralph-loop-codex --max-loops 5'
alias rpx.10='ralph-loop-codex --max-loops 10'

# Model selection
alias rpx.gpt4='ralph-loop-codex --model gpt-4'
alias rpx.gpt35='ralph-loop-codex --model gpt-3.5'
alias rpx.claude='ralph-loop-codex --model claude'

# Permission modes
alias rpx.safe='ralph-loop-codex --permission-mode auto'
alias rpx.danger='ralph-loop-codex --permission-mode dangerous'

# Worktree management
alias rpx.nowt='ralph-loop-codex --no-worktree'
alias rpx.wt.squash='ralph-loop-codex --merge-strategy squash'
alias rpx.wt.merge='ralph-loop-codex --merge-strategy merge'
alias rpx.wt.rebase='ralph-loop-codex --merge-strategy rebase'
alias rpx.wt.nogate='ralph-loop-codex --quality-gates none'

# Auto-exit control
alias rpx.autoexit='ralph-loop-codex --codex-auto-exit'
alias rpx.interactive='ralph-loop-codex --no-codex-auto-exit'

# Combined common workflows
alias rpx.dev='ralph-loop-codex --live --monitor --verbose'
alias rpx.prod='ralph-loop-codex --calls 50 --auto-reset-circuit --permission-mode dangerous'
alias rpx.debug='ralph-loop-codex --live --verbose --max-loops 1'
alias rpx.wt.full='ralph-loop-codex --live --monitor --merge-strategy squash --quality-gates auto'
alias rpx.wt.interactive='ralph-loop-codex --no-codex-auto-exit --live --monitor'

# Setup & Management
alias rpx.monitor='ralph-monitor-codex'
alias rpx.install='cd ~/.ralph/codex && ./install_codex.sh'
alias rpx.uninstall='cd ~/.ralph/codex && ./uninstall_codex.sh'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
