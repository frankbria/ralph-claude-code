#!/bin/bash
# .ralph/hooks/on-stop.sh
# Replaces: analyze_response() in lib/response_analyzer.sh
#
# Stop hook. Runs after every Claude response. Reads response from stdin (JSON).
# Updates .ralph state files deterministically.
# Exit 0 = allow stop.
#
# Performance: single-pass parsing with minimal subprocess spawns (v1.8.5).

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Guard: only run in Ralph-managed projects
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# TAP-1530: skip when invoked by the coordinator sub-process. The coordinator
# is spawned as a separate `claude --agent ralph-coordinator` CLI process by
# ralph_loop.sh's _coordinator_invoke_claude(), which means its Stop hook
# fires this same on-stop.sh against a coordinator response that intentionally
# does not emit a RALPH_STATUS block. Without this guard, every brief and
# debrief invocation increments .no_status_block_count, overwrites status.json
# with stale data, and trips the no_status_block_3x halt detector within
# 1–2 main loops (observed in tapps-brain).
if [[ "${RALPH_COORDINATOR_INVOCATION:-}" == "1" ]]; then
  exit 0
fi

# Read response from stdin
INPUT=$(cat)

# Extract response text — try multiple JSON paths for compatibility
response_text=""
for path in '.result' '.content' '.result.text' '.message.content' '.response[0].text' '.response'; do
  response_text=$(echo "$INPUT" | jq -r "$path // empty" 2>/dev/null || true)
  [[ -n "$response_text" ]] && break
done

# Fallback: if no JSON path matched, use raw input as text
# This handles agent mode and unexpected payload formats (WSL-WINDOWS-VERSION-DIVERGENCE bug)
if [[ -z "$response_text" ]]; then
  response_text="$INPUT"
fi

# STREAM-3: If response_text contains JSON-escaped RALPH_STATUS block (literal \n instead of
# newlines), unescape it so grep-based field extraction works correctly.
# This happens when the response arrives from JSONL stream extraction.
if echo "$response_text" | grep -q '\\n.*RALPH_STATUS' 2>/dev/null; then
  # Only convert literal \n to newlines (not all backslash sequences like \t, \x, etc.)
  response_text=$(echo "$response_text" | sed 's/\\n/\n/g')
fi

# PERF: Extract ALL fields in a single grep+sed pass instead of 6 separate extract_field() calls
# Each extract_field() call spawned grep + sed + tr = 3 subprocesses × 6 fields = 18 subprocesses.
# This block does it in ~3 subprocesses total.
_status_block=$(echo "$response_text" | sed -n '/---RALPH_STATUS---/,/---END_RALPH_STATUS---/p' || true)

# TRANSCRIPT-FALLBACK (Claude Code 2.1.x): The stop hook stdin no longer carries
# the response text — 2.1.x removed the "type":"result" line from both the hook
# payload and the transcript. If _status_block is still empty, read the last
# assistant message's text from transcript_path and try again. This also fixes
# response_text so question-pattern and permission-denial detection work correctly.
if [[ -z "$_status_block" ]]; then
  _tf_for_status=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
  if [[ -n "$_tf_for_status" && -f "$_tf_for_status" ]]; then
    _last_assistant_text=$(jq -rs '
      [.[] | select(.type == "assistant")] | last |
      .message.content // [] |
      [.[] | select(.type == "text") | .text] |
      join("\n")
    ' "$_tf_for_status" 2>/dev/null || echo "")
    if [[ -n "$_last_assistant_text" ]]; then
      response_text="$_last_assistant_text"
      _status_block=$(echo "$response_text" | sed -n '/---RALPH_STATUS---/,/---END_RALPH_STATUS---/p' || true)
    fi
  fi
fi

# PARSER-HARDENING (2026-04-30): two real bugs caused exit-gate bypass when
# Claude correctly reported STATUS: BLOCKED + EXIT_SIGNAL: true on a fully-
# blocked Linear backlog (NLTlabsPE incident, 10 wasted loops + CB trip):
#   1. Field-name case drift. Projects whose PROMPT.md uses lowercase
#      `linear_open_count: 0` had the value silently dropped because the
#      original grep was case-sensitive. The awk pre-pass below uppercases
#      the field-identifier portion of every "<ident>:..." line so the
#      downstream greps work regardless of project-side case.
#   2. Unanchored greps + prose colon. A RECOMMENDATION line containing
#      "STATUS:BLOCKED" in free-text prose poisoned `grep "STATUS:"` —
#      `tail -1` picked the recommendation line, sed stripped up to the
#      *last* "STATUS:" and yielded `BLOCKED)` (the closing paren of the
#      parenthetical), which broke the EXIT-CLEAN equality check at
#      line 607. Anchoring every field grep to ^[[:space:]] makes prose
#      mid-line uncatchable.
if [[ -n "$_status_block" ]]; then
  _status_block=$(echo "$_status_block" | awk '
    {
      pos = index($0, ":")
      if (pos > 0) {
        field = substr($0, 1, pos - 1)
        rest  = substr($0, pos)
        match(field, /^[[:space:]]*/); ws = substr(field, RSTART, RLENGTH)
        sub(/^[[:space:]]*/, "", field)
        if (field ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
          print ws toupper(field) rest
          next
        }
      }
      print
    }
  ')
  exit_signal=$(echo "$_status_block" | grep -E "^[[:space:]]*EXIT_SIGNAL:" | tail -1 | sed -E 's/^[[:space:]]*EXIT_SIGNAL:[[:space:]]*//' | tr -d '[:space:]' || echo "false")
  status=$(echo "$_status_block" | grep -E "^[[:space:]]*STATUS:" | tail -1 | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//' | tr -d '[:space:]' || echo "UNKNOWN")
  tasks_done=$(echo "$_status_block" | grep -E "^[[:space:]]*TASKS_COMPLETED_THIS_LOOP:" | tail -1 | sed -E 's/^[[:space:]]*TASKS_COMPLETED_THIS_LOOP:[[:space:]]*//' | tr -d '[:space:]' || echo "0")
  files_modified_reported=$(echo "$_status_block" | grep -E "^[[:space:]]*FILES_MODIFIED:" | tail -1 | sed -E 's/^[[:space:]]*FILES_MODIFIED:[[:space:]]*//' | tr -d '[:space:]' || echo "0")
  work_type=$(echo "$_status_block" | grep -E "^[[:space:]]*WORK_TYPE:" | tail -1 | sed -E 's/^[[:space:]]*WORK_TYPE:[[:space:]]*//' | tr -d '[:space:]' || echo "UNKNOWN")
  recommendation=$(echo "$_status_block" | grep -E "^[[:space:]]*RECOMMENDATION:" | tail -1 | sed -E 's/^[[:space:]]*RECOMMENDATION:[[:space:]]*//' || echo "")
  # LINEAR-DASH: optional Linear-driven fields. Absent in file-mode projects.
  linear_issue=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_ISSUE:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_ISSUE:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  linear_url=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_URL:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_URL:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  linear_epic=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_EPIC:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_EPIC:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  linear_epic_done=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_EPIC_DONE:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_EPIC_DONE:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  linear_epic_total=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_EPIC_TOTAL:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_EPIC_TOTAL:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  # TAP-741: project-wide counts Claude reports via Linear MCP. These feed the
  # push-mode read path in lib/linear_backend.sh so the harness can run the
  # exit-gate and preflight checks without LINEAR_API_KEY.
  linear_open_count=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_OPEN_COUNT:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_OPEN_COUNT:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  linear_done_count=$(echo "$_status_block" | grep -E "^[[:space:]]*LINEAR_DONE_COUNT:" | tail -1 | sed -E 's/^[[:space:]]*LINEAR_DONE_COUNT:[[:space:]]*//' | tr -d '[:space:]' || echo "")
  tests_status=$(echo "$_status_block" | grep -E "^[[:space:]]*TESTS_STATUS:" | tail -1 | sed -E 's/^[[:space:]]*TESTS_STATUS:[[:space:]]*//' | tr -d '[:space:]' || echo "")
else
  # No structured status block found — extract from full text
  exit_signal="false"
  status="UNKNOWN"
  tasks_done="0"
  files_modified_reported="0"
  work_type="UNKNOWN"
  recommendation=""
  linear_issue=""
  linear_url=""
  linear_epic=""
  linear_epic_done=""
  linear_epic_total=""
  linear_open_count=""
  linear_done_count=""
  tests_status=""
fi

# LINEAR-DASH: sanitize Linear fields; empty strings become JSON null
[[ "$linear_issue" =~ ^[Nn]one$ ]] && linear_issue=""
[[ "$linear_epic" =~ ^[Nn]one$ ]] && linear_epic=""
[[ "$linear_epic_done" =~ ^[0-9]+$ ]] || linear_epic_done=""
[[ "$linear_epic_total" =~ ^[0-9]+$ ]] || linear_epic_total=""
# TAP-741: enforce non-negative integer shape; anything else → null (abstain).
[[ "$linear_open_count" =~ ^[0-9]+$ ]] || linear_open_count=""
[[ "$linear_done_count" =~ ^[0-9]+$ ]] || linear_done_count=""

# Normalize TESTS_STATUS to upper-case for comparison
tests_status="${tests_status^^}"

# Defaults for empty values
exit_signal="${exit_signal:-false}"
status="${status:-UNKNOWN}"
tasks_done="${tasks_done:-0}"
files_modified_reported="${files_modified_reported:-0}"
work_type="${work_type:-UNKNOWN}"

# Validate numeric fields to prevent arithmetic errors from non-numeric Claude output
[[ "$tasks_done" =~ ^[0-9]+$ ]] || tasks_done=0
[[ "$files_modified_reported" =~ ^[0-9]+$ ]] || files_modified_reported=0

# STREAM-3: Fallback inference — if WORK_TYPE is UNKNOWN but files were modified, infer IMPLEMENTATION
if [[ "$work_type" == "UNKNOWN" && "$files_modified_reported" -gt 0 ]]; then
  work_type="IMPLEMENTATION"
fi

# USYNC-1: Detect question patterns in response text (upstream #190)
# When Claude asks questions in headless mode, it's not making progress but it's
# also not stuck — corrective guidance (USYNC-2) will redirect next loop.
QUESTION_PATTERNS=(
    "should I"
    "would you"
    "do you want"
    "which approach"
    "which option"
    "how should"
    "what should"
    "shall I"
    "do you prefer"
    "can you clarify"
    "could you"
    "what do you think"
    "please confirm"
    "need clarification"
    "awaiting.*input"
    "waiting.*response"
    "your preference"
)

asking_questions="false"
question_count=0
if [[ -n "$response_text" ]]; then
  for pattern in "${QUESTION_PATTERNS[@]}"; do
    count=$(echo "$response_text" | grep -ciE "$pattern" 2>/dev/null || echo "0")
    count=$(echo "$count" | tr -cd '0-9')
    count=${count:-0}
    question_count=$((question_count + count))
  done
  [[ "$question_count" -gt 0 ]] && asking_questions="true"
fi

# USYNC-4: Detect permission denials in response (upstream #101)
# Permission denials are deterministic — they won't self-resolve on retry.
has_permission_denials="false"
permission_denial_count=0
if [[ -n "$response_text" ]]; then
  permission_denial_count=$(echo "$response_text" | grep -ciE '(permission denied|tool not allowed|not in allowed|disallowed tool|not permitted)' 2>/dev/null || echo "0")
  permission_denial_count=$(echo "$permission_denial_count" | tr -cd '0-9')
  permission_denial_count=${permission_denial_count:-0}
  [[ "$permission_denial_count" -gt 0 ]] && has_permission_denials="true"
fi

# Count actual files modified (from PostToolUse tracking)
actual_files_modified=0
if [[ -f "$RALPH_DIR/.files_modified_this_loop" ]]; then
  actual_files_modified=$(sort -u "$RALPH_DIR/.files_modified_this_loop" | wc -l | tr -cd '0-9')
  actual_files_modified=${actual_files_modified:-0}
fi

# Use the higher of reported vs actual (defense-in-depth)
files_modified=$((files_modified_reported > actual_files_modified ? files_modified_reported : actual_files_modified))

# PLANOPT: Mark import graph stale if new source files were created this loop
# This enables the optimizer to rebuild the graph on next session start
if [[ -f "$RALPH_DIR/.files_modified_this_loop" && -f "$RALPH_DIR/.import_graph.json" ]]; then
  while IFS= read -r _modified_file; do
    [[ -z "$_modified_file" ]] && continue
    # Only check source files (not config, docs, etc.)
    if echo "$_modified_file" | grep -qE '\.(py|ts|tsx|js|jsx|sh)$'; then
      # If this file didn't exist at HEAD, it's newly created → graph is stale
      if ! git show HEAD:"$_modified_file" &>/dev/null 2>&1; then
        touch "$RALPH_DIR/.import_graph.json.stale" 2>/dev/null || true
        break  # One new file is enough to trigger rebuild
      fi
    fi
  done < "$RALPH_DIR/.files_modified_this_loop"
fi

# SESSION-SCOPE: Read the run ID written by ralph_loop.sh at startup. If
# status.json.ralph_run_id differs (stale file from a prior run that crashed
# before the startup reset completed), zero out session accumulators so this
# loop starts a clean session rather than inheriting stale totals.
_current_run_id=""
if [[ -f "$RALPH_DIR/.ralph_run_id" ]]; then
  read -r _current_run_id < "$RALPH_DIR/.ralph_run_id" 2>/dev/null || _current_run_id=""
fi
_status_run_id=""
if [[ -f "$RALPH_DIR/status.json" ]]; then
  _status_run_id=$(jq -r '.ralph_run_id // ""' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
fi
_new_session="false"
if [[ -n "$_current_run_id" && "$_current_run_id" != "$_status_run_id" ]]; then
  _new_session="true"
fi

# PERF: Read loop count and write status.json in single operation (was: jq read + date + jq write = 3 subprocesses)
loop_count=0
prev_session_cost=0
prev_session_input=0
prev_session_output=0
if [[ -f "$RALPH_DIR/status.json" && "$_new_session" == "false" ]]; then
  loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
  prev_session_cost=$(jq -r '.session_cost_usd // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
  prev_session_input=$(jq -r '.session_input_tokens // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
  prev_session_output=$(jq -r '.session_output_tokens // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
elif [[ -f "$RALPH_DIR/status.json" ]]; then
  # New session — inherit loop_count only; session accumulators start at 0
  loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
fi
# Validate loop_count is numeric before arithmetic
[[ "$loop_count" =~ ^[0-9]+$ ]] || loop_count=0
loop_count=$((loop_count + 1))
[[ "$prev_session_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] || prev_session_cost=0
[[ "$prev_session_input" =~ ^[0-9]+$ ]] || prev_session_input=0
[[ "$prev_session_output" =~ ^[0-9]+$ ]] || prev_session_output=0

# TOKEN/COST EXTRACTION (rewritten 2026-04 for Claude Code 2.1.x).
# The Stop-hook stdin doesn't carry .usage or .total_cost_usd, and 2.1.x
# transcripts omit the "type":"result" line entirely. Primary source is now a
# single jq pass summing .message.usage across every assistant message in the
# transcript at $_transcript. Cost is computed via lib/pricing.sh. The
# stream-json capture (when present) is still a preferred source for the
# authoritative total_cost_usd, but only when the log is stable (age >=2s) —
# picking the newest file unconditionally races with the next loop's tee.
_transcript=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")

loop_input_tokens=0
loop_output_tokens=0
loop_cache_read=0
loop_cache_create=0
loop_cache_create_5m=0
loop_cache_create_1h=0
loop_model=""
loop_cost_usd=0

# Future-proofing: if some later Claude Code version adds usage/cost to the hook
# payload, use it — it's authoritative and avoids both the transcript sum and
# the stream-log fallback.
_ti=$(echo "$INPUT" | jq -r '.usage.input_tokens // empty' 2>/dev/null || echo "")
_to=$(echo "$INPUT" | jq -r '.usage.output_tokens // empty' 2>/dev/null || echo "")
_tc=$(echo "$INPUT" | jq -r '.total_cost_usd // empty' 2>/dev/null || echo "")
[[ "$_ti" =~ ^[0-9]+$ ]] && loop_input_tokens="$_ti"
[[ "$_to" =~ ^[0-9]+$ ]] && loop_output_tokens="$_to"
[[ "$_tc" =~ ^[0-9]+(\.[0-9]+)?$ ]] && loop_cost_usd="$_tc"

# Primary path: transcript sum. Single jq over the JSONL derives the last model
# plus input/output/cache-read/cache-create-5m/cache-create-1h token totals.
if [[ -n "$_transcript" && -f "$_transcript" ]]; then
  _usage_json=$(jq -cs '
    [ .[] | select(.type == "assistant") ] as $a
    | {
        model: (($a[-1].message.model // $a[-1].model // "") | tostring),
        input:           ([$a[] | .message.usage.input_tokens // 0] | add // 0),
        output:          ([$a[] | .message.usage.output_tokens // 0] | add // 0),
        cache_read:      ([$a[] | .message.usage.cache_read_input_tokens // 0] | add // 0),
        cache_create_5m: ([$a[] | .message.usage.cache_creation.ephemeral_5m_input_tokens // 0] | add // 0),
        cache_create_1h: ([$a[] | .message.usage.cache_creation.ephemeral_1h_input_tokens // 0] | add // 0)
      }
  ' "$_transcript" 2>/dev/null || echo '{}')
  if [[ -n "$_usage_json" && "$_usage_json" != "null" && "$_usage_json" != "{}" ]]; then
    _m=$(echo "$_usage_json" | jq -r '.model // ""' 2>/dev/null || echo "")
    [[ -n "$_m" && "$_m" != "null" ]] && loop_model="$_m"
    _ui=$(echo "$_usage_json" | jq -r '.input // 0' 2>/dev/null || echo "0")
    _uo=$(echo "$_usage_json" | jq -r '.output // 0' 2>/dev/null || echo "0")
    _ur=$(echo "$_usage_json" | jq -r '.cache_read // 0' 2>/dev/null || echo "0")
    _u5=$(echo "$_usage_json" | jq -r '.cache_create_5m // 0' 2>/dev/null || echo "0")
    _u1=$(echo "$_usage_json" | jq -r '.cache_create_1h // 0' 2>/dev/null || echo "0")
    [[ "$_ui" =~ ^[0-9]+$ ]] && loop_input_tokens="$_ui"
    [[ "$_uo" =~ ^[0-9]+$ ]] && loop_output_tokens="$_uo"
    [[ "$_ur" =~ ^[0-9]+$ ]] && loop_cache_read="$_ur"
    [[ "$_u5" =~ ^[0-9]+$ ]] && loop_cache_create_5m="$_u5"
    [[ "$_u1" =~ ^[0-9]+$ ]] && loop_cache_create_1h="$_u1"
    loop_cache_create=$((loop_cache_create_5m + loop_cache_create_1h))
  fi
fi

# Stream-log fallback: scan the stream-json capture for the authoritative
# `"type":"result"` line ralph_loop.sh tee'd. Pick the newest (ls -t) log that
# ALREADY CONTAINS a result line — this sidesteps the ls-t race where the next
# loop's tee has opened a fresh log before the stop hook for the previous turn
# fires. The next loop's log has no result line yet, so it's skipped; the
# previous loop's log does, so it's picked. When ralph_loop.sh isn't capturing
# (agent mode / SDK), the glob is empty and this block is a no-op.
if [[ "$loop_cost_usd" == "0" ]]; then
  _live_stream=""
  while IFS= read -r _cand; do
    [[ -z "$_cand" || ! -f "$_cand" ]] && continue
    if grep -qE '"type"[[:space:]]*:[[:space:]]*"result"' "$_cand" 2>/dev/null; then
      _live_stream="$_cand"
      break
    fi
  done < <(ls -t "$RALPH_DIR"/logs/claude_output_*.log 2>/dev/null | grep -v '_stream\.log$')

  if [[ -n "$_live_stream" && -f "$_live_stream" ]]; then
    _result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$_live_stream" 2>/dev/null | tail -1 || true)
    if [[ -n "$_result" ]]; then
      _ti3=$(echo "$_result" | jq -r '.usage.input_tokens // empty' 2>/dev/null || echo "")
      _to3=$(echo "$_result" | jq -r '.usage.output_tokens // empty' 2>/dev/null || echo "")
      _tc3=$(echo "$_result" | jq -r '.total_cost_usd // empty' 2>/dev/null || echo "")
      _lm3=$(echo "$_result" | jq -r '(.modelUsage | keys[0]) // empty' 2>/dev/null || echo "")
      [[ "$_ti3" =~ ^[0-9]+$ ]] && loop_input_tokens="$_ti3"
      [[ "$_to3" =~ ^[0-9]+$ ]] && loop_output_tokens="$_to3"
      [[ "$_tc3" =~ ^[0-9]+(\.[0-9]+)?$ ]] && loop_cost_usd="$_tc3"
      [[ -n "$_lm3" && ( -z "$loop_model" || "$loop_model" == "null" ) ]] && loop_model="$_lm3"
    fi
  fi
fi

# Cost calc via pricing table — only fires if the two paths above left us with
# zero cost but a known model. Estimate-quality; the stream-log total_cost_usd
# is always preferred when available.
if [[ "$loop_cost_usd" == "0" ]] && [[ -n "$loop_model" && "$loop_model" != "null" ]]; then
  _pricing_lib=""
  _hook_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")" 2>/dev/null || echo "")
  for _p in "$HOME/.ralph/lib/pricing.sh" \
            "${RALPH_INSTALL_DIR:-/nonexistent}/lib/pricing.sh" \
            "$_hook_dir/../../lib/pricing.sh" \
            "$_hook_dir/../lib/pricing.sh"; do
    if [[ -f "$_p" ]]; then _pricing_lib="$_p"; break; fi
  done
  if [[ -n "$_pricing_lib" ]]; then
    # shellcheck source=/dev/null
    source "$_pricing_lib"
    loop_cost_usd=$(pricing_compute_cost "$loop_model" \
      "$loop_input_tokens" "$loop_output_tokens" \
      "$loop_cache_read" "$loop_cache_create_5m" "$loop_cache_create_1h" \
      2>/dev/null || echo "0")
  fi
fi

# Sanitize the final cost — must be a decimal string jq can ingest as a number.
[[ "$loop_cost_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || loop_cost_usd=0

# PHASE1: sub-agent invocations this loop — count Task tool calls by subagent_type
# Single jq pass over the transcript (treated as JSONL via -s slurp) so counts sum correctly.
loop_subagents_json="{}"
if [[ -n "$_transcript" && -f "$_transcript" ]]; then
  loop_subagents_json=$(jq -cs '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "Task")
      | .input.subagent_type // "unknown" ]
    | group_by(.) | map({(.[0]): length}) | add // {}
  ' "$_transcript" 2>/dev/null || echo "{}")
  [[ -z "$loop_subagents_json" || "$loop_subagents_json" == "null" ]] && loop_subagents_json="{}"
fi

# Merge session sub-agent counts (previous + this loop; zero base on new session)
prev_subagents_json="{}"
if [[ "$_new_session" == "false" && -f "$RALPH_DIR/status.json" ]]; then
  prev_subagents_json=$(jq -r '.session_subagents // {}' "$RALPH_DIR/status.json" 2>/dev/null || echo "{}")
fi
[[ -z "$prev_subagents_json" || "$prev_subagents_json" == "null" ]] && prev_subagents_json="{}"
session_subagents_json=$(jq -cn --argjson a "$prev_subagents_json" --argjson b "$loop_subagents_json" \
  '$a as $a | $b as $b | ($a | to_entries) + ($b | to_entries) | group_by(.key) | map({(.[0].key): (map(.value) | add)}) | add // {}' 2>/dev/null || echo "{}")
[[ -z "$session_subagents_json" || "$session_subagents_json" == "null" ]] && session_subagents_json="{}"

# TAP-588 (epic TAP-583): Count mcp__tapps-mcp__* and mcp__docs-mcp__* tool
# calls this loop. The transcript already lists every tool_use; one jq pass
# extracts MCP names, sums per-server, and emits a by-tool histogram. Without
# this counter we have no way to tell whether TAP-585's prompt guidance is
# actually moving Claude's behavior — see TAP-583 success criterion.
_empty_mcp_calls='{"tapps_mcp":0,"docs_mcp":0,"by_tool":{}}'
loop_mcp_calls_json="$_empty_mcp_calls"
if [[ -n "$_transcript" && -f "$_transcript" ]]; then
  loop_mcp_calls_json=$(jq -cs '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and ((.name // "") | startswith("mcp__")))
      | .name ]
    | {
        tapps_mcp: (map(select(startswith("mcp__tapps-mcp__"))) | length),
        docs_mcp:  (map(select(startswith("mcp__docs-mcp__"))) | length),
        by_tool:   (group_by(.) | map({(.[0]): length}) | add // {})
      }
  ' "$_transcript" 2>/dev/null || echo "$_empty_mcp_calls")
  [[ -z "$loop_mcp_calls_json" || "$loop_mcp_calls_json" == "null" ]] && loop_mcp_calls_json="$_empty_mcp_calls"
fi

# TAP-590 (epic TAP-589 LINOPT): Capture this loop's actual file set into
# .ralph/.last_completed_files for cache-locality scoring in lib/linear_optimizer.sh.
# Walks the transcript JSONL for Edit/Write/MultiEdit/NotebookEdit tool_use records,
# extracts file_path / notebook_path, normalizes to repo-relative, dedupes (jq's
# `unique` sorts as a side effect), caps at 100, atomic-writes. On no transcript
# or no edit-class tools, writes an empty file rather than leaving a stale list.
_lcf_dest="$RALPH_DIR/.last_completed_files"
_lcf_tmp="${_lcf_dest}.tmp.$$"
if [[ -n "$_transcript" && -f "$_transcript" ]]; then
  jq -rs '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use"
            and (.name == "Edit" or .name == "Write"
              or .name == "MultiEdit" or .name == "NotebookEdit"))
      | (.input.file_path // .input.notebook_path // empty) ]
    | map(select(. != null and . != ""))
    | unique
    | .[0:100]
    | .[]
  ' "$_transcript" 2>/dev/null > "$_lcf_tmp" || : > "$_lcf_tmp"

  # Strip CLAUDE_PROJECT_DIR prefix to keep paths repo-relative.
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -s "$_lcf_tmp" ]]; then
    _proj_dir="${CLAUDE_PROJECT_DIR%/}"
    _proj_dir_escaped="${_proj_dir//\\/\\\\}"
    _proj_dir_escaped="${_proj_dir_escaped//|/\\|}"
    sed -i "s|^${_proj_dir_escaped}/||" "$_lcf_tmp" 2>/dev/null || true
    # Re-sort+dedupe in case normalization produced collisions.
    sort -u -o "$_lcf_tmp" "$_lcf_tmp" 2>/dev/null || true
  fi

  if mv -f "$_lcf_tmp" "$_lcf_dest" 2>/dev/null; then
    rm -f "${_lcf_dest}.tmp."* 2>/dev/null || true
  else
    rm -f "$_lcf_tmp" 2>/dev/null || true
  fi
else
  # No transcript → empty file (don't leave a stale prior-loop list).
  : > "$_lcf_dest" 2>/dev/null || true
fi

# Merge session MCP-call totals (previous + this loop; zero base on new session).
prev_mcp_calls_json="$_empty_mcp_calls"
if [[ "$_new_session" == "false" && -f "$RALPH_DIR/status.json" ]]; then
  prev_mcp_calls_json=$(jq -r '.session_mcp_calls // {"tapps_mcp":0,"docs_mcp":0,"by_tool":{}}' "$RALPH_DIR/status.json" 2>/dev/null || echo "$_empty_mcp_calls")
fi
[[ -z "$prev_mcp_calls_json" || "$prev_mcp_calls_json" == "null" ]] && prev_mcp_calls_json="$_empty_mcp_calls"
session_mcp_calls_json=$(jq -cn --argjson a "$prev_mcp_calls_json" --argjson b "$loop_mcp_calls_json" '
  {
    tapps_mcp: (($a.tapps_mcp // 0) + ($b.tapps_mcp // 0)),
    docs_mcp:  (($a.docs_mcp  // 0) + ($b.docs_mcp  // 0)),
    by_tool: (
      (($a.by_tool // {}) | to_entries) + (($b.by_tool // {}) | to_entries)
      | group_by(.key)
      | map({(.[0].key): (map(.value) | add)})
      | add // {}
    )
  }' 2>/dev/null || echo "$_empty_mcp_calls")
[[ -z "$session_mcp_calls_json" || "$session_mcp_calls_json" == "null" ]] && session_mcp_calls_json="$_empty_mcp_calls"

session_cost_usd=$(awk -v p="$prev_session_cost" -v l="$loop_cost_usd" 'BEGIN{printf "%.6f", p+l}')
session_input_tokens=$((prev_session_input + loop_input_tokens))
session_output_tokens=$((prev_session_output + loop_output_tokens))

# MERGE-1: also refresh calls_made_this_hour from .call_count, which ralph_loop.sh's
# update_status may have written as a stale pre-increment value at loop start.
fresh_calls_made=""
if [[ -f "$RALPH_DIR/.call_count" ]]; then
  read -r fresh_calls_made < "$RALPH_DIR/.call_count" 2>/dev/null || true
  [[ "$fresh_calls_made" =~ ^[0-9]+$ ]] || fresh_calls_made=""
fi

# Accumulate session cache stats (zero out on new session boundary)
prev_session_cache_read=0
prev_session_cache_create=0
if [[ "$_new_session" == "false" && -f "$RALPH_DIR/status.json" ]]; then
  prev_session_cache_read=$(jq -r '.session_cache_read_tokens // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
  prev_session_cache_create=$(jq -r '.session_cache_create_tokens // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
fi
[[ "$prev_session_cache_read" =~ ^[0-9]+$ ]] || prev_session_cache_read=0
[[ "$prev_session_cache_create" =~ ^[0-9]+$ ]] || prev_session_cache_create=0
session_cache_read=$((prev_session_cache_read + loop_cache_read))
session_cache_create=$((prev_session_cache_create + loop_cache_create))

# Sanitize all numeric/boolean fields for valid JSON output (MINGW/CRLF safety)
[[ "$question_count" =~ ^[0-9]+$ ]] || question_count=0
[[ "$permission_denial_count" =~ ^[0-9]+$ ]] || permission_denial_count=0
[[ "$files_modified" =~ ^[0-9]+$ ]] || files_modified=0
[[ "$asking_questions" == "true" ]] || asking_questions="false"
[[ "$has_permission_denials" == "true" ]] || has_permission_denials="false"

# Write status.json (atomic write via temp file).
# MERGE-1: Two writers (ralph_loop.sh update_status and this hook) emit different fields.
# Preserve the loop-writer fields (calls_made_this_hour, max_calls_per_hour, last_action,
# exit_reason, next_reset) so the monitor has a complete view regardless of which writer
# ran last.
local_tmp=$(mktemp "$RALPH_DIR/status.json.XXXXXX")
_now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build this-hook's object, then merge onto the prior status.json so unrelated fields survive.
jq -n \
  --arg ts "$_now_ts" \
  --argjson lc "$loop_count" \
  --arg st "$status" \
  --arg es "$exit_signal" \
  --argjson td "$tasks_done" \
  --argjson fm "$files_modified" \
  --arg wt "$work_type" \
  --arg rec "$recommendation" \
  --argjson aq "$asking_questions" \
  --argjson qc "$question_count" \
  --argjson hpd "$has_permission_denials" \
  --argjson pdc "$permission_denial_count" \
  --arg li "$linear_issue" \
  --arg lu "$linear_url" \
  --arg le "$linear_epic" \
  --arg led "${linear_epic_done}" \
  --arg let "${linear_epic_total}" \
  --arg loc "${linear_open_count}" \
  --arg ldc "${linear_done_count}" \
  --argjson lit "$loop_input_tokens" \
  --argjson lot "$loop_output_tokens" \
  --argjson lcu "$loop_cost_usd" \
  --argjson sit "$session_input_tokens" \
  --argjson sot "$session_output_tokens" \
  --argjson scu "$session_cost_usd" \
  --arg lm "$loop_model" \
  --argjson lcr "$loop_cache_read" \
  --argjson lcc "$loop_cache_create" \
  --argjson scr "$session_cache_read" \
  --argjson scc "$session_cache_create" \
  --argjson lsa "$loop_subagents_json" \
  --argjson ssa "$session_subagents_json" \
  --argjson lmc "$loop_mcp_calls_json" \
  --argjson smc "$session_mcp_calls_json" \
  --arg fcm "$fresh_calls_made" \
  --arg rid "$_current_run_id" \
  '{
    timestamp: $ts, loop_count: $lc, status: $st, exit_signal: $es,
    tasks_completed: $td, files_modified: $fm, work_type: $wt, recommendation: $rec,
    asking_questions: $aq, question_count: $qc,
    has_permission_denials: $hpd, permission_denial_count: $pdc,
    linear_issue: (if $li == "" then null else $li end),
    linear_url: (if $lu == "" then null else $lu end),
    linear_epic: (if $le == "" then null else $le end),
    linear_epic_done: (if $led == "" then null else ($led|tonumber) end),
    linear_epic_total: (if $let == "" then null else ($let|tonumber) end),
    linear_open_count: (if $loc == "" then null else ($loc|tonumber) end),
    linear_done_count: (if $ldc == "" then null else ($ldc|tonumber) end),
    linear_counts_at: (if ($loc == "" and $ldc == "") then null else $ts end),
    loop_input_tokens: $lit, loop_output_tokens: $lot, loop_cost_usd: $lcu,
    session_input_tokens: $sit, session_output_tokens: $sot, session_cost_usd: $scu,
    loop_model: (if $lm == "" then null else $lm end),
    loop_cache_read_tokens: $lcr, loop_cache_create_tokens: $lcc,
    session_cache_read_tokens: $scr, session_cache_create_tokens: $scc,
    loop_subagents: $lsa, session_subagents: $ssa,
    loop_mcp_calls: $lmc, session_mcp_calls: $smc,
    ralph_run_id: (if $rid == "" then null else $rid end)
  }
  | if $fcm != "" then .calls_made_this_hour = ($fcm|tonumber) else . end
  ' > "$local_tmp.hook" 2>/dev/null

if [[ -f "$RALPH_DIR/status.json" ]] && jq -e 'type == "object"' "$RALPH_DIR/status.json" >/dev/null 2>&1; then
  # Merge: existing status.json + hook fields (hook wins on overlap).
  # LAST-ISSUE: after merge, if linear_issue is now non-null, persist it as
  # last_linear_issue so the monitor can show it during the next executing loop
  # (when linear_issue resets to null before Claude picks the next issue).
  jq -s '(.[0] * .[1]) | if .linear_issue != null then .last_linear_issue = .linear_issue else . end' \
    "$RALPH_DIR/status.json" "$local_tmp.hook" > "$local_tmp" 2>/dev/null \
    || cp "$local_tmp.hook" "$local_tmp"
else
  jq 'if .linear_issue != null then .last_linear_issue = .linear_issue else . end' \
    "$local_tmp.hook" > "$local_tmp" 2>/dev/null \
    || cp "$local_tmp.hook" "$local_tmp"
fi
rm -f "$local_tmp.hook" 2>/dev/null

mv "$local_tmp" "$RALPH_DIR/status.json"
rm -f "$local_tmp" 2>/dev/null  # WSL-1: catch cross-fs copy+unlink orphans

# PERF: Update circuit breaker in a single jq call (was: 2-3 separate jq + mktemp + mv per branch)
if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
  # TAP-538: Guard against corrupt CB state. If jq cannot parse the file the
  # downstream `jq … > tmp && mv` pattern silently no-ops and the state stays
  # corrupt forever. Re-initialize to a safe skeleton and emit a WARN line so
  # the hook still exits 0 (preserving the loop) instead of crashing.
  if ! jq -e 'type == "object"' "$RALPH_DIR/.circuit_breaker_state" >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] WARN: .circuit_breaker_state is corrupt — reinitializing to CLOSED" >&2
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
      > "$RALPH_DIR/.circuit_breaker_state"
  fi
  local_tmp=$(mktemp "$RALPH_DIR/.circuit_breaker_state.XXXXXX")
  if [[ "$files_modified" -gt 0 || "$tasks_done" -gt 0 ]]; then
    # Progress detected — reset no-progress counter, permission denials, and close
    jq '.consecutive_no_progress = 0 | .consecutive_permission_denials = 0 | .state = "CLOSED"' \
      "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" 2>/dev/null \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
  elif [[ "$asking_questions" == "true" ]]; then
    # USYNC-3: Claude is asking questions — not progress, but not stagnation either.
    # Suppress no-progress counter; corrective guidance (USYNC-2) will redirect next loop.
    # Also reset permission denial counter (questions aren't denials).
    jq '.consecutive_permission_denials = 0' \
      "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" 2>/dev/null \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
  elif [[ "$has_permission_denials" == "true" ]]; then
    # USYNC-4: Permission denials are deterministic — trip fast with lower threshold.
    pd_threshold=${CB_PERMISSION_DENIAL_THRESHOLD:-2}
    jq --argjson pd_threshold "$pd_threshold" '
      .consecutive_permission_denials = ((.consecutive_permission_denials // 0) + 1) |
      .consecutive_no_progress = ((.consecutive_no_progress // 0) + 1) |
      if .consecutive_permission_denials >= $pd_threshold then
        .state = "OPEN" | .total_opens = ((.total_opens // 0) + 1) | .opened_at = (now | todate) |
        .reason = ("Permission denied " + (.consecutive_permission_denials | tostring) + " consecutive times")
      else . end
    ' "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" 2>/dev/null \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"

    # Log if circuit breaker opened from permission denials
    new_pd=$(jq -r '.consecutive_permission_denials // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
    if [[ "$new_pd" -ge "${pd_threshold}" ]]; then
      echo "Circuit breaker OPEN: permission denied $new_pd consecutive times" >&2
    fi
  elif [[ "$exit_signal" == "true" && ( "$status" == "COMPLETE" || "$status" == "BLOCKED" ) ]]; then
    # EXIT-CLEAN: Claude reported clean exit with EXIT_SIGNAL: true and either:
    #   - STATUS: COMPLETE — plan is empty / nothing to do (Grounds 1 in skill)
    #   - STATUS: BLOCKED — entire queue blocked on external action (Grounds 2)
    # Both are legitimate "stop looping" signals, not stagnation. Reset the
    # no-progress counter so consecutive clean-exit loops don't trip the
    # breaker on the SAME signal Claude is already using to ask for shutdown.
    # Also reset permission denials (none happened) and ensure state stays CLOSED.
    jq '.consecutive_no_progress = 0 | .consecutive_permission_denials = 0 | .state = "CLOSED"' \
      "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" 2>/dev/null \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
  else
    # No progress — single jq call to read threshold, increment, and conditionally open
    # LOGFIX-8: Also increment total_opens when transitioning to OPEN
    threshold=${CB_NO_PROGRESS_THRESHOLD:-3}
    jq --argjson threshold "$threshold" '
      .consecutive_no_progress = ((.consecutive_no_progress // 0) + 1) |
      .consecutive_permission_denials = 0 |
      if .consecutive_no_progress >= $threshold then
        .state = "OPEN" | .total_opens = ((.total_opens // 0) + 1) | .opened_at = (now | todate)
      else . end
    ' "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" 2>/dev/null \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"

    # Log if circuit breaker opened
    new_count=$(jq -r '.consecutive_no_progress // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
    if [[ "$new_count" -ge "${threshold}" ]]; then
      echo "Circuit breaker OPEN: $new_count loops with no progress" >&2
    fi
  fi
  rm -f "$local_tmp" 2>/dev/null  # WSL-1: catch cross-fs orphans
fi

# Log for monitoring
log_line="[$(date '+%H:%M:%S')] Loop $loop_count: status=$status exit=$exit_signal tasks=$tasks_done files=$files_modified type=$work_type"
[[ "$asking_questions" == "true" ]] && log_line+=" questions=$question_count"
[[ "$has_permission_denials" == "true" ]] && log_line+=" denials=$permission_denial_count"
echo "$log_line" >> "$RALPH_DIR/live.log"

# Detailed logging to ralph.log for key decisions
_ralph_log="$RALPH_DIR/logs/ralph.log"
if [[ -f "$_ralph_log" ]]; then
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
  # Log status block parsing result
  if [[ -z "$_status_block" ]]; then
    echo "[$_ts] [WARN] on-stop: No RALPH_STATUS block found in response" >> "$_ralph_log"
  fi
  # Log question detection
  if [[ "$asking_questions" == "true" ]]; then
    echo "[$_ts] [INFO] on-stop: Detected $question_count question pattern(s) in response (USYNC-1)" >> "$_ralph_log"
  fi
  # Log permission denial detection
  if [[ "$has_permission_denials" == "true" ]]; then
    echo "[$_ts] [WARN] on-stop: Detected $permission_denial_count permission denial(s) in response (USYNC-4)" >> "$_ralph_log"
  fi
  # Log circuit breaker state transitions
  if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
    _cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
    _cb_np=$(jq -r '.consecutive_no_progress // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
    if [[ "$_cb_state" == "OPEN" ]]; then
      _cb_reason=$(jq -r '.reason // "no progress threshold"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "unknown")
      echo "[$_ts] [ERROR] on-stop: Circuit breaker OPEN ($_cb_reason)" >> "$_ralph_log"
    elif [[ "$files_modified" -gt 0 || "$tasks_done" -gt 0 ]]; then
      echo "[$_ts] [INFO] on-stop: Progress detected (tasks=$tasks_done files=$files_modified) — circuit breaker reset" >> "$_ralph_log"
    elif [[ "$_cb_np" -gt 0 ]]; then
      echo "[$_ts] [WARN] on-stop: No progress — consecutive_no_progress=$_cb_np" >> "$_ralph_log"
    fi
  fi
  # Log import graph staleness
  if [[ -f "$RALPH_DIR/.import_graph.json.stale" ]]; then
    echo "[$_ts] [INFO] on-stop: Import graph marked stale (new source files created)" >> "$_ralph_log"
  fi
fi

# =============================================================================
# TAP-1528: Halt detector — consecutive responses with no RALPH_STATUS block.
#
# When Claude returns N consecutive responses lacking a parseable RALPH_STATUS
# block, the harness has no way to advance state. The previous behavior was to
# log a WARN and keep looping forever (tapps-brain May 2026 ran 222+ loops in
# this state, burning ~$1.83 with zero work output). This detector tracks the
# count in .ralph/.no_status_block_count, resets on any successful parse, and
# writes .ralph/.harness_halt_reason when the threshold is reached. The main
# loop reads the sentinel at the top of each iteration and breaks cleanly.
#
# The sentinel resists CB_AUTO_RESET (which clears CB OPEN at startup) — this
# is a separate code-path the user must clear manually after fixing the cause.
# =============================================================================
_nsb_threshold="${RALPH_HALT_NO_STATUS_BLOCK_THRESHOLD:-3}"
_nsb_count_file="$RALPH_DIR/.no_status_block_count"
if [[ -z "$_status_block" ]]; then
  _nsb_prev=0
  if [[ -f "$_nsb_count_file" ]]; then
    read -r _nsb_prev < "$_nsb_count_file" 2>/dev/null || _nsb_prev=0
    [[ "$_nsb_prev" =~ ^[0-9]+$ ]] || _nsb_prev=0
  fi
  _nsb_new=$((_nsb_prev + 1))
  printf '%s\n' "$_nsb_new" > "$_nsb_count_file" 2>/dev/null || true
  if [[ "$_nsb_new" -ge "$_nsb_threshold" && ! -f "$RALPH_DIR/.harness_halt_reason" ]]; then
    _resp_len=${#response_text}
    printf 'no_status_block_%sx loop=%s response_bytes=%s\n' \
      "$_nsb_new" "$loop_count" "$_resp_len" > "$RALPH_DIR/.harness_halt_reason" 2>/dev/null || true
    if [[ -f "$_ralph_log" ]]; then
      echo "[$_ts] [FATAL] on-stop: $_nsb_new consecutive responses with no RALPH_STATUS block — halting (loop=$loop_count, response_bytes=$_resp_len)" >> "$_ralph_log"
    fi
    echo "FATAL: $_nsb_new consecutive responses with no RALPH_STATUS block — halting" >&2
  fi
else
  # Successful parse — reset counter
  rm -f "$_nsb_count_file" 2>/dev/null || true
fi

# =============================================================================
# TAP-1529: Halt detector — CB OPEN state thrashing (consecutive opens).
#
# When the CB enters OPEN state for N+ consecutive iterations without an
# intervening progress event, the harness is in a loop-forever pattern: the
# CB opens, an external watchdog (or CB_AUTO_RESET on next session) clears it,
# the loop runs, no progress, CB opens again. This counter increments on each
# OPEN-with-no-progress in this loop and resets on any progress. When >= the
# threshold, write the halt sentinel.
#
# Distinguished from the no-status-block path: a CB OPEN can fire from
# permission denials, no-progress threshold, or fresh-start thrashing — all
# share the same "loop is stuck" signature once consecutive.
# =============================================================================
_cbt_threshold="${RALPH_HALT_CB_OPEN_THRESHOLD:-3}"
_cbt_count_file="$RALPH_DIR/.cb_open_thrash_count"
if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
  _cbt_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
  if [[ "$files_modified" -gt 0 || "$tasks_done" -gt 0 ]]; then
    rm -f "$_cbt_count_file" 2>/dev/null || true
  elif [[ "$_cbt_state" == "OPEN" ]]; then
    _cbt_prev=0
    if [[ -f "$_cbt_count_file" ]]; then
      read -r _cbt_prev < "$_cbt_count_file" 2>/dev/null || _cbt_prev=0
      [[ "$_cbt_prev" =~ ^[0-9]+$ ]] || _cbt_prev=0
    fi
    _cbt_new=$((_cbt_prev + 1))
    printf '%s\n' "$_cbt_new" > "$_cbt_count_file" 2>/dev/null || true
    if [[ "$_cbt_new" -ge "$_cbt_threshold" && ! -f "$RALPH_DIR/.harness_halt_reason" ]]; then
      _cbt_reason=$(jq -r '.reason // "unknown"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "unknown")
      printf 'cb_open_thrash_%sx loop=%s reason=%s\n' \
        "$_cbt_new" "$loop_count" "$_cbt_reason" > "$RALPH_DIR/.harness_halt_reason" 2>/dev/null || true
      if [[ -f "$_ralph_log" ]]; then
        echo "[$_ts] [FATAL] on-stop: CB OPEN $_cbt_new consecutive iterations (reason: $_cbt_reason) — halting (loop=$loop_count)" >> "$_ralph_log"
      fi
      echo "FATAL: CB OPEN $_cbt_new consecutive iterations — halting" >&2
    fi
  fi
fi

# =============================================================================
# QA failure tracking — feeds the type-aware router's Opus escalation path.
#
# When TESTS_STATUS is FAILING for a Linear issue, increment the per-issue
# counter in .ralph/.qa_failures.json. When TESTS_STATUS is PASSING, clear
# the counter. The router (build_claude_command) reads this counter for the
# current issue on the next loop and forces Opus when count >= 3.
#
# DEFERRED / NOT_RUN are explicitly ignored — they're not failure signals
# and resetting on DEFERRED would mask consecutive-failure patterns when
# QA is mid-epic-skipped between two failures.
# =============================================================================
if [[ -n "$linear_issue" ]]; then
  _qa_lib=""
  for _p in "$HOME/.ralph/lib/qa_failures.sh" \
            "${RALPH_INSTALL_DIR:-/nonexistent}/lib/qa_failures.sh" \
            "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")")/../../lib/qa_failures.sh"; do
    [[ -f "$_p" ]] && { _qa_lib="$_p"; break; }
  done
  if [[ -n "$_qa_lib" ]]; then
    # shellcheck source=/dev/null
    source "$_qa_lib"
    case "$tests_status" in
      FAILING)
        qa_failures_increment "$linear_issue" >/dev/null 2>&1 || true
        ;;
      PASSING)
        qa_failures_reset "$linear_issue" >/dev/null 2>&1 || true
        ;;
    esac
  fi
fi

# TAP-750: token propagation for hooks launched outside ralph_loop.sh.
# When Claude Code is launched from VSCode (not via ralph_loop.sh), secrets.env
# is never sourced, so TAPPS_BRAIN_AUTH_TOKEN is absent. Load it here so the
# brain client can authenticate — same fix as Phase A, applied to the hook path.
if [[ -z "${TAPPS_BRAIN_AUTH_TOKEN:-}" && -f "$HOME/.ralph/secrets.env" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$HOME/.ralph/secrets.env" 2>/dev/null || true; set +a
fi

# =============================================================================
# BRAIN-PHASE-B1: Deterministic tapps-brain writes.
#
# Runs after status.json and CB state are finalized, so we can read the
# authoritative outcome for this loop. The client internally gates on
# TAPPS_BRAIN_AUTH_TOKEN + session kill-switch — this block only decides
# *whether the loop was memory-worthy*.
#
# Rationale for writing directly from the hook instead of steering Claude:
# across every stream log on disk Claude never organically called
# brain_remember from a non-brain repo. Brain stays empty → recall returns
# nothing → the feedback loop dies. Hook writes bypass Claude's cooperation
# entirely — every productive loop leaves a trace, every CB trip leaves a
# warning.
# =============================================================================
_brain_lib=""
for _p in "$HOME/.ralph/lib/brain_client.sh" \
          "${RALPH_INSTALL_DIR:-/nonexistent}/lib/brain_client.sh"; do
  [[ -f "$_p" ]] && { _brain_lib="$_p"; break; }
done

if [[ -n "$_brain_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_brain_lib"

  # TAP-918: if the coordinator wrote a brief at the top of this loop AND
  # is not disabled, its debrief pass owns the brain write — skip the
  # hook write to avoid double-counting. The hook write stays as fallback
  # when the coordinator is disabled or its brief is missing (spawn failed
  # before it could write). This check runs in on-stop, which executes
  # BEFORE the coordinator's debrief in the loop sequence — so brief.json
  # is still present here on the coordinator-active path.
  _brain_skip_hook="false"
  if [[ -f "$RALPH_DIR/brief.json" ]] && [[ "${RALPH_COORDINATOR_DISABLED:-false}" != "true" ]]; then
    _brain_skip_hook="true"
  fi

  # Success signal: this loop made real progress. Record what got done so
  # future loops can recall. Task id from Linear field when available.
  if [[ "$_brain_skip_hook" != "true" && "$files_modified" -gt 0 && "$tasks_done" -gt 0 ]]; then
    _brain_desc="Loop $loop_count completed $tasks_done task(s) touching $files_modified file(s)"
    [[ -n "$recommendation" ]] && _brain_desc="${_brain_desc}. ${recommendation:0:200}"
    _brain_task_id="${linear_issue:-}"
    brain_client_write_success "$RALPH_DIR" "$_brain_desc" "$_brain_task_id" "coordinator-fallback" >/dev/null 2>&1 || true
  fi

  # Failure signal: permission denials OR circuit breaker just opened.
  # Both are deterministic "this task is blocked" markers worth memorizing
  # so future loops on the same task can recognize the pattern fast.
  _cb_now="CLOSED"
  if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
    _cb_now=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
  fi
  if [[ "$_brain_skip_hook" != "true" && ( "$has_permission_denials" == "true" || "$_cb_now" == "OPEN" ) ]]; then
    _brain_desc="Loop $loop_count stalled"
    _brain_err=""
    if [[ "$has_permission_denials" == "true" ]]; then
      _brain_desc="${_brain_desc}: $permission_denial_count permission denial(s)"
      _brain_err="permission_denial"
    fi
    if [[ "$_cb_now" == "OPEN" ]]; then
      _cb_reason=$(jq -r '.reason // "no progress threshold reached"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "no progress")
      _brain_desc="${_brain_desc} — circuit breaker OPEN: ${_cb_reason}"
      _brain_err="circuit_breaker_open"
    fi
    _brain_task_id="${linear_issue:-}"
    brain_client_write_failure "$RALPH_DIR" "$_brain_desc" "$_brain_err" "$_brain_task_id" "coordinator-fallback" >/dev/null 2>&1 || true
  fi
fi

exit 0
