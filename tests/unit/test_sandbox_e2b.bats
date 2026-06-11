#!/usr/bin/env bats
# Unit tests for lib/sandbox_e2b.sh (Issue #75)
#
# Covers the E2B cloud sandbox module: config validation, transport
# availability, API key resolution, sandbox lifecycle (create/connect/
# recreate/kill), project upload + artifact download (with .git filtering),
# claude-CLI bootstrap, cost tracking with max-cost/alert thresholds,
# timeout recovery, idempotent cleanup, and the status JSON for status.json.
#
# The E2B Python SDK is never called: SANDBOX_E2B_PYTHON points at a mock
# that records its args to a file (same pattern as test_sandbox_docker.bats's
# docker mock) and replays canned helper JSON responses.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/e2b.XXXXXX")"
    cd "$TEST_DIR"

    export RALPH_DIR="$TEST_DIR/.ralph"
    export E2B_SANDBOX_STATE_FILE="$RALPH_DIR/.e2b_sandbox_state"
    export LOG_DIR="$RALPH_DIR/logs"
    mkdir -p "$RALPH_DIR" "$LOG_DIR"

    # Isolate HOME so host ~/.claude and ~/.ralph never leak into tests
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    export E2B_API_KEY_FILE="$HOME/.ralph/e2b_api_key"

    # Clean default sandbox configuration
    export SANDBOX_PROVIDER="e2b"
    export SANDBOX_E2B_TEMPLATE="base"
    export SANDBOX_E2B_SANDBOX_ID=""
    export SANDBOX_E2B_TIMEOUT="3600"
    export SANDBOX_E2B_KEEP_ALIVE="false"
    export SANDBOX_E2B_MAX_COST=""
    export SANDBOX_E2B_COST_ALERT=""
    export SANDBOX_E2B_COST_PER_HOUR="0.10"
    export SANDBOX_E2B_WORKDIR="/home/user/workspace"
    export E2B_API_KEY="test-key-12345"
    unset ANTHROPIC_API_KEY

    # Clean sync filter configuration (Issue #76)
    export SYNC_INCLUDE=""
    export SYNC_EXCLUDE=""
    export SYNC_MAX_FILE_SIZE="10485760"
    export SYNC_LARGE_FILE_ACTION="warn"
    export RALPHIGNORE_FILE=".ralphignore"

    # Transport boundary: helper path must exist (availability check); the
    # python interpreter is the mock that intercepts every helper call.
    export SANDBOX_E2B_HELPER="$PROJECT_ROOT/lib/e2b_helper.py"

    source "$PROJECT_ROOT/lib/sandbox_e2b.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Build a mock "python" that records each helper invocation (minus the helper
# script path) and simulates failure modes.
# $1 = ok | no-sdk | create-fail | connect-fail | sandbox-dead | exec-fail |
#      upload-fail | download-fail | download-empty | no-claude | no-claude-ever
_mock_e2b() {
    local mode="${1:-ok}"
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/e2b-python" << EOF
#!/bin/bash
# argv: <helper.py> <subcommand> [args...] — drop the script path
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    check)
        if [[ "$mode" == "no-sdk" ]]; then
            echo '{"ok": false, "error": "E2B SDK not installed (pip install e2b)"}'
            exit 3
        fi
        echo '{"ok": true, "sdk_version": "9.9.9-mock"}'
        exit 0 ;;
    create)
        if [[ "$mode" == "create-fail" ]]; then
            echo '{"ok": false, "error": "invalid API key"}'
            exit 1
        fi
        [[ -n "\${ANTHROPIC_API_KEY:-}" ]] && touch "$TEST_DIR/saw_anthropic_env"
        echo '{"ok": true, "sandbox_id": "sbx_mock123"}'
        exit 0 ;;
    connect)
        if [[ "$mode" == "connect-fail" ]]; then
            echo '{"ok": false, "error": "sandbox not found"}'
            exit 1
        fi
        echo "{\"ok\": true, \"sandbox_id\": \"\$3\"}"
        exit 0 ;;
    info)
        if [[ "$mode" == "sandbox-dead" ]]; then
            echo '{"ok": false, "error": "sandbox not found"}'
            exit 1
        fi
        echo '{"ok": true, "state": "running"}'
        exit 0 ;;
    exec)
        while [[ \$# -gt 0 && "\$1" != "--" ]]; do shift; done
        shift
        if [[ "\$1" == "claude" && "\$2" == "--version" ]]; then
            if [[ "$mode" == "no-claude-ever" ]]; then exit 127; fi
            if [[ "$mode" == "no-claude" && ! -f "$TEST_DIR/npm_installed" ]]; then exit 127; fi
            echo "2.0.0-mock"
            exit 0
        fi
        if [[ "\$1" == "npm" ]]; then
            touch "$TEST_DIR/npm_installed"
            exit 0
        fi
        if [[ "$mode" == "exec-fail" ]]; then exit 1; fi
        exit 0 ;;
    upload)
        wc -c < /dev/stdin > "$TEST_DIR/upload_bytes"
        if [[ "$mode" == "upload-fail" ]]; then
            echo '{"ok": false, "error": "upload failed"}'
            exit 1
        fi
        echo '{"ok": true}'
        exit 0 ;;
    download)
        if [[ "$mode" == "download-fail" ]]; then exit 1; fi
        if [[ "$mode" == "download-empty" ]]; then
            tar -czf - -T /dev/null 2>/dev/null
            exit 0
        fi
        tmpd=\$(mktemp -d)
        mkdir -p "\$tmpd/.git" "\$tmpd/src"
        echo "from-sandbox" > "\$tmpd/src/synced.txt"
        echo "evil" > "\$tmpd/.git/config"
        # Manifest member: the sandbox's CURRENT file list (deletion sync).
        # Faithful default = everything previously synced plus the new file
        # (the real helper lists the whole workspace, a superset of uploads).
        # Deletion tests narrow it via \$TEST_DIR/manifest_override.
        if [[ -f "$TEST_DIR/manifest_override" ]]; then
            cp "$TEST_DIR/manifest_override" "\$tmpd/.ralph_e2b_manifest"
        else
            { sed 's|^|./|' "$RALPH_DIR/.e2b_synced_files" 2>/dev/null; echo "./src/synced.txt"; } > "\$tmpd/.ralph_e2b_manifest"
        fi
        tar -czf - -C "\$tmpd" src/synced.txt .git/config .ralph_e2b_manifest
        rm -rf "\$tmpd"
        exit 0 ;;
    write-file)
        cat > "$TEST_DIR/seeded_credentials"
        echo '{"ok": true}'
        exit 0 ;;
    kill)
        if [[ "$mode" == "kill-fail" ]]; then
            echo '{"ok": false, "error": "kill failed"}'
            exit 1
        fi
        echo '{"ok": true}'
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python"
    export SANDBOX_E2B_PYTHON="$TEST_DIR/mock_bin/e2b-python"
}

_e2b_args() { cat "$TEST_DIR/e2b_args" 2>/dev/null; }

# Shorthand: a fully started sandbox (init + start) in ok mode
_started_sandbox() {
    _mock_e2b ok
    init_e2b_sandbox
    start_e2b_sandbox
}

# -----------------------------------------------------------------------------
# validate_e2b_sandbox_config
# -----------------------------------------------------------------------------

@test "validate_e2b_sandbox_config: accepts clean defaults" {
    run validate_e2b_sandbox_config
    assert_success
}

@test "validate_e2b_sandbox_config: rejects non-e2b provider" {
    export SANDBOX_PROVIDER="docker"
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"provider"* ]]
}

@test "validate_e2b_sandbox_config: rejects template with shell metacharacters" {
    export SANDBOX_E2B_TEMPLATE='evil;rm -rf /'
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"template"* ]]
}

@test "validate_e2b_sandbox_config: rejects malformed sandbox id" {
    export SANDBOX_E2B_SANDBOX_ID='bad id!'
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"sandbox id"* ]]
}

@test "validate_e2b_sandbox_config: rejects non-numeric timeout" {
    export SANDBOX_E2B_TIMEOUT="soon"
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"timeout"* ]]
}

@test "validate_e2b_sandbox_config: rejects zero timeout" {
    export SANDBOX_E2B_TIMEOUT="0"
    run validate_e2b_sandbox_config
    assert_failure
}

@test "validate_e2b_sandbox_config: rejects non-numeric max-cost" {
    export SANDBOX_E2B_MAX_COST="five dollars"
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"max-cost"* ]]
}

@test "validate_e2b_sandbox_config: accepts decimal cost limits" {
    export SANDBOX_E2B_MAX_COST="5.00"
    export SANDBOX_E2B_COST_ALERT="2.5"
    run validate_e2b_sandbox_config
    assert_success
}

@test "validate_e2b_sandbox_config: rejects non-numeric cost-alert" {
    export SANDBOX_E2B_COST_ALERT="lots"
    run validate_e2b_sandbox_config
    assert_failure
    [[ "$output" == *"cost-alert"* ]]
}

# -----------------------------------------------------------------------------
# e2b_is_available
# -----------------------------------------------------------------------------

@test "e2b_is_available: succeeds when helper check passes" {
    _mock_e2b ok
    run e2b_is_available
    assert_success
    [[ "$(_e2b_args)" == *"check"* ]]
}

@test "e2b_is_available: fails when python interpreter is missing" {
    export SANDBOX_E2B_PYTHON="$TEST_DIR/no/such/python"
    run e2b_is_available
    assert_failure
    [[ "$output" == *ython* ]]
}

@test "e2b_is_available: fails with install guidance when SDK is missing" {
    _mock_e2b no-sdk
    run e2b_is_available
    assert_failure
    [[ "$output" == *"pip install e2b"* ]]
}

# -----------------------------------------------------------------------------
# setup_e2b_credentials (E2B API key resolution)
# -----------------------------------------------------------------------------

@test "setup_e2b_credentials: uses E2B_API_KEY from environment" {
    run setup_e2b_credentials
    assert_success
    [[ "$output" == *"environment"* ]]
}

@test "setup_e2b_credentials: reads key file when env var unset" {
    unset E2B_API_KEY
    mkdir -p "$(dirname "$E2B_API_KEY_FILE")"
    ( umask 177 && echo "file-key-67890" > "$E2B_API_KEY_FILE" )
    setup_e2b_credentials
    [[ "$E2B_API_KEY" == "file-key-67890" ]]
}

@test "setup_e2b_credentials: warns on group/world-readable key file" {
    unset E2B_API_KEY
    mkdir -p "$(dirname "$E2B_API_KEY_FILE")"
    echo "file-key-67890" > "$E2B_API_KEY_FILE"
    chmod 644 "$E2B_API_KEY_FILE"
    run setup_e2b_credentials
    assert_success
    [[ "$output" == *"600"* ]]
}

@test "setup_e2b_credentials: env var takes precedence over key file" {
    mkdir -p "$(dirname "$E2B_API_KEY_FILE")"
    echo "file-key-67890" > "$E2B_API_KEY_FILE"
    setup_e2b_credentials
    [[ "$E2B_API_KEY" == "test-key-12345" ]]
}

@test "setup_e2b_credentials: fails with actionable message when no key anywhere" {
    unset E2B_API_KEY
    run setup_e2b_credentials
    assert_failure
    [[ "$output" == *"E2B_API_KEY"* ]]
    [[ "$output" == *"e2b_api_key"* ]]
}

# -----------------------------------------------------------------------------
# init_e2b_sandbox
# -----------------------------------------------------------------------------

@test "init_e2b_sandbox: writes initial state file" {
    _mock_e2b ok
    run init_e2b_sandbox
    assert_success
    assert_file_exists "$E2B_SANDBOX_STATE_FILE"
    assert_equal "$(jq -r '.provider' "$E2B_SANDBOX_STATE_FILE")" "e2b"
    assert_equal "$(jq -r '.template' "$E2B_SANDBOX_STATE_FILE")" "base"
    assert_equal "$(jq -r '.status' "$E2B_SANDBOX_STATE_FILE")" "initialized"
    assert_equal "$(jq -r '.sandbox_id' "$E2B_SANDBOX_STATE_FILE")" ""
}

@test "init_e2b_sandbox: fails on invalid config" {
    _mock_e2b ok
    export SANDBOX_E2B_TIMEOUT="never"
    run init_e2b_sandbox
    assert_failure
}

@test "init_e2b_sandbox: fails when no API key is available" {
    _mock_e2b ok
    unset E2B_API_KEY
    run init_e2b_sandbox
    assert_failure
    [[ "$output" == *"E2B_API_KEY"* ]]
}

@test "init_e2b_sandbox: fails when SDK is unavailable" {
    _mock_e2b no-sdk
    run init_e2b_sandbox
    assert_failure
}

# -----------------------------------------------------------------------------
# start_e2b_sandbox
# -----------------------------------------------------------------------------

@test "start_e2b_sandbox: creates sandbox with template and timeout" {
    _mock_e2b ok
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_success
    _e2b_args | grep -q '^create --template base --timeout 3600$'
}

@test "start_e2b_sandbox: records sandbox id, epoch, and running status" {
    _started_sandbox
    assert_equal "$(jq -r '.sandbox_id' "$E2B_SANDBOX_STATE_FILE")" "sbx_mock123"
    assert_equal "$(jq -r '.status' "$E2B_SANDBOX_STATE_FILE")" "running"
    [[ "$(jq -r '.created_epoch' "$E2B_SANDBOX_STATE_FILE")" =~ ^[0-9]+$ ]]
}

@test "start_e2b_sandbox: connects instead of creating when sandbox id is given" {
    _mock_e2b ok
    export SANDBOX_E2B_SANDBOX_ID="sbx_user42"
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_success
    _e2b_args | grep -q '^connect --sandbox-id sbx_user42$'
    [[ $(_e2b_args | grep -c '^create ') -eq 0 ]]
}

@test "start_e2b_sandbox: uploads the project after creation" {
    echo "content" > "$TEST_DIR/afile.txt"
    _started_sandbox
    _e2b_args | grep -q "^upload --sandbox-id sbx_mock123 --dest $SANDBOX_E2B_WORKDIR$"
    # the upload actually carried tar bytes
    [[ "$(cat "$TEST_DIR/upload_bytes" | tr -d '[:space:]')" -gt 0 ]]
}

@test "start_e2b_sandbox: fails hard when creation fails" {
    _mock_e2b create-fail
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_failure
    [[ "$output" == *"create"* ]]
}

@test "start_e2b_sandbox: fails hard when connect to given id fails" {
    _mock_e2b connect-fail
    export SANDBOX_E2B_SANDBOX_ID="sbx_gone"
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_failure
}

@test "start_e2b_sandbox: fails when upload fails" {
    _mock_e2b upload-fail
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_failure
}

@test "start_e2b_sandbox: seeds host claude credentials when no API key env" {
    mkdir -p "$HOME/.claude"
    echo '{"token": "host-secret"}' > "$HOME/.claude/.credentials.json"
    _started_sandbox
    _e2b_args | grep -q '^write-file --sandbox-id sbx_mock123 --path /home/user/.claude/.credentials.json --mode 600$'
    assert_equal "$(cat "$TEST_DIR/seeded_credentials")" '{"token": "host-secret"}'
}

@test "start_e2b_sandbox: skips credential seeding when ANTHROPIC_API_KEY is set" {
    export ANTHROPIC_API_KEY="sk-ant-test"
    mkdir -p "$HOME/.claude"
    echo '{"token": "host-secret"}' > "$HOME/.claude/.credentials.json"
    _started_sandbox
    [[ $(_e2b_args | grep -c '^write-file ') -eq 0 ]]
    # the helper saw the key via environment (never via argv)
    [[ -f "$TEST_DIR/saw_anthropic_env" ]]
    [[ $(_e2b_args | grep -c "sk-ant-test") -eq 0 ]]
}

# -----------------------------------------------------------------------------
# claude CLI bootstrap inside the sandbox
# -----------------------------------------------------------------------------

@test "start_e2b_sandbox: verifies claude CLI inside the sandbox" {
    _started_sandbox
    _e2b_args | grep -q -- '-- claude --version$'
}

@test "start_e2b_sandbox: bootstraps claude via npm when missing" {
    _mock_e2b no-claude
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_success
    _e2b_args | grep -q -- '-- npm install -g @anthropic-ai/claude-code$'
}

@test "start_e2b_sandbox: fails with template guidance when claude cannot be installed" {
    _mock_e2b no-claude-ever
    init_e2b_sandbox
    run start_e2b_sandbox
    assert_failure
    [[ "$output" == *"template"* ]]
}

# -----------------------------------------------------------------------------
# ensure_e2b_sandbox (liveness + recovery)
# -----------------------------------------------------------------------------

@test "ensure_e2b_sandbox: no-op when sandbox is running" {
    _started_sandbox
    rm -f "$TEST_DIR/e2b_args"
    run ensure_e2b_sandbox
    assert_success
    _e2b_args | grep -q '^info '
    [[ $(_e2b_args | grep -c '^create ') -eq 0 ]]
}

@test "ensure_e2b_sandbox: recreates and re-uploads when sandbox expired" {
    _started_sandbox
    rm -f "$TEST_DIR/e2b_args"
    # Sandbox dies (session timeout) — info now fails
    _mock_e2b sandbox-dead
    # Recreation must succeed: dead only for info, alive for create
    cat > "$TEST_DIR/mock_bin/e2b-python-dead-info" << EOF
#!/bin/bash
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    info) echo '{"ok": false, "error": "sandbox not found"}'; exit 1 ;;
    create) echo '{"ok": true, "sandbox_id": "sbx_fresh456"}'; exit 0 ;;
    upload) cat > /dev/null; echo '{"ok": true}'; exit 0 ;;
    exec) echo "2.0.0-mock"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python-dead-info"
    export SANDBOX_E2B_PYTHON="$TEST_DIR/mock_bin/e2b-python-dead-info"
    run ensure_e2b_sandbox
    assert_success
    _e2b_args | grep -q '^create '
    _e2b_args | grep -q '^upload --sandbox-id sbx_fresh456 '
    assert_equal "$(jq -r '.sandbox_id' "$E2B_SANDBOX_STATE_FILE")" "sbx_fresh456"
}

@test "ensure_e2b_sandbox: fails when no sandbox was ever started" {
    _mock_e2b ok
    init_e2b_sandbox
    run ensure_e2b_sandbox
    assert_failure
}

# -----------------------------------------------------------------------------
# build_e2b_exec_args
# -----------------------------------------------------------------------------

@test "build_e2b_exec_args: wraps command in helper exec with cwd" {
    _started_sandbox
    build_e2b_exec_args claude --output-format json -p "do things"
    assert_equal "${SANDBOX_EXEC_ARGS[0]}" "$SANDBOX_E2B_PYTHON"
    assert_equal "${SANDBOX_EXEC_ARGS[1]}" "$SANDBOX_E2B_HELPER"
    assert_equal "${SANDBOX_EXEC_ARGS[2]}" "exec"
    assert_equal "${SANDBOX_EXEC_ARGS[3]}" "--sandbox-id"
    assert_equal "${SANDBOX_EXEC_ARGS[4]}" "sbx_mock123"
    assert_equal "${SANDBOX_EXEC_ARGS[5]}" "--cwd"
    assert_equal "${SANDBOX_EXEC_ARGS[6]}" "$SANDBOX_E2B_WORKDIR"
    assert_equal "${SANDBOX_EXEC_ARGS[7]}" "--"
    assert_equal "${SANDBOX_EXEC_ARGS[8]}" "claude"
    # argument boundaries preserved (prompt with spaces stays one arg)
    assert_equal "${SANDBOX_EXEC_ARGS[12]}" "do things"
}

@test "build_e2b_exec_args: fails without a running sandbox" {
    _mock_e2b ok
    init_e2b_sandbox
    run build_e2b_exec_args claude -p "x"
    assert_failure
}

# -----------------------------------------------------------------------------
# sync_e2b_artifacts_down
# -----------------------------------------------------------------------------

@test "sync_e2b_artifacts_down: extracts changed files into the project" {
    _started_sandbox
    sync_e2b_artifacts_down
    assert_file_exists "src/synced.txt"
    assert_equal "$(cat src/synced.txt)" "from-sandbox"
}

@test "sync_e2b_artifacts_down: never extracts .git paths from the sandbox" {
    _started_sandbox
    sync_e2b_artifacts_down
    [[ ! -f ".git/config" ]]
}

@test "sync_e2b_artifacts_down: quiet no-op on empty download" {
    _mock_e2b download-empty
    init_e2b_sandbox
    start_e2b_sandbox
    run sync_e2b_artifacts_down
    assert_success
    [[ ! -f "src/synced.txt" ]]
}

@test "sync_e2b_artifacts_down: warns and fails on download error" {
    _mock_e2b download-fail
    init_e2b_sandbox
    start_e2b_sandbox
    run sync_e2b_artifacts_down
    assert_failure
}

@test "sync_e2b_artifacts_down: no-op when sandbox was never started" {
    _mock_e2b ok
    run sync_e2b_artifacts_down
    assert_success
}

@test "sync_e2b_artifacts_down: never extracts the manifest member into the project" {
    _started_sandbox
    sync_e2b_artifacts_down
    [[ ! -f ".ralph_e2b_manifest" ]]
}

@test "sync_e2b_artifacts_down: deletes host files removed in the sandbox" {
    _started_sandbox
    # src/obsolete.txt was previously synced/uploaded but is gone from the
    # sandbox manifest — a sandbox-side deletion must propagate to the host
    mkdir -p src && echo "stale" > src/obsolete.txt
    printf '%s\n' "src/obsolete.txt" "src/synced.txt" > "$RALPH_DIR/.e2b_synced_files"
    printf '%s\n' "./src/synced.txt" > "$TEST_DIR/manifest_override"
    sync_e2b_artifacts_down
    [[ ! -f "src/obsolete.txt" ]]
    assert_file_exists "src/synced.txt"
}

@test "sync_e2b_artifacts_down: rename leaves no stale file behind" {
    _started_sandbox
    # The sandbox renamed old_name.txt -> synced.txt: manifest only lists the
    # new name, so the host copy of the old name must be removed
    mkdir -p src && echo "old" > src/old_name.txt
    printf '%s\n' "src/old_name.txt" > "$RALPH_DIR/.e2b_synced_files"
    printf '%s\n' "./src/synced.txt" > "$TEST_DIR/manifest_override"
    sync_e2b_artifacts_down
    [[ ! -f "src/old_name.txt" ]]
    assert_equal "$(cat src/synced.txt)" "from-sandbox"
}

@test "sync_e2b_artifacts_down: host-only files are never deleted" {
    _started_sandbox
    mkdir -p src && echo "host work" > src/host_only.txt   # never synced
    printf '%s\n' "src/something_else.txt" > "$RALPH_DIR/.e2b_synced_files"
    sync_e2b_artifacts_down
    assert_file_exists "src/host_only.txt"
}

@test "sync_e2b_artifacts_down: refuses to delete .git or .ralph paths even if state is poisoned" {
    _started_sandbox
    mkdir -p .git
    echo "ref: refs/heads/main" > .git/HEAD
    echo "keep" > "$RALPH_DIR/fix_plan.md"
    printf '%s\n' ".git/HEAD" ".ralph/fix_plan.md" "/etc/passwd" "../escape.txt" > "$RALPH_DIR/.e2b_synced_files"
    printf '%s\n' "./src/synced.txt" > "$TEST_DIR/manifest_override"
    sync_e2b_artifacts_down
    assert_file_exists ".git/HEAD"
    assert_file_exists "$RALPH_DIR/fix_plan.md"
}

@test "sync_e2b_artifacts_down: updates the synced-files state to the manifest" {
    _started_sandbox
    sync_e2b_artifacts_down
    grep -qxF "src/synced.txt" "$RALPH_DIR/.e2b_synced_files"
}

@test "sync_e2b_artifacts_down: tolerates archives without a manifest (no deletions)" {
    _mock_e2b download-empty
    init_e2b_sandbox
    start_e2b_sandbox
    mkdir -p src && echo "keep" > src/keep.txt
    printf '%s\n' "src/keep.txt" > "$RALPH_DIR/.e2b_synced_files"
    run sync_e2b_artifacts_down
    assert_success
    assert_file_exists "src/keep.txt"
}

@test "sync_e2b_artifacts_down: acks the download only after successful extraction" {
    _started_sandbox
    rm -f "$TEST_DIR/e2b_args"
    sync_e2b_artifacts_down
    # ack-download must follow the download (marker advances only post-extract)
    local calls
    calls=$(grep -oE "^(download|ack-download)" "$TEST_DIR/e2b_args" | paste -sd, -)
    assert_equal "$calls" "download,ack-download"
}

@test "sync_e2b_artifacts_down: failed download is never acked (retry stays possible)" {
    _mock_e2b download-fail
    init_e2b_sandbox
    start_e2b_sandbox
    rm -f "$TEST_DIR/e2b_args"
    run sync_e2b_artifacts_down
    assert_failure
    [[ $(_e2b_args | grep -c '^ack-download ') -eq 0 ]]
}

@test "e2b_helper.py: ack-download requires a sandbox id" {
    command -v python3 > /dev/null || skip "python3 not available"
    run python3 "$PROJECT_ROOT/lib/e2b_helper.py" ack-download
    assert_failure
}

@test "upload_project_to_e2b: initializes the synced-files state from the upload list" {
    echo "content" > "$TEST_DIR/tracked.txt"
    _started_sandbox
    assert_file_exists "$RALPH_DIR/.e2b_synced_files"
    grep -qxF "tracked.txt" "$RALPH_DIR/.e2b_synced_files"
}

@test "upload_project_to_e2b: never uploads ralph state files" {
    # Internal state must not reach the sandbox: a sandbox-side write could
    # otherwise sync back over the host's control state
    echo '{"provider":"e2b"}' > "$RALPH_DIR/.fake_state_probe"
    echo '{"status":"x"}' > "$RALPH_DIR/status.json"
    echo "keep me" > "$RALPH_DIR/fix_plan.md"
    _started_sandbox
    [[ $(grep -c "fake_state_probe" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
    [[ $(grep -c "status.json" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
    # ...while the allowlisted control files still upload
    grep -q "fix_plan.md" "$RALPH_DIR/.e2b_synced_files"
}

@test "sync_e2b_artifacts_down: never overwrites ralph state files from the sandbox" {
    _started_sandbox
    # Malicious/buggy sandbox content targeting host control state
    cat > "$TEST_DIR/mock_bin/e2b-python" << EOF
#!/bin/bash
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    download)
        tmpd=\$(mktemp -d); mkdir -p "\$tmpd/.ralph"
        echo '{"provider":"evil"}' > "\$tmpd/.ralph/.e2b_sandbox_state"
        echo 'evil-status' > "\$tmpd/.ralph/status.json"
        printf '%s\n' "./.ralph/.e2b_sandbox_state" "./.ralph/status.json" > "\$tmpd/.ralph_e2b_manifest"
        tar -czf - -C "\$tmpd" .ralph/.e2b_sandbox_state .ralph/status.json .ralph_e2b_manifest
        rm -rf "\$tmpd"; exit 0 ;;
    ack-download) echo '{"ok": true}'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python"
    sync_e2b_artifacts_down
    # The host state file still names the real provider, not "evil"
    assert_equal "$(jq -r '.provider' "$E2B_SANDBOX_STATE_FILE")" "e2b"
    [[ ! -f "$RALPH_DIR/status.json" || "$(cat "$RALPH_DIR/status.json")" != "evil-status" ]]
}

@test "cleanup_e2b_sandbox: warns when the sandbox kill fails" {
    _started_sandbox
    _mock_e2b kill-fail
    run cleanup_e2b_sandbox
    assert_success
    [[ "$output" == *"Failed to kill"* ]]
}

# -----------------------------------------------------------------------------
# cost tracking
# -----------------------------------------------------------------------------

# Pin the sandbox start time N seconds into the past
_age_sandbox() {
    local seconds=$1
    local past=$(( $(date +%s) - seconds ))
    local tmp
    tmp=$(mktemp)
    jq --argjson e "$past" '.created_epoch = $e' "$E2B_SANDBOX_STATE_FILE" > "$tmp"
    mv "$tmp" "$E2B_SANDBOX_STATE_FILE"
}

@test "update_e2b_cost: estimates elapsed runtime times hourly rate" {
    _started_sandbox
    _age_sandbox 7200   # 2 hours at $0.10/h
    local cost
    cost=$(update_e2b_cost)
    assert_equal "$cost" "0.2000"
    assert_equal "$(jq -r '.estimated_cost' "$E2B_SANDBOX_STATE_FILE")" "0.2000"
}

@test "check_e2b_cost_limits: passes when no limit configured" {
    _started_sandbox
    _age_sandbox 7200
    run check_e2b_cost_limits
    assert_success
}

@test "check_e2b_cost_limits: passes below the max-cost limit" {
    export SANDBOX_E2B_MAX_COST="5.00"
    _started_sandbox
    _age_sandbox 7200
    run check_e2b_cost_limits
    assert_success
}

@test "check_e2b_cost_limits: fails once estimated cost reaches max-cost" {
    export SANDBOX_E2B_MAX_COST="0.15"
    _started_sandbox
    _age_sandbox 7200
    run check_e2b_cost_limits
    assert_failure
    [[ "$output" == *"cost limit"* ]]
}

@test "check_e2b_cost_limits: warns once at the alert threshold" {
    export SANDBOX_E2B_COST_ALERT="0.10"
    _started_sandbox
    _age_sandbox 7200
    run check_e2b_cost_limits
    assert_success
    [[ "$output" == *"cost alert"* ]]
    # Second call: alert already fired, no repeat
    run check_e2b_cost_limits
    assert_success
    [[ "$output" != *"cost alert"* ]]
}

@test "check_e2b_cost_limits: no-op for non-e2b providers" {
    export SANDBOX_PROVIDER="docker"
    run check_e2b_cost_limits
    assert_success
}

@test "update_e2b_cost: cost accrued before a sandbox recreation is preserved" {
    _started_sandbox
    _age_sandbox 7200            # $0.20 spent on the first sandbox
    start_e2b_sandbox            # replacement (e.g. after expiry) resets the epoch
    _age_sandbox 3600            # $0.10 on the replacement
    local cost
    cost=$(update_e2b_cost)
    assert_equal "$cost" "0.3000"
}

@test "update_e2b_cost: persists accrued-only cost while no sandbox is active" {
    _started_sandbox
    _age_sandbox 7200            # $0.20 on the first sandbox
    start_e2b_sandbox            # folds $0.20 into accrued_cost
    # Simulate the no-active-sandbox window (epoch cleared)
    local tmp
    tmp=$(mktemp)
    jq '.created_epoch = 0' "$E2B_SANDBOX_STATE_FILE" > "$tmp"
    mv "$tmp" "$E2B_SANDBOX_STATE_FILE"
    local cost
    cost=$(update_e2b_cost)
    assert_equal "$cost" "0.2000"
    assert_equal "$(jq -r '.estimated_cost' "$E2B_SANDBOX_STATE_FILE")" "0.2000"
}

@test "check_e2b_cost_limits: max-cost spans sandbox replacements" {
    export SANDBOX_E2B_MAX_COST="0.15"
    _started_sandbox
    _age_sandbox 7200            # $0.20 already spent
    start_e2b_sandbox            # fresh sandbox: runtime resets, spend must not
    run check_e2b_cost_limits
    assert_failure
    [[ "$output" == *"cost limit"* ]]
}

# -----------------------------------------------------------------------------
# handle_e2b_sandbox_timeout
# -----------------------------------------------------------------------------

@test "handle_e2b_sandbox_timeout: kills orphaned claude in the sandbox" {
    _started_sandbox
    rm -f "$TEST_DIR/e2b_args"
    run handle_e2b_sandbox_timeout
    assert_success
    _e2b_args | grep -q -- '-- pkill -f claude$'
}

@test "handle_e2b_sandbox_timeout: no-op without a sandbox" {
    _mock_e2b ok
    run handle_e2b_sandbox_timeout
    assert_success
}

# -----------------------------------------------------------------------------
# cleanup_e2b_sandbox
# -----------------------------------------------------------------------------

@test "cleanup_e2b_sandbox: syncs artifacts, kills sandbox, marks state cleaned" {
    _started_sandbox
    rm -f "$TEST_DIR/e2b_args"
    run cleanup_e2b_sandbox
    assert_success
    _e2b_args | grep -q '^download '
    _e2b_args | grep -q '^kill --sandbox-id sbx_mock123$'
    assert_equal "$(jq -r '.status' "$E2B_SANDBOX_STATE_FILE")" "cleaned"
    assert_equal "$(jq -r '.sandbox_id' "$E2B_SANDBOX_STATE_FILE")" ""
}

@test "cleanup_e2b_sandbox: idempotent — second call does not kill again" {
    _started_sandbox
    cleanup_e2b_sandbox
    rm -f "$TEST_DIR/e2b_args"
    run cleanup_e2b_sandbox
    assert_success
    [[ $(_e2b_args | grep -c '^kill ') -eq 0 ]]
}

@test "cleanup_e2b_sandbox: keep-alive skips the kill and reports reuse hint" {
    export SANDBOX_E2B_KEEP_ALIVE="true"
    _started_sandbox
    run cleanup_e2b_sandbox
    assert_success
    [[ $(_e2b_args | grep -c '^kill ') -eq 0 ]]
    [[ "$output" == *"sbx_mock123"* ]]
    assert_equal "$(jq -r '.status' "$E2B_SANDBOX_STATE_FILE")" "kept_alive"
}

@test "cleanup_e2b_sandbox: appends a cost summary line to the cost log" {
    _started_sandbox
    _age_sandbox 7200
    cleanup_e2b_sandbox
    assert_file_exists "$LOG_DIR/e2b_cost.log"
    grep -q 'sbx_mock123' "$LOG_DIR/e2b_cost.log"
    grep -q '0.2000' "$LOG_DIR/e2b_cost.log"
}

@test "cleanup_e2b_sandbox: safe to call before init" {
    _mock_e2b ok
    run cleanup_e2b_sandbox
    assert_success
}

# -----------------------------------------------------------------------------
# get_e2b_sandbox_status + provider routing
# -----------------------------------------------------------------------------

@test "get_e2b_sandbox_status: emits provider, sandbox_id, status, cost" {
    _started_sandbox
    run get_e2b_sandbox_status
    assert_success
    echo "$output" | jq -e . > /dev/null
    assert_equal "$(echo "$output" | jq -r '.provider')" "e2b"
    assert_equal "$(echo "$output" | jq -r '.sandbox_id')" "sbx_mock123"
    assert_equal "$(echo "$output" | jq -r '.status')" "running"
}

@test "get_e2b_sandbox_status: reports none when never initialized" {
    run get_e2b_sandbox_status
    assert_equal "$(echo "$output" | jq -r '.provider')" "none"
}

@test "get_sandbox_status router: dispatches to e2b when provider is e2b" {
    # The router lives in lib/sandbox_docker.sh; both libs sourced like ralph_loop.sh
    export DOCKER_SANDBOX_STATE_FILE="$RALPH_DIR/.docker_sandbox_state"
    source "$PROJECT_ROOT/lib/sandbox_docker.sh"
    source "$PROJECT_ROOT/lib/sandbox_e2b.sh"
    export SANDBOX_PROVIDER="e2b"
    _started_sandbox
    run get_sandbox_status
    assert_equal "$(echo "$output" | jq -r '.provider')" "e2b"
    assert_equal "$(echo "$output" | jq -r '.sandbox_id')" "sbx_mock123"
}

# -----------------------------------------------------------------------------
# e2b_helper.py CLI surface (no SDK required — argument/JSON contract only)
# -----------------------------------------------------------------------------

@test "e2b_helper.py: check emits machine-readable JSON" {
    command -v python3 > /dev/null || skip "python3 not available"
    run python3 "$PROJECT_ROOT/lib/e2b_helper.py" check
    echo "$output" | jq -e 'has("ok")' > /dev/null
}

@test "e2b_helper.py: create without E2B_API_KEY fails with JSON error" {
    command -v python3 > /dev/null || skip "python3 not available"
    unset E2B_API_KEY
    run python3 "$PROJECT_ROOT/lib/e2b_helper.py" create --template base --timeout 60
    assert_failure
    echo "$output" | jq -e '.ok == false' > /dev/null
}

@test "e2b_helper.py: exec requires a sandbox id" {
    command -v python3 > /dev/null || skip "python3 not available"
    run python3 "$PROJECT_ROOT/lib/e2b_helper.py" exec -- echo hi
    assert_failure
}

@test "e2b_helper.py: unknown subcommand fails" {
    command -v python3 > /dev/null || skip "python3 not available"
    run python3 "$PROJECT_ROOT/lib/e2b_helper.py" frobnicate
    assert_failure
}

# -----------------------------------------------------------------------------
# Issue #76: sync filtering (lib/sync.sh integration)
# -----------------------------------------------------------------------------

@test "issue #76: upload respects .ralphignore patterns" {
    printf '*.secret\n' > .ralphignore
    echo "keep" > keep.txt
    echo "creds" > probe.secret
    _started_sandbox
    grep -qxF "keep.txt" "$RALPH_DIR/.e2b_synced_files"
    [[ $(grep -c "probe.secret" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
}

@test "issue #76: upload respects SYNC_EXCLUDE patterns" {
    export SYNC_EXCLUDE="*.log,vendor"
    echo "keep" > keep.txt
    echo "noise" > debug.log
    mkdir -p vendor && echo "dep" > vendor/dep.js
    _started_sandbox
    grep -qxF "keep.txt" "$RALPH_DIR/.e2b_synced_files"
    [[ $(grep -c "debug.log" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
    [[ $(grep -c "vendor/dep.js" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
}

@test "issue #76: SYNC_INCLUDE restricts the upload but control files still go" {
    export SYNC_INCLUDE="src/**"
    mkdir -p src && echo "code" > src/a.sh
    echo "stray" > other.txt
    echo "plan" > "$RALPH_DIR/fix_plan.md"
    _started_sandbox
    grep -qxF "src/a.sh" "$RALPH_DIR/.e2b_synced_files"
    [[ $(grep -c "other.txt" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
    # .ralph control files are force-included past any include filter
    grep -q "fix_plan.md" "$RALPH_DIR/.e2b_synced_files"
}

@test "issue #76: upload skips oversized files with SYNC_LARGE_FILE_ACTION=skip" {
    export SYNC_MAX_FILE_SIZE="1024"
    export SYNC_LARGE_FILE_ACTION="skip"
    head -c 4096 /dev/zero > huge.bin
    echo "small" > small.txt
    _started_sandbox
    grep -qxF "small.txt" "$RALPH_DIR/.e2b_synced_files"
    [[ $(grep -c "huge.bin" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
}

@test "issue #76: upload logs a progress summary with file count and size" {
    echo "content" > tracked.txt
    _started_sandbox
    run upload_project_to_e2b
    assert_success
    [[ "$output" == *"Uploading"* ]]
    [[ "$output" == *"file(s)"* ]]
    [[ "$output" =~ [0-9](\.[0-9])?(B|KB|MB|GB) ]]
}

@test "issue #76: download extraction filters SYNC_EXCLUDE patterns" {
    _started_sandbox
    export SYNC_EXCLUDE="*.txt"
    sync_e2b_artifacts_down
    # default ok-mock download delivers src/synced.txt — must be filtered out
    [[ ! -f src/synced.txt ]]
}

@test "issue #76: download extraction filters .ralphignore patterns" {
    _started_sandbox
    printf 'synced.txt\n' > .ralphignore
    sync_e2b_artifacts_down
    [[ ! -f src/synced.txt ]]
}

@test "issue #76: download-filtered files never enter the deletion baseline" {
    _started_sandbox
    export SYNC_EXCLUDE="*.txt"
    sync_e2b_artifacts_down
    # src/synced.txt is in the sandbox manifest but was filtered from
    # extraction — recording it would make a same-named host file a
    # deletion candidate the moment the sandbox removes its copy
    [[ $(grep -c "src/synced.txt" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
}

@test "issue #76: excluded host files are never deleted by deletion sync" {
    _started_sandbox
    # Manifest = everything currently synced plus the new sandbox file,
    # but WITHOUT noise.log (the sandbox no longer has it)
    { sed 's|^|./|' "$RALPH_DIR/.e2b_synced_files"; echo "./src/synced.txt"; } > "$TEST_DIR/manifest_override"
    # Poisoned baseline: noise.log was synced before the user added *.log
    # to SYNC_EXCLUDE
    echo "noise.log" >> "$RALPH_DIR/.e2b_synced_files"
    echo "host data" > noise.log
    export SYNC_EXCLUDE="*.log"
    sync_e2b_artifacts_down
    [[ -f noise.log ]]
    assert_equal "$(cat noise.log)" "host data"
}

@test "issue #76: download logs a sync summary with file count and size" {
    _started_sandbox
    run sync_e2b_artifacts_down
    assert_success
    [[ "$output" == *"Synced 1 changed file(s)"* ]]
    [[ "$output" =~ [0-9](\.[0-9])?(B|KB|MB|GB) ]]
}

@test "issue #76: download logs how many files the sync patterns filtered" {
    _started_sandbox
    export SYNC_EXCLUDE="*.txt"
    run sync_e2b_artifacts_down
    assert_success
    [[ "$output" == *"Filtered 1 file(s)"* ]]
}

@test "issue #76: member classification honors a non-default RALPH_DIR" {
    # The upload side derives the control-dir basename from RALPH_DIR;
    # the download-side classifiers must do the same (claude-review, PR #305)
    export RALPH_DIR="$TEST_DIR/.customralph"
    _e2b_member_hard_excluded ".customralph/status.json"
    _e2b_member_hard_excluded "./.customralph/.e2b_sandbox_state"
    _e2b_member_control_file ".customralph/fix_plan.md"
    _e2b_member_control_file "./.customralph/specs/feature.md"
    # With a custom control dir, a plain .ralph path is ordinary project
    # content — neither protected nor force-included
    run _e2b_member_hard_excluded ".ralph/status.json"
    assert_failure
    run _e2b_member_control_file ".ralph/fix_plan.md"
    assert_failure
}

@test "issue #76: download force-includes .ralph control files past user patterns" {
    # A broad user pattern (*.md) must not drop Claude's plan/prompt updates
    # on download — mirror of the upload allowlist (claude-review P3)
    _started_sandbox
    export SYNC_EXCLUDE="*.md"
    cat > "$TEST_DIR/mock_bin/e2b-python" << EOF
#!/bin/bash
shift
printf '%s\n' "\$*" >> "$TEST_DIR/e2b_args"
case "\$1" in
    download)
        tmpd=\$(mktemp -d); mkdir -p "\$tmpd/.ralph" "\$tmpd/docs"
        echo 'updated plan' > "\$tmpd/.ralph/fix_plan.md"
        echo 'generic doc' > "\$tmpd/docs/notes.md"
        printf '%s\n' "./.ralph/fix_plan.md" "./docs/notes.md" > "\$tmpd/.ralph_e2b_manifest"
        tar -czf - -C "\$tmpd" .ralph/fix_plan.md docs/notes.md .ralph_e2b_manifest
        rm -rf "\$tmpd"; exit 0 ;;
    ack-download) echo '{"ok": true}'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/mock_bin/e2b-python"
    sync_e2b_artifacts_down
    # Control file extracted despite matching *.md...
    assert_equal "$(cat "$RALPH_DIR/fix_plan.md")" "updated plan"
    # ...while the generic .md artifact is filtered as configured
    [[ ! -f docs/notes.md ]]
    # Baseline keeps the control file (it IS synced) but not the filtered doc
    grep -qxF ".ralph/fix_plan.md" "$RALPH_DIR/.e2b_synced_files"
    [[ $(grep -c "docs/notes.md" "$RALPH_DIR/.e2b_synced_files") -eq 0 ]]
}
