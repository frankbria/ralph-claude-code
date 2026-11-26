#!/usr/bin/env bats
# Unit Tests for the GLM review workflow fork guard (Issue #384)
#
# pull_request events from forks get no repository secrets, so the GLM review
# job failed on every fork PR. The job must only run when the PR's head repo is
# this repository, and the fork check must gate the whole condition (AND), not
# sit beside the size checks as one more OR branch.

load '../helpers/test_helper'

WORKFLOW="$BATS_TEST_DIRNAME/../../.github/workflows/glm-review.yml"

# Print the job-level `if:` block scalar (the lines indented under `if: |`).
review_if_block() {
    awk '
        /^[[:space:]]*if:[[:space:]]*\|/ { inif = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; next }
        inif {
            match($0, /^[[:space:]]*/)
            if ($0 !~ /^[[:space:]]*$/ && RLENGTH <= ind) exit
            print
        }
    ' "$WORKFLOW"
}

@test "glm-review workflow exists" {
    [ -f "$WORKFLOW" ]
}

@test "review job is gated on the PR head repo being this repository" {
    run review_if_block
    [ "$status" -eq 0 ]
    [[ "$output" == *"github.event.pull_request.head.repo.full_name == github.repository"* ]]
}

@test "fork guard is ANDed with the size checks, not ORed" {
    block="$(review_if_block | tr -s '[:space:]' ' ')"
    # The guard must come first and be followed by && and a parenthesised group
    [[ "$block" =~ head\.repo\.full_name\ ==\ github\.repository\ \&\&\ \( ]]
    # Every size check must sit inside that group (after the opening paren)
    group="${block#*&& (}"
    [[ "$group" == *"changed_files >= 5"* ]]
    [[ "$group" == *"additions >= 20"* ]]
    [[ "$group" == *"deletions >= 20"* ]]
    [[ "$group" == *")"* ]]
}
