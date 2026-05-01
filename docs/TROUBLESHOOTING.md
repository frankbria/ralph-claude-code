---
title: Troubleshooting
description: Solutions for common Ralph runtime failures and diagnostic procedures.
audience: [user, operator]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Troubleshooting

If you're hitting a problem, find the closest match below, try the fix, then run the diagnostic in [Collecting diagnostics](#collecting-diagnostics) if it persists. For a map of every known failure mode, see [FAILURE.md](../FAILURE.md).

## Startup and installation

### `ralph: command not found`

`~/.local/bin` is not on your `$PATH`.

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
ralph --version
```

On WSL, repeat for `~/.zshrc` if you use zsh.

### `bash: $'\r': command not found` on WSL

Line-ending drift from a Windows checkout.

```bash
sed -i 's/\r$//' install.sh ralph_loop.sh lib/*.sh
git config core.autocrlf input
git rm --cached -r .
git reset --hard
```

### `jq: command not found`

```bash
# Let the installer bootstrap a static jq
./install.sh   # downloads jq into ~/.local/bin/jq on Linux/macOS

# Or install a system package
sudo apt install jq            # Debian/Ubuntu
brew install jq                # macOS
```

To skip the bootstrap and force a system package, set `RALPH_SKIP_JQ_BOOTSTRAP=1` before running `install.sh`.

### `timeout: command not found` (macOS)

```bash
brew install coreutils
# Ralph's timeout_utils.sh will auto-detect gtimeout
```

### `Bash version must be 4.0 or later`

macOS ships with Bash 3.2. Install a current version:

```bash
brew install bash
# Then either set Ralph's shebang env, or:
export SHELL=/opt/homebrew/bin/bash
```

### Claude CLI not found

```bash
npm install -g @anthropic-ai/claude-code
which claude    # should be on your PATH
ralph-doctor    # comprehensive dependency check
```

If Claude is installed but not detected, set `CLAUDE_CODE_CMD` in `.ralphrc`:

```bash
CLAUDE_CODE_CMD="/usr/local/bin/claude"
```

### `.zshrc` paths not picked up

Ralph sources shell rc files and checks `nvm`/`fnm`/`volta` before the "CLI not found" error fires. If it still misses your Claude install, add the full path to `.ralphrc`.

## Loop behavior

### Ralph exits immediately on first loop

Likely causes (in order of likelihood):

1. **Empty fix_plan.md** — pre-flight check skipped the invocation. Add tasks.
2. **Claude CLI not installed** — see above.
3. **Hook crash** — check `tail -50 .ralph/logs/ralph.log` for `hook returned non-zero`.

### Ralph exits "too early" — work isn't done

The dual-condition exit gate requires **both** Claude's `EXIT_SIGNAL: true` and `completion_indicators >= 2`. If Ralph still exits prematurely:

```bash
# Inspect the last status.json
jq . .ralph/status.json

# Inspect rolling exit signals
cat .ralph/.exit_signals

# If exit_signal was true but tasks remain, the PROMPT.md or spec is
# underspecified — Claude thinks it's done. Tighten the instructions.
```

Make sure your PROMPT.md explicitly tells Claude not to emit `EXIT_SIGNAL: true` while unchecked `- [ ]` items remain in `fix_plan.md`.

### Ralph keeps running tests but never implements anything

Your `fix_plan.md` tasks are too vague. Rewrite with specific, actionable items. See [docs/user-guide/03-writing-requirements.md](user-guide/03-writing-requirements.md) for examples.

### Ralph keeps hitting the same error

Circuit breaker will trip after `CB_NO_PROGRESS_THRESHOLD` (default 3) consecutive iterations without progress.

```bash
# See the failure history
cat .ralph/.circuit_breaker_events | jq .

# Reset when you've addressed the root cause
ralph --reset-circuit

# Or enable auto-recovery between runs
echo 'CB_AUTO_RESET=true' >> .ralphrc
```

If the CB keeps tripping on the same signal, check if Claude is emitting `EXIT_SIGNAL: true && STATUS: COMPLETE` with zero files modified — the `EXIT-CLEAN` branch should catch this, but if you're running an older hook copy, run `ralph-upgrade` first.

### `grep -c | echo "0"` corruption in status.json

Historical bug where the shell idiom `count=$(grep -c PAT || echo "0")` produced `"0\n0"`, corrupting the JSON. Fix: the current `templates/hooks/on-stop.sh` pipes through `tr -cd '0-9'`. Older project hooks need `ralph-upgrade`:

```bash
ralph-upgrade           # or: ralph-upgrade-project
ralph-doctor            # verify hooks match templates
```

### Permission denied for a tool

```bash
# Ralph logged the denied command — find the last one
grep -E 'permission|denied' .ralph/logs/ralph.log | tail -5

# Edit .claude/agents/ralph.md — either widen the tools: allowlist or
# remove the matching pattern from disallowedTools:. For destructive
# patterns hard-blocked by .claude/hooks/validate-command.sh, edit that
# hook instead. Then reset the session so Claude re-reads permissions:
ralph --reset-session
```

## Rate limits and API

### 5-hour API limit hit

Ralph auto-detects this and prints a countdown. To skip the wait and exit:

```bash
# Press Ctrl+C during the countdown
# Ralph cleans up and exits with code 1
```

### Token budget exceeded

```bash
# View token usage
ralph --stats
ralph --cost-dashboard

# Cap per-hour tokens
echo 'MAX_TOKENS_PER_HOUR=500000' >> .ralphrc
```

### Rate limit counter stuck

Counter files got corrupted:

```bash
rm .ralph/.call_count .ralph/.last_reset .ralph/.token_count
ralph --reset-session
```

## Session and state

### Session expired

```bash
ralph --reset-session
```

Sessions expire after 24 hours (configurable via `SESSION_EXPIRY_HOURS`). This is intentional — research shows agent success drops after ~35 minutes. See **Continue-As-New** in [ARCHITECTURE.md](ARCHITECTURE.md#session-continuity).

### status.json is corrupt or missing

```bash
# Validate
jq . .ralph/status.json

# Remove and let the next loop recreate
rm -f .ralph/status.json
ralph
```

### Circuit breaker file corrupt

The stop hook self-heals this since TAP-538 — it reinitializes to CLOSED with a WARN. If you're on an older copy:

```bash
echo '{"state":"CLOSED","consecutive_no_progress":0}' > .ralph/.circuit_breaker_state
ralph-upgrade   # update to current hooks
```

## Monitoring and display

### Monitor shows `(executing...)` indefinitely

The current loop is running. Expected during the 3-10 min Claude invocation window. If it stays that way after 15+ minutes, the Claude call may be hung — kill with Ctrl+C.

### Monitor shows `in 0, out 0, $0.0000`

Token extraction failed (TAP-662). Likely causes:

1. Claude CLI version doesn't emit `usage` blocks in the format `on-stop.sh` expects
2. Stream log got truncated

Upgrade Claude CLI and Ralph:

```bash
npm install -g @anthropic-ai/claude-code
./install.sh upgrade      # from ralph-claude-code checkout
```

### Monitor shows "LIKELY DEAD"

`status.json` is older than `MONITOR_STALE_DEAD_SECS` (default 120) seconds. The loop crashed or is stuck. Check:

```bash
ps -ef | grep ralph_loop
tail -50 .ralph/logs/ralph.log
tail -20 .ralph/logs/claude_output_$(date +%Y%m%d).log
```

### tmux session not starting

```bash
tmux --version    # need 2.0+
which tmux

# Start manually
tmux new-session -d -s ralph
ralph --live
```

## WSL and Windows

### Version divergence warning at startup

You have two Ralph installs — one under WSL `~/.ralph/`, one under `/mnt/c/Users/*/.ralph/` — at different versions.

```bash
# Reinstall both from the same checkout
cd ralph-claude-code
./install.sh upgrade
```

### PowerShell hooks fail under WSL

Bare `powershell` is Windows-only; WSL needs `powershell.exe`. Ralph auto-patches this in-place since XPLAT-2b. If you see the error:

```bash
# Trigger the auto-patch by re-validating
ralph-doctor
```

### Monitor fails with `powershell not found`

```bash
# Verify .claude/settings.json hooks don't reference bare `powershell`
grep -n powershell .claude/settings.json
# All matches should be `powershell.exe`
```

## Linear backend

### `linear_api_error: op=... reason=no_api_key`

This message is expected on iteration 1 of a Linear-mode session — the harness reads counts from `.ralph/status.json`, which Claude populates via the on-stop hook from its `RALPH_STATUS` block. Iteration 2 onwards reads fresh counts and the message goes silent.

If the message persists past iteration 1, confirm the Linear MCP plugin is enabled in your Claude Code session (OAuth-via-MCP is the only supported mode) and that Claude is including `LINEAR_OPEN_COUNT` / `LINEAR_DONE_COUNT` in its `RALPH_STATUS` block.

### Linear exit gate never fires

The push-mode check abstains when counts are missing or stale. Verify Claude is emitting `LINEAR_OPEN_COUNT` / `LINEAR_DONE_COUNT` in RALPH_STATUS:

```bash
jq '.linear_open_count, .linear_done_count, .linear_counts_at' .ralph/status.json
```

If `null` or stale, update your `PROMPT.md` to remind Claude to include the counts. See [LINEAR-WORKFLOW.md](LINEAR-WORKFLOW.md).

### Linear backend picks a new ticket when one's In Progress

Fixed in v2.8.3+ (`linear_get_in_progress_task`). Upgrade:

```bash
./install.sh upgrade
```

## MCP servers

### Ralph hangs on startup probing MCPs

Fixed in v2.8.3+: the probe uses a temp file plus `--kill-after` so orphaned MCP children can't block indefinitely. Upgrade to v2.8.3+.

### MCP server not reachable

```bash
ralph --mcp-status    # shows which probes succeeded

# For tapps-brain (HTTP-based):
curl -s http://127.0.0.1:8080/health
```

MCP servers are registered **by the project**, not by Ralph. Check `.mcp.json`:

```bash
jq '.mcpServers | keys' .mcp.json
```

### tapps-brain probe returns 403 even though `claude mcp list` shows ✓ Connected (TAP-1105)

The `TAPPS_BRAIN_AUTH_TOKEN` in `~/.ralph/secrets.env` is stale — the brain container was rebuilt with a fresh token and the local file wasn't updated. Linear MCP plugin auth uses a different path so `claude mcp list` stays green; that's why the two disagree.

```bash
docker exec tapps-brain-http env | grep TAPPS_BRAIN_AUTH_TOKEN  # canonical value
$EDITOR ~/.ralph/secrets.env                                     # paste the new value
ralph --mcp-status                                               # confirm: tapps-brain: true
```

### tapps-mcp rejects every tool call

Permission issue in Claude Code:

```json
// .claude/settings.json
{
  "permissions": {
    "allow": [
      "mcp__tapps-mcp",
      "mcp__tapps-mcp__*"
    ]
  }
}
```

Both entries are required — the bare one as a fallback.

## Docker sandbox

### `ralph --sandbox` fails with `docker: permission denied`

```bash
# Add user to docker group (preferred)
sudo usermod -aG docker "$USER"
newgrp docker

# Or use rootless Docker — Ralph auto-detects
dockerd-rootless-setuptool.sh install
```

### Container can't reach the network

Intentional — Ralph defaults to `--network none` for the sandbox. Override with `RALPH_SANDBOX_NETWORK=bridge` if you need egress (but understand the security tradeoff).

## Tests and CI

### Tests pass locally, fail in CI

```bash
# Match the CI environment
nvm use 18
npm ci   # not npm install
npm run test:unit
npm run test:integration    # hard-fails since TAP-537 (no more || true)
```

See [TESTING.md](../TESTING.md#local-vs-ci-differences) for the full parity checklist.

### `test_settings_json.bats` fails after editing hooks

Guard against the TAP-656 regression. Re-validate `.claude/settings.json`:

```bash
jq . .claude/settings.json
# No trailing backslashes in matchers, no tool names as commands,
# no pipe-separator statusMessages, entry counts match the test
```

## Upgrades

### After `ralph-upgrade`, managed projects still use old behavior

`ralph-upgrade` updates the global install. To propagate new hooks/templates to an existing managed project:

```bash
cd my-project
ralph-upgrade-project    # syncs .ralph/hooks/ and templates
ralph-doctor             # verify no drift vs templates
```

Since TAP-730, the upgrader can overwrite read-only (mode 555) hook files.

### `ralph-doctor` reports hook drift

```bash
cd my-project
ralph-upgrade-project

# If drift persists, the hook file was manually edited — either accept the
# template or keep your copy. Drift is a warning, not a blocker.
```

## Collecting diagnostics

When opening an issue, attach the output of:

```bash
ralph --version
ralph-doctor
ralph --mcp-status
jq . .ralph/status.json
tail -100 .ralph/logs/ralph.log
ls -lt .ralph/logs/claude_output_*.log | head -3
cat .ralph/.circuit_breaker_state
```

For intermittent loop crashes, also include:

```bash
# Last 200 lines of the most recent raw Claude output
last_log=$(ls -t .ralph/logs/claude_output_*.log | head -1)
tail -200 "$last_log"
```

## Still stuck?

- **[FAILURE.md](../FAILURE.md)** — every known failure mode
- **[FAILSAFE.md](../FAILSAFE.md)** — safe defaults and degradation
- **[GLOSSARY.md](GLOSSARY.md)** — terminology cheat sheet
- **[GitHub Issues](https://github.com/wtthornton/ralph-claude-code/issues)** — report a bug
