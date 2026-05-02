#!/bin/bash
# lib/brain_client.sh
#
# BRAIN-PHASE-B1: Deterministic tapps-brain writes from Ralph hooks.
#
# Ralph's prompt steering for tapps-brain was too soft — across every stream
# log on disk, Claude never organically called brain_recall/remember from a
# non-brain repo. Without writes, brain stays empty; with an empty brain,
# recall returns nothing and the whole feedback loop dies.
#
# This module sidesteps the "will Claude call the tool?" question by posting
# directly to brain's /v1/remember HTTP endpoint when the on-stop hook
# detects a memory-worthy signal:
#   - success: tasks_done > 0 AND files_modified > 0 in this loop
#   - failure: circuit breaker opened OR permission denials detected
#
# Writes are fire-and-forget with a 3-second timeout and a session-scoped
# kill-switch — one HTTP failure silences the rest of the session so Ralph's
# loop cadence is never slowed by a flaky brain.
#
# Authentication flows via TAPPS_BRAIN_AUTH_TOKEN (loaded from
# ~/.ralph/secrets.env in Phase A). URL flows from the project's .mcp.json
# tapps-brain entry; if absent, the local-dev default is used.
#
# Metrics written to $RALPH_DIR/metrics/brain.jsonl — one row per attempted
# write (success or failure) — so `ralph --stats` can show whether B1 is
# actually hitting the network.

# Guard against double-source.
if [[ "${_RALPH_BRAIN_CLIENT_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_RALPH_BRAIN_CLIENT_LOADED=1

# =============================================================================
# brain_client_endpoint - derive /v1/remember URL from .mcp.json
#
# Echoes a URL on stdout; returns non-zero if nothing usable is found.
# The MCP transport URL ends in /mcp/; we swap that suffix for /v1/remember.
# =============================================================================
brain_client_endpoint() {
    local mcp_json="${1:-./.mcp.json}"
    local url=""
    if [[ -f "$mcp_json" ]] && command -v jq &>/dev/null; then
        url=$(jq -r '.mcpServers["tapps-brain"].url // ""' "$mcp_json" 2>/dev/null || echo "")
    fi
    [[ -z "$url" || "$url" == "null" ]] && url="http://127.0.0.1:8080/mcp/"
    # scheme://host[:port]/v1/remember
    echo "$url" | sed -E 's#(https?://[^/]+).*#\1/v1/remember#'
}

# =============================================================================
# brain_client_project_id - derive X-Project-Id from .mcp.json, falling back
# to the basename of the current project directory.
# =============================================================================
brain_client_project_id() {
    local mcp_json="${1:-./.mcp.json}"
    local pid=""
    if [[ -f "$mcp_json" ]] && command -v jq &>/dev/null; then
        pid=$(jq -r '.mcpServers["tapps-brain"].headers["X-Project-Id"] // ""' "$mcp_json" 2>/dev/null || echo "")
    fi
    if [[ -z "$pid" || "$pid" == "null" ]]; then
        pid=$(basename "$(pwd)" 2>/dev/null | tr -cd '[:alnum:]._-' | head -c 64)
    fi
    echo "${pid:-unknown}"
}

# =============================================================================
# brain_client_enabled - gate writes on prerequisites.
#
# Returns 0 when a write should be attempted, non-zero to skip.
# Checked (in order): session kill-switch, TAPPS_BRAIN_AUTH_TOKEN, curl
# availability. Does NOT probe the server — that would cost every hook
# call; instead we rely on the write itself to fail-loud and trip the
# kill-switch.
# =============================================================================
brain_client_enabled() {
    local ralph_dir="${1:-${RALPH_DIR:-.ralph}}"
    # Session kill-switch — set by brain_client_record_metric on failure.
    [[ -f "$ralph_dir/.brain_disabled_this_session" ]] && return 1
    [[ -z "${TAPPS_BRAIN_AUTH_TOKEN:-}" ]] && return 1
    command -v curl &>/dev/null || return 1
    return 0
}

# =============================================================================
# brain_client_record_metric - append one JSONL row per attempt.
#
# On error status, also write the session kill-switch file so subsequent
# writes in the same session no-op. The switch is cleared at session start
# by ralph_loop.sh (see brain_client_clear_session_disable).
# =============================================================================
brain_client_record_metric() {
    local ralph_dir="${1:?ralph_dir required}"
    local op="${2:?op required}"            # success | failure
    local http_code="${3:-000}"
    local ms="${4:-0}"
    local reason="${5:-}"
    # TAP-918: tag each row with its origin so `ralph --stats` can show how
    # often the coordinator-debrief path is taking over from the hook path.
    # Pre-this-story rows have no `source` field — `ralph_show_brain_stats`
    # treats those as `hook` for backward compatibility.
    local source="${6:-hook}"               # hook | coordinator-fallback | coordinator

    local metrics_dir="$ralph_dir/metrics"
    mkdir -p "$metrics_dir" 2>/dev/null || return 0
    local file="$metrics_dir/brain.jsonl"

    local ok="false"
    [[ "$http_code" == "200" ]] && ok="true"

    if command -v jq &>/dev/null; then
        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
        jq -cn \
            --arg ts "$ts" \
            --arg op "$op" \
            --arg code "$http_code" \
            --argjson ms "$ms" \
            --arg reason "$reason" \
            --argjson ok "$ok" \
            --arg source "$source" \
            '{timestamp:$ts, op:$op, http_code:$code, latency_ms:$ms, reason:$reason, ok:$ok, source:$source}' \
            >> "$file" 2>/dev/null || true
    fi

    # TAP-747: trip the kill-switch on network errors (000) or client errors
    # (4xx), but NOT on 5xx. A 5xx is a server-side bug (the server received
    # the request but errored internally — see TAP-747 where a Pydantic
    # ValidationError returns 500 instead of 400). Silencing on 5xx would
    # permanently disable writes for a server bug outside our control.
    if [[ "$ok" == "false" && ( "$http_code" == "000" || "${http_code:0:1}" == "4" ) ]]; then
        touch "$ralph_dir/.brain_disabled_this_session" 2>/dev/null || true
    fi
}

# =============================================================================
# brain_client_clear_session_disable - clear the kill-switch at session start.
# Called from ralph_loop.sh so a new session starts with brain writes enabled
# even if the previous session tripped it.
# =============================================================================
brain_client_clear_session_disable() {
    local ralph_dir="${1:-${RALPH_DIR:-.ralph}}"
    rm -f "$ralph_dir/.brain_disabled_this_session" 2>/dev/null || true
}

# =============================================================================
# _brain_client_post - internal. POST JSON body to /v1/remember.
# Echoes "HTTP_CODE ELAPSED_MS" on stdout. Never exits non-zero — caller
# decides based on the HTTP code.
# =============================================================================
_brain_client_post() {
    local url="$1"
    local project_id="$2"
    local body="$3"

    local start_ms end_ms code
    # Millisecond-resolution timing that works on bash 4+ and macOS.
    start_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo "0")

    code=$(curl -sS -o /dev/null --max-time 3 -w "%{http_code}" \
        -X POST "$url" \
        -H "Authorization: Bearer ${TAPPS_BRAIN_AUTH_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Project-Id: $project_id" \
        -H "X-Agent-Id: ralph-loop" \
        --data-raw "$body" 2>/dev/null || echo "000")

    end_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo "0")
    local elapsed=$((end_ms - start_ms))
    [[ "$elapsed" -lt 0 ]] && elapsed=0

    echo "$code $elapsed"
}

# =============================================================================
# _brain_client_key - produce a key that matches brain's validator.
#
# brain's MemoryEntry validator requires: lowercase slug, letters/digits/
# dots/hyphens/underscores, 1-128 chars, starts with alphanumeric.
# We take first ~32 chars of sha256(op + content) — all lowercase hex.
# =============================================================================
_brain_client_key() {
    local op="$1"
    local content="$2"
    if command -v sha256sum &>/dev/null; then
        printf '%s\n' "${op}:${content}" | sha256sum | cut -c1-32
    elif command -v shasum &>/dev/null; then
        # macOS fallback
        printf '%s\n' "${op}:${content}" | shasum -a 256 | cut -c1-32
    else
        # Worst case — use date epoch + pid. Still matches the regex.
        printf '%s%s' "$(date +%s)" "$$"
    fi
}

# =============================================================================
# brain_client_write_success - record a successful task outcome.
#
# Shape matches tapps-brain's memory_service.brain_learn_success:
#   tier=procedural, tags=["success", "task:<id>"], agent_scope=domain
#   so learnings compound across all Ralph projects.
# =============================================================================
brain_client_write_success() {
    local ralph_dir="${1:?ralph_dir required}"
    local description="${2:?description required}"
    local task_id="${3:-}"
    local source="${4:-hook}"   # TAP-918: caller marks origin for metrics

    brain_client_enabled "$ralph_dir" || return 0

    local url project_id
    url=$(brain_client_endpoint)
    project_id=$(brain_client_project_id)

    # Brain expects key to be a deterministic slug — matches behavior of
    # brain_learn_success('_content_key("success-" + desc)') server-side.
    local key
    key="success-$(_brain_client_key "success" "$description")"

    local body
    if command -v jq &>/dev/null; then
        local tags_json
        if [[ -n "$task_id" ]]; then
            tags_json=$(jq -cn --arg t "$task_id" '["success", ("task:" + $t)]')
        else
            tags_json='["success"]'
        fi
        body=$(jq -cn \
            --arg key "$key" \
            --arg value "$description" \
            --argjson tags "$tags_json" \
            '{
                key: $key,
                value: $value,
                tier: "procedural",
                source: "agent",
                tags: $tags,
                agent_scope: "domain"
            }')
    else
        return 0
    fi

    local result code ms
    result=$(_brain_client_post "$url" "$project_id" "$body")
    code="${result% *}"
    ms="${result#* }"
    brain_client_record_metric "$ralph_dir" "success" "$code" "$ms" "" "$source"
}

# =============================================================================
# brain_client_write_failure - record a failed task outcome.
#
# Shape matches tapps-brain's memory_service.brain_learn_failure.
# =============================================================================
brain_client_write_failure() {
    local ralph_dir="${1:?ralph_dir required}"
    local description="${2:?description required}"
    local error_msg="${3:-}"
    local task_id="${4:-}"
    local source="${5:-hook}"   # TAP-918: caller marks origin for metrics

    brain_client_enabled "$ralph_dir" || return 0

    local url project_id
    url=$(brain_client_endpoint)
    project_id=$(brain_client_project_id)

    local key
    key="failure-$(_brain_client_key "failure" "$description")"

    local value="$description"
    [[ -n "$error_msg" ]] && value="${description}"$'\n\n'"Error: ${error_msg}"

    local body
    if command -v jq &>/dev/null; then
        local tags_json
        if [[ -n "$task_id" ]]; then
            tags_json=$(jq -cn --arg t "$task_id" '["failure", ("task:" + $t)]')
        else
            tags_json='["failure"]'
        fi
        body=$(jq -cn \
            --arg key "$key" \
            --arg value "$value" \
            --argjson tags "$tags_json" \
            '{
                key: $key,
                value: $value,
                tier: "procedural",
                source: "agent",
                tags: $tags,
                agent_scope: "domain"
            }')
    else
        return 0
    fi

    local result code ms
    result=$(_brain_client_post "$url" "$project_id" "$body")
    code="${result% *}"
    ms="${result#* }"
    brain_client_record_metric "$ralph_dir" "failure" "$code" "$ms" "${error_msg:0:80}" "$source"
}
