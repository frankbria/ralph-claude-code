#!/usr/bin/env bash

# platform_utils.sh - Cross-platform utility functions
# Provides OS detection and terminal multiplexer abstraction for Linux, macOS, and Windows

# =============================================================================
# PLATFORM DETECTION
# =============================================================================

# Get the current operating system type
# Returns: "linux", "darwin", "windows", or "unknown"
get_platform() {
    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        Linux*)
            echo "linux"
            ;;
        Darwin*)
            echo "darwin"
            ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Check if running on Windows (any variant)
# Returns: 0 if Windows, 1 otherwise
is_windows() {
    local platform
    platform=$(get_platform)
    [[ "$platform" == "windows" ]]
}

# Check if running on macOS
# Returns: 0 if macOS, 1 otherwise
is_macos() {
    local platform
    platform=$(get_platform)
    [[ "$platform" == "darwin" ]]
}

# Check if running on Linux
# Returns: 0 if Linux, 1 otherwise
is_linux() {
    local platform
    platform=$(get_platform)
    [[ "$platform" == "linux" ]]
}

# =============================================================================
# TERMINAL MULTIPLEXER DETECTION
# =============================================================================

# Check if tmux is available
# Returns: 0 if available, 1 otherwise
has_tmux() {
    command -v tmux &>/dev/null
}

# Check if Windows Terminal is available
# Returns: 0 if available, 1 otherwise
has_windows_terminal() {
    # Windows Terminal provides wt.exe in PATH when installed
    # Also check common installation paths on Windows
    if command -v wt.exe &>/dev/null; then
        return 0
    fi

    if command -v wt &>/dev/null; then
        return 0
    fi

    # Check Windows-specific paths
    if is_windows; then
        # Get Windows username (may differ from Unix USER)
        local win_user="${USER:-$USERNAME}"

        # Check common installation locations
        local wt_paths=(
            "/c/Users/$win_user/AppData/Local/Microsoft/WindowsApps/wt.exe"
            "/mnt/c/Users/$win_user/AppData/Local/Microsoft/WindowsApps/wt.exe"
        )

        for wt_path in "${wt_paths[@]}"; do
            if [[ -f "$wt_path" ]]; then
                return 0
            fi
        done

        # Check via cmd.exe with timeout (may hang in some environments)
        # Only try this as a last resort
        if timeout 2s cmd.exe /c "where wt" &>/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Get the Windows Terminal executable path
# Returns: path to wt.exe or empty string if not found
get_windows_terminal_path() {
    # Check if wt.exe is in PATH
    if command -v wt.exe &>/dev/null; then
        command -v wt.exe
        return 0
    fi

    if command -v wt &>/dev/null; then
        command -v wt
        return 0
    fi

    # Check common installation locations on Windows
    if is_windows; then
        local win_user="${USER:-$USERNAME}"
        local wt_paths=(
            "/c/Users/$win_user/AppData/Local/Microsoft/WindowsApps/wt.exe"
            "/mnt/c/Users/$win_user/AppData/Local/Microsoft/WindowsApps/wt.exe"
        )

        for wt_path in "${wt_paths[@]}"; do
            if [[ -f "$wt_path" ]]; then
                echo "$wt_path"
                return 0
            fi
        done

        # Check via cmd.exe with timeout (may hang in some environments)
        local wt_path
        wt_path=$(timeout 2s cmd.exe /c "where wt" 2>/dev/null | head -1 | tr -d '\r')
        if [[ -n "$wt_path" ]]; then
            echo "$wt_path"
            return 0
        fi
    fi

    echo ""
    return 1
}

# Get the best available terminal multiplexer for the current platform
# Returns: "tmux", "windows_terminal", or "none"
get_available_multiplexer() {
    if has_tmux; then
        echo "tmux"
    elif is_windows && has_windows_terminal; then
        echo "windows_terminal"
    else
        echo "none"
    fi
}

# Get the Git Bash executable path (Windows only)
# Returns: path to bash.exe or empty string if not found
get_git_bash_path() {
    if ! is_windows; then
        echo ""
        return 1
    fi

    # Check common Git Bash installation locations
    local git_bash_paths=(
        "/c/Program Files/Git/bin/bash.exe"
        "/c/Program Files (x86)/Git/bin/bash.exe"
        "/c/Users/${USER:-$USERNAME}/AppData/Local/Programs/Git/bin/bash.exe"
    )

    for bash_path in "${git_bash_paths[@]}"; do
        if [[ -f "$bash_path" ]]; then
            echo "$bash_path"
            return 0
        fi
    done

    echo ""
    return 1
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Convert Unix path to Windows path format
# Usage: unix_to_windows_path "/c/Users/name/project"
# Returns: "C:\Users\name\project"
unix_to_windows_path() {
    local unix_path=$1

    if [[ "$unix_path" =~ ^/([a-zA-Z])/ ]]; then
        # Convert /c/path to C:\path
        local drive="${BASH_REMATCH[1]}"
        local rest="${unix_path:2}"
        echo "${drive^^}:${rest//\//\\}"
    else
        # Return as-is if not a Unix-style Windows path
        echo "$unix_path"
    fi
}

# Get the current working directory in Windows format (if on Windows)
# Returns: Windows-style path on Windows, Unix path otherwise
get_windows_cwd() {
    if is_windows; then
        unix_to_windows_path "$(pwd)"
    else
        pwd
    fi
}

# Export functions for use in other scripts
export -f get_platform
export -f is_windows
export -f is_macos
export -f is_linux
export -f has_tmux
export -f has_windows_terminal
export -f get_windows_terminal_path
export -f get_git_bash_path
export -f get_available_multiplexer
export -f unix_to_windows_path
export -f get_windows_cwd
