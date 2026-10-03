#!/usr/bin/env bats
# Tests for Issue #340: Circuit breaker false positive in non-git workspaces
# Verifies progress detection fallback when git is unavailable

load '../helpers/test_helper'

setup() {
    # Create a truly non-git temp directory
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    # Source the library
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    source "$BATS_TEST_DIRNAME/../../lib/response_analyzer.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# Helper to create a JSON response with files_modified
create_json_response() {
    local files_modified=$1
    local output_file="$TEST_DIR/output.json"
    cat > "$output_file" << EOF
{
  "type": "result",
  "result": "Completed work.",
  "metadata": {
    "files_changed": $files_modified
  }
}
EOF
    echo "$output_file"
}

# Helper to create text response with RALPH_STATUS block
create_text_response() {
    local files_modified=$1
    local output_file="$TEST_DIR/output.txt"
    cat > "$output_file" << EOF
Working on the implementation...

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: $files_modified
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
---END_RALPH_STATUS---
EOF
    echo "$output_file"
}

@test "JSON path: non-git workspace uses self-reported files_modified" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file
    output_file=$(create_json_response 5)

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    # Check analysis result
    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "true" ]

    local files_modified
    files_modified=$(jq -r '.analysis.files_modified' "$RALPH_DIR/.response_analysis")
    [ "$files_modified" = "5" ]
}

@test "JSON path: non-git workspace with zero files_modified has no progress" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file
    output_file=$(create_json_response 0)

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "false" ]
}

@test "Text path: non-git workspace extracts FILES_MODIFIED from RALPH_STATUS" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file
    output_file=$(create_text_response 3)

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "true" ]

    local files_modified
    files_modified=$(jq -r '.analysis.files_modified' "$RALPH_DIR/.response_analysis")
    [ "$files_modified" = "3" ]
}

@test "Text path: non-git workspace with FILES_MODIFIED: 0 has no progress" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file
    output_file=$(create_text_response 0)

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "false" ]
}

@test "Text path: non-git workspace without RALPH_STATUS block has no progress" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file="$TEST_DIR/output.txt"
    echo "Just some text output without any structured status block" > "$output_file"

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "false" ]
}

@test "Text path: YAML-style RALPH_STATUS also extracts FILES_MODIFIED" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file="$TEST_DIR/output.txt"
    cat > "$output_file" << 'EOF'
Working on implementation...

RALPH_STATUS:
  STATUS: IN_PROGRESS
  FILES_MODIFIED: 7
  EXIT_SIGNAL: false
EOF

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "true" ]

    local files_modified
    files_modified=$(jq -r '.analysis.files_modified' "$RALPH_DIR/.response_analysis")
    [ "$files_modified" = "7" ]
}

@test "Text path: invalid FILES_MODIFIED value is ignored" {
    # Verify we're NOT in a git repo
    run git rev-parse --git-dir
    [ "$status" -ne 0 ]

    local output_file="$TEST_DIR/output.txt"
    cat > "$output_file" << 'EOF'
---RALPH_STATUS---
STATUS: IN_PROGRESS
FILES_MODIFIED: invalid
EXIT_SIGNAL: false
---END_RALPH_STATUS---
EOF

    run analyze_response "$output_file" 1 "$RALPH_DIR/.response_analysis"
    [ "$status" -eq 0 ]

    [ -f "$RALPH_DIR/.response_analysis" ]
    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    [ "$has_progress" = "false" ]
}
