#!/usr/bin/env bash
# tapps-mcp-hook-version: 3.8.0
# TappsMCP PostToolUse hook — Linear gate sentinel writer (TAP-981)
# Writes .tapps-mcp/.linear-validate-sentinel with current epoch seconds
# whenever an agent calls mcp__docs-mcp__docs_validate_linear_issue. Paired
# with tapps-pre-linear-write.sh which reads the sentinel to decide whether
# to allow a downstream save_issue.
INPUT=$(cat)
PYBIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
TOOL=$(echo "$INPUT" | "$PYBIN" -c   "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('tool_name') or d.get('toolName') or '')
except Exception:
    print('')" 2>/dev/null)
case "$TOOL" in
  mcp__docs-mcp__docs_validate_linear_issue|docs_validate_linear_issue)
    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    mkdir -p "$ROOT/.tapps-mcp" 2>/dev/null
    date +%s > "$ROOT/.tapps-mcp/.linear-validate-sentinel" 2>/dev/null
    ;;
esac
exit 0
