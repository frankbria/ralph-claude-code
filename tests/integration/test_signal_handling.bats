#!/usr/bin/env bats
#
# Regression tests for the SIGINT/SIGTERM stop control.
#
# The bug: `trap cleanup SIGINT SIGTERM` invoked a cleanup() that deliberately
# returns rather than exiting ("No exit here — EXIT trap handles natural
# termination" — but no EXIT trap existed). The handler therefore returned and
# bash resumed the main loop: Ralph logged "Ralph loop interrupted. Cleaning
# up..." and kept running. The _CLEANUP_DONE reentrancy guard then made every
# subsequent signal a silent no-op, so repeated Ctrl-C could not recover.
#
# These tests run the loop with --dry-run, so they make no API calls.
#
# NOTE ON SIGINT: a background job started from a non-interactive shell
# inherits SIGINT as SIG_IGN, and bash cannot re-trap an inherited-ignored
# signal. A naive harness therefore shows the loop surviving Ctrl-C whether or
# not the bug is present. The perl wrapper resets SIGINT to its default
# disposition before exec, which is what an interactive terminal supplies.

load ../helpers/test_helper

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

# Build a minimal but valid Ralph project in the per-test temp dir.
setup_ralph_project() {
    mkdir -p .ralph/specs src
    printf 'Say hello. Do nothing else.\n' > .ralph/PROMPT.md
    printf '# fix plan\n- nothing\n'        > .ralph/fix_plan.md
    printf '# agent\nTest fixture.\n'       > .ralph/AGENT.md
    printf 'ALLOWED_TOOLS="Read"\n'         > .ralphrc
}

# Start the loop in its own process group with default signal dispositions.
# Sets LOOP_PID. Must NOT be called in a command substitution, or the job
# becomes a child of the subshell and `wait` cannot reach it.
start_loop() {
    perl -e '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
        bash "$RALPH_LOOP" --dry-run > loop.log 2>&1 &
    LOOP_PID=$!
}

# Wait until the loop is actually executing an iteration, or fail.
wait_for_loop() {
    local waited=0
    while [ "$waited" -lt 40 ]; do
        grep -q "DRY RUN" loop.log 2>/dev/null && return 0
        kill -0 "$LOOP_PID" 2>/dev/null || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Block until the loop exits, with a hard watchdog so a hung test cannot wedge
# the suite. Sets LOOP_RC to the loop's exit status. `wait` is used rather than
# a kill -0 poll because a dead-but-unreaped child still answers kill -0.
reap_loop() {
    ( sleep 15; kill -9 "-$LOOP_PID" 2>/dev/null ) &
    local watchdog=$!
    # A signalled child returns 128+n; capture it without tripping bats' errexit.
    LOOP_RC=0
    wait "$LOOP_PID" 2>/dev/null || LOOP_RC=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return 0
}

@test "SIGTERM terminates the loop instead of being swallowed" {
    setup_ralph_project
    start_loop
    wait_for_loop || { kill -9 "-$LOOP_PID" 2>/dev/null; skip "loop did not start"; }

    kill -TERM "$LOOP_PID"
    reap_loop

    if [ "$LOOP_RC" -ne 143 ]; then   # 128 + SIGTERM
        echo "expected exit 143, got $LOOP_RC; log:"; cat loop.log
        return 1
    fi
}

@test "SIGINT terminates the loop instead of being swallowed" {
    command -v perl >/dev/null || skip "perl required to reset SIGINT disposition"
    setup_ralph_project
    start_loop
    wait_for_loop || { kill -9 "-$LOOP_PID" 2>/dev/null; skip "loop did not start"; }

    kill -INT "-$LOOP_PID"   # process group, as a terminal would
    reap_loop

    if [ "$LOOP_RC" -ne 130 ]; then   # 128 + SIGINT
        echo "expected exit 130, got $LOOP_RC; log:"; cat loop.log
        return 1
    fi
}

@test "repeated signals do not disarm the handler" {
    setup_ralph_project
    start_loop
    wait_for_loop || { kill -9 "-$LOOP_PID" 2>/dev/null; skip "loop did not start"; }

    # Under the reentrancy-guard bug the first signal disarmed cleanup() and
    # every later one was a silent no-op. The loop must die on the first.
    kill -TERM "$LOOP_PID"
    kill -TERM "$LOOP_PID" 2>/dev/null || true
    reap_loop

    if [ "$LOOP_RC" -eq 137 ]; then
        echo "loop had to be SIGKILLed by the watchdog; log:"; cat loop.log
        return 1
    fi
}

@test "the signal trap is not a bare call to cleanup" {
    # cleanup() is teardown only and must never be installed as the handler on
    # its own: it returns, and bash then resumes the loop.
    run grep -E '^trap[[:space:]]+cleanup[[:space:]]+SIGINT[[:space:]]+SIGTERM' "$RALPH_LOOP"
    [ "$status" -ne 0 ]
}

@test "the child Claude pid is exposed to the signal handler" {
    # A SIGTERM addressed to the script does not reach a backgrounded child,
    # so the handler needs a non-local pid to stop it.
    run grep -q 'CLAUDE_CHILD_PID' "$RALPH_LOOP"
    [ "$status" -eq 0 ]
}
