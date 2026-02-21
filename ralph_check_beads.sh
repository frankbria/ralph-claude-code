#!/bin/bash

# Ralph Check Beads - Verify beads sync functionality
# Usage: ralph-check-beads
#
# This command checks if beads integration is properly configured
# in your Ralph project and diagnoses any issues.

set -e

echo "=== Ralph Beads Sync Diagnostic ==="
echo ""
echo "Project: $(pwd)"
echo ""

# Source the task_sources library
# Try global installation first, then local
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
if [[ -f "$RALPH_HOME/lib/task_sources.sh" ]]; then
    source "$RALPH_HOME/lib/task_sources.sh"
elif [[ -f "lib/task_sources.sh" ]]; then
    source "lib/task_sources.sh"
else
    echo "❌ Error: Cannot find task_sources.sh library"
    echo "   Please run './install.sh' to install Ralph globally"
    exit 1
fi

echo "1. Checking for .beads directory..."
if [[ -d ".beads" ]]; then
    echo "   ✅ .beads directory exists"
else
    echo "   ❌ .beads directory NOT found"
    echo "   → Run 'bd init' to initialize beads in this project"
fi

echo ""
echo "2. Checking for bd CLI..."
if command -v bd &>/dev/null; then
    echo "   ✅ bd CLI is installed"
    bd --version 2>/dev/null || echo "   (version info unavailable)"
else
    echo "   ❌ bd CLI NOT found in PATH"
    echo "   → Install beads: npm install -g @beadorg/cli"
fi

echo ""
echo "3. Testing beads_sync_available()..."
if beads_sync_available; then
    echo "   ✅ Beads sync is available"
else
    echo "   ❌ Beads sync is NOT available"
    echo "   → Ensure both .beads/ exists and bd CLI is installed"
    exit 1
fi

echo ""
echo "4. Checking for open beads..."
if command -v bd &>/dev/null; then
    open_count=$(bd list --json --status open 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    echo "   Found $open_count open bead(s)"
    
    if [[ "$open_count" -gt 0 ]]; then
        echo ""
        echo "   Open beads:"
        bd list --json --status open 2>/dev/null | jq -r '.[] | "   - [\(.id)] \(.title)"' 2>/dev/null || echo "   (unable to parse)"
    fi
fi

echo ""
echo "5. Testing beads_pre_sync()..."
if [[ -f ".ralph/fix_plan.md" ]]; then
    echo "   Current fix_plan.md:"
    grep -E '^\s*- \[' .ralph/fix_plan.md 2>/dev/null | head -5 || echo "   (no tasks found)"
    
    echo ""
    echo "   Running beads_pre_sync..."
    if beads_pre_sync ".ralph/fix_plan.md"; then
        echo "   ✅ beads_pre_sync completed"
        echo ""
        echo "   Updated fix_plan.md:"
        grep -E '^\s*- \[' .ralph/fix_plan.md 2>/dev/null | head -10 || echo "   (no tasks found)"
    else
        echo "   ❌ beads_pre_sync failed"
    fi
else
    echo "   ⚠️  .ralph/fix_plan.md not found"
    echo "   → Run 'ralph-enable' to set up Ralph in this project"
fi

echo ""
echo "=== Diagnostic Complete ==="
