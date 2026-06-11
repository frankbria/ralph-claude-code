# Sandbox File Synchronization

How project files move between your host and a Ralph sandbox, and how to
control what syncs (Issue #76).

## Sync model by provider

| Provider | Strategy | How it works |
|---|---|---|
| `--sandbox docker` | **Real-time** (bind mount) | The project directory is bind-mounted read-write at `/workspace`. Every change is visible instantly in both directions. There is nothing to upload, download, or filter — sync flags are rejected for this provider. |
| `--sandbox e2b` | **Snapshot + per-iteration download** | The project uploads once at session start (tar over the E2B SDK). After **every** loop iteration, files changed in the sandbox download back to the host. Deletions and renames propagate via a manifest. |

Both directions exclude `.git` — commits made inside a sandbox are NOT synced
back; content arrives as uncommitted changes in the host working tree.
Ralph's own state (`.ralph/` dotfiles, `status.json`, logs) never syncs in
either direction, so a sandbox can never clobber the host's loop control.

## What uploads (E2B)

The upload list is built from `git ls-files` (tracked + untracked,
**`.gitignore` respected**), then filtered through, in order:

1. **`SYNC_INCLUDE`** / `--sync-include` — if set, only matching files upload
2. **`SYNC_EXCLUDE`** / `--sync-exclude` — matching files are dropped
3. **`.ralphignore`** — extra exclude patterns from the project root
4. **Large-file policy** — files over `SYNC_MAX_FILE_SIZE` (default 10MB) are
   warned about (`SYNC_LARGE_FILE_ACTION=warn`, default) or dropped (`skip`)

The `.ralph` control files (`.ralphrc`, `PROMPT.md`, `fix_plan.md`,
`AGENT.md`, `specs/`) are **always uploaded**, past any filter — the loop must
never be able to starve itself of its own prompt and plan.

## What downloads (E2B)

Files changed in the sandbox since the last sync, filtered through
`SYNC_EXCLUDE` + `.ralphignore` only. The `.ralph` control files
(`.ralphrc`, `PROMPT.md`, `fix_plan.md`, `AGENT.md`, `specs/`) bypass these
patterns on download too — a broad pattern like `*.md` must not silently
drop Claude's plan updates. Two asymmetries are deliberate:

- **Include patterns are NOT applied on download** — an artifact Claude
  creates outside your include set (a build output, a report) still comes
  back. Use exclude patterns to keep sandbox noise out.
- **The size policy is upload-only** — sandbox-side files aren't measurable
  before transfer.

Deletion safety: a host file matching an exclude pattern is **never** deleted
by deletion sync, and download-filtered files never enter the deletion
baseline — a same-named host file can't become a casualty when the sandbox
removes its copy.

## CLI flags

```bash
# Only sync source and docs up; keep logs and deps out of both directions
ralph --sandbox e2b --sync-include "src/**,tests/**,*.md" \
      --sync-exclude "*.log,node_modules"

# Sync flags require the e2b provider:
ralph --sandbox docker --sync-exclude "*.log"   # ERROR: bind mount syncs everything
```

Flags forward through `--monitor` (tmux) like all sandbox sub-flags.

## Configuration (.ralphrc)

```bash
SYNC_INCLUDE=""                   # comma-separated patterns; empty = everything
SYNC_EXCLUDE=""                   # excluded from upload AND download
SYNC_MAX_FILE_SIZE="10485760"     # bytes; 0 = unlimited
SYNC_LARGE_FILE_ACTION="warn"     # warn (keep) | skip (drop)
```

Precedence: CLI flags > environment variables > `.ralphrc` > defaults
(the same rule as every other Ralph setting).

## .ralphignore

One pattern per line in the project root (template:
`templates/.ralphignore`). The syntax is a **subset of gitignore**:

| Pattern | Matches |
|---|---|
| `name` | the basename or any whole path segment, at any depth (`node_modules` anywhere) |
| `*.ext` | glob against the basename, at any depth |
| `dir/` | the directory and everything under it (anchored only if the body contains `/`) |
| `src/**` | glob against the full relative path (`*` crosses `/`) |
| `# ...`, blank | ignored |
| `!negation` | **not supported** — dropped |

`.gitignore` already excludes its matches from upload (via `git ls-files`);
`.ralphignore` is for sync-specific exclusions you don't want in
`.gitignore`, and it also filters the download direction.

## Progress reporting

Sync operations log human-readable summaries to the loop output:

```text
Uploading 412 file(s) (2.3MB compressed) to E2B sandbox...
Uploaded 412 file(s) to E2B workspace /home/user/workspace
Synced 7 changed file(s) (18.2KB) from the E2B sandbox
Filtered 3 file(s) from sandbox download (SYNC_EXCLUDE / .ralphignore patterns)
Large file in sync: data/fixtures.bin (24.0MB > 10.0MB limit; SYNC_LARGE_FILE_ACTION=skip to drop)
```

Nothing is silently capped: skipped large files and filtered downloads are
always logged with counts.

## Troubleshooting

- **A file isn't reaching the sandbox** — check, in order: is it
  `.gitignore`d? does it match `SYNC_EXCLUDE` or `.ralphignore`? is
  `SYNC_INCLUDE` set without covering it? is it over `SYNC_MAX_FILE_SIZE`
  with `SYNC_LARGE_FILE_ACTION=skip`? Every drop except include-misses is
  logged.
- **Sandbox junk keeps syncing back** — add patterns to `.ralphignore` or
  `--sync-exclude`; the download filter drops them and logs the count.
- **Commits made in the sandbox disappear** — expected: `.git` is excluded
  both directions. Changes arrive as uncommitted host modifications; commit
  them on the host.
- **Upload is slow / huge** — check the upload summary for the size; exclude
  data directories (`.ralphignore`) or set a `SYNC_INCLUDE` allowlist.

## Out of scope (descoped to a follow-up issue)

- **Git-based sync** (push/pull through a remote) — conflicts with the
  `.git`-exclusion safety model and would require git credentials inside the
  sandbox.
- **Real-time sync for E2B** — the per-iteration download already lands
  changes at every loop boundary; a file watcher adds complexity for little
  gain in an autonomous loop.

See also: [E2B_SANDBOX.md](E2B_SANDBOX.md), [DOCKER_SANDBOX.md](DOCKER_SANDBOX.md).
