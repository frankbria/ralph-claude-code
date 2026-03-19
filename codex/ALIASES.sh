# ============================================================================
# Ralph for Codex (rpx) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpx='ralph-codex'
alias rpx.live='ralph-codex --live'
alias rpx.monitor='ralph-codex --monitor'
alias rpx.verbose='ralph-codex --verbose'
alias rpx.hitl='ralph-codex --live --monitor'

# Session management
alias rpx.continue='ralph-codex --continue'
alias rpx.reset='ralph-codex --reset-session'
alias rpx.status='ralph-codex --status'

# Circuit breaker
alias rpx.cb.reset='ralph-codex --reset-circuit'
alias rpx.cb.status='ralph-codex --circuit-status'
alias rpx.cb.auto='ralph-codex --auto-reset-circuit'

# Configuration variants
alias rpx.fast='ralph-codex --calls 200'
alias rpx.slow='ralph-codex --calls 50'
alias rpx.test='ralph-codex --max-loops 1'
alias rpx.5='ralph-codex --max-loops 5'
alias rpx.10='ralph-codex --max-loops 10'

# Model selection
alias rpx.gpt4='ralph-codex --model gpt-4'
alias rpx.gpt35='ralph-codex --model gpt-3.5'
alias rpx.claude='ralph-codex --model claude'

# Permission modes
alias rpx.safe='ralph-codex --permission-mode auto'
alias rpx.danger='ralph-codex --permission-mode dangerous'

# Worktree management
alias rpx.nowt='ralph-codex --no-worktree'
alias rpx.wt.squash='ralph-codex --merge-strategy squash'
alias rpx.wt.merge='ralph-codex --merge-strategy merge'
alias rpx.wt.rebase='ralph-codex --merge-strategy rebase'
alias rpx.wt.nogate='ralph-codex --quality-gates none'

# Auto-exit control
alias rpx.autoexit='ralph-codex --codex-auto-exit'
alias rpx.int='ralph-codex --no-codex-auto-exit'

# Parallel mode (spawns N agents: iTerm2 tabs from iTerm, IDE terminal tabs from Windsurf/VS Code/Cursor)
# Usage: rpx.int.p 3  -> spawns 3 parallel codex agents
rpx.int.p() { ralph-codex --no-codex-auto-exit --parallel "${1:?Usage: rpx.int.p <number>}"; }

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpx.int.p.b 3  -> spawns 3 parallel codex agents in background
rpx.int.p.b() { ralph-codex --no-codex-auto-exit --parallel-bg "${1:?Usage: rpx.int.p.b <number>}"; }

# Combined common workflows
alias rpx.dev='ralph-codex --live --monitor --verbose'
alias rpx.prod='ralph-codex --calls 50 --auto-reset-circuit --permission-mode dangerous'
alias rpx.debug='ralph-codex --live --verbose --max-loops 1'
alias rpx.wt.full='ralph-codex --live --monitor --merge-strategy squash --quality-gates auto'
alias rpx.wt.int='ralph-codex --no-codex-auto-exit --live --monitor'

# Setup & Management
alias rpx.monitor='ralph-monitor-codex'
alias rpx.install='(cd ~/Projects/Tools-Utilities/ai-ralph/codex && ./install_codex.sh)'
alias rpx.uninstall='(cd ~/Projects/Tools-Utilities/ai-ralph/codex && ./uninstall_codex.sh)'

# Planning mode (AI-powered, uses codex engine)
alias rpx.plan='ralph-plan --engine codex'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
alias ralph.plan='ralph-plan'
