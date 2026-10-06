#!/usr/bin/env bats
# Unit tests for .ralphrc security parsing (Issue #346)
# Verifies that .ralphrc is parsed as data, not executed as code, and that
# command-bearing keys from the (repository-controlled) file cannot choose what
# Ralph executes or sources.

load '../helpers/test_helper'

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR=".ralph"
    export RALPHRC_FILE=".ralphrc"
    mkdir -p "$RALPH_DIR/logs"

    log_status() {
        echo "[$1] $2"
    }

    # Load the real parser: shared lib + load_ralphrc from ralph_loop.sh
    source "${BATS_TEST_DIRNAME}/../../lib/ralphrc.sh"
    eval "$(sed -n '/^load_ralphrc()/,/^}/p' "$RALPH_LOOP")"

    # Script defaults the parser may override
    MAX_CALLS_PER_HOUR=100
    CLAUDE_CODE_CMD="claude"
    RALPH_SHELL_INIT_FILE=""
    SANDBOX_DOCKER_IMAGE="ralph-sandbox:latest"
    SANDBOX_E2B_TEMPLATE="base"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# load_ralphrc must run in the current shell (not `run`) so its assignments are
# visible; output goes to $TEST_DIR/out for assertions.
load_rc() {
    load_ralphrc > "$TEST_DIR/out" 2>&1
}

# =============================================================================
# Shell code is never executed or assigned
# =============================================================================

@test "issue #346: shell commands in .ralphrc are not executed" {
    cat > .ralphrc << EOF
touch $TEST_DIR/marker
eval "touch $TEST_DIR/marker"
source /etc/hostname
MAX_CALLS_PER_HOUR=50
EOF

    load_rc
    [ ! -e "$TEST_DIR/marker" ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$(grep -c 'Invalid syntax' "$TEST_DIR/out")" -eq 3 ]
}

@test "issue #346: command substitution and expansion are not evaluated or assigned" {
    cat > .ralphrc << EOF
MAX_CALLS_PER_HOUR=\$(touch $TEST_DIR/marker)
MAX_CALLS_PER_HOUR="\$(touch $TEST_DIR/marker)"
MAX_CALLS_PER_HOUR=\`touch $TEST_DIR/marker\`
MAX_CALLS_PER_HOUR="\$HOME"
MAX_CALLS_PER_HOUR=\${HOME}
EOF

    load_rc
    [ ! -e "$TEST_DIR/marker" ]
    [ "$MAX_CALLS_PER_HOUR" = "100" ]
    [ "$(grep -c 'shell syntax' "$TEST_DIR/out")" -eq 5 ]
}

@test "issue #346: chained commands after an assignment are rejected whole" {
    cat > .ralphrc << EOF
MAX_CALLS_PER_HOUR=50; touch $TEST_DIR/marker
MAX_CALLS_PER_HOUR=50 | tee $TEST_DIR/marker
MAX_CALLS_PER_HOUR=50 && touch $TEST_DIR/marker
EOF

    load_rc
    [ ! -e "$TEST_DIR/marker" ]
    [ "$MAX_CALLS_PER_HOUR" = "100" ]
}

@test "issue #346: single-quoted values are literal, as in bash" {
    cat > .ralphrc << 'EOF'
OPTIONAL_SECTIONS='Costs $5; maybe `later`'
EOF

    load_rc
    [ "$OPTIONAL_SECTIONS" = 'Costs $5; maybe `later`' ]
}

# =============================================================================
# Valid configuration
# =============================================================================

@test "issue #346: plain KEY=VALUE assignments are applied" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=50
CLAUDE_TIMEOUT_MINUTES=30
EOF

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$CLAUDE_TIMEOUT_MINUTES" = "30" ]
    [ "$RALPHRC_LOADED" = "true" ]
}

@test "issue #346: double- and single-quoted values are unquoted" {
    cat > .ralphrc << 'EOF'
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit"
OPTIONAL_SECTIONS='Optional,Future'
EOF

    load_rc
    [ "$CLAUDE_ALLOWED_TOOLS" = "Write,Read,Edit" ]
    [ "$OPTIONAL_SECTIONS" = "Optional,Future" ]
}

@test "issue #346: the ralph-enable generated ALLOWED_TOOLS with Bash(...) specs is accepted" {
    cat > .ralphrc << 'EOF'
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(npm *),Bash(pytest)"
MAX_CALLS_PER_HOUR=50
EOF

    load_rc
    [ "$CLAUDE_ALLOWED_TOOLS" = "Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(npm *),Bash(pytest)" ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$(grep -c 'WARN' "$TEST_DIR/out")" -eq 0 ]
}

@test "issue #346: a real ralph-enable .ralphrc loads with no warnings" {
    source "${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"
    generate_ralphrc "demo" "typescript" "local,github" > .ralphrc

    load_rc
    [ "$(grep -c 'WARN' "$TEST_DIR/out")" -eq 0 ]
    [[ "$CLAUDE_ALLOWED_TOOLS" == *"Bash(git add *)"* ]]
}

@test "issue #346: comments, blank lines, CRLF and export prefixes are handled" {
    printf '%s\r\n' '# comment' '' '  # indented comment' 'export MAX_CALLS_PER_HOUR=50' 'CLAUDE_TIMEOUT_MINUTES=30' > .ralphrc

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$CLAUDE_TIMEOUT_MINUTES" = "30" ]
}

@test "issue #346: trailing comments are stripped from unquoted and quoted values" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=75  # raised from default
CLAUDE_MODEL="claude-sonnet-4-6"   # pinned
OPTIONAL_SECTIONS='Later' # note
EOF

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "75" ]
    [ "$CLAUDE_MODEL" = "claude-sonnet-4-6" ]
    [ "$OPTIONAL_SECTIONS" = "Later" ]
}

@test "issue #346: unknown keys are ignored with a warning" {
    cat > .ralphrc << 'EOF'
UNKNOWN_KEY=value
PATH=/tmp/evil
MAX_CALLS_PER_HOUR=50
EOF
    local path_before="$PATH"

    load_rc
    grep -q "Unknown key 'UNKNOWN_KEY'" "$TEST_DIR/out"
    grep -q "Unknown key 'PATH'" "$TEST_DIR/out"
    [ "$PATH" = "$path_before" ]
    [ -z "${UNKNOWN_KEY:-}" ]
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
}

@test "issue #346: a rejected line does not skip later lines or env precedence" {
    cat > .ralphrc << 'EOF'
CLAUDE_TIMEOUT_MINUTES=$(id)
MAX_CALLS_PER_HOUR=50
CLAUDE_MODEL=from-file
EOF
    _env_CLAUDE_MODEL="from-env"

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
    [ "$CLAUDE_MODEL" = "from-env" ]
}

@test "issue #346: PROMPT_FILE from .ralphrc is applied" {
    echo 'PROMPT_FILE=".ralph/CUSTOM_PROMPT.md"' > .ralphrc

    load_rc
    [ "$PROMPT_FILE" = ".ralph/CUSTOM_PROMPT.md" ]
}

@test "issue #346: a UTF-8 BOM on the first line does not drop the first key" {
    printf '\xef\xbb\xbfMAX_CALLS_PER_HOUR=50\n' > .ralphrc

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "50" ]
}

@test "issue #346: array-subscript and declare-style assignments are rejected" {
    printf '%s\n' 'MAX_CALLS_PER_HOUR[0]=50' 'declare MAX_CALLS_PER_HOUR=50' 'readonly MAX_CALLS_PER_HOUR=50' > .ralphrc

    load_rc
    [ "$MAX_CALLS_PER_HOUR" = "100" ]
    [ "$(grep -c 'Invalid syntax' "$TEST_DIR/out")" -eq 3 ]
}

@test "issue #346: missing .ralphrc returns success" {
    rm -f .ralphrc

    load_rc
    [ "${RALPHRC_LOADED:-false}" != "true" ]
}

@test "issue #346: parser does not use bash 4 associative arrays (bash 3.2 support)" {
    [ "$(sed -n '/^load_ralphrc()/,/^}/p' "$RALPH_LOOP" | grep -cE '(local|declare) -A')" -eq 0 ]
}

# =============================================================================
# Command-bearing keys: only stock values from the repo file; the rest via env
# =============================================================================

@test "issue #346: stock CLAUDE_CODE_CMD values from .ralphrc are honored" {
    echo 'CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"' > .ralphrc
    load_rc
    [ "$CLAUDE_CODE_CMD" = "npx @anthropic-ai/claude-code" ]

    echo 'CLAUDE_CODE_CMD="claude"' > .ralphrc
    load_rc
    [ "$CLAUDE_CODE_CMD" = "claude" ]
}

@test "issue #346: a custom CLAUDE_CODE_CMD from .ralphrc is ignored with a warning" {
    echo 'CLAUDE_CODE_CMD="./tools/fakeclaude"' > .ralphrc

    load_rc
    [ "$CLAUDE_CODE_CMD" = "claude" ]
    grep -q "CLAUDE_CODE_CMD" "$TEST_DIR/out"
    grep -q "environment" "$TEST_DIR/out"
}

@test "issue #346: CLAUDE_CODE_CMD from the environment still wins" {
    echo 'CLAUDE_CODE_CMD="claude"' > .ralphrc
    _env_CLAUDE_CODE_CMD="/opt/claude/bin/claude"

    load_rc
    [ "$CLAUDE_CODE_CMD" = "/opt/claude/bin/claude" ]
}

@test "issue #346: RALPH_SHELL_INIT_FILE from .ralphrc is ignored with a warning" {
    echo 'RALPH_SHELL_INIT_FILE=".ralph/init.sh"' > .ralphrc

    load_rc
    [ -z "$RALPH_SHELL_INIT_FILE" ]
    grep -q "RALPH_SHELL_INIT_FILE" "$TEST_DIR/out"
}

@test "issue #346: RALPH_SHELL_INIT_FILE from the environment is honored" {
    _env_RALPH_SHELL_INIT_FILE="$HOME/.zshrc"

    echo 'MAX_CALLS_PER_HOUR=50' > .ralphrc
    load_rc
    [ "$RALPH_SHELL_INIT_FILE" = "$HOME/.zshrc" ]
}

@test "issue #346: sandbox image/template from .ralphrc: stock accepted, custom ignored" {
    cat > .ralphrc << 'EOF'
SANDBOX_DOCKER_IMAGE="ghcr.io/frankbria/ralph-sandbox:latest"
SANDBOX_E2B_TEMPLATE="base"
EOF
    load_rc
    [ "$SANDBOX_DOCKER_IMAGE" = "ghcr.io/frankbria/ralph-sandbox:latest" ]
    [ "$SANDBOX_E2B_TEMPLATE" = "base" ]

    SANDBOX_DOCKER_IMAGE="ralph-sandbox:latest"
    cat > .ralphrc << 'EOF'
SANDBOX_DOCKER_IMAGE="attacker/image:latest"
SANDBOX_E2B_TEMPLATE="attacker-template"
EOF
    load_rc
    [ "$SANDBOX_DOCKER_IMAGE" = "ralph-sandbox:latest" ]
    [ "$SANDBOX_E2B_TEMPLATE" = "base" ]
    [ "$(grep -c 'environment' "$TEST_DIR/out")" -eq 2 ]
}

# =============================================================================
# End to end: the issue's reproduction against the real ralph_loop.sh
# =============================================================================

# Minimal Ralph project; PATH without a claude CLI so ralph exits at CLI
# validation, right after the points where the old code executed repo content.
make_project() {
    mkdir -p .ralph home
    echo "# prompt" > .ralph/PROMPT.md
    echo "# plan" > .ralph/fix_plan.md
    echo "# agent" > .ralph/AGENT.md
    git init -q .
}

run_ralph_dry() {
    HOME="$TEST_DIR/home" PATH="/usr/bin:/bin" CLAUDE_AUTO_UPDATE=false \
        timeout -s KILL 60 bash "$RALPH_LOOP" --dry-run > "$TEST_DIR/ralph.out" 2>&1 || true
}

@test "issue #346 repro: RALPH_SHELL_INIT_FILE in .ralphrc is not sourced by ralph" {
    make_project
    printf 'touch %s/marker\n' "$TEST_DIR" > .ralph/init.sh
    echo 'RALPH_SHELL_INIT_FILE=".ralph/init.sh"' > .ralphrc

    run_ralph_dry
    [ ! -e "$TEST_DIR/marker" ]
    grep -q "RALPH_SHELL_INIT_FILE" "$TEST_DIR/ralph.out"
}

@test "issue #346 repro: CLAUDE_CODE_CMD in .ralphrc does not choose what ralph executes" {
    make_project
    printf '#!/bin/sh\ntouch %s/marker\necho 9.9.9\n' "$TEST_DIR" > fakeclaude
    chmod +x fakeclaude
    echo "CLAUDE_CODE_CMD=\"$TEST_DIR/fakeclaude\"" > .ralphrc

    run_ralph_dry
    [ ! -e "$TEST_DIR/marker" ]
}

@test "issue #346 repro: a shell line in .ralphrc is not executed by ralph" {
    make_project
    printf '%s\n' "printf '%s\\n' RALPHRC_EXECUTED > $TEST_DIR/marker" "exit 0" > .ralphrc

    run_ralph_dry
    [ ! -e "$TEST_DIR/marker" ]
}

# =============================================================================
# Sibling readers of .ralphrc go through the same policy (lib/ralphrc.sh)
# =============================================================================

@test "issue #346: ralph-import does not execute a CLAUDE_CODE_CMD from .ralphrc" {
    printf '#!/bin/sh\ntouch %s/marker\necho 9.9.9\n' "$TEST_DIR" > pwn
    chmod +x pwn
    echo "CLAUDE_CODE_CMD=\"$TEST_DIR/pwn\"" > .ralphrc

    run env -u CLAUDE_CODE_CMD bash -c 'source "$1"; echo "CMD=$CLAUDE_CODE_CMD"; check_claude_version' _ "${BATS_TEST_DIRNAME}/../../ralph_import.sh"
    [ ! -e "$TEST_DIR/marker" ]
    [[ "$output" == *"CMD=claude"* ]]
    [[ "$output" == *"only accepted from the environment"* ]]
}

@test "issue #346: ralph-import honors CLAUDE_CODE_CMD from the environment" {
    printf '#!/bin/sh\ntouch %s/env-marker\necho 9.9.9\n' "$TEST_DIR" > myclaude
    chmod +x myclaude
    echo 'CLAUDE_CODE_CMD="claude"' > .ralphrc

    run env CLAUDE_CODE_CMD="$TEST_DIR/myclaude" bash -c 'source "$1"; check_claude_version' _ "${BATS_TEST_DIRNAME}/../../ralph_import.sh"
    [ -e "$TEST_DIR/env-marker" ]
}

@test "issue #346: inspect-allowed-tools reads .ralphrc as data, not code" {
    printf '%s\n' "touch $TEST_DIR/marker" 'ALLOWED_TOOLS="Write,Bash(git add *)"' > .ralphrc

    run env -u ALLOWED_TOOLS -u CLAUDE_ALLOWED_TOOLS bash "${BATS_TEST_DIRNAME}/../../tools/inspect-allowed-tools.sh" .ralphrc
    [ ! -e "$TEST_DIR/marker" ]
    [[ "$output" == *"Bash(git add *)"* ]]
}

@test "issue #346: SANDBOX_DOCKER_NETWORK=host is ignored from .ralphrc (none/bridge accepted)" {
    SANDBOX_DOCKER_NETWORK="bridge"
    echo 'SANDBOX_DOCKER_NETWORK="none"' > .ralphrc
    load_rc
    [ "$SANDBOX_DOCKER_NETWORK" = "none" ]

    SANDBOX_DOCKER_NETWORK="bridge"
    echo 'SANDBOX_DOCKER_NETWORK="host"' > .ralphrc
    load_rc
    [ "$SANDBOX_DOCKER_NETWORK" = "bridge" ]
    grep -q "only accepted from the environment" "$TEST_DIR/out"
}

@test "issue #346: control characters from .ralphrc are not echoed to the terminal" {
    printf 'CLAUDE_CODE_CMD='"'"'\033]0;pwned\007'"'"'\n' > .ralphrc

    load_rc
    [ "$CLAUDE_CODE_CMD" = "claude" ]
    [ "$(grep -c $'\033' "$TEST_DIR/out")" -eq 0 ]
}

@test "issue #346: a # glued to a closing quote is not treated as a comment" {
    printf '%s\n' 'OPTIONAL_SECTIONS="Later"#note' > .ralphrc

    load_rc
    [ "${OPTIONAL_SECTIONS:-}" != "Later" ]
}

@test "issue #346: the shipped ralphrc.template loads with no warnings" {
    cp "${BATS_TEST_DIRNAME}/../../templates/ralphrc.template" .ralphrc

    load_rc
    [ "$(grep -c 'WARN' "$TEST_DIR/out")" -eq 0 ]
}

@test "issue #346: backslash escape text from .ralphrc is not turned into escapes by echo -e" {
    printf '%s\n' "CLAUDE_CODE_CMD='\\033]0;pwned\\007'" > .ralphrc
    log_status() { echo -e "[$1] $2"; }   # the real log_status interprets escapes

    load_rc
    [ "$CLAUDE_CODE_CMD" = "claude" ]
    [ "$(grep -c $'\033' "$TEST_DIR/out")" -eq 0 ]
}

@test "issue #346: every CLI flag that sets a .ralphrc key is re-applied after load_ralphrc" {
    # Keys .ralphrc may set
    local allowed
    allowed=$(sed -n '/local allowed_keys="/,/"$/p' "$RALPH_LOOP" | tr -s ' \n"' '\n' | grep -E '^[A-Z_]+$' | sort -u)
    # Variables assigned by the CLI parse loop (top-level `while [[ $# -gt 0 ]]`)
    local cli_set
    cli_set=$(awk '/^while \[\[ \$# -gt 0 \]\]; do/{p=1} p' "$RALPH_LOOP" \
        | grep -oE '^[[:space:]]+[A-Z][A-Z_]*=' | tr -d ' =' | sort -u)

    local missing="" v
    for v in $(comm -12 <(echo "$allowed") <(echo "$cli_set")); do
        grep -qE "_cli_.*\]\] && ${v}=" "$RALPH_LOOP" || missing="$missing $v"
    done
    [ -z "$missing" ] || { echo "CLI flags overridden by .ralphrc:$missing"; false; }
}

@test "issue #346: SANDBOX_E2B_SANDBOX_ID is never taken from .ralphrc" {
    SANDBOX_E2B_SANDBOX_ID=""
    echo 'SANDBOX_E2B_SANDBOX_ID="sbx-attacker123"' > .ralphrc

    load_rc
    [ -z "$SANDBOX_E2B_SANDBOX_ID" ]
    grep -q "only accepted from the environment" "$TEST_DIR/out"
}

@test "issue #346: inspect-allowed-tools never prints raw control bytes from .ralphrc" {
    printf "ALLOWED_TOOLS='Read,\033]0;pwned\007Write'\n" > .ralphrc

    run env -u ALLOWED_TOOLS -u CLAUDE_ALLOWED_TOOLS bash "${BATS_TEST_DIRNAME}/../../tools/inspect-allowed-tools.sh" .ralphrc
    [ "$(printf '%s' "$output" | grep -c $'\033')" -eq 0 ]
}
