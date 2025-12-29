#!/usr/bin/env bats
# Unit Tests for Exit Detection Logic

load '../helpers/test_helper'

setup() {
	# Source helper functions
	source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

	# Set up environment
	export EXIT_SIGNALS_FILE=".exit_signals"
	export MAX_CONSECUTIVE_TEST_LOOPS=3
	export MAX_CONSECUTIVE_DONE_SIGNALS=2

	# Create temp test directory
	export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
	cd "$TEST_TEMP_DIR"

	# Initialize exit signals file
	echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"
}

teardown() {
	cd /
	rm -rf "$TEST_TEMP_DIR"
}

# Helper function: should_exit_gracefully (extracted from ralph_loop.sh)
should_exit_gracefully() {
	if [[ ! -f $EXIT_SIGNALS_FILE ]]; then
		echo ""  # Return empty string instead of using return code
		return 1 # Don't exit, file doesn't exist
	fi

	local signals=$(cat "$EXIT_SIGNALS_FILE")

	# Count recent signals (last 5 loops) - with error handling
	local recent_test_loops
	local recent_done_signals
	local recent_completion_indicators

	recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
	recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
	recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

	# Check for exit conditions

	# 1. Too many consecutive test-only loops
	if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
		echo "test_saturation"
		return 0
	fi

	# 2. Multiple "done" signals
	if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
		echo "completion_signals"
		return 0
	fi

	# 3. Strong completion indicators
	if [[ $recent_completion_indicators -ge 2 ]]; then
		echo "project_complete"
		return 0
	fi

	# 4. Check fix_plan.md for completion
	if [[ -f "@fix_plan.md" ]]; then
		local total_items=$(grep -c "^- \[" "@fix_plan.md" 2>/dev/null)
		local completed_items=$(grep -c "^- \[x\]" "@fix_plan.md" 2>/dev/null)

		# Handle case where grep returns no matches (exit code 1)
		[[ -z $total_items ]] && total_items=0
		[[ -z $completed_items ]] && completed_items=0

		if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
			echo "plan_complete"
			return 0
		fi
	fi

	echo ""  # Return empty string instead of using return code
	return 1 # Don't exit
}

# Test 1: No exit when signals are empty
@test "should_exit_gracefully returns empty with no signals" {
	echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 2: Exit on test saturation (3 test loops)
@test "should_exit_gracefully exits on test saturation (3 loops)" {
	echo '{"test_only_loops": [1,2,3], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully)
	assert_equal "$result" "test_saturation"
}

# Test 3: Exit on test saturation (4 test loops)
@test "should_exit_gracefully exits on test saturation (4 loops)" {
	echo '{"test_only_loops": [1,2,3,4], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully)
	assert_equal "$result" "test_saturation"
}

# Test 4: No exit with only 2 test loops
@test "should_exit_gracefully continues with 2 test loops" {
	echo '{"test_only_loops": [1,2], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 5: Exit on done signals (2 signals)
@test "should_exit_gracefully exits on 2 done signals" {
	echo '{"test_only_loops": [], "done_signals": [1,2], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" "completion_signals"
}

# Test 6: Exit on done signals (3 signals)
@test "should_exit_gracefully exits on 3 done signals" {
	echo '{"test_only_loops": [], "done_signals": [1,2,3], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" "completion_signals"
}

# Test 7: No exit with only 1 done signal
@test "should_exit_gracefully continues with 1 done signal" {
	echo '{"test_only_loops": [], "done_signals": [1], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 8: Exit on completion indicators (2 indicators)
@test "should_exit_gracefully exits on 2 completion indicators" {
	echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" "project_complete"
}

# Test 9: No exit with only 1 completion indicator
@test "should_exit_gracefully continues with 1 completion indicator" {
	echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1]}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 10: Exit when @fix_plan.md all items complete
@test "should_exit_gracefully exits when all fix_plan items complete" {
	cat >"@fix_plan.md" <<'EOF'
# Fix Plan
- [x] Task 1
- [x] Task 2
- [x] Task 3
EOF

	result=$(should_exit_gracefully)
	assert_equal "$result" "plan_complete"
}

# Test 11: No exit when @fix_plan.md partially complete
@test "should_exit_gracefully continues when fix_plan partially complete" {
	cat >"@fix_plan.md" <<'EOF'
# Fix Plan
- [x] Task 1
- [ ] Task 2
- [ ] Task 3
EOF

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 12: No exit when @fix_plan.md missing
@test "should_exit_gracefully continues when fix_plan missing" {
	# Don't create @fix_plan.md

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 13: No exit when exit signals file missing
@test "should_exit_gracefully continues when exit signals file missing" {
	rm -f "$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 14: Handle corrupted JSON gracefully
@test "should_exit_gracefully handles corrupted JSON" {
	echo 'invalid json{' >"$EXIT_SIGNALS_FILE"

	# Should not crash, should treat as 0 signals
	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 15: Multiple exit conditions simultaneously (test takes priority)
@test "should_exit_gracefully returns first matching condition" {
	echo '{"test_only_loops": [1,2,3,4], "done_signals": [1,2], "completion_indicators": [1,2]}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully)
	# Should return test_saturation (checked first)
	assert_equal "$result" "test_saturation"
}

# Test 16: @fix_plan.md with no checkboxes
@test "should_exit_gracefully handles fix_plan with no checkboxes" {
	cat >"@fix_plan.md" <<'EOF'
# Fix Plan
This is just text, no tasks yet.
EOF

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 17: @fix_plan.md with mixed checkbox formats
@test "should_exit_gracefully handles mixed checkbox formats" {
	cat >"@fix_plan.md" <<'EOF'
# Fix Plan
- [x] Task 1 completed
- [ ] Task 2 pending
- [X] Task 3 completed (uppercase)
- [] Task 4 (invalid format, should not count)
EOF

	result=$(should_exit_gracefully || true)
	# 2 completed out of 3 valid tasks
	assert_equal "$result" ""
}

# Test 18: Empty signals arrays
@test "should_exit_gracefully handles empty arrays correctly" {
	echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully || true)
	assert_equal "$result" ""
}

# Test 19: Threshold boundary test (exactly at threshold)
@test "should_exit_gracefully exits at exact threshold for test loops" {
	# MAX_CONSECUTIVE_TEST_LOOPS = 3
	echo '{"test_only_loops": [1,2,3], "done_signals": [], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully)
	assert_equal "$result" "test_saturation"
}

# Test 20: Threshold boundary test (exactly at threshold for done signals)
@test "should_exit_gracefully exits at exact threshold for done signals" {
	# MAX_CONSECUTIVE_DONE_SIGNALS = 2
	echo '{"test_only_loops": [], "done_signals": [1,2], "completion_indicators": []}' >"$EXIT_SIGNALS_FILE"

	result=$(should_exit_gracefully)
	assert_equal "$result" "completion_signals"
}
