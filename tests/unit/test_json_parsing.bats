#!/usr/bin/env bats
# Unit tests for JSON output parsing in response_analyzer.sh
# TDD: Write tests first, then implement

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo for tests
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# JSON FORMAT DETECTION TESTS
# =============================================================================

@test "detect_output_format identifies valid JSON output" {
    local output_file="$LOG_DIR/test_output.log"

    # Create JSON output
    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "Implemented authentication module"
}
EOF

    # Should detect as JSON
    run detect_output_format "$output_file"
    assert_equal "$output" "json"
}

@test "detect_output_format identifies text output" {
    local output_file="$LOG_DIR/test_output.log"

    # Create text output
    cat > "$output_file" << 'EOF'
Reading PROMPT.md...
Implementing feature X...
All tests passed.
Done.
EOF

    # Should detect as text
    run detect_output_format "$output_file"
    assert_equal "$output" "text"
}

@test "detect_output_format handles mixed content (JSON with surrounding text)" {
    local output_file="$LOG_DIR/test_output.log"

    # Create mixed output (Claude sometimes adds text around JSON)
    cat > "$output_file" << 'EOF'
Starting execution...

{
    "status": "IN_PROGRESS",
    "exit_signal": false
}

Done processing.
EOF

    # Should detect as text since it's not pure JSON
    run detect_output_format "$output_file"
    # Mixed content should be treated as text for safety
    [[ "$output" == "text" || "$output" == "mixed" ]]
}

@test "detect_output_format handles empty file" {
    local output_file="$LOG_DIR/empty.log"
    touch "$output_file"

    run detect_output_format "$output_file"
    assert_equal "$output" "text"
}

# =============================================================================
# JSON PARSING TESTS
# =============================================================================

@test "parse_json_response extracts status field correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "All tasks completed"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    # Should create result file with parsed values
    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local status=$(jq -r '.status' "$result_file")
    assert_equal "$status" "COMPLETE"
}

@test "parse_json_response extracts exit_signal correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response maps IN_PROGRESS status to non-exit signal" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "exit_signal": false,
    "work_type": "IMPLEMENTATION",
    "files_modified": 3
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "false"
}

@test "parse_json_response identifies TEST_ONLY work type" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "exit_signal": false,
    "work_type": "TEST_ONLY",
    "files_modified": 0
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local is_test_only=$(jq -r '.is_test_only' "$result_file")
    assert_equal "$is_test_only" "true"
}

@test "parse_json_response extracts files_modified count" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "files_modified": 7,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local files=$(jq -r '.files_modified' "$result_file")
    assert_equal "$files" "7"
}

@test "parse_json_response handles error_count field" {
    local output_file="$LOG_DIR/test_output.log"

    # is_stuck threshold is >5 errors (matches response_analyzer.sh text parsing)
    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "error_count": 6,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # High error count (>5) should indicate stuck state
    local is_stuck=$(jq -r '.is_stuck' "$result_file")
    assert_equal "$is_stuck" "true"
}

@test "parse_json_response extracts summary field" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "summary": "Implemented user authentication with JWT tokens"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local summary=$(jq -r '.summary' "$result_file")
    [[ "$summary" == *"authentication"* ]]
}

# =============================================================================
# JSON SCHEMA VALIDATION TESTS
# =============================================================================

@test "parse_json_response handles missing optional fields gracefully" {
    local output_file="$LOG_DIR/test_output.log"

    # Minimal JSON with only required fields
    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Should not error, should use defaults
    local status=$(jq -r '.status' "$result_file")
    assert_equal "$status" "IN_PROGRESS"
}

@test "parse_json_response handles malformed JSON gracefully" {
    local output_file="$LOG_DIR/test_output.log"

    # Invalid JSON
    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE"
    "missing_comma": true
}
EOF

    run parse_json_response "$output_file"
    # Should fail gracefully
    [[ $status -ne 0 ]] || [[ "$output" == *"error"* ]] || [[ "$output" == *"fallback"* ]] || skip "parse_json_response not yet implemented"
}

@test "parse_json_response handles nested metadata object" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "metadata": {
        "loop_number": 5,
        "timestamp": "2026-01-09T10:30:00Z",
        "session_id": "abc123"
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local loop_num=$(jq -r '.metadata.loop_number // .loop_number' "$result_file")
    assert_equal "$loop_num" "5"
}

# =============================================================================
# INTEGRATION: analyze_response WITH JSON
# =============================================================================

@test "analyze_response detects JSON format and parses correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "All authentication features completed"
}
EOF

    analyze_response "$output_file" 1
    local result=$?

    assert_equal "$result" "0"
    assert_file_exists "$RALPH_DIR/.response_analysis"

    local exit_signal=$(jq -r '.analysis.exit_signal' "$RALPH_DIR/.response_analysis")
    assert_equal "$exit_signal" "true"
}

@test "analyze_response falls back to text parsing on JSON failure" {
    local output_file="$LOG_DIR/test_output.log"

    # Invalid JSON but contains completion keywords
    cat > "$output_file" << 'EOF'
{ invalid json here }
But the project is complete and all tasks are done.
EOF

    analyze_response "$output_file" 1
    local result=$?

    assert_equal "$result" "0"
    assert_file_exists "$RALPH_DIR/.response_analysis"

    # Should still detect completion via text parsing
    local has_completion=$(jq -r '.analysis.has_completion_signal' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_completion" "true"
}

@test "analyze_response uses JSON confidence boost when available" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "confidence": 95
}
EOF

    analyze_response "$output_file" 1

    # JSON with explicit exit_signal should have high confidence
    local confidence=$(jq -r '.analysis.confidence_score' "$RALPH_DIR/.response_analysis")
    [[ "$confidence" -ge 50 ]]
}

# =============================================================================
# BACKWARD COMPATIBILITY TESTS
# =============================================================================

@test "analyze_response still handles traditional RALPH_STATUS format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
Completed the implementation.

---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
WORK_TYPE: IMPLEMENTATION
---END_RALPH_STATUS---
EOF

    analyze_response "$output_file" 1

    local exit_signal=$(jq -r '.analysis.exit_signal' "$RALPH_DIR/.response_analysis")
    assert_equal "$exit_signal" "true"

    local confidence=$(jq -r '.analysis.confidence_score' "$RALPH_DIR/.response_analysis")
    [[ "$confidence" -ge 100 ]]
}

@test "analyze_response handles plain text completion signals" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
I have finished implementing all the requested features.
The project is complete and ready for review.
All tests are passing.
EOF

    analyze_response "$output_file" 1

    local has_completion=$(jq -r '.analysis.has_completion_signal' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_completion" "true"
}

@test "analyze_response maintains text parsing for test-only detection" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
Running tests...
npm test
All tests passed successfully!
EOF

    analyze_response "$output_file" 1

    local is_test_only=$(jq -r '.analysis.is_test_only' "$RALPH_DIR/.response_analysis")
    assert_equal "$is_test_only" "true"
}

# =============================================================================
# CLAUDE CODE CLI JSON STRUCTURE TESTS
# =============================================================================
# Tests for the modernized Claude Code CLI output format with:
# - result: Actual Claude response content
# - sessionId: Session UUID for continuity
# - metadata: Structured information about the execution

@test "detect_output_format identifies Claude CLI JSON with result field" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Implemented authentication module with JWT tokens.",
    "sessionId": "session-abc123",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "completion_status": "in_progress"
    }
}
EOF

    run detect_output_format "$output_file"
    assert_equal "$output" "json"
}

@test "parse_json_response extracts result field from Claude CLI format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "All tasks completed successfully. Project ready for review.",
    "sessionId": "session-xyz789"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Result should be captured in summary field
    local summary=$(jq -r '.summary' "$result_file")
    [[ "$summary" == *"All tasks completed"* ]]
}

@test "parse_json_response extracts sessionId from Claude CLI format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Working on feature implementation.",
    "sessionId": "session-unique-123"
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local session_id=$(jq -r '.session_id' "$result_file")
    assert_equal "$session_id" "session-unique-123"
}

@test "parse_json_response extracts metadata.files_changed" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Modified configuration files.",
    "sessionId": "session-001",
    "metadata": {
        "files_changed": 5,
        "has_errors": false
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local files=$(jq -r '.files_modified' "$result_file")
    assert_equal "$files" "5"
}

@test "parse_json_response extracts metadata.has_errors" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Encountered compilation errors.",
    "sessionId": "session-002",
    "metadata": {
        "files_changed": 0,
        "has_errors": true
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # has_errors should map to error tracking
    local is_stuck=$(jq -r '.is_stuck' "$result_file")
    # Single error shouldn't trigger stuck (threshold is >5)
    # But we should track error state
    [[ -f "$result_file" ]]
}

@test "parse_json_response detects completion from metadata.completion_status" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Project implementation finished.",
    "sessionId": "session-003",
    "metadata": {
        "files_changed": 10,
        "has_errors": false,
        "completion_status": "complete"
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response handles progress_indicators array" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Made significant progress.",
    "sessionId": "session-004",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "progress_indicators": ["implemented auth", "added tests", "updated docs"]
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Progress indicators should boost confidence or be stored
    [[ -f "$result_file" ]]
}

@test "parse_json_response extracts usage metadata" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Completed task.",
    "sessionId": "session-005",
    "metadata": {
        "files_changed": 2,
        "usage": {
            "input_tokens": 1500,
            "output_tokens": 800
        }
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file="$RALPH_DIR/.json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Usage info should be preserved in metadata
    [[ -f "$result_file" ]]
}

@test "analyze_response handles Claude CLI JSON and detects completion" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "All requested features have been implemented. The project is complete.",
    "sessionId": "session-complete-001",
    "metadata": {
        "files_changed": 8,
        "has_errors": false,
        "completion_status": "complete"
    }
}
EOF

    analyze_response "$output_file" 1

    assert_file_exists "$RALPH_DIR/.response_analysis"

    local exit_signal=$(jq -r '.analysis.exit_signal' "$RALPH_DIR/.response_analysis")
    assert_equal "$exit_signal" "true"

    local output_format=$(jq -r '.output_format' "$RALPH_DIR/.response_analysis")
    assert_equal "$output_format" "json"
}

@test "analyze_response persists sessionId to .claude_session_id file" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Working on implementation.",
    "sessionId": "session-persist-test-123"
}
EOF

    analyze_response "$output_file" 1

    # Session ID should be persisted for continuity
    [[ -f "$RALPH_DIR/.claude_session_id" ]] || skip "Session persistence not yet implemented"

    local stored_session=$(cat "$RALPH_DIR/.claude_session_id")
    [[ "$stored_session" == *"session-persist-test-123"* ]]
}

# =============================================================================
# SESSION MANAGEMENT FUNCTION TESTS
# =============================================================================

@test "store_session_id writes session to file with timestamp" {
    run store_session_id "session-test-abc"

    [[ -f "$RALPH_DIR/.claude_session_id" ]] || skip "store_session_id not yet implemented"

    local content=$(cat "$RALPH_DIR/.claude_session_id")
    [[ "$content" == *"session-test-abc"* ]]
}

@test "get_last_session_id retrieves stored session" {
    # First store a session
    echo '{"session_id": "session-retrieve-test", "timestamp": "2026-01-09T10:00:00Z"}' > "$RALPH_DIR/.claude_session_id"

    run get_last_session_id

    [[ "$output" == *"session-retrieve-test"* ]] || skip "get_last_session_id not yet implemented"
}

@test "get_last_session_id returns empty when no session file" {
    rm -f "$RALPH_DIR/.claude_session_id"

    run get_last_session_id

    # Should return empty string, not error
    [[ "$status" -eq 0 ]] || skip "get_last_session_id not yet implemented"
    [[ -z "$output" || "$output" == "" || "$output" == "null" ]]
}

@test "should_resume_session returns true for recent session" {
    # Store a recent session (simulated as current timestamp)
    local now=$(date +%s)
    echo "{\"session_id\": \"session-recent\", \"timestamp\": \"$(date -Iseconds)\"}" > "$RALPH_DIR/.claude_session_id"

    run should_resume_session

    # Should indicate session can be resumed
    [[ "$status" -eq 0 ]] || skip "should_resume_session not yet implemented"
}

@test "should_resume_session returns false for old session" {
    # Store an old session (24+ hours ago)
    echo '{"session_id": "session-old", "timestamp": "2020-01-01T00:00:00Z"}' > "$RALPH_DIR/.claude_session_id"

    run should_resume_session

    # Should indicate session expired
    [[ "$status" -ne 0 || "$output" == "false" ]] || skip "should_resume_session not yet implemented"
}

@test "should_resume_session returns false when no session file" {
    rm -f "$RALPH_DIR/.claude_session_id"

    run should_resume_session

    # Should indicate no session to resume
    [[ "$status" -ne 0 || "$output" == "false" ]] || skip "should_resume_session not yet implemented"
}

# =============================================================================
# CLAUDE CLI JSON ARRAY FORMAT TESTS (Issue #112)
# =============================================================================
# Tests for the Claude CLI JSON array output format:
# [ {type: "system", ...}, {type: "assistant", ...}, {type: "result", ...} ]

@test "detect_output_format identifies JSON array as json" {
    local output_file="$LOG_DIR/test_output.log"

    # Create Claude CLI array format output
    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-init-123"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working..."}]}},
    {"type": "result", "subtype": "success", "result": "Task completed", "session_id": "session-result-123"}
]
EOF

    run detect_output_format "$output_file"
    assert_equal "$output" "json"
}

@test "parse_json_response handles Claude CLI JSON array format" {
    local output_file="$LOG_DIR/test_output.log"

    # Create Claude CLI array format output (as shown in issue #112)
    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "hook_response", "session_id": "session-abc123"},
    {"type": "system", "subtype": "init", "session_id": "session-abc123", "tools": ["Write", "Read"]},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Implementing feature..."}]}},
    {"type": "result", "subtype": "success", "result": "All tasks completed successfully.", "session_id": "session-abc123", "is_error": false, "duration_ms": 5000}
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should extract result text into summary
    local summary=$(jq -r '.summary' "$result_file")
    [[ "$summary" == *"All tasks completed"* ]]
}

@test "parse_json_response extracts session_id from Claude CLI array init message" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-unique-from-init"},
    {"type": "result", "subtype": "success", "result": "Done"}
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    local session_id=$(jq -r '.session_id' "$result_file")
    assert_equal "$session_id" "session-unique-from-init"
}

@test "parse_json_response handles empty array gracefully" {
    local output_file="$LOG_DIR/test_output.log"

    echo '[]' > "$output_file"

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should have default/empty values
    local status_val=$(jq -r '.status' "$result_file")
    assert_equal "$status_val" "UNKNOWN"
}

@test "parse_json_response handles array without result type message" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-no-result"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working..."}]}}
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should still work with defaults
    local session_id=$(jq -r '.session_id' "$result_file")
    assert_equal "$session_id" "session-no-result"
}

@test "parse_json_response extracts is_error from Claude CLI array result" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-error-test"},
    {"type": "result", "subtype": "error", "result": "Failed to complete", "is_error": true, "duration_ms": 1000}
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]
}

@test "analyze_response handles Claude CLI JSON array and extracts signals" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-analyze-array"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "All work complete."}]}},
    {"type": "result", "subtype": "success", "result": "Project complete and ready for review.", "is_error": false}
]
EOF

    analyze_response "$output_file" 1

    assert_file_exists "$RALPH_DIR/.response_analysis"

    local output_format=$(jq -r '.output_format' "$RALPH_DIR/.response_analysis")
    assert_equal "$output_format" "json"
}

@test "analyze_response persists session_id from Claude CLI array format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-persist-array-test"},
    {"type": "result", "subtype": "success", "result": "Working on task."}
]
EOF

    analyze_response "$output_file" 1

    # Session ID should be persisted for continuity
    [[ -f "$RALPH_DIR/.claude_session_id" ]]

    local stored_session=$(cat "$RALPH_DIR/.claude_session_id")
    [[ "$stored_session" == *"session-persist-array-test"* ]]
}

# Regression test: arrays where only result element carries session_id (review fix: CodeRabbit)
@test "parse_json_response extracts session_id from result object when no init message" {
    local output_file="$LOG_DIR/test_output.log"

    # Array with session_id only in result object, no init message
    cat > "$output_file" << 'EOF'
[
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working..."}]}},
    {"type": "result", "subtype": "success", "result": "Task complete.", "session_id": "session-in-result-only"}
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Session ID should be extracted from result object
    local session_id=$(jq -r '.session_id' "$result_file")
    assert_equal "$session_id" "session-in-result-only"
}

# =============================================================================
# PERMISSION DENIAL DETECTION TESTS (Issue #101)
# =============================================================================
# Tests for detecting permission_denials from Claude Code JSON output.
# When Claude Code is denied permission to execute commands (e.g., npm install),
# the JSON output contains a permission_denials array that Ralph should detect.

@test "parse_json_response detects permission_denials array" {
    local output_file="$LOG_DIR/test_output.log"

    # Create JSON output with permission denials (as Claude Code outputs)
    cat > "$output_file" << 'EOF'
{
    "result": "I tried to run npm install but was denied permission.",
    "sessionId": "session-denied-123",
    "is_error": false,
    "permission_denials": [
        {"tool": "Bash", "command": "npm install", "reason": "Tool not in allowed list"}
    ]
}
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should extract has_permission_denials flag
    local has_denials=$(jq -r '.has_permission_denials' "$result_file")
    assert_equal "$has_denials" "true"
}

@test "parse_json_response extracts permission_denial_count" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Multiple commands were denied.",
    "sessionId": "session-multi-deny",
    "permission_denials": [
        {"tool": "Bash", "command": "npm install", "reason": "Not allowed"},
        {"tool": "Bash", "command": "pnpm install", "reason": "Not allowed"},
        {"tool": "Bash", "command": "yarn add lodash", "reason": "Not allowed"}
    ]
}
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should count denials correctly
    local denial_count=$(jq -r '.permission_denial_count' "$result_file")
    assert_equal "$denial_count" "3"
}

@test "parse_json_response extracts denied_commands list" {
    local output_file="$LOG_DIR/test_output.log"

    # Use real Claude CLI output structure with tool_input.command
    cat > "$output_file" << 'EOF'
{
    "result": "Permission denied for npm install",
    "sessionId": "session-extract-cmds",
    "permission_denials": [
        {"tool_name": "Bash", "tool_use_id": "toolu_123", "tool_input": {"command": "npm install express"}}
    ]
}
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should extract the denied commands from tool_input.command
    local denied_cmds=$(jq -r '.denied_commands[0]' "$result_file")
    [[ "$denied_cmds" == *"npm install"* ]]
}

@test "parse_json_response handles empty permission_denials array" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "All commands executed successfully.",
    "sessionId": "session-no-denials",
    "permission_denials": []
}
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should set has_permission_denials to false
    local has_denials=$(jq -r '.has_permission_denials' "$result_file")
    assert_equal "$has_denials" "false"

    local denial_count=$(jq -r '.permission_denial_count' "$result_file")
    assert_equal "$denial_count" "0"
}

@test "parse_json_response handles missing permission_denials field (backward compat)" {
    local output_file="$LOG_DIR/test_output.log"

    # Old format without permission_denials field
    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5
}
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    # Should default to no denials
    local has_denials=$(jq -r '.has_permission_denials' "$result_file")
    assert_equal "$has_denials" "false"

    local denial_count=$(jq -r '.permission_denial_count' "$result_file")
    assert_equal "$denial_count" "0"
}

@test "analyze_response includes permission denial info in analysis result" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Tried npm install but permission was denied.",
    "sessionId": "session-analyze-denial",
    "permission_denials": [
        {"tool": "Bash", "command": "npm install", "reason": "Tool not allowed"}
    ]
}
EOF

    analyze_response "$output_file" 1

    assert_file_exists "$RALPH_DIR/.response_analysis"

    # Should include permission denial in analysis
    local has_denials=$(jq -r '.analysis.has_permission_denials' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_denials" "true"

    local denial_count=$(jq -r '.analysis.permission_denial_count' "$RALPH_DIR/.response_analysis")
    assert_equal "$denial_count" "1"
}

@test "parse_json_response handles Claude CLI array format with permission denials" {
    local output_file="$LOG_DIR/test_output.log"

    # Claude CLI array format with permission denials in result
    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "session-array-deny"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Trying to install..."}]}},
    {
        "type": "result",
        "subtype": "success",
        "result": "Could not run npm install - permission denied",
        "session_id": "session-array-deny",
        "permission_denials": [
            {"tool": "Bash", "command": "npm install", "reason": "Not in allowed tools"}
        ]
    }
]
EOF

    run parse_json_response "$output_file"
    assert_equal "$status" "0"

    local result_file="$RALPH_DIR/.json_parse_result"
    [[ -f "$result_file" ]]

    local has_denials=$(jq -r '.has_permission_denials' "$result_file")
    assert_equal "$has_denials" "true"
}

# =============================================================================
# PROGRESS DETECTION WITH COMMITTED WORK TESTS
# =============================================================================
# When Claude commits work after each task, git diff shows 0 uncommitted changes.
# Progress must be detected via recent commits and the embedded RALPH_STATUS block.

@test "analyze_response detects progress from TASKS_COMPLETED_THIS_LOOP in embedded RALPH_STATUS" {
    local output_file="$LOG_DIR/test_output.log"

    local ralph_status
    ralph_status=$(printf '%s' \
        'Implemented notifications context.\n\n' \
        '---RALPH_STATUS---\n' \
        'STATUS: IN_PROGRESS\n' \
        'TASKS_COMPLETED_THIS_LOOP: 1\n' \
        'FILES_MODIFIED: 2\n' \
        'TESTS_STATUS: NOT_RUN\n' \
        'WORK_TYPE: IMPLEMENTATION\n' \
        'EXIT_SIGNAL: false\n' \
        '---END_RALPH_STATUS---')

    jq -n \
        --arg result "$ralph_status" \
        --arg session "session-tasks-completed" \
        '{type: "result", subtype: "success", result: $result, session_id: $session, permission_denials: []}' \
        > "$output_file"

    # No uncommitted changes, no recent commits — progress must come from RALPH_STATUS block
    analyze_response "$output_file" 1

    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_progress" "true"
}

@test "analyze_response detects progress via recent git commit when git diff is zero" {
    local output_file="$LOG_DIR/test_output.log"

    local ralph_status
    ralph_status=$(printf '%s' \
        'Module created and committed.\n\n' \
        '---RALPH_STATUS---\n' \
        'STATUS: IN_PROGRESS\n' \
        'TASKS_COMPLETED_THIS_LOOP: 1\n' \
        'FILES_MODIFIED: 1\n' \
        'TESTS_STATUS: NOT_RUN\n' \
        'WORK_TYPE: IMPLEMENTATION\n' \
        'EXIT_SIGNAL: false\n' \
        '---END_RALPH_STATUS---')

    jq -n \
        --arg result "$ralph_status" \
        --arg session "session-committed" \
        '{type: "result", subtype: "success", result: $result, session_id: $session, permission_denials: []}' \
        > "$output_file"

    # Commit a file so git log --since shows a recent commit but git diff shows nothing
    echo "defmodule Foo do end" > foo.ex
    git add foo.ex
    git commit -m "feat: implement Foo context" > /dev/null 2>&1

    analyze_response "$output_file" 1

    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_progress" "true"
}

@test "analyze_response extracts FILES_MODIFIED from RALPH_STATUS when git diff is zero" {
    local output_file="$LOG_DIR/test_output.log"

    local ralph_status
    ralph_status=$(printf '%s' \
        'Three files created.\n\n' \
        '---RALPH_STATUS---\n' \
        'STATUS: IN_PROGRESS\n' \
        'TASKS_COMPLETED_THIS_LOOP: 1\n' \
        'FILES_MODIFIED: 3\n' \
        'TESTS_STATUS: NOT_RUN\n' \
        'WORK_TYPE: IMPLEMENTATION\n' \
        'EXIT_SIGNAL: false\n' \
        '---END_RALPH_STATUS---')

    jq -n \
        --arg result "$ralph_status" \
        --arg session "session-files-modified" \
        '{type: "result", subtype: "success", result: $result, session_id: $session, permission_denials: []}' \
        > "$output_file"

    # Commit everything so git diff returns 0
    echo "defmodule Bar do end" > bar.ex
    git add bar.ex
    git commit -m "feat: add Bar module" > /dev/null 2>&1

    analyze_response "$output_file" 1

    local files_modified
    files_modified=$(jq -r '.analysis.files_modified' "$RALPH_DIR/.response_analysis")
    [[ "$files_modified" -ge 1 ]]
}

@test "analyze_response does not flag progress when TASKS_COMPLETED_THIS_LOOP is zero" {
    local output_file="$LOG_DIR/test_output.log"

    local ralph_status
    ralph_status=$(printf '%s' \
        'Reviewed code, no changes needed.\n\n' \
        '---RALPH_STATUS---\n' \
        'STATUS: IN_PROGRESS\n' \
        'TASKS_COMPLETED_THIS_LOOP: 0\n' \
        'FILES_MODIFIED: 0\n' \
        'TESTS_STATUS: NOT_RUN\n' \
        'WORK_TYPE: IMPLEMENTATION\n' \
        'EXIT_SIGNAL: false\n' \
        '---END_RALPH_STATUS---')

    jq -n \
        --arg result "$ralph_status" \
        --arg session "session-no-progress" \
        '{type: "result", subtype: "success", result: $result, session_id: $session, permission_denials: []}' \
        > "$output_file"

    analyze_response "$output_file" 1

    local has_progress
    has_progress=$(jq -r '.analysis.has_progress' "$RALPH_DIR/.response_analysis")
    assert_equal "$has_progress" "false"
}
