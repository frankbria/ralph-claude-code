#!/usr/bin/env bash
# Generic provider adapter test harness helpers.
#
# These helpers intentionally do not know about Claude, Codex, Gemini, or any
# other provider implementation. They provide fixture-based assertions and a
# deterministic mock CLI pattern that provider adapter tests can reuse without
# invoking a real external agent CLI.

adapter_harness_fail() {
    local message="$1"

    if declare -F fail >/dev/null 2>&1; then
        fail "$message"
    else
        echo "$message"
        return 1
    fi
}

adapter_harness_require_command() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 || \
        adapter_harness_fail "Required command not found: $command_name"
}

adapter_harness_assert_file_exists() {
    local file_path="$1"

    [[ -f "$file_path" ]] || adapter_harness_fail "Expected file to exist: $file_path"
}

adapter_harness_create_mock_cli() {
    local mock_cli_path="$1"
    local output_fixture_path="$2"
    local argv_capture_path="$3"
    local exit_code="${4:-0}"

    adapter_harness_assert_file_exists "$output_fixture_path"

    mkdir -p "$(dirname "$mock_cli_path")" "$(dirname "$argv_capture_path")"

    cat > "$mock_cli_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${ADAPTER_HARNESS_OUTPUT_FIXTURE:?ADAPTER_HARNESS_OUTPUT_FIXTURE is required}"
: "${ADAPTER_HARNESS_ARGV_CAPTURE:?ADAPTER_HARNESS_ARGV_CAPTURE is required}"
: "${ADAPTER_HARNESS_EXIT_CODE:=0}"

printf '%s\n' "$@" > "$ADAPTER_HARNESS_ARGV_CAPTURE"
cat "$ADAPTER_HARNESS_OUTPUT_FIXTURE"
exit "$ADAPTER_HARNESS_EXIT_CODE"
EOF
    chmod +x "$mock_cli_path"

    export ADAPTER_HARNESS_OUTPUT_FIXTURE="$output_fixture_path"
    export ADAPTER_HARNESS_ARGV_CAPTURE="$argv_capture_path"
    export ADAPTER_HARNESS_EXIT_CODE="$exit_code"
}

adapter_harness_assert_argv_contains() {
    local argv_capture_path="$1"
    local expected_arg="$2"

    adapter_harness_assert_file_exists "$argv_capture_path"

    grep -Fx -- "$expected_arg" "$argv_capture_path" >/dev/null || \
        adapter_harness_fail "Expected argv to contain '$expected_arg' in $argv_capture_path"
}

adapter_harness_assert_argv_not_contains() {
    local argv_capture_path="$1"
    local unexpected_arg="$2"

    adapter_harness_assert_file_exists "$argv_capture_path"

    if grep -Fx -- "$unexpected_arg" "$argv_capture_path" >/dev/null; then
        adapter_harness_fail "Did not expect argv to contain '$unexpected_arg' in $argv_capture_path"
    fi
}

adapter_harness_assert_json_file() {
    local json_path="$1"

    adapter_harness_require_command jq
    adapter_harness_assert_file_exists "$json_path"

    jq empty "$json_path" >/dev/null || \
        adapter_harness_fail "Expected valid JSON file: $json_path"
}

adapter_harness_assert_json_has_key() {
    local json_path="$1"
    local key="$2"

    adapter_harness_assert_json_file "$json_path"

    jq -e --arg key "$key" 'has($key)' "$json_path" >/dev/null || \
        adapter_harness_fail "Expected JSON key '$key' in $json_path"
}

adapter_harness_assert_json_value() {
    local json_path="$1"
    local jq_filter="$2"
    local expected_value="$3"
    local actual_value

    adapter_harness_assert_json_file "$json_path"

    actual_value=$(jq -r "$jq_filter" "$json_path") || \
        adapter_harness_fail "jq filter failed for $json_path: $jq_filter"

    [[ "$actual_value" == "$expected_value" ]] || \
        adapter_harness_fail "Expected $jq_filter to be '$expected_value' but got '$actual_value'"
}

adapter_harness_assert_normalized_output_schema() {
    local json_path="$1"

    adapter_harness_assert_json_file "$json_path"

    local required_keys=(
        status
        exit_signal
        work_type
        files_modified
        asking_questions
        question_count
        token_usage
        permission_denials
        is_error
        rate_limit_detected
        session_id
        confidence_score
        work_summary
    )

    local key
    for key in "${required_keys[@]}"; do
        adapter_harness_assert_json_has_key "$json_path" "$key"
    done

    jq -e '
        (.status | type == "string") and
        (.exit_signal | type == "boolean") and
        (.work_type | type == "string") and
        (.files_modified | type == "number") and
        (.asking_questions | type == "boolean") and
        (.question_count | type == "number") and
        (.token_usage | type == "object") and
        (.token_usage.input_tokens | type == "number") and
        (.token_usage.output_tokens | type == "number") and
        (.permission_denials | type == "array") and
        (.is_error | type == "boolean") and
        (.rate_limit_detected | type == "boolean") and
        ((.session_id | type == "string") or (.session_id == null)) and
        (.confidence_score | type == "number") and
        (.work_summary | type == "string")
    ' "$json_path" >/dev/null || \
        adapter_harness_fail "Normalized provider output schema check failed: $json_path"
}

adapter_harness_assert_capabilities_schema() {
    local json_path="$1"

    adapter_harness_assert_json_file "$json_path"

    local required_keys=(
        provider
        supports_structured_output
        supports_token_usage
        supports_session_continuity
        supports_tool_restrictions
        supports_permission_denials
        supports_rate_limit_detection
    )

    local key
    for key in "${required_keys[@]}"; do
        adapter_harness_assert_json_has_key "$json_path" "$key"
    done

    jq -e '
        (.provider | type == "string") and
        (.supports_structured_output | type == "boolean") and
        (.supports_token_usage | type == "boolean") and
        (.supports_session_continuity | type == "boolean") and
        (.supports_tool_restrictions | type == "boolean") and
        (.supports_permission_denials | type == "boolean") and
        (.supports_rate_limit_detection | type == "boolean")
    ' "$json_path" >/dev/null || \
        adapter_harness_fail "Provider capabilities schema check failed: $json_path"
}
