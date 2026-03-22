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
    # reason must be ≤35 chars to fit the box; callers must enforce this
    echo "║  Reason: ${reason}$(printf '%*s' $((37 - ${#reason})) '')║"
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

    else
        log_status "WARN" "PR skipped — gh not available. Branch committed and pushed: $_WT_CURRENT_BRANCH"
    fi

    # ── Step 4: Add failure label ────────────────────────────────────────────
    if [[ "$gate_passed" == "false" && "$RALPH_PR_GH_CAPABLE" == "true" ]]; then
        gh pr edit "$_WT_CURRENT_BRANCH" --add-label "quality-gates-failed" 2>/dev/null \
            || log_status "WARN" "Could not add 'quality-gates-failed' label (may not exist in repo)"
    fi

    return 0
}
