#!/bin/bash
# Test script for detect_stuck_loop function
# Validates that the stuck loop detection uses two-stage filtering
# to avoid false positives from JSON fields
#
# TEST STRATEGY:
# The detect_stuck_loop function extracts errors from current output and checks
# if the same errors appear in the last 3 historical outputs. This test validates:
#
# 1. Two-stage filtering is applied (same as analyze_response)
# 2. JSON field names don't cause false stuck loop detection
# 3. Actual repeated errors are correctly detected
# 4. Function returns appropriate exit codes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Create temporary directory for test files
TEST_DIR=$(mktemp -d)
HISTORY_DIR="$TEST_DIR/logs"
mkdir -p "$HISTORY_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Source the response_analyzer.sh to get access to detect_stuck_loop function
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/response_analyzer.sh"

# Helper function to run tests
run_test() {
    local test_name="$1"
    local expected_result="$2"  # 0 = stuck detected, 1 = not stuck

    echo -e "\n${YELLOW}Running test: $test_name${NC}"

    # Call detect_stuck_loop function
    local result=1
    if detect_stuck_loop "$TEST_DIR/current_output.log" "$HISTORY_DIR"; then
        result=0
    else
        result=1
    fi

    # Check result
    if [[ $result -eq $expected_result ]]; then
        echo -e "${GREEN}✓ PASS${NC} - Expected exit code: $expected_result, Got: $result"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC} - Expected exit code: $expected_result, Got: $result"
        echo "Current output:"
        cat "$TEST_DIR/current_output.log"
        echo "History files:"
        ls -la "$HISTORY_DIR"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "========================================"
echo "Stuck Loop Detection Test Suite"
echo "========================================"

# Test 1: No history - should return not stuck (exit code 1)
cat > "$TEST_DIR/current_output.log" << 'EOF'
Error: Build failed
EOF
# Empty history directory
rm -f "$HISTORY_DIR"/*
run_test "No history available" 1

# Create history directory again for next tests
mkdir -p "$HISTORY_DIR"

# Test 2: JSON with "is_error": false should NOT trigger stuck detection
cat > "$TEST_DIR/current_output.log" << 'EOF'
{
  "is_error": false,
  "error_count": 0,
  "status": "success"
}
EOF
# Create 3 history files with same JSON
for i in 1 2 3; do
    cat > "$HISTORY_DIR/claude_output_00${i}.log" << 'EOF'
{
  "is_error": false,
  "error_count": 0,
  "status": "success"
}
EOF
done
run_test "JSON fields should not trigger stuck detection" 1

# Test 3: Actual repeated errors should trigger stuck detection
cat > "$TEST_DIR/current_output.log" << 'EOF'
Build started
Error: Failed to compile src/main.ts
Type error on line 42
EOF
# Create 3 history files with same error
for i in 1 2 3; do
    sleep 0.1  # Ensure different timestamps
    cat > "$HISTORY_DIR/claude_output_00${i}.log" << 'EOF'
Build started
Error: Failed to compile src/main.ts
Type error on line 42
EOF
done
run_test "Repeated actual errors trigger stuck detection" 0

# Test 4: Different errors should NOT trigger stuck detection
cat > "$TEST_DIR/current_output.log" << 'EOF'
Error: Database connection failed
EOF
# Create history with different errors
sleep 0.1
cat > "$HISTORY_DIR/claude_output_001.log" << 'EOF'
Error: File not found
EOF
sleep 0.1
cat > "$HISTORY_DIR/claude_output_002.log" << 'EOF'
Error: Permission denied
EOF
sleep 0.1
cat > "$HISTORY_DIR/claude_output_003.log" << 'EOF'
Error: Network timeout
EOF
run_test "Different errors should not trigger stuck detection" 1

# Test 5: No errors in current output should return not stuck
cat > "$TEST_DIR/current_output.log" << 'EOF'
Build successful
All tests passed
Deployment complete
EOF
# History doesn't matter if current has no errors
run_test "No errors in current output" 1

# Test 6: Mixed JSON + real error - only real error should be extracted
cat > "$TEST_DIR/current_output.log" << 'EOF'
{
  "is_error": false,
  "status": "processing"
}
Error: Compilation failed
EOF
# Create history with same real error (JSON part varies)
for i in 1 2 3; do
    sleep 0.1
    cat > "$HISTORY_DIR/claude_output_00${i}.log" << 'EOF'
{
  "is_error": false,
  "status": "different"
}
Error: Compilation failed
EOF
done
run_test "Mixed JSON and error - only error matters" 0

# Test 7: Type annotations should not trigger stuck detection
cat > "$TEST_DIR/current_output.log" << 'EOF'
diff --git a/src/error.ts b/src/error.ts
+export class ErrorHandler {
+  handleError(error: Error) {
+    console.log(error);
EOF
# Create history with similar code diffs
for i in 1 2 3; do
    sleep 0.1
    cat > "$HISTORY_DIR/claude_output_00${i}.log" << 'EOF'
diff --git a/src/error.ts b/src/error.ts
+export class ErrorHandler {
+  handleError(error: Error) {
+    console.log(error);
EOF
done
run_test "Type annotations should not trigger stuck detection" 1

# Print summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "========================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
