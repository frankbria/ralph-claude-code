# Quick Start: Your First Ralph Project

This tutorial walks you through enabling Ralph on an existing project and running your first autonomous development loop. By the end, you'll have Ralph building a simple CLI todo app.

## Prerequisites

- Ralph installed globally (`./install.sh` from the ralph-claude-code repo)
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- A project directory (we'll create one)

## Step 1: Create Your Project

Let's create a simple Node.js project:

```bash
mkdir todo-cli
cd todo-cli
npm init -y
git init
```

## Step 2: Enable Ralph

Run the interactive wizard:

```bash
ralph-enable
```

The wizard will:
1. Detect your project type (Node.js/TypeScript)
2. Ask about task sources (you can skip for now)
3. Create the `.ralph/` directory with starter files

You'll see output like:

```
Ralph Enable Wizard
==================

Phase 1: Environment Detection
------------------------------
Detected project type: javascript
Detected package manager: npm
Git repository: yes

Phase 2: Task Source Selection
------------------------------
No task sources selected. You can add tasks manually.

Phase 3: Configuration
------------------------------
Creating .ralph/ directory structure...

Phase 4: File Generation
------------------------------
Created: .ralph/PROMPT.md
Created: .ralph/fix_plan.md
Created: .ralph/AGENT.md
Created: .ralphrc

Ralph is now enabled for this project.
```

## Step 3: Customize Your Requirements

After `ralph-enable`, you have starter files that need customization. Open `.ralph/PROMPT.md` and replace the placeholder content:

```markdown
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent building a CLI todo application in Node.js.

## Current Objectives
1. Create a command-line todo app with add, list, complete, and delete commands
2. Store todos in a JSON file (~/.todos.json)
3. Use commander.js for argument parsing
4. Include helpful --help output
5. Write unit tests with Jest

## Key Principles
- Keep the code simple and readable
- Use async/await for file operations
- Provide clear error messages
- Follow Node.js best practices
```

## Step 4: Define Your Tasks

Edit `.ralph/fix_plan.md` to list specific tasks:

```markdown
# Fix Plan - Todo CLI

## Priority 1: Core Structure
- [ ] Set up package.json with dependencies (commander, jest)
- [ ] Create src/index.js entry point with commander setup
- [ ] Create src/storage.js for JSON file operations

## Priority 2: Commands
- [ ] Implement `todo add "task description"` command
- [ ] Implement `todo list` command with status indicators
- [ ] Implement `todo complete <id>` command
- [ ] Implement `todo delete <id>` command

## Priority 3: Polish
- [ ] Add --help documentation for all commands
- [ ] Handle edge cases (empty list, invalid IDs)
- [ ] Write unit tests for storage module
```

## Step 5: Start Ralph

Now let Ralph build your project:

```bash
ralph --monitor
```

This opens a tmux session with:
- **Left pane**: Ralph loop output (what Claude is doing)
- **Right pane**: Live monitoring dashboard

### What You'll See

Ralph will:
1. Read your PROMPT.md and fix_plan.md
2. Start implementing tasks in priority order
3. Create files, run tests, update fix_plan.md
4. Continue until all tasks are complete

### Monitoring Tips

- **Ctrl+B, then D** - Detach from tmux (Ralph keeps running)
- **tmux attach -t todo-cli** - Reattach to watch progress
- **ralph --status** - Check current loop status

## Step 6: Review the Results

When Ralph finishes (or you want to check progress), look at:

```bash
# See what files were created
ls -la src/

# Check the updated fix_plan.md
cat .ralph/fix_plan.md

# Run the tests Ralph wrote
npm test

# Try your new CLI
node src/index.js add "Buy groceries"
node src/index.js list
```

## What Just Happened?

Ralph followed this cycle:
1. **Read** - Loaded PROMPT.md for context and fix_plan.md for tasks
2. **Implement** - Wrote code for the highest priority unchecked task
3. **Test** - Ran any tests and fixed failures
4. **Update** - Marked completed tasks in fix_plan.md
5. **Repeat** - Continued until EXIT_SIGNAL was set

## Next Steps

- Read [Understanding Ralph Files](02-understanding-ralph-files.md) to learn what each file does
- Check [Writing Effective Requirements](03-writing-requirements.md) for best practices
- Explore the [examples/](../../examples/) directory for more complex projects

## Common Questions

### Ralph stopped early - why?

Check `.ralph/logs/` for the latest log. Common reasons:
- Rate limit reached (waits for reset)
- Circuit breaker opened (detected stuck loop)
- All tasks marked complete

### Ralph keeps running tests without implementing anything

Your fix_plan.md might be too vague. Make tasks specific and actionable:
- Bad: "Improve the code"
- Good: "Add error handling for missing ~/.todos.json file"

### How do I add more features later?

Just add new tasks to `.ralph/fix_plan.md` and run `ralph --monitor` again. Ralph will pick up where it left off.
