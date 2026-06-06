#!/usr/bin/env bats
# Unit Tests for GitHub Actions SHA Pinning (Issue #275)
#
# Supply-chain hardening: every external action in the hand-maintained
# workflows must be pinned to a full 40-char commit SHA with a version tag
# comment (e.g. `uses: actions/checkout@<sha> # v4.3.1`), not a mutable tag.
# Generated workflows (gh-aw *.lock.yml) are excluded — they are pinned by
# their generator.

load '../helpers/test_helper'

WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
PINNED_WORKFLOWS=(test.yml claude.yml claude-code-review.yml)

# Extract all `uses:` lines referencing external actions (owner/repo@ref).
# Skips local actions (./) and docker:// references, which have no SHA to pin.
# POSIX character classes only — BSD grep (macOS) has no \s/\b in ERE.
extract_uses_lines() {
    grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^./]' "$1" | grep -v 'docker://' || true
}

@test "workflow files under test exist" {
    for wf in "${PINNED_WORKFLOWS[@]}"; do
        [ -f "$WORKFLOWS_DIR/$wf" ] || fail "missing workflow: $wf"
    done
}

@test "all external actions are pinned to 40-char commit SHAs" {
    local violations=""
    for wf in "${PINNED_WORKFLOWS[@]}"; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if ! echo "$line" | grep -qE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}([^0-9a-f]|$)'; then
                violations+="$wf: $line"$'\n'
            fi
        done < <(extract_uses_lines "$WORKFLOWS_DIR/$wf")
    done
    if [ -n "$violations" ]; then
        echo "Actions not pinned to a full commit SHA:"
        echo "$violations"
        return 1
    fi
}

@test "all SHA-pinned actions carry a version tag comment" {
    local violations=""
    for wf in "${PINNED_WORKFLOWS[@]}"; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if ! echo "$line" | grep -qE '@[0-9a-f]{40}[[:space:]]*#[[:space:]]*v[0-9]'; then
                violations+="$wf: $line"$'\n'
            fi
        done < <(extract_uses_lines "$WORKFLOWS_DIR/$wf")
    done
    if [ -n "$violations" ]; then
        echo "SHA-pinned actions missing a '# vX[.Y.Z]' tag comment:"
        echo "$violations"
        return 1
    fi
}

@test "dependabot config keeps pinned actions updated" {
    local config="$BATS_TEST_DIRNAME/../../.github/dependabot.yml"
    [ -f "$config" ] || fail "missing .github/dependabot.yml"
    grep -qE 'package-ecosystem:[[:space:]]*"?github-actions"?' "$config" || \
        fail "dependabot.yml does not cover the github-actions ecosystem"
}
