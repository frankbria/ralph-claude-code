#!/usr/bin/env bash
# lib/coordinator_rpc.sh — TAP-922: coordinator consultation for HIGH-risk tasks.
#
# Invoked by the main ralph agent via Bash:
#   bash /path/to/lib/coordinator_rpc.sh consult "PLAN: one sentence"
#
# Reads .ralph/brief.json to gate on risk_level == HIGH; all other risk
# levels emit {"skipped":true} and exit 0 so the caller never needs to
# special-case non-HIGH paths.
#
# On HIGH-risk tasks, spawns (or resumes via --resume) the ralph-coordinator
# agent with MODE=consult and the supplied plan text. Extracts the verdict
# JSON from the stream output and writes it to stdout.
#
# Stdout contract (always valid JSON, one line):
#   {"verdict":"APPROVE","reason":"...","alternative":null,"elevated_qa":false}
#   {"skipped":true,"reason":"..."}
#
# Exit codes:
#   0 — success (including graceful skip)
#   1 — hard failure (brief unreadable, CLI not found, unexpected error)
#
# Environment:
#   RALPH_DIR                         default: .ralph
#   CLAUDE_CODE_CMD                   default: claude
#   RALPH_COORDINATOR_DISABLED        skip when true
#   DRY_RUN                           skip when true
#   RALPH_COORDINATOR_TIMEOUT_SECONDS timeout for coordinator call (default: 120)
#   COORDINATOR_SESSION_MAX_AGE_SECONDS session TTL (default: 3600)

set -euo pipefail

_RPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers — both are safe to source standalone (they define their own
# atomic_write fallback).
# shellcheck source=lib/brief.sh
[[ -f "$_RPC_DIR/brief.sh" ]] && source "$_RPC_DIR/brief.sh"
# shellcheck source=lib/coordinator_session.sh
[[ -f "$_RPC_DIR/coordinator_session.sh" ]] && source "$_RPC_DIR/coordinator_session.sh"

_rpc_skip() {
    local reason="$1"
    printf '{"skipped":true,"reason":"%s"}\n' "$reason"
    exit 0
}

_rpc_default_approve() {
    local reason="$1"
    printf '{"verdict":"APPROVE","reason":"%s","alternative":null,"elevated_qa":false}\n' "$reason"
}

# --- arg validation ---------------------------------------------------------

if [[ "${1:-}" != "consult" ]]; then
    echo "usage: coordinator_rpc.sh consult \"PLAN: one sentence\"" >&2
    exit 1
fi

PLAN_TEXT="${2:-}"

# --- guards -----------------------------------------------------------------

if [[ "${RALPH_COORDINATOR_DISABLED:-false}" == "true" ]]; then
    _rpc_skip "coordinator disabled"
fi

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _rpc_skip "dry run"
fi

_CLAUDE_CMD="${CLAUDE_CODE_CMD:-claude}"
if ! command -v "$_CLAUDE_CMD" >/dev/null 2>&1; then
    _rpc_skip "claude CLI not on PATH"
fi

# --- risk gate --------------------------------------------------------------

if ! declare -F brief_exists >/dev/null 2>&1 || ! brief_exists 2>/dev/null; then
    _rpc_skip "brief.json missing — cannot determine risk_level"
fi

_RISK=$(jq -r '.risk_level // empty' "$(brief_path)" 2>/dev/null)
if [[ "$_RISK" != "HIGH" ]]; then
    _rpc_skip "risk level is ${_RISK:-unknown} — consultation reserved for HIGH only"
fi

# --- consult invocation -----------------------------------------------------

_TIMEOUT="${RALPH_COORDINATOR_TIMEOUT_SECONDS:-120}"
_STREAM_FILE=$(mktemp -t "coord_consult.XXXXXX" 2>/dev/null || echo "")
_STDOUT="${_STREAM_FILE:-/dev/null}"

_RESUME_ARGS=()
if declare -F coordinator_session_read >/dev/null 2>&1; then
    _SID=$(coordinator_session_read 2>/dev/null)
    if [[ -n "$_SID" ]]; then
        _RESUME_ARGS=(--resume "$_SID")
    fi
fi

_INPUT="MODE=consult
PLAN: ${PLAN_TEXT}

Read .ralph/brief.json for task context. Evaluate this plan against the
acceptance_criteria and prior_learnings. Output ONLY a single JSON line:
{\"verdict\":\"APPROVE|RECONSIDER|BLOCK\",\"reason\":\"one sentence\",\"alternative\":\"one sentence or null\",\"elevated_qa\":true|false}

No prose before or after the JSON line."

_RC=0
if [[ "$_TIMEOUT" == "0" ]]; then
    "$_CLAUDE_CMD" \
        --agent ralph-coordinator \
        --permission-mode bypassPermissions \
        "${_RESUME_ARGS[@]}" \
        --output-format stream-json --verbose \
        -p "$_INPUT" \
        >"$_STDOUT" 2>&1 || _RC=$?
else
    timeout "$_TIMEOUT" "$_CLAUDE_CMD" \
        --agent ralph-coordinator \
        --permission-mode bypassPermissions \
        "${_RESUME_ARGS[@]}" \
        --output-format stream-json --verbose \
        -p "$_INPUT" \
        >"$_STDOUT" 2>&1 || _RC=$?
fi

# Capture session_id from stream output (for future resume).
if [[ -n "$_STREAM_FILE" && -s "$_STREAM_FILE" ]] \
   && declare -F coordinator_session_write >/dev/null 2>&1 \
   && declare -F coordinator_session_extract_from_stream >/dev/null 2>&1; then
    _NEW_SID=$(coordinator_session_extract_from_stream "$_STREAM_FILE" 2>/dev/null)
    [[ -n "$_NEW_SID" ]] && coordinator_session_write "$_NEW_SID" 2>/dev/null || true
fi

if [[ "$_RC" -ne 0 ]]; then
    [[ -n "$_STREAM_FILE" ]] && rm -f -- "$_STREAM_FILE" 2>/dev/null
    _rpc_default_approve "coordinator invocation failed (exit ${_RC}) — defaulting to APPROVE"
    exit 0
fi

# --- verdict extraction -----------------------------------------------------
# The coordinator is told to output exactly one JSON line. Extract it from
# the stream-json result field, or fall back to scanning for bare JSON lines.

_VERDICT=""

if [[ -n "$_STREAM_FILE" && -s "$_STREAM_FILE" ]]; then
    # Primary: parse the result text from stream-json.
    _RESULT_TEXT=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$_STREAM_FILE" \
        | tail -1 \
        | jq -r '.result // empty' 2>/dev/null) || _RESULT_TEXT=""

    if [[ -n "$_RESULT_TEXT" ]]; then
        # Look for a line that starts with {"verdict" in the result text.
        _VERDICT=$(printf '%s\n' "$_RESULT_TEXT" \
            | grep -E '^\{"verdict"' \
            | tail -1) || _VERDICT=""
    fi

    # Fallback: scan the raw stream file for a bare verdict JSON line
    # (handles cases where stream format differs or result wrapping changes).
    if [[ -z "$_VERDICT" ]]; then
        _VERDICT=$(grep -E '^\{"verdict"' "$_STREAM_FILE" | tail -1) || _VERDICT=""
    fi

    rm -f -- "$_STREAM_FILE" 2>/dev/null
fi

if [[ -z "$_VERDICT" ]]; then
    _rpc_default_approve "coordinator output did not contain a verdict JSON line — defaulting to APPROVE"
    exit 0
fi

# Validate the extracted JSON has at least a "verdict" field.
if ! echo "$_VERDICT" | jq -e '.verdict' >/dev/null 2>&1; then
    _rpc_default_approve "coordinator verdict JSON invalid — defaulting to APPROVE"
    exit 0
fi

printf '%s\n' "$_VERDICT"
