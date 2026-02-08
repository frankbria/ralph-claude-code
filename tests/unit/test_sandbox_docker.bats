#!/usr/bin/env bats
## =============================================================================
## tests/unit/test_sandbox_docker.bats - Unit tests for Docker sandbox functions
## Implements: Issue #74 - Phase 6.1 Local Docker Sandbox Execution
## =============================================================================

# Setup: source the library with mocked docker command
setup() {
    export DOCKER_IMAGE="ralph-claude-code:test"
    export DOCKER_CONTAINER_PREFIX="ralph-test"
    export DOCKER_WORKSPACE="/workspace"

    # Source the library
    source "${BATS_TEST_DIRNAME}/../../lib/sandbox_docker.sh"
}

## =============================================================================
## Version and Constants
## =============================================================================

@test "sandbox_docker: version is set" {
    [[ -n "$SANDBOX_DOCKER_VERSION" ]]
}

@test "sandbox_docker: default image name is set" {
    [[ "$DOCKER_IMAGE" == "ralph-claude-code:test" ]]
}

@test "sandbox_docker: default container prefix is set" {
    [[ "$DOCKER_CONTAINER_PREFIX" == "ralph-test" ]]
}

## =============================================================================
## Container Naming
## =============================================================================

@test "sandbox_docker_container_name: generates loop name" {
    result=$(sandbox_docker_container_name loop)
    [[ "$result" == "ralph-test-loop" ]]
}

@test "sandbox_docker_container_name: generates monitor name" {
    result=$(sandbox_docker_container_name monitor)
    [[ "$result" == "ralph-test-monitor" ]]
}

@test "sandbox_docker_container_name: generates shell name" {
    result=$(sandbox_docker_container_name shell)
    [[ "$result" == "ralph-test-shell" ]]
}

@test "sandbox_docker_container_name: defaults to loop" {
    result=$(sandbox_docker_container_name)
    [[ "$result" == "ralph-test-loop" ]]
}

@test "sandbox_docker_container_name: handles custom suffix" {
    result=$(sandbox_docker_container_name custom-worker)
    [[ "$result" == "ralph-test-custom-worker" ]]
}

## =============================================================================
## Run Arguments
## =============================================================================

@test "sandbox_docker_build_run_args: includes project dir volume" {
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"/my/project:/workspace"* ]]
}

@test "sandbox_docker_build_run_args: includes container name" {
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--name test-container"* ]]
}

@test "sandbox_docker_build_run_args: includes TERM env" {
    export TERM="xterm-256color"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"TERM="* ]]
}

@test "sandbox_docker_build_run_args: includes API key when set" {
    export ANTHROPIC_API_KEY="sk-test-key"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"ANTHROPIC_API_KEY=sk-test-key"* ]]
    unset ANTHROPIC_API_KEY
}

@test "sandbox_docker_build_run_args: excludes API key when unset" {
    unset ANTHROPIC_API_KEY
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" != *"ANTHROPIC_API_KEY"* ]]
}

@test "sandbox_docker_build_run_args: includes memory limit when set" {
    export DOCKER_MEMORY_LIMIT="4g"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--memory 4g"* ]]
    unset DOCKER_MEMORY_LIMIT
}

@test "sandbox_docker_build_run_args: excludes memory limit when unset" {
    unset DOCKER_MEMORY_LIMIT
    export DOCKER_MEMORY_LIMIT=""
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" != *"--memory"* ]]
}

@test "sandbox_docker_build_run_args: includes CPU limit when set" {
    export DOCKER_CPU_LIMIT="2"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--cpus 2"* ]]
    unset DOCKER_CPU_LIMIT
}

@test "sandbox_docker_build_run_args: includes network mode" {
    export DOCKER_NETWORK_MODE="host"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--network host"* ]]
    export DOCKER_NETWORK_MODE="bridge"
}

@test "sandbox_docker_build_run_args: defaults to bridge network" {
    export DOCKER_NETWORK_MODE="bridge"
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--network bridge"* ]]
}

@test "sandbox_docker_build_run_args: includes working directory" {
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"-w /workspace"* ]]
}

@test "sandbox_docker_build_run_args: includes interactive and tty flags" {
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"-it"* ]]
}

@test "sandbox_docker_build_run_args: includes rm flag" {
    result=$(sandbox_docker_build_run_args "/my/project" "test-container")
    [[ "$result" == *"--rm"* ]]
}

## =============================================================================
## Docker Check (mocked)
## =============================================================================

@test "sandbox_docker_check: fails when docker not found" {
    # Override PATH to hide docker
    PATH="/usr/bin/nonexistent" run sandbox_docker_check
    [[ "$status" -ne 0 ]]
}

## =============================================================================
## Configuration Defaults
## =============================================================================

@test "sandbox_docker: default network mode is bridge" {
    # Reset to defaults
    source "${BATS_TEST_DIRNAME}/../../lib/sandbox_docker.sh"
    # The default is set at source time; re-check with clean env
    [[ "${DOCKER_NETWORK_MODE}" == "bridge" ]]
}

@test "sandbox_docker: workspace path is /workspace" {
    [[ "$DOCKER_WORKSPACE" == "/workspace" ]]
}
