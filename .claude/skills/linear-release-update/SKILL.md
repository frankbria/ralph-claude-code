---
name: linear-release-update
user-invocable: true
model: claude-haiku-4-5-20251001
description: Post a structured Linear project update document on a version release. Orchestrates tapps_release_update → docs_validate_release_update → save_document → cache invalidation.
allowed-tools: mcp__tapps-mcp__tapps_release_update mcp__docs-mcp__docs_generate_release_update mcp__docs-mcp__docs_validate_release_update mcp__plugin_linear_linear__save_document mcp__tapps-mcp__tapps_linear_snapshot_invalidate
argument-hint: "--version vX.Y.Z --prev-version vX.Y.W [--team <team>] [--project <project>] [--dry-run]"
---

Post a structured Linear project update document when a new version is released. The user's request to post a release update is standing authorization for the full pipeline — do NOT pause mid-flow to ask "should I post this?"

**Flow:**

1. Call `mcp__tapps-mcp__tapps_release_update(version, prev_version, team, project)`.
   - `version` and `prev_version` are required. Parse from the user's prompt or ask once if both are missing.
   - `team` and `project`: read from `.tapps-mcp.yaml` if present (`linear_team`, `linear_project` fields), otherwise pass empty strings.
   - If `dry_run=true` is requested, pass it through — the tool returns the body without requiring validation to pass.

2. Check the response:
   - If `success=false`: surface the `error.message` and `findings` to the user. Stop — do not post.
   - If `agent_ready=false` (and not dry_run): surface findings, stop.
   - If `agent_ready=true`: proceed.

3. Call `mcp__plugin_linear_linear__save_document`:
   - `project`: use `data.project` from the tool response.
   - `title`: use `data.document_title` from the tool response (format: `Release vX.Y.Z — YYYY-MM-DD`).
   - `content`: use `data.body` from the tool response verbatim.

4. After `save_document` succeeds, call `mcp__tapps-mcp__tapps_linear_snapshot_invalidate`:
   - `team`: use `data.team` from tool response.
   - `project`: use `data.project` from tool response.

5. Report the document URL from `save_document` response and the version that was posted.

**Rules:**
- Never call `save_document` without a prior `agent_ready=true` from `tapps_release_update` (unless `dry_run=true`).
- `document_title` must use the em-dash format from `data.document_title` — do not construct it manually.
- Do not modify the body returned by the tool. Pass `data.body` verbatim.
