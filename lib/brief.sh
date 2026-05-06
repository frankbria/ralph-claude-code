#!/usr/bin/env bash
# lib/brief.sh — read/write/validate helpers for .ralph/brief.json
#
# The coordinator agent (TAP-913) writes a structured brief at the start of
# each task; sub-agents and ralph_loop.sh read it for context. This module
# is the single source of truth for the schema (see docs/specs/brief-schema.md).
#
# Pure-bash + jq. Sourceable from any caller. Defines its own atomic_write
# only if the parent shell hasn't already provided one (ralph_loop.sh does).

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

# Resolved brief path. Honors RALPH_DIR override (tests use a tmpdir).
brief_path() {
    echo "${RALPH_DIR:-.ralph}/brief.json"
}

# Returns 0 if the brief file exists and is non-empty.
brief_exists() {
    local p
    p=$(brief_path)
    [[ -s "$p" ]]
}

# Echo one top-level field via jq. Empty stdout + non-zero exit on missing
# file or absent field. Caller decides whether absence is fatal.
brief_read_field() {
    local field="$1"
    local p
    p=$(brief_path)
    [[ -n "$field" ]] || return 2
    [[ -s "$p" ]] || return 1
    local value
    value=$(jq -r --arg f "$field" '.[$f] // empty' "$p" 2>/dev/null) || return 1
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

# Validate a brief file against the schema. Returns 0 if valid; non-zero
# with a single 'brief_validate: <reason>' line on stderr otherwise.
#
# Usage: brief_validate <path>
brief_validate() {
    local p="${1:-}"
    [[ -n "$p" ]] || { echo "brief_validate: path argument required" >&2; return 2; }
    [[ -s "$p" ]] || { echo "brief_validate: file missing or empty: $p" >&2; return 1; }

    # First gate: parses as JSON object.
    if ! jq -e 'type == "object"' "$p" >/dev/null 2>&1; then
        echo "brief_validate: not a JSON object" >&2
        return 1
    fi

    # Required fields and their types. jq does the heavy lifting in one pass.
    local check
    check=$(jq -r '
        def fail($msg): "FAIL:" + $msg;
        # Required scalar fields with type checks.
        if (.schema_version | type) != "number" then fail("schema_version must be number")
        elif .schema_version != 1                 then fail("schema_version must be 1")
        elif (.task_id | type) != "string" or .task_id == "" then fail("task_id must be non-empty string")
        elif (.task_source | type) != "string"    then fail("task_source must be string")
        elif ([.task_source] | inside(["linear","file"]) | not) then fail("task_source must be linear|file")
        elif (.task_summary | type) != "string" or .task_summary == "" then fail("task_summary must be non-empty string")
        elif (.risk_level | type) != "string"     then fail("risk_level must be string")
        elif ([.risk_level] | inside(["LOW","MEDIUM","HIGH"]) | not) then fail("risk_level must be LOW|MEDIUM|HIGH")
        elif (.affected_modules | type) != "array" then fail("affected_modules must be array")
        elif (.acceptance_criteria | type) != "array" then fail("acceptance_criteria must be array")
        elif (has("prior_learnings") and (.prior_learnings | type) != "array") then fail("prior_learnings must be array")
        elif (.qa_required | type) != "boolean"   then fail("qa_required must be boolean")
        elif (has("qa_scope") and (.qa_scope | type) != "string") then fail("qa_scope must be string")
        elif (.delegate_to | type) != "string"    then fail("delegate_to must be string")
        elif ([.delegate_to] | inside(["ralph","ralph-architect"]) | not) then fail("delegate_to must be ralph|ralph-architect")
        elif (.coordinator_confidence | type) != "number" then fail("coordinator_confidence must be number")
        elif (.coordinator_confidence < 0 or .coordinator_confidence > 1) then fail("coordinator_confidence must be in [0.0, 1.0]")
        elif (.created_at | type) != "string" or .created_at == "" then fail("created_at must be non-empty string")
        else "OK"
        end
    ' "$p" 2>/dev/null) || {
        echo "brief_validate: jq parse failed" >&2
        return 1
    }

    if [[ "$check" != "OK" ]]; then
        echo "brief_validate: ${check#FAIL:}" >&2
        return 1
    fi
    return 0
}

# Atomically write a JSON string as the brief. The string is validated by
# parsing through jq before the rename — invalid JSON never overwrites a
# good brief.
#
# Usage: brief_write '{"schema_version":1,...}'
brief_write() {
    local payload="${1:-}"
    [[ -n "$payload" ]] || { echo "brief_write: payload required" >&2; return 2; }

    # Parse + canonicalize via jq. This rejects invalid JSON before any
    # filesystem write.
    local canon
    if ! canon=$(jq -c . <<<"$payload" 2>/dev/null); then
        echo "brief_write: invalid JSON payload" >&2
        return 1
    fi

    local p dir
    p=$(brief_path)
    dir=$(dirname -- "$p")
    [[ -d "$dir" ]] || mkdir -p -- "$dir" || {
        echo "brief_write: cannot create $dir" >&2
        return 1
    }

    atomic_write "$p" "$canon"
}

# Atomic in-place patch of a single top-level field. Re-validates the
# resulting JSON before the rename — a malformed patch never overwrites a
# good brief. Boolean / null / number values are passed through verbatim
# (e.g. "true", "false", "null", "0.7"); anything else is stored as a string.
#
# Usage: brief_patch_field <field> <value>
brief_patch_field() {
    local field="${1:-}"
    local value="${2-}"
    [[ -n "$field" ]] || { echo "brief_patch_field: field required" >&2; return 2; }

    local p
    p=$(brief_path)
    [[ -s "$p" ]] || { echo "brief_patch_field: brief missing: $p" >&2; return 1; }

    local patched
    case "$value" in
        true|false|null)
            patched=$(jq -c --arg f "$field" --argjson v "$value" '.[$f] = $v' "$p" 2>/dev/null) || patched=""
            ;;
        *)
            if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                patched=$(jq -c --arg f "$field" --argjson v "$value" '.[$f] = $v' "$p" 2>/dev/null) || patched=""
            else
                patched=$(jq -c --arg f "$field" --arg v "$value" '.[$f] = $v' "$p" 2>/dev/null) || patched=""
            fi
            ;;
    esac

    [[ -n "$patched" ]] || { echo "brief_patch_field: jq patch failed" >&2; return 1; }
    atomic_write "$p" "$patched"
}

# Remove the brief — used at task close so the next loop starts fresh.
brief_clear() {
    local p
    p=$(brief_path)
    rm -f -- "$p" 2>/dev/null
    return 0
}
