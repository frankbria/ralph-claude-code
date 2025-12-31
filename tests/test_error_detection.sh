#!/bin/bash
# Test script for error detection fix
# Validates that JSON field names don't trigger false positives

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
trap 'rm -rf "$TEST_DIR"' EXIT

# Helper function to run tests
run_test() {
    local test_name="$1"
    local test_file="$2"
    local expected_result="$3"  # "true" or "false"

    echo -e "\n${YELLOW}Running test: $test_name${NC}"

    # Apply the error detection logic (same as in ralph_loop.sh)
    local has_errors="false"
    if grep -v '"[^"]*error[^"]*":' "$test_file" 2>/dev/null | \
       grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
        has_errors="true"
    fi

    # Check result
    if [[ "$has_errors" == "$expected_result" ]]; then
        echo -e "${GREEN}✓ PASS${NC} - Expected: $expected_result, Got: $has_errors"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC} - Expected: $expected_result, Got: $has_errors"
        echo "File contents:"
        cat "$test_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "========================================"
echo "Error Detection Test Suite"
echo "========================================"

# Test 1: JSON with "is_error": false should NOT trigger
cat > "$TEST_DIR/test1.txt" << 'EOF'
{
  "status": "success",
  "is_error": false,
  "message": "Operation completed successfully"
}
EOF
run_test "JSON with is_error: false" "$TEST_DIR/test1.txt" "false"

# Test 2: JSON with "error": null should NOT trigger
cat > "$TEST_DIR/test2.txt" << 'EOF'
{
  "status": "ok",
  "error": null,
  "error_count": 0,
  "has_error": false
}
EOF
run_test "JSON with error: null" "$TEST_DIR/test2.txt" "false"

# Test 3: Actual error message SHOULD trigger
cat > "$TEST_DIR/test3.txt" << 'EOF'
Running build process...
Error: Failed to compile src/main.ts
  Type error on line 42
EOF
run_test "Actual error message" "$TEST_DIR/test3.txt" "true"

# Test 4: Exception in log SHOULD trigger
cat > "$TEST_DIR/test4.txt" << 'EOF'
[2025-12-31 10:30:00] INFO: Starting process
[2025-12-31 10:30:05] ERROR: Unhandled exception in handler
Exception: NullPointerException at line 123
EOF
run_test "Exception in log" "$TEST_DIR/test4.txt" "true"

# Test 5: Mixed content - JSON + real error SHOULD trigger
cat > "$TEST_DIR/test5.txt" << 'EOF'
{
  "is_error": false,
  "status": "running"
}
Processing files...
Fatal: Segmentation fault in module X
EOF
run_test "Mixed JSON and real error" "$TEST_DIR/test5.txt" "true"

# Test 6: Normal output without errors should NOT trigger
cat > "$TEST_DIR/test6.txt" << 'EOF'
Build successful
All tests passed
Deployment complete
EOF
run_test "Normal output no errors" "$TEST_DIR/test6.txt" "false"

# Test 7: Error in context (colon after) SHOULD trigger
cat > "$TEST_DIR/test7.txt" << 'EOF'
[BUILD] Compiling...
[BUILD] Link: error: undefined reference to 'main'
[BUILD] Failed
EOF
run_test "Error with context (colon)" "$TEST_DIR/test7.txt" "true"

# Test 8: Multiple JSON fields with "error" should NOT trigger
cat > "$TEST_DIR/test8.txt" << 'EOF'
{
  "error_message": "",
  "is_error": false,
  "error_code": 0,
  "has_errors": false,
  "error_list": []
}
EOF
run_test "Multiple JSON error fields" "$TEST_DIR/test8.txt" "false"

# Test 9: Case sensitivity - ERROR SHOULD trigger
cat > "$TEST_DIR/test9.txt" << 'EOF'
SYSTEM LOG:
ERROR: Database connection failed
Retrying...
EOF
run_test "Uppercase ERROR message" "$TEST_DIR/test9.txt" "true"

# Test 10: Words "cannot" and "unable" in actual error context SHOULD trigger
cat > "$TEST_DIR/test10.txt" << 'EOF'
Build process started
Error: unable to access file system
cannot proceed with deployment
EOF
run_test "Cannot/unable in error context" "$TEST_DIR/test10.txt" "true"

# Test 11: Documentation mentioning "error" should NOT trigger
cat > "$TEST_DIR/test11.txt" << 'EOF'
# Error Handling Guide

This document describes how to handle errors in the application.
When an error occurs, the system will log it and continue.
EOF
run_test "Documentation about errors" "$TEST_DIR/test11.txt" "false"

# Test 12: Git diff with error keywords should NOT trigger
cat > "$TEST_DIR/test12.txt" << 'EOF'
diff --git a/src/error.ts b/src/error.ts
+export class ErrorHandler {
+  handleError(error: Error) {
+    console.log(error);
EOF
run_test "Git diff with error class" "$TEST_DIR/test12.txt" "false"

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
