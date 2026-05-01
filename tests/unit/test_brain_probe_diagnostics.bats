#!/usr/bin/env bats
# TAP-1105: Regression test for ralph_diagnose_brain_probe_failure().
#
# Locks in the diagnostic-message contract operators rely on when the
# tapps-brain MCP probe fails. Three branches:
#   - container reachable + auth fails -> surface bearer-token hint
#   - container unreachable             -> surface "container appears down" hint
#   - unexpected HTTP status            -> surface raw code + container-logs hint
#
# Slices the function out of ralph_loop.sh and mocks `curl` via PATH
# injection so we don't need the real brain container running.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    # Slice the diagnostic function out of ralph_loop.sh.
    local slice="$TEST_TEMP_DIR/_diagnose_slice.sh"
    awk '/^ralph_diagnose_brain_probe_failure\(\) \{/,/^\}/' "$RALPH_LOOP_SH" > "$slice"

    # Capturing log_status stub — appends every call to a log file we can grep.
    cat > "$TEST_TEMP_DIR/_log_stub.sh" <<'EOF'
log_status() {
    local level="$1"; shift
    printf '%s %s\n' "$level" "$*" >> "$LOG_FILE"
}
EOF

    export LOG_FILE="$TEST_TEMP_DIR/log.txt"
    : > "$LOG_FILE"

    # shellcheck disable=SC1090
    source "$TEST_TEMP_DIR/_log_stub.sh"
    # shellcheck disable=SC1090
    source "$slice"

    declare -F ralph_diagnose_brain_probe_failure >/dev/null \
        || skip "ralph_diagnose_brain_probe_failure not defined after source"

    # PATH-shadow `curl` with a script that prints whatever HTTP code we
    # set in CURL_MOCK_CODE. The function uses `-w "%{http_code}"` so we
    # only need to print the code on stdout.
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/bin/bash
printf '%s' "${CURL_MOCK_CODE:-000}"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "TAP-1105: 200 surfaces bearer-token-likely-missing-or-wrong hint" {
    export CURL_MOCK_CODE="200"
    unset TAPPS_BRAIN_AUTH_TOKEN
    ralph_diagnose_brain_probe_failure
    grep -q 'NOT reachable' "$LOG_FILE"
    grep -q 'bearer token is likely missing or wrong' "$LOG_FILE"
}

@test "TAP-1105: 200 + token unset advises adding it to secrets.env" {
    export CURL_MOCK_CODE="200"
    unset TAPPS_BRAIN_AUTH_TOKEN
    ralph_diagnose_brain_probe_failure
    grep -q 'TAPPS_BRAIN_AUTH_TOKEN is not set' "$LOG_FILE"
    grep -q 'secrets.env' "$LOG_FILE"
}

@test "TAP-1105: 200 + token set advises verifying it matches container" {
    export CURL_MOCK_CODE="200"
    export TAPPS_BRAIN_AUTH_TOKEN="some-stale-value"
    ralph_diagnose_brain_probe_failure
    grep -q 'TAPPS_BRAIN_AUTH_TOKEN is set' "$LOG_FILE"
    grep -q 'verify it matches' "$LOG_FILE"
}

@test "TAP-1105: 000 (unreachable) surfaces 'container appears to be down' hint" {
    export CURL_MOCK_CODE="000"
    ralph_diagnose_brain_probe_failure
    grep -q 'container appears to be down' "$LOG_FILE"
    grep -q 'docker ps' "$LOG_FILE"
}

@test "TAP-1105: unexpected HTTP code surfaces raw code + container-logs hint" {
    export CURL_MOCK_CODE="500"
    ralph_diagnose_brain_probe_failure
    grep -q 'HTTP 500' "$LOG_FILE"
    grep -q 'check the brain container logs' "$LOG_FILE"
}
