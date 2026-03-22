# Ralph Auto-PR at End of Every Run

**Date:** 2026-03-22
**Status:** Approved
**Scope:** All Ralph variants (Claude, Codex, Devin) — interactive and loop modes

---

## Problem

Ralph currently ends each loop iteration by merging the worktree branch directly into the main branch after an interactive "Merge into main? (yes/no)" prompt. There is no audit trail, no code review gate, and no PR for the work done in each run. The desired end state is always a Pull Request — never a direct merge to main.

---

## Goal

At the end of every Ralph run, Ralph must:
1. Commit all work in its working worktree branch
2. Push the branch to remote
3. Open a GitHub Pull Request targeting the main branch

This is **default behaviour** across all execution modes and all variants. Ralph never directly merges to main.

---

## Prerequisites and Existing Globals

`lib/pr_manager.sh` is sourced **after** `lib/worktree_manager.sh` in each loop script. The following globals are already defined by `worktree_manager.sh` and are available in `pr_manager.sh`:

| Variable | Set by | Value |
|---|---|---|
| `_WT_CURRENT_PATH` | `worktree_create()` | Absolute path to active worktree directory; empty if no active worktree |
| `_WT_CURRENT_BRANCH` | `worktree_create()` | Active worktree branch name; empty if none |
| `_WT_MAIN_DIR` | `worktree_init()` | `$(pwd)` at time `worktree_init` was called — the main project root |
| `WORKTREE_ENABLED` | `.ralphrc` / default | `"true"` or `"false"` |
| `RALPH_DIR` | each loop script | `".ralph"` — the Ralph config subdirectory inside the project |

`worktree_is_active` is a function defined in `worktree_manager.sh`. It returns `0` (true) if `_WT_CURRENT_PATH` is non-empty and the directory exists; returns `1` otherwise.

`worktree_merge` is a function defined in `worktree_manager.sh`. It merges `_WT_CURRENT_BRANCH` into `_WT_MAIN_BRANCH` using the configured strategy. It is referenced by `worktree_commit_and_pr` when `PR_ENABLED=false`.

`$RALPH_DIR` (i.e., `.ralph/`) is always present inside the worktree because `worktree_create()` copies `.ralph/` into the worktree via `cp -R`. Therefore `$_WT_CURRENT_PATH/.ralph/.quality_gate_results` always resolves correctly when a worktree is active.

`picked_task_id`, `picked_task_name`, `picked_line_num` are variables set by existing fix_plan.md task-picking logic in each loop script before the execution block. They may be empty strings if no task was picked. All `pr_manager.sh` functions handle empty values for `task_id` and `task_name` gracefully (see fallback logic in `pr_build_title`).

---

## Quality Gate Retry Behaviour

When quality gates fail, Ralph **keeps the same worktree alive** and loops again to let the agent fix the failures, rather than starting a new worktree. Only when Ralph gives up does it create a PR — with a failure label and full failure details.

**Retry flow:**
1. Quality gates fail → increment `QG_RETRY_COUNT` → skip cleanup → loop continues with same worktree
2. `worktree_is_active` is true at top of next iteration → worktree creation is skipped → agent runs in same worktree
3. If quality gates now pass → PR created (success)
4. If `QG_RETRY_COUNT >= MAX_QG_RETRIES` or circuit breaker opens → PR created with `quality-gates-failed` label

`MAX_QG_RETRIES` defaults to `3`. Configurable in `.ralphrc` as `MAX_QG_RETRIES=3`.

`QG_RETRY_COUNT` is reset to `0` in two places: (a) when quality gates pass, (b) when a new worktree is created (beginning of each iteration where `worktree_is_active` is false and `worktree_create` is called).

---

## Architecture

### New file: `lib/pr_manager.sh`

A shared library sourced by all three loop scripts. Contains all PR-related logic.

**New global state set by this library:**
```bash
RALPH_PR_PUSH_CAPABLE=true|false  # true if git origin remote exists
RALPH_PR_GH_CAPABLE=true|false    # true if gh CLI is installed and authenticated
```
These are set by `pr_preflight_check()` and read by `worktree_commit_and_pr()` and `worktree_fallback_branch_pr()`.

---

### Function: `pr_preflight_check()`

**Purpose:** Validate PR prerequisites. Called **once** before the main `while` loop in each loop script.

**Checks:**

1. Git remote `origin` exists: `git remote get-url origin &>/dev/null`
   - On fail: set `RALPH_PR_PUSH_CAPABLE=false`, print warning block, reason: `"No git remote named 'origin' — cannot push branches"`

2. `gh` CLI is installed: `command -v gh &>/dev/null`
   - On fail: set `RALPH_PR_GH_CAPABLE=false`, print warning block, reason: `"gh CLI not found — install from https://cli.github.com"`

3. `gh` is authenticated: `gh auth status &>/dev/null` (only checked if `gh` is installed)
   - On fail: set `RALPH_PR_GH_CAPABLE=false`, print warning block, reason: `"gh is not authenticated — run: gh auth login"`

**Warning block format:**
```
╔══════════════════════════════════════════════════════╗
║  WARNING: PR CREATION DISABLED                       ║
║  Reason: <specific reason string>                    ║
║  Ralph will commit and push branches only.           ║
╚══════════════════════════════════════════════════════╝
```
Each failing check prints its own warning block.

**On all checks passing:** Set both to `true`. Log `INFO "PR preflight: all checks passed (push=true, gh=true)"`.

**Return value:** Always `0`. Never blocks execution.

---

### Function: `pr_build_title(task_id, task_name)`

**Inputs:**
- `$1` — `task_id`: string from fix_plan.md; may be empty string
- `$2` — `task_name`: string from fix_plan.md; may be empty string

**Output:** Prints PR title string to stdout.

**Logic (in order):**
1. Both non-empty → `"ralph: ${task_name} [${task_id}]"`
2. `task_name` empty, `task_id` non-empty → `"ralph: task [${task_id}]"`
3. Both empty → `"ralph: automated work [$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')]"`
4. Truncation: if the resulting title string is longer than 72 characters, keep the first 69 characters and append `"..."`. Result is exactly 72 characters. Example: a 90-char title becomes `<first-69-chars>...`

**Return value:** Always `0`.

---

### Function: `pr_build_description(task_id, task_name, branch, gate_passed, gate_results_file)`

**Inputs:**
- `$1` — `task_id`: string; may be empty
- `$2` — `task_name`: string; may be empty
- `$3` — `branch`: git branch name string
- `$4` — `gate_passed`: must be literal string `"true"` or `"false"` (caller passes quoted string based on `$gate_result -eq 0` check)
- `$5` — `gate_results_file`: absolute path to `.quality_gate_results` file; file may not exist

**Output:** Prints Markdown PR body to stdout.

**`.quality_gate_results` file format** (written by existing `worktree_run_quality_gates` in `worktree_manager.sh`):
```
PASS: <command string>
FAIL: <command string> (exit <N>)
```
One entry per gate. Written via `printf "%b"` so `\n` is real newlines.

**Parsing each line:**
- Trim leading/trailing whitespace before processing
- Line starts with `PASS: ` (6 chars) → status=`PASS`, cmd=everything after `PASS: `
- Line starts with `FAIL: ` (6 chars) → status=`FAIL`; to extract cmd and exit code:
  - cmd = `${line% (exit *)}` after stripping the `FAIL: ` prefix (removes trailing ` (exit N)`)
  - exit_code = extracted via `[[ $line =~ \(exit ([0-9]+)\)$ ]]` → `${BASH_REMATCH[1]}`
- Blank line: skip
- Line not matching either prefix: skip; log `DEBUG "Skipping unparseable gate result line: $line"`

**Two-branch output for Quality Gates section:**

*Branch A — file exists and has content:*
```markdown
## Quality Gates
| Gate Command | Result |
|---|---|
| `<cmd>` | ✅ PASS |
| `<cmd>` | ❌ FAIL (exit <N>) |
```

*Branch B — file does not exist or is empty:*
```markdown
## Quality Gates
No quality gate data available.
```

**Full body structure:**
```markdown
## Summary
Task: <task_name> (<task_id>)
Branch: <branch>

## Quality Gates
<branch A or branch B above>

## Quality Gate Failures
> ⚠️ The following gates failed and could not be resolved:
- `<cmd>` — exit code `<N>`

---
🤖 Generated by Ralph [<RALPH_ENGINE>] loop #<loop_count> — <timestamp>
```

**Conditional sections:**
- `Task: ...` line: omitted if both `task_id` and `task_name` are empty
- `## Quality Gate Failures` section: only present when `gate_passed="false"`. Lists only `FAIL:` lines from the parsed file.
- `<timestamp>` = `$(date -u +%Y-%m-%dT%H:%M:%SZ)` (ISO 8601 UTC)
- `<RALPH_ENGINE>` = value of env var `$RALPH_ENGINE`
- `<loop_count>` = value of env var `$loop_count` (the loop counter variable in calling scope; pass it as a separate env var `RALPH_LOOP_COUNT` set by the caller before invoking this function, or pass as `$6` — use `$6` as the 6th positional parameter to keep it simple)

**Revised signature:** `pr_build_description(task_id, task_name, branch, gate_passed, gate_results_file, loop_count)`
- `$6` — `loop_count`: integer

**Return value:** Always `0`.

---

### Function: `worktree_commit_and_pr(task_id, task_name, gate_passed, loop_count)`

**Inputs:**
- `$1` — `task_id`: string; may be empty
- `$2` — `task_name`: string; may be empty
- `$3` — `gate_passed`: literal `"true"` or `"false"`
- `$4` — `loop_count`: integer

**Environment variables read (all set before this function is called):**
- `PR_ENABLED` — if unset or `"true"`: use PR flow. If `"false"`: call `worktree_merge` and `return 0`.
- `PR_BASE_BRANCH` — target branch for PR. Resolution:
  ```bash
  local base_branch="${PR_BASE_BRANCH}"
  if [[ -z "$base_branch" ]]; then
      base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  fi
  if [[ -z "$base_branch" ]]; then
      base_branch="main"
  fi
  log_status "INFO" "PR base branch: $base_branch"
  ```
- `PR_DRAFT` — if `"true"`: pass `--draft` to `gh pr create`
- `RALPH_PR_PUSH_CAPABLE` — controls whether Step 2 (push) runs
- `RALPH_PR_GH_CAPABLE` — controls whether Steps 3–4 run
- `_WT_CURRENT_PATH`, `_WT_CURRENT_BRANCH`, `_WT_MAIN_DIR` — from `worktree_manager.sh`
- `RALPH_ENGINE`, `RALPH_DIR` — from loop script

**Steps:**

**Step 1 — Auto-commit (run inside `$_WT_CURRENT_PATH`):**
```bash
(
  cd "$_WT_CURRENT_PATH" || { log_status "ERROR" "Cannot cd to worktree: $_WT_CURRENT_PATH"; exit 1; }
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      git add -A 2>/dev/null
      git commit -m "ralph-${RALPH_ENGINE}: auto-commit run #${loop_count}" 2>/dev/null
      if [[ $? -ne 0 ]]; then log_status "ERROR" "Commit failed"; exit 1; fi
      log_status "INFO" "Changes committed to $_WT_CURRENT_BRANCH"
  else
      log_status "INFO" "Nothing to commit in worktree — proceeding to push"
  fi
)
commit_result=$?
if [[ $commit_result -ne 0 ]]; then return 1; fi
```

**Step 2 — Push branch (from `$_WT_MAIN_DIR`):**
```bash
if [[ "$RALPH_PR_PUSH_CAPABLE" != "true" ]]; then
    log_status "WARN" "Push skipped — no git remote. Branch: $_WT_CURRENT_BRANCH"
else
    (
      cd "$_WT_MAIN_DIR"
      git push origin "$_WT_CURRENT_BRANCH" --set-upstream 2>/dev/null
      if [[ $? -ne 0 ]]; then log_status "ERROR" "Push failed for $_WT_CURRENT_BRANCH"; exit 1; fi
      log_status "SUCCESS" "Branch pushed: $_WT_CURRENT_BRANCH"
    )
    push_result=$?
    if [[ $push_result -ne 0 ]]; then return 1; fi
fi
```
Note: `--set-upstream` is always passed. On retries where upstream already exists it is harmless; git ignores it.

**Step 3 — Create PR (only if `RALPH_PR_GH_CAPABLE="true"` and `RALPH_PR_PUSH_CAPABLE="true"`):**
```bash
existing_pr=$(gh pr view "$_WT_CURRENT_BRANCH" --json url --jq '.url' 2>/dev/null)
if [[ -n "$existing_pr" ]]; then
    log_status "INFO" "PR already exists for branch $_WT_CURRENT_BRANCH: $existing_pr. Skipping creation."
    # Note: new commits pushed in Step 2 are automatically included in the existing PR — no action needed.
else
    pr_title=$(pr_build_title "$task_id" "$task_name")
    pr_body=$(pr_build_description "$task_id" "$task_name" "$_WT_CURRENT_BRANCH" \
              "$gate_passed" "$_WT_CURRENT_PATH/.ralph/.quality_gate_results" "$loop_count")
    gh_args=(--base "$base_branch" --head "$_WT_CURRENT_BRANCH" --title "$pr_title" --body "$pr_body")
    [[ "$PR_DRAFT" == "true" ]] && gh_args+=(--draft)
    pr_url=$(gh pr create "${gh_args[@]}" 2>&1)
    if [[ $? -ne 0 ]]; then
        log_status "ERROR" "PR creation failed: $pr_url"
        return 1
    fi
    log_status "SUCCESS" "PR created: $pr_url"
fi
```

**Step 4 — Add failure label (only if `gate_passed="false"` and `RALPH_PR_GH_CAPABLE="true"`):**
```bash
if [[ "$gate_passed" == "false" ]]; then
    gh pr edit "$_WT_CURRENT_BRANCH" --add-label "quality-gates-failed" 2>/dev/null \
        || log_status "WARN" "Could not add 'quality-gates-failed' label (may not exist in repo)"
fi
```
Always returns 0 regardless of label step outcome.

**Step 5 — If not GH/push capable:**
```bash
if [[ "$RALPH_PR_GH_CAPABLE" != "true" ]]; then
    log_status "WARN" "PR skipped — gh not available. Branch committed${RALPH_PR_PUSH_CAPABLE:+ and pushed}: $_WT_CURRENT_BRANCH"
fi
```

**Return values:**
- `0` — all attempted steps succeeded or were intentionally skipped
- `1` — Step 1 (commit failed) or Step 2 (push failed) or Step 3 (PR create failed); error logged before return

**Caller response to return 1:**
```bash
if [[ $pr_result -ne 0 ]]; then
    log_status "ERROR" "PR workflow failed for branch: $(worktree_get_branch). Branch preserved for manual recovery."
fi
worktree_cleanup "false"   # always called regardless of pr_result
```
Loop continues to next iteration regardless.

---

### Function: `worktree_fallback_branch_pr(task_id, task_name, loop_count)`

**Purpose:** Used when `WORKTREE_ENABLED=false`. Called at end of each loop iteration. Creates a temporary branch, commits work, pushes, opens PR.

**Inputs:**
- `$1` — `task_id`; may be empty
- `$2` — `task_name`; may be empty
- `$3` — `loop_count`: integer

**Environment:** Runs from the main project root directory (`$(pwd)` or `$(git rev-parse --show-toplevel 2>/dev/null)`). Does NOT use `_WT_MAIN_DIR` (may not be set when `WORKTREE_ENABLED=false`). Does NOT use `_WT_CURRENT_PATH` or `_WT_CURRENT_BRANCH`.

**Branch name:**
```bash
FALLBACK_BRANCH="ralph-${RALPH_ENGINE}/${task_id:-run}-$(date +%s)"
```
`date +%s` is Unix epoch seconds.

**Steps:**

**Step 1 — Stash uncommitted changes:**
```bash
stash_was_empty=false
stash_output=$(git stash 2>&1)
stash_exit=$?
if echo "$stash_output" | grep -q "No local changes to save"; then
    stash_was_empty=true
elif [[ $stash_exit -ne 0 ]]; then
    log_status "ERROR" "git stash failed (exit $stash_exit): $stash_output"
    return 1
fi
```

**Step 2 — Create and checkout fallback branch:**
```bash
git checkout -b "$FALLBACK_BRANCH" 2>&1
checkout_exit=$?
if [[ $checkout_exit -ne 0 ]]; then
    [[ "$stash_was_empty" == "false" ]] && git stash pop 2>/dev/null
    log_status "ERROR" "Failed to create fallback branch: $FALLBACK_BRANCH (exit $checkout_exit)"
    return 1
fi
```

**Step 3 — Pop stash:**
```bash
if [[ "$stash_was_empty" == "false" ]]; then
    git stash pop 2>&1
    pop_exit=$?
    if [[ $pop_exit -ne 0 ]]; then
        log_status "ERROR" "git stash pop failed (exit $pop_exit). Work is saved in stash."
        return 1
    fi
fi
```

**Step 4 — Commit:**
```bash
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    git add -A 2>/dev/null
    git commit -m "ralph-${RALPH_ENGINE}: auto-commit run #${loop_count}" 2>/dev/null
    if [[ $? -ne 0 ]]; then log_status "ERROR" "Commit failed on fallback branch $FALLBACK_BRANCH"; return 1; fi
else
    log_status "WARN" "Nothing to commit on fallback branch $FALLBACK_BRANCH"
fi
```

**Steps 5–7 — Push, create/skip PR, add label:**

Identical to Steps 2–4 of `worktree_commit_and_pr` except:
- Replace all references to `$_WT_CURRENT_BRANCH` with `$FALLBACK_BRANCH`
- Replace `cd "$_WT_MAIN_DIR"` with no `cd` (already at project root)
- Replace `$_WT_CURRENT_PATH/.ralph/.quality_gate_results` with `$RALPH_DIR/.quality_gate_results`

**Return values:** Same as `worktree_commit_and_pr`. Caller response is identical.

---

## Changes to Loop Scripts

Applies to all three variants: `ralph_loop.sh`, `codex/ralph_loop_codex.sh`, `devin/ralph_loop_devin.sh`.

### Change 1 — Set `RALPH_ENGINE` (near top, after shebang, before other config)

```bash
RALPH_ENGINE="claude"   # ralph_loop.sh
RALPH_ENGINE="codex"    # codex/ralph_loop_codex.sh
RALPH_ENGINE="devin"    # devin/ralph_loop_devin.sh
```

### Change 2 — Source `pr_manager.sh`

Added after all existing `source` calls (`.ralphrc` already sourced at this point, so `PR_ENABLED` etc. are available):
```bash
source "$LIB_DIR/pr_manager.sh" || { echo "FATAL: Failed to source lib/pr_manager.sh" >&2; exit 1; }
```

### Change 3 — Declare QG retry counter after existing variable declarations

```bash
QG_RETRY_COUNT=0
MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"
```

### Change 4 — Call `pr_preflight_check()` once before `while true; do`

Insert immediately after existing `worktree_init` call:
```bash
pr_preflight_check
```

### Change 5 — Update worktree creation block to support re-use on QG retry

**Current (all 3 variants):**
```bash
work_dir="$(pwd)"
if [[ "$WORKTREE_ENABLED" == "true" ]]; then
    local wt_task_id="${picked_task_id:-loop-${loop_count}-$(date +%s)}"
    if worktree_create "$loop_count" "$wt_task_id" > /dev/null; then
        work_dir="$(worktree_get_path)"
        log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
    fi
fi
```

**Replacement:**
```bash
work_dir="$(pwd)"
if [[ "$WORKTREE_ENABLED" == "true" ]]; then
    if worktree_is_active; then
        # QG retry — reuse existing worktree (do not create a new one)
        work_dir="$(worktree_get_path)"
        log_status "INFO" "QG retry #${QG_RETRY_COUNT}: reusing worktree $work_dir (branch: $(worktree_get_branch))"
    else
        QG_RETRY_COUNT=0   # reset counter when starting fresh with a new worktree
        local wt_task_id="${picked_task_id:-loop-${loop_count}-$(date +%s)}"
        if worktree_create "$loop_count" "$wt_task_id" > /dev/null; then
            work_dir="$(worktree_get_path)"
            log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
        fi
    fi
fi
```

### Change 6 — Replace the merge prompt block entirely

Locate the existing block below `if [ $exec_result -eq 0 ]; then` that starts with `if [[ "$WORKTREE_ENABLED" == "true" ]] && worktree_is_active; then`.

**Remove the entire contents of this `if` block** (from `if [[ $gate_result -eq 0 ]]; then` down through the final `worktree_cleanup "false"` in the else branch).

**Replace with:**
```bash
if [[ $gate_result -eq 0 ]]; then
    # Quality gates passed — commit + push + open PR
    log_status "SUCCESS" "Quality gates passed."
    QG_RETRY_COUNT=0
    worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "true" "$loop_count"
    pr_result=$?
    worktree_cleanup "false"    # branch preserved as PR head; never deleted by Ralph
    if [[ $pr_result -eq 0 ]]; then
        if [[ -n "$picked_line_num" ]] && [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
            mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
        fi
    else
        log_status "ERROR" "PR workflow failed. Branch preserved for manual recovery: $(worktree_get_branch)"
    fi
else
    # Quality gates failed — increment retry counter
    QG_RETRY_COUNT=$((QG_RETRY_COUNT + 1))
    log_status "WARN" "Quality gates failed (attempt $QG_RETRY_COUNT/$MAX_QG_RETRIES)."
    if [[ $QG_RETRY_COUNT -ge $MAX_QG_RETRIES ]]; then
        log_status "WARN" "Max QG retries reached. Creating PR with failure details."
        worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count"
        worktree_cleanup "false"    # branch preserved
        QG_RETRY_COUNT=0
    else
        log_status "INFO" "Keeping worktree alive for QG retry in next loop iteration."
        # do NOT call worktree_cleanup — worktree stays active
    fi
fi
```

### Change 7 — Add non-worktree fallback

Inside `if [ $exec_result -eq 0 ]; then`, **after** all the worktree-related code (after the `elif [[ "$WORKTREE_ENABLED" == "true" ]] && [[ -n "$_WT_CURRENT_PATH" ]]...` block and the beads sync block), add:

```bash
# Non-worktree PR: create branch + push + PR when not using worktrees
if [[ "$WORKTREE_ENABLED" != "true" ]]; then
    worktree_fallback_branch_pr "$picked_task_id" "$picked_task_name" "$loop_count"
fi
```

### Change 8 — Replace circuit breaker worktree cleanup with PR-first cleanup

**Current (all 3 variants)** in the `elif [ $exec_result -eq 3 ]` block:
```bash
if worktree_is_active; then worktree_cleanup "true"; fi
```

**Replacement:**
```bash
if worktree_is_active; then
    log_status "WARN" "Circuit breaker opened — creating failure PR before cleanup."
    worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count"
    worktree_cleanup "false"    # branch preserved
fi
QG_RETRY_COUNT=0
```

---

## Configuration Changes

### `lib/enable_core.sh` — `.ralphrc` template

Add these four lines to the generated `.ralphrc`:
```bash
# Pull Request settings
PR_ENABLED=true          # false = revert to old direct-merge behaviour
PR_BASE_BRANCH=""        # empty = auto-detect from origin/HEAD; fallback: "main"
PR_DRAFT=false           # true = create PRs as GitHub Drafts
MAX_QG_RETRIES=3         # max quality gate retry loops before creating failure PR
```

### `codex/setup_codex.sh` — `.ralphrc.codex` template

Add the same four lines to the `.ralphrc.codex` template section.

### `devin/setup_devin.sh` — `.ralphrc.devin` template

Add the same four lines to the `.ralphrc.devin` template section.

**Unset variable defaults** (for existing projects without updated `.ralphrc`):
| Variable | Default when unset |
|---|---|
| `PR_ENABLED` | treated as `"true"` (PR flow active) |
| `PR_BASE_BRANCH` | auto-detected |
| `PR_DRAFT` | treated as `"false"` |
| `MAX_QG_RETRIES` | `3` |

Existing projects are not automatically updated. No migration script.

---

## Behaviour Matrix

| Scenario | Result |
|---|---|
| Quality gates pass on first try | `worktree_commit_and_pr(..., "true", ...)` → PR opened; branch preserved |
| Quality gates fail, retries remain | Worktree kept alive; Ralph loops again; no PR yet |
| Quality gates pass after retry | `worktree_commit_and_pr(..., "true", ...)` → PR opened |
| Quality gates fail, `MAX_QG_RETRIES` hit | `worktree_commit_and_pr(..., "false", ...)` → PR with `quality-gates-failed` label |
| Circuit breaker opens | `worktree_commit_and_pr(..., "false", ...)` → PR with `quality-gates-failed` label |
| `origin` remote missing | `RALPH_PR_PUSH_CAPABLE=false`; commit only; push skipped; no PR |
| `gh` not installed | `RALPH_PR_GH_CAPABLE=false`; commit + push; PR skipped |
| `gh` not authenticated | `RALPH_PR_GH_CAPABLE=false`; commit + push; PR skipped |
| PR already exists for branch | Log info; skip creation; new commits already included; add label if gates failed |
| `WORKTREE_ENABLED=false` | `worktree_fallback_branch_pr()` → temp branch → commit → push → PR |
| `PR_DRAFT=true` | PR created with `--draft` flag |
| `PR_ENABLED=false` | `worktree_merge()` called directly; no PR (old behaviour) |
| Commit fails | Log ERROR; `return 1`; caller calls `worktree_cleanup "false"`; loop continues |
| Push fails | Log ERROR; `return 1`; same caller behaviour |
| PR creation fails | Log ERROR; `return 1`; same caller behaviour |
| `quality-gates-failed` label missing in repo | Log WARN; skip label step; PR still created with failure details in body |
| Nothing to commit | Log INFO; proceed to push (not an error) |

---

## Files Changed

| File | Change |
|---|---|
| `lib/pr_manager.sh` | **New** — 4 functions: `pr_preflight_check`, `pr_build_title`, `pr_build_description`, `worktree_commit_and_pr`, `worktree_fallback_branch_pr` |
| `ralph_loop.sh` | `RALPH_ENGINE="claude"`, source pr_manager, preflight, QG counter, worktree re-use, replace merge block, non-worktree fallback, circuit-breaker PR |
| `codex/ralph_loop_codex.sh` | `RALPH_ENGINE="codex"`, same changes |
| `devin/ralph_loop_devin.sh` | `RALPH_ENGINE="devin"`, same changes |
| `lib/enable_core.sh` | Add 4 PR config lines to `.ralphrc` template |
| `codex/setup_codex.sh` | Add 4 PR config lines to `.ralphrc.codex` template |
| `devin/setup_devin.sh` | Add 4 PR config lines to `.ralphrc.devin` template |

---

## Out of Scope

- Updating existing `.ralphrc` files in already-enabled projects
- Auto-assigning reviewers to PRs
- PR auto-merge after review approval
- Creating the `quality-gates-failed` label in the repo automatically
