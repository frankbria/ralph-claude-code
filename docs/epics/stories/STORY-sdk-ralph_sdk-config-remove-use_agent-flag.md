# sdk ralph_sdk config remove use_agent flag

## What

sdk ralph_sdk config remove use_agent flag

## Where

- `sdk/ralph_sdk/config.py:89`
- `sdk/ralph_sdk/agent.py:1308-1323`

## Acceptance

- [ ] use_agent field deleted from config
- [ ] all call sites updated to always emit --agent
- [ ] SDK unit tests pass
