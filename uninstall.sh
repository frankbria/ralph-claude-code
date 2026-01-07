#!/bin/bash

# Ralph for Claude Code - Uninstallation Script
set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"

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

# Check if Ralph is installed
check_installation() {
    local installed=false

    if [ -f "$INSTALL_DIR/ralph" ] || [ -d "$RALPH_HOME" ]; then
        installed=true
    fi

    if [ "$installed" = false ]; then
        log "WARN" "Ralph does not appear to be installed"
        echo "Checked locations:"
        echo "  - $INSTALL_DIR/ralph"
        echo "  - $RALPH_HOME"
        exit 0
    fi
}

# Show what will be removed
show_removal_plan() {
    echo ""
    log "INFO" "The following will be removed:"
    echo ""

    # Commands
    echo "Commands in $INSTALL_DIR:"
    for cmd in ralph ralph-monitor ralph-setup ralph-import; do
        if [ -f "$INSTALL_DIR/$cmd" ]; then
            echo "  - $cmd"
        fi
    done

    # Ralph home
    if [ -d "$RALPH_HOME" ]; then
        echo ""
        echo "Ralph home directory:"
        echo "  - $RALPH_HOME (includes templates, scripts, and libraries)"
    fi

    echo ""
}

# Confirm uninstallation
confirm_uninstall() {
    if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
        return 0
    fi

    read -p "Are you sure you want to uninstall Ralph? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Uninstallation cancelled"
        exit 0
    fi
}

# Remove commands
remove_commands() {
    log "INFO" "Removing Ralph commands..."

    local removed=0
    for cmd in ralph ralph-monitor ralph-setup ralph-import; do
        if [ -f "$INSTALL_DIR/$cmd" ]; then
            rm -f "$INSTALL_DIR/$cmd"
            ((removed++))
        fi
    done

    if [ $removed -gt 0 ]; then
        log "SUCCESS" "Removed $removed command(s) from $INSTALL_DIR"
    else
        log "INFO" "No commands found in $INSTALL_DIR"
    fi
}

# Remove Ralph home directory
remove_ralph_home() {
    log "INFO" "Removing Ralph home directory..."

    if [ -d "$RALPH_HOME" ]; then
        rm -rf "$RALPH_HOME"
        log "SUCCESS" "Removed $RALPH_HOME"
    else
        log "INFO" "Ralph home directory not found"
    fi
}

# Main uninstallation
main() {
    echo "🗑️  Uninstalling Ralph for Claude Code..."

    check_installation
    show_removal_plan
    confirm_uninstall "$1"

    echo ""
    remove_commands
    remove_ralph_home

    echo ""
    log "SUCCESS" "Ralph for Claude Code has been uninstalled"
    echo ""
    echo "Note: Project files created with ralph-setup are not removed."
    echo "You can safely delete those project directories manually if needed."
    echo ""
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        echo "Ralph for Claude Code - Uninstallation Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -y, --yes    Skip confirmation prompt"
        echo "  -h, --help   Show this help message"
        echo ""
        echo "This script removes:"
        echo "  - Ralph commands from $INSTALL_DIR"
        echo "  - Ralph home directory ($RALPH_HOME)"
        echo ""
        echo "Project directories created with ralph-setup are NOT removed."
        ;;
    *)
        main "$1"
        ;;
esac
