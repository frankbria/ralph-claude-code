#!/usr/bin/env bats
# Unit tests for lib/sandbox_docker.sh (Issue #74)
#
# Covers the Docker sandbox module: config validation, daemon availability,
# sandbox init (state file + image presence check), container lifecycle
# (start/stop/cleanup), secure credential handoff (env-file / seeded claude
# home), exec-arg wrapping, timeout recovery, and the status JSON emitted for
# status.json.
#
# The `docker` mock records its args to a file so assertions survive `run`'s
# subshell boundary — same pattern as test_github_lifecycle.bats's gh mock.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
    cd "$TEST_DIR"

    export RALPH_DIR="$TEST_DIR/.ralph"
    export DOCKER_SANDBOX_STATE_FILE="$RALPH_DIR/.docker_sandbox_state"
    mkdir -p "$RALPH_DIR"

    # Credential artifacts live OUTSIDE the workspace (bind-mount safety);
    # tests pin them to an inspectable location
    export SANDBOX_RUNTIME_DIR="$TEST_DIR/runtime"
    export SANDBOX_ENV_FILE="$SANDBOX_RUNTIME_DIR/env"
    export SANDBOX_CLAUDE_HOME="$SANDBOX_RUNTIME_DIR/claude_home"

    # Isolate HOME so host ~/.claude never leaks into credential tests
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    # Clean default sandbox configuration
    export SANDBOX_PROVIDER="docker"
    export SANDBOX_DOCKER_IMAGE="ralph-sandbox:latest"
    export SANDBOX_DOCKER_MEMORY="4g"
    export SANDBOX_DOCKER_CPUS="2"
    export SANDBOX_DOCKER_NETWORK="bridge"
    unset ANTHROPIC_API_KEY

    source "$PROJECT_ROOT/lib/sandbox_docker.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Build a mock docker that records each invocation's args and can simulate
# failure modes. $1 = "ok" | "no-daemon" | "no-image" | "run-fail".
_mock_docker() {
    local mode="${1:-ok}"
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/docker" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_DIR/docker_args"
case "\$1" in
    info)
        if [[ "$mode" == "no-daemon" ]]; then
            echo "Cannot connect to the Docker daemon" >&2
            exit 1
        fi
        exit 0 ;;
    image)
        # docker image inspect <image>
        if [[ "$mode" == "no-image" ]]; then
            echo "Error: No such image" >&2
            exit 1
        fi
        exit 0 ;;
    run)
        if [[ "$mode" == "run-fail" ]]; then
            echo "docker: Error response from daemon" >&2
            exit 125
        fi
        if [[ "$mode" == "run-warning" ]]; then
            echo "WARNING: Your kernel does not support swap limit capabilities" >&2
        fi
        echo "abc123containerid"
        exit 0 ;;
    inspect)
        # docker inspect -f '{{.State.Running}}' <cid>
        if [[ "$mode" == "container-stopped" ]]; then
            echo "false"
            exit 0
        fi
        if [[ "$mode" == "container-gone" ]]; then
            echo "Error: No such object" >&2
            exit 1
        fi
        echo "true"
        exit 0 ;;
    start)
        if [[ "$mode" == "container-gone" ]]; then
            echo "Error: No such container" >&2
            exit 1
        fi
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/docker"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

_docker_args() { cat "$TEST_DIR/docker_args" 2>/dev/null; }

# -----------------------------------------------------------------------------
# validate_sandbox_config
# -----------------------------------------------------------------------------

@test "validate_sandbox_config: accepts clean defaults" {
    run validate_sandbox_config
    assert_success
}

@test "validate_sandbox_config: rejects unknown provider" {
    export SANDBOX_PROVIDER="podman"
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"provider"* ]]
}

@test "validate_sandbox_config: rejects empty image" {
    export SANDBOX_DOCKER_IMAGE=""
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"image"* ]]
}

@test "validate_sandbox_config: rejects image with shell metacharacters" {
    export SANDBOX_DOCKER_IMAGE='evil;rm -rf /'
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"image"* ]]
}

@test "validate_sandbox_config: accepts registry-qualified image with tag" {
    export SANDBOX_DOCKER_IMAGE="ghcr.io/frankbria/ralph-sandbox:v1.2"
    run validate_sandbox_config
    assert_success
}

@test "validate_sandbox_config: rejects malformed memory limit" {
    export SANDBOX_DOCKER_MEMORY="lots"
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"memory"* ]]
}

@test "validate_sandbox_config: accepts docker memory formats" {
    for mem in 4g 512m 1024k 2048; do
        export SANDBOX_DOCKER_MEMORY="$mem"
        run validate_sandbox_config
        assert_success
    done
}

@test "validate_sandbox_config: rejects non-numeric cpus" {
    export SANDBOX_DOCKER_CPUS="two"
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"cpus"* ]]
}

@test "validate_sandbox_config: accepts fractional cpus" {
    export SANDBOX_DOCKER_CPUS="1.5"
    run validate_sandbox_config
    assert_success
}

@test "validate_sandbox_config: rejects unknown network mode" {
    export SANDBOX_DOCKER_NETWORK="vpn"
    run validate_sandbox_config
    assert_failure
    [[ "$output" == *"network"* ]]
}

@test "validate_sandbox_config: accepts none, bridge, and host networks" {
    for net in none bridge host; do
        export SANDBOX_DOCKER_NETWORK="$net"
        run validate_sandbox_config
        assert_success
    done
}

# -----------------------------------------------------------------------------
# docker_is_available
# -----------------------------------------------------------------------------

@test "docker_is_available: succeeds when docker CLI and daemon respond" {
    _mock_docker ok
    run docker_is_available
    assert_success
}

@test "docker_is_available: fails when daemon is unreachable" {
    _mock_docker no-daemon
    run docker_is_available
    assert_failure
}

@test "docker_is_available: fails when docker CLI is not on PATH" {
    local original_path="$PATH"
    PATH="/usr/bin:/bin"
    if command -v docker &>/dev/null; then
        PATH="$original_path"
        skip "Cannot hide docker from PATH in this environment"
    fi
    run docker_is_available
    PATH="$original_path"
    assert_failure
}

# -----------------------------------------------------------------------------
# init_docker_sandbox
# -----------------------------------------------------------------------------

@test "init_docker_sandbox: writes state file with config" {
    _mock_docker ok
    run init_docker_sandbox
    assert_success
    [[ -f "$DOCKER_SANDBOX_STATE_FILE" ]]
    assert_equal "$(jq -r '.provider' "$DOCKER_SANDBOX_STATE_FILE")" "docker"
    assert_equal "$(jq -r '.image' "$DOCKER_SANDBOX_STATE_FILE")" "ralph-sandbox:latest"
    assert_equal "$(jq -r '.status' "$DOCKER_SANDBOX_STATE_FILE")" "initialized"
    assert_equal "$(jq -r '.container_id' "$DOCKER_SANDBOX_STATE_FILE")" ""
}

@test "init_docker_sandbox: fails when daemon is unreachable" {
    _mock_docker no-daemon
    run init_docker_sandbox
    assert_failure
    [[ "$output" == *"daemon"* || "$output" == *"Docker"* ]]
}

@test "init_docker_sandbox: missing default image suggests docker build" {
    _mock_docker no-image
    run init_docker_sandbox
    assert_failure
    [[ "$output" == *"docker build"* ]]
}

@test "init_docker_sandbox: missing custom image suggests docker pull" {
    _mock_docker no-image
    export SANDBOX_DOCKER_IMAGE="python:3.11"
    run init_docker_sandbox
    assert_failure
    [[ "$output" == *"python:3.11"* ]]
}

@test "init_docker_sandbox: fails on invalid config" {
    _mock_docker ok
    export SANDBOX_DOCKER_NETWORK="vpn"
    run init_docker_sandbox
    assert_failure
}

# -----------------------------------------------------------------------------
# start_sandbox_container
# -----------------------------------------------------------------------------

@test "start_sandbox_container: runs detached with workspace mount and limits" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *"-d"* ]]
    [[ "$run_line" == *"-v $TEST_DIR:/workspace"* ]]
    [[ "$run_line" == *"-w /workspace"* ]]
    [[ "$run_line" == *"--memory 4g"* ]]
    [[ "$run_line" == *"--cpus 2"* ]]
    [[ "$run_line" == *"--network bridge"* ]]
    [[ "$run_line" == *"ralph-sandbox:latest"* ]]
    [[ "$run_line" == *"sleep infinity"* ]]
}

@test "start_sandbox_container: runs as the host uid:gid (bind-mount ownership)" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *"--user $(id -u):$(id -g)"* ]]
}

@test "start_sandbox_container: always mounts a writable sandbox home with HOME override" {
    _mock_docker ok
    init_docker_sandbox
    setup_docker_credentials   # no API key, no host credentials → still creates the home
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *"-v $SANDBOX_CLAUDE_HOME:/ralph-home"* ]]
    [[ "$run_line" == *"-e HOME=/ralph-home"* ]]
}

@test "start_sandbox_container: records container id and running status" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    assert_equal "$(jq -r '.container_id' "$DOCKER_SANDBOX_STATE_FILE")" "abc123containerid"
    assert_equal "$(jq -r '.status' "$DOCKER_SANDBOX_STATE_FILE")" "running"
}

@test "start_sandbox_container: uses custom image" {
    _mock_docker ok
    export SANDBOX_DOCKER_IMAGE="node:20"
    init_docker_sandbox
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *" node:20 "* ]]
}

@test "start_sandbox_container: fails when docker run fails" {
    _mock_docker run-fail
    init_docker_sandbox
    run start_sandbox_container
    assert_failure
}

@test "start_sandbox_container: daemon warnings on stderr do not contaminate the container id" {
    _mock_docker run-warning
    init_docker_sandbox
    start_sandbox_container
    assert_equal "$(jq -r '.container_id' "$DOCKER_SANDBOX_STATE_FILE")" "abc123containerid"
}

@test "credential artifacts default to a location outside the workspace" {
    # Fresh shell without the test overrides: the lib's own defaults must not
    # place secrets inside the bind-mounted project directory
    run bash -c "cd '$TEST_DIR' && unset SANDBOX_RUNTIME_DIR SANDBOX_ENV_FILE SANDBOX_CLAUDE_HOME && source '$PROJECT_ROOT/lib/sandbox_docker.sh' && printf '%s\n%s\n' \"\$SANDBOX_ENV_FILE\" \"\$SANDBOX_CLAUDE_HOME\""
    assert_success
    [[ "${lines[0]}" != "$TEST_DIR"* ]]
    [[ "${lines[1]}" != "$TEST_DIR"* ]]
}

# -----------------------------------------------------------------------------
# setup_docker_credentials
# -----------------------------------------------------------------------------

@test "setup_docker_credentials: writes 600 env-file from ANTHROPIC_API_KEY" {
    _mock_docker ok
    export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
    setup_docker_credentials
    [[ -f "$SANDBOX_ENV_FILE" ]]
    assert_equal "$(stat -c %a "$SANDBOX_ENV_FILE" 2>/dev/null || stat -f %Lp "$SANDBOX_ENV_FILE")" "600"
    grep -q "ANTHROPIC_API_KEY=sk-ant-test-placeholder" "$SANDBOX_ENV_FILE"
}

@test "setup_docker_credentials: env-file is passed to docker run" {
    _mock_docker ok
    export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
    init_docker_sandbox
    setup_docker_credentials
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *"--env-file $SANDBOX_ENV_FILE"* ]]
}

@test "setup_docker_credentials: never logs the API key value" {
    _mock_docker ok
    export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
    run setup_docker_credentials
    assert_success
    [[ "$output" != *"sk-ant-test-placeholder"* ]]
}

@test "setup_docker_credentials: seeds container claude home from host credentials" {
    _mock_docker ok
    mkdir -p "$HOME/.claude"
    echo '{"token":"test-placeholder-token"}' > "$HOME/.claude/.credentials.json"
    setup_docker_credentials
    [[ -f "$SANDBOX_CLAUDE_HOME/.claude/.credentials.json" ]]
    assert_equal "$(stat -c %a "$SANDBOX_CLAUDE_HOME/.claude/.credentials.json" 2>/dev/null || stat -f %Lp "$SANDBOX_CLAUDE_HOME/.claude/.credentials.json")" "600"
}

@test "setup_docker_credentials: claude home is mounted with HOME override" {
    _mock_docker ok
    mkdir -p "$HOME/.claude"
    echo '{"token":"test-placeholder-token"}' > "$HOME/.claude/.credentials.json"
    init_docker_sandbox
    setup_docker_credentials
    start_sandbox_container
    local run_line
    run_line=$(_docker_args | grep '^run ')
    [[ "$run_line" == *"-v $SANDBOX_CLAUDE_HOME:/ralph-home"* ]]
    [[ "$run_line" == *"-e HOME=/ralph-home"* ]]
}

@test "setup_docker_credentials: warns but succeeds with no credentials" {
    _mock_docker ok
    run setup_docker_credentials
    assert_success
    [[ "$output" == *"WARN"* || "$output" == *"credential"* ]]
}

@test "setup_docker_credentials: creates the sandbox home even without credentials" {
    _mock_docker ok
    setup_docker_credentials
    [[ -d "$SANDBOX_CLAUDE_HOME/.claude" ]]
}

@test "setup_docker_credentials: seeds gitconfig so in-container commits work" {
    _mock_docker ok
    printf '[user]\n\temail = t@t.io\n\tname = T\n' > "$HOME/.gitconfig"
    setup_docker_credentials
    grep -q "t@t.io" "$SANDBOX_CLAUDE_HOME/.gitconfig"
}

# -----------------------------------------------------------------------------
# ensure_sandbox_container (liveness + recovery)
# -----------------------------------------------------------------------------

@test "ensure_sandbox_container: no-op when the container is running" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    run ensure_sandbox_container
    assert_success
    ! _docker_args | grep -q '^start '
}

@test "ensure_sandbox_container: restarts a stopped container (OOM kill recovery)" {
    _mock_docker container-stopped
    init_docker_sandbox
    start_sandbox_container
    run ensure_sandbox_container
    assert_success
    _docker_args | grep -q '^start .*abc123containerid'
}

@test "ensure_sandbox_container: replaces a container that no longer exists" {
    _mock_docker container-gone
    init_docker_sandbox
    start_sandbox_container
    : > "$TEST_DIR/docker_args"   # only observe recovery calls
    ensure_sandbox_container
    # Fresh docker run replaced the lost container
    _docker_args | grep -q '^run '
    assert_equal "$(jq -r '.container_id' "$DOCKER_SANDBOX_STATE_FILE")" "abc123containerid"
}

@test "ensure_sandbox_container: fails when no container was ever started" {
    _mock_docker ok
    init_docker_sandbox
    run ensure_sandbox_container
    assert_failure
}

# -----------------------------------------------------------------------------
# build_sandbox_exec_args
# -----------------------------------------------------------------------------

@test "build_sandbox_exec_args: wraps command in docker exec" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    build_sandbox_exec_args claude --output-format json -p "do things"
    assert_equal "${SANDBOX_EXEC_ARGS[0]}" "docker"
    assert_equal "${SANDBOX_EXEC_ARGS[1]}" "exec"
    assert_equal "${SANDBOX_EXEC_ARGS[2]}" "-i"
    assert_equal "${SANDBOX_EXEC_ARGS[3]}" "-w"
    assert_equal "${SANDBOX_EXEC_ARGS[4]}" "/workspace"
    assert_equal "${SANDBOX_EXEC_ARGS[5]}" "abc123containerid"
    assert_equal "${SANDBOX_EXEC_ARGS[6]}" "claude"
    assert_equal "${SANDBOX_EXEC_ARGS[9]}" "-p"
    assert_equal "${SANDBOX_EXEC_ARGS[10]}" "do things"
}

@test "build_sandbox_exec_args: fails when no container is running" {
    _mock_docker ok
    init_docker_sandbox
    run build_sandbox_exec_args claude -p "x"
    assert_failure
}

# -----------------------------------------------------------------------------
# handle_sandbox_timeout
# -----------------------------------------------------------------------------

@test "handle_sandbox_timeout: restarts the container to kill orphaned exec" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    run handle_sandbox_timeout
    assert_success
    _docker_args | grep -q '^restart .*abc123containerid'
}

@test "handle_sandbox_timeout: no-op without a container" {
    _mock_docker ok
    init_docker_sandbox
    run handle_sandbox_timeout
    assert_success
    ! _docker_args | grep -q '^restart'
}

# -----------------------------------------------------------------------------
# stop / cleanup
# -----------------------------------------------------------------------------

@test "stop_sandbox_container: stops and removes the container" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    stop_sandbox_container
    _docker_args | grep -q '^stop .*abc123containerid'
    _docker_args | grep -q '^rm .*abc123containerid'
    assert_equal "$(jq -r '.status' "$DOCKER_SANDBOX_STATE_FILE")" "stopped"
    assert_equal "$(jq -r '.container_id' "$DOCKER_SANDBOX_STATE_FILE")" ""
}

@test "cleanup_docker_sandbox: removes container, env-file, and claude home" {
    _mock_docker ok
    export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
    mkdir -p "$HOME/.claude"
    echo '{"token":"test-placeholder-token"}' > "$HOME/.claude/.credentials.json"
    init_docker_sandbox
    setup_docker_credentials
    start_sandbox_container
    cleanup_docker_sandbox
    [[ ! -f "$SANDBOX_ENV_FILE" ]]
    [[ ! -d "$SANDBOX_CLAUDE_HOME" ]]
    _docker_args | grep -q '^rm .*abc123containerid'
    assert_equal "$(jq -r '.status' "$DOCKER_SANDBOX_STATE_FILE")" "cleaned"
}

@test "cleanup_docker_sandbox: is idempotent" {
    _mock_docker ok
    init_docker_sandbox
    cleanup_docker_sandbox
    run cleanup_docker_sandbox
    assert_success
}

@test "cleanup_docker_sandbox: safe to call before init" {
    _mock_docker ok
    run cleanup_docker_sandbox
    assert_success
}

# -----------------------------------------------------------------------------
# get_sandbox_status
# -----------------------------------------------------------------------------

@test "get_sandbox_status: emits JSON with provider, container id, and status" {
    _mock_docker ok
    init_docker_sandbox
    start_sandbox_container
    run get_sandbox_status
    assert_success
    echo "$output" | jq -e . >/dev/null
    assert_equal "$(echo "$output" | jq -r '.provider')" "docker"
    assert_equal "$(echo "$output" | jq -r '.container_id')" "abc123containerid"
    assert_equal "$(echo "$output" | jq -r '.status')" "running"
}

@test "get_sandbox_status: reports none when sandbox never initialized" {
    run get_sandbox_status
    assert_success
    assert_equal "$(echo "$output" | jq -r '.provider')" "none"
}
