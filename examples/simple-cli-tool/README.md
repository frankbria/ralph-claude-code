# Example: Simple CLI Tool

This example shows a minimal Ralph configuration for a command-line todo application built with Node.js.

## What This Example Demonstrates

- **Minimal PROMPT.md** - Just enough context for a focused project
- **Specific fix_plan.md** - Concrete, actionable tasks
- **No specs/ needed** - Simple enough that PROMPT.md covers everything

## Project Structure

```
simple-cli-tool/
├── .ralph/
│   ├── PROMPT.md        # Project goals and principles
│   └── fix_plan.md      # Task list
├── .ralphrc             # Configuration (auto-generated)
└── README.md            # This file
```

## How to Use This Example

1. Copy this directory to a new location:
   ```bash
   cp -r examples/simple-cli-tool ~/my-todo-app
   cd ~/my-todo-app
   ```

2. Initialize git and npm:
   ```bash
   git init
   npm init -y
   ```

3. Run Ralph:
   ```bash
   ralph --monitor
   ```

## Key Points

### PROMPT.md is Focused

Notice how PROMPT.md:
- States exactly what the tool should do
- Specifies the technology (Node.js, commander.js)
- Defines key behaviors (where data is stored, error handling)

### fix_plan.md Uses Priorities

Tasks are grouped by priority:
- Priority 1: Foundation (must work before anything else)
- Priority 2: Core features (the main functionality)
- Priority 3: Polish (nice-to-have improvements)

### No specs/ Directory

This project is simple enough that PROMPT.md provides all necessary context. specs/ would be overkill here.

## When to Add More Files

Consider adding specs/ if you need:
- Complex command behavior documentation
- Data format specifications
- External service integration details

For this simple example, PROMPT.md is sufficient.
