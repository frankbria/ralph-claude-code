#!/bin/bash

# Ralph for Devin CLI - Uninstallation Script
# Removes only Devin-specific Ralph components, leaving Claude Code Ralph untouched.
#
# Version: 0.1.0

set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
    esac

    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

# Check if Devin Ralph is installed
check_installation() {
    local installed=false

    for cmd in ralph-devin ralph-devin-monitor ralph-devin-setup ralph-devin-import ralph-devin-enable ralph-devin-enable-ci; do
        if [[ -f "$INSTALL_DIR/$cmd" ]]; then
            installed=true
            break
        fi
    done

    if [[ "$installed" == "false" && -d "$DEVIN_HOME" ]]; then
        installed=true
    fi

    if [[ "$installed" == "false" ]]; then
        log "WARN" "Ralph Devin does not appear to be installed"
        echo "Checked locations:"
        echo "  - $INSTALL_DIR/ralph-devin*"
        echo "  - $DEVIN_HOME"
        exit 0
    fi
}

# Show removal plan
show_removal_plan() {
    echo ""
    log "INFO" "The following Devin-specific items will be removed:"
    echo ""

    echo "Commands in $INSTALL_DIR:"
    for cmd in ralph-devin ralph-devin-monitor ralph-devin-setup ralph-devin-import ralph-devin-enable ralph-devin-enable-ci; do
        if [[ -f "$INSTALL_DIR/$cmd" ]]; then
            echo "  - $cmd"
        fi
    done

    if [[ -d "$DEVIN_HOME" ]]; then
        echo ""
        echo "Devin scripts directory:"
        echo "  - $DEVIN_HOME (scripts and libraries)"
    fi

    echo ""
    echo "Note: Claude Code Ralph installation will NOT be affected."
    echo ""
}

# Confirm uninstall
confirm_uninstall() {
    if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
        return 0
    fi

    read -p "Are you sure you want to uninstall Ralph Devin? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Uninstallation cancelled"
        exit 0
    fi
}

# Remove Devin commands
remove_commands() {
    log "INFO" "Removing Ralph Devin commands..."

    local removed=0
    for cmd in ralph-devin ralph-devin-monitor ralph-devin-setup ralph-devin-import ralph-devin-enable ralph-devin-enable-ci; do
        if [[ -f "$INSTALL_DIR/$cmd" ]]; then
            rm -f "$INSTALL_DIR/$cmd"
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "SUCCESS" "Removed $removed command(s) from $INSTALL_DIR"
    else
        log "INFO" "No commands found in $INSTALL_DIR"
    fi
}

# Remove Devin home directory
remove_devin_home() {
    log "INFO" "Removing Devin scripts directory..."

    if [[ -d "$DEVIN_HOME" ]]; then
        rm -rf "$DEVIN_HOME"
        log "SUCCESS" "Removed $DEVIN_HOME"
    else
        log "INFO" "Devin scripts directory not found"
    fi
}

# Main
main() {
    echo "Uninstalling Ralph for Devin CLI..."

    check_installation
    show_removal_plan
    confirm_uninstall "$1"

    echo ""
    remove_commands
    remove_devin_home

    echo ""
    log "SUCCESS" "Ralph for Devin CLI has been uninstalled"
    echo ""
    echo "Note: Claude Code Ralph (ralph, ralph-monitor, etc.) is still installed."
    echo "      Project files (.ralph/) in your projects are not removed."
    echo ""
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        echo "Ralph for Devin CLI - Uninstallation Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -y, --yes    Skip confirmation prompt"
        echo "  -h, --help   Show this help message"
        echo ""
        echo "This script removes only Devin-specific Ralph components."
        echo "Claude Code Ralph installation is NOT affected."
        ;;
    *)
        main "$1"
        ;;
esac
