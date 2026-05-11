#!/bin/bash
# .ralph/hooks/on-linear-tool.sh
# PreToolUse hook for Linear MCP tools (TAP-1201).
#
# Writes the Linear issue identifier (TAP-NNNN-style) Claude is about to
# operate on into .ralph/.current_issue, atomically. ralph-monitor reads
# this file to display "Working on:" mid-loop, before the on-stop hook
# parses RALPH_STATUS at the end of the iteration.
#
# Wire-up (per-project, opt-in by editing .claude/settings.json):
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "mcp__plugin_linear_linear__.*",
#           "hooks": [
#             { "type": "command",
#               "command": "bash .ralph/hooks/on-linear-tool.sh" }
#           ]
#         }
#       ]
#     }
#   }
#
# Claude Code passes the tool input as JSON on stdin. We extract the first
# TAP-NNNN-style identifier we see in the input and write it. If no match,
# we exit 0 silently (the hook is observational, never blocking).

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

# Read tool input JSON from stdin. Cap at 64KB so a malformed payload
# can't burn the hook's runtime.
input=$(head -c 65536 2>/dev/null || true)
[[ -n "$input" ]] || exit 0

# Pull the first issue identifier. Linear issue IDs are uppercase prefix +
# dash + digits (e.g. TAP-1201, NLT-42). We deliberately match the prefix
# class loosely so this works for any Linear team.
issue=$(printf '%s' "$input" | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)
[[ -n "$issue" ]] || exit 0

# Atomic write to .current_issue. The monitor reads with `head -1` so a
# trailing newline is fine.
tmp="${RALPH_DIR}/.current_issue.tmp.$$"
printf '%s\n' "$issue" > "$tmp"
mv -f "$tmp" "${RALPH_DIR}/.current_issue"

exit 0
