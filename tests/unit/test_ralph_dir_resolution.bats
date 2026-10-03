#!/usr/bin/env bats
# Regression tests for #352: ralph_loop.sh:51 clobbered an exported RALPH_DIR
# with a hardcoded ".ralph", even though every sourced lib/*.sh (sourced
# earlier, at lines 38-47) already resolves RALPH_DIR with the env-respecting
# form ("${RALPH_DIR:-.ralph}"). This split main-script state (PROMPT_FILE,
# LOG_DIR, STATUS_FILE, CLAUDE_SESSION_FILE, ...) into ".ralph" while the libs'
# own state (CB_STATE_FILE, SESSION_FILE, QUEUE_FILE, ...) stayed under the
# exported directory.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/ralphdir.XXXXXX")"
    cd "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Sourcing ralph_loop.sh must not execute the main loop (guarded by the
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` check at the bottom of the file), so
# it is safe to source it in a subshell and inspect the resulting variables.
@test "ralph_loop.sh honors an exported RALPH_DIR (not silently reset to .ralph)" {
    mkdir -p "$TEST_DIR/custom-state"
    run bash -c "
        export RALPH_DIR='$TEST_DIR/custom-state'
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
        echo \"PROMPT_FILE=\$PROMPT_FILE\"
        echo \"LOG_DIR=\$LOG_DIR\"
        echo \"CLAUDE_SESSION_FILE=\$CLAUDE_SESSION_FILE\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=$TEST_DIR/custom-state$"
    echo "$output" | grep -q "^PROMPT_FILE=$TEST_DIR/custom-state/PROMPT.md$"
    echo "$output" | grep -q "^LOG_DIR=$TEST_DIR/custom-state/logs$"
    echo "$output" | grep -q "^CLAUDE_SESSION_FILE=$TEST_DIR/custom-state/.claude_session_id$"
}

@test "ralph_loop.sh and lib/response_analyzer.sh agree on the session-id file path" {
    # This is the concrete failure mode: ralph_loop.sh's own CLAUDE_SESSION_FILE
    # (used to decide what to --resume) and response_analyzer.sh's SESSION_FILE
    # (written by store_session_id()) must resolve to the same path, or the
    # main loop resumes a stale/wrong session id that store_session_id() never
    # actually updated.
    mkdir -p "$TEST_DIR/custom-state"
    run bash -c "
        export RALPH_DIR='$TEST_DIR/custom-state'
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"CLAUDE_SESSION_FILE=\$CLAUDE_SESSION_FILE\"
        echo \"SESSION_FILE=\$SESSION_FILE\"
    "
    [ "$status" -eq 0 ]
    local claude_session_file session_file
    claude_session_file=$(echo "$output" | grep '^CLAUDE_SESSION_FILE=' | cut -d= -f2-)
    session_file=$(echo "$output" | grep '^SESSION_FILE=' | cut -d= -f2-)
    [ -n "$claude_session_file" ]
    [ "$claude_session_file" = "$session_file" ]
}

@test "ralph_loop.sh still defaults to .ralph when RALPH_DIR is unset" {
    run bash -c "
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=\.ralph$"
}

# --- .ralphrc-sourced RALPH_DIR (#352 follow-up) ----------------------------
# load_ralphrc() runs far below the Configuration block, so a RALPH_DIR set in
# .ralphrc used to arrive after every path var had already been derived from
# ".ralph". ralph_loop.sh now scans .ralphrc for RALPH_DIR before sourcing the
# libraries. It scans rather than sources, so a .ralphrc guard that calls
# `exit` cannot take the read path down with it.

@test "ralph_loop.sh honors RALPH_DIR set in .ralphrc when the environment does not set it" {
    mkdir -p "$TEST_DIR/rc-state"
    cat > "$TEST_DIR/.ralphrc" <<RC
PROJECT_NAME="fixture"
RALPH_DIR="$TEST_DIR/rc-state"
RC
    run bash -c "
        cd '$TEST_DIR'
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
        echo \"PROMPT_FILE=\$PROMPT_FILE\"
        echo \"LOG_DIR=\$LOG_DIR\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=$TEST_DIR/rc-state$"
    echo "$output" | grep -q "^PROMPT_FILE=$TEST_DIR/rc-state/PROMPT.md$"
    echo "$output" | grep -q "^LOG_DIR=$TEST_DIR/rc-state/logs$"
}

@test "an exported RALPH_DIR takes precedence over the value in .ralphrc" {
    mkdir -p "$TEST_DIR/from-env" "$TEST_DIR/from-rc"
    cat > "$TEST_DIR/.ralphrc" <<RC
RALPH_DIR="$TEST_DIR/from-rc"
RC
    run bash -c "
        cd '$TEST_DIR'
        export RALPH_DIR='$TEST_DIR/from-env'
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=$TEST_DIR/from-env$"
}

@test "RALPH_DIR is read from a .ralphrc whose guard exits when sourced too early" {
    # Mirrors a real workspace: a tripwire above the assignment aborts the shell
    # unless RALPH_DIR already holds the expected value. Sourcing .ralphrc to
    # learn RALPH_DIR would therefore yield nothing; scanning it works, and the
    # guard then passes when load_ralphrc() finally does source the file.
    mkdir -p "$TEST_DIR/guarded"
    cat > "$TEST_DIR/.ralphrc" <<RC
if [[ "\${RALPH_DIR:-}" != "$TEST_DIR/guarded" ]]; then
    echo "FATAL: RALPH_DIR is '\${RALPH_DIR:-<unset>}'" >&2
    exit 1
fi
RALPH_DIR="$TEST_DIR/guarded"
RC
    run bash -c "
        cd '$TEST_DIR'
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        load_ralphrc
        echo \"RALPH_DIR=\$RALPH_DIR\"
        echo \"CLAUDE_SESSION_FILE=\$CLAUDE_SESSION_FILE\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=$TEST_DIR/guarded$"
    echo "$output" | grep -q "^CLAUDE_SESSION_FILE=$TEST_DIR/guarded/.claude_session_id$"
    # The guard must not have fired. Asserted via `run` + status so a failure
    # reports what was actually captured; a line-leading bare '!' would be a
    # silent no-op under bats (tests/unit/test_bats_hygiene.bats).
    local captured="$output"
    run grep -q "FATAL: RALPH_DIR" <<< "$captured"
    [ "$status" -ne 0 ]
}

@test "a commented-out RALPH_DIR in .ralphrc is ignored" {
    cat > "$TEST_DIR/.ralphrc" <<RC
# RALPH_DIR="$TEST_DIR/should-not-be-used"
PROJECT_NAME="fixture"
RC
    run bash -c "
        cd '$TEST_DIR'
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=\.ralph$"
}

@test "a .ralphrc RALPH_DIR keeps ralph_loop.sh and response_analyzer.sh on the same session file" {
    mkdir -p "$TEST_DIR/rc-state"
    cat > "$TEST_DIR/.ralphrc" <<RC
RALPH_DIR="$TEST_DIR/rc-state"
RC
    run bash -c "
        cd '$TEST_DIR'
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"CLAUDE_SESSION_FILE=\$CLAUDE_SESSION_FILE\"
        echo \"SESSION_FILE=\$SESSION_FILE\"
    "
    [ "$status" -eq 0 ]
    local claude_session_file session_file
    claude_session_file=$(echo "$output" | grep '^CLAUDE_SESSION_FILE=' | cut -d= -f2-)
    session_file=$(echo "$output" | grep '^SESSION_FILE=' | cut -d= -f2-)
    [ -n "$claude_session_file" ]
    [ "$claude_session_file" = "$session_file" ]
    # Both must land under the .ralphrc directory, not merely agree on ".ralph"
    [ "$claude_session_file" = "$TEST_DIR/rc-state/.claude_session_id" ]
}

@test "a .ralphrc RALPH_DIR containing a shell expansion is refused, not applied literally" {
    # Applying "$HOME/..." verbatim would derive literal paths here while
    # load_ralphrc() expands the same assignment later -- the exact split this
    # block exists to prevent. Fall back to the default and say why instead.
    cat > "$TEST_DIR/.ralphrc" <<RC
RALPH_DIR="\$HOME/ralph-state"
RC
    run bash -c "
        cd '$TEST_DIR'
        unset RALPH_DIR
        source '$PROJECT_ROOT/ralph_loop.sh'
        echo \"RALPH_DIR=\$RALPH_DIR\"
        echo \"PROMPT_FILE=\$PROMPT_FILE\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^RALPH_DIR=\.ralph$"
    echo "$output" | grep -q "^PROMPT_FILE=\.ralph/PROMPT\.md$"
    echo "$output" | grep -q "shell expansion"
}
