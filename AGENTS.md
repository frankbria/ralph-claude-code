<!-- tapps-agents-version: 3.8.0 -->
# TappsMCP - instructions for AI assistants

When the **TappsMCP** MCP server is configured, you have access to tools for **code quality, doc lookup, and domain expert advice**. Use them to avoid hallucinated APIs, missed quality steps, and inconsistent output.

**File paths:** Use paths relative to project root (e.g. `src/main.py`). Absolute host paths also work when `TAPPS_MCP_HOST_PROJECT_ROOT` is set.

---

## Essential tools (always-on workflow)

| Tool | When to use |
|------|--------------|
| **tapps_session_start** | **FIRST call in every session** - server info only |
| **tapps_quick_check** | **After editing any Python file** - quick score + gate + security |
| **tapps_validate_changed** | **Before declaring multi-file work complete** - score + gate on changed files. **Always pass explicit `file_paths`** (comma-separated). Default is quick mode; only use `quick=false` as a last resort. |
| **tapps_checklist** | **Before declaring work complete** - reports missing required steps |
| **tapps_quality_gate** | Before declaring work complete - ensures file passes preset |

**For full tool reference** (26 tools with per-tool guidance), invoke the **tapps-tool-reference** skill when the user asks "what tools does TappsMCP have?", "when do I use tapps_score_file?", etc.

---

## tapps_session_start vs tapps_init

| Aspect | tapps_session_start | tapps_init |
|--------|---------------------|------------|
| **When** | **First call in every session** | **Pipeline bootstrap** (once per project, or when upgrading) |
| **Duration** | Fast (~1s, server info only) | Full run: 10-35+ seconds |
| **Purpose** | Load server info (version, checkers, config) into context | Create files (AGENTS.md, TECH_STACK.md, platform rules), optionally warm cache/RAG |
| **Side effects** | None (read-only) | Writes files, warms caches |
| **Typical flow** | Call at session start, then work | Call once to bootstrap, or `dry_run: true` to preview |

**Session start** -> `tapps_session_start`. Use this as the first call in every session. Returns server info and project context.

**Pipeline/bootstrap** -> `tapps_init`. Use when you need to set up TappsMCP in a project (AGENTS.md, TECH_STACK.md, platform rules) or upgrade existing files.

**Both in one session?** Yes. If the project is not yet bootstrapped: call `tapps_session_start` first (fast), then `tapps_init` (creates files). If the project is already bootstrapped: call only `tapps_session_start` at session start.

**Lighter tapps_init options** (for timeout-prone MCP clients): Use `dry_run: true` to preview (~2-5s); use `verify_only: true` for a quick server/checker check (~1-3s); or set `warm_cache_from_tech_stack: false` and `warm_expert_rag_from_tech_stack: false` for a faster init without cache warming.

**Tool contract:** Session start returns server info and project context. tapps_validate_changed default = score + gate only; use `security_depth='full'` or `quick=false` for security. tapps_quick_check has no `quick` parameter (use tapps_score_file(quick=True) for that).

---

## Using tapps_lookup_docs for domain guidance

`tapps_lookup_docs` is the primary tool for both library documentation and domain-specific guidance. Pass a `library` name for API docs, or use `topic` to query for patterns and best practices.

| Context | Example call |
|---------|--------------|
| Using an external library | `tapps_lookup_docs(library="fastapi", topic="dependency injection")` |
| Testing patterns | `tapps_lookup_docs(library="pytest", topic="fixtures and parametrize")` |
| Security patterns | `tapps_lookup_docs(library="python-security", topic="input validation")` |
| API design | `tapps_lookup_docs(library="fastapi", topic="routing best practices")` |
| Database patterns | `tapps_lookup_docs(library="sqlalchemy", topic="session management")` |

---

## Recommended workflow

1. **Session start:** Call `tapps_session_start` (returns server info and project context).
2. **Check project memory:** Consider calling `tapps_memory(action="search", query="...")` to recall past decisions and project context.
3. **Record key decisions:** Use `tapps_session_notes(action="save", ...)` for session-local notes. Use `tapps_memory(action="save", ...)` to persist decisions across sessions.
3. **Before using a library:** Call `tapps_lookup_docs(library=...)` and use the returned content when implementing.
4. **Before modifying a file's API:** Call `tapps_impact_analysis(file_path=...)` to see what depends on it.
5. **During edits:** Call `tapps_quick_check(file_path=...)` or `tapps_score_file(file_path=..., quick=True)` after each change.
6. **Before declaring work complete:**
   - Recommended: invoke the `/tapps-finish-task` skill — bundles `tapps_validate_changed` + `tapps_checklist` + an optional memory save and reports a one-line summary.
   - If you'd rather run the steps manually: `tapps_validate_changed(file_paths="file1.py,file2.py")` with explicit paths to score + gate changed files (never call without `file_paths` in large repos; default is quick mode), then `tapps_checklist(task_type=...)` and, if `complete` is false, call the missing required tools (use `missing_required_hints` for reasons).
   - Optionally call `tapps_report(format="markdown")` to generate a quality summary.
7. **When in doubt:** Use `tapps_lookup_docs` for domain-specific questions and library guidance; use `tapps_validate_config` for Docker/infra files.

### Review Pipeline (multi-file)

For reviewing and fixing multiple files in parallel, use the `/tapps-review-pipeline` skill:

1. It detects changed Python files and spawns `tapps-review-fixer` agents (one per file or batch)
2. Each agent scores the file, fixes issues, and runs the quality gate
3. Results are merged and validated with `tapps_validate_changed`
4. A summary table shows before/after scores, gate status, and fixes applied

You can also invoke the `tapps-review-fixer` agent directly on individual files for combined review+fix in a single pass.

---

## Checklist task types

Use the `task_type` that best matches the current work:

- **feature** - New code
- **bugfix** - Fixing a bug
- **refactor** - Refactoring
- **security** - Security-focused change
- **review** - General code review (default)

The checklist uses this to decide which tools are required vs recommended vs optional for that task.

---

## Project scope (do not break out of this repo/project)

You were deployed into THIS repo by `tapps_init` / `tapps_upgrade`. Stay in scope:

- You **MAY read across projects** — docs lookups, reading sibling repos, fetching references.
- You **MUST NOT write outside this repo or this project**:
  - Do not create, update, comment on, or move Linear (or other tracker) issues belonging to a different project.
  - Do not modify files, branches, or pull requests in any other repository.
  - Do not push, merge, or release on behalf of another project.
- Read team / project / repo identity from local config (`.tapps-mcp.yaml`, current git remote) — never infer from search results or memory hits that point at unrelated workspaces.
- If a task seems to require a write outside this repo/project, stop and ask the user.

---

## Memory systems

Your project may have two complementary memory systems:

- **Claude Code auto memory** (`~/.claude/projects/<project>/memory/MEMORY.md`): Build commands, IDE preferences, personal workflow notes. Auto-managed.
- **TappsMCP shared memory** (`tapps_memory` tool): Architecture decisions, quality patterns, expert findings, cross-agent knowledge. Structured with tiers, confidence decay, contradiction detection, consolidation, and federation.

RECOMMENDED: Use `tapps_memory` for architecture decisions and quality patterns.

### Memory actions (33 total)

**Core:** `save`, `save_bulk`, `get`, `list`, `delete` — CRUD with tier/scope/tag classification (`save` + architectural tier may **supersede** prior versions when `memory.auto_supersede_architectural` is true)

**Search:** `search` — ranked BM25 retrieval with composite scoring (relevance + confidence + recency + frequency)

**Intelligence:** `reinforce`, `gc`, `contradictions`, `reseed`

**Consolidation:** `consolidate`, `unconsolidate`

**Import/export:** `import`, `export`

**Federation:** `federate_register`, `federate_publish`, `federate_subscribe`, `federate_sync`, `federate_search`, `federate_status`

**Maintenance:** `index_session`, `validate`, `maintain`

**Security:** `safety_check`, `verify_integrity`

**Profiles:** `profile_info`, `profile_list`, `profile_switch`

**Diagnostics:** `health`

**Hive / Agent Teams:** `hive_status`, `hive_search`, `hive_propagate`, `agent_register` (opt-in; see `hive_status` when `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is set)

**Default pipeline behavior (POC-oriented):** Shipped config turns on auto-save quality signals, recurring quick_check memory, architectural supersede, impact enrichment, and `memory_hooks` auto-recall/capture — set `false` in `.tapps-mcp.yaml` if you want a quieter setup. See `docs/MEMORY_REFERENCE.md`.

### Memory tiers and scopes

**Tiers:** `architectural` (180-day half-life, stable decisions), `pattern` (60-day, conventions), `procedural` (30-day, workflows), `context` (14-day, short-lived)

**Scopes:** `project` (default, all sessions), `branch` (git branch), `session` (ephemeral), `shared` (federation-eligible)

**Memory profiles:** Built-in profiles from tapps-brain (e.g. `repo-brain` default). Use `profile_info`, `profile_list`, `profile_switch` actions.

**Configuration:** Override `memory.profile`, `memory.capture_prompt`, `memory.write_rules`, and `memory_hooks` in `.tapps-mcp.yaml`. Max 1500 entries per project. Auto-GC at 80% capacity.

---

## Platform hooks and automation

When `tapps_init` generates platform-specific files, it also creates **hooks**, **subagents**, and **skills** that automate parts of the workflow:

### Hooks (auto-generated)

**Claude Code** (`.claude/hooks/`): 7 hook scripts that enforce quality automatically:
- **SessionStart** - Injects TappsMCP awareness on session start and after compaction
- **PostToolUse (Edit/Write)** - Reminds you to run `tapps_quick_check` after Python edits
- **Stop** - Reminds you to run `tapps_validate_changed` before session end (non-blocking)
- **TaskCompleted** - Reminds you to validate before marking task complete (non-blocking)
- **PreCompact** - Backs up scoring context before context window compaction
- **SubagentStart** - Injects TappsMCP awareness into spawned subagents

Opt-in `PreToolUse` gates are independent flags in `.tapps-mcp.yaml` — enable each based on what you want blocked:
- `destructive_guard: true` — blocks destructive Bash commands (`rm -rf`, `format c:`, etc.).
- `linear_enforce_gate: true` — blocks `mcp__plugin_linear_linear__save_issue` unless the `linear-issue` skill flow (with `docs_validate_linear_issue`) was used recently. Bypass: `TAPPS_LINEAR_SKIP_VALIDATE=1`. Bash + PowerShell. Default: on at medium/high engagement, off at low.
- `linear_enforce_cache_gate: "off" | "warn" | "block"` (TAP-1224) — gates `mcp__plugin_linear_linear__list_issues` behind a recent `tapps_linear_snapshot_get` for the same `(team, project, state, label, limit)` slice. **Warn mode** (default at medium/high engagement) logs violations to `.tapps-mcp/.cache-gate-violations.jsonl` and allows the call. **Block mode** rejects with exit 2 unless a matching sentinel < 300s old exists. Single-issue lookups must use `mcp__plugin_linear_linear__get_issue` instead. Pairs with the `linear-read` skill which routes the cache-first dance. Bypass: `TAPPS_LINEAR_SKIP_CACHE_GATE=1`. `tapps doctor` reports current mode + 24h violation count.
- `install_git_hooks: true` (TAP-979) — writes `.githooks/pre-commit` and sets `core.hooksPath = .githooks`. Runs `tapps-mcp validate-changed --quick` on staged Python files and fails the commit on gate failure. Bypass: `TAPPS_SKIP_GATE=1`. Default: off.

Run `tapps-mcp doctor` to list wired matchers.

**Cursor** (`.cursor/hooks/`): 3 hook scripts:
- **beforeMCPExecution** - Logs MCP tool invocations for observability
- **afterFileEdit** - Fire-and-forget reminder to run quality checks
- **stop** - Prompts validation via followup_message before session ends

### Subagents (auto-generated)

Four agent definitions per platform in `.claude/agents/` or `.cursor/agents/`:
- **tapps-reviewer** (sonnet) - Reviews code quality and runs security scans after edits
- **tapps-researcher** (haiku) - Looks up documentation and consults domain experts
- **tapps-validator** (sonnet) - Runs pre-completion validation on all changed files

### Skills (auto-generated)

Twelve SKILL.md files per platform in `.claude/skills/` or `.cursor/skills/`:
- **tapps-score** - Score a Python file across 7 quality categories
- **tapps-gate** - Run a quality gate check and report pass/fail
- **tapps-validate** - Validate all changed files before declaring work complete
- **tapps-review-pipeline** - Orchestrate a parallel review-fix-validate pipeline
- **tapps-research** - Research a technical question using domain experts and docs
- **tapps-security** - Run a comprehensive security audit with vulnerability scanning
- **tapps-memory** - Manage shared project memory for cross-session knowledge

### Agent Teams (opt-in, Claude Code only)

When `tapps_init` is called with `agent_teams=True`, additional hooks enable a quality watchdog teammate pattern:
- **TeammateIdle** - Keeps the quality watchdog active while issues remain
- **TaskCompleted** - Reminds about quality gate validation on task completion

Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to enable Agent Teams.

### VS Code / Copilot Instructions (auto-generated)

`.github/copilot-instructions.md` - Provides GitHub Copilot in VS Code with
TappsMCP tool guidance, recommended workflow, and scoring category reference.

### Cursor BugBot Rules (auto-generated, Cursor only)

`.cursor/BUGBOT.md` - Quality standards for Cursor BugBot automated PR review:
security requirements, style rules, testing requirements, and scoring thresholds.

### CI Integration (auto-generated)

`.github/workflows/tapps-quality.yml` - GitHub Actions workflow that validates
changed Python files on every pull request using TappsMCP quality gates.

### MCP Elicitation

When the MCP client supports elicitation (e.g. Cursor), TappsMCP can prompt
the user interactively:
- `tapps_quality_gate` prompts for preset selection when none is provided
- `tapps_init` asks for confirmation before writing configuration files

On unsupported clients, tools fall back to default behavior silently.

---

## Content-return pattern (Docker / read-only environments)

When TappsMCP or DocsMCP runs inside a Docker container with a read-only workspace
mount, tools **cannot write files directly**.  Instead they return a `file_manifest`
in the response with the file contents and instructions for you to apply.

**How to detect:** Check for `content_return: true` in the tool response `data`.

**How to apply:**
1. Read `file_manifest.agent_instructions` for persona, tool preference, and warnings
2. For each file in `file_manifest.files[]` (sorted by `priority`, lowest first):
   - `mode: "create"` or `"overwrite"` → Use the **Write** tool with the `content` verbatim
   - `mode: "merge"` → The content is the pre-computed merge result; write it with the **Write** tool
3. Create parent directories as needed
4. Follow `verification_steps` after all files are written
5. **Never modify the content** — write it exactly as provided

**Tools that support content-return:** `tapps_init`, `tapps_upgrade`, `tapps_set_engagement_level`, `tapps_memory` (export), `docs_config`, and all `docs_generate_*` generators.

**Force content-return:** Pass `output_mode: "content_return"` to `tapps_init` or `tapps_upgrade`.

---

## DocsMCP - documentation tools (companion server)

When the **DocsMCP** MCP server is also configured, you have access to documentation generation and validation tools.

| Tool | When to use |
|------|--------------|
| **docs_project_scan** | Audit documentation state for a project |
| **docs_generate_readme** | Generate or update README with smart merge |
| **docs_generate_changelog** | Generate CHANGELOG from git history |
| **docs_generate_api** | Generate API reference docs |
| **docs_check_drift** | Detect code changes not reflected in docs |
| **docs_check_completeness** | Score documentation completeness |
| **docs_check_freshness** | Check documentation staleness |

DocsMCP is a separate MCP server. Install via `pip install docs-mcp` or `npx docs-mcp serve`.

**Combined server (TappsPlatform):** For clients that support 47+ tools (Claude Code, GitHub Copilot), run both servers as one via `tapps-platform serve`. Note: Cursor has a 40-tool limit, so use standalone servers there.

### Optional: More specialized agents

For more specialized agents (e.g. Frontend Developer, Reality Checker), see [agency-agents](https://github.com/msitarzewski/agency-agents) and run their install script for your platform. TappsMCP and agency-agents can coexist; there is no path conflict.

---

## Troubleshooting: MCP server not available

For the full consumer requirements checklist, see [docs/TAPPS_MCP_REQUIREMENTS.md](docs/TAPPS_MCP_REQUIREMENTS.md).

TappsMCP tools (`tapps_session_start`, `tapps_init`, `tapps_quick_check`, etc.) are only callable when the tapps-mcp server is **listed as an available MCP server** in your host (Claude Code, Cursor, or VS Code). If the server is configured in MCP config files but not visible to the agent, tool calls will fail.

**How to verify the server is available:**
- **Claude Code:** Run `/mcp` to list connected servers, or check `.claude.json` / `.mcp.json`
- **Cursor:** Open Settings > MCP and confirm tapps-mcp is listed and enabled
- **VS Code:** Check `.vscode/mcp.json` and the MCP panel in the sidebar

**If the server is not available (CLI fallback):**
1. From the project root, run: `tapps-mcp upgrade --force --host auto`
2. Then verify: `tapps-mcp doctor`
3. Restart your MCP host (Claude Code / Cursor / VS Code) to pick up the new config
4. If tools are still unavailable, use CLI commands directly: `tapps-mcp init`, `tapps-mcp doctor`

---

## Troubleshooting: MCP tool permissions

If TappsMCP tools are being rejected or prompting for approval on every call:

**Claude Code:** Ensure `.claude/settings.json` contains **both** permission entries:
```json
{
  "permissions": {
    "allow": [
      "mcp__tapps-mcp",
      "mcp__tapps-mcp__*"
    ]
  }
}
```
The bare `mcp__tapps-mcp` entry is needed as a reliable fallback - the wildcard `mcp__tapps-mcp__*` syntax has known issues in some Claude Code versions (see issues #3107, #13077, #27139). Run `tapps-mcp upgrade --host claude-code` to fix automatically.

**Cursor / VS Code:** These hosts manage MCP tool permissions differently. No `.claude/settings.json` needed.

**If tools are still rejected after fixing permissions:**
1. Restart your MCP host (Claude Code / Cursor / VS Code)
2. Verify the TappsMCP server is running: `tapps-mcp doctor`
3. Check that your permission mode is not `dontAsk` (which auto-denies unlisted tools)
4. As a last resort, use `tapps_quick_check` on individual files instead of `tapps_validate_changed`

---

## Troubleshooting: Doctor timeout

`tapps-mcp doctor` runs version checks on all quality tools (ruff, mypy, bandit, radon, vulture, pylint, pip-audit) and may take **30-60+ seconds**, especially on first run or in cold environments where mypy is slow to start.

**If doctor times out or takes too long:**
- Use `tapps-mcp doctor --quick` to skip tool version checks (completes in a few seconds)
- Run doctor in the background if your agent or IDE has a short CLI timeout
- The MCP tool `tapps_doctor(quick=True)` provides the same quick mode

<!-- BEGIN: karpathy-guidelines c9a44ae (MIT, forrestchang/andrej-karpathy-skills) -->
<!--
  Vendored from https://github.com/forrestchang/andrej-karpathy-skills
  Pinned commit: c9a44ae835fa2f5765a697216692705761a53f40 (2026-04-15)
  License: MIT (c) forrestchang
  Do not edit by hand — update KARPATHY_GUIDELINES_SOURCE_SHA in prompt_loader.py
  and re-run the vendor script, then bump tapps-mcp version.
-->
## Karpathy Behavioral Guidelines

> Source: https://github.com/forrestchang/andrej-karpathy-skills @ c9a44ae835fa2f5765a697216692705761a53f40 (MIT)
> Derived from [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
<!-- END: karpathy-guidelines -->
