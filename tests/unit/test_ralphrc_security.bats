#!/usr/bin/env bats
# Unit tests for .ralphrc security parsing (Issue #346)
# Verifies that .ralphrc is parsed as data, not executed as code

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo (required by Ralph)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up minimal Ralph project structure
    export RALPH_DIR=".ralph"
    export RALPHRC_FILE=".ralphrc"
    mkdir -p "$RALPH_DIR/logs" "$RALPH_DIR/docs/generated"
    echo "# test prompt" > "$RALPH_DIR/PROMPT.md"
    echo "# test plan" > "$RALPH_DIR/fix_plan.md"
    echo "# test agent" > "$RALPH_DIR/AGENT.md"

    # Define colors for log_status
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'

    # Minimal log_status for tests
    log_status() {
        echo "[$1] $2"
    }
    export -f log_status

    # Source the actual load_ralphrc function
    # Extract just the function from ralph_loop.sh
    eval "$(sed -n '/^load_ralphrc()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# SECURITY TESTS - Issue #346
# =============================================================================

@test "issue #346: .ralphrc does not execute arbitrary commands" {
    # Create a .ralphrc that would create a marker file if executed
    cat > .ralphrc << 'EOF'
touch /tmp/ralphrc-executed-$$
MAX_CALLS_PER_HOUR=50
EOF

    # Run load_ralphrc
    run load_ralphrc

    # The function should reject this file (contains shell command)
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]] || [[ "$output" == *"Invalid syntax"* ]]
}

@test "issue #346: .ralphrc rejects command substitution \$()" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=$(cat /etc/passwd | wc -l)
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects backtick command substitution" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=`id`
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects semicolon command chaining" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=50; touch /tmp/hacked
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects pipe operators" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=50 | tee /tmp/hacked
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects eval" {
    cat > .ralphrc << 'EOF'
eval "touch /tmp/hacked"
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects source/. commands" {
    cat > .ralphrc << 'EOF'
source /etc/passwd
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

@test "issue #346: .ralphrc rejects variable expansion in values" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=$HOME
EOF

    run load_ralphrc
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell syntax"* ]]
}

# =============================================================================
# VALID CONFIGURATION TESTS
# =============================================================================

@test "issue #346: .ralphrc accepts valid KEY=VALUE assignments" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=50
CLAUDE_TIMEOUT_MINUTES=30
EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$CLAUDE_TIMEOUT_MINUTES" = "30" ]
}

@test "issue #346: .ralphrc accepts quoted values" {
    cat > .ralphrc << 'EOF'
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit"
OPTIONAL_SECTIONS='Optional,Future'
EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [ "$CLAUDE_ALLOWED_TOOLS" = "Write,Read,Edit" ]
    [ "$OPTIONAL_SECTIONS" = "Optional,Future" ]
}

@test "issue #346: .ralphrc ignores comments" {
    cat > .ralphrc << 'EOF'
# This is a comment
MAX_CALLS_PER_HOUR=50
  # Indented comment
CLAUDE_TIMEOUT_MINUTES=30
EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
}

@test "issue #346: .ralphrc ignores empty lines" {
    cat > .ralphrc << 'EOF'

MAX_CALLS_PER_HOUR=50

CLAUDE_TIMEOUT_MINUTES=30

EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
}

@test "issue #346: .ralphrc warns on unknown keys" {
    cat > .ralphrc << 'EOF'
UNKNOWN_KEY=value
MAX_CALLS_PER_HOUR=50
EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown key"* ]]
    [[ "$output" == *"UNKNOWN_KEY"* ]]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
}

@test "issue #346: .ralphrc accepts all documented configuration keys" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=100
MAX_TOKENS_PER_HOUR=50000
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT=json
CLAUDE_USE_CONTINUE=true
VERBOSE_PROGRESS=false
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false
SANDBOX_PROVIDER=docker
EOF

    run load_ralphrc
    [ "$status" -eq 0 ]
    [ "$MAX_CALLS_PER_HOUR" = "100" ]
    [ "$SANDBOX_PROVIDER" = "docker" ]
}

@test "issue #346: missing .ralphrc returns success" {
    rm -f .ralphrc

    run load_ralphrc
    [ "$status" -eq 0 ]
}
