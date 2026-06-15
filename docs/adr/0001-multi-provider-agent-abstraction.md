# ADR 0001: Multi-Provider Agent Abstraction

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Frank Bria
- **Tracking issue:** [#310](https://github.com/frankbria/ralph-claude-code/issues/310) (`[P0.1]`)
- **Epic / label:** `multi-provider` (issues [#310](https://github.com/frankbria/ralph-claude-code/issues/310)–[#325](https://github.com/frankbria/ralph-claude-code/issues/325))
- **Supersedes / relates:** Phased plan tracked under the [`multi-provider`](https://github.com/frankbria/ralph-claude-code/labels/multi-provider) epic (issues #310–#325). Next ADR: `0002-agent-adapter-contract.md` (`[P0.2]`, #311).

## Context

Ralph drives an autonomous development loop by repeatedly invoking the `claude`
CLI in headless mode (`claude -p …`). That coupling makes Ralph's viability
depend on a single vendor decision: per the project owner, Anthropic is moving
`claude -p` headless billing toward API credits (no OAuth / subscription quota).
If headless Claude becomes API-metered, every Ralph run is billed per token with
no subscription-quota path — an existential risk for a tool whose value is
*running an agent in a loop for a long time*.

Two ways out were considered:

1. **Drive the subscription TUI** (the Maestro / `maestro-p` approach): wrap the
   interactive `claude` TUI with `node-pty`, type the prompt into the terminal,
   and tail the on-disk JSONL transcript
   (`$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-id>.jsonl`) to harvest the
   model's output while spending Max-plan subscription quota instead of API
   credits.
2. **Become provider-agnostic**: make "which agent CLI runs the loop" a
   configuration flag, so Codex, Gemini, OpenCode, Droid, Kilocode, Copilot, or
   any future headless coding CLI can drive Ralph. Headless `claude` stays as one
   (API-billed) option among many.

This ADR ratifies the decision between them and records the **live-probed
capability matrix** that every later phase (the adapter contract, the abstraction
seam, the per-provider adapters) builds on.

## Decision

**Ralph will become provider-agnostic (option 2).** "Which agent runs" becomes a
config flag (`AGENT_PROVIDER`, resolved env > CLI > `.ralphrc`), with **Claude as
the reference adapter and byte-for-byte unchanged default behavior** until a
different provider is selected. The work is sequenced as an abstraction-first,
incremental rollout — the phased issue index lives in the
[`multi-provider`](https://github.com/frankbria/ralph-claude-code/labels/multi-provider)
epic (issues #310–#325, work order #310 → #311 → #312 → … → #325).

### Rejected alternative: driving the subscription TUI

The `maestro-p` approach is clever and genuinely solves the billing problem, but
it is rejected:

- **Maintenance treadmill.** It depends on the *interactive* TUI's rendering and
  the private on-disk JSONL transcript layout — both undocumented internals that
  Anthropic can change at any release, breaking the harness with no notice.
- **ToS / detection risk.** Automating the interactive client to spend
  subscription quota at machine scale is adversarial to the vendor's billing
  intent and plausibly against terms; a detection/enforcement change could
  disable it (or the account) overnight.
- **Single-vendor lock-in remains.** Even if it worked forever, it only buys
  cheaper *Claude*. It does nothing for users who prefer or already pay for
  another model.

The provider-agnostic path instead treats vendor billing decisions as *market
signals* — "let the market decide." Each provider is one option; if one becomes
expensive or unavailable, users switch a flag rather than abandon Ralph.

## Provider capability matrix

Probed live against the installed CLIs on 2026-06-15 by reading each tool's
`--help` (and relevant subcommand `--help`). Versions cited so the matrix is
reproducible:

| Provider | Version | Probe |
|---|---|---|
| Claude (reference) | `2.1.177` | `claude --version` |
| Codex | `codex-cli 0.137.0` | `codex --version` |
| Gemini | `0.46.0` | `gemini --version` |
| OpenCode | `1.4.0` | `opencode --version` |
| Kilocode | `0.22.0` | `kilocode --version` |
| Droid | `0.147.0` | `droid --version` |
| Copilot | `GitHub Copilot CLI 0.0.404` | `copilot --version` |

| Provider | Headless invoke | Structured output | Resume by id | Pre-assign session | Granular perms | Model flag |
|---|---|---|---|---|---|---|
| **Claude** (ref) | `-p`/`--print <prompt>` | `--output-format json\|stream-json` | `--resume <id>` | `--session-id <uuid>` | `--allowedTools`/`--disallowedTools` | `--model` |
| **Gemini** | `-p`/`--prompt` | `-o`/`--output-format json\|stream-json` | `-r`/`--resume` | `--session-id <uuid>` | `--approval-mode default\|auto_edit\|yolo\|plan` | `-m`/`--model` |
| **Codex** | `codex exec [PROMPT]` (stdin ok) | `--json` (JSONL) · `--output-schema <file>` · `-o`/`--output-last-message <file>` | `codex exec resume <id>` (`--last`) | — | `-s`/`--sandbox <mode>` · `--dangerously-bypass-approvals-and-sandbox` | `-m`/`--model` |
| **Droid** | `droid exec [prompt]` | `-o`/`--output-format json` (default `text`) · `--input-format stream-json\|stream-jsonrpc` | `-s`/`--session-id <id>` · `--fork <id>` | — | `--auto low\|medium\|high` · `--skip-permissions-unsafe` | `-m`/`--model` (default `claude-opus-4-8`) |
| **OpenCode** | `opencode run [message]` | `--format default\|json` (raw JSON events) | `-s`/`--session <id>` · `-c`/`--continue` · `--fork` | — | `--dangerously-skip-permissions` | `-m`/`--model provider/model` |
| **Kilocode** | `kilocode --auto` | `-j`/`--json` (requires `--auto`) · `-i`/`--json-io` (bidirectional) | `-s`/`--session <id>` · `-c`/`--continue` (last) · `-f`/`--fork <shareId>` | — | `--yolo` | `-mo`/`--model` |
| **Copilot** | `-p`/`--prompt <text>` | **TEXT ONLY** (`-s`/`--silent`, `--stream <mode>`) | `--resume [id]` · `--continue` | — | `--allow-tool`/`--deny-tool`/`--allow-all` | `--model` |

Notes on accuracy (refinements found while re-probing `--help` for this ADR, vs.
the earlier draft matrix from the 2026-06-14 probe):

- **Kilocode supports resume-by-id** via `-s`/`--session <id>` (plus
  `-c`/`--continue` for last-only and `-f`/`--fork`). The draft had listed only
  continue-last.
- **Codex `--json` emits JSONL**; the last assistant message can be captured to a
  file with `-o`/`--output-last-message`, and an optional `--output-schema`
  constrains the final response shape.
- **Droid's `-o`/`--output-format` defaults to `text`** — JSON must be requested
  explicitly; multi-turn/streaming uses `--input-format stream-json` /
  `stream-jsonrpc`. Default model is `claude-opus-4-8`.
- **Only Claude and Gemini offer race-free pre-assigned session ids**
  (`--session-id <uuid>` *at create*). Every other provider supports resume, but
  only by a discovered id or continue-last.
- **Copilot is the degraded case**: no machine-readable output flag at all
  (`--silent` / `--stream` produce text), so any feature that parses structured
  events is unavailable.

## Feature portability

What each adapter must declare in its capabilities record, and which of Ralph's
existing features survive the move:

- **Exit detection via the `RALPH_STATUS` text block — portable to *all*
  providers.** It is text the agent emits, not a provider JSON field, so it works
  identically everywhere. This stays Ralph's **primary** completion signal; it is
  the lowest-risk thing to carry across providers.
- **Token counting / `MAX_TOKENS_PER_HOUR` — provider-gated.** Only works where
  the event stream carries usage (Claude, Gemini, Codex, Droid likely; OpenCode /
  Kilocode TBD; **Copilot: none → disable**).
- **Permission-denial circuit breaker (#101) — provider-gated.** Requires
  machine-readable denial events. Several CLIs have rich permission *flags*
  (Claude, Copilot) but only some emit parseable denials → gate per provider.
- **API-limit detection (#100 / #183) — provider-gated.** Today it keys off
  Claude's specific `rate_limit_event` JSON shape; each provider needs its own
  pattern or the feature is disabled for it.
- **Session continuity — universal, with a quality tier.** All providers support
  resume; only Claude and Gemini support *pre-assigned* (race-free) session ids.
  Others fall back to resume-by-discovered-id or continue-last.

The governing rule (carried into every later phase): **unsupported features
degrade with a logged warning, never a silent misbehavior**, and Claude's
behavior is unchanged until a different `AGENT_PROVIDER` is selected.

## Consequences

**Positive**

- Vendor billing/availability changes become a config flip, not an existential
  event.
- A stable, version-cited reference matrix anchors `[P0.2]` (adapter contract)
  and all Phase 1+ implementation work.
- Users gain optionality (subscription Claude TUI is *not* required to escape
  per-token billing — a different provider is).

**Negative / costs**

- Ongoing per-provider maintenance: seven CLIs with divergent flags, output
  formats, and session models; each `--help` can drift between releases (this ADR
  is a point-in-time snapshot — re-probe when bumping a provider).
- Feature surface is non-uniform: token/permission/api-limit detection must be
  gated, so the same Ralph run behaves differently across providers.
- Copilot's text-only output forces a genuinely degraded adapter.

**Neutral**

- No code changes in this ADR. It ratifies direction and the matrix only;
  implementation begins at `[P0.2]`/`[P1.1]`.

## References

- Phased issue index and work order: [`multi-provider`](https://github.com/frankbria/ralph-claude-code/labels/multi-provider) epic (issues #310–#325)
- Capability probes: `--help` output of claude `2.1.177`, codex `0.137.0`,
  gemini `0.46.0`, opencode `1.4.0`, kilocode `0.22.0`, droid `0.147.0`,
  copilot `0.0.404` (captured 2026-06-15).
- Rejected approach reference: Maestro / `maestro-p` subscription-TUI driver.
