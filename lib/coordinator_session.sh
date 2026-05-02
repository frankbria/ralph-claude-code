#!/usr/bin/env bash
# lib/coordinator_session.sh — TAP-920: persist coordinator session_id
# across loops so subsequent spawns can `--resume` instead of cold-starting.
#
# Story 2.1 just lays the plumbing — read/write/clear/age helpers and the
# capture step in ralph_spawn_coordinator. Resume logic itself lands in
# story 2.2 (TAP-921). Session expires after
# ${COORDINATOR_SESSION_MAX_AGE_SECONDS:-3600} seconds; stale files are
# treated as missing by `coordinator_session_read`.
#
# Pure-bash. Sourceable from any caller. Reuses atomic_write from the
# parent shell when present (ralph_loop.sh provides one); falls back to
# its own minimal copy otherwise.

# shellcheck shell=bash

if ! declare -F atomic_write >/dev/null 2>&1; then
    atomic_write() {
        local target="$1"
        local value="$2"
        [[ -n "$target" ]] || return 1
        local dir
        dir=$(dirname -- "$target")
        [[ -d "$dir" ]] || return 1
        local tmp="${target}.tmp.$$.${RANDOM}"
        if ! printf '%s\n' "$value" > "$tmp" 2>/dev/null; then
            rm -f -- "$tmp" 2>/dev/null
            return 1
        fi
        sync -- "$tmp" 2>/dev/null || true
        if ! mv -f -- "$tmp" "$target"; then
            rm -f -- "$tmp" 2>/dev/null
            return 1
        fi
        return 0
    }
fi

coordinator_session_path() {
    echo "${RALPH_DIR:-.ralph}/.coordinator_session"
}

# Echo the stored session_id, or empty if file is missing or stale.
# Stale = older than COORDINATOR_SESSION_MAX_AGE_SECONDS (default 3600).
# A stale file is treated as missing here but NOT auto-deleted — callers
# decide when to clear (story 2.5 owns lifecycle).
coordinator_session_read() {
    local p
    p=$(coordinator_session_path)
    [[ -s "$p" ]] || return 0
    local age
    age=$(coordinator_session_age_seconds)
    local max="${COORDINATOR_SESSION_MAX_AGE_SECONDS:-3600}"
    if [[ "$age" -ge "$max" ]]; then
        return 0
    fi
    local id
    id=$(head -n1 "$p" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$id" ]] && printf '%s\n' "$id"
}

coordinator_session_write() {
    local id="$1"
    [[ -n "$id" ]] || return 1
    local p
    p=$(coordinator_session_path)
    local dir
    dir=$(dirname -- "$p")
    [[ -d "$dir" ]] || mkdir -p -- "$dir" 2>/dev/null || return 1
    atomic_write "$p" "$id"
}

coordinator_session_clear() {
    local p
    p=$(coordinator_session_path)
    rm -f -- "$p" 2>/dev/null
    return 0
}

# Echo the session file's age in seconds. 999999 if missing.
coordinator_session_age_seconds() {
    local p
    p=$(coordinator_session_path)
    [[ -f "$p" ]] || { echo "999999"; return 0; }
    local mtime now
    if mtime=$(stat -c %Y "$p" 2>/dev/null) && [[ -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]]; then
        :
    elif mtime=$(stat -f %m "$p" 2>/dev/null) && [[ -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]]; then
        :
    elif mtime=$(date -r "$p" +%s 2>/dev/null) && [[ -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]]; then
        :
    else
        echo "999999"
        return 0
    fi
    now=$(date +%s 2>/dev/null || echo "0")
    local age=$((now - mtime))
    [[ "$age" -lt 0 ]] && age=0
    echo "$age"
}

# Extract a session_id (UUID) from a JSONL stream file. The Claude CLI
# stream-json format emits multiple objects; we take the first one whose
# `session_id` field is present. Empty stdout + zero exit on no match —
# the caller decides whether absence is fatal.
coordinator_session_extract_from_stream() {
    local stream_file="$1"
    [[ -s "$stream_file" ]] || return 0
    # Portable across mawk + gawk: grep -o emits the matched fragment, then
    # sed peels off the surrounding `"session_id"...:"..."` framing. We
    # take the first hit (head -1) since all subsequent stream lines carry
    # the same id for a single spawn.
    grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]\+"' "$stream_file" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*"([^"]+)"$/\1/'
}
