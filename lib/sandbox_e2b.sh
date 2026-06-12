#!/bin/bash
# E2B Cloud Sandbox Execution for Ralph (Issue #75)
#
# Runs the Claude Code CLI inside an E2B cloud sandbox (e2b.dev) instead of on
# the host. Ralph's orchestration (loop control, rate limiting, circuit
# breaker, response analysis, status.json) stays on the host — exactly the
# Docker sandbox model (lib/sandbox_docker.sh) — only Claude's execution moves
# to the cloud. Because E2B has no bind mounts, the project is uploaded once
# at startup and changed files are downloaded back after every iteration.
#
# Design notes:
#   - The E2B SDK is Python/JS only, so all API traffic goes through
#     lib/e2b_helper.py (subcommands emit JSON; exec streams remote output and
#     propagates the remote exit code). Tests substitute the interpreter via
#     SANDBOX_E2B_PYTHON to mock the transport.
#   - One sandbox per ralph run, reused across iterations (E2B bills
#     per-second; per-loop creation would multiply cost and lose Claude's
#     in-sandbox session state). --sandbox-keep-alive leaves it running for
#     reuse via --sandbox-id.
#   - Secrets never travel via argv: E2B_API_KEY (env or 0600
#     ~/.ralph/e2b_api_key) and ANTHROPIC_API_KEY reach the helper through the
#     environment; host ~/.claude/.credentials.json is seeded over stdin.
#   - File sync is content-based: commits Claude makes INSIDE the sandbox are
#     not synced back (.git is excluded both directions for host safety) —
#     changes land as uncommitted modifications in the host working tree.
#   - Cost tracking is an estimate: elapsed runtime x SANDBOX_E2B_COST_PER_HOUR.
#     check_e2b_cost_limits stops the loop at --sandbox-max-cost and warns once
#     at --sandbox-cost-alert.
#   - State lives in $RALPH_DIR/.e2b_sandbox_state (JSON), mutated through a
#     temp file + mv — same convention as lib/sandbox_docker.sh.

# Source date utilities for cross-platform timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"
# Sync filter layer: include/exclude/.ralphignore patterns + large-file
# policy applied to upload and download (Issue #76)
source "$(dirname "${BASH_SOURCE[0]}")/sync.sh"

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"
LOG_DIR="${LOG_DIR:-$RALPH_DIR/logs}"
E2B_SANDBOX_STATE_FILE="${E2B_SANDBOX_STATE_FILE:-$RALPH_DIR/.e2b_sandbox_state}"
# Newline list of project-relative paths that exist in the sandbox workspace
# (initialized from the upload, refreshed from each download's manifest) —
# the deletion-sync baseline: only paths on this list may ever be deleted.
E2B_SYNCED_FILES_FILE="${E2B_SYNCED_FILES_FILE:-$RALPH_DIR/.e2b_synced_files}"
# Archive member name carrying the sandbox's current file list (must match
# MANIFEST_NAME in lib/e2b_helper.py)
E2B_SYNC_MANIFEST_NAME=".ralph_e2b_manifest"

# Transport: the Python helper that wraps the official E2B SDK
_E2B_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
SANDBOX_E2B_PYTHON="${SANDBOX_E2B_PYTHON:-python3}"
SANDBOX_E2B_HELPER="${SANDBOX_E2B_HELPER:-$_E2B_LIB_DIR/e2b_helper.py}"

# Sandbox configuration defaults (overridable via .ralphrc, env, or CLI flags)
SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-}"
SANDBOX_E2B_TEMPLATE="${SANDBOX_E2B_TEMPLATE:-base}"
SANDBOX_E2B_SANDBOX_ID="${SANDBOX_E2B_SANDBOX_ID:-}"
SANDBOX_E2B_TIMEOUT="${SANDBOX_E2B_TIMEOUT:-3600}"
SANDBOX_E2B_KEEP_ALIVE="${SANDBOX_E2B_KEEP_ALIVE:-false}"
SANDBOX_E2B_MAX_COST="${SANDBOX_E2B_MAX_COST:-}"
SANDBOX_E2B_COST_ALERT="${SANDBOX_E2B_COST_ALERT:-}"
# Estimated $/hour for a default sandbox — verify against e2b.dev/pricing for
# your template size; only used for the cost estimate and limit enforcement.
SANDBOX_E2B_COST_PER_HOUR="${SANDBOX_E2B_COST_PER_HOUR:-0.10}"
SANDBOX_E2B_WORKDIR="${SANDBOX_E2B_WORKDIR:-/home/user/workspace}"

# API key file fallback when E2B_API_KEY is not exported
E2B_API_KEY_FILE="${E2B_API_KEY_FILE:-$HOME/.ralph/e2b_api_key}"

# --- logging ----------------------------------------------------------------

# _e2b_log <level> <message>
# Prefer the main script's log_status() when available; otherwise fall back to
# stderr so the lib is usable (and testable) standalone.
_e2b_log() {
    local level="$1"
    local message="$2"
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "$message" >&2
    else
        echo "[$level] $message" >&2
    fi
}

# --- transport --------------------------------------------------------------

# _e2b_helper <subcommand> [args...]
# Single boundary to the Python helper — tests replace SANDBOX_E2B_PYTHON with
# a mock that records argv and replays canned responses.
_e2b_helper() {
    "$SANDBOX_E2B_PYTHON" "$SANDBOX_E2B_HELPER" "$@"
}

# --- state primitives -------------------------------------------------------

# _e2b_apply <jq-program> [jq args...]
# Atomically mutate the sandbox state file with a jq program (temp file + mv).
_e2b_apply() {
    local program=$1
    shift
    [[ -f "$E2B_SANDBOX_STATE_FILE" ]] || return 1
    local now tmp
    now=$(get_iso_timestamp)
    tmp=$(mktemp "${E2B_SANDBOX_STATE_FILE}.XXXXXX" 2>/dev/null) || return 1
    if jq --arg now "$now" "$@" "($program) | .updated_at = \$now" \
        "$E2B_SANDBOX_STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$E2B_SANDBOX_STATE_FILE" || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# e2b_state_get <jq-path>
# Print a value from the sandbox state file ("" if missing/null).
e2b_state_get() {
    local path=$1
    [[ -f "$E2B_SANDBOX_STATE_FILE" ]] || return 1
    jq -r "$path // empty" "$E2B_SANDBOX_STATE_FILE" 2>/dev/null
}

# --- availability and validation ----------------------------------------------

# e2b_is_available
# Returns 0 when the Python interpreter, the helper script, and the E2B SDK
# are all usable.
e2b_is_available() {
    if ! command -v "$SANDBOX_E2B_PYTHON" &>/dev/null; then
        _e2b_log "ERROR" "Python interpreter '$SANDBOX_E2B_PYTHON' not found (E2B sandboxing needs python3)"
        return 1
    fi
    if [[ ! -f "$SANDBOX_E2B_HELPER" ]]; then
        _e2b_log "ERROR" "E2B helper not found: $SANDBOX_E2B_HELPER"
        return 1
    fi
    local out
    if ! out=$(_e2b_helper check 2>/dev/null); then
        local err
        err=$(jq -r '.error // empty' <<<"$out" 2>/dev/null)
        _e2b_log "ERROR" "E2B SDK unavailable: ${err:-helper check failed}. Install it with: pip install e2b"
        return 1
    fi
    return 0
}

# validate_e2b_sandbox_config
# Validates the SANDBOX_E2B_* configuration values. Prints the offending
# setting on failure so CLI users get an actionable message.
validate_e2b_sandbox_config() {
    if [[ "$SANDBOX_PROVIDER" != "e2b" ]]; then
        echo "Error: unsupported sandbox provider '$SANDBOX_PROVIDER' (expected: e2b)" >&2
        return 1
    fi
    # Template names allow alphanumerics plus . _ - only — this also blocks
    # shell metacharacters from reaching the remote command line.
    if [[ -z "$SANDBOX_E2B_TEMPLATE" || ! "$SANDBOX_E2B_TEMPLATE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "Error: invalid E2B template '$SANDBOX_E2B_TEMPLATE'" >&2
        return 1
    fi
    if [[ -n "$SANDBOX_E2B_SANDBOX_ID" && ! "$SANDBOX_E2B_SANDBOX_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo "Error: invalid E2B sandbox id '$SANDBOX_E2B_SANDBOX_ID'" >&2
        return 1
    fi
    if [[ ! "$SANDBOX_E2B_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: invalid E2B session timeout '$SANDBOX_E2B_TIMEOUT' (expected seconds, e.g. 3600)" >&2
        return 1
    fi
    if [[ -n "$SANDBOX_E2B_MAX_COST" && ! "$SANDBOX_E2B_MAX_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: invalid max-cost '$SANDBOX_E2B_MAX_COST' (expected e.g. 5.00)" >&2
        return 1
    fi
    if [[ -n "$SANDBOX_E2B_COST_ALERT" && ! "$SANDBOX_E2B_COST_ALERT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: invalid cost-alert '$SANDBOX_E2B_COST_ALERT' (expected e.g. 2.00)" >&2
        return 1
    fi
    if [[ ! "$SANDBOX_E2B_COST_PER_HOUR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: invalid SANDBOX_E2B_COST_PER_HOUR '$SANDBOX_E2B_COST_PER_HOUR'" >&2
        return 1
    fi
    return 0
}

# --- credentials ---------------------------------------------------------------

# setup_e2b_credentials
# Resolves the E2B API key: environment variable first, then the 0600 key
# file. The key value is exported for the helper and never logged.
setup_e2b_credentials() {
    if [[ -n "${E2B_API_KEY:-}" ]]; then
        export E2B_API_KEY
        _e2b_log "INFO" "E2B credentials: E2B_API_KEY via environment"
        return 0
    fi
    if [[ -f "$E2B_API_KEY_FILE" ]]; then
        # GNU stat -c with BSD stat -f fallback (same convention as log_utils.sh)
        local perms
        perms=$(stat -c '%a' "$E2B_API_KEY_FILE" 2>/dev/null || stat -f '%Lp' "$E2B_API_KEY_FILE" 2>/dev/null)
        if [[ -n "$perms" && ! "$perms" =~ 00$ ]]; then
            _e2b_log "WARN" "E2B API key file $E2B_API_KEY_FILE is group/world-accessible (mode $perms) — run: chmod 600 $E2B_API_KEY_FILE"
        fi
        E2B_API_KEY=$(tr -d '[:space:]' < "$E2B_API_KEY_FILE")
        if [[ -z "$E2B_API_KEY" ]]; then
            _e2b_log "ERROR" "E2B API key file $E2B_API_KEY_FILE is empty"
            return 1
        fi
        export E2B_API_KEY
        _e2b_log "INFO" "E2B credentials: API key via $E2B_API_KEY_FILE"
        return 0
    fi
    _e2b_log "ERROR" "E2B API key not found. Set the E2B_API_KEY environment variable or create $E2B_API_KEY_FILE (chmod 600). Get a key at https://e2b.dev/dashboard"
    return 1
}

# _seed_e2b_claude_credentials
# Claude auth handoff into the sandbox, mirroring setup_docker_credentials:
#   1. ANTHROPIC_API_KEY set      → already passed as a sandbox env at create
#                                   time (helper reads it from the environment)
#   2. host ~/.claude credentials → copied into the sandbox home over stdin
#   3. neither                    → warn and continue (the template may have
#                                   its own auth baked in)
_seed_e2b_claude_credentials() {
    local sandbox_id=$1
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        _e2b_log "INFO" "Sandbox credentials: ANTHROPIC_API_KEY via sandbox environment"
        return 0
    fi
    if [[ -f "$HOME/.claude/.credentials.json" ]]; then
        if ! _e2b_helper write-file --sandbox-id "$sandbox_id" \
                --path "/home/user/.claude/.credentials.json" --mode 600 \
                < "$HOME/.claude/.credentials.json" >/dev/null; then
            _e2b_log "ERROR" "Failed to seed claude credentials into the E2B sandbox"
            return 1
        fi
        _e2b_log "INFO" "Sandbox credentials: seeded sandbox claude home from host credentials"
        return 0
    fi
    _e2b_log "WARN" "No credentials found (ANTHROPIC_API_KEY unset, no ~/.claude/.credentials.json). Claude may fail to authenticate in the sandbox."
    return 0
}

# --- initialization -----------------------------------------------------------

# init_e2b_sandbox
# Validates config + transport + credentials and writes the initial sandbox
# state file. Fails hard (return 1) on any problem — the caller must NOT fall
# back to host execution when the user asked for sandboxing.
init_e2b_sandbox() {
    if ! validate_e2b_sandbox_config; then
        return 1
    fi
    if ! e2b_is_available; then
        return 1
    fi
    if ! setup_e2b_credentials; then
        return 1
    fi

    local now tmp
    now=$(get_iso_timestamp)
    tmp=$(mktemp "${E2B_SANDBOX_STATE_FILE}.XXXXXX" 2>/dev/null) || return 1
    if jq -n \
        --arg now "$now" \
        --arg template "$SANDBOX_E2B_TEMPLATE" \
        --arg requested_id "$SANDBOX_E2B_SANDBOX_ID" \
        --arg timeout "$SANDBOX_E2B_TIMEOUT" \
        --arg keep_alive "$SANDBOX_E2B_KEEP_ALIVE" \
        --arg workdir "$SANDBOX_E2B_WORKDIR" \
        '{
            provider: "e2b",
            template: $template,
            requested_sandbox_id: $requested_id,
            timeout: ($timeout | tonumber),
            keep_alive: ($keep_alive == "true"),
            workdir: $workdir,
            sandbox_id: "",
            status: "initialized",
            created_epoch: 0,
            estimated_cost: "0.0000",
            accrued_cost: "0.0000",
            cost_alerted: false,
            created_at: $now,
            updated_at: $now
        }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$E2B_SANDBOX_STATE_FILE" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi

    _e2b_log "INFO" "E2B sandbox initialized (template: $SANDBOX_E2B_TEMPLATE, session timeout: ${SANDBOX_E2B_TIMEOUT}s)"
    return 0
}

# --- sandbox lifecycle ----------------------------------------------------------

# start_e2b_sandbox
# Creates a fresh sandbox (or connects to SANDBOX_E2B_SANDBOX_ID), seeds
# Claude credentials, uploads the project, and verifies the Claude CLI exists
# in the sandbox (bootstrapping it via npm once when missing).
start_e2b_sandbox() {
    local out sandbox_id
    if [[ -n "$SANDBOX_E2B_SANDBOX_ID" ]]; then
        if ! out=$(_e2b_helper connect --sandbox-id "$SANDBOX_E2B_SANDBOX_ID"); then
            _e2b_log "ERROR" "Failed to connect to E2B sandbox '$SANDBOX_E2B_SANDBOX_ID': $(jq -r '.error // "unknown error"' <<<"$out" 2>/dev/null)"
            return 1
        fi
    else
        if ! out=$(_e2b_helper create --template "$SANDBOX_E2B_TEMPLATE" --timeout "$SANDBOX_E2B_TIMEOUT"); then
            _e2b_log "ERROR" "Failed to create E2B sandbox: $(jq -r '.error // "unknown error"' <<<"$out" 2>/dev/null)"
            return 1
        fi
    fi
    sandbox_id=$(jq -r '.sandbox_id // empty' <<<"$out" 2>/dev/null)
    if [[ -z "$sandbox_id" ]]; then
        _e2b_log "ERROR" "E2B helper returned no sandbox id"
        return 1
    fi

    # Fold the previous sandbox's runtime cost into the accrued total BEFORE
    # resetting the epoch, so --sandbox-max-cost spans replacements — a run
    # that keeps expiring/recreating must not restart its budget from zero.
    local prev_epoch
    prev_epoch=$(e2b_state_get '.created_epoch')
    if [[ -n "$prev_epoch" && "$prev_epoch" != "0" ]]; then
        local segment_s accrued
        segment_s=$(( $(get_epoch_seconds) - prev_epoch ))
        (( segment_s < 0 )) && segment_s=0
        accrued=$(e2b_state_get '.accrued_cost')
        accrued=$(awk -v a="${accrued:-0}" -v s="$segment_s" -v r="$SANDBOX_E2B_COST_PER_HOUR" \
            'BEGIN{printf "%.4f", a + s / 3600 * r}')
        _e2b_apply '.accrued_cost = $a' --arg a "$accrued" || true
    fi

    _e2b_apply '.sandbox_id = $sid | .status = "running" | .created_epoch = ($epoch | tonumber)' \
        --arg sid "$sandbox_id" --arg epoch "$(get_epoch_seconds)" || return 1

    if ! _seed_e2b_claude_credentials "$sandbox_id"; then
        return 1
    fi
    if ! upload_project_to_e2b; then
        return 1
    fi
    if ! _ensure_claude_in_e2b "$sandbox_id"; then
        return 1
    fi

    _e2b_log "SUCCESS" "E2B sandbox started: ${sandbox_id:0:16} (template: $SANDBOX_E2B_TEMPLATE)"
    return 0
}

# _ensure_claude_in_e2b <sandbox-id>
# The sandbox has no bind mount to the host CLI, so the template must provide
# `claude` — or we bootstrap it once via npm (the base template ships node).
_ensure_claude_in_e2b() {
    local sandbox_id=$1
    if _e2b_helper exec --sandbox-id "$sandbox_id" --cwd "$SANDBOX_E2B_WORKDIR" -- claude --version >/dev/null 2>&1; then
        return 0
    fi
    _e2b_log "WARN" "Claude CLI not found in the sandbox — attempting: npm install -g @anthropic-ai/claude-code"
    local npm_output
    npm_output=$(_e2b_helper exec --sandbox-id "$sandbox_id" --cwd "$SANDBOX_E2B_WORKDIR" -- npm install -g @anthropic-ai/claude-code 2>&1) || true
    if _e2b_helper exec --sandbox-id "$sandbox_id" --cwd "$SANDBOX_E2B_WORKDIR" -- claude --version >/dev/null 2>&1; then
        return 0
    fi
    # Surface why the bootstrap failed (registry unreachable vs missing npm)
    # so a broken install is distinguishable from a missing-template case.
    [[ -n "$npm_output" ]] && _e2b_log "WARN" "npm bootstrap output: $(tail -3 <<<"$npm_output" | tr '\n' ' ')"
    _e2b_log "ERROR" "Claude Code CLI is unavailable in the E2B sandbox. Build a custom E2B template with it preinstalled and pass it via --sandbox-template (see docs/E2B_SANDBOX.md)"
    return 1
}

# ensure_e2b_sandbox
# Liveness probe + recovery, called before each exec. E2B sandboxes expire at
# their session timeout; a dead sandbox is replaced (fresh create + re-upload)
# rather than burning loops until the circuit breaker opens.
ensure_e2b_sandbox() {
    local sandbox_id
    sandbox_id=$(e2b_state_get '.sandbox_id')
    if [[ -z "$sandbox_id" ]]; then
        _e2b_log "ERROR" "No E2B sandbox recorded (start_e2b_sandbox first)"
        return 1
    fi

    local out state=""
    if out=$(_e2b_helper info --sandbox-id "$sandbox_id" 2>/dev/null); then
        state=$(jq -r '.state // empty' <<<"$out" 2>/dev/null)
    fi
    if [[ "$state" == "running" ]]; then
        return 0
    fi

    _e2b_log "WARN" "E2B sandbox not running (expired or killed) — starting a replacement"
    _e2b_apply '.sandbox_id = "" | .status = "lost"' || true
    # A replacement is always a fresh create: a user-supplied --sandbox-id that
    # died cannot be reconnected.
    SANDBOX_E2B_SANDBOX_ID="" start_e2b_sandbox
}

# build_e2b_exec_args <command> [args...]
# Populates the global SANDBOX_EXEC_ARGS array with the helper-exec wrapping
# of the given command (same convention as the Docker provider). The remote
# command runs in the workspace; its stdout/stderr stream back through the
# helper, and the remote exit code is propagated.
build_e2b_exec_args() {
    local sandbox_id
    sandbox_id=$(e2b_state_get '.sandbox_id')
    if [[ -z "$sandbox_id" ]]; then
        _e2b_log "ERROR" "No running E2B sandbox (start_e2b_sandbox first)"
        return 1
    fi
    SANDBOX_EXEC_ARGS=("$SANDBOX_E2B_PYTHON" "$SANDBOX_E2B_HELPER" exec
        --sandbox-id "$sandbox_id" --cwd "$SANDBOX_E2B_WORKDIR" -- "$@")
    return 0
}

# --- file synchronization --------------------------------------------------------

# _build_e2b_upload_list
# NUL-separated list of project files to upload: tracked + untracked
# non-ignored files (so .git internals, node_modules etc. follow .gitignore),
# plus the .ralph control files Claude needs even when .ralph/ is gitignored.
# The generic lists exclude .ralph/ ENTIRELY — internal state (.e2b_*,
# status.json, counters) must never reach the sandbox, where a write could
# sync back over the host's control state. Only the explicit allowlist below
# re-adds the control files.
_build_e2b_upload_list() {
    local ralph_base="${RALPH_DIR##*/}"
    # Generic list runs through the sync filter (SYNC_INCLUDE/SYNC_EXCLUDE/
    # .ralphignore/large-file policy, Issue #76); the .ralph control-file
    # allowlist below is appended unfiltered — the loop must never be able
    # to starve itself of its own prompt and plan.
    {
        if git rev-parse --git-dir &>/dev/null; then
            git ls-files -coz --exclude-standard -- . ":(exclude)$ralph_base" 2>/dev/null
        else
            find . -type f \
                ! -path './.git/*' ! -path './node_modules/*' \
                ! -path "./$ralph_base/*" -print0 2>/dev/null
        fi
    } | sync_filter_file_list
    # Allowlist entries must be cwd-relative: an absolute RALPH_DIR would
    # otherwise become a wrong member path in the tar (leading / stripped).
    local f rel
    for f in .ralphrc "$RALPH_DIR/PROMPT.md" "$RALPH_DIR/fix_plan.md" "$RALPH_DIR/AGENT.md"; do
        rel="${f#"$PWD"/}"
        [[ -f "$rel" ]] && printf '%s\0' "$rel"
    done
    rel="${RALPH_DIR#"$PWD"/}"
    if [[ -d "$rel/specs" ]]; then
        find "$rel/specs" -type f -print0 2>/dev/null
    fi
}

# upload_project_to_e2b
# Tars the project file list and streams it to the sandbox workspace.
upload_project_to_e2b() {
    local sandbox_id
    sandbox_id=$(e2b_state_get '.sandbox_id')
    if [[ -z "$sandbox_id" ]]; then
        _e2b_log "ERROR" "No E2B sandbox to upload to"
        return 1
    fi

    local tarball
    tarball=$(mktemp "${TMPDIR:-/tmp}/ralph-e2b-upload.XXXXXX") || return 1
    if ! _build_e2b_upload_list | tar -czf "$tarball" --null -T - 2>/dev/null; then
        _e2b_log "ERROR" "Failed to build project tarball for E2B upload"
        rm -f "$tarball"
        return 1
    fi

    local file_count tar_size
    # grep -c exits 1 on zero matches (everything filtered) — never let that
    # abort an errexit caller
    file_count=$(tar -tzf "$tarball" 2>/dev/null | grep -cv '/$' || true)
    tar_size=$(_sync_file_size "$tarball")
    _e2b_log "INFO" "Uploading $file_count file(s) ($(format_sync_size "$tar_size") compressed) to E2B sandbox..."
    if ! _e2b_helper upload --sandbox-id "$sandbox_id" --dest "$SANDBOX_E2B_WORKDIR" < "$tarball" >/dev/null; then
        _e2b_log "ERROR" "Failed to upload project to E2B sandbox"
        rm -f "$tarball"
        return 1
    fi
    # Deletion-sync baseline: what the sandbox workspace now contains
    # (atomic temp+mv — a torn baseline would corrupt deletion propagation)
    local baseline_tmp
    if baseline_tmp=$(mktemp "${E2B_SYNCED_FILES_FILE}.XXXXXX" 2>/dev/null); then
        tar -tzf "$tarball" 2>/dev/null | grep -v '/$' | sed 's|^\./||' > "$baseline_tmp" \
            && mv "$baseline_tmp" "$E2B_SYNCED_FILES_FILE" || rm -f "$baseline_tmp"
    fi
    rm -f "$tarball"
    _e2b_log "INFO" "Uploaded $file_count file(s) to E2B workspace $SANDBOX_E2B_WORKDIR"
    return 0
}

# _apply_e2b_deletions <manifest-content>
# Deletes host files that were previously synced with the sandbox but are
# absent from the sandbox's current manifest (sandbox-side rm / rename).
# Only paths recorded in E2B_SYNCED_FILES_FILE are candidates — host-only
# files are untouchable — and .git/.ralph paths are refused outright even if
# the state file is corrupted or poisoned.
_apply_e2b_deletions() {
    local manifest=$1
    [[ -f "$E2B_SYNCED_FILES_FILE" ]] || return 0
    # comm needs both sides sorted; this keeps the pass O(n log n) instead of
    # a per-line grep subshell over the whole manifest (O(n^2))
    local candidates
    candidates=$(comm -23 <(sort -u "$E2B_SYNCED_FILES_FILE") <(sort -u <<<"$manifest"))
    [[ -z "$candidates" ]] && return 0
    # Paths the sync filter would never sync are never deletion candidates:
    # a host file matching SYNC_EXCLUDE/.ralphignore must survive even if a
    # stale baseline entry says it once synced (Issue #76). Control files
    # stay candidates — what syncs may also be deletion-synced.
    candidates=$(printf '%s\n' "$candidates" | _e2b_filter_download_members)
    [[ -z "$candidates" ]] && return 0
    local deleted=0 old
    while IFS= read -r old; do
        [[ -z "$old" ]] && continue
        case "$old" in
            /*|*..*|.git|.git/*|*/.git/*|.ralph|.ralph/*) continue ;;
        esac
        if [[ -f "$old" ]]; then
            rm -f "$old" && deleted=$((deleted + 1))
        fi
    done <<<"$candidates"
    if (( deleted > 0 )); then
        _e2b_log "INFO" "Removed $deleted file(s) deleted in the E2B sandbox"
    fi
    return 0
}

# _e2b_member_hard_excluded <member>
# rc 0 for archive members that must NEVER reach the host regardless of user
# sync patterns: the manifest member, .git paths, and host-owned .ralph state
# (mirrors the tar --exclude list in sync_e2b_artifacts_down).
_e2b_member_hard_excluded() {
    local m="${1#./}"
    # Same control-dir derivation as _build_e2b_upload_list — honors a
    # non-default RALPH_DIR (absolute or relative)
    local rb="${RALPH_DIR##*/}"
    case "$m" in
        "$E2B_SYNC_MANIFEST_NAME") return 0 ;;
        .git|.git/*|*/.git|*/.git/*) return 0 ;;
        "$rb"/.*) return 0 ;;
        "$rb"/status.json|"$rb"/progress.json|"$rb"/live.log) return 0 ;;
        "$rb"/logs|"$rb"/logs/*) return 0 ;;
    esac
    return 1
}

# _e2b_member_control_file <member>
# rc 0 for the .ralph control files (mirror of the upload allowlist): user
# sync patterns never filter these on download — a broad pattern like *.md
# must not silently drop Claude's plan/prompt updates.
_e2b_member_control_file() {
    local rb="${RALPH_DIR##*/}"
    # .ralphrc lives at the project root, not under RALPH_DIR
    case "${1#./}" in
        .ralphrc|"$rb"/PROMPT.md|"$rb"/fix_plan.md|"$rb"/AGENT.md|"$rb"/specs/*) return 0 ;;
    esac
    return 1
}

# _e2b_filter_download_members
# stdin: newline member paths; stdout: members that survive the user's sync
# patterns, with .ralph control files force-included past them (deduped).
_e2b_filter_download_members() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-e2b-members.XXXXXX") || return 1
    cat > "$tmp"
    {
        sync_filter_download_list < "$tmp"
        local m
        while IFS= read -r m; do
            [[ -n "$m" ]] && _e2b_member_control_file "$m" && printf '%s\n' "$m"
        done < "$tmp"
    } | awk '!seen[$0]++'
    rm -f "$tmp"
    return 0
}

# sync_e2b_artifacts_down
# Downloads files changed in the sandbox since the last sync and extracts them
# into the host project. Tar's default protections reject absolute paths and
# '..' members; .git and .ralph/logs are excluded so sandbox-side git state
# can never clobber the host repository.
sync_e2b_artifacts_down() {
    local sandbox_id=""
    if [[ -f "$E2B_SANDBOX_STATE_FILE" ]]; then
        sandbox_id=$(e2b_state_get '.sandbox_id')
    fi
    [[ -z "$sandbox_id" ]] && return 0

    local tarball
    tarball=$(mktemp "${TMPDIR:-/tmp}/ralph-e2b-download.XXXXXX") || return 1
    if ! _e2b_helper download --sandbox-id "$sandbox_id" --src "$SANDBOX_E2B_WORKDIR" > "$tarball" 2>/dev/null; then
        _e2b_log "WARN" "Failed to download artifacts from E2B sandbox"
        rm -f "$tarball"
        return 1
    fi
    if [[ ! -s "$tarball" ]]; then
        rm -f "$tarball"
        return 0
    fi
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        _e2b_log "WARN" "E2B download is not a valid archive — skipping sync"
        rm -f "$tarball"
        return 1
    fi

    # The manifest member lists ALL current sandbox files — read it out (it is
    # never extracted into the project) and use it to propagate deletions.
    local manifest=""
    manifest=$(tar -xzOf "$tarball" "$E2B_SYNC_MANIFEST_NAME" 2>/dev/null | sed 's|^\./||') || manifest=""

    # Member selection: hard exclusions (host-owned state, .git) first, then
    # the user's sync patterns (SYNC_EXCLUDE/.ralphignore, Issue #76) with
    # .ralph control files exempt. The surviving names are extracted
    # explicitly via -T; the tar --exclude flags below stay as defense in
    # depth. Accumulate in a temp file — bash += in a loop is O(n^2).
    local member kept_file file_count filtered_count
    if ! kept_file=$(mktemp "${TMPDIR:-/tmp}/ralph-e2b-kept.XXXXXX"); then
        rm -f "$tarball"
        return 1
    fi
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        _e2b_member_hard_excluded "$member" && continue
        printf '%s\n' "$member" >> "$kept_file"
    done < <(tar -tzf "$tarball" 2>/dev/null | grep -v '/$')
    local selected kept_count
    selected=$(_e2b_filter_download_members < "$kept_file")
    # grep -c exits 1 on zero matches — never let that abort an errexit caller
    file_count=$(printf '%s' "$selected" | grep -c . || true)
    kept_count=$(grep -c . "$kept_file" || true)
    rm -f "$kept_file"
    filtered_count=$(( kept_count - file_count ))

    if [[ "$file_count" -gt 0 ]]; then
        # .ralph control files (fix_plan.md, PROMPT.md, specs/) sync back —
        # Claude updates them — but state dotfiles, status.json, progress.json,
        # live.log and logs/ are host-owned and must never be overwritten.
        local list_file
        if ! list_file=$(mktemp "${TMPDIR:-/tmp}/ralph-e2b-extract.XXXXXX"); then
            rm -f "$tarball"
            return 1
        fi
        printf '%s' "$selected" > "$list_file"
        local rb="${RALPH_DIR##*/}"
        if ! tar -xzf "$tarball" -C . -T "$list_file" \
            --exclude="$E2B_SYNC_MANIFEST_NAME" \
            --exclude='.git' --exclude='.git/*' --exclude='*/.git' --exclude='*/.git/*' \
            --exclude="$rb/.*" --exclude="$rb/status.json" \
            --exclude="$rb/progress.json" --exclude="$rb/live.log" \
            --exclude="$rb/logs" --exclude="$rb/logs/*" 2>/dev/null; then
            _e2b_log "WARN" "Failed to extract some synced files from the E2B sandbox"
            rm -f "$tarball" "$list_file"
            return 1
        fi
        rm -f "$list_file"
        local tar_size
        tar_size=$(_sync_file_size "$tarball")
        _e2b_log "INFO" "Synced $file_count changed file(s) ($(format_sync_size "$tar_size")) from the E2B sandbox"
    fi
    if [[ "$filtered_count" -gt 0 ]]; then
        _e2b_log "INFO" "Filtered $filtered_count file(s) from sandbox download (SYNC_EXCLUDE / .ralphignore patterns)"
    fi
    rm -f "$tarball"

    # Deletion sync: archives without a manifest (older helper, empty download)
    # skip this pass — content sync alone, never speculative deletion.
    # Deliberately gated on the manifest, NOT on file_count: a deletion-only
    # iteration carries a manifest but zero changed files and must still run.
    if [[ -n "$manifest" ]]; then
        _apply_e2b_deletions "$manifest"
        # Baseline = what is actually synced to the host: members the download
        # filter excludes are dropped so a same-named host file can never
        # become a deletion candidate once the sandbox removes its copy
        # (Issue #76)
        local manifest_synced manifest_tmp
        manifest_synced=$(printf '%s\n' "$manifest" | _e2b_filter_download_members)
        if manifest_tmp=$(mktemp "${E2B_SYNCED_FILES_FILE}.XXXXXX" 2>/dev/null); then
            printf '%s\n' "$manifest_synced" > "$manifest_tmp" \
                && mv "$manifest_tmp" "$E2B_SYNCED_FILES_FILE" || rm -f "$manifest_tmp"
        fi
    fi

    # Everything landed on the host — advance the sandbox-side sync marker.
    # An ack failure is non-fatal: the next download simply re-delivers the
    # same changes and re-extraction is an idempotent overwrite.
    _e2b_helper ack-download --sandbox-id "$sandbox_id" --src "$SANDBOX_E2B_WORKDIR" >/dev/null 2>&1 || \
        _e2b_log "WARN" "Failed to ack E2B download (changes will be re-synced next iteration)"
    return 0
}

# --- cost tracking ----------------------------------------------------------------

# update_e2b_cost
# Recomputes the estimated cost — cost accrued by previous (replaced)
# sandboxes plus the active sandbox's elapsed runtime x hourly rate —
# persists it in the state file, and prints it.
update_e2b_cost() {
    local accrued created
    accrued=$(e2b_state_get '.accrued_cost')
    accrued=${accrued:-0}
    created=$(e2b_state_get '.created_epoch')
    if [[ -z "$created" || "$created" == "0" ]]; then
        # No active sandbox: the estimate is the accrued total alone — still
        # persisted so status.json/monitor never show 0 while accrued > 0
        local idle_cost
        idle_cost=$(awk -v a="$accrued" 'BEGIN{printf "%.4f", a + 0}')
        _e2b_apply '.estimated_cost = $c' --arg c "$idle_cost" || true
        echo "$idle_cost"
        return 0
    fi
    local now elapsed cost
    now=$(get_epoch_seconds)
    elapsed=$((now - created))
    (( elapsed < 0 )) && elapsed=0
    cost=$(awk -v a="$accrued" -v s="$elapsed" -v r="$SANDBOX_E2B_COST_PER_HOUR" \
        'BEGIN{printf "%.4f", a + s / 3600 * r}')
    _e2b_apply '.estimated_cost = $c' --arg c "$cost" || true
    echo "$cost"
}

# check_e2b_cost_limits
# Returns 1 once the estimated cost reaches --sandbox-max-cost (the loop must
# stop gracefully); warns once at --sandbox-cost-alert. No-op for other
# providers or before init.
check_e2b_cost_limits() {
    [[ "$SANDBOX_PROVIDER" == "e2b" ]] || return 0
    [[ -f "$E2B_SANDBOX_STATE_FILE" ]] || return 0
    local cost
    cost=$(update_e2b_cost)

    if [[ -n "$SANDBOX_E2B_MAX_COST" ]] && \
       awk -v c="$cost" -v m="$SANDBOX_E2B_MAX_COST" 'BEGIN{exit !(c >= m)}'; then
        _e2b_log "ERROR" "E2B cost limit reached: estimated \$$cost >= max \$$SANDBOX_E2B_MAX_COST"
        return 1
    fi
    if [[ -n "$SANDBOX_E2B_COST_ALERT" ]] && \
       [[ "$(e2b_state_get '.cost_alerted')" != "true" ]] && \
       awk -v c="$cost" -v a="$SANDBOX_E2B_COST_ALERT" 'BEGIN{exit !(c >= a)}'; then
        _e2b_log "WARN" "E2B cost alert: estimated \$$cost has reached the \$$SANDBOX_E2B_COST_ALERT threshold"
        _e2b_apply '.cost_alerted = true' || true
    fi
    return 0
}

# --- timeout and cleanup -------------------------------------------------------

# handle_e2b_sandbox_timeout
# A host-side timeout (exit 124) kills the local helper client but NOT the
# command inside the cloud sandbox. Kill orphaned claude processes remotely
# so the next iteration starts clean. No-op when no sandbox is recorded.
handle_e2b_sandbox_timeout() {
    local sandbox_id=""
    if [[ -f "$E2B_SANDBOX_STATE_FILE" ]]; then
        sandbox_id=$(e2b_state_get '.sandbox_id')
    fi
    [[ -z "$sandbox_id" ]] && return 0
    _e2b_log "WARN" "Sandbox timeout: killing orphaned claude processes in the E2B sandbox"
    _e2b_helper exec --sandbox-id "$sandbox_id" --cwd "$SANDBOX_E2B_WORKDIR" -- pkill -f claude >/dev/null 2>&1 || true
    return 0
}

# cleanup_e2b_sandbox
# Full teardown: final artifact sync, sandbox kill (unless keep-alive), and a
# cost summary appended to $LOG_DIR/e2b_cost.log. Idempotent and safe to call
# from traps, before init, or repeatedly — it always returns 0 so cleanup
# paths never mask the real exit status.
cleanup_e2b_sandbox() {
    local sandbox_id=""
    if [[ -f "$E2B_SANDBOX_STATE_FILE" ]]; then
        sandbox_id=$(e2b_state_get '.sandbox_id')
    fi
    [[ -z "$sandbox_id" ]] && return 0

    sync_e2b_artifacts_down || true
    local cost created runtime=0
    cost=$(update_e2b_cost)
    created=$(e2b_state_get '.created_epoch')
    if [[ -n "$created" && "$created" != "0" ]]; then
        runtime=$(( $(get_epoch_seconds) - created ))
        (( runtime < 0 )) && runtime=0
    fi

    if [[ "$SANDBOX_E2B_KEEP_ALIVE" == "true" ]]; then
        _e2b_apply '.status = "kept_alive"' || true
        _e2b_log "INFO" "E2B sandbox kept alive: $sandbox_id (estimated cost so far: \$$cost). Reuse it with --sandbox-id $sandbox_id or kill it from the E2B dashboard."
    else
        _e2b_helper kill --sandbox-id "$sandbox_id" >/dev/null 2>&1 || \
            _e2b_log "WARN" "Failed to kill E2B sandbox ${sandbox_id:0:16} (it will expire at its session timeout)"
        _e2b_apply '.sandbox_id = "" | .status = "cleaned"' || true
        _e2b_log "INFO" "E2B sandbox killed (runtime: ${runtime}s, estimated cost: \$$cost)"
    fi

    if [[ -d "$LOG_DIR" ]]; then
        echo "$(get_iso_timestamp) | sandbox: $sandbox_id | runtime: ${runtime}s | estimated_cost: \$$cost" >> "$LOG_DIR/e2b_cost.log" 2>/dev/null
    fi
    return 0
}

# --- status -----------------------------------------------------------------

# get_e2b_sandbox_status
# Emits a JSON object for embedding in status.json:
#   {"provider": "e2b", "sandbox_id": "...", "status": "running", "estimated_cost": "0.0123"}
# Prints {"provider": "none"} when the sandbox was never initialized.
get_e2b_sandbox_status() {
    if [[ ! -f "$E2B_SANDBOX_STATE_FILE" ]]; then
        echo '{"provider": "none"}'
        return 0
    fi
    jq -c '{provider, sandbox_id, status, estimated_cost}' "$E2B_SANDBOX_STATE_FILE" 2>/dev/null \
        || echo '{"provider": "none"}'
    return 0
}

# Export public functions for use by ralph_loop.sh
export -f e2b_is_available
export -f validate_e2b_sandbox_config
export -f setup_e2b_credentials
export -f init_e2b_sandbox
export -f start_e2b_sandbox
export -f ensure_e2b_sandbox
export -f build_e2b_exec_args
export -f upload_project_to_e2b
export -f sync_e2b_artifacts_down
export -f update_e2b_cost
export -f check_e2b_cost_limits
export -f handle_e2b_sandbox_timeout
export -f cleanup_e2b_sandbox
export -f get_e2b_sandbox_status
export -f e2b_state_get
