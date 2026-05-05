#!/bin/bash

# Ralph for Claude Code - Global Installation Script
#
# Windows/WSL: If ./install.sh fails with "invalid option" or "$'\r': command not found",
# run: bash install.sh   (or normalize CRLF: sed -i 's/\r$//' install.sh in WSL)
set -e
# TAP-636: surface pipeline failures (sed | tr) so a failed sed doesn't silently
# install a zero-byte ralph_loop.sh.
set -o pipefail

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

# Ensure jq is on PATH: use system jq, ~/.local/bin/jq, or download official static binary (Linux/macOS).
# Set RALPH_SKIP_JQ_BOOTSTRAP=1 to disable download (fail if jq missing).
ensure_jq() {
    mkdir -p "$INSTALL_DIR"

    if command -v jq &>/dev/null; then
        return 0
    fi

    if [[ -x "$INSTALL_DIR/jq" ]]; then
        export PATH="$INSTALL_DIR:$PATH"
        log "INFO" "Using jq from $INSTALL_DIR/jq"
        return 0
    fi

    if [[ -n "${RALPH_SKIP_JQ_BOOTSTRAP:-}" ]]; then
        return 1
    fi

    local url=""
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "${os}:${arch}" in
        Linux:x86_64|Linux:amd64)
            url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
            ;;
        Linux:aarch64|Linux:arm64)
            url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64"
            ;;
        Darwin:x86_64|Darwin:amd64)
            url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"
            ;;
        Darwin:arm64|Darwin:aarch64)
            url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"
            ;;
        *)
            return 1
            ;;
    esac

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        return 1
    fi

    log "INFO" "jq not found — downloading static binary to $INSTALL_DIR/jq ..."
    local tmp="${TMPDIR:-/tmp}/ralph-jq-$$.bin"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
    else
        wget -qO "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    fi
    chmod +x "$tmp"
    if ! "$tmp" --version &>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$INSTALL_DIR/jq"
    export PATH="$INSTALL_DIR:$PATH"
    log "SUCCESS" "jq installed at $INSTALL_DIR/jq (add $INSTALL_DIR to PATH if needed)"
    return 0
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

    if ! ensure_jq; then
        if ! command -v jq &>/dev/null; then
            missing_deps+=("jq")
        fi
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
        echo ""
        echo "  On Linux/macOS, re-run install without RALPH_SKIP_JQ_BOOTSTRAP to auto-download jq to ~/.local/bin."
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

    # Check Claude Code CLI availability
    if command -v claude &>/dev/null; then
        log "INFO" "Claude Code CLI found: $(command -v claude)"
    else
        log "WARN" "Claude Code CLI ('claude') not found in PATH."
        log "INFO" "  Install globally: npm install -g @anthropic-ai/claude-code"
        log "INFO" "  Or use npx: set CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\" in .ralphrc"
    fi

    # Check tmux (optional)
    if ! command -v tmux &> /dev/null; then
        log "WARN" "tmux not found. Install for integrated monitoring: apt-get install tmux / brew install tmux"
    fi

    # Check Python 3.12+ (optional, for SDK mode)
    if command -v python3 &>/dev/null; then
        local py_version
        py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [[ -n "$py_version" ]]; then
            local py_major py_minor
            py_major=$(echo "$py_version" | cut -d. -f1)
            py_minor=$(echo "$py_version" | cut -d. -f2)
            if [[ "$py_major" -ge 3 ]] && [[ "$py_minor" -ge 12 ]]; then
                log "INFO" "Python $py_version found (SDK mode available)"
            else
                log "WARN" "Python $py_version found — SDK mode requires 3.12+ (CLI mode unaffected)"
            fi
        fi
    else
        log "WARN" "Python 3 not found — SDK mode unavailable (CLI mode unaffected)"
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
    
    # TAP-1419: stage templates into a parallel directory, then swap each
    # subdirectory into place via `rm -rf old + mv staged old`. Without the
    # stage+swap, a `ralph-upgrade-project` running concurrently with
    # `install.sh` could observe a half-populated `~/.ralph/templates/hooks/`
    # — exactly the race that produced the on-linear-tool.sh first-sync miss
    # against AgentForge. `cp -r` walks the tree file-by-file with no
    # cross-file atomicity, so the source of truth must be a directory the
    # upgrade tool only sees in its complete form.
    local stage_dir="$RALPH_HOME/templates.stage.$$.${RANDOM}"
    mkdir -p "$stage_dir"
    shopt -s dotglob
    cp -r "$SCRIPT_DIR/templates/"* "$stage_dir/"
    shopt -u dotglob

    # Per-subdir atomic swap. Top-level files (e.g. AGENTS.md) get mv'd
    # individually since there is no enclosing dir to swap.
    shopt -s dotglob nullglob
    local staged
    for staged in "$stage_dir"/*; do
        local name
        name="$(basename "$staged")"
        if [[ -d "$staged" ]]; then
            rm -rf "$RALPH_HOME/templates/$name" 2>/dev/null || true
            mv "$staged" "$RALPH_HOME/templates/$name"
        else
            mv -f "$staged" "$RALPH_HOME/templates/$name"
        fi
    done
    shopt -u dotglob nullglob
    rmdir "$stage_dir" 2>/dev/null || rm -rf "$stage_dir"

    # Copy lib scripts (strip CR for WSL/Windows CRLF source)
    for f in "$SCRIPT_DIR"/lib/*.sh; do
        [[ -f "$f" ]] && tr -d $'\r' < "$f" > "$RALPH_HOME/lib/$(basename "$f")"
    done

    # Copy agent definitions to templates/agents/ (for ralph-upgrade-project)
    if [[ -d "$SCRIPT_DIR/.claude/agents" ]]; then
        mkdir -p "$RALPH_HOME/templates/agents"
        for f in "$SCRIPT_DIR"/.claude/agents/ralph*.md; do
            [[ -f "$f" ]] && tr -d $'\r' < "$f" > "$RALPH_HOME/templates/agents/$(basename "$f")"
        done
        log "SUCCESS" "Agent definitions installed to $RALPH_HOME/templates/agents/"
    fi
    
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
# Migrates existing projects from flat structure to .ralph/ subfolde

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

    # Create ralph-upgrade-project command
    cat > "$INSTALL_DIR/ralph-upgrade-project" << 'EOF'
#!/bin/bash
# Ralph Upgrade Project - Propagate updated runtime files to existing projects

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_upgrade_project.sh" "$@"
EOF

    # Copy actual script files to Ralph home (strip CR for CRLF source)
    for script in ralph_monitor ralph_import migrate_to_ralph_folder ralph_enable ralph_enable_ci ralph_upgrade_project; do
        tr -d $'\r' < "$SCRIPT_DIR/${script}.sh" > "$RALPH_HOME/${script}.sh"
    done

    # Copy setup.sh (handled in install_setup)

    # Make all commands executable
    chmod +x "$INSTALL_DIR/ralph"
    chmod +x "$INSTALL_DIR/ralph-monitor"
    chmod +x "$INSTALL_DIR/ralph-setup"
    chmod +x "$INSTALL_DIR/ralph-import"
    chmod +x "$INSTALL_DIR/ralph-migrate"
    chmod +x "$INSTALL_DIR/ralph-enable"
    chmod +x "$INSTALL_DIR/ralph-enable-ci"
    chmod +x "$INSTALL_DIR/ralph-upgrade-project"
    chmod +x "$RALPH_HOME/ralph_monitor.sh"
    chmod +x "$RALPH_HOME/ralph_import.sh"
    chmod +x "$RALPH_HOME/migrate_to_ralph_folder.sh"
    chmod +x "$RALPH_HOME/ralph_enable.sh"
    chmod +x "$RALPH_HOME/ralph_enable_ci.sh"
    chmod +x "$RALPH_HOME/ralph_upgrade_project.sh"
    chmod +x "$RALPH_HOME/lib/"*.sh

    log "SUCCESS" "Ralph scripts installed to $INSTALL_DIR"
}

# Install global ralph_loop.sh
install_ralph_loop() {
    log "INFO" "Installing global ralph_loop.sh..."

    # TAP-636: previously this used sed | tr without pipefail and targeted
    # `$script_dir` (lowercase) — ralph_loop.sh uses `$SCRIPT_DIR`, so the
    # sed rules never matched and the whole pipeline was effectively just a
    # CRLF stripper. A failing sed would also slip past `set -e` because the
    # pipeline's exit came from `tr`. Replace with tmp + tr + `bash -n` syntax
    # check + atomic mv so silent zero-byte installs can't happen.
    local tmp="$RALPH_HOME/ralph_loop.sh.install.tmp.$$"
    tr -d $'\r' < "$SCRIPT_DIR/ralph_loop.sh" > "$tmp"
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log "ERROR" "Deployed ralph_loop.sh failed syntax check"
        return 1
    fi
    mv -f "$tmp" "$RALPH_HOME/ralph_loop.sh"
    chmod +x "$RALPH_HOME/ralph_loop.sh"

    log "SUCCESS" "Global ralph_loop.sh installed"
}

# BRAIN-PHASE-A: Ship ~/.ralph/secrets.env.example so users have a template
# for user-level secrets (TAPPS_BRAIN_AUTH_TOKEN, etc.). ralph_loop.sh sources
# ~/.ralph/secrets.env at startup — before arg parsing and the MCP probe — so
# non-interactive shells don't need to source ~/.bashrc.
#
# Never overwrites an existing live secrets.env; never auto-creates one.
install_secrets_example() {
    local example="$RALPH_HOME/secrets.env.example"
    cat > "$example" << 'EOF'
# Ralph user-level secrets. Loaded at startup by ralph_loop.sh before the MCP
# probe, so non-interactive shells (cron, systemd, tmux panes started before
# the user exported a var) don't need to source ~/.bashrc to pick these up.
#
# Setup:
#   cp ~/.ralph/secrets.env.example ~/.ralph/secrets.env
#   chmod 600 ~/.ralph/secrets.env
#   $EDITOR ~/.ralph/secrets.env
#
# Variables go through `set -a; source; set +a`, so exports propagate to the
# Claude CLI subprocess and its MCP handshakes.

# tapps-brain HTTP MCP bearer token. Must match the token the brain container
# was started with. Referenced from per-project .mcp.json as
# ${TAPPS_BRAIN_AUTH_TOKEN}.
#
# Where the value comes from:
#   1. Generated when the tapps-brain container is first launched. The brain
#      project's setup script writes the same value to its own .env (see
#      ~/code/tapps-brain/.env -> TAPPS_BRAIN_AUTH_TOKEN) and prints the
#      value to stdout.
#   2. Inspect the running container directly:
#        docker exec tapps-brain-http env | grep TAPPS_BRAIN_AUTH_TOKEN
#
# How to rotate (TAP-1105):
#   When the brain container is rebuilt with a fresh token, the value here
#   goes stale and Ralph's startup probe reports
#   `tapps-brain NOT reachable -- bearer token is likely missing or wrong`
#   even though `claude mcp list` shows the server connected (the Linear MCP
#   plugin's auth path differs and stays green; that's why the two disagree).
#
#   Fix:
#     1. docker exec tapps-brain-http env | grep TAPPS_BRAIN_AUTH_TOKEN
#     2. Paste the value below.
#     3. ralph --mcp-status   # confirm: tapps-brain: true
#
# TAPPS_BRAIN_AUTH_TOKEN=
EOF
    chmod 644 "$example"
    log "SUCCESS" "Secrets template installed: $example"
    if [[ ! -f "$RALPH_HOME/secrets.env" ]]; then
        log "INFO" "No ~/.ralph/secrets.env yet — copy the example above, chmod 600, fill in values"
    fi
}

# Install global setup.sh
install_setup() {
    log "INFO" "Installing global setup script..."

    # Copy the actual setup.sh from ralph-claude-code root directory (strip CR for CRLF source)
    if [[ -f "$SCRIPT_DIR/setup.sh" ]]; then
        tr -d $'\r' < "$SCRIPT_DIR/setup.sh" > "$RALPH_HOME/setup.sh"
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

# Install SDK (optional, requires Python 3.12+)
install_sdk() {
    local sdk_src="$SCRIPT_DIR/sdk"
    local sdk_dst="$RALPH_HOME/sdk"

    if [[ ! -d "$sdk_src" ]]; then
        log "INFO" "SDK source not found — skipping SDK installation"
        return 0
    fi

    log "INFO" "Installing Ralph SDK..."

    # Copy SDK source
    mkdir -p "$sdk_dst"
    cp -r "$sdk_src/ralph_sdk" "$sdk_dst/"
    cp "$sdk_src/pyproject.toml" "$sdk_dst/" 2>/dev/null || true

    # Create venv if Python 3.12+ is available
    if command -v python3 &>/dev/null; then
        local py_version
        py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        local py_major py_minor
        py_major=$(echo "$py_version" | cut -d. -f1)
        py_minor=$(echo "$py_version" | cut -d. -f2)

        if [[ "$py_major" -ge 3 ]] && [[ "$py_minor" -ge 12 ]]; then
            if [[ ! -d "$sdk_dst/.venv" ]]; then
                log "INFO" "Creating Python venv for SDK..."
                python3 -m venv "$sdk_dst/.venv" 2>/dev/null || {
                    log "WARN" "Failed to create venv — SDK mode may require manual setup"
                    return 0
                }
            fi
            log "SUCCESS" "SDK installed with Python venv"
        else
            log "INFO" "SDK source copied (Python $py_version — venv requires 3.12+)"
        fi
    else
        log "INFO" "SDK source copied (Python not available — CLI mode only)"
    fi

    # Create ralph-sdk command wrapper
    cat > "$INSTALL_DIR/ralph-sdk" << 'SDKEOF'
#!/bin/bash
# Ralph SDK - Python Agent SDK Mode
RALPH_HOME="$HOME/.ralph"
SDK_DIR="$RALPH_HOME/sdk"

if [[ -f "$SDK_DIR/.venv/bin/python" ]]; then
    PYTHONPATH="$SDK_DIR" exec "$SDK_DIR/.venv/bin/python" -m ralph_sdk "$@"
elif [[ -f "$SDK_DIR/.venv/Scripts/python.exe" ]]; then
    PYTHONPATH="$SDK_DIR" exec "$SDK_DIR/.venv/Scripts/python.exe" -m ralph_sdk "$@"
elif command -v python3 &>/dev/null; then
    PYTHONPATH="$SDK_DIR" exec python3 -m ralph_sdk "$@"
else
    echo "Error: Python 3.12+ required for SDK mode"
    echo "Install Python or use CLI mode: ralph (without --sdk)"
    exit 1
fi
SDKEOF
    chmod +x "$INSTALL_DIR/ralph-sdk"

    # Create ralph-doctor command
    cat > "$INSTALL_DIR/ralph-doctor" << 'DOCTOREOF'
#!/bin/bash
# Ralph Doctor - Verify all dependencies
# Match install layout: jq may live in ~/.local/bin without a login shell PATH
export PATH="${HOME}/.local/bin:${PATH}"
echo "Ralph Doctor — Dependency Check"
echo "================================"
echo ""

check() {
    local name=$1
    local cmd=$2
    local required=$3
    if eval "$cmd" &>/dev/null; then
        local version
        version=$(eval "$cmd" 2>/dev/null | head -1)
        echo "  [OK] $name: $version"
    elif [[ "$required" == "required" ]]; then
        echo "  [FAIL] $name: NOT FOUND (required)"
    else
        echo "  [SKIP] $name: not found (optional)"
    fi
}

echo "Core (required for CLI mode):"
check "Node.js" "node --version" "required"
check "jq" "jq --version" "required"
check "git" "git --version" "required"
check "Claude CLI" "claude --version" "required"
echo ""

echo "Optional (CLI enhancements):"
check "tmux" "tmux -V" "optional"
check "timeout" "timeout --version" "optional"
echo ""

echo "SDK mode (optional):"
check "Python 3" "python3 --version" "optional"
if [[ -d "$HOME/.ralph/sdk/.venv" ]]; then
    echo "  [OK] SDK venv: $HOME/.ralph/sdk/.venv"
else
    echo "  [SKIP] SDK venv: not created"
fi
echo ""

echo "Docker sandbox (optional):"
check "Docker" "docker --version" "optional"
echo ""

echo "GitHub integration (optional):"
check "gh CLI" "gh --version" "optional"
echo ""

# TAP-779: project files — PROMPT.md and fix_plan.md must exist before
# Ralph can loop. A missing PROMPT.md makes the loop blind (no task
# contract, no RALPH_STATUS requirement) and the exit gate never fires.
echo "Project files (current directory):"
if [[ -d ".ralph" ]]; then
    if [[ -f ".ralph/PROMPT.md" ]]; then
        if [[ -s ".ralph/PROMPT.md" ]]; then
            echo "  [OK] .ralph/PROMPT.md: present"
        else
            echo "  [FAIL] .ralph/PROMPT.md: empty — Ralph will loop blind"
        fi
    else
        echo "  [FAIL] .ralph/PROMPT.md: MISSING — Ralph cannot start"
    fi
    if [[ -f ".ralph/fix_plan.md" ]]; then
        echo "  [OK] .ralph/fix_plan.md: present"
    else
        echo "  [WARN] .ralph/fix_plan.md: missing (required for file-backed task source)"
    fi
elif [[ -f "PROMPT.md" ]]; then
    echo "  [FAIL] old flat structure detected (PROMPT.md at root, no .ralph/) — run ralph-migrate"
else
    echo "  [SKIP] not a Ralph project directory (.ralph/ not found in $(pwd))"
fi
echo ""

# TAP-538: hooks drift check — compare .ralph/hooks/*.sh against the
# installed templates/hooks/*.sh. Drift means a project is running a
# stale hook that may be missing security or sanity hardening.
echo "Hooks drift (vs ~/.ralph/templates/hooks):"
TPL_HOOKS_DIR="${HOME}/.ralph/templates/hooks"
RT_HOOKS_DIR=".ralph/hooks"
if [[ ! -d "$TPL_HOOKS_DIR" ]]; then
    echo "  [SKIP] template hooks dir not found at $TPL_HOOKS_DIR"
elif [[ ! -d "$RT_HOOKS_DIR" ]]; then
    echo "  [SKIP] no project-local .ralph/hooks/ in CWD ($(pwd))"
else
    drift_found=0
    for tpl in "$TPL_HOOKS_DIR"/*.sh; do
        [[ -e "$tpl" ]] || continue
        bn=$(basename "$tpl")
        rt="$RT_HOOKS_DIR/$bn"
        if [[ ! -f "$rt" ]]; then
            echo "  [WARN] missing in project: $bn (template has it)"
            drift_found=1
        elif ! diff -q "$rt" "$tpl" >/dev/null 2>&1; then
            echo "  [WARN] drift: $bn differs from template — re-run 'ralph-upgrade' to sync"
            drift_found=1
        fi
    done
    [[ $drift_found -eq 0 ]] && echo "  [OK] all hooks match templates"
fi
DOCTOREOF
    chmod +x "$INSTALL_DIR/ralph-doctor"

    return 0
}

# Get source version from ralph_loop.sh
get_source_version() {
    grep -m1 'RALPH_VERSION=' "$SCRIPT_DIR/ralph_loop.sh" 2>/dev/null | sed 's/.*RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/'
}

# Get currently installed version
get_installed_version() {
    if [[ -f "$RALPH_HOME/ralph_loop.sh" ]]; then
        grep -m1 'RALPH_VERSION=' "$RALPH_HOME/ralph_loop.sh" 2>/dev/null | sed 's/.*RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/'
    else
        echo ""
    fi
}

# Clean up files that no longer exist in the current version
cleanup_stale_files() {
    log "INFO" "Cleaning up stale files from previous versions..."

    local stale_count=0

    # Known removed files from previous versions
    local stale_files=(
        "$RALPH_HOME/lib/response_analyzer.sh"
        "$RALPH_HOME/lib/file_protection.sh"
    )

    for f in "${stale_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log "INFO" "  Removed stale file: $f"
            stale_count=$((stale_count + 1))
        fi
    done

    # Remove commands that no longer exist in the current version
    # (future-proofing: if a command is ever retired)
    local valid_commands=(ralph ralph-monitor ralph-setup ralph-import ralph-migrate ralph-enable ralph-enable-ci ralph-sdk ralph-doctor ralph-upgrade ralph-upgrade-project)
    for cmd_file in "$INSTALL_DIR"/ralph*; do
        [[ -f "$cmd_file" ]] || continue
        local cmd_name
        cmd_name=$(basename "$cmd_file")
        local found=false
        for valid in "${valid_commands[@]}"; do
            if [[ "$cmd_name" == "$valid" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            rm -f "$cmd_file"
            log "INFO" "  Removed stale command: $cmd_name"
            stale_count=$((stale_count + 1))
        fi
    done

    if [[ $stale_count -eq 0 ]]; then
        log "INFO" "  No stale files found"
    else
        log "SUCCESS" "Cleaned up $stale_count stale file(s)"
    fi
}

# Backup current installation before upgrade
backup_installation() {
    local backup_dir="$RALPH_HOME.backup"

    if [[ -d "$RALPH_HOME" ]]; then
        log "INFO" "Backing up current installation to $backup_dir..."
        rm -rf "$backup_dir"
        cp -r "$RALPH_HOME" "$backup_dir"
        log "SUCCESS" "Backup created at $backup_dir"
    fi
}

# Install ralph-upgrade global command
install_upgrade_command() {
    cat > "$INSTALL_DIR/ralph-upgrade" << 'UPGRADEEOF'
#!/bin/bash
# Ralph Upgrade - Self-update from source repository
# Usage: ralph-upgrade [--source /path/to/ralph-claude-code]

RALPH_HOME="$HOME/.ralph"
SOURCE_DIR=""

# Check for stored source directory
if [[ -f "$RALPH_HOME/.source_dir" ]]; then
    SOURCE_DIR=$(cat "$RALPH_HOME/.source_dir")
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Ralph Upgrade - Update Ralph to the latest version"
            echo ""
            echo "Usage: ralph-upgrade [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --source DIR  Path to ralph-claude-code repository"
            echo "  -h, --help    Show this help"
            echo ""
            echo "If --source is not provided, uses the stored source directory"
            echo "from the last install/upgrade."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ -z "$SOURCE_DIR" ]] || [[ ! -f "$SOURCE_DIR/install.sh" ]]; then
    echo "Error: Cannot find Ralph source repository."
    echo ""
    if [[ -n "$SOURCE_DIR" ]]; then
        echo "Checked: $SOURCE_DIR"
    fi
    echo ""
    echo "Usage: ralph-upgrade --source /path/to/ralph-claude-code"
    echo ""
    echo "Or clone the repo first:"
    echo "  git clone https://github.com/frankbria/ralph-claude-code.git"
    echo "  ralph-upgrade --source ./ralph-claude-code"
    exit 1
fi

# Pull latest if it's a git repo
if [[ -d "$SOURCE_DIR/.git" ]]; then
    echo "Pulling latest changes from git..."
    git -C "$SOURCE_DIR" pull --ff-only 2>/dev/null || {
        echo "Warning: git pull failed (you may have local changes). Proceeding with current source."
    }
fi

exec "$SOURCE_DIR/install.sh" upgrade
UPGRADEEOF
    chmod +x "$INSTALL_DIR/ralph-upgrade"
}

# Store source directory for future upgrades
store_source_dir() {
    echo "$SCRIPT_DIR" > "$RALPH_HOME/.source_dir"
}

# TAP-574: Sync global Claude skills from templates/skills/global/ into
# ~/.claude/skills/ with sidecar-based idempotency.
install_global_skills() {
    local skills_src="$SCRIPT_DIR/templates/skills/global"
    local skills_dst="$HOME/.claude/skills"
    local version
    version=$(get_source_version)
    [[ -z "$version" ]] && version="unknown"

    if [[ ! -d "$skills_src" ]]; then
        log "INFO" "No templates/skills/global/ in source — skipping skill sync"
        return 0
    fi

    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/skills_install.sh"

    log "INFO" "Syncing global Claude skills into $skills_dst ..."
    if skills_install_global "$skills_src" "$skills_dst" "$version"; then
        log "SUCCESS" "Global skills synced"
    else
        log "WARN" "Global skill sync reported an error — continuing"
    fi
}

# TAP-574: Remove Ralph-managed files from ~/.claude/skills/ during uninstall.
# Never touches user-authored skills or user-modified files.
remove_global_skills() {
    local skills_dir="$HOME/.claude/skills"
    [[ -d "$skills_dir" ]] || return 0

    if [[ ! -f "$SCRIPT_DIR/lib/skills_install.sh" ]]; then
        return 0
    fi

    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/skills_install.sh"

    log "INFO" "Removing Ralph-managed global skills (user-authored files preserved) ..."
    skills_uninstall_global "$skills_dir" || true
}

# Main installation
main() {
    echo "🚀 Installing Ralph for Claude Code globally..."
    echo ""

    check_dependencies
    create_install_dirs
    install_scripts
    install_ralph_loop
    install_secrets_example
    install_setup
    install_sdk
    install_upgrade_command
    store_source_dir
    install_global_skills
    check_path

    echo ""
    log "SUCCESS" "🎉 Ralph for Claude Code installed successfully!"
    echo ""
    echo "Global commands available:"
    echo "  ralph --monitor          # Start Ralph with integrated monitoring"
    echo "  ralph --live             # Stream Claude Code output (JSON/stream-json resilient)"
    echo "  ralph --help            # Show Ralph options (includes v0.11.6+ behavior notes)"
    echo "  ralph-setup my-project  # Create new Ralph project"
    echo "  ralph-enable            # Enable Ralph in existing project (interactive)"
    echo "  ralph-enable-ci         # Enable Ralph in existing project (non-interactive)"
    echo "  ralph-import prd.md     # Convert PRD to Ralph project"
    echo "  ralph-migrate           # Migrate existing project to .ralph/ structure"
    echo "  ralph-monitor           # Manual monitoring dashboard"
    echo "  ralph-upgrade           # Upgrade Ralph to latest version"
    echo ""
    echo "Quick start:"
    echo "  1. ralph-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .ralph/PROMPT.md with your requirements"
    echo "  4. ralph --monitor"
    echo ""
    echo "Docs: README.md, docs/user-guide/, docs/specs/ (design). TESTING.md for npm test."
    echo ""

    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "⚠️  Don't forget to add $INSTALL_DIR to your PATH (see above)"
    fi
}

# Upgrade existing installation
upgrade() {
    local current_version
    local new_version
    current_version=$(get_installed_version)
    new_version=$(get_source_version)

    if [[ -z "$current_version" ]]; then
        log "WARN" "No existing installation found. Running fresh install instead."
        main
        return
    fi

    echo "🔄 Upgrading Ralph for Claude Code..."
    echo ""
    log "INFO" "Current version: $current_version"
    log "INFO" "New version:     $new_version"
    echo ""

    if [[ "$current_version" == "$new_version" ]]; then
        log "INFO" "Already at version $new_version. Reinstalling to ensure all files are current."
    fi

    backup_installation

    check_dependencies
    create_install_dirs
    install_scripts
    install_ralph_loop
    install_secrets_example
    install_setup
    install_sdk
    install_upgrade_command
    store_source_dir
    install_global_skills
    cleanup_stale_files
    check_path

    echo ""
    if [[ "$current_version" == "$new_version" ]]; then
        log "SUCCESS" "🎉 Ralph $new_version reinstalled successfully!"
    else
        log "SUCCESS" "🎉 Ralph upgraded from $current_version to $new_version!"
    fi
    echo ""
    echo "Backup of previous installation: $RALPH_HOME.backup"
    echo "To rollback: rm -rf $RALPH_HOME && mv $RALPH_HOME.backup $RALPH_HOME"
    echo ""
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "INFO" "Uninstalling Ralph for Claude Code..."
        remove_global_skills
        rm -f "$INSTALL_DIR/ralph" "$INSTALL_DIR/ralph-monitor" "$INSTALL_DIR/ralph-setup" \
              "$INSTALL_DIR/ralph-import" "$INSTALL_DIR/ralph-migrate" "$INSTALL_DIR/ralph-enable" \
              "$INSTALL_DIR/ralph-enable-ci" "$INSTALL_DIR/ralph-sdk" "$INSTALL_DIR/ralph-doctor" \
              "$INSTALL_DIR/ralph-upgrade" "$INSTALL_DIR/ralph-upgrade-project"
        rm -rf "$RALPH_HOME"
        log "SUCCESS" "Ralph for Claude Code uninstalled"
        ;;
    upgrade)
        upgrade
        ;;
    --help|-h)
        echo "Ralph for Claude Code Installation"
        echo ""
        echo "Usage: $0 [install|upgrade|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph globally (default)"
        echo "  upgrade    Upgrade existing installation (backs up first)"
        echo "  uninstall  Remove Ralph installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac