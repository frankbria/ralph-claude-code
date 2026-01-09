#!/bin/bash
# Log Rotation Component for Ralph
# Manages log file size and retention to prevent disk space exhaustion

# Log rotation configuration
LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB:-10}           # Max size per log file (MB)
LOG_MAX_FILES=${LOG_MAX_FILES:-5}                # Number of rotated files to keep
LOG_MAX_AGE_DAYS=${LOG_MAX_AGE_DAYS:-7}          # Max age of log files (days)

# Convert MB to bytes for comparison
LOG_MAX_SIZE_BYTES=$((LOG_MAX_SIZE_MB * 1024 * 1024))

# Get file size in bytes (cross-platform)
get_file_size() {
    local file=$1
    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        stat -f %z "$file" 2>/dev/null || echo "0"
    else
        # Linux
        stat -c %s "$file" 2>/dev/null || echo "0"
    fi
}

# Rotate a single log file
# Creates: file.1, file.2, etc., removing oldest when exceeding LOG_MAX_FILES
rotate_log_file() {
    local log_file=$1
    local max_files=${2:-$LOG_MAX_FILES}

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    # Remove oldest rotated file if at max
    local oldest="$log_file.$max_files"
    if [[ -f "$oldest" ]]; then
        rm -f "$oldest"
    fi

    # Shift existing rotated files (file.4 -> file.5, file.3 -> file.4, etc.)
    local i=$((max_files - 1))
    while [[ $i -ge 1 ]]; do
        local current="$log_file.$i"
        local next="$log_file.$((i + 1))"
        if [[ -f "$current" ]]; then
            mv "$current" "$next"
        fi
        i=$((i - 1))
    done

    # Rotate current log to .1
    mv "$log_file" "$log_file.1"

    # Create new empty log file
    touch "$log_file"

    return 0
}

# Check if log file needs rotation (exceeds max size)
needs_rotation() {
    local log_file=$1
    local max_size=${2:-$LOG_MAX_SIZE_BYTES}

    if [[ ! -f "$log_file" ]]; then
        return 1  # No file, no rotation needed
    fi

    local file_size=$(get_file_size "$log_file")

    if [[ $file_size -gt $max_size ]]; then
        return 0  # Needs rotation
    else
        return 1  # Does not need rotation
    fi
}

# Rotate log file if it exceeds max size
rotate_if_needed() {
    local log_file=$1

    if needs_rotation "$log_file"; then
        rotate_log_file "$log_file"
        return 0
    fi
    return 1
}

# Clean up old log files (older than LOG_MAX_AGE_DAYS)
cleanup_old_logs() {
    local log_dir=$1
    local max_age_days=${2:-$LOG_MAX_AGE_DAYS}

    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi

    # Find and remove files older than max_age_days
    find "$log_dir" -type f -name "*.log*" -mtime +"$max_age_days" -delete 2>/dev/null

    return 0
}

# Rotate all logs in a directory
rotate_all_logs() {
    local log_dir=$1

    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi

    # Find all .log files (not already rotated)
    for log_file in "$log_dir"/*.log; do
        if [[ -f "$log_file" ]]; then
            rotate_if_needed "$log_file"
        fi
    done

    return 0
}

# Perform full log maintenance (rotation + cleanup)
maintain_logs() {
    local log_dir=$1

    # Rotate large files
    rotate_all_logs "$log_dir"

    # Clean up old files
    cleanup_old_logs "$log_dir"

    return 0
}

# Get log statistics for a directory
get_log_stats() {
    local log_dir=$1

    if [[ ! -d "$log_dir" ]]; then
        echo '{"total_files": 0, "total_size_mb": 0}'
        return
    fi

    local total_files=$(find "$log_dir" -type f -name "*.log*" 2>/dev/null | wc -l)
    local total_size=$(find "$log_dir" -type f -name "*.log*" -exec cat {} \; 2>/dev/null | wc -c)
    local total_size_mb=$((total_size / 1024 / 1024))

    echo "{\"total_files\": $total_files, \"total_size_mb\": $total_size_mb}"
}

# Export functions
export -f get_file_size
export -f rotate_log_file
export -f needs_rotation
export -f rotate_if_needed
export -f cleanup_old_logs
export -f rotate_all_logs
export -f maintain_logs
export -f get_log_stats
