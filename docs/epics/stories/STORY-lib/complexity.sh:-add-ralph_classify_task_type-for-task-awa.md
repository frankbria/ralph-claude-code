# lib/complexity.sh: add ralph_classify_task_type for task-aware routing

## What

lib/complexity.sh: add ralph_classify_task_type for task-aware routing

## Where

- `lib/complexity.sh:1-250`
- `tests/unit/test_complexity.bats:1-400`

## Acceptance

- [ ] ralph_classify_task_type returns exactly one of docs/tools/code/arch
- [ ] Word-boundary regex prevents search matching research
- [ ] Empty input returns code
- [ ] 27 BATS tests in test_complexity.bats pass covering each type with keyword variations
- [ ] Function is sourced by ralph_loop.sh and callable from build_claude_command
