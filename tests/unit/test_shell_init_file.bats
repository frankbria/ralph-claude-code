#!/usr/bin/env bats
# Issue #211 (ported from upstream frankbria/ralph-claude-code):
# RALPH_SHELL_INIT_FILE sources a shell init file before launching the Claude
# CLI. Use case: zsh / Nix / asdf users whose `claude` lives on a PATH set in
# ~/.zshrc; bash startup wouldn't pick it up otherwise.
#
# Pattern follows test_cli_rc_precedence.bats — subshell isolation.

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

_load_in_subshell() {
    local setup_snippet="$1"
    local var_to_check="$2"
    bash -c "
        set +e
        source '$RALPH_SCRIPT' >/dev/null 2>&1
        trap - EXIT SIGINT SIGTERM
        $setup_snippet
        load_ralphrc >/dev/null 2>&1
        printf '%s' \"\${$var_to_check}\"
    " 2>/dev/null
}

@test "RALPH_SHELL_INIT_FILE: defaults to empty when unset" {
    local result
    result=$(_load_in_subshell '' 'RALPH_SHELL_INIT_FILE')
    [[ -z "$result" ]]
}

@test "RALPH_SHELL_INIT_FILE: .ralphrc value loads when env unset" {
    cat > .ralphrc <<'EOF'
RALPH_SHELL_INIT_FILE="/etc/ralphrc-test-init"
EOF
    local result
    result=$(_load_in_subshell '' 'RALPH_SHELL_INIT_FILE')
    [[ "$result" == "/etc/ralphrc-test-init" ]]
}

@test "RALPH_SHELL_INIT_FILE: env var beats .ralphrc value" {
    cat > .ralphrc <<'EOF'
RALPH_SHELL_INIT_FILE="/from/ralphrc"
EOF
    local result
    result=$(_load_in_subshell '_env_RALPH_SHELL_INIT_FILE=/from/env; RALPH_SHELL_INIT_FILE=/from/env' 'RALPH_SHELL_INIT_FILE')
    [[ "$result" == "/from/env" ]]
}

@test "RALPH_SHELL_INIT_FILE: env-snapshot variable is declared" {
    # Regression guard for the env-precedence chain — _env_RALPH_SHELL_INIT_FILE
    # must be captured before defaults are set, same as other config vars.
    grep -q '^_env_RALPH_SHELL_INIT_FILE=' "$RALPH_SCRIPT"
}

@test "RALPH_SHELL_INIT_FILE: source block exists in main()" {
    # Verify the source-and-warn block is wired into main() before
    # validate_claude_command. Anchor on the issue tag we left in the comment.
    grep -q 'Issue #211' "$RALPH_SCRIPT"
    grep -q 'source "\$RALPH_SHELL_INIT_FILE"' "$RALPH_SCRIPT"
    grep -q 'RALPH_SHELL_INIT_FILE not found' "$RALPH_SCRIPT"
}
