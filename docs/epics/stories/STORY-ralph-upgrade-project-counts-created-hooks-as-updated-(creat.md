# ralph-upgrade-project counts created hooks as Updated (Created always 0)

## What

ralph-upgrade-project counts created hooks as Updated (Created always 0)

## Where

- `ralph_upgrade_project.sh:210`

## Acceptance

- [ ] Newly-copied hooks log Created hook NAME and increment PROJ_CREATED counter
- [ ] Dry-run preview emits Would create hook NAME for missing destinations and the summary projects Created accurately
- [ ] Same fix applies to upgrade_agents so newly-installed agents are counted under Created not Updated
- [ ] New BATS test reproduces the empty-hooks-dir scenario and asserts Created equals the template count and Updated equals 0
- [ ] Same test asserts the inverse case (every hook already current) reports Created=0 Updated=0 Skipped=N
- [ ] npm run test unit stays green
