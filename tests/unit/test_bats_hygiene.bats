#!/usr/bin/env bats
# Guard: line-leading bare `! cmd` assertions are silent no-ops in bats
# (Issue #303)
#
# bats-core's ERR trap does not fire for negated commands, so a failing
# `! cmd` line in a @test body asserts nothing. Only a final-line `!`
# affects the test via its return status — and refactors move lines — so
# the repo rule is absolute: NO line-leading bare `!` in any .bats file.
# Use instead:
#   [[ $(cmd | grep -c PATTERN) -eq 0 ]]   # negative grep assertions
#   run cmd; [ "$status" -ne 0 ]           # expected-failure commands
#   a helper that returns 1 on unexpected success, checked at the call site
#
# Discovered in #75 (PR #302): 9 such assertions let 5 product mutations
# survive undetected. This guard prevents the pattern from returning.

load '../helpers/test_helper'

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

@test "no .bats file contains a line-leading bare '!' assertion" {
    local violations
    # POSIX classes only — BSD grep (macOS) has no \s in ERE
    violations=$(grep -rnE '^[[:space:]]*![[:space:]]' "$REPO_ROOT/tests" --include='*.bats' || true)
    if [[ -n "$violations" ]]; then
        echo "Bare '!' assertions found (silent no-ops under bats — issue #303):" >&2
        echo "$violations" >&2
        echo "Convert to a count-based grep, 'run' + status check, or a checked helper." >&2
        return 1
    fi
    return 0
}
