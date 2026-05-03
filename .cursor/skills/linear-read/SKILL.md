---
name: linear-read
description: Read multi-issue Linear data via cache-first dance. MANDATORY for any list-style Linear read. Single-issue lookups go straight to get_issue. Routes through tapps_linear_snapshot_get/put before list_issues.
mcp_tools:
  - tapps_linear_snapshot_get
  - tapps_linear_snapshot_put
  - linear_list_issues
  - linear_get_issue
---

Multi-issue Linear reads are cache-first by contract (TAP-967 audit: 5,368 `list_issues` calls / 0.26% cache adoption). Invoke ANY time the user asks for a list, batch, or filtered view of Linear issues.

**When to invoke:** "list Linear issues", "what's open in TAP", "find issues assigned to X", "review the backlog". Skip for single-issue lookups (`get_issue(id="TAP-686")`).

**Core flow — every multi-issue read:**

1. `tapps_linear_snapshot_get(team, project, state, label?)` first.
2. On `cached=true`, use `data.issues` and filter in-memory — `list_issues` is NOT called.
3. On `cached=false`, call `linear_list_issues` with NARROW filters: `team`, `project`, `state`, `includeArchived=false`.
4. Immediately call `tapps_linear_snapshot_put(team, project, issues_json=json.dumps(issues), state, label?, limit?)` with the **same** key dimensions as the get call.

**The 6-poll kickoff antipattern:** firing six `list_issues` calls (one per state×priority bucket) collapses to one `snapshot_get(state="open")` plus an in-memory filter. The 5-min open-state TTL means the next session warms instantly.

**Status-bucket sweep antipattern:** three sequential `list_issues` calls for `backlog`/`unstarted`/`started` collapses to one `snapshot_get(state="open")` + memory filter on `state.type`.

**Anti-patterns — do not do these:**

- `list_issues` without a prior `snapshot_get` for the same key.
- `list_issues({})` or `list_issues({team, limit:250})` (the unfiltered scroll).
- Re-fetching the same narrow query 5–12 times in one turn with no intervening writes.
- Single-issue lookup via `list_issues` filtering — use `get_issue(id)` instead.
