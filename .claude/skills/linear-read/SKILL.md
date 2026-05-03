---
name: linear-read
user-invocable: true
model: claude-haiku-4-5-20251001
description: Read multi-issue Linear data via cache-first dance. MANDATORY for any list-style Linear read (triage, backlog review, "what's open", "find issues assigned to X"). Single-issue lookups go straight to get_issue. Routes through tapps_linear_snapshot_get/put before list_issues.
allowed-tools: mcp__tapps-mcp__tapps_linear_snapshot_get mcp__tapps-mcp__tapps_linear_snapshot_put mcp__plugin_linear_linear__list_issues mcp__plugin_linear_linear__get_issue
argument-hint: "[free-form query, e.g. 'open issues in TAP', 'backlog assigned to me']"
---

Multi-issue Linear reads are cache-first by contract (TAP-967 audit found 5,368 `list_issues` calls with 0.26% cache adoption — soft rules failed; this skill is the routed path the agent reaches for instead). Invoke ANY time the user asks for a list, batch, or filtered view of Linear issues.

**When to invoke this skill:** "list Linear issues", "what's open in TAP", "find issues assigned to X", "review the backlog", "show me high-priority bugs", "what's in flight", "triage" (also routes through `linear-issue`). Do NOT invoke for single-issue lookups when the user has an issue id (e.g. "what's TAP-686 about?") — go straight to `mcp__plugin_linear_linear__get_issue(id="TAP-686")`.

**Core flow — every multi-issue read goes through these four steps in order:**

1. **`tapps_linear_snapshot_get(team, project, state, label?)` first.** Pass the same `state`, `label`, and `limit` you would pass to `list_issues`. State buckets the cache TTL (5 min for `open`/`unstarted`/`started`, 1 h for `completed`/`canceled`).
2. **On `cached=true`**, use `data.issues` and filter in-memory for the rest of the user's question — `list_issues` is NOT called. Project the fields you need with a list comprehension; do not re-query.
3. **On `cached=false`**, call `mcp__plugin_linear_linear__list_issues` with NARROW filters: `team`, `project`, `state`, `includeArchived=false`. Never call without filters; never call with only `team` + `limit:250`.
4. **Immediately after the miss-fetch**, populate the cache via `tapps_linear_snapshot_put(team, project, issues_json=json.dumps(issues), state, label?, limit?)` using the **same** key dimensions as the get call so the keys align.

**The 6-poll kickoff antipattern (the single biggest source of TAP-967's call volume):**

A common bad pattern is firing six sequential `list_issues` calls — `(state="Backlog", priority=1)`, `(Backlog, p2)`, `(Backlog, p3)`, `(Backlog, p4)`, `In Progress`, `Todo` — to assemble a session-start summary. Don't. Instead:

```
snap = tapps_linear_snapshot_get(team=<team>, project=<project>, state="open")
# on cache hit, use snap.data.issues directly; on miss, fetch once with state="open" then put.
issues = snap.data.issues
backlog_p1 = [i for i in issues if i["state"]["name"] == "Backlog" and i.get("priority", {}).get("value") == 1]
in_progress = [i for i in issues if i["state"]["type"] == "started"]
# ...etc, all from one snapshot.
```

One snapshot_get on `state="open"` covers Backlog + In Progress + Todo + Triage + Unstarted. The 5-minute TTL means the next session warms instantly — six API calls become zero.

**Status-bucket sweep (also a TAP-967 antipattern):**

Three sequential `list_issues({state: "backlog"})`, `({state: "unstarted"})`, `({state: "started"})` calls collapse to one `snapshot_get(state="open")` plus an in-memory filter on `state.type`.

**Other read shapes — same four-step flow:**

- **Filter by parent epic:** call `list_issues(parentId="TAP-1078")` directly on cache miss; pass the same parentId to `snapshot_put` as the `label` slot if you need a finer cache key. For most parent-epic reads, snapshot the broader `(team, project, state="open")` slice and filter in memory by `parent.id`.
- **Filter by assignee:** snapshot the team/state slice, filter `i["assignee"]["name"] == "X"` in memory.
- **Recent activity:** if you need `updatedAt=-P7D`, do the snapshot first; if the cache is < 5 min old, the `updatedAt` filter is a memory-side comprehension.

**After any Linear write** (from `linear-issue` or `linear-release-update` skills), call `mcp__tapps-mcp__tapps_linear_snapshot_invalidate(team, project)` so the next read returns fresh data. This skill itself does not write.

**Anti-patterns — do not do these:**

- Calling `list_issues` without a prior `snapshot_get` for the same key.
- Calling `list_issues({})` or `list_issues({team: "TAP", limit: 250})` (the unfiltered scroll — TAP-967's worst offender).
- Re-fetching the same narrow query 5–12 times in one assistant turn with no intervening writes (use the cache).
- Single-issue lookup via `list_issues` filtering — use `get_issue(id)` instead.

**Linear plugin parameter cheatsheet** (the flat parameters cover almost every real query — there is no need for raw GraphQL filter shapes):

- `team` — team name or ID, required for any narrow filter
- `project` — project name, ID, or slug
- `state` — state type (`triage`/`backlog`/`unstarted`/`started`/`completed`/`canceled`) or state name (`Backlog`/`Done`/...). The bucketed states (`open`, `closed`) are tapps-mcp cache keys, not Linear states.
- `assignee` — user ID, name, email, or `me`. `null` for unassigned.
- `parentId` — parent issue ID (e.g. `TAP-1078`)
- `label` — label name or ID
- `priority` — `0`=None, `1`=Urgent, `2`=High, `3`=Normal, `4`=Low
- `updatedAt` / `createdAt` — ISO-8601 date or duration (`-P7D`)
- `query` — full-text search across title and description
- `includeArchived` — default `true`; pass `false` to skip archived
- `limit` — max 250
