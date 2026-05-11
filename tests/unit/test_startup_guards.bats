#!/usr/bin/env bats
# TAP-779: Startup guards — Ralph must fail fast with exit 1 when PROMPT.md
# is missing, BEFORE expensive startup work (MCP probes, version checks,
# instance lock acquisition).

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
RALPH_SCRIPT="${PROJECT_ROOT}/ralph_loop.sh"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

@test "ralph exits with code 1 when .ralph/PROMPT.md is missing" {
    mkdir -p .ralph/logs
    run bash "$RALPH_SCRIPT"
    assert_failure
    [ "$status" -eq 1 ]
}

@test "missing PROMPT.md error message mentions the file path" {
    mkdir -p .ralph/logs
    run bash "$RALPH_SCRIPT"
    [[ "$output" == *"PROMPT.md"* ]]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"missing"* ]]
}

@test "missing PROMPT.md detects partial Ralph project via fix_plan.md" {
    mkdir -p .ralph/logs
    touch .ralph/fix_plan.md
    run bash "$RALPH_SCRIPT"
    assert_failure
    [[ "$output" == *"Ralph project"* ]]
    [[ "$output" == *"missing .ralph/PROMPT.md"* ]]
}

@test "missing PROMPT.md suggests ralph-enable / ralph-setup" {
    mkdir -p .ralph/logs
    run bash "$RALPH_SCRIPT"
    assert_failure
    [[ "$output" == *"ralph-enable"* ]]
    [[ "$output" == *"ralph-setup"* ]]
}

@test "old flat structure (root PROMPT.md, no .ralph/) triggers migration error" {
    touch PROMPT.md
    run bash "$RALPH_SCRIPT"
    assert_failure
    [[ "$output" == *"flat structure"* ]]
    [[ "$output" == *"ralph-migrate"* ]]
}

@test "PROMPT.md check fires in --dry-run mode" {
    mkdir -p .ralph/logs
    run bash "$RALPH_SCRIPT" --dry-run
    assert_failure
    [ "$status" -eq 1 ]
    [[ "$output" == *"PROMPT.md"* ]]
}

@test "PROMPT.md check fires before MCP probes (fail-fast ordering)" {
    # Verify the check is early enough in main() that a missing file
    # short-circuits before ralph_probe_mcp_servers runs. We proxy this
    # by asserting the startup never logs the "MCP probe" success/failure
    # lines when PROMPT.md is absent.
    mkdir -p .ralph/logs
    run bash "$RALPH_SCRIPT"
    assert_failure
    [[ "$output" != *"MCP probe"* ]]
    [[ "$output" != *"Probing MCP"* ]]
}

@test "PROMPT.md check precedes acquire_instance_lock in main()" {
    # Source-level assertion: in ralph_loop.sh main(), the PROMPT_FILE
    # check must appear before the call to acquire_instance_lock.
    local main_start main_end
    main_start=$(grep -n '^main() {' "$RALPH_SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$main_start" ]
    main_end=$(awk -v s="$main_start" 'NR > s && /^}/ { print NR; exit }' "$RALPH_SCRIPT")
    [ -n "$main_end" ]

    local prompt_line lock_line
    prompt_line=$(awk -v s="$main_start" -v e="$main_end" \
        'NR >= s && NR <= e && /\[\[ ! -f "\$PROMPT_FILE" \]\]/ { print NR; exit }' "$RALPH_SCRIPT")
    lock_line=$(awk -v s="$main_start" -v e="$main_end" \
        'NR >= s && NR <= e && /acquire_instance_lock/ { print NR; exit }' "$RALPH_SCRIPT")

    [ -n "$prompt_line" ]
    [ -n "$lock_line" ]
    [ "$prompt_line" -lt "$lock_line" ]
}

@test "ralph-doctor heredoc includes project-files section" {
    # TAP-779 AC #2: doctor reports PROMPT.md when absent. The doctor is
    # generated inline in install.sh; verify the project-files probe is
    # present in the heredoc.
    grep -q "Project files" "$INSTALL_SCRIPT"
    grep -q '.ralph/PROMPT.md' "$INSTALL_SCRIPT"
}

@test "ralph-doctor flags missing PROMPT.md in a Ralph-shaped directory" {
    # Extract and run the doctor script body against the test dir.
    local doctor_script
    doctor_script="$TEST_DIR/ralph-doctor"
    awk '/ralph-doctor.*DOCTOREOF/ {flag=1; next} /^DOCTOREOF$/ {flag=0} flag' \
        "$INSTALL_SCRIPT" > "$doctor_script"
    chmod +x "$doctor_script"
    mkdir -p .ralph
    touch .ralph/fix_plan.md
    run bash "$doctor_script"
    [[ "$output" == *"PROMPT.md"* ]]
    [[ "$output" == *"MISSING"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "ralph-doctor flags missing TAP-1530 coordinator guard in project on-stop.sh" {
    local doctor_script
    doctor_script="$TEST_DIR/ralph-doctor"
    awk '/ralph-doctor.*DOCTOREOF/ {flag=1; next} /^DOCTOREOF$/ {flag=0} flag' \
        "$INSTALL_SCRIPT" > "$doctor_script"
    chmod +x "$doctor_script"
    mkdir -p .ralph/hooks
    # Stale on-stop.sh missing the guard string.
    cat > .ralph/hooks/on-stop.sh <<'EOF'
#!/bin/bash
# old version, no TAP-1530 guard
exit 0
EOF
    chmod +x .ralph/hooks/on-stop.sh
    run bash "$doctor_script"
    [[ "$output" == *"TAP-1530"* ]]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"ralph-upgrade"* ]]
}

@test "TAP-1532: doctor FAIL/WARN messages name ralph-upgrade-project (not bare ralph-upgrade)" {
    # ralph-upgrade refreshes ~/.ralph/templates/ and ~/.local/bin/ only —
    # it does NOT sync per-repo .ralph/hooks/. The remediation text in the
    # drift WARN, the TAP-1530 FAIL, and the TAP-1531 FAIL must point users
    # at ralph-upgrade-project, which is what actually copies the new
    # template into a managed repo. Regression guard for the 2.14.2 issue
    # where re-running 'ralph-upgrade' three times produced zero convergence
    # because the diagnostic named the wrong command.
    local doctor_script
    doctor_script="$TEST_DIR/ralph-doctor"
    awk '/ralph-doctor.*DOCTOREOF/ {flag=1; next} /^DOCTOREOF$/ {flag=0} flag' \
        "$INSTALL_SCRIPT" > "$doctor_script"

    # All three remediation lines must reference ralph-upgrade-project.
    # We grep the extracted doctor script (not the install.sh heredoc) so
    # the test catches drift in either the source or the install path.
    grep -q "ralph-upgrade-project" "$doctor_script" \
        || fail "doctor script missing ralph-upgrade-project remediation"

    # And ensure none of the three FAIL/WARN paths use the bare
    # 'ralph-upgrade' form as the remediation verb. We allow the literal
    # 'ralph-upgrade' to appear *as part of* 'ralph-upgrade-project' or in
    # an explanatory aside; what we reject is a bare "Run 'ralph-upgrade'"
    # or "re-run 'ralph-upgrade' to sync" style instruction.
    ! grep -qE "Run 'ralph-upgrade'[^-]" "$doctor_script" \
        || fail "doctor script still names bare ralph-upgrade as remediation"
    ! grep -qE "re-run 'ralph-upgrade' to sync" "$doctor_script" \
        || fail "doctor drift WARN still says re-run ralph-upgrade"
}

@test "ralph-doctor reports OK when on-stop.sh has the TAP-1530 guard" {
    local doctor_script
    doctor_script="$TEST_DIR/ralph-doctor"
    awk '/ralph-doctor.*DOCTOREOF/ {flag=1; next} /^DOCTOREOF$/ {flag=0} flag' \
        "$INSTALL_SCRIPT" > "$doctor_script"
    chmod +x "$doctor_script"
    mkdir -p .ralph/hooks
    cat > .ralph/hooks/on-stop.sh <<'EOF'
#!/bin/bash
if [[ "${RALPH_COORDINATOR_INVOCATION:-}" == "1" ]]; then exit 0; fi
exit 0
EOF
    chmod +x .ralph/hooks/on-stop.sh
    run bash "$doctor_script"
    [[ "$output" == *"TAP-1530"* ]]
    [[ "$output" == *"OK"* ]]
}

@test "ralph-doctor reports OK when PROMPT.md is present and non-empty" {
    local doctor_script
    doctor_script="$TEST_DIR/ralph-doctor"
    awk '/ralph-doctor.*DOCTOREOF/ {flag=1; next} /^DOCTOREOF$/ {flag=0} flag' \
        "$INSTALL_SCRIPT" > "$doctor_script"
    chmod +x "$doctor_script"
    mkdir -p .ralph
    echo "Task instructions here" > .ralph/PROMPT.md
    touch .ralph/fix_plan.md
    run bash "$doctor_script"
    [[ "$output" == *".ralph/PROMPT.md"* ]]
    [[ "$output" == *"present"* ]] || [[ "$output" == *"OK"* ]]
}
