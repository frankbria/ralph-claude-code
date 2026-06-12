#!/usr/bin/env bats
# Guards for the sandbox-image publishing workflow (Issue #298)
#
# docker-publish.yml builds the default ralph-sandbox image on release tags
# (v*), smoke-tests it, and pushes to GHCR. These grep-based guards pin the
# load-bearing properties; SHA pinning and checkout credential hygiene are
# enforced by the generic guards (test_workflow_sha_pinning.bats,
# test_workflow_credential_hygiene.bats — both list this workflow).

load '../helpers/test_helper'

WORKFLOW="$BATS_TEST_DIRNAME/../../.github/workflows/docker-publish.yml"

@test "docker-publish workflow exists" {
    [ -f "$WORKFLOW" ]
}

@test "docker-publish triggers on v* tags and manual dispatch" {
    grep -qE "^\s*tags:" "$WORKFLOW"
    grep -qE "v\*" "$WORKFLOW"
    grep -q "workflow_dispatch:" "$WORKFLOW"
}

@test "docker-publish targets GHCR with least-privilege permissions" {
    grep -q "ghcr.io" "$WORKFLOW"
    grep -qE "packages:\s*write" "$WORKFLOW"
    grep -qE "contents:\s*read" "$WORKFLOW"
    # Registry auth rides on the ephemeral workflow GITHUB_TOKEN — no other
    # secret may be referenced anywhere in the workflow
    [[ $(grep -o 'secrets\.[A-Za-z_]*' "$WORKFLOW" | grep -cv '^secrets\.GITHUB_TOKEN$') -eq 0 ]]
}

@test "docker-publish smoke test runs before the multi-arch push" {
    # The amd64 image must prove `claude --version` works as a non-root user
    # BEFORE anything is pushed: the smoke step must appear earlier in the
    # file than the push step.
    local smoke_line push_line
    smoke_line=$(grep -n "claude --version" "$WORKFLOW" | head -1 | cut -d: -f1)
    push_line=$(grep -n "push:" "$WORKFLOW" | tail -1 | cut -d: -f1)
    [ -n "$smoke_line" ]
    [ -n "$push_line" ]
    [ "$smoke_line" -lt "$push_line" ]
    # Non-root: the smoke container must not run as root
    grep -q -- "--user" "$WORKFLOW"
}

@test "docker-publish builds multi-arch (amd64 + arm64)" {
    grep -q "linux/amd64" "$WORKFLOW"
    grep -q "linux/arm64" "$WORKFLOW"
}

@test "docker-publish dispatch dry-run cannot publish" {
    # workflow_dispatch exposes a push input that defaults to false so the
    # build+smoke can be validated from a branch without releasing an image
    grep -qE "default:\s*false" "$WORKFLOW"
}
