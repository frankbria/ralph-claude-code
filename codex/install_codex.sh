#!/bin/bash

# Ralph for Codex CLI - Installation Script
# Installs Codex-specific Ralph commands alongside existing Claude Code installation.
# This is designed to be run AFTER the main install.sh (which installs Claude-based Ralph).
#
# Installs to:
#   - ~/.local/bin/ralph-codex*  (commands)
#   - ~/.ralph/codex/            (scripts and libraries)
#
# Version: 0.1.0

set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"
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

    # Check for Codex CLI (warn but don't block)
    if ! command -v codex &>/dev/null; then
        log "WARN" "Codex CLI ('codex') not found."
        echo ""
        echo "Install Codex CLI via one of:"
        echo "  brew tap revanthpobala/tap && brew install codex-cli"
        echo "  pipx install codex-cli"
        echo "  pip install codex-cli"
        echo ""
        echo "Then configure: codex configure"
        echo ""
        echo "Continuing installation anyway (you can install codex-cli later)..."
        echo ""
    else
        log "SUCCESS" "Codex CLI found"
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
    mkdir -p "$CODEX_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $RALPH_HOME/lib, $CODEX_HOME"
}

# Install Codex-specific scripts
install_scripts() {
    log "INFO" "Installing Ralph Codex scripts..."

    # Copy Codex adapter libraries
    cp "$SCRIPT_DIR/lib/codex_adapter.sh" "$CODEX_HOME/lib/"
    cp "$SCRIPT_DIR/lib/worktree_manager.sh" "$CODEX_HOME/lib/"
    chmod +x "$CODEX_HOME/lib/codex_adapter.sh"
    chmod +x "$CODEX_HOME/lib/worktree_manager.sh"

    # Copy Codex-specific scripts
    cp "$SCRIPT_DIR/ralph_loop_codex.sh" "$CODEX_HOME/"
    cp "$SCRIPT_DIR/ralph_monitor_codex.sh" "$CODEX_HOME/"
    cp "$SCRIPT_DIR/ralph_import_codex.sh" "$CODEX_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_codex.sh" "$CODEX_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_ci_codex.sh" "$CODEX_HOME/"
    cp "$SCRIPT_DIR/setup_codex.sh" "$CODEX_HOME/"

    # Make all scripts executable
    chmod +x "$CODEX_HOME/"*.sh
    chmod +x "$CODEX_HOME/lib/"*.sh

    # Create the main ralph-codex command
    cat > "$INSTALL_DIR/ralph-codex" << 'EOF'
#!/bin/bash
# Ralph for Codex CLI - Main Command

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/ralph_loop_codex.sh" "$@"
EOF

    # Create ralph-codex-monitor command
    cat > "$INSTALL_DIR/ralph-codex-monitor" << 'EOF'
#!/bin/bash
# Ralph Codex Monitor - Global Command

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/ralph_monitor_codex.sh" "$@"
EOF

    # Create ralph-codex-setup command
    cat > "$INSTALL_DIR/ralph-codex-setup" << 'EOF'
#!/bin/bash
# Ralph Codex Project Setup - Global Command

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/setup_codex.sh" "$@"
EOF

    # Create ralph-codex-import command
    cat > "$INSTALL_DIR/ralph-codex-import" << 'EOF'
#!/bin/bash
# Ralph Codex PRD Import - Global Command

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/ralph_import_codex.sh" "$@"
EOF

    # Create ralph-codex-enable command
    cat > "$INSTALL_DIR/ralph-codex-enable" << 'EOF'
#!/bin/bash
# Ralph Codex Enable - Interactive Wizard

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/ralph_enable_codex.sh" "$@"
EOF

    # Create ralph-codex-enable-ci command
    cat > "$INSTALL_DIR/ralph-codex-enable-ci" << 'EOF'
#!/bin/bash
# Ralph Codex Enable CI - Non-Interactive Version

RALPH_HOME="$HOME/.ralph"
CODEX_HOME="$RALPH_HOME/codex"

exec "$CODEX_HOME/ralph_enable_ci_codex.sh" "$@"
EOF

    # Create ralph-codex-plan command (Planning Mode - uses codex engine)
    cat > "$INSTALL_DIR/ralph-codex-plan" << 'EOF'
#!/bin/bash
# Ralph Codex Planning Mode - PRD-driven fix_plan.md builder
# Uses shared ralph_plan.sh with --engine codex

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_plan.sh" --engine codex "$@"
EOF

    # Make all commands executable
    chmod +x "$INSTALL_DIR/ralph-codex"
    chmod +x "$INSTALL_DIR/ralph-codex-monitor"
    chmod +x "$INSTALL_DIR/ralph-codex-setup"
    chmod +x "$INSTALL_DIR/ralph-codex-import"
    chmod +x "$INSTALL_DIR/ralph-codex-enable"
    chmod +x "$INSTALL_DIR/ralph-codex-enable-ci"
    chmod +x "$INSTALL_DIR/ralph-codex-plan"

    log "SUCCESS" "Ralph Codex scripts installed to $INSTALL_DIR"
}

# Ensure shared libraries are available
install_shared_libs() {
    log "INFO" "Checking shared libraries..."

    # These are needed by the Codex loop (response_analyzer, circuit_breaker, etc.)
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
    echo "🚀 Installing Ralph for Codex CLI..."
    echo ""

    check_dependencies
    create_install_dirs
    install_shared_libs
    install_scripts
    check_path

    echo ""
    log "SUCCESS" "Ralph for Codex CLI installed successfully!"
    echo ""
    echo "Codex-specific commands available:"
    echo "  ralph-codex --monitor         # Start Ralph loop with Codex + monitoring"
    echo "  ralph-codex --help            # Show Ralph Codex options"
    echo "  ralph-codex-setup my-project  # Create new Ralph+Codex project"
    echo "  ralph-codex-enable            # Enable Ralph+Codex in existing project"
    echo "  ralph-codex-enable-ci         # Non-interactive enable for CI/CD"
    echo "  ralph-codex-import prd.md     # Convert PRD to Ralph+Codex project"
    echo "  ralph-codex-plan              # Planning mode - build fix_plan from PRDs & beads"
    echo "  ralph-codex-monitor           # Manual monitoring dashboard"
    echo ""
    echo "Quick start:"
    echo "  1. ralph-codex-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .ralph/PROMPT.md with your requirements"
    echo "  4. ralph-codex --monitor"
    echo ""

    if ! command -v codex &>/dev/null; then
        echo "⚠️  Don't forget to install Codex CLI: pip install codex-cli"
        echo "   Then configure: codex configure"
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
        log "INFO" "Uninstalling Ralph Codex..."
        rm -f "$INSTALL_DIR/ralph-codex"
        rm -f "$INSTALL_DIR/ralph-codex-monitor"
        rm -f "$INSTALL_DIR/ralph-codex-setup"
        rm -f "$INSTALL_DIR/ralph-codex-import"
        rm -f "$INSTALL_DIR/ralph-codex-enable"
        rm -f "$INSTALL_DIR/ralph-codex-enable-ci"
        rm -f "$INSTALL_DIR/ralph-codex-plan"
        rm -rf "$CODEX_HOME"
        log "SUCCESS" "Ralph for Codex CLI uninstalled"
        ;;
    --help|-h)
        echo "Ralph for Codex CLI Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph Codex globally (default)"
        echo "  uninstall  Remove Ralph Codex installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
