# TappsMCP developer workflow

Short reference for Setup, Update, and Daily use. For full tool reference see AGENTS.md.

## Setup (once per project)

- Run tapps_doctor (optional) to verify MCP and checkers.
- Run tapps_init to bootstrap AGENTS.md, rules, hooks, skills.

## Update (after upgrading TappsMCP)

- After upgrading TappsMCP (or pulling a new version), run tapps_upgrade. Optionally run tapps_doctor to verify.

## Daily workflow

Every session:

- 1. FIRST: Call tapps_session_start() to initialize the session
- 2. BEFORE using any library API: Call tapps_lookup_docs(library='<name>')
- 3. DURING edits: Call tapps_quick_check(file_path='<path>') after each change
- 4. BEFORE declaring done: Call tapps_validate_changed() - all gates MUST pass
- 5. FINAL step: Call tapps_checklist(task_type='<type>') to verify completeness

Use `task_type` in tapps_checklist: feature, bugfix, refactor, security, review, or epic.

## When to use other tools

- **tapps_lookup_docs** — Before using any external library API.
- **tapps_impact_analysis** — Before changing or removing a file's public API.
- **tapps_security_scan** — For auth, API routes, secrets, input validation.
- **tapps_validate_config** — When editing Dockerfile, docker-compose, or infra config.
