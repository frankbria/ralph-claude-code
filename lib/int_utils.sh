#!/usr/bin/env bash
# lib/int_utils.sh - Safe integer coercion for untrusted values (Issue #371)
#
# Bash arithmetic evaluates its operands as expressions, so a[$(cmd)] read from
# a .ralph/ state file (which a repository can commit) or parsed from Claude's
# output runs cmd at `$((x + 0))` or `[[ $x -ge n ]]`. Every such value goes
# through to_int before it is used as a number.

# to_int VALUE - VALUE as a base-10 integer when it is one (surrounding
# whitespace ignored, at most 18 digits), otherwise 0. Never evaluates VALUE.
to_int() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$v" =~ ^[0-9]{1,18}$ ]]; then
        printf '%s' "$((10#$v))"
    else
        printf '0'
    fi
}
