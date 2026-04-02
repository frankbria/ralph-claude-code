#!/usr/bin/env bash
# lib/log_utils.sh - Log management utilities for Ralph

# rotate_logs - Rotate ralph.log when it exceeds 10MB (Issue #18)
#
# Keeps 4 archived files: ralph.log.1 through ralph.log.4
# (ralph.log.4 is deleted to make room). Cross-platform: works on
# both Linux (GNU stat) and macOS (BSD stat).
#
rotate_logs() {
    local log_file="$LOG_DIR/ralph.log"
    local max_size=10485760  # 10MB in bytes

    [[ -f "$log_file" ]] || return 0

    # Get file size cross-platform
    local file_size
    if stat -c%s "$log_file" > /dev/null 2>&1; then
        file_size=$(stat -c%s "$log_file")
    else
        file_size=$(stat -f%z "$log_file" 2>/dev/null || echo "0")
    fi

    [[ "$file_size" -lt "$max_size" ]] && return 0

    # Rotate: delete oldest, shift others up
    [[ -f "${log_file}.4" ]] && rm -f "${log_file}.4"
    [[ -f "${log_file}.3" ]] && mv "${log_file}.3" "${log_file}.4"
    [[ -f "${log_file}.2" ]] && mv "${log_file}.2" "${log_file}.3"
    [[ -f "${log_file}.1" ]] && mv "${log_file}.1" "${log_file}.2"
    mv "$log_file" "${log_file}.1"
}
