#!/usr/bin/env bats
# Unit Tests for Multi-Account Rotation (Issue #81)
# Tests account config loading, rotation logic, cooldown tracking, and env var switching

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-account-rotation.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export ACCOUNT_ROTATION_STATE_FILE="$RALPH_DIR/.account_rotation_state"
    export ACCOUNT_ROTATION="true"
    mkdir -p "$RALPH_DIR"

    # Create a temp home for accounts.conf (avoid touching real ~/.ralph)
    export TEST_HOME="$(mktemp -d /tmp/ralph-home.XXXXXX)"
    mkdir -p "$TEST_HOME/.ralph"
    export ACCOUNT_KEYS_FILE="$TEST_HOME/.ralph/accounts.conf"

    # Source the library
    source "$SCRIPT_DIR/date_utils.sh"
    source "$SCRIPT_DIR/account_rotation.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" "$TEST_HOME"
}

# ============================================================================
# Helper functions
# ============================================================================

# Create accounts.conf with API keys
create_accounts_conf() {
    local num_keys=${1:-2}
    echo 'CLAUDE_ACCOUNT_KEYS=(' > "$ACCOUNT_KEYS_FILE"
    for (( i = 0; i < num_keys; i++ )); do
        echo "    \"sk-ant-test-key-${i}\"" >> "$ACCOUNT_KEYS_FILE"
    done
    echo ')' >> "$ACCOUNT_KEYS_FILE"
}

# Set up config dirs in env
setup_config_dirs() {
    local num_dirs=${1:-2}
    CLAUDE_CONFIG_DIRS=()
    for (( i = 0; i < num_dirs; i++ )); do
        local dir="$TEST_HOME/.claude-account${i}"
        mkdir -p "$dir"
        CLAUDE_CONFIG_DIRS+=("$dir")
    done
    export CLAUDE_CONFIG_DIRS
}

# Create a rate-limited state for a specific account
mark_limited_now() {
    local account_id=$1
    _ensure_state_file
    local ts
    ts=$(get_iso_timestamp)
    local state_data
    state_data=$(cat "$ACCOUNT_ROTATION_STATE_FILE")
    echo "$state_data" | jq \
        --arg id "$account_id" \
        --arg ts "$ts" \
        '.rate_limited[$id] = $ts' \
        > "$ACCOUNT_ROTATION_STATE_FILE"
}

# Create a rate-limited state with an old timestamp (cooldown expired)
mark_limited_expired() {
    local account_id=$1
    _ensure_state_file
    # Use a timestamp from 2 hours ago (well past 60-min cooldown)
    local old_ts="2020-01-01T00:00:00+00:00"
    local state_data
    state_data=$(cat "$ACCOUNT_ROTATION_STATE_FILE")
    echo "$state_data" | jq \
        --arg id "$account_id" \
        --arg ts "$old_ts" \
        '.rate_limited[$id] = $ts' \
        > "$ACCOUNT_ROTATION_STATE_FILE"
}

# ============================================================================
# load_account_config tests
# ============================================================================

@test "load_account_config: returns failure when no config exists" {
    rm -f "$ACCOUNT_KEYS_FILE"
    unset CLAUDE_CONFIG_DIRS 2>/dev/null || true
    run load_account_config
    assert_failure
}

@test "load_account_config: loads API keys from accounts.conf" {
    create_accounts_conf 3
    load_account_config
    [[ ${#ACCOUNT_KEYS[@]} -eq 3 ]]
    [[ "${ACCOUNT_KEYS[0]}" == "sk-ant-test-key-0" ]]
    [[ "${ACCOUNT_KEYS[2]}" == "sk-ant-test-key-2" ]]
}

@test "load_account_config: loads config dirs from CLAUDE_CONFIG_DIRS" {
    setup_config_dirs 2
    load_account_config
    [[ ${#ACCOUNT_CONFIG_DIRS[@]} -eq 2 ]]
}

@test "load_account_config: loads both keys and config dirs" {
    create_accounts_conf 2
    setup_config_dirs 2
    load_account_config
    [[ ${#ACCOUNT_KEYS[@]} -eq 2 ]]
    [[ ${#ACCOUNT_CONFIG_DIRS[@]} -eq 2 ]]
}

@test "load_account_config: returns success with only keys configured" {
    create_accounts_conf 1
    unset CLAUDE_CONFIG_DIRS 2>/dev/null || true
    run load_account_config
    assert_success
}

@test "load_account_config: returns success with only config dirs" {
    rm -f "$ACCOUNT_KEYS_FILE"
    setup_config_dirs 1
    run load_account_config
    assert_success
}

# ============================================================================
# get_total_accounts tests
# ============================================================================

@test "get_total_accounts: returns 0 with no accounts" {
    ACCOUNT_KEYS=()
    ACCOUNT_CONFIG_DIRS=()
    run get_total_accounts
    assert_success
    [[ "$output" == "0" ]]
}

@test "get_total_accounts: counts keys and config dirs together" {
    create_accounts_conf 2
    setup_config_dirs 3
    load_account_config
    run get_total_accounts
    assert_success
    [[ "$output" == "5" ]]
}

# ============================================================================
# _ensure_state_file tests
# ============================================================================

@test "_ensure_state_file: creates state file when missing" {
    rm -f "$ACCOUNT_ROTATION_STATE_FILE"
    _ensure_state_file
    [[ -f "$ACCOUNT_ROTATION_STATE_FILE" ]]
    run jq -r '.active_index' "$ACCOUNT_ROTATION_STATE_FILE"
    [[ "$output" == "0" ]]
}

@test "_ensure_state_file: recreates corrupted state file" {
    echo "not json" > "$ACCOUNT_ROTATION_STATE_FILE"
    _ensure_state_file
    run jq -r '.active_type' "$ACCOUNT_ROTATION_STATE_FILE"
    assert_success
    [[ "$output" == "none" ]]
}

@test "_ensure_state_file: preserves valid state file" {
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 2,
    "active_type": "key",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 5
}
EOF
    _ensure_state_file
    run jq -r '.active_index' "$ACCOUNT_ROTATION_STATE_FILE"
    [[ "$output" == "2" ]]
    run jq -r '.total_rotations' "$ACCOUNT_ROTATION_STATE_FILE"
    [[ "$output" == "5" ]]
}

# ============================================================================
# get_active_account tests
# ============================================================================

@test "get_active_account: returns defaults for new state" {
    run get_active_account
    assert_success
    [[ "$output" == "0 none" ]]
}

@test "get_active_account: returns current active account from state" {
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 1,
    "active_type": "config_dir",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    run get_active_account
    assert_success
    [[ "$output" == "1 config_dir" ]]
}

# ============================================================================
# mark_account_rate_limited tests
# ============================================================================

@test "mark_account_rate_limited: records timestamp in state file" {
    _ensure_state_file
    mark_account_rate_limited 0 "key"
    run jq -r '.rate_limited["key:0"]' "$ACCOUNT_ROTATION_STATE_FILE"
    assert_success
    # Should contain a timestamp (not empty or null)
    [[ "$output" != "null" ]]
    [[ "$output" != "" ]]
}

@test "mark_account_rate_limited: can mark multiple accounts" {
    _ensure_state_file
    mark_account_rate_limited 0 "key"
    mark_account_rate_limited 1 "key"
    mark_account_rate_limited 0 "config_dir"

    local count
    count=$(jq '.rate_limited | length' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$count" == "3" ]]
}

# ============================================================================
# _is_account_in_cooldown tests
# ============================================================================

@test "_is_account_in_cooldown: returns false for unknown account" {
    _ensure_state_file
    run _is_account_in_cooldown "key:99"
    assert_failure  # failure = not in cooldown = available
}

@test "_is_account_in_cooldown: returns true for recently limited account" {
    _ensure_state_file
    mark_account_rate_limited 0 "key"
    run _is_account_in_cooldown "key:0"
    assert_success  # success = in cooldown
}

@test "_is_account_in_cooldown: returns false for expired cooldown" {
    _ensure_state_file
    mark_limited_expired "key:0"
    run _is_account_in_cooldown "key:0"
    assert_failure  # failure = not in cooldown = available
}

# ============================================================================
# get_next_available_account tests
# ============================================================================

@test "get_next_available_account: returns empty when no accounts configured" {
    ACCOUNT_KEYS=()
    ACCOUNT_CONFIG_DIRS=()
    run get_next_available_account
    assert_failure
    [[ -z "$output" ]]
}

@test "get_next_available_account: rotates to next key account" {
    create_accounts_conf 3
    load_account_config
    # Active is index 0, type key
    _ensure_state_file
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 0,
    "active_type": "key",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    run get_next_available_account
    assert_success
    [[ "$output" == "1 key" ]]
}

@test "get_next_available_account: skips rate-limited accounts" {
    create_accounts_conf 3
    load_account_config
    _ensure_state_file
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 0,
    "active_type": "key",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    # Mark account 1 as rate-limited
    mark_limited_now "key:1"

    run get_next_available_account
    assert_success
    [[ "$output" == "2 key" ]]
}

@test "get_next_available_account: wraps around to beginning" {
    create_accounts_conf 3
    load_account_config
    _ensure_state_file
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 2,
    "active_type": "key",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    run get_next_available_account
    assert_success
    [[ "$output" == "0 key" ]]
}

@test "get_next_available_account: returns failure when all accounts rate-limited" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    mark_limited_now "key:0"
    mark_limited_now "key:1"

    run get_next_available_account
    assert_failure
}

@test "get_next_available_account: crosses from keys to config dirs" {
    create_accounts_conf 2
    setup_config_dirs 2
    load_account_config
    _ensure_state_file
    # Active is last key account (index 1)
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 1,
    "active_type": "key",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    run get_next_available_account
    assert_success
    [[ "$output" == "0 config_dir" ]]
}

@test "get_next_available_account: crosses from config dirs back to keys (wrap-around)" {
    create_accounts_conf 2
    setup_config_dirs 2
    load_account_config
    _ensure_state_file
    # Active is last config_dir account (index 1, unified pos 3)
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 1,
    "active_type": "config_dir",
    "rate_limited": {},
    "last_rotation": "",
    "total_rotations": 0
}
EOF
    run get_next_available_account
    assert_success
    # Should wrap around to key:0 (unified pos 0), NOT config_dir:0
    [[ "$output" == "0 key" ]]
}

@test "get_next_available_account: uses expired cooldown accounts" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    # Mark account 1 with expired cooldown
    mark_limited_expired "key:1"

    run get_next_available_account
    assert_success
    [[ "$output" == "1 key" ]]
}

# ============================================================================
# switch_account tests
# ============================================================================

@test "switch_account: sets ANTHROPIC_API_KEY for key type" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file

    switch_account 1 "key"
    [[ "$ANTHROPIC_API_KEY" == "sk-ant-test-key-1" ]]
}

@test "switch_account: sets CLAUDE_CONFIG_DIR for config_dir type" {
    setup_config_dirs 2
    load_account_config
    _ensure_state_file

    switch_account 1 "config_dir"
    [[ "$CLAUDE_CONFIG_DIR" == "${ACCOUNT_CONFIG_DIRS[1]}" ]]
}

@test "switch_account: updates state file with new active account" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file

    switch_account 1 "key"
    local active_index active_type
    active_index=$(jq -r '.active_index' "$ACCOUNT_ROTATION_STATE_FILE")
    active_type=$(jq -r '.active_type' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$active_index" == "1" ]]
    [[ "$active_type" == "key" ]]
}

@test "switch_account: increments total_rotations counter" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file

    switch_account 0 "key"
    switch_account 1 "key"
    local total
    total=$(jq -r '.total_rotations' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$total" == "2" ]]
}

@test "switch_account: fails for out-of-bounds key index" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file

    run switch_account 5 "key"
    assert_failure
}

@test "switch_account: fails for out-of-bounds config_dir index" {
    setup_config_dirs 1
    load_account_config
    _ensure_state_file

    run switch_account 5 "config_dir"
    assert_failure
}

@test "switch_account: fails for unknown type" {
    _ensure_state_file
    run switch_account 0 "invalid_type"
    assert_failure
}

# ============================================================================
# all_accounts_exhausted tests
# ============================================================================

@test "all_accounts_exhausted: returns true with no accounts configured" {
    ACCOUNT_KEYS=()
    ACCOUNT_CONFIG_DIRS=()
    run all_accounts_exhausted
    assert_success
}

@test "all_accounts_exhausted: returns false when some accounts available" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    mark_limited_now "key:0"
    # key:1 is not limited

    run all_accounts_exhausted
    assert_failure  # failure = not all exhausted
}

@test "all_accounts_exhausted: returns true when all keys rate-limited" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    mark_limited_now "key:0"
    mark_limited_now "key:1"

    run all_accounts_exhausted
    assert_success
}

@test "all_accounts_exhausted: checks both keys and config dirs" {
    create_accounts_conf 1
    setup_config_dirs 1
    load_account_config
    _ensure_state_file
    mark_limited_now "key:0"
    # config_dir:0 is still available

    run all_accounts_exhausted
    assert_failure  # failure = not all exhausted
}

@test "all_accounts_exhausted: returns false when cooldown expired" {
    create_accounts_conf 1
    load_account_config
    _ensure_state_file
    mark_limited_expired "key:0"

    run all_accounts_exhausted
    assert_failure  # failure = account available after cooldown
}

@test "all_accounts_exhausted: respects custom ACCOUNT_COOLDOWN_SECONDS" {
    export ACCOUNT_COOLDOWN_SECONDS=1
    create_accounts_conf 1
    load_account_config
    _ensure_state_file
    mark_limited_now "key:0"

    # Should be in cooldown immediately
    run all_accounts_exhausted
    assert_success

    # Wait past the 1-second custom cooldown
    sleep 2

    run all_accounts_exhausted
    assert_failure  # failure = account available after custom cooldown
}

# ============================================================================
# reset_account_rotation tests
# ============================================================================

@test "reset_account_rotation: clears all rate-limit state" {
    _ensure_state_file
    mark_limited_now "key:0"
    mark_limited_now "key:1"

    reset_account_rotation "test reset"

    local count
    count=$(jq '.rate_limited | length' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$count" == "0" ]]
}

@test "reset_account_rotation: resets active index to 0" {
    _ensure_state_file
    # Set active to index 2
    cat > "$ACCOUNT_ROTATION_STATE_FILE" << 'EOF'
{
    "active_index": 2,
    "active_type": "key",
    "rate_limited": {"key:0": "2025-01-01T00:00:00+00:00"},
    "last_rotation": "",
    "total_rotations": 5
}
EOF
    reset_account_rotation

    local index
    index=$(jq -r '.active_index' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$index" == "0" ]]
    local rotations
    rotations=$(jq -r '.total_rotations' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$rotations" == "0" ]]
}

# ============================================================================
# init_account_rotation tests
# ============================================================================

@test "init_account_rotation: returns failure when ACCOUNT_ROTATION is false" {
    export ACCOUNT_ROTATION="false"
    run init_account_rotation
    assert_failure
}

@test "init_account_rotation: returns failure when no accounts configured" {
    export ACCOUNT_ROTATION="true"
    rm -f "$ACCOUNT_KEYS_FILE"
    unset CLAUDE_CONFIG_DIRS 2>/dev/null || true
    run init_account_rotation
    assert_failure
}

@test "init_account_rotation: succeeds with keys configured" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 2
    init_account_rotation

    local active_type
    active_type=$(jq -r '.active_type' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$active_type" == "key" ]]
}

@test "init_account_rotation: sets first config_dir when no keys" {
    export ACCOUNT_ROTATION="true"
    rm -f "$ACCOUNT_KEYS_FILE"
    setup_config_dirs 2
    init_account_rotation

    local active_type
    active_type=$(jq -r '.active_type' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$active_type" == "config_dir" ]]
}

# ============================================================================
# try_rotate_account tests
# ============================================================================

@test "try_rotate_account: returns failure when rotation disabled" {
    export ACCOUNT_ROTATION="false"
    run try_rotate_account
    assert_failure
}

@test "try_rotate_account: returns failure with no accounts" {
    export ACCOUNT_ROTATION="true"
    ACCOUNT_KEYS=()
    ACCOUNT_CONFIG_DIRS=()
    run try_rotate_account
    assert_failure
}

@test "try_rotate_account: rotates to next account and marks current as limited" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 3
    load_account_config
    _ensure_state_file
    # Set active to key:0
    switch_account 0 "key"

    try_rotate_account

    # Current (key:0) should be rate-limited
    local limited
    limited=$(jq -r '.rate_limited["key:0"]' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$limited" != "null" ]]

    # Active should now be key:1
    local active_index
    active_index=$(jq -r '.active_index' "$ACCOUNT_ROTATION_STATE_FILE")
    [[ "$active_index" == "1" ]]
}

@test "try_rotate_account: returns failure when all accounts exhausted" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    switch_account 0 "key"

    # Mark all others as limited
    mark_limited_now "key:1"

    # try_rotate will mark key:0 as limited, then find no available accounts
    run try_rotate_account
    assert_failure
}

@test "try_rotate_account: sets ANTHROPIC_API_KEY after rotation" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 2
    load_account_config
    _ensure_state_file
    switch_account 0 "key"

    try_rotate_account

    [[ "$ANTHROPIC_API_KEY" == "sk-ant-test-key-1" ]]
}

# ============================================================================
# CLI integration tests (--reset-accounts flag)
# ============================================================================

@test "--reset-accounts: help output includes reset-accounts flag" {
    local ralph_script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    run bash "$ralph_script" --help
    assert_success
    [[ "$output" == *"--reset-accounts"* ]]
}

@test "--reset-accounts: resets account rotation state" {
    local ralph_script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Create state file with some rate-limited accounts
    _ensure_state_file
    mark_limited_now "key:0"
    mark_limited_now "key:1"

    run bash "$ralph_script" --reset-accounts
    assert_success
    [[ "$output" == *"reset successfully"* ]]
}

# ============================================================================
# Loop integration behavior tests
# ============================================================================

@test "try_rotate_account: full rotation cycle across multiple accounts" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 3
    load_account_config
    _ensure_state_file
    switch_account 0 "key"

    # First rotation: 0 -> 1
    try_rotate_account
    [[ "$ANTHROPIC_API_KEY" == "sk-ant-test-key-1" ]]

    # Second rotation: 1 -> 2
    try_rotate_account
    [[ "$ANTHROPIC_API_KEY" == "sk-ant-test-key-2" ]]

    # Third rotation: all 3 are limited, should fail
    run try_rotate_account
    assert_failure
}

@test "try_rotate_account: rotation falls back when disabled" {
    export ACCOUNT_ROTATION="false"
    create_accounts_conf 3
    load_account_config
    _ensure_state_file

    # Should fail since rotation is disabled — loop should fall back to wait
    run try_rotate_account
    assert_failure
}

@test "try_rotate_account: rotation with mixed key and config_dir accounts" {
    export ACCOUNT_ROTATION="true"
    create_accounts_conf 1
    setup_config_dirs 1
    load_account_config
    _ensure_state_file
    switch_account 0 "key"

    # First rotation: key:0 limited, should go to config_dir:0
    try_rotate_account
    [[ "$CLAUDE_CONFIG_DIR" == "${ACCOUNT_CONFIG_DIRS[0]}" ]]

    # Second rotation: config_dir:0 limited too, key:0 still in cooldown, should fail
    run try_rotate_account
    assert_failure
}

# ============================================================================
# Explicit config dir handling (always set CLAUDE_CONFIG_DIR)
# ============================================================================

@test "switch_account: always sets CLAUDE_CONFIG_DIR explicitly for config_dir accounts" {
    # Each rotation account must have a dedicated config dir.
    # CLAUDE_CONFIG_DIR is always set explicitly — no unset/fallback to default.
    export ACCOUNT_CONFIG_DIRS=("/tmp/test-claude-account1" "/tmp/test-claude-account2")
    export ACCOUNT_KEYS=()
    _ensure_state_file

    switch_account 0 "config_dir"

    [[ "$CLAUDE_CONFIG_DIR" == "/tmp/test-claude-account1" ]]
}

@test "switch_account: sets CLAUDE_CONFIG_DIR for second account" {
    export ACCOUNT_CONFIG_DIRS=("/tmp/test-claude-account1" "/tmp/test-claude-account2")
    export ACCOUNT_KEYS=()
    _ensure_state_file

    switch_account 1 "config_dir"

    [[ "$CLAUDE_CONFIG_DIR" == "/tmp/test-claude-account2" ]]
}

@test "switch_account: resolves tilde in config dir paths" {
    export ACCOUNT_CONFIG_DIRS=("~/custom-claude-dir" "/tmp/test-claude-account2")
    export ACCOUNT_KEYS=()
    _ensure_state_file

    switch_account 0 "config_dir"

    [[ "$CLAUDE_CONFIG_DIR" == "$HOME/custom-claude-dir" ]]
}

@test "switch_account: unsets CLAUDE_CONFIG_DIR when switching to key type" {
    create_accounts_conf 2
    load_account_config
    _ensure_state_file

    # Simulate a previous config_dir switch
    export CLAUDE_CONFIG_DIR="/tmp/some-dir"

    switch_account 0 "key"
    [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]
    [[ "$ANTHROPIC_API_KEY" == "sk-ant-test-key-0" ]]
}

@test "switch_account: unsets ANTHROPIC_API_KEY when switching to config_dir type" {
    setup_config_dirs 2
    load_account_config
    _ensure_state_file

    # Simulate a previous key switch
    export ANTHROPIC_API_KEY="sk-ant-old-key"

    switch_account 1 "config_dir"
    [[ -z "${ANTHROPIC_API_KEY:-}" ]]
}

@test "switch_account: resolves tilde in all config dir paths" {
    # Tilde doesn't expand inside quoted array values in .ralphrc
    export ACCOUNT_CONFIG_DIRS=("~/.claude-account1" "~/.claude-account2")
    export ACCOUNT_KEYS=()
    _ensure_state_file

    switch_account 0 "config_dir"
    [[ "$CLAUDE_CONFIG_DIR" == "$HOME/.claude-account1" ]]

    switch_account 1 "config_dir"
    [[ "$CLAUDE_CONFIG_DIR" == "$HOME/.claude-account2" ]]
}
