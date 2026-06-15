# ADR 0002: Agent Adapter Contract + Capabilities Schema

- **Status:** Proposed
- **Date:** 2026-06-15
- **Deciders:** Frank Bria
- **Tracking issue:** [#311](https://github.com/frankbria/ralph-claude-code/issues/311) (`[P0.2]`)
- **Epic / label:** `multi-provider` (issues [#310](https://github.com/frankbria/ralph-claude-code/issues/310)–[#325](https://github.com/frankbria/ralph-claude-code/issues/325))
- **Depends on:** [ADR 0001](0001-multi-provider-agent-abstraction.md) (`[P0.1]`, [#310](https://github.com/frankbria/ralph-claude-code/issues/310)) — the ratified decision to go provider-agnostic and the live-probed capability matrix.
- **Blocks:** [#312](https://github.com/frankbria/ralph-claude-code/issues/312) (`[P1.1]`, abstraction seam + adapter loader), [#313](https://github.com/frankbria/ralph-claude-code/issues/313) (`[P1.2]`, Claude reference adapter), [#315](https://github.com/frankbria/ralph-claude-code/issues/315) (`[P2.1]`).

## Context

ADR 0001 ratified the decision to make Ralph **provider-agnostic**: "which agent
CLI runs the loop" becomes a config flag (`AGENT_PROVIDER`), with Claude as the
reference adapter and byte-for-byte unchanged default behavior until a different
provider is selected. It also recorded a live-probed capability matrix across
seven CLIs (Claude, Codex, Gemini, OpenCode, Droid, Kilocode, Copilot).

ADR 0001 stopped at *direction + matrix*. It did **not** specify the seam itself:
the precise interface every provider adapter implements, the shape of the
normalized analysis struct the core loop consumes, the capabilities record that
drives graceful degradation, or how adapters are discovered and loaded. Without
that specification, the Phase 1 work (`[P1.1]` seam, `[P1.2]` Claude adapter)
has no contract to build against, and `[P2.1]`+ providers have nothing to
conform to.

This ADR specifies that seam. It is **design only** — no `lib/agents/` code is
written here (that begins at `[P1.1]`/`[P1.2]`). Its job is to define a contract
that is (a) implementable for Claude with zero behavior change and (b) feasible
for the divergent providers in the ADR 0001 matrix.

### Grounding

Every field below is grounded in current Claude-specific behavior so the
contract is provably implementable, not aspirational:

- **Command build** mirrors `build_claude_command()` in `ralph_loop.sh`
  (lines 1535–1627).
- **Output normalize** mirrors the fields `lib/response_analyzer.sh` extracts
  into `.ralph/.response_analysis` (under `.analysis.*`) and persists to
  `.ralph/.claude_session_id`.
- **Provider dispatch** follows the precedent already in the tree: the sandbox
  provider router (`SANDBOX_PROVIDER` → `case` dispatch in `ralph_loop.sh` and
  `get_sandbox_status()` in `lib/sandbox_docker.sh`, routing docker/e2b).

## Decision

An **agent adapter** is a single bash file, `lib/agents/<provider>.sh`, that
implements three pure-ish functions: one to **build** the provider's headless
command, one to **normalize** the provider's output into Ralph's internal
analysis struct, and one to **declare** the provider's capabilities. The core
loop talks only to these three functions plus the capabilities record; it
contains no provider-specific branches.

The contract has four parts: the **Command-Build interface**, the
**Output-Normalize interface**, the **Capabilities schema**, and the
**Registration convention**.

---

### 1. Command-Build interface contract

Each adapter declares, as a set of **declarative fields**, how its provider's
headless command line is assembled. Fields are presented below as a JSON-schema
fragment for precision; an adapter realizes them in bash (the `<provider>_build_command()`
function, §4) by appending to a command array — exactly as
`build_claude_command()` populates `CLAUDE_CMD_ARGS` today.

```jsonc
{
  "command_build": {
    // --- Invocation (required) ---
    "executable":          "string",   // argv[0]; for Claude: $CLAUDE_CODE_CMD (default "claude")
    "headless_subcommand": "string?",  // print/exec mode token, e.g. Codex "exec"; Claude: none (the -p flag is the headless switch)
    "stdin_behavior":      "enum",     // "none" | "prompt" | "closed" — how stdin is used; Claude: "none" (prompt passed as argv)

    // --- Prompt delivery (required) ---
    "prompt_flag":         "string?",  // flag that carries the prompt; Claude: "-p"
    "prompt_source":       "enum",     // "inline" | "file" | "stdin"; Claude: "inline" (PROMPT.md content read and passed as an argv element, NOT a file path, NOT stdin)

    // --- Model selection (optional) ---
    "model_flag":          "string?",  // Claude: "--model"
    "model_value_source":  "string?",  // config var holding the value; Claude: "CLAUDE_MODEL" (omitted when empty)
    "effort_flag":         "string?",  // Claude: "--effort"
    "effort_value_source": "string?",  // Claude: "CLAUDE_EFFORT" (omitted when empty)

    // --- Output format (required if supports_structured_output) ---
    "output_format_flag":  "string?",  // Claude: "--output-format"
    "supported_formats":   ["json", "stream-json", "text"], // values the flag accepts; Claude: json | stream-json | text

    // --- Session continuity (optional; see session_continuity capability) ---
    "resume_flag":         "string?",  // resume-by-id; Claude: "--resume" (gated by CLAUDE_USE_CONTINUE; deliberately NOT --continue, per #151)
    "session_id_source":   "string?",  // where the id comes from; Claude: .ralph/.claude_session_id (read via read_session_id_file)
    "continue_flag":       "string?",  // continue-last-session; Claude: none
    "preassign_flag":      "string?",  // assign an id at create time; Claude: "--session-id" (race-free; not currently used by the loop)

    // --- Tool restrictions (optional; see supports_tool_restrictions) ---
    "allowed_tools_flag":  "string?",  // Claude: "--allowedTools"
    "tools_value_format":  "enum",     // "repeated-args" | "comma-list" | "single-arg"; Claude: "repeated-args" (CLAUDE_ALLOWED_TOOLS is comma-split, each tool a separate argv element)
    "approval_flag":       "string?",  // providers that gate via approval modes instead of allowlists (Gemini --approval-mode, Codex -s, Droid --auto); Claude: none

    // --- System prompt injection (optional) ---
    "system_prompt_flag":  "string?",  // Claude: "--append-system-prompt"
    "system_prompt_mode":  "enum",     // "append" | "replace"; Claude: "append" (used to inject build_loop_context per iteration)

    // --- Environment (optional) ---
    "required_env_vars":   ["string"], // env vars that MUST be set or the adapter fails fast; Claude: none (auth is ambient)
    "optional_env_vars":   { "NAME": "default" } // env vars with defaults
  }
}
```

**Conformance rules**

- **Required for every adapter:** `executable`, `stdin_behavior`, `prompt_flag`
  (or `prompt_source: "stdin"`), `prompt_source`. Without these, the loop cannot
  invoke the provider at all.
- **Conditionally required:** `output_format_flag` + `supported_formats` when
  `supports_structured_output` is true; `allowed_tools_flag` **or**
  `approval_flag` when `supports_tool_restrictions` is true; `resume_flag`,
  `continue_flag`, or `preassign_flag` consistent with the `session_continuity`
  capability value.
- **Optional:** model/effort/system-prompt fields — adapters that lack the
  capability simply leave them null, and the loop skips that argv contribution.
- A null/absent field means "this provider does not support this knob"; the
  builder MUST NOT emit a flag for a null field.

**Canonical Claude mapping** (from `build_claude_command()`, `ralph_loop.sh:1535–1627`):

| Field | Claude value | Source line |
|---|---|---|
| `executable` | `$CLAUDE_CODE_CMD` (`"claude"`) | 1544 |
| `model_flag` / source | `--model` / `CLAUDE_MODEL` | 1553–1555 |
| `effort_flag` / source | `--effort` / `CLAUDE_EFFORT` | 1558–1560 |
| `output_format_flag` | `--output-format json` (when `CLAUDE_OUTPUT_FORMAT=json`) | 1563–1565 |
| `allowed_tools_flag` / format | `--allowedTools` / repeated-args from comma-split `CLAUDE_ALLOWED_TOOLS` | 1567–1580 |
| `resume_flag` / source | `--resume <id>` (gated by `CLAUDE_USE_CONTINUE`) | 1582–1589 |
| `system_prompt_flag` / mode | `--append-system-prompt <loop_context>` / append | 1593–1596 |
| `prompt_flag` / source | `-p <content>` / inline (PROMPT.md read at 1602) | 1598–1603 |

---

### 2. Output-Normalize interface contract

Each adapter implements `<provider>_normalize_output()`, a parser that maps the
provider's raw stdout/stream into Ralph's **internal analysis struct**. The core
loop and `should_exit_gracefully()` / circuit-breaker logic consume only this
struct — never the provider's native format.

**Parser signature**

```
<provider>_normalize_output(raw_output_path, output_format_hint) -> normalized JSON (stdout)
```

- `raw_output_path` — path to the file containing the provider's captured output.
- `output_format_hint` — one of `json` | `stream-json` | `text`, as requested in
  the command build (the adapter MAY re-detect; cf. `detect_output_format()` in
  `lib/response_analyzer.sh`, which also guards against truncated JSONL streams).
- Returns the normalized struct as JSON on stdout. The core loop writes it to
  `.ralph/.response_analysis` under the `.analysis.*` keys (unchanged from today).

**Target normalized struct**

```jsonc
{
  "status":             "string",   // "COMPLETE" | "IN_PROGRESS" | "ERROR" (informational; not sufficient alone to exit)
  "exit_signal":        false,      // boolean — explicit EXIT_SIGNAL from the RALPH_STATUS block (the authoritative completion signal)
  "work_type":          "string",   // "IMPLEMENTATION" | "TEST_ONLY" | "DOCUMENTATION" | ...
  "files_modified":     0,          // integer
  "asking_questions":   false,      // boolean (#190 — agent asked instead of acting)
  "question_count":     0,          // integer
  "token_usage":        { "input_tokens": 0, "output_tokens": 0 }, // for MAX_TOKENS_PER_HOUR
  "permission_denials": [],         // array of { tool_name, command } (#101)
  "is_error":           false,      // boolean — provider-level error despite exit 0 (#134/#199)
  "rate_limit_detected": false,     // boolean — provider API/usage limit hit (#100/#183)
  "session_id":         "string?",  // for persistence + resume
  "confidence_score":   0,          // integer 0–100 (text-mode heuristic; #224)
  "work_summary":       "string"    // short human-readable summary of the iteration
}
```

**Fallback behavior for missing fields** — a normalizer MUST always return every
key; when the provider's output does not carry a value, it falls back as follows:

| Field | Fallback when absent |
|---|---|
| `files_modified` | count of **distinct files** changed since `.ralph/.loop_start_sha` — the deduplicated union of `git diff --name-only` over committed + staged + unstaged changes (a file count, *not* a line count); cf. `ralph_loop.sh` ~2257–2272 |
| `exit_signal` | `false` (and `status` from the RALPH_STATUS text block if present) |
| `token_usage` | `{0,0}` when the provider lacks usage events (`supports_token_usage:false`) |
| `permission_denials` | `[]` when `supports_permission_denials:false` |
| `is_error` / `rate_limit_detected` | `false` when not detectable for the provider |
| `confidence_score` | computed heuristically (text mode), else `0` |
| `session_id` | empty (a new session will be assigned next loop) |

**Baseline shapes the contract is derived from** — `lib/response_analyzer.sh`
handles three JSON shapes today, and every adapter normalizer must collapse its
native output into the single struct above:

1. **Flat object** — the oldest schema: `{ "status", "exit_signal", "work_type", "files_modified", ... }`.
2. **Provider CLI nested object** — Claude's `{ "result", "sessionId", "metadata": { "files_changed", "has_errors", "completion_status", "session_id" } }`.
3. **Stream-json array** — Claude's `[{type:"system",...}, {type:"assistant",...}, {type:"result", sessionId, result, is_error, ...}]`, collapsed to a flat object (session id merged from the `init` or `result` element).

**Portable primary exit signal.** Independent of all three JSON shapes, the
authoritative completion signal is the **`RALPH_STATUS` text block** the agent
emits in its output. Its canonical format is defined by `templates/PROMPT.md`,
which is the **source of truth** for the field set and enum values:

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary of what to do next>
---END_RALPH_STATUS---
```

Because it is text the agent prints (not a provider JSON field), it is portable
to **every** provider — including text-only Copilot. It also supplies
text-mode-portable sources for several normalized-struct fields:
`STATUS → status`, `WORK_TYPE → work_type`, `FILES_MODIFIED → files_modified`
(when git fallback is unavailable), and `EXIT_SIGNAL → exit_signal`.

Every normalizer MUST scan for this block (in the result text for JSON modes,
or the raw output for text mode) and set `exit_signal` from an explicit
`EXIT_SIGNAL: true/false`, which wins over any heuristic. This keeps exit
detection uniform across providers and is the lowest-risk feature to carry
across the matrix (per ADR 0001).

**Parsing robustness** (so all adapters behave identically; mirrors
`lib/response_analyzer.sh` today):

- **Anchoring:** match the block only at the start of a line
  (`^[[:space:]]*---RALPH_STATUS---`); ignore inline prose mentions of
  `RALPH_STATUS`.
- **Field keys are case-sensitive and uppercase** (`STATUS`, `EXIT_SIGNAL`, …)
  as emitted by the template; values are matched case-insensitively
  (`true`/`True`).
- **Whitespace:** trim surrounding whitespace around `KEY: value`; do not assume
  a fixed column.
- **Field ordering is not guaranteed** — parse by key, never by position. Unknown
  or extra fields are ignored (additive-evolution safe).
- If multiple blocks appear, the **last** complete block wins.

---

### 3. Capabilities schema

Each adapter declares a **capabilities record** via `<provider>_capabilities()`.
The core loop reads it once and uses it to gate provider-dependent features. The
governing rule from ADR 0001 applies: **unsupported features degrade with a
logged warning, never a silent misbehavior.**

```jsonc
{
  "supports_structured_output":   true,   // can emit machine-readable JSON / stream-json
  "supports_token_usage":         true,   // output carries input/output token counts
  "supports_permission_denials":  true,   // emits machine-readable tool-denial events (#101)
  "supports_api_limit_detection": true,   // rate/usage limits detectable from output (#100/#183)
  "supports_preassigned_session": true,   // a session id can be assigned at create time (race-free)
  "session_continuity":           "preassign", // "preassign" | "resume-id" | "continue-last" | "none"
  "supports_streaming":           true,   // stream-json or equivalent incremental output
  "supports_tool_restrictions":   true    // allowlist/denylist or approval-mode gating
}
```

**Graceful-degradation rules** (how the loop reacts to each `false`):

| Capability false | Loop behavior |
|---|---|
| `supports_structured_output` | request text format; rely on the RALPH_STATUS text block + git/heuristic fallbacks; disable JSON-only signals below |
| `supports_token_usage` | skip token extraction; `MAX_TOKENS_PER_HOUR` is inert (call-rate limiting still applies) |
| `supports_permission_denials` | permission-denial circuit breaker (#101) disabled for this provider; log once |
| `supports_api_limit_detection` | API-limit recovery (#100/#183) disabled; log once |
| `supports_preassigned_session` | use `session_continuity` fallback (resume-id / continue-last / none) |
| `supports_streaming` | use non-streaming output; `--live` monitoring degrades to per-loop summaries |
| `supports_tool_restrictions` | tools cannot be constrained; log a security warning at startup |

`session_continuity` is an enum rather than a bare boolean because the matrix
has four tiers: **preassign** (Claude, Gemini — race-free id at create),
**resume-id** (resume a discovered id), **continue-last** (resume the most recent
session only), and **none**.

**Example: Claude reference adapter** (matches current behavior):

```json
{
  "supports_structured_output":   true,
  "supports_token_usage":         true,
  "supports_permission_denials":  true,
  "supports_api_limit_detection": true,
  "supports_preassigned_session": true,
  "session_continuity":           "resume-id",
  "supports_streaming":           true,
  "supports_tool_restrictions":   true
}
```

> Note: Claude *supports* preassigned sessions (`--session-id`), but the loop
> today uses `--resume <id>` (resume-by-id) per #151. The capability flag
> records the provider's ability (`true`); `session_continuity` records the
> strategy the adapter actually uses (`resume-id`). `[P1.2]` may switch Claude
> to `preassign` without changing this contract.

---

### 4. Adapter registration convention

**Directory layout.** One file per provider:

```
lib/agents/
  claude.sh      # reference adapter (P1.2)
  codex.sh       # P3.1 pilot
  gemini.sh      # P4.x
  ...
```

**Required exported functions.** Each `lib/agents/<provider>.sh` MUST define
exactly these three, namespaced by provider:

| Function | Returns | Mirrors today |
|---|---|---|
| `<provider>_build_command()` | populates the command array (e.g. `AGENT_CMD_ARGS`) | `build_claude_command()` populating `CLAUDE_CMD_ARGS` |
| `<provider>_normalize_output(raw_path, format_hint)` | normalized analysis JSON on stdout (§2) | `analyze_response()` writing `.analysis.*` |
| `<provider>_capabilities()` | capabilities JSON (§3) on stdout | — (new) |

**Lookup mechanism.** The active provider is selected by `AGENT_PROVIDER`
(resolved **env > CLI > `.ralphrc`**, matching ADR 0001), defaulting to
`claude`. The loader sources `lib/agents/${AGENT_PROVIDER}.sh` and dispatches to
the three namespaced functions. This mirrors the existing sandbox router
(`SANDBOX_PROVIDER` → `case` dispatch in `ralph_loop.sh`;
`get_sandbox_status()` routing docker/e2b in `lib/sandbox_docker.sh`).

> **Naming.** `AGENT_PROVIDER` is canonical, per accepted ADR 0001. Some earlier
> draft notes used `RALPH_AGENT_PROVIDER`; treat that only as a deprecated alias
> if back-compat is ever needed — new code and docs use `AGENT_PROVIDER`.

**Loader signature** (to be implemented in `[P1.1]`, sketched here for feasibility):

```
load_agent_adapter(provider) -> sources lib/agents/<provider>.sh; fails fast (logged) if missing or
                                 if any of the three required functions is undefined after sourcing
```

**Isolation rules.**

- Adapters MAY source shared utilities from `lib/` (e.g. `date_utils.sh`,
  `response_analyzer.sh` helpers).
- Adapters MUST NOT depend on or call into another adapter — no
  `lib/agents/claude.sh` ↔ `lib/agents/codex.sh` coupling. Shared logic belongs
  in `lib/`, not in a sibling adapter.
- Adapters MUST be loadable in isolation (sourcing one must not require another).

## Consequences

**Positive**

- `[P1.1]`/`[P1.2]` now have a concrete contract to build against; `[P2.1]`+
  providers conform to a single, version-stable interface.
- The core loop loses all provider-specific branching: it builds via
  `<provider>_build_command`, parses via `<provider>_normalize_output`, and
  gates features via `<provider>_capabilities`. New providers are added by
  dropping a file in `lib/agents/` — **no core-loop edits**.
- The normalized struct is exactly today's `.analysis.*` shape, so Claude's
  behavior is unchanged (the ADR 0001 invariant) and the existing exit-detection,
  circuit-breaker, and rate-limit logic keep working verbatim.

**Negative / costs**

- Adapter authors must conform to the full contract; a partial adapter (missing
  required fields or one of the three functions) fails fast at load.
- The normalized struct is now a published interface — changing it means
  revising every adapter. It must evolve additively (new optional fields with
  fallbacks), not by renaming/removing existing keys.
- Per-provider feature gating means the same Ralph run behaves differently across
  providers (token/permission/api-limit detection may be off); this is by design
  (ADR 0001) but is a support-surface cost.

**Neutral**

- No code in this ADR. It specifies the seam only; implementation begins at
  `[P1.1]` (loader + seam) and `[P1.2]` (Claude reference adapter).

### Migration path

1. `[P1.1]` — add `load_agent_adapter()` + the `AGENT_PROVIDER` lookup and the
   command/normalize/capabilities dispatch points in `ralph_loop.sh`, with
   Claude still inline behind the dispatch (no behavior change).
2. `[P1.2]` — move the Claude-specific logic (`build_claude_command()`, the
   `response_analyzer.sh` parsing relevant to a provider, session handling) into
   `lib/agents/claude.sh` implementing the three functions. Default
   `AGENT_PROVIDER=claude` keeps every existing run byte-for-byte identical.
3. `[P2.1]`+ — onboard providers one PR at a time, each a new `lib/agents/*.sh`
   declaring its capabilities so unsupported features degrade gracefully.

### Extensibility

Adding a provider is: (a) probe its `--help` (extend the ADR 0001 matrix), (b)
write `lib/agents/<provider>.sh` with the three functions and an honest
capabilities record, (c) set `AGENT_PROVIDER=<provider>`. No change to the core
loop, the exit-detection logic, or any other adapter.

### Feasibility review checklist (acceptance criterion)

Confirming this contract is implementable for the immediate downstream phases:

- [x] **`[P1.1]` (seam + loader):** lookup + dispatch model mirrors the existing
  `SANDBOX_PROVIDER` router already in the tree — proven pattern, no new
  mechanism required.
- [x] **`[P1.2]` (Claude adapter):** every Command-Build field maps 1:1 to a real
  flag in `build_claude_command()` (lines 1535–1627); the normalized struct is
  exactly the current `.analysis.*` shape. Refactor-in-place, zero behavior change.
- [x] **Divergent providers (matrix in ADR 0001):** capabilities enum/booleans
  cover the known gaps — Codex/Droid/OpenCode/Kilocode have no preassign
  (`session_continuity: resume-id`/`continue-last`); Copilot is text-only
  (`supports_structured_output:false` → RALPH_STATUS text block carries exit
  detection). No provider in the matrix violates the contract.
- [x] **Degradation is explicit:** every `false` capability has a defined,
  logged loop behavior — no silent misbehavior.

## References

- [ADR 0001 — Multi-Provider Agent Abstraction](0001-multi-provider-agent-abstraction.md) (`[P0.1]`, #310): decision + capability matrix this contract builds on.
- `ralph_loop.sh::build_claude_command()` (lines 1535–1627) — canonical Command-Build mapping.
- `lib/response_analyzer.sh` (`analyze_response()`, `parse_json_response()`, `detect_output_format()`, `write_session_id_file()`/`read_session_id_file()`) — canonical Output-Normalize + session source.
- Sandbox provider router precedent: `SANDBOX_PROVIDER` dispatch in `ralph_loop.sh`; `get_sandbox_status()` in `lib/sandbox_docker.sh`.
- Phased issue index: [`multi-provider`](https://github.com/frankbria/ralph-claude-code/labels/multi-provider) epic (issues #310–#325).
