#!/bin/bash

# Ralph Import - Convert PRDs to Ralph format using Claude Code
set -e

# Configuration
CLAUDE_CODE_CMD="claude"

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
	"INFO") color=$BLUE ;;
	"WARN") color=$YELLOW ;;
	"ERROR") color=$RED ;;
	"SUCCESS") color=$GREEN ;;
	esac

	echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

show_help() {
	cat <<HELPEOF
Ralph Import - Convert PRDs to Ralph Format

Usage: $0 <source-file> [project-name]

Arguments:
    source-file     Path to your PRD/specification file (any format)
    project-name    Name for the new Ralph project (optional, defaults to filename)

Examples:
    $0 my-app-prd.md
    $0 requirements.txt my-awesome-app
    $0 project-spec.json
    $0 design-doc.docx webapp

Supported formats:
    - Markdown (.md)
    - Text files (.txt)
    - JSON (.json)
    - Word documents (.docx)
    - PDFs (.pdf)
    - Any text-based format

The command will:
1. Create a new Ralph project
2. Use Claude Code to intelligently convert your PRD into:
   - PROMPT.md (Ralph instructions)
   - @fix_plan.md (prioritized tasks)
   - specs/ (technical specifications)

HELPEOF
}

# Check dependencies
check_dependencies() {
	if ! command -v ralph-setup &>/dev/null; then
		log "ERROR" "Ralph not installed. Run ./install.sh first"
		exit 1
	fi

	if ! bunx @anthropic/claude-code --version &>/dev/null 2>&1; then
		log "WARN" "Claude Code CLI not found. It will be downloaded when first used."
	fi
}

# Convert PRD using Claude Code
convert_prd() {
	local source_file=$1
	local project_name=$2

	log "INFO" "Converting PRD to Ralph format using Claude Code..."

	# Create conversion prompt
	cat >.ralph_conversion_prompt.md <<'PROMPTEOF'
# PRD to Ralph Conversion Task

You are tasked with converting a Product Requirements Document (PRD) or specification into Ralph for Claude Code format.

## Input Analysis
Analyze the provided specification file and extract:
- Project goals and objectives
- Core features and requirements  
- Technical constraints and preferences
- Priority levels and phases
- Success criteria

## Required Outputs

Create these files in the current directory:

### 1. PROMPT.md
Transform the PRD into Ralph development instructions:
```markdown
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a [PROJECT NAME] project.

## Current Objectives
[Extract and prioritize 4-6 main objectives from the PRD]

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update @fix_plan.md with your learnings
- Commit working changes with descriptive messages

## 🧪 Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop
- PRIORITIZE: Implementation > Documentation > Tests
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Focus on CORE functionality first, comprehensive testing later

## Project Requirements
[Convert PRD requirements into clear, actionable development requirements]

## Technical Constraints
[Extract any technical preferences, frameworks, languages mentioned]

## Success Criteria
[Define what "done" looks like based on the PRD]

## Current Task
Follow @fix_plan.md and choose the most important item to implement next.
```

### 2. @fix_plan.md  
Convert requirements into a prioritized task list:
```markdown
# Ralph Fix Plan

## High Priority
[Extract and convert critical features into actionable tasks]

## Medium Priority  
[Secondary features and enhancements]

## Low Priority
[Nice-to-have features and optimizations]

## Completed
- [x] Project initialization

## Notes
[Any important context from the original PRD]
```

### 3. specs/requirements.md
Create detailed technical specifications:
```markdown
# Technical Specifications

[Convert PRD into detailed technical requirements including:]
- System architecture requirements
- Data models and structures  
- API specifications
- User interface requirements
- Performance requirements
- Security considerations
- Integration requirements

[Preserve all technical details from the original PRD]
```

## Instructions
1. Read and analyze the attached specification file
2. Create the three files above with content derived from the PRD
3. Ensure all requirements are captured and properly prioritized
4. Make the PROMPT.md actionable for autonomous development
5. Structure @fix_plan.md with clear, implementable tasks

PROMPTEOF

	# Run Claude Code with the source file and prompt
	if $CLAUDE_CODE_CMD <.ralph_conversion_prompt.md; then
		log "SUCCESS" "PRD conversion completed"

		# Clean up temp file
		rm -f .ralph_conversion_prompt.md

		# Verify files were created
		local missing_files=()
		if [[ ! -f "PROMPT.md" ]]; then missing_files+=("PROMPT.md"); fi
		if [[ ! -f "@fix_plan.md" ]]; then missing_files+=("@fix_plan.md"); fi
		if [[ ! -f "specs/requirements.md" ]]; then missing_files+=("specs/requirements.md"); fi

		if [[ ${#missing_files[@]} -ne 0 ]]; then
			log "WARN" "Some files were not created: ${missing_files[*]}"
			log "INFO" "You may need to create these files manually or run the conversion again"
		fi

	else
		log "ERROR" "PRD conversion failed"
		rm -f .ralph_conversion_prompt.md
		exit 1
	fi
}

# Main function
main() {
	local source_file="$1"
	local project_name="$2"

	# Validate arguments
	if [[ -z $source_file ]]; then
		log "ERROR" "Source file is required"
		show_help
		exit 1
	fi

	if [[ ! -f $source_file ]]; then
		log "ERROR" "Source file does not exist: $source_file"
		exit 1
	fi

	# Default project name from filename
	if [[ -z $project_name ]]; then
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

	# Run conversion
	convert_prd "$source_file" "$project_name"

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
-h | --help | "")
	show_help
	exit 0
	;;
*)
	main "$@"
	;;
esac
