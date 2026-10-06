#!/usr/bin/env bats
#
# Regression tests for kill_tree() / list_descendants() — the stop control's
# child-kill leg.
#
# The bug these cover: the loop stored `$!` in CLAUDE_CHILD_PID and sent it a
# single SIGTERM. That pid is not reliably the agent. Measured mid-work under a
# real pty:
#
#     loop      pid 94095  pgid 94095   <- foreground group; receives the Ctrl-C
#     bash      pid 94100  pgid 94095   <- $! captured THIS, not the agent
#     gtimeout  pid 94107  pgid 94107   <- gtimeout setpgid()s ITSELF
#     claude    pid 94112  pgid 94107   <- the agent, in that other group
#
# `portable_timeout` is a shell function, so backgrounding it forks a subshell;
# bash sometimes replaces that subshell with an exec of the timeout binary and
# sometimes does not, varying with execution context. Killing the captured pid
# therefore killed a wrapper and orphaned the agent, which kept working and
# kept billing. A process-group kill is not the answer either — the agent is
# not in the loop's group, so `-$PGID` signals the loop and spares the agent.
#
# These tests use `sleep` trees. They make no API calls and cost nothing.
#
# Each behavioural test that proves kill_tree works is paired with a control
# that must genuinely FAIL first — see "a single-pid TERM leaves the tree
# alive". If that control ever passes, the others prove nothing and it fails
# loudly rather than going green for the wrong reason.
#
# Written for bash 3.2 (`#!/bin/bash` on macOS): no mapfile, no readarray, and
# no array expansion that aborts under `set -u`.

load ../helpers/test_helper

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

# Run a snippet with the real ralph_loop.sh sourced, in a subshell so the
# loop's own SIGINT/SIGTERM traps are never installed in the bats shell.
# The functions under test are the ones in the shipped file, not a copy.
in_loop_ctx() {
    bash -c "source '$RALPH_LOOP' >/dev/null 2>&1; $1"
}

@test "list_descendants finds a child and a grandchild through a wrapper" {
    run in_loop_ctx '
        bash -c "bash -c \"sleep 30\" & sleep 30" &
        root=$!
        sleep 1
        n=0
        for p in $(list_descendants "$root"); do n=$((n + 1)); done
        kill -KILL $(list_descendants "$root") "$root" 2>/dev/null || true
        echo "descendants=$n"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"descendants=2"* ]]
}

@test "a single-pid TERM leaves the tree alive — the defect this fix exists to stop" {
    # KNOWN-FALSE CONTROL. This asserts the OLD behaviour still fails. If this
    # ever passes, every kill_tree test below is proving nothing.
    run in_loop_ctx '
        bash -c "bash -c \"sleep 30\" & sleep 30" &
        root=$!
        sleep 1
        kids=$(list_descendants "$root")
        kill -TERM "$root" 2>/dev/null      # exactly the old child-kill leg
        sleep 1
        alive=0
        for p in $kids; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
        kill -KILL $kids 2>/dev/null || true
        echo "survivors=$alive"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"survivors=2"* ]]
}

@test "kill_tree clears the whole tree from a live root" {
    run in_loop_ctx '
        bash -c "bash -c \"sleep 30\" & sleep 30" &
        root=$!
        sleep 1
        kids=$(list_descendants "$root")
        kill_tree "$root" 3
        sleep 1
        alive=0
        for p in $root $kids; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
        kill -KILL $root $kids 2>/dev/null || true
        echo "alive=$alive"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"alive=0"* ]]
}

@test "kill_tree reaches a descendant in a DIFFERENT process group" {
    # The production shape: the timeout binary puts itself and the agent into
    # their own group, so group membership cannot be assumed from the pid the
    # loop captured. Parentage is the only test that survives this.
    command -v perl >/dev/null || skip "perl required to create a new process group"
    run in_loop_ctx '
        bash -c "perl -e \"setpgrp(0,0); exec q(sleep), q(30)\" & sleep 30" &
        root=$!
        sleep 1
        kids=$(list_descendants "$root")
        rootpg=$(ps -o pgid= -p "$root" | tr -d " ")
        crossed=no
        for p in $kids; do
            pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d " ")
            [ -n "$pg" ] && [ "$pg" != "$rootpg" ] && crossed=yes
        done
        kill_tree "$root" 3
        sleep 1
        alive=0
        for p in $root $kids; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
        kill -KILL $root $kids 2>/dev/null || true
        echo "crossed=$crossed alive=$alive"
    '
    [ "$status" -eq 0 ]
    # The fixture must actually straddle a group boundary, or it tests nothing.
    [[ "$output" == *"crossed=yes"* ]]
    [[ "$output" == *"alive=0"* ]]
}

@test "kill_tree does not kill its own caller" {
    # A candidate fix that signalled -$PGID killed the supervisor and left the
    # target running. A stop control that kills the supervisor is worse than
    # one that does nothing.
    run in_loop_ctx '
        bash -c "sleep 30" &
        root=$!
        sleep 1
        kill_tree "$root" 3
        # The target MUST be dead as well, or this test passes vacuously
        # wherever kill_tree does not exist — a test that goes green against
        # the unpatched loop is worthless.
        if kill -0 "$root" 2>/dev/null; then target=alive; else target=dead; fi
        kill -KILL "$root" 2>/dev/null || true
        # Cleanup must not be the last command: killing an already-dead pid
        # exits non-zero and would fail the test for the wrong reason.
        kill -0 $$ 2>/dev/null && echo "caller=alive target=$target" \
                               || echo "caller=dead target=$target"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"caller=alive"* ]]
    [[ "$output" == *"target=dead"* ]]
}

@test "kill_tree escalates to SIGKILL past a process that ignores SIGTERM" {
    run in_loop_ctx '
        bash -c "trap \"\" TERM; sleep 30" &
        stubborn=$!
        sleep 1
        kill_tree "$stubborn" 2
        sleep 1
        if kill -0 "$stubborn" 2>/dev/null; then
            kill -KILL "$stubborn" 2>/dev/null
            echo "stubborn=survived"
        else
            echo "stubborn=killed"
        fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"stubborn=killed"* ]]
}

@test "the signal handler stops the tree, not a single pid" {
    # Comment lines are excluded deliberately: the handler carries a comment
    # naming the old form to explain why it is wrong, and a naive grep counts
    # that as the bug still being present.
    run bash -c "grep -v '^[[:space:]]*#' '$RALPH_LOOP' | grep -cF 'kill -TERM \"\$CLAUDE_CHILD_PID\"'"
    [ "$output" -eq 0 ]

    run bash -c "grep -cF 'kill_tree \"\$CLAUDE_CHILD_PID\"' '$RALPH_LOOP'"
    [ "$output" -ge 1 ]
}
