#!/bin/bash
# =============================================================================
# Ralph Loop - Metrics Utilities
# =============================================================================
# Lightweight metrics collection for Ralph loop iterations.
#
# Metrics are recorded as JSON Lines (JSONL) in:
#   $LOG_DIR/metrics.jsonl   (default LOG_DIR is "logs")
#
# Each line has the shape:
#   {
#     "timestamp": "2025-09-30T12:00:00+0000",
#     "loop": 1,
#     "duration": 45,
#     "success": true,
#     "calls": 1
#   }
# =============================================================================

# Append a single metrics entry.
#
# Arguments:
#   $1 - loop number (integer)
#   $2 - duration in seconds (integer)
#   $3 - success flag ("true" or "false")
#   $4 - calls count (integer, usually total calls so far)
track_metrics() {
    local loop_num="$1"
    local duration="$2"
    local success="$3"
    local calls="$4"

    local log_dir="${LOG_DIR:-logs}"
    mkdir -p "$log_dir"

    # Prefer RFC-3339 style with timezone; fall back to UTC with +0000.
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S+0000')

    printf '{"timestamp":"%s","loop":%s,"duration":%s,"success":%s,"calls":%s}\n' \
        "$timestamp" "$loop_num" "$duration" "$success" "$calls" >> "$log_dir/metrics.jsonl"
}