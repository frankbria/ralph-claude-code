<!-- tapps-generated: v3.8.0 -->
# Copilot Instructions

This project uses **TappsMCP** (Code Quality MCP Server) for automated
quality analysis. When TappsMCP is available as an MCP server, follow
the pipeline below.

## TappsMCP Quality Pipeline

### Stage 1: Discover
- Run `tapps_session_start` at the beginning of each session to initialize context

### Stage 2: Research
- Use `tapps_lookup_docs` to verify library API signatures
- Use `tapps_impact_analysis` before refactoring

### Stage 3: Develop
- After editing Python files, run `tapps_quick_check`
- If quick check flags issues, run `tapps_score_file` for details
- Fix issues before moving to the next file

### Stage 4: Validate
- Run `tapps_validate_changed` with explicit `file_paths` before declaring work complete (default is quick mode; `quick=false` is a last resort)
- Run `tapps_security_scan` on security-sensitive files
- Ensure overall score >= 70 and no HIGH security findings

### Stage 5: Verify
- Run `tapps_quality_gate` for pass/fail verdict
- Run `tapps_checklist` to confirm all steps were completed

## Code Standards

- Python 3.12+ with `from __future__ import annotations`
- Type annotations on all functions (`mypy --strict`)
- `structlog` for logging, `pathlib.Path` for file paths
- `ruff` for linting and formatting (line length: 100)
- All file operations through the path validator
