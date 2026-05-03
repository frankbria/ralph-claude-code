# claude settings.json hook command does not start with bash binary

## What

claude settings.json hook command does not start with bash binary

## Where

- `.claude/settings.json:1-300`
- `tests/unit/test_settings_json.bats:20-25`

## Acceptance

- [ ] all hook commands match bash npx node python or sh prefix
- [ ] test_settings_json BATS suite green
- [ ] no regression in other settings tests
