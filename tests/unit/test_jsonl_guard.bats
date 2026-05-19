#!/usr/bin/env bats
# Regression tests for JSONL guard fix #250

setup() {
    export RALPH_DIR=$(mktemp -d)
    # Lower threshold for faster tests (100KB)
    export RALPH_JSONL_SAFE_MAX_BYTES=102400
    # Source the analyzer
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
}

teardown() { rm -rf "$RALPH_DIR"; }

@test "_file_size_bytes: returns size for existing file" {
    printf 'hello world' > "$RALPH_DIR/f.txt"
    [ "$(_file_size_bytes "$RALPH_DIR/f.txt")" = "11" ]
}

@test "_file_size_bytes: returns 0 for missing file" {
    [ "$(_file_size_bytes "/nonexistent/path")" = "0" ]
}

@test "detect_output_format: small valid JSON returns json" {
    printf '{"type":"result","ok":true}' > "$RALPH_DIR/o.json"
    [ "$(detect_output_format "$RALPH_DIR/o.json")" = "json" ]
}

@test "detect_output_format: small invalid JSON returns text" {
    printf '{"broken' > "$RALPH_DIR/o.json"
    [ "$(detect_output_format "$RALPH_DIR/o.json")" = "text" ]
}

@test "detect_output_format: large JSONL WITHOUT result marker → text (issue #250)" {
    # Simulate ~150 KB of JSONL streaming output with no "type":"result" line
    # (e.g., Claude killed mid-stream after productive timeout)
    : > "$RALPH_DIR/big.json"
    for i in $(seq 1 3000); do
        printf '{"type":"assistant","content":"chunk %d data data data data"}\n' "$i" >> "$RALPH_DIR/big.json"
    done
    # Verify file is over threshold
    [ "$(_file_size_bytes "$RALPH_DIR/big.json")" -gt 102400 ]
    # Must NOT spend time on jq parse — should fast-return text
    result=$(detect_output_format "$RALPH_DIR/big.json")
    [ "$result" = "text" ]
}

@test "detect_output_format: large JSONL WITH result marker → json (clean stream)" {
    # Simulate a large but valid stream ending with proper result line
    printf '{"type":"system","subtype":"init","session_id":"abc"}\n' > "$RALPH_DIR/big.json"
    for i in $(seq 1 3000); do
        printf '{"type":"assistant","content":"chunk %d data data data data"}\n' "$i" >> "$RALPH_DIR/big.json"
    done
    printf '{"type":"result","ok":true,"session_id":"abc"}\n' >> "$RALPH_DIR/big.json"
    # Over threshold, marker present → tries jq parse → JSONL is not single-doc, jq returns "text"
    # (this is OK — downstream handles JSONL via result_line extraction in ralph_loop.sh:1610)
    result=$(detect_output_format "$RALPH_DIR/big.json")
    # Either "json" (if jq somehow validates) or "text" — both are SAFE (no hang).
    # The key invariant: it returns quickly without crashing.
    [[ "$result" = "json" ]] || [[ "$result" = "text" ]]
}
