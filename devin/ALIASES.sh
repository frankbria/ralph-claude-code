# ============================================================================
# Ralph for Devin (rpd) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpd='ralph-devin'
alias rpd.live='ralph-devin --live'
alias rpd.monitor='ralph-devin --monitor'
alias rpd.verbose='ralph-devin --verbose'
alias rpd.hitl='ralph-devin --live --monitor'

# Session management
alias rpd.continue='ralph-devin --continue'
alias rpd.reset='ralph-devin --reset-session'
alias rpd.status='ralph-devin --status'

# Circuit breaker
alias rpd.cb.reset='ralph-devin --reset-circuit'
alias rpd.cb.status='ralph-devin --circuit-status'
alias rpd.cb.auto='ralph-devin --auto-reset-circuit'

# Configuration variants
alias rpd.fast='ralph-devin --calls 200'
alias rpd.slow='ralph-devin --calls 50'
alias rpd.test='ralph-devin --max-loops 1'
alias rpd.5='ralph-devin --max-loops 5'
alias rpd.10='ralph-devin --max-loops 10'

# Model selection
alias rpd.opus='ralph-devin --model opus'
alias rpd.sonnet='ralph-devin --model sonnet'
alias rpd.swe='ralph-devin --model swe'
alias rpd.gpt='ralph-devin --model gpt'

# Permission modes
alias rpd.safe='ralph-devin --permission-mode auto'
alias rpd.danger='ralph-devin --permission-mode dangerous'

# Worktree management
alias rpd.nowt='ralph-devin --no-worktree'
alias rpd.wt.squash='ralph-devin --merge-strategy squash'
alias rpd.wt.merge='ralph-devin --merge-strategy merge'
alias rpd.wt.rebase='ralph-devin --merge-strategy rebase'
alias rpd.wt.nogate='ralph-devin --quality-gates none'

# Auto-exit control
alias rpd.autoexit='ralph-devin --devin-auto-exit'
alias rpd.int='ralph-devin --no-devin-auto-exit'

# Parallel mode (spawns N agents: iTerm2 tabs from iTerm, IDE terminal tabs from Windsurf/VS Code/Cursor)
# Usage: rpd.int.p 3  -> spawns 3 parallel devin agents
rpd.int.p() { ralph-devin --no-devin-auto-exit --parallel "${1:?Usage: rpd.int.p <number>}"; }

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpd.int.p.b 3  -> spawns 3 parallel devin agents in background
rpd.int.p.b() { ralph-devin --no-devin-auto-exit --parallel-bg "${1:?Usage: rpd.int.p.b <number>}"; }

# Combined common workflows
alias rpd.dev='ralph-devin --live --monitor --verbose'
alias rpd.prod='ralph-devin --calls 50 --auto-reset-circuit --permission-mode dangerous'
alias rpd.debug='ralph-devin --live --verbose --max-loops 1'
alias rpd.wt.full='ralph-devin --live --monitor --merge-strategy squash --quality-gates auto'
alias rpd.wt.int='ralph-devin --no-devin-auto-exit --live --monitor'

# Setup & Management
alias rpd.monitor='ralph-monitor-devin'
alias rpd.install='(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./install_devin.sh)'
alias rpd.uninstall='(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./uninstall_devin.sh)'

# Planning mode (AI-powered, uses devin engine)
alias rpd.plan='ralph-plan --engine devin'

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
alias ralph.plan='ralph-plan'
