# Fork Sync - Agent Workflow for Any CLI Agent

> Standalone workflow document for Claude Code, Codex, or any AI coding agent.
> This is the agent-portable version of the Devin `/fork-sync` skill.

## Overview

This workflow syncs a GitHub fork with its upstream repository, using AI to
intelligently resolve merge conflicts. It preserves local customizations while
incorporating upstream enhancements.

## Prerequisites

- `git`, `gh` (GitHub CLI), `jq` installed
- Authenticated with GitHub (`gh auth status`)
- Working directory is inside the forked git repo
- Helper script available at `.cognition/skills/fork-sync/fork_sync.sh`

## Quick Start (for agents)

Paste this into your agent prompt or run it as instructions:

---

### Step 1: Detect and Prepare

```bash
# Detect the upstream parent repo
UPSTREAM=$(gh repo view --json parent --jq '.parent.owner.login + "/" + .parent.name')
echo "Upstream: $UPSTREAM"

# Add upstream remote if not present
if ! git remote get-url upstream &>/dev/null; then
    git remote add upstream "https://github.com/${UPSTREAM}.git"
fi

# Fetch upstream main
git fetch upstream main

# Check how many commits behind
BEHIND=$(git rev-list --count main..upstream/main)
echo "$BEHIND commits behind upstream"

# Create a sync branch (never merge directly into main)
git checkout main
git checkout -b main-sync-fork

# Attempt the merge
git merge upstream/main --no-edit
```

If the merge succeeds cleanly, skip to Step 5.
If the merge fails with conflicts, continue to Step 2.

### Step 2: List All Conflicts

```bash
# Get list of conflicted files
git diff --name-only --diff-filter=U

# For each file, count conflict regions
for f in $(git diff --name-only --diff-filter=U); do
    COUNT=$(grep -c '<<<<<<<' "$f" 2>/dev/null || echo 0)
    echo "$f: $COUNT conflict(s)"
done
```

### Step 3: Resolve Each Conflict

For every conflicted file, read the FULL file and resolve each conflict region.

**Conflict anatomy:**
```
<<<<<<< HEAD
(your local changes)
=======
(upstream changes)
>>>>>>> upstream/main
```

**Resolution strategy — `combine` (recommended):**

| Scenario | Action |
|----------|--------|
| Local adds functionality upstream doesn't have | **KEEP local** |
| Upstream adds new feature/bugfix not in local | **ACCEPT upstream** |
| Both add different things to same area | **COMBINE both** |
| Upstream removes/replaces local functionality | **KEEP local** |
| Upstream improves patterns (error handling, guards) | **ADOPT pattern + keep local functionality** |
| Pure formatting/style conflict | **Accept upstream** |

**Concrete example — combining both sides:**

```bash
# BEFORE (conflict in source statements)
<<<<<<< HEAD
source "$DIR/lib/date_utils.sh"
source "$DIR/lib/my_custom_lib.sh"        # local addition
=======
source "$DIR/lib/date_utils.sh" || { echo "FATAL" >&2; exit 1; }  # upstream: error handling
source "$DIR/lib/new_upstream_lib.sh" || { echo "FATAL" >&2; exit 1; }  # upstream: new lib
>>>>>>> upstream/main

# AFTER (resolved — combine all three improvements)
source "$DIR/lib/date_utils.sh" || { echo "FATAL" >&2; exit 1; }        # upstream pattern
source "$DIR/lib/my_custom_lib.sh" || { echo "FATAL" >&2; exit 1; }     # local + upstream pattern
source "$DIR/lib/new_upstream_lib.sh" || { echo "FATAL" >&2; exit 1; }  # upstream addition
```

**For each conflict, follow this process:**
1. Read HEAD (your) side completely
2. Read upstream side completely
3. Identify what each side adds, changes, or removes
4. Apply the resolution strategy from the table above
5. Remove ALL conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
6. Check that the resolved code is syntactically valid

**Critical: Watch for orphaned code.** After resolving a conflict, check the lines
immediately following it. Sometimes code that was inside the upstream's conflict block
references variables defined in the upstream's version (`$error_msg` vs your `$api_error`).
Fix variable references to match your resolved version.

### Step 4: Verify Resolution

```bash
# Must return zero results
grep -rn '<<<<<<<\|>>>>>>>' $(git diff --name-only --diff-filter=U)

# Also check for stray ======= that aren't section dividers
grep -n '^=======$' $(git diff --name-only --diff-filter=U)
```

### Step 5: Commit

```bash
# Stage all resolved files
git add -A

# Commit with descriptive message
git commit -m "merge: sync main with upstream

Preserved local customizations:
- <list what you kept>

Incorporated upstream enhancements:
- <list what you accepted>

Combined (both sides):
- <list what was merged from both>"
```

### Step 6: Report to User

Provide this summary:

```
## Fork Sync Complete

**Branch**: main-sync-fork
**Upstream**: <owner>/<repo>
**Commits merged**: <N>

### Kept (Local Changes)
- <bullet points>

### Incorporated (Upstream Enhancements)
- <bullet points>

### Next Steps
1. Run your test suite on this branch
2. Verify your custom functionality works
3. When satisfied: git checkout main && git merge main-sync-fork
4. Push: git push origin main
```

---

## Configuration

Environment variables to customize behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `FORK_SYNC_UPSTREAM_BRANCH` | `main` | Upstream branch to sync from |
| `FORK_SYNC_LOCAL_BRANCH` | `main` | Local branch to base sync on |
| `FORK_SYNC_BRANCH_NAME` | `main-sync-fork` | Name of the sync branch |

## Using the Helper Script

The `fork_sync.sh` script automates the mechanical git operations:

```bash
# Source it for function access
source .cognition/skills/fork-sync/fork_sync.sh

# Or run commands directly
bash .cognition/skills/fork-sync/fork_sync.sh detect     # Find upstream repo
bash .cognition/skills/fork-sync/fork_sync.sh prepare     # Setup + merge attempt
bash .cognition/skills/fork-sync/fork_sync.sh conflicts   # JSON conflict list
bash .cognition/skills/fork-sync/fork_sync.sh report      # Human-readable conflict report
bash .cognition/skills/fork-sync/fork_sync.sh verify      # Check markers resolved
bash .cognition/skills/fork-sync/fork_sync.sh commit "msg" # Commit the merge
bash .cognition/skills/fork-sync/fork_sync.sh abort       # Cancel everything
bash .cognition/skills/fork-sync/fork_sync.sh summary     # Upstream changes overview
```

## For Claude Code Specifically

Add this to your project's `CLAUDE.md`:

```markdown
## Fork Sync Workflow

To sync this fork with upstream, follow the workflow in:
  .cognition/skills/fork-sync/AGENT_WORKFLOW.md

Helper script: .cognition/skills/fork-sync/fork_sync.sh

Default merge strategy: combine (preserve local, accept upstream enhancements)
```

Then tell Claude: "Sync this fork with upstream using the fork-sync workflow"

## For Other Agents (Codex, Aider, etc.)

Feed this file as context to any agent that can run shell commands and edit files:

```bash
# Codex example
codex --prompt "$(cat .cognition/skills/fork-sync/AGENT_WORKFLOW.md)"

# Or include as a system prompt
cat .cognition/skills/fork-sync/AGENT_WORKFLOW.md | your-agent --system-prompt -
```
