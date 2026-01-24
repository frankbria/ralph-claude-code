#!/usr/bin/env bash

# wizard_utils.sh - Interactive prompt utilities for Ralph enable wizard
# Provides consistent, user-friendly prompts for configuration

# Colors
WIZARD_CYAN='\033[0;36m'
WIZARD_GREEN='\033[0;32m'
WIZARD_YELLOW='\033[1;33m'
WIZARD_RED='\033[0;31m'
WIZARD_BOLD='\033[1m'
WIZARD_NC='\033[0m'

# =============================================================================
# BASIC PROMPTS
# =============================================================================

# confirm - Ask a yes/no question
#
# Parameters:
#   $1 (prompt) - The question to ask
#   $2 (default) - Default answer: "y" or "n" (optional, defaults to "n")
#
# Returns:
#   0 - User answered yes
#   1 - User answered no
#
# Example:
#   if confirm "Continue with installation?" "y"; then
#       echo "Installing..."
#   fi
#
confirm() {
    local prompt=$1
    local default="${2:-n}"
    local response

    local yn_hint="[y/N]"
    if [[ "${default,,}" == "y" ]]; then
        yn_hint="[Y/n]"
    fi

    while true; do
        echo -en "${WIZARD_CYAN}${prompt}${WIZARD_NC} ${yn_hint}: "
        read -r response

        # Handle empty response (use default)
        if [[ -z "$response" ]]; then
            response="$default"
        fi

        case "${response,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                echo -e "${WIZARD_YELLOW}Please answer yes (y) or no (n)${WIZARD_NC}"
                ;;
        esac
    done
}

# prompt_text - Ask for text input with optional default
#
# Parameters:
#   $1 (prompt) - The prompt text
#   $2 (default) - Default value (optional)
#
# Outputs:
#   Echoes the user's input (or default if empty)
#
# Example:
#   project_name=$(prompt_text "Project name" "my-project")
#
prompt_text() {
    local prompt=$1
    local default="${2:-}"
    local response

    if [[ -n "$default" ]]; then
        echo -en "${WIZARD_CYAN}${prompt}${WIZARD_NC} [${default}]: "
    else
        echo -en "${WIZARD_CYAN}${prompt}${WIZARD_NC}: "
    fi

    read -r response

    if [[ -z "$response" ]]; then
        echo "$default"
    else
        echo "$response"
    fi
}

# prompt_number - Ask for numeric input with optional default and range
#
# Parameters:
#   $1 (prompt) - The prompt text
#   $2 (default) - Default value (optional)
#   $3 (min) - Minimum value (optional)
#   $4 (max) - Maximum value (optional)
#
# Outputs:
#   Echoes the validated number
#
prompt_number() {
    local prompt=$1
    local default="${2:-}"
    local min="${3:-}"
    local max="${4:-}"
    local response

    while true; do
        if [[ -n "$default" ]]; then
            echo -en "${WIZARD_CYAN}${prompt}${WIZARD_NC} [${default}]: "
        else
            echo -en "${WIZARD_CYAN}${prompt}${WIZARD_NC}: "
        fi

        read -r response

        # Use default if empty
        if [[ -z "$response" ]]; then
            if [[ -n "$default" ]]; then
                echo "$default"
                return 0
            else
                echo -e "${WIZARD_YELLOW}Please enter a number${WIZARD_NC}"
                continue
            fi
        fi

        # Validate it's a number
        if ! [[ "$response" =~ ^[0-9]+$ ]]; then
            echo -e "${WIZARD_YELLOW}Please enter a valid number${WIZARD_NC}"
            continue
        fi

        # Check range if specified
        if [[ -n "$min" && "$response" -lt "$min" ]]; then
            echo -e "${WIZARD_YELLOW}Value must be at least ${min}${WIZARD_NC}"
            continue
        fi

        if [[ -n "$max" && "$response" -gt "$max" ]]; then
            echo -e "${WIZARD_YELLOW}Value must be at most ${max}${WIZARD_NC}"
            continue
        fi

        echo "$response"
        return 0
    done
}

# =============================================================================
# SELECTION PROMPTS
# =============================================================================

# select_option - Present a list of options for single selection
#
# Parameters:
#   $1 (prompt) - The question/prompt text
#   $@ (options) - Remaining arguments are the options
#
# Outputs:
#   Echoes the selected option (the text, not the number)
#
# Example:
#   choice=$(select_option "Select package manager" "npm" "yarn" "pnpm")
#   echo "Selected: $choice"
#
select_option() {
    local prompt=$1
    shift
    local options=("$@")
    local num_options=${#options[@]}

    echo -e "\n${WIZARD_BOLD}${prompt}${WIZARD_NC}"
    echo ""

    # Display options
    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${WIZARD_CYAN}${i})${WIZARD_NC} ${opt}"
        ((i++))
    done

    echo ""

    while true; do
        echo -en "Select option [1-${num_options}]: "
        read -r response

        # Validate it's a number in range
        if [[ "$response" =~ ^[0-9]+$ ]] && \
           [[ "$response" -ge 1 ]] && \
           [[ "$response" -le "$num_options" ]]; then
            # Return the option text (0-indexed array)
            echo "${options[$((response - 1))]}"
            return 0
        else
            echo -e "${WIZARD_YELLOW}Please enter a number between 1 and ${num_options}${WIZARD_NC}"
        fi
    done
}

# select_multiple - Present checkboxes for multi-selection
#
# Parameters:
#   $1 (prompt) - The question/prompt text
#   $@ (options) - Remaining arguments are the options
#
# Outputs:
#   Echoes space-separated list of selected options
#
# Example:
#   selected=$(select_multiple "Select task sources" "beads" "github" "prd")
#   echo "Selected: $selected"
#
select_multiple() {
    local prompt=$1
    shift
    local options=("$@")
    local num_options=${#options[@]}

    # Track selected state (0 = not selected, 1 = selected)
    declare -a selected
    for ((i = 0; i < num_options; i++)); do
        selected[$i]=0
    done

    # Display instructions
    echo -e "\n${WIZARD_BOLD}${prompt}${WIZARD_NC}"
    echo -e "${WIZARD_CYAN}(Enter numbers to toggle, press Enter when done)${WIZARD_NC}"
    echo ""

    while true; do
        # Display options with checkboxes
        local i=1
        for opt in "${options[@]}"; do
            local checkbox="[ ]"
            if [[ "${selected[$((i - 1))]}" == "1" ]]; then
                checkbox="[${WIZARD_GREEN}x${WIZARD_NC}]"
            fi
            echo -e "  ${WIZARD_CYAN}${i})${WIZARD_NC} ${checkbox} ${opt}"
            ((i++))
        done

        echo ""
        echo -en "Toggle [1-${num_options}] or Enter to confirm: "
        read -r response

        # Empty input = done
        if [[ -z "$response" ]]; then
            break
        fi

        # Validate it's a number in range
        if [[ "$response" =~ ^[0-9]+$ ]] && \
           [[ "$response" -ge 1 ]] && \
           [[ "$response" -le "$num_options" ]]; then
            # Toggle the selection
            local idx=$((response - 1))
            if [[ "${selected[$idx]}" == "0" ]]; then
                selected[$idx]=1
            else
                selected[$idx]=0
            fi
        else
            echo -e "${WIZARD_YELLOW}Please enter a number between 1 and ${num_options}${WIZARD_NC}"
        fi

        # Clear previous display (move cursor up)
        # Number of lines to clear: options + 2 (prompt line + input line)
        for ((j = 0; j < num_options + 2; j++)); do
            echo -en "\033[A\033[K"
        done
    done

    # Build result string
    local result=""
    for ((i = 0; i < num_options; i++)); do
        if [[ "${selected[$i]}" == "1" ]]; then
            if [[ -n "$result" ]]; then
                result="$result ${options[$i]}"
            else
                result="${options[$i]}"
            fi
        fi
    done

    echo "$result"
}

# select_with_default - Present options with a recommended default
#
# Parameters:
#   $1 (prompt) - The question/prompt text
#   $2 (default_index) - 1-based index of default option
#   $@ (options) - Remaining arguments are the options
#
# Outputs:
#   Echoes the selected option
#
select_with_default() {
    local prompt=$1
    local default_index=$2
    shift 2
    local options=("$@")
    local num_options=${#options[@]}

    echo -e "\n${WIZARD_BOLD}${prompt}${WIZARD_NC}"
    echo ""

    # Display options with default marked
    local i=1
    for opt in "${options[@]}"; do
        if [[ $i -eq $default_index ]]; then
            echo -e "  ${WIZARD_GREEN}${i})${WIZARD_NC} ${opt} ${WIZARD_GREEN}(recommended)${WIZARD_NC}"
        else
            echo -e "  ${WIZARD_CYAN}${i})${WIZARD_NC} ${opt}"
        fi
        ((i++))
    done

    echo ""

    while true; do
        echo -en "Select option [1-${num_options}] (default: ${default_index}): "
        read -r response

        # Use default if empty
        if [[ -z "$response" ]]; then
            echo "${options[$((default_index - 1))]}"
            return 0
        fi

        # Validate it's a number in range
        if [[ "$response" =~ ^[0-9]+$ ]] && \
           [[ "$response" -ge 1 ]] && \
           [[ "$response" -le "$num_options" ]]; then
            echo "${options[$((response - 1))]}"
            return 0
        else
            echo -e "${WIZARD_YELLOW}Please enter a number between 1 and ${num_options}${WIZARD_NC}"
        fi
    done
}

# =============================================================================
# DISPLAY UTILITIES
# =============================================================================

# print_header - Print a section header
#
# Parameters:
#   $1 (title) - The header title
#   $2 (phase) - Optional phase number (e.g., "1 of 5")
#
print_header() {
    local title=$1
    local phase="${2:-}"

    echo ""
    echo -e "${WIZARD_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${WIZARD_NC}"
    if [[ -n "$phase" ]]; then
        echo -e "${WIZARD_BOLD}  ${title}${WIZARD_NC} ${WIZARD_CYAN}(${phase})${WIZARD_NC}"
    else
        echo -e "${WIZARD_BOLD}  ${title}${WIZARD_NC}"
    fi
    echo -e "${WIZARD_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${WIZARD_NC}"
    echo ""
}

# print_bullet - Print a bullet point item
#
# Parameters:
#   $1 (text) - The text to display
#   $2 (symbol) - Optional symbol (defaults to "•")
#
print_bullet() {
    local text=$1
    local symbol="${2:-•}"

    echo -e "  ${WIZARD_CYAN}${symbol}${WIZARD_NC} ${text}"
}

# print_success - Print a success message
#
# Parameters:
#   $1 (message) - The message to display
#
print_success() {
    echo -e "${WIZARD_GREEN}✓${WIZARD_NC} $1"
}

# print_warning - Print a warning message
#
# Parameters:
#   $1 (message) - The message to display
#
print_warning() {
    echo -e "${WIZARD_YELLOW}⚠${WIZARD_NC} $1"
}

# print_error - Print an error message
#
# Parameters:
#   $1 (message) - The message to display
#
print_error() {
    echo -e "${WIZARD_RED}✗${WIZARD_NC} $1"
}

# print_info - Print an info message
#
# Parameters:
#   $1 (message) - The message to display
#
print_info() {
    echo -e "${WIZARD_CYAN}ℹ${WIZARD_NC} $1"
}

# print_detection_result - Print a detection result with status
#
# Parameters:
#   $1 (label) - What was detected
#   $2 (value) - The detected value
#   $3 (available) - "true" or "false"
#
print_detection_result() {
    local label=$1
    local value=$2
    local available="${3:-true}"

    if [[ "$available" == "true" ]]; then
        echo -e "  ${WIZARD_GREEN}✓${WIZARD_NC} ${label}: ${WIZARD_BOLD}${value}${WIZARD_NC}"
    else
        echo -e "  ${WIZARD_YELLOW}○${WIZARD_NC} ${label}: ${value}"
    fi
}

# =============================================================================
# PROGRESS DISPLAY
# =============================================================================

# show_progress - Display a simple progress indicator
#
# Parameters:
#   $1 (current) - Current step number
#   $2 (total) - Total steps
#   $3 (message) - Current step message
#
show_progress() {
    local current=$1
    local total=$2
    local message=$3

    local bar_width=30
    local filled=$((current * bar_width / total))
    local empty=$((bar_width - filled))

    local bar=""
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done

    echo -en "\r${WIZARD_CYAN}[${bar}]${WIZARD_NC} ${current}/${total} ${message}"
}

# clear_line - Clear the current line
#
clear_line() {
    echo -en "\r\033[K"
}

# =============================================================================
# SUMMARY DISPLAY
# =============================================================================

# print_summary - Print a summary box
#
# Parameters:
#   $1 (title) - Summary title
#   $@ (items) - Key=value pairs to display
#
# Example:
#   print_summary "Configuration" "Project=my-app" "Type=typescript" "Tasks=15"
#
print_summary() {
    local title=$1
    shift
    local items=("$@")

    echo ""
    echo -e "${WIZARD_BOLD}┌─ ${title} ───────────────────────────────────────┐${WIZARD_NC}"
    echo "│"

    for item in "${items[@]}"; do
        local key="${item%%=*}"
        local value="${item#*=}"
        printf "│  ${WIZARD_CYAN}%-20s${WIZARD_NC} %s\n" "${key}:" "$value"
    done

    echo "│"
    echo -e "${WIZARD_BOLD}└────────────────────────────────────────────────────┘${WIZARD_NC}"
    echo ""
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f confirm
export -f prompt_text
export -f prompt_number
export -f select_option
export -f select_multiple
export -f select_with_default
export -f print_header
export -f print_bullet
export -f print_success
export -f print_warning
export -f print_error
export -f print_info
export -f print_detection_result
export -f show_progress
export -f clear_line
export -f print_summary
