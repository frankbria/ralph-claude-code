# Ralph for Claude Code — Vision: Context Discipline for `/goal`

*Status: vision / planning document · Drafted 2026-10-06 · Owner: Frank Bria*
*Purpose: the reference for writing and prioritizing GitHub issues in `ralph-claude-code` for the mod-based rewrite.*

---

## 1. Why this exists

Claude Code's native `/goal` (v2.1.139+) now does what Ralph's outer bash loop did: it keeps Claude working, turn after turn, until a completion condition is met, judged by a separate evaluator model after each turn. Maintaining a parallel loop that duplicates a built-in is no longer a good use of the project.

What `/goal` does **not** do is keep the context healthy. In practice:

- Context accumulates for the life of the goal, often to ~1M tokens, and every turn drags all of it along, which costs money and quality (context rot).
- `/clear` and `/compact` both destroy the active goal, so the only ways to shed context also end the work.
- The evaluator judges only what is visible in the current transcript. After any reset, earlier evidence of progress is gone.

Ralph's founding principle was **fresh context per iteration**. That principle is now the missing piece. The new Ralph keeps the principle and drops the loop.

**One-line vision:** *Ralph makes long-running `/goal` work sustainable by rotating context at safe points and rebuilding each fresh session from the right information, rather than from an empty window or an ever-growing transcript.*

## 2. What Ralph is (and isn't) after the rewrite

Ralph becomes a **Claude Code plugin containing a mod** (TypeScript event handlers running inside Claude Code, v2.1.287+). It is a companion to native `/goal`, not a replacement.

**In scope:**

- Persisting the active goal outside the session, so it survives `/clear`, `/compact` and restarts.
- Monitoring context usage and rotating context at turn boundaries.
- Writing a handoff note before a rotation and re-arming the goal after it.
- Building the context packet that rehydrates a fresh session, through a pluggable provider interface.
- Showing status: goal, context use, number of rotations.

**Explicitly out of scope:**

- **Replacing `/goal` or its evaluator.** Ralph re-arms the native goal; it does not run its own completion loop.
- **Verification or proof of completion.** That belongs to CodeFRAME (see `codeframe-vision-proof-layer.md`).
- **Building code maps, indexes or memories.** Ralph consumes these from existing tools through providers. It does not create them.
- **Approving tool calls or changing permissions.** Ralph never approves anything. See §8.
- **Multi-agent orchestration.**

## 3. The loop Ralph adds

```
user: /goal <condition>
   │
   ▼
[Goal Keeper] captures the condition → .ralph/goal.json
   │
   ▼
 ... turns run under native /goal ...
   │
[Context Monitor] on each turn.complete: check $.session.usage()
   │  below threshold → do nothing
   │  above threshold, and the turn ended cleanly →
   ▼
[Handoff Writer] $.model.fork(): "write the handoff" → .ralph/handoff.md
   │
   ▼
[Rotator] trigger /clear (see M0 risk) → new session
   │
   ▼
[Rehydrator] on session.start after a clear: build the context packet from providers
   │
   ▼
re-submit `/goal <condition>` + packet → native /goal resumes in a small context
```

### The subtle requirement: evidence must be re-provable

After a rotation, the native evaluator sees only the new transcript. A condition such as "all tests in test/auth pass" is fine, because Claude can rerun the tests and show the result. A condition that depends on earlier history, such as "after migrating all 40 call sites", may never be judged met after a reset, because the earlier evidence is gone.

Ralph must handle this deliberately:

- The handoff note records the evidence achieved so far.
- The rehydration prompt tells Claude to re-surface current-state evidence early, for example by rerunning checks.
- `/ralph lint-goal` warns when a condition depends on history rather than current state.

## 4. Architecture

### 4.1 Components

| Component | Event(s) | Responsibility |
|---|---|---|
| Goal Keeper | `prompt.submit` (watches for `/goal …`), `session.start` | Capture, store and restore the goal condition and its state (active, paused, met, cleared). |
| Context Monitor | `turn.complete`, `turn.step` (usage) | Track context size and decide when to rotate: only at a clean turn boundary, never when `isAborted`, never mid-subagent. |
| Handoff Writer | called by the Monitor | Use `$.model.fork` to produce a structured handoff (template in §4.3); cheap because it is served from the prompt cache. |
| Rotator | called by the Monitor | Clear the session and request re-arming. Several strategies, tried in order (see M0). |
| Rehydrator | `session.start` / `classic.SessionStart` (source = clear) | Assemble the context packet from providers within a token budget; re-submit the goal. |
| Status UI | `ui.render`, `$.ui.status` | Status line: `ralph: goal active · ctx 212K/1M · rotation 3`. Optional pane with the handoff and event history. |
| Commands | `command.run` | `/ralph status`, `/ralph rotate` (manual), `/ralph pause`, `/ralph resume`, `/ralph config`, `/ralph lint-goal`. |

### 4.2 State (in the repo, inspectable, git-ignorable)

```
.ralph/
  goal.json          # condition, state, sessionId, rotations, createdAt, budgets
  handoff.md         # latest handoff note (previous ones archived in handoffs/)
  handoffs/          # timestamped history (capped)
  events.jsonl       # append-only log: captured, rotated, rearmed, paused, failed
  config.json        # thresholds, provider list, budgets (or plugin userConfig)
```

Key all state by **session ID** from the start. Potarix/claude-goal documents the failure mode: keying by terminal or working directory makes concurrent sessions in the same repo share one goal.

### 4.3 Handoff template (v1)

1. **Goal**: the exact condition, verbatim.
2. **Done so far**: concrete and verifiable (files changed, tests now passing, commits).
3. **Evidence to re-surface**: the commands to rerun to show current progress.
4. **In flight**: what was being attempted at the moment of rotation, and the hypothesis behind it.
5. **Next steps**: ordered, at most five.
6. **Dead ends**: approaches tried and abandoned, with the reason, so the fresh session doesn't repeat them.
7. **Pointers**: key files and docs to read first.

### 4.4 The Context Provider interface (the extensibility point)

Rehydration is built from **providers**, so a fresh session can start from more than the handoff note: code maps, codebase memories, LSP diagnostics, docs, requirements. This interface is **shared with CodeFRAME** and must be designed as a public contract from v1.

```ts
interface ContextProvider {
  id: string                       // "handoff", "git-state", "docs", "codemap:<tool>", ...
  priority: number                 // lower number = included first when the budget is tight
  maxTokens: number                // this provider's own cap
  isAvailable(io: IO): Promise<boolean>
  collect(io: IO, ctx: PacketContext): Promise<ContextSection | null>
}

interface ContextSection {
  providerId: string
  title: string
  body: string                     // markdown
  estTokens: number
  freshness?: string               // e.g. commit sha or timestamp the content reflects
}

interface PacketContext {
  goal: GoalState
  sessionId: string
  repoRoot: string
  totalBudgetTokens: number
}
```

Design rules:

- **I/O goes through an injected `IO` interface.** The mod's hooks module has no Node.js APIs; files, processes and network are only reachable through `$.fs`, `$.process` and `$.http`. The packet builder therefore takes `IO` as a parameter. The mod implements `IO` with `$`, and a CLI or tests implement it with Node or fakes. This keeps the core portable to other agents later.
- **The packet builder is deterministic** given its provider outputs: sort by priority, apply per-provider caps, then the total budget, then render.
- **A failing provider is skipped, never fatal.** Each failure is logged to `events.jsonl`.
- **Ship the contract as a tiny standalone package** (working name `context-packet`) that both Ralph and CodeFRAME import. Ralph owns it first because Ralph ships first.

Built-in providers by milestone: `handoff` (M3), `goal` (M3), `git-state` (M3: branch, diff stat, recent commits), `docs` (M3: user-listed files such as the PRD or fix_plan), then adapters for third-party code-map, memory and LSP tools (M4).

## 5. Milestones

Each milestone corresponds to a GitHub milestone. The bullets are seeds for issues; each issue should state its acceptance criteria.

### M0 — Spike: confirm the platform unknowns (gate for everything else)

These are unverified assumptions. Each gets an issue with a go/no-go result and a small reproduction mod.

- **U1:** Does `prompt.submit` fire for slash-command input such as `/goal …`, with the raw text available? If not, capture the goal another way: wrap it in a `/ralph goal …` command, or read the native goal state if any API exposes it.
- **U2:** Can a mod trigger `/clear`, for example with `$.prompt.submit({ text: '/clear', asUser: true })` while the session is idle? *Caution:* an open Claude Code issue reports mid-turn commands being misclassified as prompt text, so only submit when idle.
- **U3:** Can a mod re-arm the goal by submitting `/goal <condition>` after a clear, and does the native goal then start correctly?
- **U4:** After `/clear`, does the mod's `session.start` fire with enough information to know it follows a clear? Does `classic.SessionStart` carry `source: "clear"`? Does module state survive, or must everything be read back from `.ralph/`?
- **U5:** Which fields does `$.session.usage()` return, and are they reliable enough to use as the rotation trigger?
- **U6:** What does `$.model.fork` cost in practice at 500K+ tokens of context?

**Fallback if U2 fails:** semi-automatic rotation. At the threshold, Ralph writes the handoff and asks, via `$.ui.ask`: "Context at 600K. Rotate now?" The user runs `/clear`, and Ralph re-arms automatically on the next session start (U3 and U4). This is still a large improvement over losing the goal.

**Exit criterion:** a written decision record in `docs/adr/0001-rotation-strategy.md`.

### M1 — Goal persistence

- Capture the goal on submission; persist it to `.ralph/goal.json`, keyed by session.
- Restore and re-arm the goal after `/clear` and `/compact` (manual ones count).
- `/ralph status`, `/ralph pause`, `/ralph resume`.
- Reconcile with the native lifecycle: when the native goal is met or cleared by the user, Ralph marks it `met` or `cleared` and does **not** re-arm.

**Done when:** a goal set before a manual `/clear` resumes automatically afterwards, and a goal the user clears stays cleared.

### M2 — Automatic rotation

- Threshold configuration: absolute tokens and/or a percentage of the window, through plugin `userConfig`.
- Rotate only at clean turn boundaries; never while a subagent is running or after an interrupted turn.
- Handoff Writer using the §4.3 template.
- Loop guards: minimum turns between rotations, a maximum rotation count per goal, and a pause with a status warning when two consecutive rotations show no progress (no new commits or checks).

**Done when:** a long goal runs past three rotations without the context exceeding the threshold, and without repeating any abandoned dead end recorded in a handoff.

### M3 — Rehydration packet v1

- Publish the `context-packet` package with the §4.4 interface and builder.
- Built-in providers: `goal`, `handoff`, `git-state`, `docs`.
- The rehydration prompt includes the instruction to re-surface evidence (see §3).
- `/ralph packet` prints the packet that would be injected, for debugging and trust.

### M4 — Provider ecosystem

- Adapters for third-party context sources: code maps and repository indexes, codebase-memory tools, LSP diagnostics. Each adapter reads that tool's output; Ralph does not re-implement any of them.
- A provider authoring guide in `docs/providers.md`, plus a template repository.
- Token budgeting across providers, with an option to have a small model summarize sections that exceed their budget.

### M5 — Observability and evaluation

- Status pane: goal, context-use sparkline, rotation history, current handoff.
- `events.jsonl` analytics: tokens per turn before and after Ralph, rotations per goal, goals completed.
- **Evals** with `claude plugin eval`, comparing a set of long-goal tasks against a no-plugin baseline: completion rate, total tokens, wall time, repeated-work incidents. Gate CI on not regressing.

### M6 — Transition of legacy Ralph

- Move the bash loop to `legacy/` in maintenance mode; the README leads with the mod.
- Migration guide: "From Ralph loop to `/goal` + Ralph." The concepts map directly: the fix_plan becomes the `docs` provider, exit detection becomes the native goal, the circuit breaker becomes the M2 loop guards.

## 6. Success metrics

- **Primary:** median peak context per long goal falls by at least 70% compared with plain `/goal`, with goal completion rate the same or better on the eval suite.
- **Secondary:** tokens per turn (and therefore cost) reduced; no increase in repeated-work incidents after rotation; zero lost goals across `/clear` and `/compact`.
- **Adoption:** installs from the marketplace; legacy users migrated.

## 7. Risks

- **Anthropic ships native context rotation for `/goal`.** Likely eventually. Response: Ralph's lasting value is the provider and packet layer and its link to CodeFRAME, not rotation itself. Keep rotation thin.
- **Handoff drift.** Summaries lose or distort facts. Mitigations: a structured template, re-surfacing evidence, and verifiable claims only.
- **Rotation during delicate state** (half-applied migrations, uncommitted work). Rotate only at clean boundaries; the handoff captures `git status`; optionally require a clean or WIP-committed tree.
- **Platform churn.** The mod API is new; pin a minimum version and cover each event dependency with tests (`docs/en/plugins/mods/test`).
- **Collisions with other goal plugins** (pyyush/goal, chrischabot/claude-code-goal, jthack and Potarix claude-goal). Detect and warn rather than fight over the Stop hook.

## 8. Security posture

- Mods are not sandboxed and run with the user's permissions. Ralph should therefore do as little as possible: no network access by default, file writes only under `.ralph/`, and the only processes it runs are read-only `git` commands for the `git-state` provider.
- **Ralph never approves tool calls.** No `tool.check` handlers and no `allow` decisions.
- `claude plugin validate` output (`hooks:` and `calls:`) is published in the README and checked in CI, so users can see exactly what Ralph touches.

## 9. Relationship to CodeFRAME

Ralph is the **free, open-source context layer**. CodeFRAME builds on the same `context-packet` contract and adds two premium providers and a verification layer:

- a **requirements provider**: the active acceptance criterion and its proof status, which is the strongest rehydration context there is;
- **proof gates**: deterministic completion checks and an evidence ledger.

The CodeFRAME plugin declares Ralph as a plugin dependency instead of duplicating it. Any context-layer feature belongs in Ralph; anything about requirements or proof belongs in CodeFRAME.

## 10. Guidance for writing issues

- **Title format:** `[M#] <verb> <thing>`, for example `[M2] Rotate only at clean turn boundaries`.
- **Each issue includes:** the milestone, the component (§4.1), acceptance criteria written as checks that can be run or demonstrated, and any platform unknown it depends on (U1–U6).
- **Labels:** `milestone/M#`, `component/<name>`, `platform-unknown`, `provider`, `contract-change`. Any change to the §4.4 interface needs the `contract-change` label and a note on CodeFRAME compatibility.
- **Definition of done:** tests written with the mods test harness, an updated `docs/`, and `claude plugin validate` passing.
