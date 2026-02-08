#!/usr/bin/env bash
## =============================================================================
## lib/sandbox_docker.sh - Docker Sandbox Functions for Ralph
## Implements: Issue #74 - Phase 6.1 Local Docker Sandbox Execution
## =============================================================================
## Provides functions for running Ralph inside Docker containers with:
##   - Container lifecycle management (create, start, stop, cleanup)
##   - Volume mounting for project files and auth credentials
##   - Resource limits (memory, CPU)
##   - Network configuration
##   - Log streaming for ralph-monitor integration
## =============================================================================

# shellcheck disable=SC2034
SANDBOX_DOCKER_VERSION="0.1.0"

# Default configuration
DOCKER_IMAGE="${DOCKER_IMAGE:-ralph-claude-code:latest}"
DOCKER_CONTAINER_PREFIX="${DOCKER_CONTAINER_PREFIX:-ralph}"
DOCKER_MEMORY_LIMIT="${DOCKER_MEMORY_LIMIT:-}"
DOCKER_CPU_LIMIT="${DOCKER_CPU_LIMIT:-}"
DOCKER_NETWORK_MODE="${DOCKER_NETWORK_MODE:-bridge}"
DOCKER_WORKSPACE="/workspace"

## =============================================================================
## Validation
## =============================================================================

# Check if Docker is available and running
sandbox_docker_check() {
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is not installed." >&2
        echo "Install Docker Desktop from https://www.docker.com/products/docker-desktop/" >&2
        return 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        echo "ERROR: Docker daemon is not running." >&2
        echo "Please start Docker Desktop." >&2
        return 1
    fi

    return 0
}

# Check if the Ralph Docker image exists
sandbox_docker_image_exists() {
    local image="${1:-$DOCKER_IMAGE}"
    docker image inspect "$image" &>/dev/null 2>&1
}

# Build the Ralph Docker image
sandbox_docker_build() {
    local context_dir="${1:-.}"
    local image="${2:-$DOCKER_IMAGE}"

    echo "Building Ralph Docker image: $image"
    docker build -t "$image" "$context_dir"
}

## =============================================================================
## Container Lifecycle
## =============================================================================

# Generate a container name from prefix and optional suffix
sandbox_docker_container_name() {
    local suffix="${1:-loop}"
    echo "${DOCKER_CONTAINER_PREFIX}-${suffix}"
}

# Build the docker run arguments array
# Usage: sandbox_docker_build_args <project_dir> [container_name]
sandbox_docker_build_run_args() {
    local project_dir="$1"
    local container_name="${2:-$(sandbox_docker_container_name)}"
    local args=()

    args+=("--name" "$container_name")
    args+=("-it")
    args+=("--rm")

    # Volume mounts
    args+=("-v" "${project_dir}:${DOCKER_WORKSPACE}")

    # Mount Claude auth directory if it exists
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [[ -d "$claude_dir" ]]; then
        args+=("-v" "${claude_dir}:/home/ralph/.claude")
    fi

    # Environment variables
    args+=("-e" "TERM=${TERM:-xterm-256color}")
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        args+=("-e" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    fi

    # Resource limits
    if [[ -n "$DOCKER_MEMORY_LIMIT" ]]; then
        args+=("--memory" "$DOCKER_MEMORY_LIMIT")
    fi
    if [[ -n "$DOCKER_CPU_LIMIT" ]]; then
        args+=("--cpus" "$DOCKER_CPU_LIMIT")
    fi

    # Network mode
    args+=("--network" "$DOCKER_NETWORK_MODE")

    # Working directory
    args+=("-w" "$DOCKER_WORKSPACE")

    echo "${args[@]}"
}

# Run Ralph loop inside a Docker container
sandbox_docker_run_loop() {
    local project_dir="${1:-.}"
    local ralph_args=("${@:2}")
    local container_name
    container_name="$(sandbox_docker_container_name loop)"

    sandbox_docker_check || return 1

    local run_args
    run_args=($(sandbox_docker_build_run_args "$project_dir" "$container_name"))

    echo "Starting Ralph loop in Docker container: $container_name"
    docker run "${run_args[@]}" \
        --entrypoint ralph \
        "$DOCKER_IMAGE" \
        "${ralph_args[@]}"
}

# Run Ralph monitor inside a Docker container
sandbox_docker_run_monitor() {
    local project_dir="${1:-.}"
    local container_name
    container_name="$(sandbox_docker_container_name monitor)"

    sandbox_docker_check || return 1

    local run_args
    run_args=($(sandbox_docker_build_run_args "$project_dir" "$container_name"))

    echo "Starting Ralph monitor in Docker container: $container_name"
    docker run "${run_args[@]}" \
        --entrypoint ralph-monitor \
        "$DOCKER_IMAGE"
}

# Run interactive shell inside a Docker container
sandbox_docker_run_shell() {
    local project_dir="${1:-.}"
    local container_name
    container_name="$(sandbox_docker_container_name shell)"

    sandbox_docker_check || return 1

    local run_args
    run_args=($(sandbox_docker_build_run_args "$project_dir" "$container_name"))

    docker run "${run_args[@]}" "$DOCKER_IMAGE"
}

## =============================================================================
## Container Management
## =============================================================================

# Stop a specific Ralph container
sandbox_docker_stop() {
    local suffix="${1:-loop}"
    local container_name
    container_name="$(sandbox_docker_container_name "$suffix")"

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Stopping container: $container_name"
        docker stop "$container_name" 2>/dev/null
    else
        echo "Container not running: $container_name"
    fi
}

# Stop all Ralph containers
sandbox_docker_stop_all() {
    local containers
    containers=$(docker ps --filter "name=${DOCKER_CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null)

    if [[ -z "$containers" ]]; then
        echo "No Ralph containers running."
        return 0
    fi

    echo "$containers" | while read -r name; do
        echo "Stopping: $name"
        docker stop "$name" 2>/dev/null
    done
}

# Get status of Ralph containers
sandbox_docker_status() {
    echo "Ralph Docker Containers:"
    echo "========================"
    docker ps -a \
        --filter "name=${DOCKER_CONTAINER_PREFIX}" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null

    echo ""
    echo "Image: $(sandbox_docker_image_exists && echo "EXISTS" || echo "NOT BUILT") ($DOCKER_IMAGE)"
}

# Stream logs from a Ralph container
sandbox_docker_logs() {
    local suffix="${1:-loop}"
    local container_name
    container_name="$(sandbox_docker_container_name "$suffix")"

    docker logs -f "$container_name" 2>/dev/null
}

## =============================================================================
## Cleanup
## =============================================================================

# Remove stopped Ralph containers
sandbox_docker_cleanup_containers() {
    docker ps -a \
        --filter "name=${DOCKER_CONTAINER_PREFIX}" \
        --filter "status=exited" \
        --format '{{.Names}}' 2>/dev/null | while read -r name; do
        echo "Removing: $name"
        docker rm "$name" 2>/dev/null
    done
}

# Full cleanup: containers, image, volumes
sandbox_docker_cleanup_all() {
    echo "Cleaning up all Ralph Docker resources..."
    sandbox_docker_stop_all
    sandbox_docker_cleanup_containers

    if sandbox_docker_image_exists; then
        echo "Removing image: $DOCKER_IMAGE"
        docker rmi "$DOCKER_IMAGE" 2>/dev/null
    fi

    echo "Removing Ralph volumes..."
    docker volume rm ralph-home 2>/dev/null || true

    echo "Cleanup complete."
}
