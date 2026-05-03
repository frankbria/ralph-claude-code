# Smart task-type model routing with QA-driven Opus escalation

<!-- docsmcp:start:metadata -->
**Status:** Complete
**Priority:** P1 - High
**Estimated LOE:** ~1 day (1 developer, 6 stories shipped 2026-04-30)

<!-- docsmcp:end:metadata -->

---

<!-- docsmcp:start:purpose-intent -->
## Purpose & Intent

We are doing this so that Ralph routes each loop to the cheapest model that can credibly do the work, while a safety net forces Opus on the next attempt whenever the same Linear issue has failed QA three times in a row — replacing a 5-band complexity heuristic that collapsed to "Sonnet most of the time" and silently risked routing real coding tasks to Haiku.</purpose_and_intent>
<parameter name="goal">Replace the 5-band complexity-based router with a task-type router (docs/tools → Haiku, code → Sonnet floor, arch/research → Opus) and add per-Linear-issue QA failure tracking that escalates to Opus on the next attempt after 3 consecutive failures on the same issue.

<!-- docsmcp:end:purpose-intent -->

<!-- docsmcp:start:goal -->
## Goal

Describe how **Smart task-type model routing with QA-driven Opus escalation** will change the system. What measurable outcome proves this epic is complete?

<!-- docsmcp:end:goal -->

<!-- docsmcp:start:motivation -->
## Motivation

The 5-band complexity classifier collapses to "Sonnet most of the time" in practice and gives no signal that distinguishes actual coding work from docs cleanup or one-shot tooling jobs. That mis-routing has two costs: Haiku occasionally inheriting real coding tasks (correctness risk) and Sonnet running cheap docs/tools work that Haiku could handle for ~5x less cost. Separately, when Sonnet keeps hitting the same wall on a stuck Linear issue we have no escalation path — the loop just retries on the same model. A 3-failure Opus escalation gives us a deterministic, cheap safety net without paying Opus on every loop.

<!-- docsmcp:end:motivation -->

<!-- docsmcp:start:acceptance-criteria -->
## Acceptance Criteria

- [ ] All 6 child stories Done with passing BATS coverage
- [ ] version bumped to 2.11.0 in package.json and ralph_loop.sh RALPH_VERSION
- [ ] ralph-upgrade-project --all propagates the new templates/ralphrc.template + on-stop.sh hook to existing projects
- [ ] .ralph/.model_routing.jsonl logs every routing decision with task_type and reason fields
- [ ] .ralph/.qa_failures.json tracks per-issue counts and resets on PASSING

<!-- docsmcp:end:acceptance-criteria -->

<!-- docsmcp:start:stories -->
## Stories

### 0.1 -- ralph_classify_task_type in lib/complexity.sh + BATS

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement ralph_classify_task_type in lib/complexity.sh + bats
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** ralph_classify_task_type in lib/complexity.sh + BATS is implemented, tests pass, and documentation is updated.

---

### 0.2 -- Rewrite ralph_select_model for type-based dispatch + retry-count opus escalation

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement rewrite ralph_select_model for type-based dispatch + retry-count opus escalation
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Rewrite ralph_select_model for type-based dispatch + retry-count opus escalation is implemented, tests pass, and documentation is updated.

---

### 0.3 -- qa_failures.sh state tracking + on-stop hook integration

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement qa_failures.sh state tracking + on-stop hook integration
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** qa_failures.sh state tracking + on-stop hook integration is implemented, tests pass, and documentation is updated.

---

### 0.4 -- Wire QA count from .ralph/.qa_failures.json through build_loop_context into build_claude_command

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement wire qa count from .ralph/.qa_failures.json through build_loop_context into build_claude_command
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Wire QA count from .ralph/.qa_failures.json through build_loop_context into build_claude_command is implemented, tests pass, and documentation is updated.

---

### 0.5 -- Update templates/ralphrc.template MODEL ROUTING section + bump version + CLAUDE.md

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement update templates/ralphrc.template model routing section + bump version + claude.md
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Update templates/ralphrc.template MODEL ROUTING section + bump version + CLAUDE.md is implemented, tests pass, and documentation is updated.

---

### 0.6 -- Docs + observability examples (jq queries on .model_routing.jsonl)

**Points:** TBD

Describe what this story delivers...

**Tasks:**
- [ ] Implement docs + observability examples (jq queries on .model_routing.jsonl)
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Docs + observability examples (jq queries on .model_routing.jsonl) is implemented, tests pass, and documentation is updated.

---

<!-- docsmcp:end:stories -->

<!-- docsmcp:start:technical-notes -->
## Technical Notes

- Document architecture decisions for **Smart task-type model routing with QA-driven Opus escalation**...

<!-- docsmcp:end:technical-notes -->

<!-- docsmcp:start:non-goals -->
## Out of Scope / Future Considerations

- Removing the deprecated RALPH_MODEL_TRIVIAL/SMALL/ROUTINE/COMPLEX env vars (kept for backwards compat with one-time WARN)
- changing the 3-failure threshold to a different number
- adding model routing for sub-agents (only the main agent is routed)

<!-- docsmcp:end:non-goals -->
