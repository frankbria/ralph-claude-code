#!/usr/bin/env bats
# E2E tests: full Ralph loop in Docker sandbox mode (Issue #74)
#
# Runs ralph_loop.sh as a TRUE SUBPROCESS with both the mock claude CLI and a
# mock docker on PATH. The docker mock delegates `docker exec` to the wrapped
# command (which is the mock claude), proving the loop's command routing
# end-to-end: main() sandbox init → docker run → per-iteration docker exec →
# container cleanup on graceful exit. Covers the main() wiring that the
# sourced-function integration tests cannot reach.

load '../helpers/test_helper'
load 'helpers/e2e_helper'

setup() {
    setup_e2e_project
    install_mock_docker
}

teardown() {
    teardown_e2e_project
}

# Mock docker: records every invocation, reports a healthy daemon/image, and
# delegates `exec` to the wrapped command so the mock claude actually runs.
install_mock_docker() {
    cat > "$E2E_DIR/bin/docker" << EOF
#!/usr/bin/env bash
DOCKER_LOG="$MOCK_DIR/docker_calls.log"
EOF
    cat >> "$E2E_DIR/bin/docker" << 'EOF'
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
    info)    exit 0 ;;
    image)   exit 0 ;;
    inspect) echo "true"; exit 0 ;;
    run)     echo "e2emockcontainer"; exit 0 ;;
    exec)
        # argv: exec -i -w /workspace <container-id> <claude-path> [args...]
        shift 5
        exec "$@"
        ;;
    stop|rm|restart) exit 0 ;;
esac
exit 0
EOF
    chmod +x "$E2E_DIR/bin/docker"
    export PATH="$E2E_DIR/bin:$PATH"
}

docker_calls() { cat "$MOCK_DIR/docker_calls.log" 2>/dev/null; }

@test "E2E: sandbox loop routes execution through docker exec and cleans up" {
    queue_response 1 "COMPLETE" "true" "All planned work has shipped."
    queue_productive_effect 1
    queue_response 2 "COMPLETE" "true" "Confirming: nothing left to build."
    queue_productive_effect 2

    run run_ralph --sandbox docker

    assert_success
    # The loop ran to graceful completion entirely through the sandbox
    assert_equal "$(mock_call_count)" "2"
    assert_equal "$(status_field exit_reason)" "completion_signals"
    assert_equal "$(status_field status)" "completed"
    # status.json surfaces the sandbox for ralph-monitor
    assert_equal "$(status_field sandbox.provider)" "docker"

    # One persistent container: a single docker run, one exec per iteration
    [[ $(docker_calls | grep -c '^run ') -eq 1 ]]
    [[ $(docker_calls | grep -c '^exec ') -eq 2 ]]
    # Workspace bind mount and image are part of the run command
    docker_calls | grep '^run ' | grep -q -- "-v $PROJECT_DIR:/workspace"
    docker_calls | grep '^run ' | grep -q "ralph-sandbox:latest"
    # Normal exit tore the container down
    docker_calls | grep -q '^stop '
    docker_calls | grep -q '^rm '

    # Side effects from the (sandboxed) claude landed in the project workspace
    assert_file_exists "src/work_1.txt"
}

@test "E2E: sandbox setup failure halts before any API call (no host fallback)" {
    # Simulate an unreachable docker daemon
    cat > "$E2E_DIR/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
EOF
    chmod +x "$E2E_DIR/bin/docker"

    run run_ralph --sandbox docker

    [ "$status" -ne 0 ]
    assert_equal "$(mock_call_count)" "0"
    [[ "$output" == *"refusing to fall back to host execution"* ]]
}
