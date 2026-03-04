#!/bin/bash

# =============================================================================
# Ralph Parallel Spawn - iTerm2 Tab Spawner
# =============================================================================
# Spawns multiple iTerm2 tabs in the same working directory, each running
# the specified ralph command in interactive (int) mode.
#
# Usage (from other scripts):
#   source lib/parallel_spawn.sh
#   spawn_parallel_agents <count> <command> [args...]
#
# Requires: macOS + iTerm2

# Colors (reuse if already defined)
_PS_RED="${RED:-\033[0;31m}"
_PS_GREEN="${GREEN:-\033[0;32m}"
_PS_YELLOW="${YELLOW:-\033[1;33m}"
_PS_BLUE="${BLUE:-\033[0;34m}"
_PS_PURPLE="${PURPLE:-\033[0;35m}"
_PS_NC="${NC:-\033[0m}"

# Validate iTerm2 is available
check_iterm_available() {
    if [[ "$(uname)" != "Darwin" ]]; then
        echo -e "${_PS_RED}Error: Parallel spawn requires macOS with iTerm2${_PS_NC}"
        return 1
    fi

    if ! osascript -e 'tell application "System Events" to get name of every process' 2>/dev/null | grep -q "iTerm2"; then
        # iTerm2 might not be running yet — check if it's installed
        if [[ ! -d "/Applications/iTerm.app" ]] && [[ ! -d "$HOME/Applications/iTerm.app" ]]; then
            echo -e "${_PS_RED}Error: iTerm2 not found. Install from https://iterm2.com${_PS_NC}"
            return 1
        fi
    fi

    return 0
}

# Spawn N parallel iTerm2 tabs, each running the given command
# Arguments:
#   $1 - number of tabs to spawn
#   $2... - the command and arguments to run in each tab
spawn_parallel_agents() {
    local count="$1"
    shift
    local cmd_args=("$@")
    local cwd
    cwd="$(pwd)"

    if [[ -z "$count" ]] || [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${_PS_RED}Error: --parallel requires a positive integer (got: '${count}')${_PS_NC}"
        return 1
    fi

    if [[ "$count" -gt 10 ]]; then
        echo -e "${_PS_RED}Error: Maximum 10 parallel agents supported (got: $count)${_PS_NC}"
        return 1
    fi

    if ! check_iterm_available; then
        return 1
    fi

    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo -e "${_PS_BLUE}  Ralph Parallel Mode${_PS_NC}"
    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo -e "  ${_PS_GREEN}Agents:${_PS_NC}    $count"
    echo -e "  ${_PS_GREEN}Directory:${_PS_NC} $cwd"
    echo -e "  ${_PS_GREEN}Command:${_PS_NC}   ${cmd_args[*]}"
    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo ""

    local i
    for ((i = 1; i <= count; i++)); do
        echo -e "${_PS_BLUE}Spawning agent $i/$count...${_PS_NC}"

        osascript <<APPLESCRIPT
tell application "iTerm2"
    activate
    tell current window
        create tab with default profile
        tell current session
            write text "cd $(printf '%q' "$cwd") && ${cmd_args[*]}"
        end tell
    end tell
end tell
APPLESCRIPT

        # Small delay between spawns to avoid overwhelming iTerm
        if [[ $i -lt $count ]]; then
            sleep 0.5
        fi
    done

    echo ""
    echo -e "${_PS_GREEN}All $count agents spawned as iTerm2 tabs.${_PS_NC}"
    echo -e "${_PS_YELLOW}Tip: Use Cmd+Shift+] / Cmd+Shift+[ to switch between tabs.${_PS_NC}"

    return 0
}

# Build the ralph int-mode command for a given engine
# Arguments:
#   $1 - engine: "claude", "codex", or "devin"
#   $2... - extra flags to pass through
build_int_command() {
    local engine="$1"
    shift
    local extra_args=("$@")

    case "$engine" in
        claude)
            echo "ralph --live --monitor ${extra_args[*]}"
            ;;
        codex)
            echo "ralph-codex --no-codex-auto-exit ${extra_args[*]}"
            ;;
        devin)
            echo "ralph-devin --no-devin-auto-exit ${extra_args[*]}"
            ;;
        *)
            echo -e "${_PS_RED}Error: Unknown engine '$engine'. Use: claude, codex, or devin${_PS_NC}" >&2
            return 1
            ;;
    esac
}
