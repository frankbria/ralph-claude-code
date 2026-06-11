# E2B Cloud Sandbox Execution

`ralph --sandbox e2b` runs the Claude Code CLI inside an [E2B](https://e2b.dev)
cloud sandbox instead of on your machine (Issue #75, Phase 6.2 of the sandbox
epic #49). Use it to offload compute, get a consistent ephemeral environment,
or keep autonomous execution entirely off the host.

## Architecture

Ralph's orchestration stays on the host; only Claude's execution moves to the
cloud:

```text
HOST                                          E2B CLOUD SANDBOX (one per run)
ralph_loop.sh ── lib/e2b_helper.py exec ───▶  claude -p "..." (per iteration)
  ├─ rate limiting / circuit breaker            │ runs in /home/user/workspace
  ├─ response analysis / exit detection         ▼
  ├─ status.json (ralph-monitor)              project copy ◀── upload at start
  ├─ cost tracking / --sandbox-max-cost       changed files ── download after every loop ──▶ host
  └─ sandbox kill on exit / Ctrl+C
```

- **The E2B SDK is Python/JS only**, so all API traffic goes through
  `lib/e2b_helper.py` (a thin CLI over the official `e2b` Python package).
  `exec` streams the remote command's output and propagates its exit code, so
  both `--live` (stream-json) and background modes work unchanged.
- **One sandbox per run**, reused across iterations — E2B bills per-second,
  so per-loop creation would multiply cost and lose Claude's in-sandbox
  session state. `--sandbox-keep-alive` leaves it running for reuse via
  `--sandbox-id`.
- **File sync replaces the bind mount**: the project (tracked + untracked
  non-ignored files, plus the `.ralph` control files) is uploaded once at
  startup; files changed in the sandbox are downloaded back after every
  iteration, so progress detection, the circuit breaker, and `ralph-monitor`
  all keep working host-side. Deletions and renames propagate too: each
  download carries a manifest of the sandbox's current files, and host files
  that were previously synced but left the manifest are removed (host-only
  files, `.git`, and `.ralph` are never deletion candidates).
  What syncs is filterable — `--sync-include`/`--sync-exclude` flags, a
  `.ralphignore` file, and a large-file policy; see
  [SANDBOX_SYNC.md](SANDBOX_SYNC.md).
- **No silent fallback**: if sandbox setup fails (missing SDK, bad API key,
  unreachable API), Ralph exits with an error rather than running Claude on
  the host you asked it to protect.

## Setup

```bash
pip install e2b                                  # the official E2B Python SDK
export E2B_API_KEY="e2b_..."                     # from https://e2b.dev/dashboard
# — or store it on disk instead:
mkdir -p ~/.ralph
( umask 177 && echo "e2b_..." > ~/.ralph/e2b_api_key )

ralph --sandbox e2b
```

The Claude CLI must exist inside the sandbox. On the default `base` template
Ralph bootstraps it automatically (`npm install -g @anthropic-ai/claude-code`)
on first run; for faster startups build a custom E2B template with the CLI
preinstalled and pass it via `--sandbox-template`.

## CLI reference

| Flag | Default | Description |
|------|---------|-------------|
| `--sandbox e2b` | (off) | Enable E2B cloud sandbox execution |
| `--sandbox-template T` | `base` | E2B template name (custom templates can preinstall claude) |
| `--sandbox-id ID` | (new sandbox) | Reconnect to an existing sandbox (pairs with `--sandbox-keep-alive`) |
| `--sandbox-timeout SECS` | `3600` | Sandbox session timeout; an expired sandbox is recreated and re-uploaded automatically |
| `--sandbox-keep-alive` | (off) | Leave the sandbox running on exit (billing continues!) |
| `--sandbox-max-cost USD` | (none) | Stop the loop gracefully once the estimated cost reaches this amount |
| `--sandbox-cost-alert USD` | (none) | Warn once when the estimated cost reaches this amount |

`daytona` and `cloudflare` providers are planned (issues #79, #80) and
currently rejected with a clear error. The Docker sub-flags
(`--sandbox-image`, ...) pair only with `--sandbox docker`, and the E2B
sub-flags only with `--sandbox e2b` — mixing them is a startup error.

`.ralphrc` equivalents (CLI flags override; the API key itself never goes in
`.ralphrc`):

```bash
SANDBOX_PROVIDER="e2b"
SANDBOX_E2B_TEMPLATE="base"
SANDBOX_E2B_TIMEOUT="3600"
SANDBOX_E2B_KEEP_ALIVE="false"
SANDBOX_E2B_MAX_COST="5.00"
SANDBOX_E2B_COST_ALERT="2.00"
SANDBOX_E2B_COST_PER_HOUR="0.10"
```

Environment variables of the same names take precedence over `.ralphrc`, and
`--monitor` (tmux) forwards all sandbox flags to the loop pane.

## Credentials

Two independent secrets, neither of which ever appears on a command line:

**E2B API key** (`setup_e2b_credentials`):
1. `E2B_API_KEY` environment variable, or
2. `~/.ralph/e2b_api_key` (a warning is logged unless it is `chmod 600`).

**Claude authentication inside the sandbox** (`_seed_e2b_claude_credentials`,
mirroring the Docker provider):
1. **`ANTHROPIC_API_KEY` set** — passed to the sandbox as an environment
   variable at creation time (the helper reads it from its own environment).
2. **Host `~/.claude/.credentials.json` exists** — *copied* into the sandbox
   home over stdin (`chmod 600` remotely). The host file is never modified.
3. **Neither** — a warning is logged and the loop continues (useful for
   custom templates with authentication baked in).

## Cost tracking

E2B bills per second of sandbox runtime. Ralph estimates spend as the sum of
all sandbox segments (active runtime + any prior segments from sandboxes that
were recreated after session expiry) × `SANDBOX_E2B_COST_PER_HOUR` (default
`$0.10/h` — adjust to your template size using
[e2b.dev/pricing](https://e2b.dev/pricing)). Cost accrued by a replaced
sandbox is folded into `accrued_cost` in `.ralph/.e2b_sandbox_state` before
the epoch resets, so `--sandbox-max-cost` spans the entire run, not just the
current sandbox segment:

- The running estimate appears in `status.json` (`sandbox.estimated_cost`)
  and the `ralph-monitor` Sandbox panel.
- `--sandbox-cost-alert` logs a single warning at the threshold.
- `--sandbox-max-cost` stops the loop gracefully (final artifact sync, then
  sandbox kill) with exit reason `e2b_cost_limit`.
- Every run appends a summary line to `.ralph/logs/e2b_cost.log`.

This is an **estimate** for budget control, not a bill — check the E2B
dashboard for actual usage.

## Lifecycle and failure handling

- **Startup**: `init_e2b_sandbox` (config validation, SDK availability, API
  key resolution) → `start_e2b_sandbox` (create or `--sandbox-id` connect,
  credential seeding, project upload, claude bootstrap check). Any failure
  aborts the run.
- **Per iteration**: the built Claude command array is wrapped as
  `python3 lib/e2b_helper.py exec --sandbox-id <id> --cwd /home/user/workspace
  -- claude ...`; after every iteration (success, failure, or timeout) changed
  files are downloaded and the deletion pass runs before progress detection.
  The sandbox-side sync marker is advanced only after host extraction and the
  deletion pass both succeed (`ack-download` subcommand) — a missed ack simply
  re-delivers the same changes on the next iteration (idempotent overwrite,
  at-least-once delivery).
- **Session expiry**: E2B kills sandboxes at their session timeout. The
  pre-exec liveness probe detects this and starts a replacement (fresh create
  + re-upload) automatically.
- **Timeout (exit 124)**: the host-side timeout kills only the local helper
  client; orphaned `claude` processes are killed remotely (`pkill`) before the
  next iteration.
- **Exit**: final artifact sync, then the sandbox is killed (billing stops) —
  on graceful completion, circuit-breaker halt, cost limit, errors, and
  SIGINT/SIGTERM. With `--sandbox-keep-alive` the sandbox is left running and
  its id is logged for reuse. Cleanup is idempotent.
- **State**: `.ralph/.e2b_sandbox_state` (JSON, atomic temp+`mv` writes)
  tracks template, sandbox id, status, `estimated_cost`, and `accrued_cost`
  (cost folded in from prior sandbox segments on recreation);
  `.ralph/.e2b_synced_files` is the deletion-sync baseline (the set of
  project paths known to exist in the sandbox).

## Known limitations

- **Commits made inside the sandbox are not synced back.** Sync is
  file-content based and `.git` is excluded in both directions (a sandbox-side
  git state must never clobber the host repository). Claude's changes arrive
  as uncommitted modifications in the host working tree; commit them host-side
  or let the next host-side tool do it.
- **Network restriction is not configurable** — E2B sandboxes have outbound
  internet access by default (which the Claude API needs anyway). Security
  policies are Issue #78's scope.
- The first run on a plain template pays the `npm install -g` bootstrap cost;
  use a custom template to avoid it.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `E2B SDK unavailable ... pip install e2b` | `pip install e2b` (into the python3 environment Ralph uses) |
| `E2B API key not found` | `export E2B_API_KEY=...` or create `~/.ralph/e2b_api_key` (chmod 600) |
| `Claude Code CLI is unavailable in the E2B sandbox` | Build a custom E2B template with `@anthropic-ai/claude-code` preinstalled and pass `--sandbox-template` |
| Claude auth errors inside the sandbox | Export `ANTHROPIC_API_KEY`, or log in on the host first so `~/.claude/.credentials.json` exists |
| Loop stops with `e2b_cost_limit` | Expected — raise `--sandbox-max-cost` or fix `SANDBOX_E2B_COST_PER_HOUR` if your template rate differs |
| Orphaned sandbox after a hard kill (`kill -9`) | It expires at `--sandbox-timeout`; kill it sooner from the E2B dashboard |
