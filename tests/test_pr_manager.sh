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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
[[ $TESTS_FAILED -eq 0 ]]
