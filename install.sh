#!/bin/bash

# Ralph for Claude Code - Global Installation Script
set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    local os_type
    os_type=$(uname)

    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    # Check for timeout command (platform-specific)
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS: check for gtimeout from coreutils
        if ! command -v gtimeout &> /dev/null && ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils (for timeout command)")
        fi
    else
        # Linux: check for standard timeout command
        if ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils")
        fi
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies:"
        echo "  Ubuntu/Debian: sudo apt-get install nodejs npm jq git coreutils"
        echo "  macOS: brew install node jq git coreutils"
        echo "  CentOS/RHEL: sudo yum install nodejs npm jq git coreutils"
        exit 1
    fi

    # Additional macOS-specific warning for coreutils
    if [[ "$os_type" == "Darwin" ]]; then
        if command -v gtimeout &> /dev/null; then
            log "INFO" "GNU coreutils detected (gtimeout available)"
        elif command -v timeout &> /dev/null; then
            log "INFO" "timeout command available"
        fi
    fi

    # Claude Code CLI will be downloaded automatically when first used
    log "INFO" "Claude Code CLI (@anthropic-ai/claude-code) will be downloaded when first used."

    # Check tmux (optional)
    if ! command -v tmux &> /dev/null; then
        log "WARN" "tmux not found. Install for integrated monitoring: apt-get install tmux / brew install tmux"
    fi

    log "SUCCESS" "Dependencies check completed"
}

# Create installation directory
create_install_dirs() {
    log "INFO" "Creating installation directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$RALPH_HOME"
    mkdir -p "$RALPH_HOME/templates"
    mkdir -p "$RALPH_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $RALPH_HOME"
}

# Install Ralph scripts
install_scripts() {
    log "INFO" "Installing Ralph scripts..."
    
    # Copy templates to Ralph home (dotglob needed for dotfiles like .gitignore)
    shopt -s dotglob
    cp -r "$SCRIPT_DIR/templates/"* "$RALPH_HOME/templates/"
    shopt -u dotglob

    # Copy lib scripts (response_analyzer.sh, circuit_breaker.sh)
    cp -r "$SCRIPT_DIR/lib/"* "$RALPH_HOME/lib/"
    
    # Create the main ralph command
    cat > "$INSTALL_DIR/ralph" << 'EOF'
#!/bin/bash
# Ralph for Claude Code - Main Command

RALPH_HOME="$HOME/.ralph"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the actual ralph loop script with global paths
exec "$RALPH_HOME/ralph_loop.sh" "$@"
EOF

    # Create ralph-monitor command
    cat > "$INSTALL_DIR/ralph-monitor" << 'EOF'
#!/bin/bash
# Ralph Monitor - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_monitor.sh" "$@"
EOF

    # Create ralph-setup command
    cat > "$INSTALL_DIR/ralph-setup" << 'EOF'
#!/bin/bash
# Ralph Project Setup - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/setup.sh" "$@"
EOF

    # Create ralph-import command
    cat > "$INSTALL_DIR/ralph-import" << 'EOF'
#!/bin/bash
# Ralph PRD Import - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_import.sh" "$@"
EOF

    # Create ralph-migrate command
    cat > "$INSTALL_DIR/ralph-migrate" << 'EOF'
#!/bin/bash
# Ralph Migration - Global Command
# Migrates existing projects from flat structure to .ralph/ subfolder

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/migrate_to_ralph_folder.sh" "$@"
EOF

    # Create ralph-enable command (interactive wizard)
    cat > "$INSTALL_DIR/ralph-enable" << 'EOF'
#!/bin/bash
# Ralph Enable - Interactive Wizard for Existing Projects
# Adds Ralph configuration to an existing codebase

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_enable.sh" "$@"
EOF

    # Create ralph-enable-ci command (non-interactive)
    cat > "$INSTALL_DIR/ralph-enable-ci" << 'EOF'
#!/bin/bash
# Ralph Enable CI - Non-Interactive Version for Automation
# Adds Ralph configuration with sensible defaults

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_enable_ci.sh" "$@"
EOF

    # Copy actual script files to Ralph home with modifications for global operation
    cp "$SCRIPT_DIR/ralph_monitor.sh" "$RALPH_HOME/"

    # Copy PRD import script to Ralph home
    cp "$SCRIPT_DIR/ralph_import.sh" "$RALPH_HOME/"

    # Copy migration script to Ralph home
    cp "$SCRIPT_DIR/migrate_to_ralph_folder.sh" "$RALPH_HOME/"

    # Copy enable scripts to Ralph home
    cp "$SCRIPT_DIR/ralph_enable.sh" "$RALPH_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_ci.sh" "$RALPH_HOME/"

    # Make all commands executable
    chmod +x "$INSTALL_DIR/ralph"
    chmod +x "$INSTALL_DIR/ralph-monitor"
    chmod +x "$INSTALL_DIR/ralph-setup"
    chmod +x "$INSTALL_DIR/ralph-import"
    chmod +x "$INSTALL_DIR/ralph-migrate"
    chmod +x "$INSTALL_DIR/ralph-enable"
    chmod +x "$INSTALL_DIR/ralph-enable-ci"
    chmod +x "$RALPH_HOME/ralph_monitor.sh"
    chmod +x "$RALPH_HOME/ralph_import.sh"
    chmod +x "$RALPH_HOME/migrate_to_ralph_folder.sh"
    chmod +x "$RALPH_HOME/ralph_enable.sh"
    chmod +x "$RALPH_HOME/ralph_enable_ci.sh"
    chmod +x "$RALPH_HOME/lib/"*.sh

    log "SUCCESS" "Ralph scripts installed to $INSTALL_DIR"
}

# Install global ralph_loop.sh
install_ralph_loop() {
    log "INFO" "Installing global ralph_loop.sh..."
    
    # Create modified ralph_loop.sh for global operation
    sed \
        -e "s|RALPH_HOME=\"\$HOME/.ralph\"|RALPH_HOME=\"\$HOME/.ralph\"|g" \
        -e "s|\$script_dir/ralph_monitor.sh|\$RALPH_HOME/ralph_monitor.sh|g" \
        -e "s|\$script_dir/ralph_loop.sh|\$RALPH_HOME/ralph_loop.sh|g" \
        "$SCRIPT_DIR/ralph_loop.sh" > "$RALPH_HOME/ralph_loop.sh"
    
    chmod +x "$RALPH_HOME/ralph_loop.sh"
    
    log "SUCCESS" "Global ralph_loop.sh installed"
}

# Install global setup.sh
install_setup() {
    log "INFO" "Installing global setup script..."

    # Copy the actual setup.sh from ralph-claude-code root directory so setup information will be consistent
    if [[ -f "$SCRIPT_DIR/setup.sh" ]]; then
        cp "$SCRIPT_DIR/setup.sh" "$RALPH_HOME/setup.sh"
        chmod +x "$RALPH_HOME/setup.sh"
        log "SUCCESS" "Global setup script installed (copied from $SCRIPT_DIR/setup.sh)"
    else
        log "ERROR" "setup.sh not found in $SCRIPT_DIR"
        return 1
    fi
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
        echo "Then run: source ~/.bashrc (or restart your terminal)"
        echo ""
    else
        log "SUCCESS" "$INSTALL_DIR is already in PATH"
    fi
}

# Main installation
main() {
    echo "🚀 Installing Ralph for Claude Code globally..."
    echo ""
    
    check_dependencies
    create_install_dirs
    install_scripts
    install_ralph_loop
    install_setup
    check_path
    
    echo ""
    log "SUCCESS" "🎉 Ralph for Claude Code installed successfully!"
    echo ""
    echo "Global commands available:"
    echo "  ralph --monitor          # Start Ralph with integrated monitoring"
    echo "  ralph --help            # Show Ralph options"
    echo "  ralph-setup my-project  # Create new Ralph project"
    echo "  ralph-enable            # Enable Ralph in existing project (interactive)"
    echo "  ralph-enable-ci         # Enable Ralph in existing project (non-interactive)"
    echo "  ralph-import prd.md     # Convert PRD to Ralph project"
    echo "  ralph-migrate           # Migrate existing project to .ralph/ structure"
    echo "  ralph-monitor           # Manual monitoring dashboard"
    echo ""
    echo "Quick start:"
    echo "  1. ralph-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .ralph/PROMPT.md with your requirements"
    echo "  4. ralph --monitor"
    echo ""
    
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
        log "INFO" "Uninstalling Ralph for Claude Code..."
        rm -f "$INSTALL_DIR/ralph" "$INSTALL_DIR/ralph-monitor" "$INSTALL_DIR/ralph-setup" "$INSTALL_DIR/ralph-import" "$INSTALL_DIR/ralph-migrate" "$INSTALL_DIR/ralph-enable" "$INSTALL_DIR/ralph-enable-ci"
        rm -rf "$RALPH_HOME"
        log "SUCCESS" "Ralph for Claude Code uninstalled"
        ;;
    --help|-h)
        echo "Ralph for Claude Code Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph globally (default)"
        echo "  uninstall  Remove Ralph installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac