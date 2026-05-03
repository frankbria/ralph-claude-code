#!/usr/bin/env bash
# tapps-mcp-hook-version: 3.8.0
# TappsMCP PreToolUse hook — Linear cache-first read gate (TAP-1224)
# Gates raw mcp__plugin_linear_linear__list_issues calls behind a recent
# tapps_linear_snapshot_get sentinel for the same (team, project, state,
# label, limit) slice (within 300s). Mode is baked in at install time:
# "warn" logs to .cache-gate-violations.jsonl and allows; "block" exits 2.
# Bypass with TAPPS_LINEAR_SKIP_CACHE_GATE=1 (logged to .bypass-log.jsonl).
MODE="warn"
INPUT=$(cat)
PYBIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
if [ -z "$PYBIN" ]; then
  # No python available — cannot compute key; fail-open for portability.
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
  mcp__plugin_linear_linear__list_issues|list_issues) ;;
  *) exit 0 ;;
esac
if [ -z "$KEY" ]; then
  exit 0
fi
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ "${TAPPS_LINEAR_SKIP_CACHE_GATE:-0}" = "1" ]; then
  mkdir -p "$ROOT/.tapps-mcp" 2>/dev/null
  echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"bypass\":\"TAPPS_LINEAR_SKIP_CACHE_GATE\",\"key\":\"${KEY}\"}" \
    >> "$ROOT/.tapps-mcp/.bypass-log.jsonl" 2>/dev/null
  exit 0
fi
SENTINEL="$ROOT/.tapps-mcp/.linear-snapshot-sentinel-${KEY}"
if [ -f "$SENTINEL" ]; then
  NOW=$(date +%s)
  SENT=$(cat "$SENTINEL" 2>/dev/null)
  if echo "$SENT" | grep -Eq '^[0-9]+$'; then
    AGE=$((NOW - SENT))
    if [ "$AGE" -le 300 ]; then
      exit 0
    fi
  fi
fi
# No matching sentinel (or stale). Log the violation in either mode.
mkdir -p "$ROOT/.tapps-mcp" 2>/dev/null
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"key\":\"${KEY}\",\"mode\":\"${MODE}\"}" \
  >> "$ROOT/.tapps-mcp/.cache-gate-violations.jsonl" 2>/dev/null
if [ "$MODE" = "warn" ]; then
  cat >&2 <<MSG
TappsMCP: Linear cache-first read rule (TAP-1224, warn mode) — no recent tapps_linear_snapshot_get for this (team, project, state) slice.
Route reads through the \`linear-read\` skill (TAP-1260):
  1. tapps_linear_snapshot_get(team, project, state)
  2. On cached=false: list_issues with the same filters, then tapps_linear_snapshot_put.
This call is allowed (warn mode) but logged to .tapps-mcp/.cache-gate-violations.jsonl.
See .claude/rules/linear-standards.md.
MSG
  exit 0
fi
cat >&2 <<MSG
TappsMCP: Blocked mcp__plugin_linear_linear__list_issues — no recent tapps_linear_snapshot_get for this (team, project, state) slice.
Route reads through the \`linear-read\` skill (TAP-1260):
  1. tapps_linear_snapshot_get(team, project, state)
  2. On cached=true: filter in memory (no Linear call).
  3. On cached=false: list_issues with the same filters, then tapps_linear_snapshot_put.
For a single-issue lookup, use mcp__plugin_linear_linear__get_issue(id=...) instead.
Or set TAPPS_LINEAR_SKIP_CACHE_GATE=1 for emergency bypass (logged).
See .claude/rules/linear-standards.md.
MSG
exit 2
