#!/usr/bin/env bats
# Integration tests for Docker sandbox execution wiring (Issue #74)
#
# Part 1 sources ralph_loop.sh (the BASH_SOURCE guard prevents main from
# running) and exercises the sandbox integration points with a PATH-mocked
# docker: wrap_claude_command_for_sandbox and the sandbox field in
# update_status's status.json.
#
# Part 2 runs against a REAL Docker daemon when one is available (skipped
# otherwise): container lifecycle, exec wrapping, and the workspace bind
# mount. These catch real docker argument/quoting bugs the mocks cannot.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/dockerexec.XXXXXX")"
    cd "$TEST_DIR"

    # Isolate HOME so host ~/.claude never leaks into tests
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    # Minimal ralph project layout (sourcing ralph_loop.sh mkdirs LOG_DIR)
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR/logs"
    echo "# Test Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "0" > "$RALPH_DIR/.call_count"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Mock docker recording args (same shape as tests/unit/test_sandbox_docker.bats)
_mock_docker() {
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/docker" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_DIR/docker_args"
case "\$1" in
    info) exit 0 ;;
    image) exit 0 ;;
    run) echo "abc123containerid"; exit 0 ;;
    inspect) echo "running"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/docker"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

# Source ralph_loop.sh without running main (BASH_SOURCE guard). Top-level
# assignments run at source time, which is why we cd into TEST_DIR first.
_source_ralph() {
    source "$PROJECT_ROOT/ralph_loop.sh"
}

# -----------------------------------------------------------------------------
# wrap_claude_command_for_sandbox
# -----------------------------------------------------------------------------

@test "wrap_claude_command_for_sandbox wraps CLAUDE_CMD_ARGS in docker exec" {
    _mock_docker
    export SANDBOX_PROVIDER=docker
    _source_ralph
    init_docker_sandbox
    start_sandbox_container

    CLAUDE_CMD_ARGS=(claude --output-format json -p "build the thing")
    wrap_claude_command_for_sandbox

    [[ "${CLAUDE_CMD_ARGS[0]}" == "docker" ]]
    [[ "${CLAUDE_CMD_ARGS[1]}" == "exec" ]]
    [[ "${CLAUDE_CMD_ARGS[*]}" == *"abc123containerid claude --output-format json -p build the thing"* ]]
}

@test "wrap_claude_command_for_sandbox preserves argument boundaries" {
    _mock_docker
    export SANDBOX_PROVIDER=docker
    _source_ralph
    init_docker_sandbox
    start_sandbox_container

    CLAUDE_CMD_ARGS=(claude -p "multi word prompt with 'quotes'")
    wrap_claude_command_for_sandbox

    # Last element must still be the intact prompt string
    [[ "${CLAUDE_CMD_ARGS[${#CLAUDE_CMD_ARGS[@]}-1]}" == "multi word prompt with 'quotes'" ]]
}

@test "wrap_claude_command_for_sandbox fails without a running container" {
    _mock_docker
    export SANDBOX_PROVIDER=docker
    _source_ralph
    init_docker_sandbox

    CLAUDE_CMD_ARGS=(claude -p "x")
    run wrap_claude_command_for_sandbox
    [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# update_status sandbox field
# -----------------------------------------------------------------------------

@test "update_status embeds sandbox status when sandbox is active" {
    _mock_docker
    export SANDBOX_PROVIDER=docker
    _source_ralph
    init_docker_sandbox
    start_sandbox_container

    update_status 3 7 "executing" "running"

    [[ -f "$RALPH_DIR/status.json" ]]
    jq -e . "$RALPH_DIR/status.json" >/dev/null
    [[ "$(jq -r '.sandbox.provider' "$RALPH_DIR/status.json")" == "docker" ]]
    [[ "$(jq -r '.sandbox.container_id' "$RALPH_DIR/status.json")" == "abc123containerid" ]]
    [[ "$(jq -r '.sandbox.status' "$RALPH_DIR/status.json")" == "running" ]]
}

@test "update_status reports sandbox provider none when disabled" {
    _mock_docker
    _source_ralph

    update_status 1 1 "executing" "running"

    jq -e . "$RALPH_DIR/status.json" >/dev/null
    [[ "$(jq -r '.sandbox.provider' "$RALPH_DIR/status.json")" == "none" ]]
}

# -----------------------------------------------------------------------------
# Real Docker (skipped when no usable daemon)
# -----------------------------------------------------------------------------

_require_real_docker() {
    command -v docker &>/dev/null || skip "docker not installed"
    docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
    # Use a tiny image that is almost always present or fast to pull
    if ! docker image inspect alpine:latest >/dev/null 2>&1; then
        docker pull -q alpine:latest >/dev/null 2>&1 || skip "cannot pull alpine:latest"
    fi
}

@test "real docker: container lifecycle start, exec, cleanup" {
    _require_real_docker
    export SANDBOX_PROVIDER=docker
    export SANDBOX_DOCKER_IMAGE="alpine:latest"
    source "$PROJECT_ROOT/lib/sandbox_docker.sh"

    init_docker_sandbox
    start_sandbox_container
    local cid
    cid=$(sandbox_state_get '.container_id')
    [[ -n "$cid" ]]

    # The container is alive and execs run inside it
    build_sandbox_exec_args sh -c 'echo in-container'
    run "${SANDBOX_EXEC_ARGS[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"in-container"* ]]

    cleanup_docker_sandbox
    # Container must be gone
    run docker inspect "$cid"
    [ "$status" -ne 0 ]
}

@test "real docker: workspace bind mount is read-write from both sides" {
    _require_real_docker
    export SANDBOX_PROVIDER=docker
    export SANDBOX_DOCKER_IMAGE="alpine:latest"
    source "$PROJECT_ROOT/lib/sandbox_docker.sh"

    init_docker_sandbox
    start_sandbox_container

    echo "host-content" > host_file.txt
    build_sandbox_exec_args sh -c 'cat /workspace/host_file.txt && echo container-content > /workspace/container_file.txt'
    run "${SANDBOX_EXEC_ARGS[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"host-content"* ]]

    # File written inside the container landed on the host
    [[ -f container_file.txt ]]
    grep -q "container-content" container_file.txt

    cleanup_docker_sandbox
}
