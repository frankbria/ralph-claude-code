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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
[[ $TESTS_FAILED -eq 0 ]]
