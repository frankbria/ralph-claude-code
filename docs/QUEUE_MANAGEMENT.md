# Batch Processing and Issue Queue Management

Ralph can work through multiple GitHub issues (or local PRD specs) in one
autonomous session using a persistent, priority- and dependency-aware queue.
This guide covers building, managing, and processing that queue.

> Introduced in Issue #72. Requires the GitHub CLI (`gh`) and `jq` for the
> GitHub-issue paths; the PRD path needs neither.

## Concepts

- **Queue file** — `.ralph/queue.json` in the current Ralph project. It is the
  single source of truth and persists across restarts, so an interrupted run
  can be resumed. It is created automatically the first time you add an item.
- **Item** — one unit of work. A *github* item carries the issue number,
  title, priority, labels, milestone, and parsed dependencies. A *prd* item
  carries a path to a local spec file and a derived title.
- **Status** — each item is `pending`, `processing`, `completed`, `failed`,
  or `skipped`.
- **Priority** — read from `P0`–`P9` or `priority: PN` labels (lower number =
  higher priority). Items without a priority label sort last.
- **Dependencies** — parsed from the issue body via `depends on #N`,
  `blocked by #N`, and `requires #N` (case-insensitive). An item only becomes
  *ready* once every dependency it references in the queue is `completed`.

## Building a queue

`ralph-queue add` accepts three kinds of sources.

```bash
# 1) Metadata filters — reuses the same flags as `ralph-import`
ralph-queue add --github-label "bug,P0"            # ALL labels (comma = AND)
ralph-queue add --github-milestone "v1.0"
ralph-queue add --github-search "login timeout"
ralph-queue add --github-title "[P0]*"             # * is the only wildcard
ralph-queue add --github-assignee @me              # or a username, or none
ralph-queue add --github-label bug --exclude-label wontfix
ralph-queue add --github-state all                 # open (default), closed, all
ralph-queue add --github-label bug --repo owner/repo

# 2) Explicit issue numbers
ralph-queue add --github-issues 69,70,71

# 3) A local PRD/spec file
ralph-queue add --prd ./docs/feature.md
```

Adding is idempotent — an item already in the queue (matched by id) is skipped
with a warning, so re-running a filter add only appends what's new.

## Managing the queue

```bash
ralph-queue status            # Human-readable table of items + counts
ralph-queue status --json     # { total, pending, processing, completed, failed, skipped }
ralph-queue next              # Print the id of the next ready item (or exit 1)
ralph-queue reorder           # Persist a priority sort (P0 first, FIFO within a tier)
ralph-queue validate          # Exit non-zero if a circular dependency exists
ralph-queue remove 69         # Remove by issue number or id (e.g. github-69, prd-feature-md)
ralph-queue clear             # Remove every item
```

The most common queries are mirrored on the `ralph` command itself:

```bash
ralph --queue-status
ralph --queue-next
ralph --queue-clear
ralph --queue-remove 69
```

## Processing the queue

```bash
ralph --process-queue                  # or: ralph-queue process
ralph --process-queue --halt-on-failure
ralph --resume-queue                   # continue with the remaining pending items
```

For each ready item, in priority then FIFO order, the processor:

1. Marks the item `processing`.
2. Stages the project from the source — for a GitHub issue it writes
   `.ralph/specs/issue-<N>.md` and points `.ralph/fix_plan.md` at it; for a PRD
   it copies the spec into `.ralph/specs/`.
3. Runs the Ralph loop (`ralph_loop.sh`) until it exits.
4. On success, commits the work as `Fix #N: <title>` (one commit per issue,
   when the project is a git repo) and marks the item `completed`.
5. On a non-zero loop exit, marks the item `failed` and either skips it
   (default) or halts the whole run (`--halt-on-failure`).
6. Re-evaluates dependencies and moves to the next ready item.

Items whose dependencies never complete stay `pending` and are reported at the
end of the run. Resuming simply re-runs `process`: completed and failed items
are left alone, and only ready `pending` items are picked up. Any item left in
`processing` by an interrupted run (SIGKILL, power loss) is reset to `pending`
at the start of the next `process`/`resume` so it is retried.

Two things to know about processing:

- **GitHub connectivity is needed at process time.** Each GitHub item is
  re-fetched when it is processed (to use the freshest issue body), so
  `process` requires `gh` access even when the items are already in
  `queue.json`.
- **PROMPT.md may gain a security fence.** If the project's `.ralph/PROMPT.md`
  predates the "Handling Spec Content" untrusted-input fence, the processor
  appends it (once) so the trust boundary described above is always present.

### Progress and logging

- `.ralph/logs/queue_processing.log` captures the loop output per item.
- `ralph-queue status` (and `ralph --queue-status`) show live counts.
- The `ralph-monitor` dashboard renders an **Issue Queue** panel
  (completed/total, pending/active/failed, and the item currently processing)
  whenever a non-empty `.ralph/queue.json` is present.

## Security: queued content is untrusted input

Processing a queued item feeds the issue body (or PRD) into an autonomous agent
as the work to implement. Two protections apply:

- **Comments are excluded.** Only the issue *body* is used (via
  `format_issue_as_prd … false`); on public repos anyone can comment, so comment
  text — a prime prompt-injection surface — never reaches the agent.
- **Spec content is marked as data.** The generated `.ralph/PROMPT.md` instructs
  the agent to treat spec files as requirements describing *what* to build and to
  ignore any embedded instructions that try to change its task or tool
  permissions (the same posture as `ralph-import`).

Even so, the body is the work instruction by design. **Only queue issues you
trust** (e.g. your own backlog or a maintained milestone), and review unfamiliar
issues before processing them unattended.

## Design notes and limits

- **Single branch, one commit per issue.** Items are processed sequentially on
  the current branch; there is no per-issue branching.
- **Failures are isolated.** A failed item does not abort the run unless you
  pass `--halt-on-failure`; this maximizes throughput across a backlog.
- **Circular dependencies are refused.** `process` runs `validate` first and
  stops if the dependency graph contains a cycle. Fix the cycle (or
  `remove` an offending item) and retry.
- **No concurrency.** Parallel processing is intentionally out of scope — the
  queue is processed one item at a time.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `GitHub CLI (gh) is not installed` | Install `gh` (https://cli.github.com) |
| `GitHub CLI is not authenticated` | `gh auth login` |
| `circular dependency detected` | Run `ralph-queue validate`; remove or fix the cycle |
| Items stuck `pending` after a run | Their dependencies failed or aren't in the queue — add/complete the dependency, then resume |
| Query results were capped | Narrow your filters; very large result sets are truncated by `gh` |
