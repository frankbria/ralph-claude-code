#!/bin/bash
# ralph-stats - Metrics analytics for Ralph loop execution (Issue #21)
# Reads .ralph/logs/metrics.jsonl and prints a JSON summary

RALPH_DIR="${RALPH_DIR:-.ralph}"
METRICS_FILE="$RALPH_DIR/logs/metrics.jsonl"

if [[ ! -f "$METRICS_FILE" ]]; then
    echo '{"error":"No metrics file found. Run ralph first to generate metrics."}' >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo '{"error":"jq is required for ralph-stats"}' >&2
    exit 1
fi

jq -s '{
    total_loops: length,
    successful: (map(select(.success==true)) | length),
    avg_duration: (if length > 0 then (map(.duration) | add) / length else 0 end),
    total_calls: (map(.calls) | add // 0)
}' "$METRICS_FILE"
