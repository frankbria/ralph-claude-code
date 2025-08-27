#!/bin/bash

# Ralph Project Setup Script
set -e

PROJECT_NAME=${1:-"my-project"}

echo "🚀 Setting up Ralph project: $PROJECT_NAME"

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create structure
mkdir -p {specs/stdlib,src,examples,logs,docs/generated}

# Copy templates
cp ../templates/PROMPT.md .
cp ../templates/fix_plan.md @fix_plan.md
cp ../templates/AGENT.md @AGENT.md
cp -r ../templates/specs/* specs/ 2>/dev/null || true

# Initialize git
git init
echo "# $PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph project setup"

echo "✅ Project $PROJECT_NAME created!"
echo "Next steps:"
echo "  1. Edit PROMPT.md with your project requirements"
echo "  2. Update specs/ with your project specifications"  
echo "  3. Run: ../ralph_loop.sh"
echo "  4. Monitor: ../ralph_monitor.sh"
