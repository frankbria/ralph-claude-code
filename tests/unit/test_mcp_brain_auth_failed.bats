#!/usr/bin/env bats
# TAP-1530: MCP probe failure resilience — when tapps-brain health returns 200
# but auth fails, RALPH_MCP_BRAIN_AUTH_FAILED is exported and build_loop_context
# injects an explicit negative instruction. These tests verify the wiring
# without spinning up a full MCP environment.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
LOOP_SCRIPT="${REPO_ROOT}/ralph_loop.sh"

@test "TAP-1530: ralph_probe_mcp_servers initializes RALPH_MCP_BRAIN_AUTH_FAILED=false" {
    [[ -f "$LOOP_SCRIPT" ]]
    run grep -E 'export RALPH_MCP_BRAIN_AUTH_FAILED="false"' "$LOOP_SCRIPT"
    assert_success
}

@test "TAP-1530: ralph_diagnose_brain_probe_failure sets RALPH_MCP_BRAIN_AUTH_FAILED=true on HTTP 200" {
    [[ -f "$LOOP_SCRIPT" ]]
    # Locate the 200 case branch and confirm the export is present nearby.
    run awk '
        /200\)/ { in200=1 }
        in200 && /RALPH_MCP_BRAIN_AUTH_FAILED="true"/ { found=1; exit }
        in200 && /;;/ { in200=0 }
        END { exit (found ? 0 : 1) }
    ' "$LOOP_SCRIPT"
    assert_success
}

@test "TAP-1530: build_loop_context injects negative instruction when auth failed" {
    [[ -f "$LOOP_SCRIPT" ]]
    run grep -E 'RALPH_MCP_BRAIN_AUTH_FAILED.*==.*"true"' "$LOOP_SCRIPT"
    assert_success
    run grep -F 'tapps-brain UNAVAILABLE (auth failed)' "$LOOP_SCRIPT"
    assert_success
}

@test "TAP-1530: negative instruction is gated to elif branch (only when not available)" {
    [[ -f "$LOOP_SCRIPT" ]]
    # The negative-instruction block must use elif so it does NOT inject when
    # the brain MCP is reachable. Verify ordering.
    run awk '
        /RALPH_MCP_BRAIN_AVAILABLE.*==.*"true"/ { saw_pos=1; next }
        saw_pos && /elif.*RALPH_MCP_BRAIN_AUTH_FAILED.*==.*"true"/ { found=1; exit }
        END { exit (found ? 0 : 1) }
    ' "$LOOP_SCRIPT"
    assert_success
}
