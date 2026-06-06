#!/usr/bin/env bats
# Unit Tests for Workflow Credential Hygiene (Issue #282)
#
# Least-privilege hardening: every actions/checkout step in the hand-maintained
# workflows must set `persist-credentials: false`. None of these workflows rely
# on checkout's persisted GITHUB_TOKEN — the test jobs never push, and
# claude-code-action strips checkout's auth header (configureGitAuth) and uses
# its own GitHub App token for git operations.
# POSIX character classes only — BSD grep (macOS) has no \s in ERE.

load '../helpers/test_helper'

WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
HARDENED_WORKFLOWS=(test.yml claude.yml claude-code-review.yml)

@test "every checkout step disables credential persistence" {
    local violations=""
    for wf in "${HARDENED_WORKFLOWS[@]}"; do
        local file="$WORKFLOWS_DIR/$wf"
        [ -f "$file" ] || { violations+="$wf: missing file"$'\n'; continue; }
        local checkouts persists
        # grep -c exits 1 on zero matches but still prints "0" — keep the count
        checkouts=$(grep -cE 'uses:[[:space:]]*actions/checkout@' "$file" || true)
        persists=$(grep -cE 'persist-credentials:[[:space:]]*false' "$file" || true)
        if [ "$checkouts" -eq 0 ]; then
            violations+="$wf: no checkout steps found (guard expects at least one)"$'\n'
        elif [ "$persists" -ne "$checkouts" ]; then
            violations+="$wf: $checkouts checkout step(s) but only $persists persist-credentials: false"$'\n'
        fi
    done
    if [ -n "$violations" ]; then
        echo "Checkout steps persisting credentials:"
        echo "$violations"
        return 1
    fi
}
