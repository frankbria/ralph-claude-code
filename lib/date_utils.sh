#!/usr/bin/env bash

# date_utils.sh - Cross-platform date utility functions
# Provides consistent date formatting and arithmetic across GNU (Linux) and BSD (macOS) systems

# Get current timestamp in ISO 8601 format with seconds precision
# Returns: YYYY-MM-DDTHH:MM:SS+00:00 format
get_iso_timestamp() {
    # Try GNU date first (works on Linux and macOS with coreutils)
    local result
    result=$(date -u -Iseconds 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "$result"
        return
    fi
    # Fallback to BSD date (native macOS) - add colon to timezone offset
    date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/'
}

# Get time component (HH:MM:SS) for one hour from now
# Returns: HH:MM:SS format
get_next_hour_time() {
    # Try GNU date first (works on Linux and macOS with coreutils)
    if date -d '+1 hour' '+%H:%M:%S' 2>/dev/null; then
        return
    fi
    # Fallback to BSD date (native macOS)
    if date -v+1H '+%H:%M:%S' 2>/dev/null; then
        return
    fi
    # Ultimate fallback - compute using epoch arithmetic
    local future_epoch=$(($(date +%s) + 3600))
    date -r "$future_epoch" '+%H:%M:%S' 2>/dev/null || date '+%H:%M:%S'
}

# Get current timestamp in a basic format (fallback)
# Returns: YYYY-MM-DD HH:MM:SS format
get_basic_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get current Unix epoch time in seconds
# Returns: Integer seconds since 1970-01-01 00:00:00 UTC
get_epoch_seconds() {
    date +%s
}

# Export functions for use in other scripts
export -f get_iso_timestamp
export -f get_next_hour_time
export -f get_basic_timestamp
export -f get_epoch_seconds
