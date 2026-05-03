#!/usr/bin/env bash
# tapps-mcp-hook-version: 3.8.0
# TappsMCP PostToolUse hook — Linear cache-gate sentinel writer (TAP-1224)
# Writes a per-(team, project, state, label, limit) sentinel on BOTH
# cached=true and cached=false responses from tapps_linear_snapshot_get.
# Paired with tapps-pre-linear-list.sh which reads the sentinel to gate
# downstream list_issues calls.
INPUT=$(cat)
PYBIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
if [ -z "$PYBIN" ]; then
  exit 0
fi
PARSED=$(echo "$INPUT" | "$PYBIN" -c "
import sys, json, hashlib
try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    print('')
    sys.exit(0)
name = d.get('tool_name') or d.get('toolName') or ''
inp = d.get('tool_input') or d.get('toolInput') or {}
team = (inp.get('team') or '').strip()
project = (inp.get('project') or '').strip()
state = (inp.get('state') or '').strip()
label = (inp.get('label') or '').strip()
try:
    limit = int(inp.get('limit') or 50)
except Exception:
    limit = 50
# Mirror tapps_mcp.server_linear_tools._filter_hash: drop None/'' values.
filt = {k: v for k, v in sorted({
    'state': state, 'label': label, 'limit': limit,
}.items()) if v not in (None, '')}
payload = json.dumps(filt, sort_keys=True, default=str).encode('utf-8')
fhash = hashlib.sha256(payload).hexdigest()[:16]
parts = [
    (team.replace('/', '_') or '_'),
    (project.replace('/', '_') or '_'),
    ((state or 'any').replace('/', '_')),
    fhash,
]
key = '__'.join(parts)
# Skip the gate when the call is a single-issue get (id-only). The agent
# should be using mcp__plugin_linear_linear__get_issue, but if list_issues
# was called with a query that targets a single id, we have no team/project
# context to key on — let it through with empty key.
if not team or not project:
    key = ''
print(name)
print(key)
" 2>/dev/null)
TOOL=$(echo "$PARSED" | sed -n '1p')
KEY=$(echo "$PARSED" | sed -n '2p')
case "$TOOL" in
  mcp__tapps-mcp__tapps_linear_snapshot_get|tapps_linear_snapshot_get) ;;
  *) exit 0 ;;
esac
if [ -z "$KEY" ]; then
  exit 0
fi
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
mkdir -p "$ROOT/.tapps-mcp" 2>/dev/null
date +%s > "$ROOT/.tapps-mcp/.linear-snapshot-sentinel-${KEY}" 2>/dev/null
exit 0
