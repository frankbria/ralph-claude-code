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
    # reason must be ≤36 chars to fit the box; callers must enforce this
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
