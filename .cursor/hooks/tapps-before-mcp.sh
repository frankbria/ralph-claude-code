#!/usr/bin/env bash
# tapps-mcp-hook-version: 3.8.0
# TappsMCP beforeMCPExecution hook
# Logs MCP tool invocations and reminds to call session_start.
INPUT=$(cat)
PY="import sys,json; d=json.load(sys.stdin); print(d.get('tool','unknown'))"
PYBIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
TOOL=$(echo "$INPUT" | "$PYBIN" -c "$PY" 2>/dev/null)
case "$TOOL" in
  tapps_*)
    SENTINEL="${TMPDIR:-/tmp}/.tapps-session-started-$$"
    if [ "$TOOL" = "tapps_session_start" ]; then
      touch "$SENTINEL"
    elif [ ! -f "$SENTINEL" ]; then
      echo "REMINDER: Call tapps_session_start() first for best results."
    fi
    ;;
esac
echo "[TappsMCP] MCP tool invoked: $TOOL" >&2
exit 0
