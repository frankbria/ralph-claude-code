# Ralph Auto-PR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At the end of every Ralph loop iteration, automatically commit the worktree branch, push it, and open a GitHub PR — replacing the current interactive merge prompt entirely.

**Architecture:** A new shared library `lib/pr_manager.sh` provides all PR logic (preflight checks, title/description builders, commit+push+PR function, non-worktree fallback). All three loop scripts (Claude, Codex, Devin) source this library and replace their merge prompt blocks with calls to `worktree_commit_and_pr`. Quality gate failures keep the worktree alive for retry loops; the circuit breaker or `MAX_QG_RETRIES` threshold triggers a failure PR.

**Tech Stack:** Bash, `git`, `gh` CLI (GitHub CLI), existing Ralph shell library conventions.

**Spec:** `docs/superpowers/specs/2026-03-22-ralph-auto-pr-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/pr_manager.sh` | **Create** | All PR logic: preflight, title, description, commit+push+PR, fallback |
| `tests/test_pr_manager.sh` | **Create** | Unit tests for all `pr_manager.sh` functions |
| `ralph_loop.sh` | **Modify** | Add `RALPH_ENGINE`, source pr_manager, preflight, QG retry counter, worktree re-use, replace merge block, fallback, circuit-breaker PR |
| `codex/ralph_loop_codex.sh` | **Modify** | Same 8 changes as above (`RALPH_ENGINE="codex"`) |
| `devin/ralph_loop_devin.sh` | **Modify** | Same 8 changes as above (`RALPH_ENGINE="devin"`) |
| `lib/enable_core.sh` | **Modify** | Add 4 PR config lines to `generate_ralphrc()` heredoc |
| `codex/setup_codex.sh` | **Modify** | Add 4 PR config lines to `.ralphrc.codex` heredoc |
| `devin/setup_devin.sh` | **Modify** | Add 4 PR config lines to `.ralphrc.devin` heredoc |

---

## Task 1: Create `lib/pr_manager.sh` skeleton + `pr_preflight_check` + `pr_build_title`

**Files:**
- Create: `lib/pr_manager.sh`
- Create: `tests/test_pr_manager.sh`

- [ ] **Step 1.1: Write failing tests for `pr_preflight_check` and `pr_build_title`**

Create `tests/test_pr_manager.sh`:

```bash
#!/bin/bash
# Tests for lib/pr_manager.sh
set -e

TESTS_PASSED=0
TESTS_FAILED=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local name="$1"; local expected="$2"; local actual="$3"
    echo -e "\n${YELLOW}Test: $name${NC}"
    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL — expected: '$expected', got: '$actual'${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ENGINE="claude"
RALPH_DIR=".ralph"

# Mock log_status so tests don't need the full loop environment
log_status() { :; }

source "$SCRIPT_DIR/../lib/pr_manager.sh"

# ── pr_preflight_check: gh missing ───────────────────────────────────────────
(
    # Override command to simulate gh missing
    command() { [[ "$2" == "gh" ]] && return 1; builtin command "$@"; }
    git() { return 0; }
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    run_test "gh missing sets GH_CAPABLE=false" "false" "$RALPH_PR_GH_CAPABLE"
)

# ── pr_preflight_check: all present (mocked) ─────────────────────────────────
(
    command() { return 0; }
    git() { return 0; }
    gh() { return 0; }
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    run_test "all present sets PUSH_CAPABLE=true" "true" "$RALPH_PR_PUSH_CAPABLE"
    run_test "all present sets GH_CAPABLE=true"   "true" "$RALPH_PR_GH_CAPABLE"
)

# ── pr_build_title ────────────────────────────────────────────────────────────
run_test "both non-empty" \
    "ralph: Fix login bug [TASK-42]" \
    "$(pr_build_title "TASK-42" "Fix login bug")"

run_test "empty task_name" \
    "ralph: task [TASK-42]" \
    "$(pr_build_title "TASK-42" "")"

run_test "both empty falls back to branch" \
    "ralph: automated work [$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')]" \
    "$(pr_build_title "" "")"

# 73-char title — should be truncated to 69 + "..."
long_name="$(printf 'A%.0s' {1..70})"
title_out="$(pr_build_title "T-1" "$long_name")"
run_test "title truncated to 72 chars" "72" "${#title_out}"
run_test "title ends with ..." "..." "${title_out: -3}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
[[ $TESTS_FAILED -eq 0 ]]
```

- [ ] **Step 1.2: Run tests to confirm they fail (pr_manager.sh does not exist yet)**

```bash
bash tests/test_pr_manager.sh
```
Expected: error `lib/pr_manager.sh: No such file`

- [ ] **Step 1.3: Create `lib/pr_manager.sh` with skeleton + `pr_preflight_check` + `pr_build_title`**

Create `lib/pr_manager.sh`:

```bash
#!/usr/bin/env bash
# pr_manager.sh — PR lifecycle management for Ralph (all variants)
# Provides: pr_preflight_check, pr_build_title, pr_build_description,
#           worktree_commit_and_pr, worktree_fallback_branch_pr
#
# Prerequisites: sourced AFTER worktree_manager.sh and .ralphrc in each loop script.
# Globals read from environment:
#   _WT_CURRENT_PATH, _WT_CURRENT_BRANCH, _WT_MAIN_DIR  (from worktree_manager.sh)
#   RALPH_DIR, RALPH_ENGINE                              (from loop script)
#   PR_ENABLED, PR_BASE_BRANCH, PR_DRAFT                 (from .ralphrc)
#   MAX_QG_RETRIES                                       (from .ralphrc)
#
# Globals set by this library:
#   RALPH_PR_PUSH_CAPABLE=true|false
#   RALPH_PR_GH_CAPABLE=true|false

# Default exports
RALPH_PR_PUSH_CAPABLE="${RALPH_PR_PUSH_CAPABLE:-false}"
RALPH_PR_GH_CAPABLE="${RALPH_PR_GH_CAPABLE:-false}"

# ── Helpers ───────────────────────────────────────────────────────────────────

_pr_warn_block() {
    local reason="$1"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  WARNING: PR CREATION DISABLED                       ║"
    echo "║  Reason: ${reason}$(printf '%*s' $((36 - ${#reason})) '')║"
    echo "║  Ralph will commit and push branches only.           ║"
    echo "╚══════════════════════════════════════════════════════╝"
}

# ── pr_preflight_check ────────────────────────────────────────────────────────
# Check git remote, gh CLI, gh auth. Sets RALPH_PR_PUSH_CAPABLE and
# RALPH_PR_GH_CAPABLE. Always returns 0.
pr_preflight_check() {
    RALPH_PR_PUSH_CAPABLE="true"
    RALPH_PR_GH_CAPABLE="true"

    # Check 1: git origin remote
    if ! git remote get-url origin &>/dev/null; then
        _pr_warn_block "No git remote named 'origin'"
        log_status "WARN" "PR: No git remote 'origin' — push and PR disabled"
        RALPH_PR_PUSH_CAPABLE="false"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    # Check 2: gh CLI installed
    if ! command -v gh &>/dev/null; then
        _pr_warn_block "gh CLI not found"
        log_status "WARN" "PR: gh CLI not found — install from https://cli.github.com"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    # Check 3: gh authenticated
    if ! gh auth status &>/dev/null; then
        _pr_warn_block "gh not authenticated"
        log_status "WARN" "PR: gh is not authenticated — run: gh auth login"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    log_status "INFO" "PR preflight: all checks passed (push=true, gh=true)"
    return 0
}

# ── pr_build_title ────────────────────────────────────────────────────────────
# Args: $1=task_id  $2=task_name
# Prints PR title to stdout. Always returns 0.
pr_build_title() {
    local task_id="$1"
    local task_name="$2"
    local title

    if [[ -n "$task_id" && -n "$task_name" ]]; then
        title="ralph: ${task_name} [${task_id}]"
    elif [[ -n "$task_id" ]]; then
        title="ralph: task [${task_id}]"
    else
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        title="ralph: automated work [${branch}]"
    fi

    # Truncate to 72 chars: keep first 69, append "..."
    if [[ ${#title} -gt 72 ]]; then
        title="${title:0:69}..."
    fi

    echo "$title"
    return 0
}
```

- [ ] **Step 1.4: Run tests — verify `pr_preflight_check` and `pr_build_title` pass**

```bash
bash tests/test_pr_manager.sh
```
Expected: all tests pass, `0 failed`

- [ ] **Step 1.5: Commit**

```bash
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "feat(pr): add pr_manager.sh skeleton with pr_preflight_check and pr_build_title"
```

---

## Task 2: Add `pr_build_description` to `lib/pr_manager.sh`

**Files:**
- Modify: `lib/pr_manager.sh` (append function)
- Modify: `tests/test_pr_manager.sh` (append tests)

- [ ] **Step 2.1: Add failing tests for `pr_build_description`**

Append to `tests/test_pr_manager.sh` (before the Summary block):

```bash
# ── pr_build_description ──────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

GATE_FILE="$TEST_DIR/quality_gate_results"

# Test: file with PASS and FAIL lines
cat > "$GATE_FILE" << 'EOF'
PASS: npm run lint
FAIL: npm test (exit 1)
EOF

desc_out=$(pr_build_description "T-1" "Fix bug" "ralph-claude/T-1" "false" "$GATE_FILE" "3")

run_test "description contains task line" \
    "1" "$(echo "$desc_out" | grep -c "Task: Fix bug (T-1)")"

run_test "description contains branch line" \
    "1" "$(echo "$desc_out" | grep -c "Branch: ralph-claude/T-1")"

run_test "description contains PASS row" \
    "1" "$(echo "$desc_out" | grep -c "✅ PASS")"

run_test "description contains FAIL row" \
    "1" "$(echo "$desc_out" | grep -c "❌ FAIL")"

run_test "description contains Failures section when gate_passed=false" \
    "1" "$(echo "$desc_out" | grep -c "Quality Gate Failures")"

run_test "description contains loop number" \
    "1" "$(echo "$desc_out" | grep -c "loop #3")"

# Test: gate_passed=true — no Failures section
desc_pass=$(pr_build_description "T-1" "Fix bug" "ralph-claude/T-1" "true" "$GATE_FILE" "3")
run_test "no Failures section when gate_passed=true" \
    "0" "$(echo "$desc_pass" | grep -c "Quality Gate Failures")"

# Test: missing gate file
desc_nofile=$(pr_build_description "T-1" "Fix bug" "ralph-claude/T-1" "true" "/nonexistent/file" "1")
run_test "missing gate file shows fallback text" \
    "1" "$(echo "$desc_nofile" | grep -c "No quality gate data available")"

# Test: both task_id and task_name empty
desc_empty=$(pr_build_description "" "" "ralph-claude/run-1" "true" "/nonexistent/file" "1")
run_test "empty task_id and task_name omits Task line" \
    "0" "$(echo "$desc_empty" | grep -c "^Task:")"
```

- [ ] **Step 2.2: Run tests to confirm `pr_build_description` tests fail**

```bash
bash tests/test_pr_manager.sh
```
Expected: new `pr_build_description` tests fail with "command not found"

- [ ] **Step 2.3: Implement `pr_build_description` in `lib/pr_manager.sh`**

Append after `pr_build_title`:

```bash
# ── pr_build_description ──────────────────────────────────────────────────────
# Args: $1=task_id  $2=task_name  $3=branch  $4=gate_passed  $5=gate_results_file
#       $6=loop_count
# Prints Markdown PR body to stdout. Always returns 0.
pr_build_description() {
    local task_id="$1"
    local task_name="$2"
    local branch="$3"
    local gate_passed="$4"
    local gate_results_file="$5"
    local loop_count="$6"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local engine="${RALPH_ENGINE:-ralph}"

    # Summary section
    echo "## Summary"
    if [[ -n "$task_id" || -n "$task_name" ]]; then
        echo "Task: ${task_name:-unknown} (${task_id:-unknown})"
    fi
    echo "Branch: ${branch}"
    echo ""

    # Quality Gates section
    echo "## Quality Gates"
    if [[ -f "$gate_results_file" && -s "$gate_results_file" ]]; then
        echo "| Gate Command | Result |"
        echo "|---|---|"
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"   # ltrim
            line="${line%"${line##*[![:space:]]}"}"   # rtrim
            [[ -z "$line" ]] && continue
            if [[ "$line" == PASS:\ * ]]; then
                local cmd="${line#PASS: }"
                echo "| \`${cmd}\` | ✅ PASS |"
            elif [[ "$line" == FAIL:\ * ]]; then
                local rest="${line#FAIL: }"
                local cmd exit_code
                if [[ "$rest" =~ ^(.*)" (exit "([0-9]+)")" ]]; then
                    cmd="${BASH_REMATCH[1]}"
                    exit_code="${BASH_REMATCH[2]}"
                else
                    cmd="$rest"
                    exit_code="?"
                fi
                echo "| \`${cmd}\` | ❌ FAIL (exit ${exit_code}) |"
            else
                log_status "DEBUG" "Skipping unparseable gate result line: $line" 2>/dev/null || true
            fi
        done < "$gate_results_file"
    else
        echo "No quality gate data available."
    fi
    echo ""

    # Quality Gate Failures section (only when gates failed)
    if [[ "$gate_passed" == "false" ]]; then
        if [[ -f "$gate_results_file" && -s "$gate_results_file" ]]; then
            local has_failures=false
            while IFS= read -r line; do
                [[ "$line" == FAIL:\ * ]] && has_failures=true && break
            done < "$gate_results_file"

            if [[ "$has_failures" == "true" ]]; then
                echo "## Quality Gate Failures"
                echo "> ⚠️ The following gates failed and could not be resolved:"
                while IFS= read -r line; do
                    line="${line#"${line%%[![:space:]]*}"}"
                    [[ -z "$line" ]] && continue
                    if [[ "$line" == FAIL:\ * ]]; then
                        local rest="${line#FAIL: }"
                        local cmd exit_code
                        if [[ "$rest" =~ ^(.*)" (exit "([0-9]+)")" ]]; then
                            cmd="${BASH_REMATCH[1]}"
                            exit_code="${BASH_REMATCH[2]}"
                        else
                            cmd="$rest"; exit_code="?"
                        fi
                        echo "- \`${cmd}\` — exit code \`${exit_code}\`"
                    fi
                done < "$gate_results_file"
                echo ""
            fi
        fi
    fi

    echo "---"
    echo "🤖 Generated by Ralph [${engine}] loop #${loop_count} — ${timestamp}"
    return 0
}
```

- [ ] **Step 2.4: Run all tests — confirm all pass**

```bash
bash tests/test_pr_manager.sh
```
Expected: all tests pass, `0 failed`

- [ ] **Step 2.5: Commit**

```bash
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "feat(pr): add pr_build_description to pr_manager.sh"
```

---

## Task 3: Add `worktree_commit_and_pr` to `lib/pr_manager.sh`

**Files:**
- Modify: `lib/pr_manager.sh` (append function)
- Modify: `tests/test_pr_manager.sh` (append tests)

- [ ] **Step 3.1: Add failing tests for `worktree_commit_and_pr`**

Append to `tests/test_pr_manager.sh` before Summary block:

```bash
# ── worktree_commit_and_pr ────────────────────────────────────────────────────

# Setup: create a temp git repo as mock worktree
WT_DIR=$(mktemp -d)
WT_MAIN_DIR=$(mktemp -d)
cd "$WT_MAIN_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
touch README.md && git add . && git commit -q -m "init"

cd "$WT_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "work" > work.txt && git add . && git commit -q -m "initial work"

# Set globals that worktree_manager.sh would set
_WT_CURRENT_PATH="$WT_DIR"
_WT_CURRENT_BRANCH="ralph-claude/T-1-1234"
_WT_MAIN_DIR="$WT_MAIN_DIR"
RALPH_DIR=".ralph"
RALPH_PR_PUSH_CAPABLE="false"   # no real remote in test
RALPH_PR_GH_CAPABLE="false"
PR_ENABLED="true"
PR_BASE_BRANCH="main"
PR_DRAFT="false"
RALPH_ENGINE="claude"

# Add uncommitted changes to test auto-commit
echo "new work" >> "$WT_DIR/work.txt"

worktree_commit_and_pr "T-1" "Fix login" "true" "5"
wcp_result=$?

run_test "worktree_commit_and_pr succeeds (no push/PR in test)" "0" "$wcp_result"

# Verify commit was made in worktree
commit_count=$(cd "$WT_DIR" && git log --oneline | wc -l | tr -d ' ')
run_test "auto-commit created a commit" "2" "$commit_count"

# Test: PR_ENABLED=false calls worktree_merge (mock it)
worktree_merge() { echo "merge_called"; }
PR_ENABLED="false"
merge_out=$(worktree_commit_and_pr "T-1" "Fix login" "true" "5" 2>/dev/null)
run_test "PR_ENABLED=false calls worktree_merge" "1" "$(echo "$merge_out" | grep -c "merge_called")"
PR_ENABLED="true"
unset -f worktree_merge

# Test: nothing to commit — should still return 0
PR_ENABLED="true"
worktree_commit_and_pr "T-1" "Fix login" "true" "6"
run_test "nothing to commit still returns 0" "0" "$?"

cd "$SCRIPT_DIR/.."   # return to project root
rm -rf "$WT_DIR" "$WT_MAIN_DIR"
```

- [ ] **Step 3.2: Run tests to confirm new tests fail**

```bash
bash tests/test_pr_manager.sh
```
Expected: `worktree_commit_and_pr` tests fail

- [ ] **Step 3.3: Implement `worktree_commit_and_pr` in `lib/pr_manager.sh`**

Append after `pr_build_description`:

```bash
# ── worktree_commit_and_pr ────────────────────────────────────────────────────
# Commit work in current worktree, push branch, open PR.
# Args: $1=task_id  $2=task_name  $3=gate_passed("true"|"false")  $4=loop_count
# Returns: 0 on success or intentional skip; 1 on commit/push/PR failure.
worktree_commit_and_pr() {
    local task_id="$1"
    local task_name="$2"
    local gate_passed="$3"
    local loop_count="$4"

    # Honour PR_ENABLED=false — revert to old merge behaviour
    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        worktree_merge
        return $?
    fi

    # Resolve PR base branch
    local base_branch="${PR_BASE_BRANCH:-}"
    if [[ -z "$base_branch" ]]; then
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                      | sed 's@^refs/remotes/origin/@@')
    fi
    if [[ -z "$base_branch" ]]; then
        base_branch="main"
    fi
    log_status "INFO" "PR base branch: $base_branch"

    # ── Step 1: Auto-commit in worktree ──────────────────────────────────────
    (
        cd "$_WT_CURRENT_PATH" || { log_status "ERROR" "Cannot cd to worktree: $_WT_CURRENT_PATH"; exit 1; }
        if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
            git add -A 2>/dev/null
            if ! git commit -m "ralph-${RALPH_ENGINE:-ralph}: auto-commit run #${loop_count}" 2>/dev/null; then
                log_status "ERROR" "Commit failed in worktree $_WT_CURRENT_PATH"
                exit 1
            fi
            log_status "INFO" "Changes committed to $_WT_CURRENT_BRANCH"
        else
            log_status "INFO" "Nothing to commit in worktree — proceeding to push"
        fi
    )
    local commit_result=$?
    if [[ $commit_result -ne 0 ]]; then return 1; fi

    # ── Step 2: Push branch ──────────────────────────────────────────────────
    if [[ "$RALPH_PR_PUSH_CAPABLE" != "true" ]]; then
        log_status "WARN" "Push skipped — no git remote. Branch: $_WT_CURRENT_BRANCH"
    else
        (
            cd "$_WT_MAIN_DIR" || exit 1
            if ! git push origin "$_WT_CURRENT_BRANCH" --set-upstream 2>/dev/null; then
                log_status "ERROR" "Push failed for $_WT_CURRENT_BRANCH"
                exit 1
            fi
            log_status "SUCCESS" "Branch pushed: $_WT_CURRENT_BRANCH"
        )
        local push_result=$?
        if [[ $push_result -ne 0 ]]; then return 1; fi
    fi

    # ── Step 3: Create PR ────────────────────────────────────────────────────
    if [[ "$RALPH_PR_GH_CAPABLE" == "true" && "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        local existing_pr
        existing_pr=$(gh pr view "$_WT_CURRENT_BRANCH" --json url --jq '.url' 2>/dev/null)
        if [[ -n "$existing_pr" ]]; then
            log_status "INFO" "PR already exists for $_WT_CURRENT_BRANCH: $existing_pr. Skipping creation."
        else
            local pr_title pr_body
            pr_title=$(pr_build_title "$task_id" "$task_name")
            pr_body=$(pr_build_description "$task_id" "$task_name" "$_WT_CURRENT_BRANCH" \
                      "$gate_passed" "$_WT_CURRENT_PATH/.ralph/.quality_gate_results" "$loop_count")

            local gh_args=(--base "$base_branch" --head "$_WT_CURRENT_BRANCH" \
                           --title "$pr_title" --body "$pr_body")
            [[ "${PR_DRAFT:-false}" == "true" ]] && gh_args+=(--draft)

            local pr_url
            pr_url=$(gh pr create "${gh_args[@]}" 2>&1)
            if [[ $? -ne 0 ]]; then
                log_status "ERROR" "PR creation failed: $pr_url"
                return 1
            fi
            log_status "SUCCESS" "PR created: $pr_url"
        fi

        # ── Step 4: Add failure label ────────────────────────────────────────
        if [[ "$gate_passed" == "false" ]]; then
            gh pr edit "$_WT_CURRENT_BRANCH" --add-label "quality-gates-failed" 2>/dev/null \
                || log_status "WARN" "Could not add 'quality-gates-failed' label (may not exist in repo)"
        fi
    else
        log_status "WARN" "PR skipped — gh not available. Branch committed and pushed: $_WT_CURRENT_BRANCH"
    fi

    return 0
}
```

- [ ] **Step 3.4: Run all tests**

```bash
bash tests/test_pr_manager.sh
```
Expected: all tests pass, `0 failed`

- [ ] **Step 3.5: Commit**

```bash
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "feat(pr): add worktree_commit_and_pr to pr_manager.sh"
```

---

## Task 4: Add `worktree_fallback_branch_pr` to `lib/pr_manager.sh`

**Files:**
- Modify: `lib/pr_manager.sh` (append function)
- Modify: `tests/test_pr_manager.sh` (append tests)

- [ ] **Step 4.1: Add failing tests for `worktree_fallback_branch_pr`**

Append to `tests/test_pr_manager.sh` before Summary block:

```bash
# ── worktree_fallback_branch_pr ───────────────────────────────────────────────

FB_DIR=$(mktemp -d)
cd "$FB_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > file.txt
git add . && git commit -q -m "init"

# Add uncommitted changes
echo "new work" >> file.txt

RALPH_ENGINE="claude"
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
PR_ENABLED="true"

worktree_fallback_branch_pr "T-2" "Add feature" "7"
fb_result=$?

run_test "worktree_fallback_branch_pr returns 0" "0" "$fb_result"

# Confirm a branch matching the pattern was created
branch_count=$(git branch | grep -c "ralph-claude/T-2" || echo "0")
run_test "fallback branch created" "1" "$branch_count"

# Confirm a commit was made on that branch (2 commits: init + auto-commit)
commit_count=$(git log --oneline | wc -l | tr -d ' ')
run_test "fallback branch has 2 commits" "2" "$commit_count"

cd "$SCRIPT_DIR/.."
rm -rf "$FB_DIR"
```

- [ ] **Step 4.2: Run tests to confirm new tests fail**

```bash
bash tests/test_pr_manager.sh
```
Expected: fallback tests fail with "command not found"

- [ ] **Step 4.3: Implement `worktree_fallback_branch_pr` in `lib/pr_manager.sh`**

Append after `worktree_commit_and_pr`:

```bash
# ── worktree_fallback_branch_pr ───────────────────────────────────────────────
# Used when WORKTREE_ENABLED=false. Creates a temp branch, commits, pushes, opens PR.
# Args: $1=task_id  $2=task_name  $3=loop_count
# Returns: 0 on success or intentional skip; 1 on failure.
worktree_fallback_branch_pr() {
    local task_id="$1"
    local task_name="$2"
    local loop_count="$3"
    local engine="${RALPH_ENGINE:-ralph}"
    local FALLBACK_BRANCH="ralph-${engine}/${task_id:-run}-$(date +%s)"

    # Honour PR_ENABLED=false
    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        log_status "INFO" "PR_ENABLED=false — skipping fallback branch PR"
        return 0
    fi

    # ── Step 1: Stash uncommitted changes ────────────────────────────────────
    local stash_was_empty=false
    local stash_output
    stash_output=$(git stash 2>&1)
    local stash_exit=$?
    if echo "$stash_output" | grep -q "No local changes to save"; then
        stash_was_empty=true
    elif [[ $stash_exit -ne 0 ]]; then
        log_status "ERROR" "git stash failed (exit $stash_exit): $stash_output"
        return 1
    fi

    # ── Step 2: Create and checkout fallback branch ──────────────────────────
    if ! git checkout -b "$FALLBACK_BRANCH" 2>/dev/null; then
        [[ "$stash_was_empty" == "false" ]] && git stash pop 2>/dev/null
        log_status "ERROR" "Failed to create fallback branch: $FALLBACK_BRANCH"
        return 1
    fi

    # ── Step 3: Pop stash ────────────────────────────────────────────────────
    if [[ "$stash_was_empty" == "false" ]]; then
        if ! git stash pop 2>/dev/null; then
            log_status "ERROR" "git stash pop failed. Work is saved in stash."
            return 1
        fi
    fi

    # ── Step 4: Commit ───────────────────────────────────────────────────────
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A 2>/dev/null
        if ! git commit -m "ralph-${engine}: auto-commit run #${loop_count}" 2>/dev/null; then
            log_status "ERROR" "Commit failed on fallback branch $FALLBACK_BRANCH"
            return 1
        fi
    else
        log_status "WARN" "Nothing to commit on fallback branch $FALLBACK_BRANCH"
    fi

    # Resolve base branch
    local base_branch="${PR_BASE_BRANCH:-}"
    if [[ -z "$base_branch" ]]; then
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                      | sed 's@^refs/remotes/origin/@@')
    fi
    [[ -z "$base_branch" ]] && base_branch="main"

    # ── Step 5: Push ─────────────────────────────────────────────────────────
    if [[ "$RALPH_PR_PUSH_CAPABLE" != "true" ]]; then
        log_status "WARN" "Push skipped — no git remote. Branch: $FALLBACK_BRANCH"
    else
        if ! git push origin "$FALLBACK_BRANCH" --set-upstream 2>/dev/null; then
            log_status "ERROR" "Push failed for $FALLBACK_BRANCH"
            return 1
        fi
        log_status "SUCCESS" "Fallback branch pushed: $FALLBACK_BRANCH"
    fi

    # ── Steps 6–7: Create PR + label ─────────────────────────────────────────
    if [[ "$RALPH_PR_GH_CAPABLE" == "true" && "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        local existing_pr
        existing_pr=$(gh pr view "$FALLBACK_BRANCH" --json url --jq '.url' 2>/dev/null)
        if [[ -n "$existing_pr" ]]; then
            log_status "INFO" "PR already exists for $FALLBACK_BRANCH: $existing_pr"
        else
            local pr_title pr_body
            pr_title=$(pr_build_title "$task_id" "$task_name")
            pr_body=$(pr_build_description "$task_id" "$task_name" "$FALLBACK_BRANCH" \
                      "true" "${RALPH_DIR}/.quality_gate_results" "$loop_count")
            local gh_args=(--base "$base_branch" --head "$FALLBACK_BRANCH" \
                           --title "$pr_title" --body "$pr_body")
            [[ "${PR_DRAFT:-false}" == "true" ]] && gh_args+=(--draft)
            local pr_url
            pr_url=$(gh pr create "${gh_args[@]}" 2>&1)
            if [[ $? -ne 0 ]]; then
                log_status "ERROR" "Fallback PR creation failed: $pr_url"
                return 1
            fi
            log_status "SUCCESS" "Fallback PR created: $pr_url"
        fi
    else
        log_status "WARN" "Fallback PR skipped — gh not available. Branch: $FALLBACK_BRANCH"
    fi

    return 0
}
```

- [ ] **Step 4.4: Run all tests**

```bash
bash tests/test_pr_manager.sh
```
Expected: all tests pass, `0 failed`

- [ ] **Step 4.5: Commit**

```bash
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "feat(pr): add worktree_fallback_branch_pr to pr_manager.sh"
```

---

## Task 5: Update `ralph_loop.sh` (Claude variant)

**Files:**
- Modify: `ralph_loop.sh`

This task applies all 8 spec changes to the Claude loop. Make each edit precisely by matching the unique surrounding context.

- [ ] **Step 5.1: Add `RALPH_ENGINE` declaration**

In `ralph_loop.sh`, find the block starting at line ~22 that sets `RALPH_DIR`:

```bash
# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
```

Insert one line after `RALPH_DIR=".ralph"`:
```bash
RALPH_ENGINE="claude"           # identifier used by pr_manager.sh
```

- [ ] **Step 5.2: Source `pr_manager.sh`**

Find the last existing `source` line (line ~20):
```bash
source "$SCRIPT_DIR/lib/worktree_manager.sh" || { echo "FATAL: Failed to source lib/worktree_manager.sh" >&2; exit 1; }
```
Add immediately after it:
```bash
source "$SCRIPT_DIR/lib/pr_manager.sh" || { echo "FATAL: Failed to source lib/pr_manager.sh" >&2; exit 1; }
```

- [ ] **Step 5.3: Add QG retry counter**

Find (around line 60):
```bash
MAX_LOOPS="${MAX_LOOPS:-0}"  # 0 = unlimited
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
```
Insert after `MAX_LOOPS` line:
```bash
QG_RETRY_COUNT=0
MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"
```

- [ ] **Step 5.4: Call `pr_preflight_check` after `worktree_init`**

Find (around line 1937):
```bash
    # Reset exit signals to prevent stale state from prior run causing premature exit (Issue #194)
```
Insert before that line:
```bash
    # Run PR preflight checks once before entering the loop
    pr_preflight_check
```

- [ ] **Step 5.5: Update worktree creation block to support QG retry re-use**

Find and replace this exact block (around line 2086):
```bash
        local work_dir
        work_dir="$(pwd)"
        if [[ "$WORKTREE_ENABLED" == "true" ]]; then
            local wt_task_id="${picked_task_id:-loop-${loop_count}-$(date +%s)}"
            if worktree_create "$loop_count" "$wt_task_id" > /dev/null; then
                work_dir="$(worktree_get_path)"
                log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
            else
                log_status "WARN" "Worktree creation failed, using main directory"
            fi
        fi
```

Replace with:
```bash
        local work_dir
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
                else
                    log_status "WARN" "Worktree creation failed, using main directory"
                fi
            fi
        fi
```

- [ ] **Step 5.6: Replace the merge prompt block with PR flow**

Find and replace this exact block (around lines 2136-2176):
```bash
                if [[ $gate_result -eq 0 ]]; then
                    log_status "SUCCESS" "Quality gates passed."
                    echo ""
                    echo -e "${GREEN}Quality gates passed for branch: $(worktree_get_branch)${NC}"
                    echo -e "Merge into $(worktree_get_main_branch)? (yes/no)"
                    local merge_answer=""
                    read -r merge_answer < /dev/tty 2>/dev/null || merge_answer="no"

                    if [[ "$merge_answer" == "yes" ]]; then
                        log_status "INFO" "User approved merge. Merging..."
                        local merge_output
                        merge_output=$(worktree_merge 2>&1)
                        local merge_result=$?
                        while IFS= read -r line; do [[ -n "$line" ]] && log_status "INFO" "$line"; done <<< "$merge_output"

                        if [[ $merge_result -eq 0 ]]; then
                            log_status "SUCCESS" "Merged $(worktree_get_branch) into $(worktree_get_main_branch)"
                            worktree_cleanup "true"
                            # Mark the picked task complete in fix_plan.md
                            if [[ -n "$picked_line_num" ]] && [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
                                mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
                            fi
                        else
                            log_status "ERROR" "Merge failed. Branch preserved: $(worktree_get_branch)"
                            worktree_cleanup "false"
                        fi
                    else
                        log_status "INFO" "Merge skipped by user. Branch preserved: $(worktree_get_branch)"
                        worktree_cleanup "false"
                    fi
                else
                    log_status "WARN" "Quality gates failed. Branch preserved: $(worktree_get_branch)"
                    worktree_cleanup "false"
                fi
```

Replace with:
```bash
                if [[ $gate_result -eq 0 ]]; then
                    # Quality gates passed — commit + push + open PR
                    log_status "SUCCESS" "Quality gates passed."
                    QG_RETRY_COUNT=0
                    worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "true" "$loop_count"
                    local pr_result=$?
                    worktree_cleanup "false"    # branch preserved as PR head; never deleted by Ralph
                    if [[ $pr_result -eq 0 ]]; then
                        if [[ -n "$picked_line_num" ]] && [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
                            mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
                        fi
                    else
                        log_status "ERROR" "PR workflow failed. Branch preserved for manual recovery: $(worktree_get_branch)"
                    fi
                else
                    # Quality gates failed — increment retry counter, keep worktree alive
                    QG_RETRY_COUNT=$((QG_RETRY_COUNT + 1))
                    log_status "WARN" "Quality gates failed (attempt $QG_RETRY_COUNT/$MAX_QG_RETRIES)."
                    if [[ $QG_RETRY_COUNT -ge $MAX_QG_RETRIES ]]; then
                        log_status "WARN" "Max QG retries reached. Creating PR with failure details."
                        worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count"
                        worktree_cleanup "false"    # branch preserved
                        QG_RETRY_COUNT=0
                    else
                        log_status "INFO" "Keeping worktree alive for QG retry in next loop iteration."
                        # do NOT call worktree_cleanup — worktree stays active for next iteration
                    fi
                fi
```

- [ ] **Step 5.7: Add non-worktree fallback**

Find the comment and line (around 2194-2198):
```bash
            # Beads post-sync: close completed beads
            if beads_sync_available; then
```

Insert before it:
```bash
            # Non-worktree PR: create branch + push + PR when not using worktrees
            if [[ "$WORKTREE_ENABLED" != "true" ]]; then
                worktree_fallback_branch_pr "$picked_task_id" "$picked_task_name" "$loop_count"
            fi
```

- [ ] **Step 5.8: Replace circuit breaker cleanup with PR-first cleanup**

Find and replace (around line 2217):
```bash
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            if worktree_is_active; then worktree_cleanup "true"; fi
```

Replace with:
```bash
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened — create failure PR before cleanup
            if worktree_is_active; then
                log_status "WARN" "Circuit breaker opened — creating failure PR before cleanup."
                worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count"
                worktree_cleanup "false"    # branch preserved
            fi
            QG_RETRY_COUNT=0
```

- [ ] **Step 5.9: Smoke-test `ralph_loop.sh` parses without errors**

```bash
bash -n ralph_loop.sh && echo "Syntax OK"
```
Expected: `Syntax OK`

- [ ] **Step 5.10: Commit**

```bash
git add ralph_loop.sh
git commit -m "feat(pr): update ralph_loop.sh — auto-PR replaces merge prompt"
```

---

## Task 6: Update `codex/ralph_loop_codex.sh` and `devin/ralph_loop_devin.sh`

**Files:**
- Modify: `codex/ralph_loop_codex.sh`
- Modify: `devin/ralph_loop_devin.sh`

Apply the same 8 changes as Task 5 to each variant. The patterns to find/replace are identical except:
- `RALPH_ENGINE="codex"` (codex) / `RALPH_ENGINE="devin"` (devin)
- `source` path uses `$RALPH_ROOT/lib/pr_manager.sh` (both codex and devin source from `$RALPH_ROOT/lib/`)
- Codex: `RALPH_ROOT` is defined near the top as `$(cd "$SCRIPT_DIR/.." && pwd)` — use that
- Codex circuit breaker line: `elif [[ $exec_result -eq 3 ]]; then` (note double brackets)
- Codex/devin merge block starts at ~line 1010 (within `run_loop` function); same replacement content

**For `codex/ralph_loop_codex.sh`:**

- [ ] **Step 6.1: Add `RALPH_ENGINE="codex"` after `RALPH_DIR=".ralph"` line**
- [ ] **Step 6.2: Source pr_manager after `source "$RALPH_ROOT/lib/parallel_spawn.sh"` line:**
  ```bash
  source "$RALPH_ROOT/lib/pr_manager.sh" || { echo "FATAL: Failed to source lib/pr_manager.sh" >&2; exit 1; }
  ```
- [ ] **Step 6.3: Add `QG_RETRY_COUNT=0` and `MAX_QG_RETRIES` after `MAX_LOOPS` line**
- [ ] **Step 6.4: Add `pr_preflight_check` call (after `worktree_init` block, before `while true; do`)**
- [ ] **Step 6.5: Replace worktree creation block with QG-retry-aware version (same code as Task 5.5)**
- [ ] **Step 6.6: Replace merge prompt block with PR flow (same code as Task 5.6)**
- [ ] **Step 6.7: Add non-worktree fallback (same code as Task 5.7)**
- [ ] **Step 6.8: Replace circuit breaker cleanup with PR-first**

  Note: codex and devin use `[[ ]]` (double brackets). Find and replace:
  ```bash
  elif [[ $exec_result -eq 3 ]]; then
      # Circuit breaker opened
      if worktree_is_active; then worktree_cleanup "true"; fi
  ```
  Replace with:
  ```bash
  elif [[ $exec_result -eq 3 ]]; then
      # Circuit breaker opened — create failure PR before cleanup
      if worktree_is_active; then
          log_status "WARN" "Circuit breaker opened — creating failure PR before cleanup."
          worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "$loop_count"
          worktree_cleanup "false"    # branch preserved
      fi
      QG_RETRY_COUNT=0
  ```
- [ ] **Step 6.9: Syntax check:**
  ```bash
  bash -n codex/ralph_loop_codex.sh && echo "Syntax OK"
  ```

**For `devin/ralph_loop_devin.sh`:**

- [ ] **Step 6.10: Repeat steps 6.1–6.8 with `RALPH_ENGINE="devin"`**
- [ ] **Step 6.11: Syntax check:**
  ```bash
  bash -n devin/ralph_loop_devin.sh && echo "Syntax OK"
  ```

- [ ] **Step 6.12: Commit**

```bash
git add codex/ralph_loop_codex.sh devin/ralph_loop_devin.sh
git commit -m "feat(pr): update codex and devin loop scripts — auto-PR replaces merge prompt"
```

---

## Task 7: Update config file templates

**Files:**
- Modify: `lib/enable_core.sh` (line ~757, inside `generate_ralphrc()` heredoc)
- Modify: `codex/setup_codex.sh` (line ~89, inside `.ralphrc.codex` heredoc)
- Modify: `devin/setup_devin.sh` (line ~65, inside `.ralphrc.devin` heredoc)

- [ ] **Step 7.1: Update `lib/enable_core.sh`**

In `generate_ralphrc()`, find:
```bash
# Auto-update Claude CLI at startup
CLAUDE_AUTO_UPDATE=true
RALPHRCEOF
```

Replace with:
```bash
# Auto-update Claude CLI at startup
CLAUDE_AUTO_UPDATE=true

# Pull Request settings
PR_ENABLED=true          # false = revert to old direct-merge behaviour
PR_BASE_BRANCH=""        # empty = auto-detect from origin/HEAD; fallback: "main"
PR_DRAFT=false           # true = create PRs as GitHub Drafts
MAX_QG_RETRIES=3         # max quality gate retry loops before creating failure PR
RALPHRCEOF
```

- [ ] **Step 7.2: Update `codex/setup_codex.sh`**

Find:
```bash
# Circuit breaker thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_OUTPUT_DECLINE_THRESHOLD=70
RALPHRCEOF
```

Replace with:
```bash
# Circuit breaker thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_OUTPUT_DECLINE_THRESHOLD=70

# Pull Request settings
PR_ENABLED=true
PR_BASE_BRANCH=""
PR_DRAFT=false
MAX_QG_RETRIES=3
RALPHRCEOF
```

- [ ] **Step 7.3: Update `devin/setup_devin.sh`**

Same find/replace pattern as Step 7.2 (same circuit breaker block appears in `.ralphrc.devin` heredoc).

- [ ] **Step 7.4: Syntax check all three files**

```bash
bash -n lib/enable_core.sh && echo "enable_core OK"
bash -n codex/setup_codex.sh && echo "setup_codex OK"
bash -n devin/setup_devin.sh && echo "setup_devin OK"
```
Expected: all three print `OK`

- [ ] **Step 7.5: Run full test suite**

```bash
bash tests/test_pr_manager.sh
bash tests/test_error_detection.sh
bash tests/test_stuck_loop_detection.sh
```
Expected: all pass

- [ ] **Step 7.6: Commit**

```bash
git add lib/enable_core.sh codex/setup_codex.sh devin/setup_devin.sh
git commit -m "feat(pr): add PR config knobs to all .ralphrc templates"
```

---

## Verification Checklist

After all tasks complete:

- [ ] `bash tests/test_pr_manager.sh` — all tests pass
- [ ] `bash -n ralph_loop.sh` — no syntax errors
- [ ] `bash -n codex/ralph_loop_codex.sh` — no syntax errors
- [ ] `bash -n devin/ralph_loop_devin.sh` — no syntax errors
- [ ] `bash -n lib/pr_manager.sh` — no syntax errors
- [ ] `bash tests/test_error_detection.sh` — existing tests unaffected
- [ ] `bash tests/test_stuck_loop_detection.sh` — existing tests unaffected
- [ ] `grep -c "Merge into.*yes/no" ralph_loop.sh` → `0` (merge prompt fully removed)
- [ ] `grep -c "Merge into.*yes/no" codex/ralph_loop_codex.sh` → `0`
- [ ] `grep -c "Merge into.*yes/no" devin/ralph_loop_devin.sh` → `0`
- [ ] `grep -c "worktree_commit_and_pr" ralph_loop.sh` → `2` (QG pass + circuit breaker)
- [ ] `grep "PR_ENABLED" lib/enable_core.sh` — present in generated template
