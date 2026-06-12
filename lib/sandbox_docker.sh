#!/bin/bash
# Docker Sandbox Execution for Ralph (Issue #74)
#
# Runs the Claude Code CLI inside a local Docker container instead of directly
# on the host. Ralph's orchestration (loop control, rate limiting, circuit
# breaker, response analysis, status.json) stays on the host; only the Claude
# execution — the part that edits files and runs commands autonomously — is
# containerized. The project directory is bind-mounted read-write at
# /workspace, so file changes land on the host directly and ralph-monitor
# keeps working unchanged.
#
# Design notes:
#   - A single persistent container is started before the loop and reused by
#     every iteration via `docker exec` (no per-loop startup cost; Claude's
#     in-container session state survives across iterations).
#   - State lives in $RALPH_DIR/.docker_sandbox_state (JSON), mutated through
#     a temp file + mv so a crashed jq never leaves half-written state — the
#     same convention as lib/github_lifecycle.sh / lib/queue_manager.sh.
#   - Credentials: ANTHROPIC_API_KEY is handed off via a 0600 env-file passed
#     to `docker run --env-file` (visible only at container-create time, never
#     logged). Without an API key, the host's ~/.claude/.credentials.json is
#     COPIED into a container-scoped claude home so the container never writes
#     to the host's real ~/.claude. (`docker secret` is NOT used — it requires
#     Swarm mode and does not work with plain `docker run`.)
#   - A host-side timeout (exit 124) kills only the `docker exec` client; the
#     process inside the container keeps running. handle_sandbox_timeout
#     restarts the container to reap orphaned processes.

# Source date utilities for cross-platform ISO timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"
DOCKER_SANDBOX_STATE_FILE="${DOCKER_SANDBOX_STATE_FILE:-$RALPH_DIR/.docker_sandbox_state}"
# Credential artifacts must live OUTSIDE the project directory: the project is
# bind-mounted read-write into the container, so anything under it would be
# readable by the sandboxed process as workspace files and could be swept into
# a commit. Only the (secret-free) state file stays in $RALPH_DIR.
SANDBOX_RUNTIME_DIR="${SANDBOX_RUNTIME_DIR:-${TMPDIR:-/tmp}/ralph-sandbox-$$}"
SANDBOX_ENV_FILE="${SANDBOX_ENV_FILE:-$SANDBOX_RUNTIME_DIR/env}"
SANDBOX_CLAUDE_HOME="${SANDBOX_CLAUDE_HOME:-$SANDBOX_RUNTIME_DIR/claude_home}"

# Sandbox configuration defaults (overridable via .ralphrc, env, or CLI flags)
SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-}"
SANDBOX_DOCKER_IMAGE="${SANDBOX_DOCKER_IMAGE:-ralph-sandbox:latest}"
SANDBOX_DOCKER_MEMORY="${SANDBOX_DOCKER_MEMORY:-4g}"
SANDBOX_DOCKER_CPUS="${SANDBOX_DOCKER_CPUS:-2}"
SANDBOX_DOCKER_NETWORK="${SANDBOX_DOCKER_NETWORK:-bridge}"

# Default image name, used to tailor the "image missing" guidance
SANDBOX_DEFAULT_IMAGE="ralph-sandbox:latest"

# --- logging ----------------------------------------------------------------

# _sandbox_log <level> <message>
# Prefer the main script's log_status() when available; otherwise fall back to
# stderr so the lib is usable (and testable) standalone.
_sandbox_log() {
    local level="$1"
    local message="$2"
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "$message" >&2
    else
        echo "[$level] $message" >&2
    fi
}

# --- state primitives -------------------------------------------------------

# _sandbox_apply <jq-program> [jq args...]
# Atomically mutate the sandbox state file with a jq program (temp file + mv).
# Always refreshes .updated_at. Returns 1 if the state file is missing or jq
# fails (leaving the original state untouched).
_sandbox_apply() {
    local program=$1
    shift
    [[ -f "$DOCKER_SANDBOX_STATE_FILE" ]] || return 1
    local now tmp
    now=$(get_iso_timestamp)
    tmp=$(mktemp "${DOCKER_SANDBOX_STATE_FILE}.XXXXXX" 2>/dev/null) || return 1
    if jq --arg now "$now" "$@" "($program) | .updated_at = \$now" \
        "$DOCKER_SANDBOX_STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DOCKER_SANDBOX_STATE_FILE" || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# sandbox_state_get <jq-path>
# Print a value from the sandbox state file ("" if missing/null).
sandbox_state_get() {
    local path=$1
    [[ -f "$DOCKER_SANDBOX_STATE_FILE" ]] || return 1
    jq -r "$path // empty" "$DOCKER_SANDBOX_STATE_FILE" 2>/dev/null
}

# --- availability and validation ---------------------------------------------

# docker_is_available
# Returns 0 when the docker CLI exists AND the daemon responds.
docker_is_available() {
    if ! command -v docker &>/dev/null; then
        _sandbox_log "ERROR" "Docker CLI not found. Install Docker: https://docs.docker.com/get-docker/"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        _sandbox_log "ERROR" "Docker daemon is not reachable. Is the Docker service running?"
        return 1
    fi
    return 0
}

# validate_sandbox_config
# Validates the SANDBOX_* configuration values. Prints the offending setting
# on failure so CLI users get an actionable message.
validate_sandbox_config() {
    if [[ "$SANDBOX_PROVIDER" != "docker" ]]; then
        echo "Error: unsupported sandbox provider '$SANDBOX_PROVIDER' (supported: docker)" >&2
        return 1
    fi
    # Image references allow [registry/]name[:tag][@digest] characters only —
    # this also blocks shell metacharacters from reaching the docker command.
    if [[ -z "$SANDBOX_DOCKER_IMAGE" || ! "$SANDBOX_DOCKER_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]; then
        echo "Error: invalid sandbox image '$SANDBOX_DOCKER_IMAGE'" >&2
        return 1
    fi
    # Docker memory format: integer with optional b/k/m/g suffix
    if [[ ! "$SANDBOX_DOCKER_MEMORY" =~ ^[0-9]+[bkmgBKMG]?$ ]]; then
        echo "Error: invalid sandbox memory limit '$SANDBOX_DOCKER_MEMORY' (expected e.g. 4g, 512m)" >&2
        return 1
    fi
    # Docker --cpus accepts decimal values (e.g. 1.5)
    if [[ ! "$SANDBOX_DOCKER_CPUS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: invalid sandbox cpus limit '$SANDBOX_DOCKER_CPUS' (expected e.g. 2 or 1.5)" >&2
        return 1
    fi
    case "$SANDBOX_DOCKER_NETWORK" in
        none|bridge|host) ;;
        *)
            echo "Error: invalid sandbox network mode '$SANDBOX_DOCKER_NETWORK' (expected: none, bridge, or host)" >&2
            return 1
            ;;
    esac
    return 0
}

# --- initialization -----------------------------------------------------------

# init_docker_sandbox
# Validates config + environment and writes the initial sandbox state file.
# Fails hard (return 1) on any problem — the caller must NOT fall back to
# host execution when the user asked for sandboxing.
init_docker_sandbox() {
    if ! validate_sandbox_config; then
        return 1
    fi
    if ! docker_is_available; then
        return 1
    fi

    # The image must exist locally before the loop starts burning API calls
    if ! docker image inspect "$SANDBOX_DOCKER_IMAGE" >/dev/null 2>&1; then
        if [[ "$SANDBOX_DOCKER_IMAGE" == "$SANDBOX_DEFAULT_IMAGE" ]]; then
            _sandbox_log "ERROR" "Sandbox image '$SANDBOX_DOCKER_IMAGE' not found."
            echo "Pull the official image (published on release tags, Issue #298):" >&2
            echo "  docker pull ghcr.io/frankbria/ralph-sandbox:latest" >&2
            echo "  docker tag ghcr.io/frankbria/ralph-sandbox:latest ralph-sandbox:latest" >&2
            echo "Or build it locally:" >&2
            echo "  docker build -t ralph-sandbox \"\${RALPH_HOME:-\$HOME/.ralph}\"" >&2
            echo "(or from a Ralph source checkout: docker build -t ralph-sandbox .)" >&2
        else
            _sandbox_log "ERROR" "Sandbox image '$SANDBOX_DOCKER_IMAGE' not found."
            echo "Pull or build it first, e.g.: docker pull $SANDBOX_DOCKER_IMAGE" >&2
        fi
        return 1
    fi

    local now tmp
    now=$(get_iso_timestamp)
    tmp=$(mktemp "${DOCKER_SANDBOX_STATE_FILE}.XXXXXX" 2>/dev/null) || return 1
    if jq -n \
        --arg now "$now" \
        --arg image "$SANDBOX_DOCKER_IMAGE" \
        --arg memory "$SANDBOX_DOCKER_MEMORY" \
        --arg cpus "$SANDBOX_DOCKER_CPUS" \
        --arg network "$SANDBOX_DOCKER_NETWORK" \
        '{
            provider: "docker",
            image: $image,
            memory: $memory,
            cpus: $cpus,
            network: $network,
            container_id: "",
            status: "initialized",
            created_at: $now,
            updated_at: $now
        }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DOCKER_SANDBOX_STATE_FILE" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi

    _sandbox_log "INFO" "Docker sandbox initialized (image: $SANDBOX_DOCKER_IMAGE, network: $SANDBOX_DOCKER_NETWORK)"
    return 0
}

# --- credentials ---------------------------------------------------------------

# setup_docker_credentials
# Prepares the container-scoped home directory (always mounted as the
# container's HOME — the container runs as the host uid, which usually has no
# passwd entry in the image, so it needs a writable home regardless of
# credential mode) and the credential handoff:
#   1. ANTHROPIC_API_KEY set       → 0600 env-file passed via --env-file
#   2. host ~/.claude credentials  → copied into the container-scoped home
#                                    (the host's real ~/.claude is never mounted)
#   3. neither                     → warn and continue (the image may have its
#                                    own auth baked in)
# The host ~/.gitconfig is also seeded (when present) so autonomous commits
# inside the container have an identity. The API key value is never logged.
setup_docker_credentials() {
    mkdir -p "$SANDBOX_RUNTIME_DIR" || return 1
    chmod 700 "$SANDBOX_RUNTIME_DIR"
    rm -rf "$SANDBOX_CLAUDE_HOME"
    mkdir -p "$SANDBOX_CLAUDE_HOME/.claude" || return 1
    chmod 700 "$SANDBOX_CLAUDE_HOME" "$SANDBOX_CLAUDE_HOME/.claude"
    if [[ -f "$HOME/.gitconfig" ]]; then
        cp "$HOME/.gitconfig" "$SANDBOX_CLAUDE_HOME/.gitconfig" 2>/dev/null || true
    fi

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        rm -f "$SANDBOX_ENV_FILE"
        # Create with restrictive permissions BEFORE writing the secret
        ( umask 177 && printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$SANDBOX_ENV_FILE" ) || {
            _sandbox_log "ERROR" "Failed to write sandbox env-file"
            return 1
        }
        _sandbox_log "INFO" "Sandbox credentials: ANTHROPIC_API_KEY via env-file"
        return 0
    fi

    if [[ -f "$HOME/.claude/.credentials.json" ]]; then
        cp "$HOME/.claude/.credentials.json" "$SANDBOX_CLAUDE_HOME/.claude/.credentials.json" || return 1
        chmod 600 "$SANDBOX_CLAUDE_HOME/.claude/.credentials.json"
        _sandbox_log "INFO" "Sandbox credentials: seeded container claude home from host credentials"
        return 0
    fi

    _sandbox_log "WARN" "No credentials found (ANTHROPIC_API_KEY unset, no ~/.claude/.credentials.json). Claude may fail to authenticate in the sandbox."
    return 0
}

# --- container lifecycle --------------------------------------------------------

# start_sandbox_container
# Starts the persistent sandbox container: project dir bind-mounted read-write
# at /workspace, resource limits and network mode applied, kept alive with
# `sleep infinity` so iterations can `docker exec` into it. Records the
# container id in the state file.
start_sandbox_container() {
    local project_dir
    project_dir="$(pwd)"
    local name="ralph-sandbox-$$-$(date +%s)"

    # Run as the HOST uid:gid — otherwise files the container writes into the
    # bind-mounted /workspace are owned by the image's user (uid 1000), and a
    # host uid ≠ 1000 cannot read the 0600 seeded credentials. The host uid has
    # no passwd entry in most images, hence the explicit HOME mount below.
    local -a run_args=(run -d --init --name "$name"
        --user "$(id -u):$(id -g)"
        -v "$project_dir:/workspace"
        -w /workspace
        --memory "$SANDBOX_DOCKER_MEMORY"
        --cpus "$SANDBOX_DOCKER_CPUS"
        --network "$SANDBOX_DOCKER_NETWORK")

    if [[ -f "$SANDBOX_ENV_FILE" ]]; then
        run_args+=(--env-file "$SANDBOX_ENV_FILE")
    fi
    if [[ -d "$SANDBOX_CLAUDE_HOME" ]]; then
        # Writable container HOME (credentials, claude session state, gitconfig)
        run_args+=(-v "$SANDBOX_CLAUDE_HOME:/ralph-home" -e HOME=/ralph-home)
    fi

    run_args+=("$SANDBOX_DOCKER_IMAGE" sleep infinity)

    # Capture stderr separately: a successful `docker run -d` can still emit
    # warnings (e.g. "kernel does not support swap limit capabilities"), and
    # merging them into stdout would corrupt the recorded container id.
    # (mkdir: start can be called without setup_docker_credentials — tests do)
    mkdir -p "$SANDBOX_RUNTIME_DIR" && chmod 700 "$SANDBOX_RUNTIME_DIR"
    local container_id run_stderr
    run_stderr=$(mktemp "$SANDBOX_RUNTIME_DIR/docker-run-stderr.XXXXXX") || return 1
    if ! container_id=$(docker "${run_args[@]}" 2>"$run_stderr"); then
        _sandbox_log "ERROR" "Failed to start sandbox container: $(cat "$run_stderr" 2>/dev/null)"
        rm -f "$run_stderr"
        return 1
    fi
    if [[ -s "$run_stderr" ]]; then
        _sandbox_log "WARN" "docker run warning: $(head -1 "$run_stderr")"
    fi
    rm -f "$run_stderr"
    # The id is the last stdout line (defensive against future docker chatter)
    container_id=$(printf '%s\n' "$container_id" | tail -1)
    if [[ -z "$container_id" ]]; then
        _sandbox_log "ERROR" "docker run returned no container id"
        return 1
    fi

    _sandbox_apply '.container_id = $cid | .status = "running" | .name = $name' \
        --arg cid "$container_id" --arg name "$name" || return 1
    _sandbox_log "SUCCESS" "Sandbox container started: ${container_id:0:12} (image: $SANDBOX_DOCKER_IMAGE)"
    return 0
}

# ensure_sandbox_container
# Liveness probe + recovery, called before each exec. A container can die
# between iterations (OOM kill under --memory, daemon restart, manual rm):
#   running        → no-op
#   stopped        → docker start (state and exec env are preserved)
#   gone entirely  → start a fresh container (state file gets the new id)
# Returns 1 only when no container was ever started or recovery failed.
ensure_sandbox_container() {
    local container_id
    container_id=$(sandbox_state_get '.container_id')
    if [[ -z "$container_id" ]]; then
        _sandbox_log "ERROR" "No sandbox container recorded (start_sandbox_container first)"
        return 1
    fi

    # `|| running=""` keeps the probe safe under errexit callers — a missing
    # container makes docker inspect exit 1, which must mean "recover", not "abort"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null) || running=""
    if [[ "$running" == "true" ]]; then
        return 0
    fi

    _sandbox_log "WARN" "Sandbox container not running (possible OOM kill or daemon restart) — attempting recovery"
    if docker start "$container_id" >/dev/null 2>&1; then
        _sandbox_log "INFO" "Sandbox container restarted: ${container_id:0:12}"
        return 0
    fi

    _sandbox_log "WARN" "Sandbox container is gone — starting a replacement"
    _sandbox_apply '.container_id = "" | .status = "lost"' || true
    start_sandbox_container
}

# build_sandbox_exec_args <command> [args...]
# Populates the global SANDBOX_EXEC_ARGS array with the docker exec wrapping of
# the given command (same global-array convention as CLAUDE_CMD_ARGS).
# Environment from `docker run` (--env-file, HOME) is part of the container
# config and is inherited by exec'd processes; host-only env vars are NOT
# forwarded — anything the in-container CLI needs must arrive via argv, the
# env-file, or the image itself.
build_sandbox_exec_args() {
    local container_id
    container_id=$(sandbox_state_get '.container_id')
    if [[ -z "$container_id" ]]; then
        _sandbox_log "ERROR" "No running sandbox container (start_sandbox_container first)"
        return 1
    fi
    SANDBOX_EXEC_ARGS=(docker exec -i -w /workspace "$container_id" "$@")
    return 0
}

# handle_sandbox_timeout
# A host-side timeout kills the `docker exec` client but NOT the process inside
# the container. Restart the container to reap orphaned processes so the next
# iteration starts clean. No-op when no container is recorded.
handle_sandbox_timeout() {
    local container_id
    container_id=$(sandbox_state_get '.container_id')
    [[ -z "$container_id" ]] && return 0
    _sandbox_log "WARN" "Sandbox timeout: restarting container to reap orphaned processes"
    if ! docker restart -t 5 "$container_id" >/dev/null 2>&1; then
        _sandbox_log "WARN" "Failed to restart sandbox container ${container_id:0:12}"
    fi
    return 0
}

# stop_sandbox_container
# Gracefully stop and remove the sandbox container, clearing it from state.
stop_sandbox_container() {
    local container_id
    container_id=$(sandbox_state_get '.container_id')
    [[ -z "$container_id" ]] && return 0
    docker stop -t 10 "$container_id" >/dev/null 2>&1 || \
        _sandbox_log "WARN" "Failed to stop sandbox container ${container_id:0:12}"
    docker rm -f "$container_id" >/dev/null 2>&1 || \
        _sandbox_log "WARN" "Failed to remove sandbox container ${container_id:0:12}"
    _sandbox_apply '.container_id = "" | .status = "stopped"' || true
    _sandbox_log "INFO" "Sandbox container stopped"
    return 0
}

# cleanup_docker_sandbox
# Full teardown: container, credential env-file, and seeded claude home.
# Idempotent and safe to call from traps, before init, or repeatedly — it
# always returns 0 so cleanup paths never mask the real exit status.
cleanup_docker_sandbox() {
    local container_id=""
    if [[ -f "$DOCKER_SANDBOX_STATE_FILE" ]]; then
        container_id=$(sandbox_state_get '.container_id')
    fi
    if [[ -n "$container_id" ]]; then
        docker stop -t 10 "$container_id" >/dev/null 2>&1 || true
        docker rm -f "$container_id" >/dev/null 2>&1 || true
    fi
    rm -f "$SANDBOX_ENV_FILE" 2>/dev/null
    rm -rf "$SANDBOX_CLAUDE_HOME" 2>/dev/null
    rmdir "$SANDBOX_RUNTIME_DIR" 2>/dev/null || true
    if [[ -f "$DOCKER_SANDBOX_STATE_FILE" ]]; then
        _sandbox_apply '.container_id = "" | .status = "cleaned"' || true
    fi
    return 0
}

# --- status -----------------------------------------------------------------

# get_docker_sandbox_status
# Emits a JSON object for embedding in status.json:
#   {"provider": "docker", "container_id": "...", "status": "running"}
# Prints {"provider": "none"} when the sandbox was never initialized.
get_docker_sandbox_status() {
    if [[ ! -f "$DOCKER_SANDBOX_STATE_FILE" ]]; then
        echo '{"provider": "none"}'
        return 0
    fi
    jq -c '{provider, container_id, status}' "$DOCKER_SANDBOX_STATE_FILE" 2>/dev/null \
        || echo '{"provider": "none"}'
    return 0
}

# get_sandbox_status
# Provider router used by update_status(): dispatches to the active provider's
# status function. Lives here (not in ralph_loop.sh) so the libs stay usable
# standalone; lib/sandbox_e2b.sh is sourced after this lib by ralph_loop.sh.
get_sandbox_status() {
    case "${SANDBOX_PROVIDER:-}" in
        e2b)
            if declare -F get_e2b_sandbox_status >/dev/null 2>&1; then
                get_e2b_sandbox_status
            else
                echo '{"provider": "none"}'
            fi
            ;;
        *)
            get_docker_sandbox_status
            ;;
    esac
    return 0
}

# Export public functions for use by ralph_loop.sh
export -f docker_is_available
export -f validate_sandbox_config
export -f init_docker_sandbox
export -f setup_docker_credentials
export -f start_sandbox_container
export -f ensure_sandbox_container
export -f build_sandbox_exec_args
export -f handle_sandbox_timeout
export -f stop_sandbox_container
export -f cleanup_docker_sandbox
export -f get_docker_sandbox_status
export -f get_sandbox_status
export -f sandbox_state_get
