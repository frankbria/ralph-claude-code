# Enforce tapps-mcp + docs-mcp quality gates via Ralph-loop hooks

<!-- docsmcp:start:metadata -->
**Status:** Proposed
**Priority:** P1 - High

<!-- docsmcp:end:metadata -->

---

<!-- docsmcp:start:purpose-intent -->
## Purpose & Intent

We are doing this so that Ralph-managed projects cannot ship code that skipped the mandatory tapps-mcp / docs-mcp quality gates. A 23-loop AgentForge audit (2026-04-14) recorded 472 tool calls but only 13 MCP calls (2.7%): ten tapps_session_start, one tapps_quick_check, two misc. Zero calls to tapps_validate_changed, tapps_quality_gate, tapps_checklist, tapps_score_file, tapps_lookup_docs, any docs_*, or any brain_* tool — across 38 file edits and 21 completed loops. The agents-md template and the tapps-pipeline-md rule define the workflow but only tapps_session_start is enforced via the SessionStart hook; everything else is advisory and gets skipped under model time pressure.</purpose_and_intent>
<parameter name="goal">Move quality-gate enforcement from documentation to PreToolUse / PostToolUse / Stop hooks shipped by tapps_init / tapps_upgrade. After this epic lands, EXIT_SIGNAL=true cannot fire on a project that skipped quality gates, save_issue cannot fire without a prior docs_validate_linear_issue, and library imports cannot survive without a prior tapps_lookup_docs.

<!-- docsmcp:end:purpose-intent -->

<!-- docsmcp:start:goal -->
## Goal

Describe how **Enforce tapps-mcp + docs-mcp quality gates via Ralph-loop hooks** will change the system. What measurable outcome proves this epic is complete?

<!-- docsmcp:end:goal -->

<!-- docsmcp:start:motivation -->
## Motivation

The AgentForge audit found 38 edits to backend (FastAPI / SQLAlchemy / credential_injector / routes/secrets) and frontend (React / TypeScript) files shipped without any quality gate or docs lookup. tapps_security_scan was never called despite credential and auth code being touched. Fixing this in the harness fixes it once for every Ralph project.

<!-- docsmcp:end:motivation -->

<!-- docsmcp:start:acceptance-criteria -->
## Acceptance Criteria

- [ ] PreToolUse hook tracks Edit/Write paths in a per-loop manifest
- [ ] Stop hook blocks EXIT_SIGNAL=true when modified .py/.ts files lack a subsequent tapps_quick_check / tapps_validate_changed / tapps_quality_gate
- [ ] PostToolUse hook on Edit detects new external imports and requires tapps_lookup_docs in the same loop
- [ ] PreToolUse hook on save_issue requires a docs_validate_linear_issue with agent_ready=true earlier in the same turn cluster
- [ ] Stop hook requires tapps_checklist when EXIT_SIGNAL=true
- [ ] all hooks ship via tapps_init and tapps_upgrade with a managed-sidecar manifest
- [ ] re-running the AgentForge audit on a fresh 10-loop session shows MCP-call ratio rising from 2.7% to >=30% with zero quality-gate skips

<!-- docsmcp:end:acceptance-criteria -->

<!-- docsmcp:start:stories -->
## Stories

### 0.1 -- Block EXIT_SIGNAL when modified files skipped tapps quality gates

**Points:** 5

Describe what this story delivers...

**Tasks:**
- [ ] Implement block exit_signal when modified files skipped tapps quality gates
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Block EXIT_SIGNAL when modified files skipped tapps quality gates is implemented, tests pass, and documentation is updated.

---

### 0.2 -- Require tapps_lookup_docs before new external library imports

**Points:** 3

Describe what this story delivers...

**Tasks:**
- [ ] Implement require tapps_lookup_docs before new external library imports
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Require tapps_lookup_docs before new external library imports is implemented, tests pass, and documentation is updated.

---

### 0.3 -- Require tapps_checklist on EXIT_SIGNAL=true

**Points:** 2

Describe what this story delivers...

**Tasks:**
- [ ] Implement require tapps_checklist on exit_signal=true
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Require tapps_checklist on EXIT_SIGNAL=true is implemented, tests pass, and documentation is updated.

---

### 0.4 -- Make docs_validate_linear_issue mandatory for save_issue (hard block)

**Points:** 2

Describe what this story delivers...

**Tasks:**
- [ ] Implement make docs_validate_linear_issue mandatory for save_issue (hard block)
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Make docs_validate_linear_issue mandatory for save_issue (hard block) is implemented, tests pass, and documentation is updated.

---

### 0.5 -- Surface tapps-brain + tapps_security_scan + tapps_score_file in ralph workflow

**Points:** 2

Describe what this story delivers...

**Tasks:**
- [ ] Implement surface tapps-brain + tapps_security_scan + tapps_score_file in ralph workflow
- [ ] Write unit tests
- [ ] Update documentation

**Definition of Done:** Surface tapps-brain + tapps_security_scan + tapps_score_file in ralph workflow is implemented, tests pass, and documentation is updated.

---

<!-- docsmcp:end:stories -->

<!-- docsmcp:start:technical-notes -->
## Technical Notes

- Document architecture decisions for **Enforce tapps-mcp + docs-mcp quality gates via Ralph-loop hooks**...

<!-- docsmcp:end:technical-notes -->

<!-- docsmcp:start:non-goals -->
## Out of Scope / Future Considerations

- Retrofitting historical sessions
- adding a new MCP tool surface
- replacing AGENTS.md guidance (the prose still applies — this epic adds enforcement on top)

<!-- docsmcp:end:non-goals -->
