#!/bin/bash
# .ralph/hooks/on-subagent-done.sh
# SubagentStop hook. Logs sub-agent completion for monitoring.
#
# stdin: JSON with sub-agent result data
# Exit 0 = allow (normal)

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)

# PERF: Extract all fields in single jq call (was: 4 separate jq calls)
# Use IFS=$'\t' so that fields containing spaces (e.g. agent names) are not split
IFS=$'\t' read -r agent_name agent_id duration_ms error < <(
  echo "$INPUT" | jq -r '[
    (.agent_name // .subagent_type // "unknown"),
    (.agent_id // "unknown"),
    (.duration_ms // 0 | tostring),
    (.error // "")
  ] | @tsv' 2>/dev/null || printf 'unknown\tunknown\t0\t'
)

# Calculate duration in seconds
duration_s=0
if [[ "$duration_ms" -gt 0 ]] 2>/dev/null; then
  duration_s=$((duration_ms / 1000))
fi

# Log completion
if [[ -n "$error" ]]; then
  echo "[$(date '+%H:%M:%S')] SUBAGENT FAILED: $agent_name (id=$agent_id) after ${duration_s}s — $error" \
    >> "$RALPH_DIR/live.log"
else
  echo "[$(date '+%H:%M:%S')] SUBAGENT DONE: $agent_name (id=$agent_id) in ${duration_s}s" \
    >> "$RALPH_DIR/live.log"
fi

# =============================================================================
# TAP-1684: parallel epic-boundary fan-out — defer per-agent CB updates
# while >1 sub-agent is still in flight.
#
# Without this guard, every parallel SubagentStop event races to update the
# circuit breaker on its own verdict. A fast FAIL from tapps-validator could
# overwrite a slow PASS from ralph-tester, or vice versa, depending on
# completion order — even though the aggregate rule is order-independent
# (`any FAIL ⇒ FAIL`, see exec_aggregate_qa_results in lib/exec_helpers.sh).
#
# Sidecar shape: `.ralph/.subagent_in_flight` carries one agent_id per line,
# written by the main agent's fan-out dispatch (one line per Task call). As
# each SubagentStop arrives, this hook removes the corresponding line; while
# the file still has lines, we set `.subagent_defer_cb` so downstream CB
# update sites in ralph_loop.sh / on-stop.sh know to wait. When the last
# line drains we clear both files and CB updates resume normally.
#
# A missing/empty sidecar means serial mode — exactly the pre-TAP-1684
# behavior — so mid-epic explorer calls and one-off ralph-tester runs are
# unaffected.
_inflight_file="$RALPH_DIR/.subagent_in_flight"
if [[ -s "$_inflight_file" && -n "$agent_id" && "$agent_id" != "unknown" ]]; then
  _tmp="$_inflight_file.tmp.$$.${RANDOM}"
  # grep -v emits 0 lines when its filter removes everything; capture that
  # via `|| true` so set -e does not kill us on the last completion.
  grep -vxF -- "$agent_id" "$_inflight_file" > "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$_inflight_file" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  _remaining=$(wc -l < "$_inflight_file" 2>/dev/null | tr -cd '0-9')
  _remaining=${_remaining:-0}
  if [[ "$_remaining" -gt 0 ]]; then
    : > "$RALPH_DIR/.subagent_defer_cb" 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] SUBAGENT IN-FLIGHT GUARD: $_remaining more agent(s) outstanding — deferring CB update" \
      >> "$RALPH_DIR/live.log"
  else
    rm -f "$_inflight_file" "$RALPH_DIR/.subagent_defer_cb" 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] SUBAGENT FAN-OUT COMPLETE: all agents returned — CB update re-enabled" \
      >> "$RALPH_DIR/live.log"
  fi
fi

exit 0
