#!/usr/bin/env bats
# Unit tests for wizard_utils.sh
# Tests for stdout/stderr separation to prevent ANSI code capture in command substitution

load '../helpers/test_helper'

# Path to the library
WIZARD_UTILS="${BATS_TEST_DIRNAME}/../../lib/wizard_utils.sh"

setup() {
    # Source the wizard utils
    source "$WIZARD_UTILS"
}

# =============================================================================
# PROMPT_TEXT STDOUT/STDERR SEPARATION (4 tests)
# =============================================================================

@test "prompt_text returns only user input on stdout, no ANSI codes" {
    # Simulate user typing "my-project" followed by Enter
    result=$(echo "my-project" | prompt_text "Project name" "default")

    # The captured output should be ONLY "my-project", no ANSI escape codes
    [[ "$result" == "my-project" ]]
    # Should NOT contain ANSI escape sequence
    [[ ! "$result" =~ $'\033' ]]
    [[ ! "$result" =~ "Project name" ]]
}

@test "prompt_text with default returns clean default value on empty input" {
    # Simulate user pressing Enter (empty input)
    result=$(echo "" | prompt_text "Project name" "default-value")

    # Should return only the default value
    [[ "$result" == "default-value" ]]
    # Should NOT contain ANSI escape sequence
    [[ ! "$result" =~ $'\033' ]]
    [[ ! "$result" =~ "Project name" ]]
}

@test "prompt_text without default returns empty string on empty input" {
    # Simulate user pressing Enter (empty input) with no default
    result=$(echo "" | prompt_text "Project name")

    # Should return empty string
    [[ "$result" == "" ]]
}

@test "prompt_text handles special characters in user input" {
    # Test that special characters are preserved
    result=$(echo "my project-name_123" | prompt_text "Name" "default")

    [[ "$result" == "my project-name_123" ]]
}

# =============================================================================
# PROMPT_NUMBER STDOUT/STDERR SEPARATION (5 tests)
# =============================================================================

@test "prompt_number returns only numeric value on stdout, no ANSI codes" {
    # Simulate user typing "100"
    result=$(echo "100" | prompt_number "Max calls" "50")

    # The captured output should be ONLY "100", no ANSI codes
    [[ "$result" == "100" ]]
    # Should NOT contain ANSI escape sequence
    [[ ! "$result" =~ $'\033' ]]
    [[ ! "$result" =~ "Max calls" ]]
}

@test "prompt_number with default returns clean default on empty input" {
    # Simulate user pressing Enter (empty input)
    result=$(echo "" | prompt_number "Max calls" "50")

    # Should return only the default
    [[ "$result" == "50" ]]
    # Should NOT contain ANSI escape sequence
    [[ ! "$result" =~ $'\033' ]]
}

@test "prompt_number validates min value without ANSI in result" {
    # First input is too small, second input is valid
    result=$(printf "5\n20" | prompt_number "Value" "" "10" "100")

    # Should return only the valid number
    [[ "$result" == "20" ]]
    [[ ! "$result" =~ $'\033' ]]
}

@test "prompt_number validates max value without ANSI in result" {
    # First input is too large, second input is valid
    result=$(printf "150\n80" | prompt_number "Value" "" "10" "100")

    # Should return only the valid number
    [[ "$result" == "80" ]]
    [[ ! "$result" =~ $'\033' ]]
}

@test "prompt_number rejects non-numeric input without ANSI in result" {
    # First input is not a number, second input is valid
    result=$(printf "abc\n42" | prompt_number "Value" "")

    # Should return only the valid number
    [[ "$result" == "42" ]]
    [[ ! "$result" =~ $'\033' ]]
}

# =============================================================================
# CONFIRM STDOUT/STDERR SEPARATION (3 tests)
# =============================================================================

@test "confirm sends prompt to stderr not stdout" {
    # Capture stdout only - should be empty
    stdout_output=$(echo "y" | confirm "Continue?" 2>/dev/null)

    # Stdout should be empty (confirm uses return codes, not echo)
    [[ -z "$stdout_output" ]]
}

@test "confirm yes response returns 0" {
    echo "y" | confirm "Continue?" 2>/dev/null
    [[ $? -eq 0 ]]
}

@test "confirm no response returns 1" {
    # Run confirm with "n" response, expect return code 1 (no)
    run bash -c 'source '"$WIZARD_UTILS"' && echo "n" | confirm "Continue?" 2>/dev/null'
    [[ $status -eq 1 ]]
}

# =============================================================================
# SELECT_OPTION STDOUT/STDERR SEPARATION (3 tests)
# =============================================================================

@test "select_option returns only selected option on stdout, no ANSI codes" {
    # Simulate user selecting option 2
    result=$(echo "2" | select_option "Choose one" "first" "second" "third")

    # Should return only "second"
    [[ "$result" == "second" ]]
    [[ ! "$result" =~ $'\033' ]]
    [[ ! "$result" =~ "Choose one" ]]
}

@test "select_option handles first option selection" {
    result=$(echo "1" | select_option "Choose" "alpha" "beta")

    [[ "$result" == "alpha" ]]
    [[ ! "$result" =~ $'\033' ]]
}

@test "select_option retries on invalid input without ANSI in result" {
    # First input is invalid, second input is valid
    result=$(printf "abc\n2" | select_option "Choose" "one" "two")

    [[ "$result" == "two" ]]
    [[ ! "$result" =~ $'\033' ]]
}

# =============================================================================
# SELECT_WITH_DEFAULT STDOUT/STDERR SEPARATION (3 tests)
# =============================================================================

@test "select_with_default returns selected option on stdout, no ANSI codes" {
    # Simulate user selecting option 2
    result=$(echo "2" | select_with_default "Choose" 1 "default" "other")

    [[ "$result" == "other" ]]
    [[ ! "$result" =~ $'\033' ]]
}

@test "select_with_default returns default on empty input" {
    # Simulate user pressing Enter
    result=$(echo "" | select_with_default "Choose" 1 "default" "other")

    [[ "$result" == "default" ]]
    [[ ! "$result" =~ $'\033' ]]
}

@test "select_with_default handles non-first default" {
    # Simulate empty input with default_index=2
    result=$(echo "" | select_with_default "Choose" 2 "first" "second")

    [[ "$result" == "second" ]]
    [[ ! "$result" =~ $'\033' ]]
}

# =============================================================================
# INTEGRATION: RALPHRC GENERATION (2 tests)
# =============================================================================

@test "prompt_text output is safe for shell variable assignment" {
    result=$(echo "test-project" | prompt_text "Project" "default")

    # Result should be safe to assign to a shell variable
    eval "PROJECT_NAME=\"$result\""
    [[ "$PROJECT_NAME" == "test-project" ]]
}

@test "prompt_number output is safe for shell arithmetic" {
    result=$(echo "100" | prompt_number "Calls" "50")

    # Result should be a valid number for arithmetic
    (( result > 0 ))
    [[ "$result" -eq 100 ]]
}
