#!/bin/bash
# Queue Manager Component for Ralph (Issue #72)
# Persistent, priority- and dependency-aware queue of work items (GitHub
# issues or local PRD specs) for batch processing.
#
# State lives in $RALPH_DIR/queue.json (default .ralph/queue.json), following
# the same JSON-state convention as lib/circuit_breaker.sh. All mutations are
# read-modify-write through a temp file + mv so a crashed jq never leaves a
# half-written queue.

# Source date utilities for cross-platform ISO timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"
QUEUE_FILE="${QUEUE_FILE:-$RALPH_DIR/queue.json}"

# Valid per-issue status values
QUEUE_VALID_STATUSES="pending processing completed failed skipped"

# --- internals --------------------------------------------------------------

# _queue_apply <jq_program> [extra jq options...]
# Apply a jq transform to the queue file atomically, always refreshing
# updated_at. The program may reference $now (the new timestamp). Extra jq
# options (e.g. --arg id 69) are passed through before the program.
_queue_apply() {
    local program=$1
    shift
    local now tmp
    now=$(get_iso_timestamp)
    tmp=$(mktemp "${QUEUE_FILE}.XXXXXX") || return 1
    if jq --arg now "$now" "$@" "($program) | .updated_at = \$now" "$QUEUE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$QUEUE_FILE"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# jq snippet: select the entry matching identifier $id (issue number or id)
_QUEUE_MATCH='((.issue_number != null) and ((.issue_number|tostring) == $id)) or (.id == $id)'

# --- initialization ---------------------------------------------------------

# init_queue [repository]
# Create the queue file if absent (idempotent); recreate it if corrupt.
init_queue() {
    local repository="${1:-}"

    mkdir -p "$(dirname "$QUEUE_FILE")"

    if [[ -f "$QUEUE_FILE" ]]; then
        if jq -e '.' "$QUEUE_FILE" > /dev/null 2>&1; then
            return 0   # valid, leave it alone
        fi
        rm -f "$QUEUE_FILE"   # corrupt, recreate
    fi

    local now
    now=$(get_iso_timestamp)
    # Build with jq so a repository string containing quotes/backslashes/
    # newlines can't produce invalid JSON (codex review, #72).
    jq -n --arg now "$now" --arg repo "$repository" '{
        version: "1.0",
        created_at: $now,
        updated_at: $now,
        repository: $repo,
        queue: []
    }' > "$QUEUE_FILE"
}

# --- helpers reused by callers ---------------------------------------------

# get_priority_from_labels <labels_json_array>
# Echo the highest-priority token (lowest digit) among the labels, e.g. "P0".
# Understands bare "P0".."P9" and "priority: PN" forms (case-insensitive).
# Echoes the empty string when no priority label is present. Mirrors the
# selection logic in ralph_import.sh's select_issue_from_candidates.
get_priority_from_labels() {
    local labels_json="${1:-[]}"
    local digit
    digit=$(echo "$labels_json" | jq -r '
        [ .[]?.name
          | ascii_downcase
          | (capture("^p(?<d>[0-9])$") // capture("^priority:\\s*p(?<d>[0-9])$") // empty)
          | .d | tonumber
        ] | min // empty' 2>/dev/null)
    [[ -n "$digit" ]] && echo "P${digit}"
}

# parse_issue_dependencies <text>
# Echo issue numbers referenced as dependencies ("depends on #N",
# "blocked by #N", "requires #N"), one per line, deduped and numerically
# sorted. Case-insensitive; tolerates an optional colon and extra spaces.
parse_issue_dependencies() {
    local text="${1:-}"
    echo "$text" \
        | grep -oiE '(depends on|blocked by|requires)[[:space:]]*:?[[:space:]]*#[0-9]+' \
        | grep -oE '[0-9]+' \
        | sort -n -u
}

# --- mutations --------------------------------------------------------------

# add_to_queue <entry_json>
# Append an entry (a JSON object with at least a "source"). Fills defaults
# (id, status=pending, timestamps, dependencies=[]). Dedupes by id.
# Returns: 0 added, 1 invalid input, 2 duplicate (skipped).
add_to_queue() {
    local entry="${1:-}"

    # Validate JSON object
    if ! echo "$entry" | jq -e 'type == "object"' > /dev/null 2>&1; then
        echo "ERROR: add_to_queue requires a JSON object" >&2
        return 1
    fi

    [[ -f "$QUEUE_FILE" ]] || init_queue

    local now
    now=$(get_iso_timestamp)

    # Normalize: derive id, fill defaults
    local normalized
    normalized=$(echo "$entry" | jq -c --arg now "$now" '
        . as $e
        | .source = (.source // "prd")
        | .id = (.id //
                 (if .source == "github" and (.issue_number != null)
                  then "github-\(.issue_number)"
                  else "prd-" + ((.path // .title // "item")
                                 | ascii_downcase | gsub("[^a-z0-9]+"; "-")
                                 | gsub("^-+|-+$"; ""))
                  end))
        | .title = (.title // "")
        | .priority = (.priority // "")
        | .labels = (.labels // [])
        | .dependencies = (.dependencies // [])
        | .milestone = (.milestone // null)
        | .status = (.status // "pending")
        | .added_at = (.added_at // $now)
        | .started_at = (.started_at // null)
        | .completed_at = (.completed_at // null)
        | .error_message = (.error_message // "")
    ')

    local id
    id=$(echo "$normalized" | jq -r '.id')

    # Dedupe by id
    if jq -e --arg id "$id" 'any(.queue[]; .id == $id)' "$QUEUE_FILE" > /dev/null 2>&1; then
        echo "WARN: queue already contains '$id'; skipping" >&2
        return 2
    fi

    _queue_apply '.queue += [$entry]' --argjson entry "$normalized" || return 1
    return 0
}

# remove_from_queue <id_or_number>
# Remove the matching entry. Returns 0 if removed, 1 if not found.
remove_from_queue() {
    local id="${1:-}"
    [[ -f "$QUEUE_FILE" ]] || return 1

    if ! jq -e --arg id "$id" "any(.queue[]; $_QUEUE_MATCH)" "$QUEUE_FILE" > /dev/null 2>&1; then
        return 1
    fi
    _queue_apply ".queue |= map(select(($_QUEUE_MATCH) | not))" --arg id "$id"
}

# clear_queue - remove all entries
clear_queue() {
    [[ -f "$QUEUE_FILE" ]] || init_queue
    _queue_apply '.queue = []'
}

# mark_issue_status <id_or_number> <status> [error_message]
# Update an entry's status and stamp started_at/completed_at as appropriate.
# Returns 0 on success, 1 if the entry is missing or the status is invalid.
mark_issue_status() {
    local id="${1:-}"
    local new_status="${2:-}"
    local error_message="${3:-}"

    [[ -f "$QUEUE_FILE" ]] || return 1

    # Validate status
    case " $QUEUE_VALID_STATUSES " in
        *" $new_status "*) ;;
        *) echo "ERROR: invalid status '$new_status'" >&2; return 1 ;;
    esac

    if ! jq -e --arg id "$id" "any(.queue[]; $_QUEUE_MATCH)" "$QUEUE_FILE" > /dev/null 2>&1; then
        return 1
    fi

    _queue_apply "
        .queue |= map(
            if ($_QUEUE_MATCH) then
                  .status = \$st
                | .error_message = (if \$st == \"failed\" then \$err else .error_message end)
                | .started_at = (if \$st == \"processing\" and (.started_at == null) then \$now else .started_at end)
                | .completed_at = (if (\$st == \"completed\" or \$st == \"failed\" or \$st == \"skipped\") then \$now else .completed_at end)
            else . end)
    " --arg id "$id" --arg st "$new_status" --arg err "$error_message"
}

# sort_queue_by_priority - reorder the queue by priority (P0 first), keeping
# FIFO order within the same priority. Unprioritized entries sort last.
sort_queue_by_priority() {
    [[ -f "$QUEUE_FILE" ]] || return 1
    _queue_apply '
        .queue = (
            [ .queue | to_entries[] | .value + {__order: .key} ]
            | map(. + {__rank: (
                [ .priority // "" | ascii_downcase
                  | (capture("p(?<d>[0-9])") | .d | tonumber) ] | (.[0] // 99))})
            | sort_by(.__rank, .__order)
            | map(del(.__rank, .__order))
        )'
}

# --- queries ----------------------------------------------------------------

# get_queue_status - echo a JSON object of counts by status
get_queue_status() {
    [[ -f "$QUEUE_FILE" ]] || init_queue
    jq '{
        total:      (.queue | length),
        pending:    ([.queue[] | select(.status=="pending")]    | length),
        processing: ([.queue[] | select(.status=="processing")] | length),
        completed:  ([.queue[] | select(.status=="completed")]  | length),
        failed:     ([.queue[] | select(.status=="failed")]     | length),
        skipped:    ([.queue[] | select(.status=="skipped")]    | length)
    }' "$QUEUE_FILE"
}

# is_dependency_satisfied <id_or_number>
# Return 0 if every dependency of the entry is completed (or not blocking),
# 1 otherwise (or if the entry is missing).
is_dependency_satisfied() {
    local id="${1:-}"
    [[ -f "$QUEUE_FILE" ]] || return 1

    # A dependency blocks only if it is itself a queue item that hasn't
    # completed yet. A dependency on an issue NOT in the queue is treated as an
    # already-satisfied external prerequisite (matches validate_dependencies and
    # the documented contract; CodeRabbit #72).
    local result
    result=$(jq -r --arg id "$id" "
        ([ .queue[] | select(.status==\"completed\") | .issue_number ]) as \$done
        | ([ .queue[].issue_number | select(. != null) ]) as \$all
        | (.queue[] | select($_QUEUE_MATCH)) as \$e
        | (\$e.dependencies // [])
        | all(. as \$d | (\$done | index(\$d)) != null or (\$all | index(\$d)) == null)
    " "$QUEUE_FILE" 2>/dev/null)

    [[ "$result" == "true" ]] && return 0
    return 1
}

# get_next_issue - echo the id of the next ready pending entry (deps met),
# choosing by priority then FIFO order. Returns 1 with no output if none ready.
get_next_issue() {
    [[ -f "$QUEUE_FILE" ]] || return 1

    local id
    id=$(jq -r '
        ([ .queue[] | select(.status=="completed") | .issue_number ]) as $done
        | ([ .queue[].issue_number | select(. != null) ]) as $all
        | [ .queue | to_entries[] | .value + {__order: .key} ]
        | map(select(.status=="pending"))
        | map(select((.dependencies // []) | all(. as $d | ($done | index($d)) != null or ($all | index($d)) == null)))
        | map(. + {__rank: (
            [ .priority // "" | ascii_downcase
              | (capture("p(?<d>[0-9])") | .d | tonumber) ] | (.[0] // 99))})
        | sort_by(.__rank, .__order)
        | .[0].id // empty
    ' "$QUEUE_FILE" 2>/dev/null)

    if [[ -z "$id" ]]; then
        return 1
    fi
    echo "$id"
}

# validate_dependencies - detect circular dependencies among queued issues.
# Returns 0 if acyclic, 1 if a cycle is found (details to stderr). Only
# github entries (with issue_number) participate; dependencies pointing
# outside the queue are treated as already-satisfied external prerequisites.
validate_dependencies() {
    [[ -f "$QUEUE_FILE" ]] || return 1

    # Iterative cycle detection over the in-queue dependency edges, done in jq
    # via repeated transitive-closure expansion: a node that can reach itself
    # is on a cycle.
    local has_cycle
    has_cycle=$(jq -r '
        # adjacency restricted to issues present in the queue
        ([ .queue[] | select(.issue_number != null) | .issue_number ]) as $nodes
        | ([ .queue[] | select(.issue_number != null)
             | {key: (.issue_number|tostring),
                value: [ (.dependencies // [])[] | select(. as $d | $nodes | index($d)) | tostring ]} ]
           | from_entries) as $adj
        | reduce $nodes[] as $start (false;
            if . then true
            else
                # BFS from $start; cycle if we revisit $start
                ({stack: ($adj[($start|tostring)] // []), seen: {}} |
                 # bounded expansion: at most (#nodes) hops
                 reduce range(0; ($nodes|length)+1) as $_ (.;
                    if (.stack | length) == 0 then .
                    else
                        (.stack[0]) as $cur
                        | {stack: (.stack[1:] + ($adj[$cur] // [])),
                           seen: (.seen + {($cur): true})}
                    end)
                 | (.seen[($start|tostring)] == true))
            end)
    ' "$QUEUE_FILE" 2>/dev/null)

    if [[ "$has_cycle" == "true" ]]; then
        echo "ERROR: circular dependency detected in the queue" >&2
        return 1
    fi
    return 0
}
