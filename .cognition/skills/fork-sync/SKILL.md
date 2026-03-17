---
name: fork-sync
description: Sync a forked repo's main branch with its upstream, intelligently resolving merge conflicts
argument-hint: "[merge-strategy]"
allowed-tools:
  - read
  - edit
  - grep
  - glob
  - exec
triggers:
  - user
  - model
---

# Fork Sync - Intelligent Upstream Synchronization

You are performing a fork synchronization workflow. Your job is to merge upstream
changes into the local fork while preserving local customizations and incorporating
upstream enhancements.

## Merge Strategy

The merge strategy argument ($1) controls how conflicts are resolved. Default: `preserve-local`.

| Strategy | Behavior |
|----------|----------|
| `preserve-local` | Keep local changes, only accept upstream additions that don't override local work |
| `prefer-upstream` | Accept upstream for all conflicts (simple fast-forward-like merge) |
| `combine` | Intelligently combine both sides: keep local additions AND upstream enhancements |

**Default strategy (`combine`) rules:**
1. **Keep local additions** - If HEAD adds functionality (new functions, extra tool support, custom features) that upstream doesn't have, KEEP them
2. **Accept upstream enhancements** - If upstream adds new functionality (bug fixes, new features, safety improvements) that doesn't conflict with local additions, ACCEPT them
3. **Combine when possible** - If both sides add different things to the same area, COMBINE both
4. **Local wins on direct conflicts** - If upstream would DELETE or REPLACE local functionality, keep the local version
5. **Adopt upstream patterns** - If upstream improves code quality (error handling, guards, cleanup) in areas your code also touches, adopt those patterns while keeping your functional additions

## Workflow

### Phase 1: Setup & Merge Attempt

Run the helper script to detect upstream and attempt the merge:

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")" 2>/dev/null || dirname "$0")"
# Or find it relative to .cognition/skills/fork-sync/
source .cognition/skills/fork-sync/fork_sync.sh

fork_sync_detect_upstream
fork_sync_prepare  # Creates branch, attempts merge
```

If the merge completes cleanly (exit code 0), you're done. Report success.

If conflicts are detected (exit code 1), proceed to Phase 2.

### Phase 2: Analyze Conflicts

For each conflicted file:

1. **Read the full file** to see all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
2. **Understand both sides**:
   - `<<<<<<< HEAD` to `=======` = YOUR local changes
   - `=======` to `>>>>>>> upstream/main` = UPSTREAM changes
3. **Classify each conflict** into one of:
   - **Addition vs Addition**: Both sides add different things -> COMBINE
   - **Modification vs Modification**: Both sides change the same thing differently -> Apply strategy
   - **Addition vs Deletion**: One side adds, other removes -> Usually keep addition
   - **Style/Pattern change**: Upstream improves patterns (error handling, guards) -> Adopt pattern, keep local functionality

### Phase 3: Resolve Each Conflict

For each conflict region, apply the merge strategy:

**When combining (default):**
```
# BEFORE (conflict)
<<<<<<< HEAD
source "$DIR/lib/my_module.sh"
source "$DIR/lib/my_extra.sh"        # <-- local addition
=======
source "$DIR/lib/my_module.sh" || { echo "FATAL" >&2; exit 1; }  # <-- upstream enhancement
>>>>>>> upstream/main

# AFTER (resolved)
source "$DIR/lib/my_module.sh" || { echo "FATAL" >&2; exit 1; }  # upstream's error handling
source "$DIR/lib/my_extra.sh" || { echo "FATAL" >&2; exit 1; }   # local addition + upstream's pattern
```

**Resolution checklist per conflict:**
- [ ] Read HEAD side completely
- [ ] Read upstream side completely
- [ ] Identify what each side adds/changes/removes
- [ ] Apply strategy rules
- [ ] Remove ALL conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
- [ ] Ensure the resolved code is syntactically valid

### Phase 4: Verify & Commit

After resolving all conflicts:

1. **Verify no conflict markers remain:**
   ```bash
   grep -rn '<<<<<<<\|>>>>>>>' <all conflicted files>
   ```

2. **Check for orphaned code** - sometimes code after a conflict marker belongs to the upstream's structure but references variables from their resolution. Scan for undefined variables near resolved regions.

3. **Stage and commit:**
   ```bash
   git add <all resolved files>
   git commit -m "merge: sync <local-branch> with upstream/<upstream-branch>

   Merged upstream changes while preserving local customizations:
   - <list what was kept from local>

   Incorporated upstream enhancements:
   - <list what was accepted from upstream>"
   ```

### Phase 5: Report

Provide a structured summary:

```
## Sync Complete

**Branch**: <sync-branch-name>
**Upstream commits merged**: <count>

### Kept (Local Changes)
- <item 1>
- <item 2>

### Incorporated (Upstream Enhancements)
- <item 1>
- <item 2>

### Combined (Both Sides)
- <item 1>

### Next Steps
1. Test your commands on this branch
2. When ready: `git checkout main && git merge <sync-branch>`
```

## Important Rules

- NEVER resolve conflicts without reading BOTH sides completely first
- NEVER blindly accept one side - always understand what each side does
- ALWAYS check for orphaned/dangling code after resolving a conflict region
- ALWAYS verify zero conflict markers remain before committing
- If unsure about a conflict, ask the user rather than guessing
- The sync branch is intentionally separate from main so the user can test before merging
