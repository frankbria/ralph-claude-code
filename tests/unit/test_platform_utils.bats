#!/usr/bin/env bats
# Unit tests for platform detection and terminal multiplexer utilities
# Tests cross-platform functionality for Linux, macOS, and Windows

load '../helpers/test_helper'

# Path to platform_utils.sh
PLATFORM_UTILS="${BATS_TEST_DIRNAME}/../../lib/platform_utils.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the platform utils
    source "$PLATFORM_UTILS"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# PLATFORM DETECTION TESTS
# =============================================================================

@test "get_platform returns a valid platform string" {
    run get_platform

    assert_success
    # Should return one of: linux, darwin, windows, unknown
    [[ "$output" =~ ^(linux|darwin|windows|unknown)$ ]]
}

@test "get_platform detects current OS correctly" {
    local expected_platform
    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        Linux*)
            expected_platform="linux"
            ;;
        Darwin*)
            expected_platform="darwin"
            ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT*)
            expected_platform="windows"
            ;;
        *)
            expected_platform="unknown"
            ;;
    esac

    run get_platform
    assert_success
    [[ "$output" == "$expected_platform" ]]
}

@test "is_windows returns correct value for current platform" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" == "windows" ]]; then
        run is_windows
        assert_success
    else
        run is_windows
        assert_failure
    fi
}

@test "is_macos returns correct value for current platform" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" == "darwin" ]]; then
        run is_macos
        assert_success
    else
        run is_macos
        assert_failure
    fi
}

@test "is_linux returns correct value for current platform" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" == "linux" ]]; then
        run is_linux
        assert_success
    else
        run is_linux
        assert_failure
    fi
}

# =============================================================================
# TERMINAL MULTIPLEXER DETECTION TESTS
# =============================================================================

@test "has_tmux returns success when tmux is installed" {
    if command -v tmux &>/dev/null; then
        run has_tmux
        assert_success
    else
        run has_tmux
        assert_failure
    fi
}

@test "get_available_multiplexer returns valid multiplexer type" {
    run get_available_multiplexer

    assert_success
    # Should return one of: tmux, windows_terminal, none
    [[ "$output" =~ ^(tmux|windows_terminal|none)$ ]]
}

@test "get_available_multiplexer prefers tmux when available" {
    if command -v tmux &>/dev/null; then
        run get_available_multiplexer
        assert_success
        [[ "$output" == "tmux" ]]
    else
        skip "tmux not installed"
    fi
}

# =============================================================================
# PATH CONVERSION TESTS (Windows-specific)
# =============================================================================

@test "unix_to_windows_path converts /c/path to C:\\path" {
    run unix_to_windows_path "/c/Users/test/project"

    assert_success
    [[ "$output" == "C:\\Users\\test\\project" ]]
}

@test "unix_to_windows_path converts /d/path to D:\\path" {
    run unix_to_windows_path "/d/data/files"

    assert_success
    [[ "$output" == "D:\\data\\files" ]]
}

@test "unix_to_windows_path handles uppercase drive letters" {
    run unix_to_windows_path "/C/Windows/System32"

    assert_success
    [[ "$output" == "C:\\Windows\\System32" ]]
}

@test "unix_to_windows_path returns non-Windows paths unchanged" {
    run unix_to_windows_path "/home/user/project"

    assert_success
    [[ "$output" == "/home/user/project" ]]
}

@test "unix_to_windows_path handles relative paths unchanged" {
    run unix_to_windows_path "./relative/path"

    assert_success
    [[ "$output" == "./relative/path" ]]
}

# =============================================================================
# FUNCTION EXPORT TESTS
# =============================================================================

@test "platform utility functions are exported" {
    # Verify functions are available after sourcing
    run type get_platform
    assert_success
    [[ "$output" == *"function"* ]]

    run type is_windows
    assert_success
    [[ "$output" == *"function"* ]]

    run type has_tmux
    assert_success
    [[ "$output" == *"function"* ]]

    run type get_available_multiplexer
    assert_success
    [[ "$output" == *"function"* ]]
}

# =============================================================================
# WINDOWS TERMINAL DETECTION TESTS
# =============================================================================

@test "has_windows_terminal returns failure on non-Windows systems" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" != "windows" ]]; then
        run has_windows_terminal
        assert_failure
    else
        skip "Running on Windows - test not applicable"
    fi
}

@test "get_windows_terminal_path returns empty on non-Windows systems" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" != "windows" ]]; then
        run get_windows_terminal_path
        # Should fail or return empty
        [[ -z "$output" ]] || assert_failure
    else
        skip "Running on Windows - test not applicable"
    fi
}

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

@test "get_windows_cwd returns valid path" {
    run get_windows_cwd

    assert_success
    # Should return a non-empty path
    [[ -n "$output" ]]
}

@test "get_windows_cwd returns Windows path on Windows" {
    local platform
    platform=$(get_platform)

    if [[ "$platform" == "windows" ]]; then
        # Change to a directory with a drive letter (not /tmp which lacks it)
        local orig_dir
        orig_dir=$(pwd)
        cd "${BATS_TEST_DIRNAME}" || return 1

        run get_windows_cwd
        cd "$orig_dir" || return 1

        assert_success
        # Should start with drive letter (e.g., C:) - check second char is colon
        [[ "${output:1:1}" == ":" ]]
    else
        skip "Not running on Windows"
    fi
}
