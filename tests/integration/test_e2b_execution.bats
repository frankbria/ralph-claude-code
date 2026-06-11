#!/usr/bin/env bats
# Integration tests for E2B sandbox execution wiring (Issue #75)
#
# Sources ralph_loop.sh (the BASH_SOURCE guard prevents main from running) and
# exercises the E2B integration points with a mocked transport:
# wrap_claude_command_for_sandbox provider routing, the post-iteration
# artifact sync placement, and the sandbox field in update_status's
# status.json. Mirrors tests/integration/test_docker_execution.bats.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/e2bexec.XXXXXX")"
    cd "$TEST_DIR"

    # Isolate HOME so host ~/.claude and ~/.ralph never leak into tests
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    # Minimal ralph project layout (sourcing ralph_loop.sh mkdirs LOG_DIR)
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR/logs"
    echo "# Test Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "0" > "$RALPH_DIR/.call_count"

    export E2B_API_KEY="test-key-12345"
    unset ANTHROPIC_API_KEY
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Mock E2B transport recording args (same shape as tests/unit/test_sandbox_e2b.bats)
_mock_e2b() {
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/e2b-python" << EOF
#!/bin/bash
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    check) echo '{"ok": true}'; exit 0 ;;
    create) echo '{"ok": true, "sandbox_id": "sbx_int123"}'; exit 0 ;;
    info) echo '{"ok": true, "state": "running"}'; exit 0 ;;
    upload) cat > /dev/null; echo '{"ok": true}'; exit 0 ;;
    download) tar -czf - -T /dev/null 2>/dev/null; exit 0 ;;
    exec) echo "2.0.0-mock"; exit 0 ;;
    kill) echo '{"ok": true}'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python"
    export SANDBOX_E2B_PYTHON="$TEST_DIR/mock_bin/e2b-python"
}

_e2b_args() { cat "$TEST_DIR/e2b_args" 2>/dev/null; }

# Source ralph_loop.sh without running main (BASH_SOURCE guard). Top-level
# assignments run at source time, which is why we cd into TEST_DIR first.
_source_ralph() {
    source "$PROJECT_ROOT/ralph_loop.sh"
}

# -----------------------------------------------------------------------------
# wrap_claude_command_for_sandbox provider routing
# -----------------------------------------------------------------------------

@test "wrap_claude_command_for_sandbox wraps CLAUDE_CMD_ARGS in the e2b helper exec" {
    _mock_e2b
    export SANDBOX_PROVIDER=e2b
    _source_ralph
    init_e2b_sandbox
    start_e2b_sandbox

    CLAUDE_CMD_ARGS=(claude --output-format json -p "build the thing")
    wrap_claude_command_for_sandbox

    [[ "${CLAUDE_CMD_ARGS[0]}" == "$SANDBOX_E2B_PYTHON" ]]
    [[ "${CLAUDE_CMD_ARGS[2]}" == "exec" ]]
    [[ "${CLAUDE_CMD_ARGS[*]}" == *"--sandbox-id sbx_int123"* ]]
    [[ "${CLAUDE_CMD_ARGS[*]}" == *"-- claude --output-format json -p build the thing"* ]]
}

@test "wrap_claude_command_for_sandbox preserves argument boundaries for e2b" {
    _mock_e2b
    export SANDBOX_PROVIDER=e2b
    _source_ralph
    init_e2b_sandbox
    start_e2b_sandbox

    CLAUDE_CMD_ARGS=(claude -p "multi word prompt with 'quotes'")
    wrap_claude_command_for_sandbox

    [[ "${CLAUDE_CMD_ARGS[${#CLAUDE_CMD_ARGS[@]}-1]}" == "multi word prompt with 'quotes'" ]]
}

@test "wrap_claude_command_for_sandbox rewrites host claude paths for the sandbox CLI" {
    _mock_e2b
    export SANDBOX_PROVIDER=e2b
    _source_ralph
    init_e2b_sandbox
    start_e2b_sandbox

    CLAUDE_CMD_ARGS=(/opt/homebrew/bin/claude --output-format json -p "hi")
    wrap_claude_command_for_sandbox

    [[ "${CLAUDE_CMD_ARGS[*]}" != *"/opt/homebrew"* ]]
    [[ "${CLAUDE_CMD_ARGS[*]}" == *"-- claude --output-format json"* ]]
}

@test "wrap_claude_command_for_sandbox recovers an expired e2b sandbox before exec" {
    _mock_e2b
    export SANDBOX_PROVIDER=e2b
    _source_ralph
    init_e2b_sandbox
    start_e2b_sandbox
    rm -f "$TEST_DIR/e2b_args"

    # Sandbox expired: info fails, create succeeds with a fresh id
    cat > "$TEST_DIR/mock_bin/e2b-python" << EOF
#!/bin/bash
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    info) echo '{"ok": false, "error": "sandbox not found"}'; exit 1 ;;
    create) echo '{"ok": true, "sandbox_id": "sbx_fresh789"}'; exit 0 ;;
    upload) cat > /dev/null; echo '{"ok": true}'; exit 0 ;;
    exec) echo "2.0.0-mock"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python"

    CLAUDE_CMD_ARGS=(claude -p "x")
    wrap_claude_command_for_sandbox

    _e2b_args | grep -q '^create '
    [[ "${CLAUDE_CMD_ARGS[*]}" == *"--sandbox-id sbx_fresh789"* ]]
}

# -----------------------------------------------------------------------------
# update_status sandbox field
# -----------------------------------------------------------------------------

@test "update_status embeds e2b sandbox status when active" {
    _mock_e2b
    export SANDBOX_PROVIDER=e2b
    _source_ralph
    init_e2b_sandbox
    start_e2b_sandbox

    update_status 3 7 "executing" "running"

    [[ -f "$RALPH_DIR/status.json" ]]
    jq -e . "$RALPH_DIR/status.json" >/dev/null
    [[ "$(jq -r '.sandbox.provider' "$RALPH_DIR/status.json")" == "e2b" ]]
    [[ "$(jq -r '.sandbox.sandbox_id' "$RALPH_DIR/status.json")" == "sbx_int123" ]]
    [[ "$(jq -r '.sandbox.status' "$RALPH_DIR/status.json")" == "running" ]]
    [[ "$(jq -r '.sandbox.estimated_cost' "$RALPH_DIR/status.json")" != "null" ]]
}

@test "update_status keeps docker routing intact when provider is docker" {
    # Regression guard for the get_sandbox_status router (Issue #75)
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/docker" << EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image) exit 0 ;;
    run) echo "abc123containerid"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/docker"
    export PATH="$TEST_DIR/mock_bin:$PATH"
    export SANDBOX_PROVIDER=docker
    _source_ralph
    init_docker_sandbox
    start_sandbox_container

    update_status 1 1 "executing" "running"

    [[ "$(jq -r '.sandbox.provider' "$RALPH_DIR/status.json")" == "docker" ]]
    [[ "$(jq -r '.sandbox.container_id' "$RALPH_DIR/status.json")" == "abc123containerid" ]]
}
