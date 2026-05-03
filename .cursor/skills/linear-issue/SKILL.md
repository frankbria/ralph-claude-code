---
name: linear-issue
description: Create, lint, validate, or triage Linear issues for agents. Routes to docs-mcp Linear tools and the Linear plugin by user intent.
mcp_tools:
  - docs_generate_story
  - docs_lint_linear_issue
  - docs_validate_linear_issue
  - docs_linear_triage
  - linear_get_issue
  - linear_list_issues
  - tapps_linear_snapshot_get
  - tapps_linear_snapshot_put
  - tapps_linear_snapshot_invalidate
---

Work with Linear issues for AI-agent consumption. Infer intent from the user's prompt and act autonomously within scope. The user's original request is standing authorization for the full generator → validator → save chain — do NOT pause mid-flow to ask "should I create this?"

**Assignee — agent, not human (applies to every write below).** Resolve the agent user once per session via `linear_list_users`, picking the user whose `name`/`displayName`/`email` matches `agent`, `bot`, `tapps`, `claude`, or `agent_user` in `.tapps-mcp.yaml`. Cache the id. Pass `assignee="<agent-user-id-or-name>"` on every Linear write. If no agent user exists, leave `assignee` unset — never fall back to the OAuth user. Only override when the user explicitly names a person.

**Create** a new issue (default when prompt describes a change/bug):

1. Call `docs_generate_story` with the user's ask. Required args: `title` (<=80 chars, pattern `file.py: symptom`), `files` (comma-separated, each with `:LINE-RANGE`), `acceptance_criteria` (verifiable items).
2. Default `audience="agent"` emits the 5-section Linear template (What/Where/Why/Acceptance/Refs) and round-trips through the validator.
3. If the call returns `INPUT_INVALID`, refine the inputs per the error message and retry. Do NOT pass `audience="human"` unless the user asks for a product-review doc.
4. Call the Linear plugin's write tool with `assignee="<agent-user-id-or-name>"`. Proceed without prompting the user.
5. After the write returns, call `tapps_linear_snapshot_invalidate(team=<team>, project=<project>)` to evict stale cached snapshots for that slice.

**Lint** an existing issue (prompt like "lint TAP-686"):

1. Fetch via `linear_get_issue`.
2. Pass title/description/labels/priority/estimate to `docs_lint_linear_issue`.
3. Surface score, findings (with fix_hints), and reclaimable noise bytes.

**Validate** before creating (prompt like "is this agent-ready?"):

1. Call `docs_validate_linear_issue` with the payload.
2. Report `{agent_ready, score, missing[]}`. Missing items are blockers; propose a concrete fix per item.

**Triage** a batch (prompt like "triage open issues"):

1. If the user names a specific issue (e.g. "triage TAP-686"), use `linear_get_issue(id="TAP-686")` — skip list/cache entirely.
2. **Cache-first read:** call `tapps_linear_snapshot_get(team=<team>, project=<project>, state="backlog" | "unstarted", label?)`. If `data.cached` is `true`, use `data.issues` directly — Linear was not called.
3. **On cache miss** (`data.cached` is `false`): call `linear_list_issues` with narrow filters — `team`, `project`, `state`, `includeArchived=false` (never call without filters). Then populate the cache by calling `tapps_linear_snapshot_put(team, project, issues_json=json.dumps(response.issues), state, label?)` using the **same** team/project/state/label/limit as the get call so the keys align.
4. Pass the list to `docs_linear_triage`.
5. Apply label_proposals, parent_groupings, and metadata_gaps via Linear writes (each carrying `assignee="<agent-user-id-or-name>"` for any newly-owned items). No mid-flow user confirmation.
6. After any write, call `tapps_linear_snapshot_invalidate(team=<team>, project=<project>)` to refresh the cache on next read.

Rules (enforced by docs-mcp tools):

- Title <=80 chars; no em-dash preambles.
- Inline-code filenames (`AGENTS.md`), never `[AGENTS.md](AGENTS.md)` (Linear's autolinker mangles).
- Bare `TAP-###` refs, never `<issue id="UUID">TAP-###</issue>` wrappers.
- `## Acceptance` has at least one verifiable `- [ ]` item.
- `## Where` includes at least one `path/to/file.ext:LINE-RANGE` anchor.
