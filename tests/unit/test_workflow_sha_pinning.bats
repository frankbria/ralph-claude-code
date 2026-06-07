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

# gh-aw lock files are compiled artifacts: their workflow bodies call .cjs
# runtime scripts installed by the github/gh-aw setup action, which gh-aw docs
# version-lock to the compiler ("do not bump"). A pin bump without a recompile
# desyncs runtime scripts from the compiled body and is invisible to PR CI
# (the workflow only runs on issues events). Caught manually on PR #283;
# these guards make the desync mechanical (Issue #287).

@test "gh-aw lock files keep setup pins at the compiler version" {
    local violations="" lock compiler_version line tag
    for lock in "$WORKFLOWS_DIR"/*.lock.yml; do
        [ -f "$lock" ] || continue
        compiler_version=$(grep -oE '"compiler_version":"[^"]*"' "$lock" | head -1 | cut -d'"' -f4)
        if [ -z "$compiler_version" ]; then
            violations+="$(basename "$lock"): missing compiler_version in gh-aw-metadata"$'\n'
            continue
        fi
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            tag=$(echo "$line" | grep -oE '#[[:space:]]*v[0-9][0-9A-Za-z.-]*' | sed 's/^#[[:space:]]*//')
            if [ "$tag" != "$compiler_version" ]; then
                violations+="$(basename "$lock") [compiler $compiler_version]: $line"$'\n'
            fi
        done < <(grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*github/gh-aw' "$lock" || true)
    done
    if [ -n "$violations" ]; then
        echo "gh-aw setup pins desynced from the compiler that generated the lock file:"
        echo "$violations"
        echo "Fix by recompiling ('gh aw compile'), never by bumping the pin."
        return 1
    fi
}

@test "dependabot ignores compiler-locked gh-aw pins" {
    local config="$BATS_TEST_DIRNAME/../../.github/dependabot.yml"
    [ -f "$config" ] || fail "missing .github/dependabot.yml"
    grep -qE '^[[:space:]]*ignore:' "$config" || \
        fail "dependabot.yml has no ignore block (gh-aw setup pin must be excluded; Issue #287)"
    grep -qE 'dependency-name:[[:space:]]*"?github/gh-aw' "$config" || \
        fail "dependabot.yml does not ignore github/gh-aw (compiler-locked pin; Issue #287)"
}
