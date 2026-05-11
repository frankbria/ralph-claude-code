# Migrating

Breaking changes downstream Ralph-managed projects need to handle, in chronological order. Most recent at the top.

---

## 2026-05 — Session guard auto-upgrade (TAP-1531)

**TL;DR:** No action required. `ralph-upgrade` automatically syncs the session guard to your project on next run.

### What changed

Ralph's `on-stop.sh` Stop hook (installed in `.claude/settings.json`) now includes a guard that prevents it from mutating ralph state when invoked from an interactive Claude Code session (as opposed to a ralph autonomous loop).

### The problem it solves

Without the guard, every interactive Stop event in a ralph-managed repo would:
- Increment `.ralph/.no_status_block_count` (because interactive responses never carry a RALPH_STATUS block)
- Increment `loop_count` in `status.json`
- Accumulate `session_cost_usd` and other session metrics against zero ralph iterations
- Potentially trip the `no_status_block_3x` halt detector

**Real incident (May 2026, ralph-claude-code):** 885 interactive Stop events over several months accumulated $16,489 in false `session_cost_usd` and 885 fake loop increments, with zero actual ralph work executed. The harness had no visibility into this pollution.

### How it works

The guard uses the `RALPH_LOOP_ACTIVE` environment variable:
- `ralph_loop.sh:main()` exports `RALPH_LOOP_ACTIVE=1` before invoking Claude
- The hook checks: `if [[ "${RALPH_LOOP_ACTIVE:-}" != "1" ]]; then exit 0; fi` at startup
- When the var is unset (interactive session), the hook exits immediately (no-op)
- When the var is set to "1" (autonomous loop), the hook proceeds normally

### What you don't need to do

- **No manual edits.** The next time you run `ralph` or `ralph --upgrade`, the fix syncs automatically
- **No breaking changes.** The guard is transparent to existing autonomous workflows
- **No downtime.** Interactive sessions work unchanged; they just won't pollute ralph state anymore

### How to verify

After `ralph-upgrade` or the next loop run:

```bash
cd <your-ralph-project>
ralph-doctor
```

Look for the line: `[OK] on-stop.sh has the TAP-1531 session guard`

If you see `[FAIL]` instead, run:

```bash
ralph-upgrade
```

---

## 2026-04-28 — Legacy `-p` mode removed (always-agent-mode)

**TL;DR:** Update Claude CLI to v2.1.0 or higher, then delete two lines from your `.ralphrc`. That's it.

### What changed

Ralph used to support two CLI invocation modes:

- **Agent mode**: `claude --agent ralph` (modern; uses `.claude/agents/ralph.md` for tool/model/permissions config)
- **Legacy mode**: `claude -p <prompt> --allowedTools <list>` (older; uses `ALLOWED_TOOLS=` in `.ralphrc`)

The toggle was `RALPH_USE_AGENT` plus an auto-fallback to legacy mode whenever a project customized `ALLOWED_TOOLS`. The fallback silently dropped the agent file's `model:`, `effort:`, `maxTurns:`, and `memory:` directives, which produced real bugs (notably: NLTlabsPE running on `claude-opus-4-7` for a whole campaign because `model: sonnet` from the agent file was bypassed).

**Legacy mode is now deleted.** Ralph always invokes `claude --agent ralph`. See [ADR-0006](docs/decisions/0006-delete-legacy-mode.md) for the rationale.

### What you need to do

#### 1. Make sure your Claude CLI is v2.1.0 or higher

```bash
claude --version
# or:
npx @anthropic-ai/claude-code --version
```

If it's older, update:

```bash
claude update
# or:
npm update -g @anthropic-ai/claude-code
```

If you don't, Ralph will fail fast with a clear error on the first loop. No silent bypass.

#### 2. Delete two lines from your project's `.ralphrc`

Open `<project>/.ralphrc` and remove these lines if present:

```bash
# Delete this line entirely (and any surrounding RALPH_USE_AGENT comment block):
RALPH_USE_AGENT=true

# Delete this line entirely (and any surrounding ALLOWED_TOOLS comment block):
ALLOWED_TOOLS="Write,Read,Edit,..."
```

Ralph silently ignores both of these variables now (the bash sourcer just leaves the unused values dangling), so leaving them in place is harmless — but they're misleading clutter and you should clean up.

`RALPH_AGENT_NAME="ralph"` is **kept** if you have it. It still controls which `.claude/agents/<name>.md` file Ralph invokes.

#### 3. (Only if you customized `ALLOWED_TOOLS`) — review the agent file

Tool restrictions now live in `.claude/agents/ralph.md` (`tools:` allowlist + `disallowedTools:` blocklist) and `.claude/hooks/validate-command.sh` (destructive-pattern hard blocks).

If your `.ralphrc` had **only** the default `ALLOWED_TOOLS` value, you don't need to do anything — the agent file's defaults cover the same surface.

If you had **custom** `ALLOWED_TOOLS` entries — typically extra build tools like `Bash(uv *)`, `Bash(pytest *)`, `Bash(ruff *)`, `Bash(mypy *)`, etc. — those generally still work because the agent file's `tools:` block has `Bash` as an umbrella entry, which permits any bash command except those explicitly blocked by `disallowedTools:` or `validate-command.sh`. Smoke-test by running `ralph --dry-run` after the cleanup.

If you had **custom MCP tool entries** (e.g. specific `mcp__server__tool` names), add them to your project's `.claude/agents/ralph.md` `tools:` list:

```yaml
tools:
  - Read
  - Write
  - Edit
  # ... built-in tools ...
  - Bash
  - mcp__your-server__*       # add this
```

#### 4. (Optional cleanup) — `ralph.config.json`

If you use the JSON config form (`ralph.config.json`), remove these keys — they're ignored:

- `allowedTools` (array)
- `useAgent` (boolean)

### What you don't need to do

- **No script to run.** There is no `ralph-migrate-legacy` helper. The two-line edit is the entire migration.
- **No backup needed.** If you leave the deleted variables in `.ralphrc`, Ralph just ignores them.
- **No agent-file edit unless you customized things.** The default agent file ships with the right `tools:` and `disallowedTools:` for the common case.

### Symptoms if you skip the migration

| Symptom | Cause |
|---|---|
| `ERROR: Claude CLI does not support --agent. Update to v2.1.0+` on every loop | CLI is too old. Run `claude update`. |
| `RALPH_USE_AGENT=true` line in `.ralphrc` after upgrade | Cosmetic; not an error. Ralph ignores it. |
| Custom `ALLOWED_TOOLS` entries seemingly "lost" | Either covered by the agent's `Bash` umbrella (most common) or moved to the agent file (custom MCP tools). See step 3. |
| Old WARN messages about "falling back to legacy mode" | Those are gone too. If you see them, you're running a stale `ralph_loop.sh`. Re-run `ralph-upgrade`. |

### Rolling back

If something breaks and you need the previous behavior, the last commit on `main` with legacy mode intact is `cda7f9d`. Revert to it:

```bash
cd ~/.ralph
git checkout cda7f9d -- ralph_loop.sh templates/ralphrc.template templates/ralph.config.json lib/enable_core.sh
```

But please open an issue first — the deletion was deliberate, and patching forward is preferred over rolling back.
