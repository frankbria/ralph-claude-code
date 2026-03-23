#!/bin/bash

# Ralph for Devin CLI - Installation Script
# Installs Devin-specific Ralph commands alongside existing Claude Code installation.
# This is designed to be run AFTER the main install.sh (which installs Claude-based Ralph).
#
# Installs to:
#   - ~/.local/bin/ralph-devin*  (commands)
#   - ~/.ralph/devin/            (scripts and libraries)
#
# Version: 0.1.0

set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."

    local missing_deps=()

    if ! command -v jq &>/dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &>/dev/null; then
        missing_deps+=("git")
    fi

    # Check for Devin CLI (warn but don't block)
    if ! command -v devin &>/dev/null; then
        log "WARN" "Devin CLI ('devin') not found."
        echo ""
        echo "Install Devin CLI via one of:"
        echo "  brew tap revanthpobala/tap && brew install devin-cli"
        echo "  pipx install devin-cli"
        echo "  pip install devin-cli"
        echo ""
        echo "Then configure: devin configure"
        echo ""
        echo "Continuing installation anyway (you can install devin-cli later)..."
        echo ""
    else
        log "SUCCESS" "Devin CLI found"
    fi

    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Install:"
        echo "  macOS: brew install ${missing_deps[*]}"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        exit 1
    fi

    # Check if base Ralph is installed
    if [[ ! -d "$RALPH_HOME" ]]; then
        log "WARN" "Base Ralph installation not found at $RALPH_HOME"
        echo "It's recommended to run the main install.sh first for shared templates and libraries."
        echo "Creating minimal $RALPH_HOME structure..."
        mkdir -p "$RALPH_HOME/lib"
        mkdir -p "$RALPH_HOME/templates"
    fi

    log "SUCCESS" "Dependencies check completed"
}

# Create installation directories
create_install_dirs() {
    log "INFO" "Creating installation directories..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$RALPH_HOME/lib"
    mkdir -p "$RALPH_HOME/templates"
    mkdir -p "$DEVIN_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $RALPH_HOME/lib, $DEVIN_HOME"
}

# Install Devin-specific scripts
install_scripts() {
    log "INFO" "Installing Ralph Devin scripts..."

    # Copy Devin adapter libraries
    cp "$SCRIPT_DIR/lib/devin_adapter.sh" "$DEVIN_HOME/lib/"
    cp "$SCRIPT_DIR/lib/worktree_manager.sh" "$DEVIN_HOME/lib/"
    chmod +x "$DEVIN_HOME/lib/devin_adapter.sh"
    chmod +x "$DEVIN_HOME/lib/worktree_manager.sh"

    # Copy Devin-specific scripts
    cp "$SCRIPT_DIR/ralph_loop_devin.sh" "$DEVIN_HOME/"
    cp "$SCRIPT_DIR/ralph_monitor_devin.sh" "$DEVIN_HOME/"
    cp "$SCRIPT_DIR/ralph_import_devin.sh" "$DEVIN_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_devin.sh" "$DEVIN_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_ci_devin.sh" "$DEVIN_HOME/"
    cp "$SCRIPT_DIR/setup_devin.sh" "$DEVIN_HOME/"

    # Make all scripts executable
    chmod +x "$DEVIN_HOME/"*.sh
    chmod +x "$DEVIN_HOME/lib/"*.sh

    # Create the main ralph-devin command
    cat > "$INSTALL_DIR/ralph-devin" << 'EOF'
#!/bin/bash
# Ralph for Devin CLI - Main Command

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/ralph_loop_devin.sh" "$@"
EOF

    # Create ralph-devin-monitor command
    cat > "$INSTALL_DIR/ralph-devin-monitor" << 'EOF'
#!/bin/bash
# Ralph Devin Monitor - Global Command

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/ralph_monitor_devin.sh" "$@"
EOF

    # Create ralph-devin-setup command
    cat > "$INSTALL_DIR/ralph-devin-setup" << 'EOF'
#!/bin/bash
# Ralph Devin Project Setup - Global Command

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/setup_devin.sh" "$@"
EOF

    # Create ralph-devin-import command
    cat > "$INSTALL_DIR/ralph-devin-import" << 'EOF'
#!/bin/bash
# Ralph Devin PRD Import - Global Command

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/ralph_import_devin.sh" "$@"
EOF

    # Create ralph-devin-enable command
    cat > "$INSTALL_DIR/ralph-devin-enable" << 'EOF'
#!/bin/bash
# Ralph Devin Enable - Interactive Wizard

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/ralph_enable_devin.sh" "$@"
EOF

    # Create ralph-devin-enable-ci command
    cat > "$INSTALL_DIR/ralph-devin-enable-ci" << 'EOF'
#!/bin/bash
# Ralph Devin Enable CI - Non-Interactive Version

RALPH_HOME="$HOME/.ralph"
DEVIN_HOME="$RALPH_HOME/devin"

exec "$DEVIN_HOME/ralph_enable_ci_devin.sh" "$@"
EOF

    # Create ralph-devin-plan command (Planning Mode - uses devin engine)
    cat > "$INSTALL_DIR/ralph-devin-plan" << 'EOF'
#!/bin/bash
# Ralph Devin Planning Mode - PRD-driven fix_plan.md builder
# Uses shared ralph_plan.sh with --engine devin

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_plan.sh" --engine devin "$@"
EOF

    # Make all commands executable
    chmod +x "$INSTALL_DIR/ralph-devin"
    chmod +x "$INSTALL_DIR/ralph-devin-monitor"
    chmod +x "$INSTALL_DIR/ralph-devin-setup"
    chmod +x "$INSTALL_DIR/ralph-devin-import"
    chmod +x "$INSTALL_DIR/ralph-devin-enable"
    chmod +x "$INSTALL_DIR/ralph-devin-enable-ci"
    chmod +x "$INSTALL_DIR/ralph-devin-plan"

    log "SUCCESS" "Ralph Devin scripts installed to $INSTALL_DIR"
}

# Ensure shared libraries are available
install_shared_libs() {
    log "INFO" "Checking shared libraries..."

    # These are needed by the Devin loop (response_analyzer, circuit_breaker, etc.)
    local shared_libs=(
        "lib/date_utils.sh"
        "lib/timeout_utils.sh"
        "lib/response_analyzer.sh"
        "lib/circuit_breaker.sh"
        "lib/enable_core.sh"
        "lib/wizard_utils.sh"
        "lib/task_sources.sh"
        "lib/parallel_spawn.sh"
        "lib/pr_manager.sh"
    )

    for lib in "${shared_libs[@]}"; do
        if [[ -f "$RALPH_ROOT/$lib" ]]; then
            cp "$RALPH_ROOT/$lib" "$RALPH_HOME/$lib"
            chmod +x "$RALPH_HOME/$lib"
            log "INFO" "Updated shared library: $lib"
        else
            log "WARN" "Shared library not found: $lib (run main install.sh if needed)"
        fi
    done

    # Ensure templates exist
    if [[ -d "$RALPH_ROOT/templates" && ! -f "$RALPH_HOME/templates/PROMPT.md" ]]; then
        cp -r "$RALPH_ROOT/templates/"* "$RALPH_HOME/templates/" 2>/dev/null || true
        log "INFO" "Copied shared templates"
    fi

    log "SUCCESS" "Shared libraries verified"
}

# Check PATH
check_path() {
    log "INFO" "Checking PATH configuration..."

    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log "WARN" "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add this to your ~/.bashrc, ~/.zshrc, or ~/.profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        echo "Then run: source ~/.zshrc (or restart your terminal)"
        echo ""
    else
        log "SUCCESS" "$INSTALL_DIR is already in PATH"
    fi
}

# Main installation
main() {
    echo "🚀 Installing Ralph for Devin CLI..."
    echo ""

    check_dependencies
    create_install_dirs
    install_shared_libs
    install_scripts
    check_path

    echo ""
    log "SUCCESS" "Ralph for Devin CLI installed successfully!"
    echo ""
    echo "Devin-specific commands available:"
    echo "  ralph-devin --monitor         # Start Ralph loop with Devin + monitoring"
    echo "  ralph-devin --help            # Show Ralph Devin options"
    echo "  ralph-devin-setup my-project  # Create new Ralph+Devin project"
    echo "  ralph-devin-enable            # Enable Ralph+Devin in existing project"
    echo "  ralph-devin-enable-ci         # Non-interactive enable for CI/CD"
    echo "  ralph-devin-import prd.md     # Convert PRD to Ralph+Devin project"
    echo "  ralph-devin-plan              # Planning mode - build fix_plan from PRDs & beads"
    echo "  ralph-devin-monitor           # Manual monitoring dashboard"
    echo ""
    echo "Quick start:"
    echo "  1. ralph-devin-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .ralph/PROMPT.md with your requirements"
    echo "  4. ralph-devin --monitor"
    echo ""

    if ! command -v devin &>/dev/null; then
        echo "⚠️  Don't forget to install Devin CLI: pip install devin-cli"
        echo "   Then configure: devin configure"
        echo ""
    fi

    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "⚠️  Don't forget to add $INSTALL_DIR to your PATH (see above)"
    fi
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "INFO" "Uninstalling Ralph Devin..."
        rm -f "$INSTALL_DIR/ralph-devin"
        rm -f "$INSTALL_DIR/ralph-devin-monitor"
        rm -f "$INSTALL_DIR/ralph-devin-setup"
        rm -f "$INSTALL_DIR/ralph-devin-import"
        rm -f "$INSTALL_DIR/ralph-devin-enable"
        rm -f "$INSTALL_DIR/ralph-devin-enable-ci"
        rm -f "$INSTALL_DIR/ralph-devin-plan"
        rm -rf "$DEVIN_HOME"
        log "SUCCESS" "Ralph for Devin CLI uninstalled"
        ;;
    --help|-h)
        echo "Ralph for Devin CLI Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph Devin globally (default)"
        echo "  uninstall  Remove Ralph Devin installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
