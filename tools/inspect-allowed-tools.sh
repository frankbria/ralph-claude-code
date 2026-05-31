#!/usr/bin/env bash
#
# inspect-allowed-tools.sh — prints the exact `--allowedTools` argv that
# ralph_loop.sh would pass to Claude CLI for a given .ralphrc.
#
# Diagnostic helper for issue #154 (Bash wildcard patterns in ALLOWED_TOOLS
# not matching). Lets users verify that their pattern reaches Claude with
# the bytes they expect, ruling out shell-quoting or comma-split bugs in
# ralph before opening a Claude CLI ticket.
#
# Usage:
#   tools/inspect-allowed-tools.sh                  # uses ./.ralphrc
#   tools/inspect-allowed-tools.sh path/to/.ralphrc
#   ALLOWED_TOOLS='Bash(git *)' tools/inspect-allowed-tools.sh   # ad-hoc
#
# Exit 0 always — this is a read-only inspection tool.

set -euo pipefail

rcfile="${1:-.ralphrc}"
allowed_from_env="${ALLOWED_TOOLS:-${CLAUDE_ALLOWED_TOOLS:-}}"

if [[ -n "$allowed_from_env" ]]; then
    echo "Source: \$ALLOWED_TOOLS env var"
    allowed="$allowed_from_env"
elif [[ -f "$rcfile" ]]; then
    echo "Source: $rcfile"
    # Source in a subshell-style block to avoid leaking other .ralphrc vars
    # into this script, but still pick up ALLOWED_TOOLS.
    allowed=$(
        # shellcheck disable=SC1090
        source "$rcfile"
        printf '%s' "${ALLOWED_TOOLS:-${CLAUDE_ALLOWED_TOOLS:-}}"
    )
else
    echo "ERROR: $rcfile not found and no ALLOWED_TOOLS env var set" >&2
    echo "Usage: $0 [path/to/.ralphrc]" >&2
    exit 2
fi

if [[ -z "$allowed" ]]; then
    echo "(empty — no --allowedTools flag would be passed)"
    exit 0
fi

echo "Raw value:"
echo "  $allowed"
echo

# Replicate the parsing from ralph_loop.sh:build_claude_command
declare -a tools_array=()
IFS=','
read -ra raw_tokens <<< "$allowed"
unset IFS
for tool in "${raw_tokens[@]}"; do
    # Trim whitespace (matches the sed in ralph_loop.sh)
    tool="${tool#"${tool%%[![:space:]]*}"}"
    tool="${tool%"${tool##*[![:space:]]}"}"
    [[ -n "$tool" ]] && tools_array+=("$tool")
done

echo "Parsed argv (${#tools_array[@]} tools):"
echo "  --allowedTools"
for i in "${!tools_array[@]}"; do
    printf '  [%d] %q\n' "$i" "${tools_array[$i]}"
done

echo
echo "Notes:"
echo "  * Each tool is passed as a separate positional argument."
echo "  * Patterns like 'Bash(git *)' that contain shell metacharacters"
echo "    should appear LITERALLY in the printf %q output above."
echo "  * If a literal '*' got expanded to filenames, that's a quoting bug —"
echo "    please file a ralph issue."
echo "  * If the printf output looks correct but Claude still denies a"
echo "    command, the issue is likely in Claude CLI's matcher itself."
echo "    Reference issue #243 (compound-command false positives) for one"
echo "    documented case ralph already works around."
