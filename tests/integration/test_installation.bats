#!/usr/bin/env bats
# Integration tests for Ralph install.sh - Global Installation Script

load '../helpers/test_helper'
load '../helpers/mocks'
load '../helpers/fixtures'

# Store original values
ORIGINAL_HOME="$HOME"
ORIGINAL_PATH="$PATH"
PROJECT_ROOT=""

setup() {
    # Save project root for sourcing install.sh
    PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

    # Create unique temp directories for isolated testing
    export TEST_HOME="$(mktemp -d)"
    export TEST_INSTALL_DIR="$TEST_HOME/.local/bin"
    export TEST_RALPH_HOME="$TEST_HOME/.ralph"

    # Override HOME to isolate tests
    export HOME="$TEST_HOME"

    # Create mock source directories with required files
    export MOCK_SOURCE_DIR="$(mktemp -d)"
    mkdir -p "$MOCK_SOURCE_DIR/templates/specs"
    mkdir -p "$MOCK_SOURCE_DIR/lib"

    # Create mock template files
    echo "# Mock PROMPT.md" > "$MOCK_SOURCE_DIR/templates/PROMPT.md"
    echo "# Mock fix_plan.md" > "$MOCK_SOURCE_DIR/templates/fix_plan.md"
    echo "# Mock AGENT.md" > "$MOCK_SOURCE_DIR/templates/AGENT.md"

    # Create mock lib files
    cat > "$MOCK_SOURCE_DIR/lib/circuit_breaker.sh" << 'EOF'
#!/bin/bash
# Mock circuit_breaker.sh
init_circuit_breaker() { :; }
EOF

    cat > "$MOCK_SOURCE_DIR/lib/response_analyzer.sh" << 'EOF'
#!/bin/bash
# Mock response_analyzer.sh
analyze_response() { :; }
EOF

    cat > "$MOCK_SOURCE_DIR/lib/date_utils.sh" << 'EOF'
#!/bin/bash
# Mock date_utils.sh
get_iso_timestamp() { date -Iseconds; }
EOF

    # Create mock main scripts
    cat > "$MOCK_SOURCE_DIR/ralph_loop.sh" << 'EOF'
#!/bin/bash
# Mock ralph_loop.sh
echo "Ralph loop running"
EOF

    cat > "$MOCK_SOURCE_DIR/ralph_monitor.sh" << 'EOF'
#!/bin/bash
# Mock ralph_monitor.sh
echo "Ralph monitor running"
EOF

    cat > "$MOCK_SOURCE_DIR/ralph_import.sh" << 'EOF'
#!/bin/bash
# Mock ralph_import.sh
echo "Ralph import running"
EOF

    cat > "$MOCK_SOURCE_DIR/setup.sh" << 'EOF'
#!/bin/bash
# Mock setup.sh
echo "Setup running"
EOF

    cat > "$MOCK_SOURCE_DIR/migrate_to_ralph_folder.sh" << 'EOF'
#!/bin/bash
# Mock migrate_to_ralph_folder.sh
echo "Migration running"
EOF

    cat > "$MOCK_SOURCE_DIR/ralph_enable.sh" << 'EOF'
#!/bin/bash
# Mock ralph_enable.sh
echo "Ralph enable running"
EOF

    cat > "$MOCK_SOURCE_DIR/ralph_enable_ci.sh" << 'EOF'
#!/bin/bash
# Mock ralph_enable_ci.sh
echo "Ralph enable CI running"
EOF

    # Create mock lib files for new enable functionality
    cat > "$MOCK_SOURCE_DIR/lib/enable_core.sh" << 'EOF'
#!/bin/bash
# Mock enable_core.sh
check_existing_ralph() { :; }
EOF

    cat > "$MOCK_SOURCE_DIR/lib/wizard_utils.sh" << 'EOF'
#!/bin/bash
# Mock wizard_utils.sh
confirm() { :; }
EOF

    cat > "$MOCK_SOURCE_DIR/lib/task_sources.sh" << 'EOF'
#!/bin/bash
# Mock task_sources.sh
fetch_beads_tasks() { :; }
EOF

    cat > "$MOCK_SOURCE_DIR/lib/timeout_utils.sh" << 'EOF'
#!/bin/bash
# Mock timeout_utils.sh
portable_timeout() { timeout "$@"; }
EOF

    chmod +x "$MOCK_SOURCE_DIR"/*.sh
    chmod +x "$MOCK_SOURCE_DIR/lib"/*.sh
}

teardown() {
    # Restore original environment
    export HOME="$ORIGINAL_HOME"
    export PATH="$ORIGINAL_PATH"

    # Clean up test directories
    if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi

    if [[ -n "$MOCK_SOURCE_DIR" && -d "$MOCK_SOURCE_DIR" ]]; then
        rm -rf "$MOCK_SOURCE_DIR"
    fi
}

# Helper: Run install.sh in isolated environment
run_install() {
    local action="${1:-install}"

    # Set up environment for isolated install
    export SCRIPT_DIR="$MOCK_SOURCE_DIR"

    # Create a modified install.sh that uses our mock paths
    local temp_install="$(mktemp)"
    sed -e "s|INSTALL_DIR=\"\$HOME/.local/bin\"|INSTALL_DIR=\"$TEST_INSTALL_DIR\"|g" \
        -e "s|RALPH_HOME=\"\$HOME/.ralph\"|RALPH_HOME=\"$TEST_RALPH_HOME\"|g" \
        -e "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")\" && pwd)\"|SCRIPT_DIR=\"$MOCK_SOURCE_DIR\"|g" \
        "$PROJECT_ROOT/install.sh" > "$temp_install"

    chmod +x "$temp_install"

    # Run with specified action
    if [[ "$action" == "install" ]]; then
        bash "$temp_install" install 2>&1
    else
        bash "$temp_install" "$action" 2>&1
    fi
    local exit_code=$?

    rm -f "$temp_install"
    return $exit_code
}

# =============================================================================
# Test 1-2: Directory Creation Tests
# =============================================================================

@test "install.sh creates ~/.ralph directory" {
    run run_install

    # Check main ralph directory was created
    assert_dir_exists "$TEST_RALPH_HOME"

    # Check subdirectories
    assert_dir_exists "$TEST_RALPH_HOME/templates"
    assert_dir_exists "$TEST_RALPH_HOME/lib"
}

@test "install.sh creates ~/.local/bin directory" {
    run run_install

    # Check bin directory was created
    assert_dir_exists "$TEST_INSTALL_DIR"

    # Verify directory has correct permissions (should be accessible)
    [[ -x "$TEST_INSTALL_DIR" ]]
}

# =============================================================================
# Test 3-4: Command Installation Tests
# =============================================================================

@test "install.sh creates ~/.local/bin commands" {
    run run_install

    # Check all five wrapper commands exist
    assert_file_exists "$TEST_INSTALL_DIR/ralph"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-monitor"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-setup"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-import"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-migrate"

    # Verify each command contains proper shebang
    grep -q "#!/bin/bash" "$TEST_INSTALL_DIR/ralph"
    grep -q "#!/bin/bash" "$TEST_INSTALL_DIR/ralph-monitor"
    grep -q "#!/bin/bash" "$TEST_INSTALL_DIR/ralph-setup"
    grep -q "#!/bin/bash" "$TEST_INSTALL_DIR/ralph-import"
    grep -q "#!/bin/bash" "$TEST_INSTALL_DIR/ralph-migrate"
}

@test "install.sh sets executable permissions" {
    run run_install

    # Verify executable bit on all commands
    [[ -x "$TEST_INSTALL_DIR/ralph" ]]
    [[ -x "$TEST_INSTALL_DIR/ralph-monitor" ]]
    [[ -x "$TEST_INSTALL_DIR/ralph-setup" ]]
    [[ -x "$TEST_INSTALL_DIR/ralph-import" ]]
    [[ -x "$TEST_INSTALL_DIR/ralph-migrate" ]]

    # Verify executable bit on main scripts
    [[ -x "$TEST_RALPH_HOME/ralph_loop.sh" ]]
    [[ -x "$TEST_RALPH_HOME/ralph_monitor.sh" ]]
    [[ -x "$TEST_RALPH_HOME/setup.sh" ]]
    [[ -x "$TEST_RALPH_HOME/ralph_import.sh" ]]
    [[ -x "$TEST_RALPH_HOME/migrate_to_ralph_folder.sh" ]]

    # Verify lib scripts are executable
    [[ -x "$TEST_RALPH_HOME/lib/circuit_breaker.sh" ]]
    [[ -x "$TEST_RALPH_HOME/lib/response_analyzer.sh" ]]
    [[ -x "$TEST_RALPH_HOME/lib/date_utils.sh" ]]
}

# =============================================================================
# Test 5-6: Template and Library Copying Tests
# =============================================================================

@test "install.sh copies templates correctly" {
    run run_install

    # Check template files were copied
    assert_file_exists "$TEST_RALPH_HOME/templates/PROMPT.md"
    assert_file_exists "$TEST_RALPH_HOME/templates/fix_plan.md"
    assert_file_exists "$TEST_RALPH_HOME/templates/AGENT.md"

    # Verify content matches source
    diff -q "$MOCK_SOURCE_DIR/templates/PROMPT.md" "$TEST_RALPH_HOME/templates/PROMPT.md"
    diff -q "$MOCK_SOURCE_DIR/templates/fix_plan.md" "$TEST_RALPH_HOME/templates/fix_plan.md"
    diff -q "$MOCK_SOURCE_DIR/templates/AGENT.md" "$TEST_RALPH_HOME/templates/AGENT.md"
}

@test "install.sh copies lib/ directory" {
    run run_install

    # Check lib files were copied
    assert_file_exists "$TEST_RALPH_HOME/lib/circuit_breaker.sh"
    assert_file_exists "$TEST_RALPH_HOME/lib/response_analyzer.sh"
    assert_file_exists "$TEST_RALPH_HOME/lib/date_utils.sh"

    # Verify files are executable
    [[ -x "$TEST_RALPH_HOME/lib/circuit_breaker.sh" ]]
    [[ -x "$TEST_RALPH_HOME/lib/response_analyzer.sh" ]]
    [[ -x "$TEST_RALPH_HOME/lib/date_utils.sh" ]]
}

# =============================================================================
# Test 7-8: Dependency Detection Tests
# =============================================================================

@test "install.sh detects missing dependencies (jq, git, node)" {
    # Create a modified install.sh with mocked command -v
    local temp_script="$(mktemp)"

    cat > "$temp_script" << 'EOF'
#!/bin/bash
set -e

# Override command to simulate missing jq, git, and node/npx
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in
            jq|git|node|npx)
                return 1
                ;;
        esac
    fi
    builtin command "$@"
}

# Mock check_dependencies from install.sh
check_dependencies() {
    local missing_deps=()

    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi

    echo "SUCCESS: Dependencies check completed"
}

check_dependencies
EOF
    chmod +x "$temp_script"

    # Run and expect failure
    run bash "$temp_script"

    # Should fail
    [[ "$status" -ne 0 ]]

    # Should mention missing dependencies (all three)
    [[ "$output" =~ "Missing required dependencies" ]]
    [[ "$output" =~ "jq" ]]
    [[ "$output" =~ "git" ]]
    [[ "$output" =~ "Node.js" ]]

    rm -f "$temp_script"
}

@test "install.sh detects all dependencies present" {
    # Skip if actual dependencies are missing
    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        skip "Node.js not available"
    fi
    if ! command -v jq &> /dev/null; then
        skip "jq not available"
    fi
    if ! command -v git &> /dev/null; then
        skip "git not available"
    fi

    # Create a test script that checks dependencies
    local temp_script="$(mktemp)"

    cat > "$temp_script" << 'EOF'
#!/bin/bash

check_dependencies() {
    local missing_deps=()

    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi

    echo "Dependencies OK"
    exit 0
}

check_dependencies
EOF
    chmod +x "$temp_script"

    run bash "$temp_script"

    # Should succeed
    assert_success

    rm -f "$temp_script"
}

# =============================================================================
# Test 9-10: PATH Detection Tests
# =============================================================================

@test "install.sh PATH detection warns when not in PATH" {
    # Set PATH to exclude install directory
    export PATH="/usr/bin:/bin"

    # Extract and test check_path function
    local temp_script="$(mktemp)"

    cat > "$temp_script" << EOF
#!/bin/bash
INSTALL_DIR="$TEST_INSTALL_DIR"

check_path() {
    if [[ ":\$PATH:" != *":\$INSTALL_DIR:"* ]]; then
        echo "WARN: \$INSTALL_DIR is not in your PATH"
        echo "Add this to your ~/.bashrc:"
        echo "  export PATH=\"\\\$HOME/.local/bin:\\\$PATH\""
        return 0
    else
        echo "SUCCESS: \$INSTALL_DIR is already in PATH"
        return 0
    fi
}

check_path
EOF
    chmod +x "$temp_script"

    run bash "$temp_script"

    # Should warn about PATH
    [[ "$output" =~ "not in your PATH" ]] || [[ "$output" =~ "WARN" ]]

    rm -f "$temp_script"
}

@test "install.sh PATH detection succeeds when already in PATH" {
    # Set PATH to include install directory
    export PATH="$TEST_INSTALL_DIR:/usr/bin:/bin"

    # Extract and test check_path function
    local temp_script="$(mktemp)"

    cat > "$temp_script" << EOF
#!/bin/bash
INSTALL_DIR="$TEST_INSTALL_DIR"

check_path() {
    if [[ ":\$PATH:" != *":\$INSTALL_DIR:"* ]]; then
        echo "WARN: \$INSTALL_DIR is not in your PATH"
        return 0
    else
        echo "SUCCESS: \$INSTALL_DIR is already in PATH"
        return 0
    fi
}

check_path
EOF
    chmod +x "$temp_script"

    run bash "$temp_script"

    # Should succeed
    [[ "$output" =~ "SUCCESS" ]] || [[ "$output" =~ "already in PATH" ]]

    rm -f "$temp_script"
}

# =============================================================================
# Test 11-12: Uninstallation Tests
# =============================================================================

@test "install.sh uninstall removes all files" {
    # First run installation
    run run_install install
    assert_success

    # Verify files exist
    assert_file_exists "$TEST_INSTALL_DIR/ralph"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-monitor"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-setup"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-import"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-migrate"

    # Run uninstall
    run run_install uninstall
    assert_success

    # Verify command files are removed
    assert_file_not_exists "$TEST_INSTALL_DIR/ralph"
    assert_file_not_exists "$TEST_INSTALL_DIR/ralph-monitor"
    assert_file_not_exists "$TEST_INSTALL_DIR/ralph-setup"
    assert_file_not_exists "$TEST_INSTALL_DIR/ralph-import"
    assert_file_not_exists "$TEST_INSTALL_DIR/ralph-migrate"
}

@test "install.sh uninstall cleans up directories" {
    # First run installation
    run run_install install
    assert_success

    # Verify ralph home exists
    assert_dir_exists "$TEST_RALPH_HOME"

    # Run uninstall
    run run_install uninstall
    assert_success

    # Verify ralph home is removed
    [[ ! -d "$TEST_RALPH_HOME" ]]
}

# =============================================================================
# Test 13-14: Idempotency and Integration Tests
# =============================================================================

@test "installation idempotency (run twice without errors)" {
    # First installation
    run run_install install
    assert_success

    # Capture file counts after first install
    local ralph_count_1=$(ls "$TEST_INSTALL_DIR" | wc -l)
    local template_count_1=$(ls "$TEST_RALPH_HOME/templates" | wc -l)

    # Second installation (should overwrite cleanly)
    run run_install install
    assert_success

    # Capture file counts after second install
    local ralph_count_2=$(ls "$TEST_INSTALL_DIR" | wc -l)
    local template_count_2=$(ls "$TEST_RALPH_HOME/templates" | wc -l)

    # Counts should be the same (no duplicates or missing files)
    assert_equal "$ralph_count_1" "$ralph_count_2"
    assert_equal "$template_count_1" "$template_count_2"

    # All files should still exist and be valid
    assert_file_exists "$TEST_INSTALL_DIR/ralph"
    assert_file_exists "$TEST_RALPH_HOME/templates/PROMPT.md"
    assert_file_exists "$TEST_RALPH_HOME/lib/circuit_breaker.sh"
}

@test "complete installation workflow end-to-end" {
    # Skip if dependencies missing
    if ! command -v jq &> /dev/null; then
        skip "jq not available"
    fi
    if ! command -v git &> /dev/null; then
        skip "git not available"
    fi

    # Run full installation
    run run_install install
    assert_success

    # Verify all directories created
    assert_dir_exists "$TEST_INSTALL_DIR"
    assert_dir_exists "$TEST_RALPH_HOME"
    assert_dir_exists "$TEST_RALPH_HOME/templates"
    assert_dir_exists "$TEST_RALPH_HOME/lib"

    # Verify all commands installed
    assert_file_exists "$TEST_INSTALL_DIR/ralph"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-monitor"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-setup"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-import"
    assert_file_exists "$TEST_INSTALL_DIR/ralph-migrate"

    # Verify all templates copied
    assert_file_exists "$TEST_RALPH_HOME/templates/PROMPT.md"
    assert_file_exists "$TEST_RALPH_HOME/templates/fix_plan.md"
    assert_file_exists "$TEST_RALPH_HOME/templates/AGENT.md"

    # Verify all lib files copied
    assert_file_exists "$TEST_RALPH_HOME/lib/circuit_breaker.sh"
    assert_file_exists "$TEST_RALPH_HOME/lib/response_analyzer.sh"
    assert_file_exists "$TEST_RALPH_HOME/lib/date_utils.sh"

    # Verify all scripts in ralph home
    assert_file_exists "$TEST_RALPH_HOME/ralph_loop.sh"
    assert_file_exists "$TEST_RALPH_HOME/ralph_monitor.sh"
    assert_file_exists "$TEST_RALPH_HOME/setup.sh"
    assert_file_exists "$TEST_RALPH_HOME/ralph_import.sh"
    assert_file_exists "$TEST_RALPH_HOME/migrate_to_ralph_folder.sh"

    # Verify all permissions correct
    [[ -x "$TEST_INSTALL_DIR/ralph" ]]
    [[ -x "$TEST_RALPH_HOME/ralph_loop.sh" ]]
    [[ -x "$TEST_RALPH_HOME/lib/circuit_breaker.sh" ]]

    # Verify output contains success message
    [[ "$output" =~ "installed" ]] || [[ "$output" =~ "SUCCESS" ]] || [[ "$output" =~ "success" ]]
}
