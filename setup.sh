#!/bin/bash

# Ralph Project Setup Script
# Creates project structure with Ralph-specific files in .ralph/ subfolder
set -e

PROJECT_NAME=${1:-"my-project"}

echo "🚀 Setting up Ralph project: $PROJECT_NAME"

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Determine templates directory location (checked AFTER cd into project)
# Check local ../templates first, then global ~/.ralph/templates
TEMPLATES_DIR=""
if [[ -d "../templates" ]]; then
    TEMPLATES_DIR="../templates"
elif [[ -d "$HOME/.ralph/templates" ]]; then
    TEMPLATES_DIR="$HOME/.ralph/templates"
else
    echo "❌ Error: Templates directory not found."
    echo "   Expected at: ../templates or ~/.ralph/templates"
    echo "   Please run ./install.sh first to install Ralph globally."
    exit 1
fi

# Verify required template files exist
if [[ ! -f "$TEMPLATES_DIR/PROMPT.md" ]]; then
    echo "❌ Error: Required template file PROMPT.md not found in $TEMPLATES_DIR"
    exit 1
fi

# Create structure:
# - src/ stays at root for compatibility with existing tooling
# - All Ralph-specific files go in .ralph/ subfolder
mkdir -p src
mkdir -p .ralph/{specs/stdlib,examples,logs,docs/generated}

# Copy templates to .ralph/
cp "$TEMPLATES_DIR/PROMPT.md" .ralph/
cp "$TEMPLATES_DIR/fix_plan.md" .ralph/@fix_plan.md
cp "$TEMPLATES_DIR/AGENT.md" .ralph/@AGENT.md
cp -r "$TEMPLATES_DIR/specs"/* .ralph/specs/ 2>/dev/null || true

# Initialize git
git init
echo "# $PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph project setup"

echo "✅ Project $PROJECT_NAME created!"
echo "Next steps:"
echo "  1. Edit .ralph/PROMPT.md with your project requirements"
echo "  2. Update .ralph/specs/ with your project specifications"
echo "  3. Run: ../ralph_loop.sh"
echo "  4. Monitor: ../ralph_monitor.sh"
