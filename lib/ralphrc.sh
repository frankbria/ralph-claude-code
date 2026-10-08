#!/usr/bin/env bash
# lib/ralphrc.sh - Safe .ralphrc parsing (Issue #346)
#
# .ralphrc is repository-controlled, so it is read as KEY=VALUE data and never
# sourced. Shared by ralph_loop.sh (load_ralphrc), ralph_import.sh and
# tools/inspect-allowed-tools.sh so every reader applies the same grammar and
# the same command-bearing-key policy. Bash 3.2 compatible.

# ralphrc_parse_line LINE
#
# Sets RALPHRC_KEY and RALPHRC_VALUE (the literal value, per bash quoting rules;
# `$`, backticks, backslashes and control characters are never accepted).
# Returns 0 for an assignment, 1 for a blank or comment line, 2 for a line that
# is not KEY=VALUE, 3 for a value bash would expand or execute (rejected rather
# than reinterpreted).
ralphrc_parse_line() {
    local line="$1"
    local re_assign='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    local re_dquoted='^"([^"]*)"([[:space:]]+#.*)?$'
    local re_squoted="^'([^']*)'([[:space:]]+#.*)?\$"
    local re_bare='^([^[:space:]#]*)([[:space:]]+#.*)?$'
    # Never allowed in any value, however quoted: values later reach bash
    # arithmetic (where a[$(cmd)] executes) and echo -e (where \033 renders)
    local re_unsafe='[$`\\[:cntrl:]]'
    local re_bare_unsafe='[$`\\;|&<>()"'"'"']'

    RALPHRC_KEY=""
    RALPHRC_VALUE=""
    line="${line#$'\xef\xbb\xbf'}"
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && return 1
    [[ "$line" =~ $re_assign ]] || return 2

    RALPHRC_KEY="${BASH_REMATCH[2]}"
    local value="${BASH_REMATCH[3]}"
    if [[ "$value" =~ $re_squoted ]] || [[ "$value" =~ $re_dquoted ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ $re_bare ]]; then
        value="${BASH_REMATCH[1]}"
        [[ "$value" =~ $re_bare_unsafe ]] && return 3
    else
        return 3
    fi
    [[ "$value" =~ $re_unsafe ]] && return 3
    RALPHRC_VALUE="$value"
    return 0
}

# ralphrc_value_allowed KEY VALUE
#
# Command-bearing keys decide what Ralph executes, sources, or hands
# credentials to (or, for SANDBOX_DOCKER_NETWORK=host, how isolated it is). From the repo file only stock values are honored; custom
# values must come from the user's environment (or CLI flags). Returns 1 for a
# disallowed command-bearing value, 0 otherwise.
ralphrc_value_allowed() {
    case "$1=$2" in
        CLAUDE_CODE_CMD=|CLAUDE_CODE_CMD=claude|"CLAUDE_CODE_CMD=npx @anthropic-ai/claude-code") return 0 ;;
        SANDBOX_DOCKER_IMAGE=|SANDBOX_DOCKER_IMAGE=ralph-sandbox:latest|SANDBOX_DOCKER_IMAGE=ghcr.io/frankbria/ralph-sandbox:latest) return 0 ;;
        SANDBOX_E2B_TEMPLATE=|SANDBOX_E2B_TEMPLATE=base) return 0 ;;
        SANDBOX_DOCKER_NETWORK=|SANDBOX_DOCKER_NETWORK=bridge|SANDBOX_DOCKER_NETWORK=none) return 0 ;;
        RALPH_SHELL_INIT_FILE=|SANDBOX_E2B_SANDBOX_ID=) return 0 ;;
        CLAUDE_CODE_CMD=*|SANDBOX_DOCKER_IMAGE=*|SANDBOX_E2B_TEMPLATE=*|SANDBOX_DOCKER_NETWORK=*|RALPH_SHELL_INIT_FILE=*|SANDBOX_E2B_SANDBOX_ID=*) return 1 ;;
    esac
    return 0
}

# ralphrc_value_numeric_ok KEY VALUE
#
# Numeric keys reach bash arithmetic ([[ -ge ]], $((...))), which dereferences
# identifiers recursively (a bare name could pull code in from elsewhere) and is
# integer-only (a decimal errors the comparison and silently disables the guard).
# Returns 1 when VALUE doesn't fit KEY's numeric class.
ralphrc_value_numeric_ok() {
    case "$1" in
        MAX_CALLS_PER_HOUR|MAX_TOKENS_PER_HOUR|CLAUDE_TIMEOUT_MINUTES|CLAUDE_SESSION_EXPIRY_HOURS|SESSION_EXPIRY_HOURS|\
        CB_COOLDOWN_MINUTES|CB_NO_PROGRESS_THRESHOLD|CB_SAME_ERROR_THRESHOLD|CB_OUTPUT_DECLINE_THRESHOLD|\
        CB_PERMISSION_DENIAL_THRESHOLD|MAX_CONSECUTIVE_TEST_LOOPS|MAX_CONSECUTIVE_DONE_SIGNALS|TEST_PERCENTAGE_THRESHOLD|\
        COMMENT_INTERVAL|SANDBOX_E2B_TIMEOUT|SYNC_MAX_FILE_SIZE)
            [[ "$2" =~ ^[0-9]+$ ]] ;;
        SANDBOX_E2B_MAX_COST|SANDBOX_E2B_COST_ALERT|SANDBOX_E2B_COST_PER_HOUR)
            [[ -z "$2" || "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] ;;
        CLAUDE_MIN_VERSION)
            [[ -z "$2" || "$2" =~ ^[0-9]+([.][0-9]+)*$ ]] ;;
        *) return 0 ;;
    esac
}

# ralphrc_display VALUE - VALUE with control characters and backslashes replaced
# by '?', safe to print even via `echo -e` (repo-controlled text must not reach
# the terminal as escape sequences)
ralphrc_display() {
    local v="${1//[[:cntrl:]]/?}"
    printf '%s' "${v//\\/?}"
}

# ralphrc_get FILE KEY
#
# Prints KEY's literal value from FILE (last valid assignment wins). Values a
# repo may not set (see ralphrc_value_allowed) are skipped with a warning on
# stderr. Returns 1 when FILE has no usable assignment for KEY.
ralphrc_get() {
    local file="$1" key="$2" line found=1 value=""
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ralphrc_parse_line "$line" || continue
        [[ "$RALPHRC_KEY" == "$key" ]] || continue
        if ! ralphrc_value_allowed "$RALPHRC_KEY" "$RALPHRC_VALUE"; then
            echo "WARN: $file: $key='$(ralphrc_display "$RALPHRC_VALUE")' ignored - custom values for this key are only accepted from the environment (export $key=...)" >&2
            continue
        fi
        value="$RALPHRC_VALUE"
        found=0
    done < "$file"
    [[ $found -eq 0 ]] && printf '%s\n' "$value"
    return $found
}
