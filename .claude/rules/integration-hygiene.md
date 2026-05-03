---
alwaysApply: true
---
# Integration Hygiene (TappsMCP)

When integrating with external services, sibling repos, or sub-agent reports, respect upstream sources of truth. Don't build parallel decision paths around something an authoritative system already does, and don't cite second-hand claims about external APIs without checking the producer.

## Linear is OAuth via the Claude Code plugin

Linear access in Claude Code sessions is OAuth via `mcp__plugin_linear_linear__*`. Tokens live in `~/.claude/.credentials.json` and are refreshed automatically.

- Never ask the user to generate, paste, or set a `LINEAR_API_KEY`.
- Don't propose tools (in tapps-mcp or elsewhere) that duplicate what the plugin does. The plugin is authoritative; a parallel API client is a second source of truth that drifts.
- When a separate Python process (e.g. the tapps-mcp server) needs Linear data, it cannot share the plugin's OAuth session across processes. The correct shape is **agent-driven fetch**: the agent calls the plugin, then passes the result to tapps-mcp for caching (`tapps_linear_snapshot_put`).
- If the user says "just use what you have" for anything Linear-auth-related, assume OAuth via the plugin — don't hunt for an env var.

## Don't mirror server-enforced state into the client

If the server already enforces a decision (authorization, routing, tier policy, quota, propagation rules), do not design a client flow that fetches the rules, caches them, and re-derives the same decision. Two sources of truth = guaranteed drift.

- Just make the call. Read the response for the outcome.
- If the response isn't structured enough to react to (refused / upgraded / why), ask for **response enrichment** on the action endpoint, not for a new read endpoint exposing the rules.
- Exceptions where client-side rule reads ARE fine: rendering UI ("is this button enabled?") where the server still re-checks on submit, and fast-path local shortcuts where a stale cache is acceptable because the server re-checks.

## Verify subagent claims about external APIs before citing them

When a research / Explore subagent reports that a field is exposed in an external API response (especially for a sibling repo), do not cite it as fact in a plan without verifying the **serialization site** — not just the model definition.

- "Field exists on the config model" ≠ "field is in the wire response."
- Before writing a plan that depends on an external response shape, open the actual response-building code (service / serializer / handler) and confirm the field is written into the dict/model being returned.
- Ask the subagent for the specific `file:line` of the serializer, not the model — or just Read it yourself before finalizing.

## How to apply

These three rules cluster around one principle: when something upstream is already enforcing a decision, exposing data, or producing output, **respect that as the source of truth**. Use it; don't shadow it.

Before writing client-side logic that talks to an external system, ask:

1. Does the server already enforce this decision? If yes, just call and react to the response — don't pre-check.
2. Is the auth path I'm proposing already solved by an existing plugin / OAuth session? If yes, use it; don't add a parallel credential.
3. Does this claim about an external API come from a subagent report, or did I read the producer's code myself? If the former, verify before citing.
