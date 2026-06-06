#!/usr/bin/env bats
# Unit tests for lib/issue_analyzer.sh (Issue #70)
#
# Tests issue completeness assessment: heuristic confidence scoring of a
# formatted issue PRD, completeness levels, missing-element reporting, and
# the generate-plan recommendation. Scoring is deterministic (pure bash/grep,
# no Claude call) so fixtures map to exact score expectations.

load '../helpers/test_helper'

ISSUE_ANALYZER="${BATS_TEST_DIRNAME}/../../lib/issue_analyzer.sh"

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/issueanalyzer.XXXXXX")"
    cd "$TEST_DIR"

    source "$ISSUE_ANALYZER"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------

# High-detail issue: all six indicators present
# (acceptance criteria +25, checklist +15, code block +15, >=3 sections +15,
#  guidance keywords +15, >=150 words +15 = 100)
create_high_detail_prd() {
    cat > "$1" << 'EOF'
# Add User Authentication

> GitHub issue #42 | Labels: enhancement | https://github.com/test/repo/issues/42

## Summary

Implement session-based user authentication for the web application using the
existing middleware architecture. The implementation should follow the steps
below and modify the files listed in each task. This feature requires changes
to the API layer, the database schema, and the frontend login form. Each step
includes the technical approach and the specific functions to implement so an
autonomous agent can execute the plan without further clarification. The design
follows the existing repository patterns for error handling and validation,
reusing the middleware pipeline and the established session storage interface.
The work is split into independent tasks that can be implemented sequentially,
each with its own tests, so progress is verifiable at every stage of the
implementation and regressions are caught early by the continuous integration
pipeline before merge.

## Technical Requirements

- Session storage backed by Redis
- Password hashing with bcrypt

```python
def authenticate(username: str, password: str) -> Session:
    ...
```

## Implementation Steps

- [ ] Add `users` table migration
- [ ] Implement `authenticate()` in `auth/service.py`
- [ ] Add login endpoint to `api/routes.py`

## Acceptance Criteria

- [ ] Users can log in with valid credentials
- [ ] Invalid credentials return 401
- [ ] Sessions expire after 24 hours
EOF
}

# Low-detail issue: vague one-liner, no structure
create_low_detail_prd() {
    cat > "$1" << 'EOF'
# Make the app faster

> GitHub issue #7 | https://github.com/test/repo/issues/7

The app feels slow sometimes. Can we speed it up?
EOF
}

# Medium-detail issue: clear objective with some indicators
# (>=3 sections +15, guidance keywords +15, >=150 words +15 = 45)
create_medium_detail_prd() {
    cat > "$1" << 'EOF'
# Improve search relevance

> GitHub issue #19 | https://github.com/test/repo/issues/19

## Summary

Search results should rank exact title matches above fuzzy body matches. The
current implementation treats all the indexed fields with equal weight, which
buries the most relevant results below the noise for the common case where a
user types the exact name of a document they have seen before. We want to
adjust the ranking function so exact matches in the title field are boosted
above everything else, while preserving reasonable recall when the user query
only matches body text. There is some flexibility in the exact approach as
long as the regression suite for the existing ranking behavior keeps passing
and the search latency stays within the current budget for the interactive
search endpoint under typical production load patterns measured last quarter.

## Current Behavior

All fields are weighted equally in the ranking function implementation.

## Desired Behavior

Title matches rank first, then header matches, then body matches.
EOF
}

# -----------------------------------------------------------------------------
# assess_issue_completeness - scoring
# -----------------------------------------------------------------------------

@test "assess_issue_completeness scores a high-detail issue >= 80 (level high)" {
    create_high_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    assert_valid_json "analysis.json"
    local score level
    score=$(get_json_field "analysis.json" "confidence_score")
    level=$(get_json_field "analysis.json" "completeness_level")
    [[ "$score" -ge 80 ]]
    [[ "$level" == "high" ]]
}

@test "assess_issue_completeness scores a low-detail issue < 40 (level low)" {
    create_low_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local score level
    score=$(get_json_field "analysis.json" "confidence_score")
    level=$(get_json_field "analysis.json" "completeness_level")
    [[ "$score" -lt 40 ]]
    [[ "$level" == "low" ]]
}

@test "assess_issue_completeness scores a medium-detail issue in 40-79 (level medium)" {
    create_medium_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local score level
    score=$(get_json_field "analysis.json" "confidence_score")
    level=$(get_json_field "analysis.json" "completeness_level")
    [[ "$score" -ge 40 && "$score" -lt 80 ]]
    [[ "$level" == "medium" ]]
}

@test "assess_issue_completeness gives acceptance criteria the largest single boost" {
    # Identical fixture with and without the acceptance criteria section
    create_high_detail_prd "with_ac.md"
    sed '/^## Acceptance Criteria/,$d' "with_ac.md" > "without_ac.md"

    assess_issue_completeness "with_ac.md" "with_ac.json"
    assess_issue_completeness "without_ac.md" "without_ac.json"

    local with_score without_score
    with_score=$(get_json_field "with_ac.json" "confidence_score")
    without_score=$(get_json_field "without_ac.json" "confidence_score")
    [[ $((with_score - without_score)) -ge 25 ]]
}

# -----------------------------------------------------------------------------
# assess_issue_completeness - recommendation and threshold
# -----------------------------------------------------------------------------

@test "assess_issue_completeness recommends convert at or above threshold" {
    create_high_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local rec
    rec=$(get_json_field "analysis.json" "recommendation")
    [[ "$rec" == "convert" ]]
}

@test "assess_issue_completeness recommends generate_plan below threshold" {
    create_low_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local rec
    rec=$(get_json_field "analysis.json" "recommendation")
    [[ "$rec" == "generate_plan" ]]
}

@test "assess_issue_completeness honors a custom threshold" {
    # Medium fixture scores 40-79: below a threshold of 95 -> generate_plan
    create_medium_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json" 95
    assert_success

    local rec
    rec=$(get_json_field "analysis.json" "recommendation")
    [[ "$rec" == "generate_plan" ]]

    # ...and above a threshold of 10 -> convert
    run assess_issue_completeness "issue.md" "analysis.json" 10
    assert_success
    rec=$(get_json_field "analysis.json" "recommendation")
    [[ "$rec" == "convert" ]]
}

# -----------------------------------------------------------------------------
# assess_issue_completeness - missing elements
# -----------------------------------------------------------------------------

@test "assess_issue_completeness lists missing elements for a vague issue" {
    create_low_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local missing
    missing=$(get_json_field "analysis.json" "missing_elements | join(\",\")")
    [[ "$missing" == *"acceptance_criteria"* ]]
    [[ "$missing" == *"task_checklist"* ]]
    [[ "$missing" == *"code_examples"* ]]
}

@test "assess_issue_completeness reports no missing elements for a complete issue" {
    create_high_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json"
    assert_success

    local missing_count
    missing_count=$(get_json_field "analysis.json" "missing_elements | length")
    [[ "$missing_count" -eq 0 ]]
}

# -----------------------------------------------------------------------------
# assess_issue_completeness - error handling
# -----------------------------------------------------------------------------

@test "assess_issue_completeness fails on a missing input file" {
    run assess_issue_completeness "does-not-exist.md" "analysis.json"
    assert_failure
}

@test "assess_issue_completeness scores an empty file as 0 (level low)" {
    : > "empty.md"

    run assess_issue_completeness "empty.md" "analysis.json"
    assert_success

    local score level
    score=$(get_json_field "analysis.json" "confidence_score")
    level=$(get_json_field "analysis.json" "completeness_level")
    [[ "$score" -eq 0 ]]
    [[ "$level" == "low" ]]
}

@test "assess_issue_completeness rejects a non-numeric threshold" {
    create_high_detail_prd "issue.md"

    run assess_issue_completeness "issue.md" "analysis.json" "not-a-number"
    assert_failure
}

# -----------------------------------------------------------------------------
# log_issue_analysis
# -----------------------------------------------------------------------------

@test "log_issue_analysis prints score, level, and recommendation" {
    create_low_detail_prd "issue.md"
    assess_issue_completeness "issue.md" "analysis.json"

    run log_issue_analysis "analysis.json"
    assert_success
    [[ "$output" == *"Completeness"* ]]
    [[ "$output" == *"low"* ]]
    [[ "$output" == *"generate_plan"* ]]
}

@test "log_issue_analysis fails gracefully on a missing analysis file" {
    run log_issue_analysis "does-not-exist.json"
    assert_failure
}
