---
alwaysApply: true
---

# Deployed Agent Scope (TappsMCP)

Agents deployed by `tapps_init` / `tapps_upgrade` must stay scoped to THIS
repo and THIS project for any **write** operation.

## Allowed (read)

- Documentation lookups across any project.
- Searching memory across federated projects to inform decisions.
- Browsing sibling repositories for reference only.

## Forbidden (write outside the deploying project)

- Creating, updating, commenting on, or moving Linear (or other tracker)
  issues that belong to a different project than this repo.
- Modifying files, branches, or pull requests in any other repository.
- Pushing, merging, releasing, or running automation for another project.

## How to apply

- Read team / project / repo identity from `.tapps-mcp.yaml` or the current
  git remote, NOT from arbitrary search results that may point at other
  workspaces.
- When in doubt whether a target belongs to this project, stop and ask the
  user instead of writing.
