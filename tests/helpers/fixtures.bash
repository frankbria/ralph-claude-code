#!/usr/bin/env bash
# Fixture Data for Ralph Test Suite

# Sample PRD Document (Markdown)
create_sample_prd_md() {
    local file=${1:-"sample_prd.md"}
    cat > "$file" << 'EOF'
# Task Management Web App - Product Requirements Document

## Overview
Build a modern task management web application similar to Todoist/Asana for small teams and individuals.

## Core Features

### User Management
- User registration and authentication
- User profiles with avatars
- Team/workspace creation and management

### Task Management
- Create, edit, and delete tasks
- Task prioritization (High, Medium, Low)
- Due dates and reminders
- Task categories/projects
- Task assignment to team members
- Comments and attachments on tasks

## Technical Requirements

### Frontend
- React.js with TypeScript
- Modern UI with responsive design
- Real-time updates for collaborative features
- PWA capabilities for mobile use

### Backend
- Node.js with Express
- PostgreSQL database
- RESTful API design
- WebSocket for real-time features
- JWT authentication

### Infrastructure
- Docker containerization
- Environment-based configuration
- Automated testing (unit and integration)
- CI/CD pipeline ready

## Success Criteria
- Users can create and manage tasks efficiently
- Team collaboration features work seamlessly
- App loads quickly (<2s initial load)
- Mobile-responsive design works on all devices
- 95%+ uptime once deployed

## Priority
1. **Phase 1**: Basic task CRUD, user auth, simple UI
2. **Phase 2**: Team features, real-time updates, advanced views
3. **Phase 3**: Notifications, mobile PWA, advanced filtering

## Timeline
Target MVP completion in 4-6 weeks of development.
EOF
}

# Sample PRD Document (Text)
create_sample_prd_txt() {
    local file=${1:-"sample_prd.txt"}
    cat > "$file" << 'EOF'
Project: Task Management System

Requirements:
- User authentication with email/password
- Task CRUD operations (create, read, update, delete)
- Team collaboration features
- Real-time updates for shared workspaces

Tech Stack:
- Frontend: React, TypeScript
- Backend: Node.js, Express
- Database: PostgreSQL

Timeline: 4-6 weeks for MVP

Success Criteria:
- Users can create and manage tasks
- Teams can collaborate on shared projects
- Performance: <2s page load time
EOF
}

# Sample PRD Document (JSON)
create_sample_prd_json() {
    local file=${1:-"sample_prd.json"}
    cat > "$file" << 'EOF'
{
  "project": "Task Management App",
  "overview": "Build a modern task management web application",
  "features": [
    "User authentication",
    "Task CRUD operations",
    "Team collaboration",
    "Real-time updates"
  ],
  "tech_stack": {
    "frontend": "React.js + TypeScript",
    "backend": "Node.js + Express",
    "database": "PostgreSQL"
  },
  "timeline": "4-6 weeks"
}
EOF
}

# Sample PROMPT.md
create_sample_prompt() {
    local file=${1:-"PROMPT.md"}
    cat > "$file" << 'EOF'
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a Task Management App project.

## Current Objectives
1. Study specs/* to learn about the project specifications
2. Review fix_plan.md for current priorities
3. Implement the highest priority item using best practices
4. Use parallel subagents for complex tasks (max 100 concurrent)
5. Run tests after each implementation
6. Update documentation and fix_plan.md

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update fix_plan.md with your learnings
- Commit working changes with descriptive messages

## 🧪 Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop
- PRIORITIZE: Implementation > Documentation > Tests
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Focus on CORE functionality first, comprehensive testing later

## Current Task
Follow fix_plan.md and choose the most important item to implement next.
EOF
}

# Sample fix_plan.md
create_sample_fix_plan() {
    local file=${1:-"fix_plan.md"}
    local total=${2:-10}
    local completed=${3:-3}

    cat > "$file" << 'EOF'
# Ralph Fix Plan

## High Priority
EOF

    # Add completed items
    for ((i=1; i<=completed && i<=total; i++)); do
        echo "- [x] Task $i - Completed" >> "$file"
    done

    # Add pending high priority items
    for ((i=completed+1; i<=total/2 && i<=total; i++)); do
        echo "- [ ] Task $i - High priority pending" >> "$file"
    done

    cat >> "$file" << 'EOF'

## Medium Priority
EOF

    # Add medium priority items
    for ((i=total/2+1; i<=total*3/4 && i<=total; i++)); do
        echo "- [ ] Task $i - Medium priority pending" >> "$file"
    done

    cat >> "$file" << 'EOF'

## Low Priority
EOF

    # Add low priority items
    for ((i=total*3/4+1; i<=total; i++)); do
        echo "- [ ] Task $i - Low priority pending" >> "$file"
    done

    cat >> "$file" << 'EOF'

## Completed
- [x] Project initialization

## Notes
- Focus on MVP functionality first
- Ensure each feature is properly tested
- Update this file after each major milestone
EOF
}

# Sample AGENT.md
create_sample_agent_md() {
    local file=${1:-"AGENT.md"}
    cat > "$file" << 'EOF'
# Agent Build Instructions

## Project Setup
```bash
# Install dependencies
npm install
```

## Running Tests
```bash
# Run all tests
npm test

# Run specific test file
npm test -- tests/unit/test_rate_limiting.bats
```

## Build Commands
```bash
# Production build
npm run build
```

## Development Server
```bash
# Start development server
npm run dev
```

## Key Learnings
- Tests use BATS framework
- All scripts are in bash
- Mock functions available in tests/helpers/mocks.bash
EOF
}

# Sample Claude Code Output (Success)
create_sample_claude_output_success() {
    local file=${1:-"claude_output.log"}
    cat > "$file" << 'EOF'
Reading PROMPT.md...
Analyzing project requirements...

Implementing task: Set up basic project structure

Created the following files:
- src/main.js
- src/utils.js
- tests/test_utils.bats

Running tests...
✓ All tests passed (5/5)

Updating fix_plan.md...
Completed: Set up basic project structure

Ready for next task.
EOF
}

# Sample Claude Code Output (Error)
create_sample_claude_output_error() {
    local file=${1:-"claude_output.log"}
    cat > "$file" << 'EOF'
Reading PROMPT.md...
Analyzing project requirements...

Error: Failed to import module 'utils'
Traceback:
  File "src/main.js", line 15

Recommendation: Check import paths and ensure dependencies are installed.
EOF
}

# Sample Claude Code Output (5-hour limit)
create_sample_claude_output_limit() {
    local file=${1:-"claude_output.log"}
    cat > "$file" << 'EOF'
Error: You've reached your 5-hour usage limit for Claude.
Please try again in about an hour when your limit resets.

This helps ensure fair access for all users.
Thank you for your patience!
EOF
}

# Sample status.json (Running)
create_sample_status_running() {
    local file=${1:-"status.json"}
    cat > "$file" << 'EOF'
{
    "timestamp": "2025-09-30T12:00:00-04:00",
    "loop_count": 5,
    "calls_made_this_hour": 42,
    "max_calls_per_hour": 100,
    "last_action": "executing",
    "status": "running",
    "exit_reason": ""
}
EOF
}

# Sample status.json (Completed)
create_sample_status_completed() {
    local file=${1:-"status.json"}
    cat > "$file" << 'EOF'
{
    "timestamp": "2025-09-30T15:30:00-04:00",
    "loop_count": 25,
    "calls_made_this_hour": 25,
    "max_calls_per_hour": 100,
    "last_action": "graceful_exit",
    "status": "completed",
    "exit_reason": "plan_complete"
}
EOF
}

# Sample progress.json (Executing)
create_sample_progress_executing() {
    local file=${1:-"progress.json"}
    cat > "$file" << 'EOF'
{
    "status": "executing",
    "indicator": "⠋",
    "elapsed_seconds": 120,
    "last_output": "Analyzing code structure...",
    "timestamp": "2025-09-30 12:05:00"
}
EOF
}

# Sample metrics.jsonl
create_sample_metrics() {
    local file=${1:-"metrics.jsonl"}
    cat > "$file" << 'EOF'
{"timestamp":"2025-09-30T12:00:00-04:00","loop":1,"duration":45,"success":true,"calls":1}
{"timestamp":"2025-09-30T12:01:30-04:00","loop":2,"duration":52,"success":true,"calls":2}
{"timestamp":"2025-09-30T12:03:00-04:00","loop":3,"duration":38,"success":true,"calls":3}
{"timestamp":"2025-09-30T12:04:15-04:00","loop":4,"duration":41,"success":false,"calls":3}
{"timestamp":"2025-09-30T12:05:45-04:00","loop":5,"duration":48,"success":true,"calls":4}
EOF
}

# Create complete test project structure
# Creates .ralph/ subfolder structure for Ralph-specific files
create_test_project() {
    local project_dir=${1:-"test_project"}

    # Create project with .ralph/ subfolder structure
    mkdir -p "$project_dir"/src
    mkdir -p "$project_dir"/.ralph/{specs/stdlib,examples,logs,docs/generated}

    cd "$project_dir" || return 1

    # Create Ralph files in .ralph/ subdirectory
    create_sample_prompt ".ralph/PROMPT.md"
    create_sample_fix_plan ".ralph/fix_plan.md" 10 3
    create_sample_agent_md ".ralph/AGENT.md"

    # Create state files in .ralph/
    echo "0" > .ralph/.call_count
    echo "$(date +%Y%m%d%H)" > .ralph/.last_reset
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > .ralph/.exit_signals

    cd - > /dev/null || return 1
}
