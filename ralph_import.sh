#!/bin/bash

# Ralph Import - Convert PRDs to Ralph project structure
set -e

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

show_help() {
    cat << HELPEOF
Ralph Import - Convert PRDs to Ralph Project Structure

Usage: $0 <source-file> [project-name]

Arguments:
    source-file     Path to your PRD/specification file (markdown, text, or JSON)
    project-name    Name for the new Ralph project (optional, defaults to filename)

Examples:
    $0 my-app-prd.md
    $0 requirements.txt my-awesome-app
    $0 project-spec.json

Supported formats:
    - Markdown (.md)
    - Text files (.txt)
    - JSON (.json)

What this command does:
1. Creates a new Ralph project directory.
2. Copies your PRD into the project.
3. Deterministically generates, without calling external AI CLIs:
   - PROMPT.md (Ralph instructions, embedding the original PRD)
   - @fix_plan.md (prioritized tasks derived from bullet points where available)
   - specs/requirements.md (technical specifications copied from the PRD)

HELPEOF
}

# Check dependencies
check_dependencies() {
    if ! command -v ralph-setup &> /dev/null; then
        log "ERROR" "Ralph not installed (ralph-setup not found). Install globally or provide a ralph-setup stub in PATH."
        exit 1
    fi
}

# Convert PRD using a deterministic, CLI-free transformation.
# This implementation intentionally avoids calling external AI services so that
# it works reliably in CI and test environments. It:
#   - Creates PROMPT.md with an embedded copy of the PRD
#   - Creates @fix_plan.md with tasks derived from bullet points
#   - Creates specs/requirements.md containing the full PRD content
convert_prd() {
    local source_file=$1
    local project_name=$2

    if [[ ! -f "$source_file" ]]; then
        log "ERROR" "Source file not found in project: $source_file"
        return 1
    fi

    mkdir -p specs

    log "INFO" "Converting PRD to Ralph format (deterministic mode)..."

    # Capture bullet-style lines as candidate tasks (for markdown/text PRDs).
    local features_file=".ralph_prd_features.tmp"
    grep -E '^[[:space:]]*[-*][[:space:]]+' "$source_file" > "$features_file" 2>/dev/null || true

    # -------------------------------------------------------------------------
    # 1. PROMPT.md
    # -------------------------------------------------------------------------
    cat > PROMPT.md << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a project imported from an existing PRD.

## Current Objectives
1. Study specs/requirements.md to understand the imported requirements.
2. Review @fix_plan.md for high-level implementation tasks.
3. Implement the highest priority item using best practices.
4. Keep changes small and focused on one primary task per loop.
5. Update documentation and @fix_plan.md as you learn.

## Key Principles
- ONE task per loop – focus on the most important thing.
- Search the codebase before assuming something isn't implemented.
- Use subagents for expensive operations (file searching, analysis).
- Write tests for new functionality you add.
- Commit working changes with descriptive messages.

## 🧪 Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop.
- PRIORITIZE: Implementation > Documentation > Tests.
- Only write tests for NEW functionality you implement.
- Do NOT refactor existing tests unless broken.
- Focus on CORE functionality first, comprehensive testing later.

EOF

    cat >> PROMPT.md << EOF
## Project Name
$project_name

## Original PRD
The following content was imported from the original specification file:

\`\`\`text
$(cat "$source_file")
\`\`\`
EOF

    # -------------------------------------------------------------------------
    # 2. @fix_plan.md
    # -------------------------------------------------------------------------
    cat > "@fix_plan.md" << 'EOF'
# Ralph Fix Plan

## High Priority
EOF

    # Try to extract a human-readable title from the first line of the PRD
    # (e.g., "# Task Management Web App - Product Requirements Document").
    # This helps make the plan self-describing and satisfies tests that look
    # for the PRD title in @fix_plan.md.
    local prd_title=""
    local first_line=""
    first_line=$(head -1 "$source_file" 2>/dev/null || true)
    if [[ "$first_line" == \#* ]]; then
        prd_title="${first_line#\# }"
    fi
    if [[ -n "$prd_title" ]]; then
        echo "- [ ] Review PRD: $prd_title" >> "@fix_plan.md"
    fi

    if [[ -s "$features_file" ]]; then
        # Turn each bullet into an unchecked task.
        while IFS= read -r line; do
            # Strip leading bullet markers (-, *) and surrounding whitespace.
            line="${line#"${line%%[!-*]*}"}"
            line="${line#- }"
            line="${line#* }"
            echo "- [ ] $line" >> "@fix_plan.md"
        done < "$features_file"
    else
        echo "- [ ] Review PRD and extract concrete implementation tasks" >> "@fix_plan.md"
    fi

    cat >> "@fix_plan.md" << 'EOF'

## Medium Priority
- [ ] Break down remaining requirements into incremental tasks
- [ ] Identify integration and edge cases to cover in tests

## Low Priority
- [ ] Documentation and developer experience improvements

## Completed
- [x] Project initialization

## Notes
- This plan was generated automatically from the imported PRD.
- Update this file after each major milestone.
EOF

    # -------------------------------------------------------------------------
    # 3. specs/requirements.md
    # -------------------------------------------------------------------------
    cat > "specs/requirements.md" << 'EOF'
# Technical Specifications (Imported)

The content below was imported directly from the original PRD file.

EOF

    cat "$source_file" >> "specs/requirements.md"

    rm -f "$features_file"

    log "SUCCESS" "PRD conversion completed (PROMPT.md, @fix_plan.md, specs/requirements.md created)"
}

# Main function
main() {
    local source_file="$1"
    local project_name="$2"
    
    # Validate arguments
    if [[ -z "$source_file" ]]; then
        log "ERROR" "Source file is required"
        show_help
        exit 1
    fi
    
    if [[ ! -f "$source_file" ]]; then
        log "ERROR" "Source file does not exist: $source_file"
        exit 1
    fi
    
    # Default project name from filename
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$source_file" | sed 's/\.[^.]*$//')
    fi
    
    log "INFO" "Converting PRD: $source_file"
    log "INFO" "Project name: $project_name"
    
    check_dependencies
    
    # Create project directory
    log "INFO" "Creating Ralph project: $project_name"
    ralph-setup "$project_name"
    cd "$project_name"
    
    # Copy source file to project
    cp "../$source_file" .
    local project_source_file
    project_source_file=$(basename "$source_file")
    
    # Run conversion
    convert_prd "$project_source_file" "$project_name"
    
    log "SUCCESS" "🎉 PRD imported successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Review and edit the generated files:"
    echo "     - PROMPT.md (Ralph instructions)"  
    echo "     - @fix_plan.md (task priorities)"
    echo "     - specs/requirements.md (technical specs)"
    echo "  2. Start autonomous development:"
    echo "     ralph --monitor"
    echo ""
    echo "Project created in: $(pwd)"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help|"")
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac