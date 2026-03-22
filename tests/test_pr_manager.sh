#!/bin/bash
# Tests for lib/pr_manager.sh

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

# ── pr_preflight_check: no remote → both flags false ─────────────────────────
result=$(
    git() { return 1; }   # all git calls fail — simulates no remote
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    echo "PUSH=$RALPH_PR_PUSH_CAPABLE GH=$RALPH_PR_GH_CAPABLE"
)
push_val=$(echo "$result" | grep -o 'PUSH=[^ ]*' | cut -d= -f2)
gh_val=$(echo "$result"   | grep -o 'GH=[^ ]*'   | cut -d= -f2)
run_test "no remote sets PUSH_CAPABLE=false" "false" "$push_val"
run_test "no remote sets GH_CAPABLE=false"   "false" "$gh_val"

# ── pr_preflight_check: gh missing → only GH_CAPABLE false ───────────────────
result=$(
    git() { return 0; }
    command() { [[ "$2" == "gh" ]] && return 1; builtin command "$@"; }
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    echo "PUSH=$RALPH_PR_PUSH_CAPABLE GH=$RALPH_PR_GH_CAPABLE"
)
push_val=$(echo "$result" | grep -o 'PUSH=[^ ]*' | cut -d= -f2)
gh_val=$(echo "$result"   | grep -o 'GH=[^ ]*'   | cut -d= -f2)
run_test "gh missing sets GH_CAPABLE=false"    "false" "$gh_val"
run_test "gh missing leaves PUSH_CAPABLE=true" "true"  "$push_val"

# ── pr_preflight_check: gh not authenticated → only GH_CAPABLE false ─────────
result=$(
    git() { return 0; }
    command() { return 0; }  # gh exists
    gh() { [[ "$1" == "auth" ]] && return 1; return 0; }
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    echo "PUSH=$RALPH_PR_PUSH_CAPABLE GH=$RALPH_PR_GH_CAPABLE"
)
push_val=$(echo "$result" | grep -o 'PUSH=[^ ]*' | cut -d= -f2)
gh_val=$(echo "$result"   | grep -o 'GH=[^ ]*'   | cut -d= -f2)
run_test "gh not authed sets GH_CAPABLE=false"    "false" "$gh_val"
run_test "gh not authed leaves PUSH_CAPABLE=true" "true"  "$push_val"

# ── pr_preflight_check: all present (mocked) ─────────────────────────────────
result=$(
    git() { return 0; }
    command() { return 0; }
    gh() { return 0; }
    RALPH_PR_PUSH_CAPABLE=""
    RALPH_PR_GH_CAPABLE=""
    pr_preflight_check
    echo "PUSH=$RALPH_PR_PUSH_CAPABLE GH=$RALPH_PR_GH_CAPABLE"
)
push_val=$(echo "$result" | grep -o 'PUSH=[^ ]*' | cut -d= -f2)
gh_val=$(echo "$result"   | grep -o 'GH=[^ ]*'   | cut -d= -f2)
run_test "all present sets PUSH_CAPABLE=true" "true" "$push_val"
run_test "all present sets GH_CAPABLE=true"   "true" "$gh_val"

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

# Test: gate_passed=false but PASS-only gate file → no Failures section
cat > "$GATE_FILE" << 'EOF'
PASS: npm run lint
PASS: npm test
EOF
desc_fail_noerrors=$(pr_build_description "T-1" "Fix bug" "ralph-claude/T-1" "false" "$GATE_FILE" "2")
run_test "gate_passed=false with no FAIL lines omits Failures section" \
    "0" "$(echo "$desc_fail_noerrors" | grep -c "Quality Gate Failures")"

# Test: missing gate file
desc_nofile=$(pr_build_description "T-1" "Fix bug" "ralph-claude/T-1" "true" "/nonexistent/file" "1")
run_test "missing gate file shows fallback text" \
    "1" "$(echo "$desc_nofile" | grep -c "No quality gate data available")"

# Test: both task_id and task_name empty
desc_empty=$(pr_build_description "" "" "ralph-claude/run-1" "true" "/nonexistent/file" "1")
run_test "empty task_id and task_name omits Task line" \
    "0" "$(echo "$desc_empty" | grep -c "^Task:")"

# ── worktree_commit_and_pr ────────────────────────────────────────────────────

# Setup: create a temp git repo as mock worktree
WT_DIR=$(mktemp -d)
WT_MAIN_DIR=$(mktemp -d)
(
    cd "$WT_MAIN_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md && git add . && git commit -q -m "init"
)
(
    cd "$WT_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
)

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

# Test: PR_ENABLED=false propagates worktree_merge exit code
worktree_merge() { return 1; }
PR_ENABLED="false"
worktree_commit_and_pr "T-1" "Fix login" "true" "5"
run_test "PR_ENABLED=false propagates merge failure exit code" "1" "$?"
PR_ENABLED="true"
unset -f worktree_merge

# Test: nothing to commit — should still return 0
PR_ENABLED="true"
worktree_commit_and_pr "T-1" "Fix login" "true" "6"
run_test "nothing to commit still returns 0" "0" "$?"

rm -rf "$WT_DIR" "$WT_MAIN_DIR"

# Test: existing PR detected — creation skipped (idempotency)
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
# Set up temp dirs again for this test
WT_DIR2=$(mktemp -d)
(
    cd "$WT_DIR2"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
)
_WT_CURRENT_PATH="$WT_DIR2"
_WT_CURRENT_BRANCH="ralph-claude/T-1-1234"
_WT_MAIN_DIR="$WT_DIR2"
PR_ENABLED="true"
PR_BASE_BRANCH="main"
# Mock gh: pr view returns URL (PR exists), pr create must NOT be called
PR_CREATE_CALLED=0
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then echo "https://github.com/owner/repo/pull/42"; return 0; fi
    if [[ "$1" == "pr" && "$2" == "create" ]]; then PR_CREATE_CALLED=1; return 0; fi
    if [[ "$1" == "pr" && "$2" == "edit" ]]; then return 0; fi
    return 0
}
# Mock git push
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-1" "Fix login" "true" "7"
run_test "existing PR skips gh pr create" "0" "$PR_CREATE_CALLED"
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR2"

# Test: gh pr create failure → function returns 1
WT_DIR3=$(mktemp -d)
(
    cd "$WT_DIR3"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
)
_WT_CURRENT_PATH="$WT_DIR3"
_WT_CURRENT_BRANCH="ralph-claude/T-1-fail"
_WT_MAIN_DIR="$WT_DIR3"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then return 1; fi  # no existing PR
    if [[ "$1" == "pr" && "$2" == "create" ]]; then echo "error: API error"; return 1; fi
    return 0
}
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-1" "Fail test" "true" "1"
run_test "gh pr create failure returns 1" "1" "$?"
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR3"

# Test: gate_passed=false + GH_CAPABLE=true → quality-gates-failed label applied
WT_DIR4=$(mktemp -d)
(
    cd "$WT_DIR4"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
)
_WT_CURRENT_PATH="$WT_DIR4"
_WT_CURRENT_BRANCH="ralph-claude/T-1-gates"
_WT_MAIN_DIR="$WT_DIR4"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
PR_EDIT_LABEL_CALLED=0
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then echo "https://github.com/owner/repo/pull/99"; return 0; fi
    if [[ "$1" == "pr" && "$2" == "edit" && "$*" == *"quality-gates-failed"* ]]; then PR_EDIT_LABEL_CALLED=1; return 0; fi
    return 0
}
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-1" "Gates test" "false" "2"
run_test "gate_passed=false calls gh pr edit --add-label" "1" "$PR_EDIT_LABEL_CALLED"
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR4"

# ── worktree_fallback_branch_pr ───────────────────────────────────────────────

FB_DIR=$(mktemp -d)
(
    cd "$FB_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add . && git commit -q -m "init"
)

# Add uncommitted changes (in a subshell that exits back to original dir)
echo "new work" >> "$FB_DIR/file.txt"

# Set globals for test
_WT_CURRENT_PATH="$FB_DIR"   # not used by fallback fn, but set for consistency
RALPH_ENGINE="claude"
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
PR_ENABLED="true"
RALPH_DIR=".ralph"

# Run the fallback fn from within FB_DIR context
# The function operates in the current shell dir, so cd there first (in subshell)
fb_result=$(
    cd "$FB_DIR"
    worktree_fallback_branch_pr "T-2" "Add feature" "7"
    echo "EXIT:$?"
)
fb_exit=$(echo "$fb_result" | grep -o 'EXIT:[0-9]*' | cut -d: -f2)
run_test "worktree_fallback_branch_pr returns 0" "0" "$fb_exit"

# Confirm branch matching pattern was created
branch_count=$(cd "$FB_DIR" && git branch | grep -c "ralph-claude/T-2" || echo "0")
run_test "fallback branch created" "1" "$branch_count"

# Confirm 2 commits on the branch (init + auto-commit)
commit_count=$(cd "$FB_DIR" && git log --oneline | wc -l | tr -d ' ')
run_test "fallback branch has 2 commits" "2" "$commit_count"

rm -rf "$FB_DIR"

# Test: PR_ENABLED=false skips fallback branch PR
FB_DIR2=$(mktemp -d)
(
    cd "$FB_DIR2"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > f.txt && git add . && git commit -q -m "init"
    echo "work" >> f.txt
)
RALPH_ENGINE="claude"
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
PR_ENABLED="false"
fb2_result=$(cd "$FB_DIR2" && worktree_fallback_branch_pr "T-3" "Test" "1" "true"; echo "EXIT:$?")
fb2_exit=$(echo "$fb2_result" | grep -o 'EXIT:[0-9]*' | cut -d: -f2)
run_test "PR_ENABLED=false fallback returns 0" "0" "$fb2_exit"
# Confirm NO branch was created (still on original branch)
branch_count2=$(cd "$FB_DIR2" && git branch | grep -c "ralph-claude"; true)
run_test "PR_ENABLED=false creates no branch" "0" "$branch_count2"
PR_ENABLED="true"
rm -rf "$FB_DIR2"

# ── _pr_remote_to_web_url ─────────────────────────────────────────────────────

WEBURL_DIR=$(mktemp -d)
(
    cd "$WEBURL_DIR"
    git init -q
    git remote add origin "https://github.com/owner/repo.git"
)
https_result=$(cd "$WEBURL_DIR" && _pr_remote_to_web_url)
run_test "_pr_remote_to_web_url strips .git from HTTPS" "https://github.com/owner/repo" "$https_result"
rm -rf "$WEBURL_DIR"

WEBURL_DIR2=$(mktemp -d)
(
    cd "$WEBURL_DIR2"
    git init -q
    git remote add origin "git@github.com:owner/repo.git"
)
ssh_result=$(cd "$WEBURL_DIR2" && _pr_remote_to_web_url)
run_test "_pr_remote_to_web_url converts SSH to HTTPS" "https://github.com/owner/repo" "$ssh_result"
rm -rf "$WEBURL_DIR2"

# ── worktree_commit_and_pr: GH_CAPABLE=false prints compare URL ───────────────

CMP_DIR=$(mktemp -d)
(
    cd "$CMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "init"
    git remote add origin "https://github.com/owner/ralph-test.git"
)
_WT_CURRENT_PATH="$CMP_DIR"
_WT_CURRENT_BRANCH="ralph-claude/T-cmp"
_WT_MAIN_DIR="$CMP_DIR"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="false"
PR_ENABLED="true"
git() {
    if [[ "$1" == "push" ]]; then return 0
    elif [[ "$1" == "remote" && "$2" == "get-url" ]]; then echo "https://github.com/owner/ralph-test.git"; return 0
    fi
    command git "$@"
}
cmp_out=$(cd "$CMP_DIR" && worktree_commit_and_pr "T-cmp" "compare test" "true" "1")
unset -f git
contains_url=$(echo "$cmp_out" | grep -c "github.com/owner/ralph-test/compare" || echo "0")
run_test "GH_CAPABLE=false prints compare URL" "1" "$contains_url"
RALPH_PR_PUSH_CAPABLE="false"
rm -rf "$CMP_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
[[ $TESTS_FAILED -eq 0 ]]
