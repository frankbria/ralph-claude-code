# tapps-brain bearer token mismatch in ralph mcp probe

## What

tapps-brain bearer token mismatch in ralph mcp probe

## Where

- `ralph_loop.sh:2300-2400`
- `templates/secrets.env.example:1-30`

## Acceptance

- [ ] ralph mcp-status reports tapps-brain reachable
- [ ] probe and claude mcp client agree on auth
- [ ] secrets template documents canonical token source
