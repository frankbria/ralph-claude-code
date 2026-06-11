#!/usr/bin/env bats
# E2E tests: full Ralph loop in E2B sandbox mode (Issue #75)
#
# Runs ralph_loop.sh as a TRUE SUBPROCESS with the mock claude CLI on PATH and
# a mock E2B transport substituted via SANDBOX_E2B_PYTHON. The transport mock
# delegates `exec` to the wrapped command (which resolves to the mock claude),
# proving the loop's command routing end-to-end: main() e2b init → create →
# project upload → per-iteration helper exec + artifact download → sandbox
# kill on graceful exit. Covers the main() wiring that the sourced-function
# integration tests cannot reach.

load '../helpers/test_helper'
load 'helpers/e2e_helper'

setup() {
    setup_e2e_project
    install_mock_e2b_transport
    export E2B_API_KEY="e2e-test-key"
}

teardown() {
    teardown_e2e_project
}

# Mock E2B transport: records every helper invocation and delegates `exec` to
# the wrapped command so the mock claude actually runs (host-side, cwd =
# project dir — the cloud workspace is simulated by the project itself).
install_mock_e2b_transport() {
    cat > "$E2E_DIR/bin/e2b-python" << EOF
#!/usr/bin/env bash
E2B_LOG="$MOCK_DIR/e2b_calls.log"
EOF
    cat >> "$E2E_DIR/bin/e2b-python" << 'EOF'
shift   # drop the helper script path
printf '%s\n' "$*" >> "$E2B_LOG"
case "$1" in
    check)    echo '{"ok": true, "sdk_version": "9.9.9-e2e"}'; exit 0 ;;
    create)   echo '{"ok": true, "sandbox_id": "sbx_e2e_test"}'; exit 0 ;;
    connect)  echo '{"ok": true, "sandbox_id": "sbx_e2e_test"}'; exit 0 ;;
    info)     echo '{"ok": true, "state": "running"}'; exit 0 ;;
    upload)   cat > /dev/null; echo '{"ok": true}'; exit 0 ;;
    download) tar -czf - -T /dev/null 2>/dev/null; exit 0 ;;
    kill)     echo '{"ok": true}'; exit 0 ;;
    exec)
        # argv: exec --sandbox-id ID --cwd DIR -- <command...>
        while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
        shift
        exec "$@"
        ;;
esac
exit 0
EOF
    chmod +x "$E2E_DIR/bin/e2b-python"
    export SANDBOX_E2B_PYTHON="$E2E_DIR/bin/e2b-python"
    # The wrapped command's argv[0] is rewritten to bare `claude`, which must
    # resolve to the mock CLI when the transport delegates exec
    export PATH="$E2E_DIR/bin:$PATH"
}

e2b_calls() { cat "$MOCK_DIR/e2b_calls.log" 2>/dev/null; }

@test "E2E: e2b sandbox loop routes execution through the helper and cleans up" {
    queue_response 1 "COMPLETE" "true" "All planned work has shipped."
    queue_productive_effect 1
    queue_response 2 "COMPLETE" "true" "Confirming: nothing left to build."
    queue_productive_effect 2

    run run_ralph --sandbox e2b

    assert_success
    # The loop ran to graceful completion entirely through the sandbox
    assert_equal "$(mock_call_count)" "2"
    assert_equal "$(status_field exit_reason)" "completion_signals"
    assert_equal "$(status_field status)" "completed"
    # status.json surfaces the sandbox for ralph-monitor
    assert_equal "$(status_field sandbox.provider)" "e2b"
    assert_equal "$(status_field sandbox.sandbox_id)" "sbx_e2e_test"

    # One sandbox for the whole run, project uploaded once
    [[ $(e2b_calls | grep -c '^create ') -eq 1 ]]
    [[ $(e2b_calls | grep -c '^upload ') -eq 1 ]]
    # One claude exec per iteration (plus the claude --version bootstrap probe)
    [[ $(e2b_calls | grep -c -- '-- claude --version$') -ge 1 ]]
    [[ $(e2b_calls | grep '^exec ' | grep -v -- '-- claude --version$' | grep -c -- '-- claude ') -eq 2 ]]
    # Changed files are pulled back after each iteration
    [[ $(e2b_calls | grep -c '^download ') -ge 2 ]]
    # Normal exit killed the sandbox (billing stops)
    e2b_calls | grep -q '^kill --sandbox-id sbx_e2e_test$'

    # Side effects from the (sandboxed) claude landed in the project
    assert_file_exists "src/work_1.txt"
}

@test "E2E: e2b setup failure halts before any API call (no host fallback)" {
    # Simulate a missing E2B SDK — the transport check fails
    cat > "$E2E_DIR/bin/e2b-python" << 'EOF'
#!/usr/bin/env bash
shift
echo '{"ok": false, "error": "E2B SDK not installed (pip install e2b)"}'
exit 3
EOF
    chmod +x "$E2E_DIR/bin/e2b-python"

    run run_ralph --sandbox e2b

    [ "$status" -ne 0 ]
    assert_equal "$(mock_call_count)" "0"
    [[ "$output" == *"refusing to fall back to host execution"* ]]
}

@test "E2E: e2b run without an API key halts with actionable guidance" {
    unset E2B_API_KEY

    run run_ralph --sandbox e2b

    [ "$status" -ne 0 ]
    assert_equal "$(mock_call_count)" "0"
    [[ "$output" == *"E2B_API_KEY"* ]]
}
