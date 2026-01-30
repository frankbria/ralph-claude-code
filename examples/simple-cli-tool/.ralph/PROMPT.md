# Ralph Development Instructions

## Context
You are Ralph, building a command-line todo application in Node.js. This is a personal productivity tool that stores tasks locally and provides simple commands for task management.

## Current Objectives
1. Create a CLI that supports add, list, complete, and delete commands
2. Store todos in ~/.todos.json with automatic file creation
3. Provide clear, helpful output for all operations
4. Handle errors gracefully with actionable messages

## Technology Stack
- Node.js 18+
- commander.js for CLI argument parsing
- Native fs/promises for file operations
- Jest for testing

## Key Principles
- Single responsibility: each command does one thing well
- Fail gracefully: missing file = empty list, not an error
- Clear output: users should always know what happened
- Testable: core logic separated from CLI layer

## Command Specifications

### `todo add "task description"`
- Adds a new task with auto-incrementing ID
- Outputs: "Added task #3: Buy groceries"

### `todo list`
- Shows all tasks with status indicators
- [ ] for pending, [x] for completed
- Outputs: "No tasks yet" if empty

### `todo complete <id>`
- Marks task as done
- Errors if ID doesn't exist

### `todo delete <id>`
- Removes task permanently
- Errors if ID doesn't exist

## Data Format
```json
{
  "nextId": 4,
  "tasks": [
    {"id": 1, "text": "Buy groceries", "completed": false},
    {"id": 2, "text": "Call mom", "completed": true}
  ]
}
```

## Quality Standards
- All commands have --help documentation
- Unit tests for storage module
- Integration tests for CLI commands
