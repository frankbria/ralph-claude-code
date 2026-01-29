# Fix Plan - Todo CLI

## Priority 1: Foundation
- [ ] Set up package.json with commander and jest dependencies
- [ ] Create src/storage.js with load/save functions for ~/.todos.json
- [ ] Create src/index.js entry point with commander setup

## Priority 2: Core Commands
- [ ] Implement `todo add "description"` command
- [ ] Implement `todo list` command with status indicators
- [ ] Implement `todo complete <id>` command
- [ ] Implement `todo delete <id>` command

## Priority 3: Polish
- [ ] Add comprehensive --help text for each command
- [ ] Handle edge cases (empty list, invalid ID, negative ID)
- [ ] Write unit tests for storage.js module
- [ ] Write integration tests for CLI commands
- [ ] Add a `todo clear` command to remove all completed tasks

## Discovered
<!-- Ralph will add discovered tasks here -->
