#!/usr/bin/env bats
# Unit tests for lib/queue_manager.sh (Issue #72)
#
# Covers the queue-state primitives backing batch processing: queue
# initialization/persistence at .ralph/queue.json, add/remove/clear, status
# counts, priority extraction + sorting, dependency parsing + circular
# detection, dependency-aware "next issue" selection, and status transitions.
#
# The lib computes QUEUE_FILE from RALPH_DIR at source time, so each test
# points RALPH_DIR at a temp .ralph dir before sourcing (same pattern as the
# circuit-breaker recovery tests).

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/queue.XXXXXX")"
    cd "$TEST_DIR"
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    source "$PROJECT_ROOT/lib/queue_manager.sh"
    QUEUE_FILE="$RALPH_DIR/queue.json"
}

teardown() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# --- helpers ----------------------------------------------------------------

# Build a GitHub queue entry JSON object for add_to_queue
_gh_entry() {
    local number=$1 title=${2:-"Issue $1"} priority=${3:-""} deps=${4:-"[]"} labels=${5:-"[]"} milestone=${6:-null}
    jq -nc --argjson n "$number" --arg t "$title" --arg p "$priority" \
           --argjson d "$deps" --argjson l "$labels" --argjson m "$milestone" \
      '{source:"github", issue_number:$n, title:$t, priority:$p, dependencies:$d, labels:$l, milestone:$m}'
}

_count() { echo "$1" | jq -r ".$2"; }

# ============================================================================
# init_queue
# ============================================================================

@test "init_queue creates a valid empty queue file" {
    run init_queue
    [ "$status" -eq 0 ]
    [ -f "$QUEUE_FILE" ]
    run jq -e '.' "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 0 ]
    [ "$(jq -r '.version' "$QUEUE_FILE")" = "1.0" ]
}

@test "init_queue records repository when provided" {
    init_queue "owner/repo"
    [ "$(jq -r '.repository' "$QUEUE_FILE")" = "owner/repo" ]
}

@test "init_queue is idempotent - does not clobber existing entries" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    init_queue
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 1 ]
}

@test "init_queue recreates a corrupt queue file" {
    echo "not json {" > "$QUEUE_FILE"
    run init_queue
    [ "$status" -eq 0 ]
    run jq -e '.' "$QUEUE_FILE"
    [ "$status" -eq 0 ]
}

# ============================================================================
# add_to_queue
# ============================================================================

@test "add_to_queue appends a github entry with defaults filled" {
    init_queue
    run add_to_queue "$(_gh_entry 69 'Single import')"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue[0].issue_number' "$QUEUE_FILE")" -eq 69 ]
    [ "$(jq -r '.queue[0].status' "$QUEUE_FILE")" = "pending" ]
    [ "$(jq -r '.queue[0].id' "$QUEUE_FILE")" = "github-69" ]
    [ "$(jq -r '.queue[0].added_at' "$QUEUE_FILE")" != "null" ]
}

@test "add_to_queue auto-initializes the queue if missing" {
    [ ! -f "$QUEUE_FILE" ]
    run add_to_queue "$(_gh_entry 70)"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 1 ]
}

@test "add_to_queue dedupes by id (skips duplicate)" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    run add_to_queue "$(_gh_entry 69)"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 1 ]
}

@test "add_to_queue rejects invalid JSON" {
    init_queue
    run add_to_queue "not-json"
    [ "$status" -eq 1 ]
}

@test "add_to_queue supports a prd source entry with derived id" {
    init_queue
    local entry
    entry=$(jq -nc '{source:"prd", path:"/tmp/specs/login.md", title:"Login spec"}')
    run add_to_queue "$entry"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue[0].source' "$QUEUE_FILE")" = "prd" ]
    [[ "$(jq -r '.queue[0].id' "$QUEUE_FILE")" == prd-* ]]
}

# ============================================================================
# get_priority_from_labels
# ============================================================================

@test "get_priority_from_labels reads bare PN label" {
    run get_priority_from_labels '[{"name":"bug"},{"name":"P1"}]'
    [ "$status" -eq 0 ]
    [ "$output" = "P1" ]
}

@test "get_priority_from_labels reads 'priority: PN' label" {
    run get_priority_from_labels '[{"name":"priority: P2"}]'
    [ "$output" = "P2" ]
}

@test "get_priority_from_labels picks the highest (lowest number) on multiple" {
    run get_priority_from_labels '[{"name":"P3"},{"name":"P0"}]'
    [ "$output" = "P0" ]
}

@test "get_priority_from_labels returns empty when no priority label" {
    run get_priority_from_labels '[{"name":"bug"},{"name":"enhancement"}]'
    [ "$output" = "" ]
}

# ============================================================================
# parse_issue_dependencies
# ============================================================================

@test "parse_issue_dependencies extracts 'depends on #N'" {
    run parse_issue_dependencies "This depends on #69 to land first."
    [ "$status" -eq 0 ]
    [ "$output" = "69" ]
}

@test "parse_issue_dependencies handles blocked by and requires, multiple, deduped+sorted" {
    run parse_issue_dependencies "Blocked by #71. Requires #69. Also depends on #70 and #69 again."
    [ "$(echo "$output" | tr '\n' ' ')" = "69 70 71 " ]
}

@test "parse_issue_dependencies emits nothing when there are no dependency phrases" {
    run parse_issue_dependencies "Just mentions #42 casually with no keyword."
    [ "$output" = "" ]
}

# ============================================================================
# get_queue_status
# ============================================================================

@test "get_queue_status reports counts by status" {
    init_queue
    add_to_queue "$(_gh_entry 1)"
    add_to_queue "$(_gh_entry 2)"
    add_to_queue "$(_gh_entry 3)"
    mark_issue_status 2 processing
    mark_issue_status 3 completed
    local out
    out=$(get_queue_status)
    [ "$(_count "$out" total)" -eq 3 ]
    [ "$(_count "$out" pending)" -eq 1 ]
    [ "$(_count "$out" processing)" -eq 1 ]
    [ "$(_count "$out" completed)" -eq 1 ]
}

# ============================================================================
# remove_from_queue / clear_queue
# ============================================================================

@test "remove_from_queue removes by issue number" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    add_to_queue "$(_gh_entry 70)"
    run remove_from_queue 69
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 1 ]
    [ "$(jq -r '.queue[0].issue_number' "$QUEUE_FILE")" -eq 70 ]
}

@test "remove_from_queue removes by entry id" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    run remove_from_queue github-69
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 0 ]
}

@test "remove_from_queue returns 1 when not found" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    run remove_from_queue 999
    [ "$status" -eq 1 ]
}

@test "clear_queue empties the queue" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    add_to_queue "$(_gh_entry 70)"
    run clear_queue
    [ "$status" -eq 0 ]
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 0 ]
}

# ============================================================================
# mark_issue_status
# ============================================================================

@test "mark_issue_status sets started_at on processing" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    mark_issue_status 69 processing
    [ "$(jq -r '.queue[0].status' "$QUEUE_FILE")" = "processing" ]
    [ "$(jq -r '.queue[0].started_at' "$QUEUE_FILE")" != "null" ]
}

@test "mark_issue_status sets completed_at and error on failure" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    mark_issue_status 69 failed "boom"
    [ "$(jq -r '.queue[0].status' "$QUEUE_FILE")" = "failed" ]
    [ "$(jq -r '.queue[0].completed_at' "$QUEUE_FILE")" != "null" ]
    [ "$(jq -r '.queue[0].error_message' "$QUEUE_FILE")" = "boom" ]
}

@test "mark_issue_status rejects an invalid status" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    run mark_issue_status 69 bogus
    [ "$status" -eq 1 ]
}

@test "mark_issue_status returns 1 for unknown issue" {
    init_queue
    run mark_issue_status 999 completed
    [ "$status" -eq 1 ]
}

# ============================================================================
# sort_queue_by_priority
# ============================================================================

@test "sort_queue_by_priority orders P0 before P2 before unprioritized" {
    init_queue
    add_to_queue "$(_gh_entry 1 'none')"
    add_to_queue "$(_gh_entry 2 'high' 'P0')"
    add_to_queue "$(_gh_entry 3 'mid' 'P2')"
    sort_queue_by_priority
    [ "$(jq -r '.queue[0].issue_number' "$QUEUE_FILE")" -eq 2 ]
    [ "$(jq -r '.queue[1].issue_number' "$QUEUE_FILE")" -eq 3 ]
    [ "$(jq -r '.queue[2].issue_number' "$QUEUE_FILE")" -eq 1 ]
}

@test "sort_queue_by_priority keeps FIFO order within the same priority" {
    init_queue
    add_to_queue "$(_gh_entry 5 'a' 'P1')"
    add_to_queue "$(_gh_entry 3 'b' 'P1')"
    sort_queue_by_priority
    [ "$(jq -r '.queue[0].issue_number' "$QUEUE_FILE")" -eq 5 ]
    [ "$(jq -r '.queue[1].issue_number' "$QUEUE_FILE")" -eq 3 ]
}

# ============================================================================
# dependencies: is_dependency_satisfied / get_next_issue / validate
# ============================================================================

@test "is_dependency_satisfied true when no dependencies" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    run is_dependency_satisfied 69
    [ "$status" -eq 0 ]
}

@test "is_dependency_satisfied false while a dependency is still pending" {
    init_queue
    add_to_queue "$(_gh_entry 68)"
    add_to_queue "$(_gh_entry 70 'dep' '' '[68]')"
    run is_dependency_satisfied 70
    [ "$status" -eq 1 ]
}

@test "is_dependency_satisfied true once the dependency is completed" {
    init_queue
    add_to_queue "$(_gh_entry 68)"
    add_to_queue "$(_gh_entry 70 'dep' '' '[68]')"
    mark_issue_status 68 completed
    run is_dependency_satisfied 70
    [ "$status" -eq 0 ]
}

@test "get_next_issue respects priority order among ready issues" {
    init_queue
    add_to_queue "$(_gh_entry 1 'low' 'P3')"
    add_to_queue "$(_gh_entry 2 'high' 'P0')"
    run get_next_issue
    [ "$status" -eq 0 ]
    [ "$output" = "github-2" ]
}

@test "get_next_issue skips an issue whose dependency is unmet" {
    init_queue
    add_to_queue "$(_gh_entry 68 'dep' 'P1')"
    add_to_queue "$(_gh_entry 70 'blocked-high' 'P0' '[68]')"
    # 70 is higher priority but blocked by 68; 68 should come first
    run get_next_issue
    [ "$output" = "github-68" ]
    mark_issue_status 68 completed
    run get_next_issue
    [ "$output" = "github-70" ]
}

@test "get_next_issue returns 1 when nothing is ready" {
    init_queue
    add_to_queue "$(_gh_entry 1)"
    mark_issue_status 1 completed
    run get_next_issue
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "validate_dependencies passes for an acyclic queue" {
    init_queue
    add_to_queue "$(_gh_entry 68)"
    add_to_queue "$(_gh_entry 70 'x' '' '[68]')"
    run validate_dependencies
    [ "$status" -eq 0 ]
}

@test "validate_dependencies detects a circular dependency" {
    init_queue
    add_to_queue "$(_gh_entry 1 'a' '' '[2]')"
    add_to_queue "$(_gh_entry 2 'b' '' '[1]')"
    run validate_dependencies
    [ "$status" -eq 1 ]
}

@test "queue state persists across re-sourcing the library" {
    init_queue
    add_to_queue "$(_gh_entry 69)"
    # simulate a new process: re-source and read
    source "$PROJECT_ROOT/lib/queue_manager.sh"
    [ "$(jq -r '.queue | length' "$QUEUE_FILE")" -eq 1 ]
}
