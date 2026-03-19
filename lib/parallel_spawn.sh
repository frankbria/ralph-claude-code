#!/bin/bash

# =============================================================================
# Ralph Parallel Spawn - Terminal-Aware Agent Spawner
# =============================================================================
# Spawns multiple parallel agents using the best available method:
#   - iTerm2 tabs:       when running from iTerm2 on macOS
#   - IDE terminal tabs: when running from VS Code, Windsurf, Cursor, etc.
#   - Background jobs:   fallback for unsupported terminals
#
# Usage (from other scripts):
#   source lib/parallel_spawn.sh
#   spawn_parallel_agents <count> <command> [args...]
#
# Requires: macOS (for tab spawning via AppleScript)

# Colors (reuse if already defined)
_PS_RED="${RED:-\033[0;31m}"
_PS_GREEN="${GREEN:-\033[0;32m}"
_PS_YELLOW="${YELLOW:-\033[1;33m}"
_PS_BLUE="${BLUE:-\033[0;34m}"
_PS_PURPLE="${PURPLE:-\033[0;35m}"
_PS_NC="${NC:-\033[0m}"

# Detect terminal environment
# Returns: "iterm", "ide", or "other"
detect_terminal_env() {
    # VS Code, Windsurf, Cursor all set TERM_PROGRAM=vscode
    if [[ "${TERM_PROGRAM:-}" == "vscode" ]]; then
        echo "ide"
        return 0
    fi

    # JetBrains IDEs (IntelliJ, WebStorm, etc.)
    if [[ "${TERMINAL_EMULATOR:-}" == JetBrains-* ]]; then
        echo "ide"
        return 0
    fi

    # Explicit iTerm2
    if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then
        echo "iterm"
        return 0
    fi

    # Fallback: unknown terminal
    echo "other"
    return 0
}

# Detect the IDE application name from the VSCODE_PID environment variable.
# VS Code and all its forks (Windsurf, Cursor) set VSCODE_PID to the main
# Electron process PID. We read that process's executable path to determine
# which app is running.
# Returns the macOS application name (e.g. "Windsurf", "Cursor", "Code")
detect_ide_app_name() {
    if [[ -z "${VSCODE_PID:-}" ]]; then
        return 1
    fi

    local exe_info
    exe_info=$(ps -p "$VSCODE_PID" -o args= 2>/dev/null) || return 1

    if [[ "$exe_info" == *"Windsurf"* ]]; then
        echo "Windsurf"
    elif [[ "$exe_info" == *"Cursor"* ]]; then
        echo "Cursor"
    elif [[ "$exe_info" == *"Visual Studio Code"* ]] || [[ "$exe_info" == *"Code.app"* ]] || [[ "$exe_info" == *"Code Helper"* ]]; then
        echo "Code"
    else
        return 1
    fi
}

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

# Spawn agents as iTerm2 tabs (original behavior)
spawn_iterm_tabs() {
    local count="$1"
    shift
    local cmd_args=("$@")
    local cwd
    cwd="$(pwd)"

    if ! check_iterm_available; then
        return 1
    fi

    local i
    for ((i = 1; i <= count; i++)); do
        echo -e "${_PS_BLUE}Spawning agent $i/$count (iTerm2 tab)...${_PS_NC}"

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

# Spawn agents as new integrated terminal tabs in VS Code / Windsurf / Cursor.
# Uses AppleScript + System Events to:
#   1. Focus the IDE window
#   2. Send Ctrl+Shift+` to create a new terminal tab
#   3. Type the command and press Enter
spawn_ide_terminals() {
    local count="$1"
    shift
    local cmd_args=("$@")
    local cwd
    cwd="$(pwd)"

    local ide_app
    ide_app="$(detect_ide_app_name)" || {
        echo -e "${_PS_RED}Error: Could not detect IDE application name from VSCODE_PID${_PS_NC}"
        return 1
    }

    if [[ "$(uname)" != "Darwin" ]]; then
        echo -e "${_PS_RED}Error: IDE terminal tab spawning requires macOS${_PS_NC}"
        return 1
    fi

    # Build the command string to type into each terminal.
    # Prefix with 'sleep 2' to let the IDE terminal fully initialize its PTY
    # dimensions — TUI apps (e.g. Devin CLI) panic if they query terminal size
    # before the PTY is ready and get 0 cols/rows.
    local cmd_text="sleep 2 && cd $(printf '%q' "$cwd") && ${cmd_args[*]}"
    # Escape for AppleScript string literal: \ -> \\, " -> \"
    local as_cmd
    as_cmd=$(printf '%s' "$cmd_text" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local i
    for ((i = 1; i <= count; i++)); do
        echo -e "${_PS_BLUE}Spawning agent $i/$count ($ide_app terminal tab)...${_PS_NC}"

        local tmpscript
        tmpscript=$(mktemp /tmp/ralph_spawn_XXXXXX.scpt)

        # Write AppleScript to temp file to avoid nested escaping issues
        cat > "$tmpscript" <<ASCRIPT_EOF
tell application "$ide_app" to activate
delay 0.5
tell application "System Events"
    tell process "$ide_app"
        -- Ctrl+Shift+\` → "Terminal: Create New Terminal" in VS Code / forks
        key code 50 using {control down, shift down}
        delay 2.0
        keystroke "$as_cmd"
        delay 0.3
        keystroke return
    end tell
end tell
ASCRIPT_EOF

        if ! osascript "$tmpscript" 2>/dev/null; then
            rm -f "$tmpscript"
            echo -e "${_PS_RED}Error: AppleScript failed. Ensure Accessibility permissions are granted for your terminal.${_PS_NC}"
            echo -e "${_PS_YELLOW}  System Settings → Privacy & Security → Accessibility → enable your terminal app${_PS_NC}"
            return 1
        fi
        rm -f "$tmpscript"

        # Longer delay between IDE terminal spawns (UI needs time to settle)
        if [[ $i -lt $count ]]; then
            sleep 1.5
        fi
    done

    echo ""
    echo -e "${_PS_GREEN}All $count agents spawned as $ide_app terminal tabs.${_PS_NC}"
    echo -e "${_PS_YELLOW}Tip: Use the terminal tab bar in $ide_app to switch between agents.${_PS_NC}"

    return 0
}

# Spawn agents as background processes (fallback for unsupported terminals)
spawn_background_agents() {
    local count="$1"
    shift
    local cmd_args=("$@")
    local cwd
    cwd="$(pwd)"
    local log_dir="${cwd}/.ralph/logs/parallel"
    local pids=()

    mkdir -p "$log_dir"

    local i
    for ((i = 1; i <= count; i++)); do
        local log_file="${log_dir}/agent_${i}.log"
        echo -e "${_PS_BLUE}Spawning agent $i/$count (background)...${_PS_NC}"
        echo -e "  ${_PS_YELLOW}Log: ${log_file}${_PS_NC}"

        # Run each agent in a background subshell with output tee'd to a log file
        (cd "$cwd" && "${cmd_args[@]}" > >(tee -a "$log_file") 2>&1) &
        pids+=($!)

        if [[ $i -lt $count ]]; then
            sleep 0.5
        fi
    done

    echo ""
    echo -e "${_PS_GREEN}All $count agents spawned as background processes.${_PS_NC}"
    echo -e "${_PS_YELLOW}PIDs: ${pids[*]}${_PS_NC}"
    echo -e "${_PS_YELLOW}Logs: ${log_dir}/agent_*.log${_PS_NC}"
    echo -e "${_PS_YELLOW}Tip: Use 'kill <pid>' to stop an individual agent, or 'kill ${pids[*]}' to stop all.${_PS_NC}"

    # Wait for all agents to finish
    echo -e "\n${_PS_BLUE}Waiting for all agents to complete (Ctrl+C to interrupt)...${_PS_NC}"
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo -e "${_PS_YELLOW}$failed agent(s) exited with errors. Check logs in ${log_dir}/${_PS_NC}"
    else
        echo -e "${_PS_GREEN}All $count agents completed successfully.${_PS_NC}"
    fi

    return 0
}

# Spawn N parallel agents, each running the given command.
# Automatically selects the best spawn method based on terminal environment:
#   - iTerm2 → new iTerm tabs (AppleScript → iTerm2 API)
#   - IDE    → new integrated terminal tabs (AppleScript → System Events keystroke)
#   - other  → background processes (fallback)
# Set PARALLEL_BG=true to force background mode regardless of terminal.
# Arguments:
#   $1 - number of agents to spawn
#   $2... - the command and arguments to run in each agent
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

    # Force background mode when PARALLEL_BG is set
    local force_bg="${PARALLEL_BG:-false}"

    local term_env
    if [[ "$force_bg" == "true" ]]; then
        term_env="background"
    else
        term_env="$(detect_terminal_env)"
    fi

    local spawn_method="$term_env"
    # For IDE, verify we can detect the app name; fall back to background if not
    if [[ "$term_env" == "ide" ]]; then
        if detect_ide_app_name >/dev/null 2>&1; then
            spawn_method="ide ($(detect_ide_app_name))"
        else
            spawn_method="background (IDE app not detected)"
        fi
    fi

    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo -e "${_PS_BLUE}  Ralph Parallel Mode${_PS_NC}"
    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo -e "  ${_PS_GREEN}Agents:${_PS_NC}    $count"
    echo -e "  ${_PS_GREEN}Directory:${_PS_NC} $cwd"
    echo -e "  ${_PS_GREEN}Command:${_PS_NC}   ${cmd_args[*]}"
    echo -e "  ${_PS_GREEN}Terminal:${_PS_NC}  $spawn_method"
    echo -e "${_PS_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PS_NC}"
    echo ""

    case "$term_env" in
        iterm)
            spawn_iterm_tabs "$count" "${cmd_args[@]}"
            ;;
        ide)
            # Try IDE terminal tabs; fall back to background on failure
            if detect_ide_app_name >/dev/null 2>&1; then
                spawn_ide_terminals "$count" "${cmd_args[@]}" || {
                    echo -e "${_PS_YELLOW}IDE terminal spawn failed, falling back to background processes...${_PS_NC}"
                    spawn_background_agents "$count" "${cmd_args[@]}"
                }
            else
                echo -e "${_PS_YELLOW}Could not detect IDE app name, falling back to background processes...${_PS_NC}"
                spawn_background_agents "$count" "${cmd_args[@]}"
            fi
            ;;
        background|other)
            spawn_background_agents "$count" "${cmd_args[@]}"
            ;;
    esac
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
