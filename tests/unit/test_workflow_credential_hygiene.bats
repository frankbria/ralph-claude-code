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

# Count checkout steps lacking persist-credentials: false WITHIN their own
# step block (from the checkout `uses:` line to the next `- ` list item).
# Per-block matching — a stray persist-credentials elsewhere in the file
# cannot mask an unhardened checkout. Also prints total checkout count.
unhardened_checkouts() {
    awk '
        /uses:[[:space:]]*actions\/checkout@/ {
            if (inblock && !found) bad++
            inblock = 1; found = 0; total++; next
        }
        inblock && /^[[:space:]]*-[[:space:]]/ {       # next step begins
            if (!found) bad++
            inblock = 0
        }
        inblock && /persist-credentials:[[:space:]]*false/ { found = 1 }
        END {
            if (inblock && !found) bad++
            print total, bad+0
        }
    ' "$1"
}

@test "every checkout step disables credential persistence in its own block" {
    local violations=""
    for wf in "${HARDENED_WORKFLOWS[@]}"; do
        local file="$WORKFLOWS_DIR/$wf"
        [ -f "$file" ] || { violations+="$wf: missing file"$'\n'; continue; }
        local total bad
        read -r total bad < <(unhardened_checkouts "$file")
        if [ "$total" -eq 0 ]; then
            violations+="$wf: no checkout steps found (guard expects at least one)"$'\n'
        elif [ "$bad" -ne 0 ]; then
            violations+="$wf: $bad of $total checkout step(s) missing persist-credentials: false"$'\n'
        fi
    done
    if [ -n "$violations" ]; then
        echo "Checkout steps persisting credentials:"
        echo "$violations"
        return 1
    fi
}
