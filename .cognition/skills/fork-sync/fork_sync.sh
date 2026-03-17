#!/usr/bin/env bash
# fork_sync.sh - Mechanical git operations for syncing a fork with upstream
#
# This script handles the non-AI parts of fork synchronization:
#   - Detecting the upstream (parent) repository
#   - Adding/verifying the upstream remote
#   - Fetching upstream changes
#   - Creating a sync branch
#   - Attempting the merge
#   - Detecting and reporting conflicts
#   - Final verification and commit (after AI resolves conflicts)
#
# Usage:
#   source fork_sync.sh              # Source for function access
#   fork_sync_detect_upstream        # Detect upstream repo
#   fork_sync_prepare <branch>       # Setup remote, fetch, create branch, merge
#   fork_sync_list_conflicts         # List conflicted files with line ranges
#   fork_sync_extract_conflict <file> <n>  # Extract Nth conflict from a file
#   fork_sync_verify_resolved        # Check no conflict markers remain
#   fork_sync_commit <message>       # Stage resolved files and commit
#   fork_sync_abort                  # Abort merge and delete sync branch
#
# Environment:
#   FORK_SYNC_UPSTREAM_BRANCH  - upstream branch to sync (default: main)
#   FORK_SYNC_LOCAL_BRANCH     - local branch to base sync on (default: main)
#   FORK_SYNC_BRANCH_NAME      - name for the sync branch (default: main-sync-fork)

set -euo pipefail

# Defaults
FORK_SYNC_UPSTREAM_BRANCH="${FORK_SYNC_UPSTREAM_BRANCH:-main}"
FORK_SYNC_LOCAL_BRANCH="${FORK_SYNC_LOCAL_BRANCH:-main}"
FORK_SYNC_BRANCH_NAME="${FORK_SYNC_BRANCH_NAME:-main-sync-fork}"

# Colors
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_NC='\033[0m'

# State
_UPSTREAM_OWNER=""
_UPSTREAM_REPO=""
_UPSTREAM_URL=""
_CONFLICTED_FILES=()
_ORIGINAL_BRANCH=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_info()  { echo -e "${_BLUE}[fork-sync]${_NC} $*"; }
_log_ok()    { echo -e "${_GREEN}[fork-sync]${_NC} $*"; }
_log_warn()  { echo -e "${_YELLOW}[fork-sync]${_NC} $*"; }
_log_err()   { echo -e "${_RED}[fork-sync]${_NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
fork_sync_check_prereqs() {
    local missing=()
    command -v git &>/dev/null || missing+=("git")
    command -v gh  &>/dev/null || missing+=("gh (GitHub CLI)")
    command -v jq  &>/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        _log_err "Missing required tools: ${missing[*]}"
        return 1
    fi

    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        _log_err "Not inside a git repository"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Detect upstream (parent) repository from GitHub fork metadata
# Sets _UPSTREAM_OWNER, _UPSTREAM_REPO, _UPSTREAM_URL
# ---------------------------------------------------------------------------
fork_sync_detect_upstream() {
    fork_sync_check_prereqs || return 1

    # If upstream remote already exists, use it directly
    if git remote get-url upstream &>/dev/null 2>&1; then
        _UPSTREAM_URL=$(git remote get-url upstream)
        # Extract owner/repo from URL
        local slug
        slug=$(echo "$_UPSTREAM_URL" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
        _UPSTREAM_OWNER=$(echo "$slug" | cut -d/ -f1)
        _UPSTREAM_REPO=$(echo "$slug" | cut -d/ -f2)
        _log_ok "Upstream remote already configured: ${_UPSTREAM_OWNER}/${_UPSTREAM_REPO}"
        echo "$_UPSTREAM_URL"
        return 0
    fi

    # Try gh repo view to detect fork parent
    # First try without explicit repo (works for most forks)
    local parent_json
    parent_json=$(gh repo view --json parent --jq '.parent' 2>/dev/null)

    # If that returns null, try with explicit owner/repo from origin
    if [[ -z "$parent_json" || "$parent_json" == "null" ]]; then
        local origin_url
        origin_url=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$origin_url" ]]; then
            local origin_slug
            origin_slug=$(echo "$origin_url" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
            parent_json=$(gh repo view "$origin_slug" --json parent --jq '.parent' 2>/dev/null)
        fi
    fi

    if [[ -z "$parent_json" || "$parent_json" == "null" ]]; then
        _log_err "This repo is not a fork, or GitHub CLI cannot determine the parent."
        _log_err "You can set the upstream manually:"
        _log_err "  git remote add upstream <url>"
        return 1
    fi

    _UPSTREAM_OWNER=$(echo "$parent_json" | jq -r '.owner.login')
    _UPSTREAM_REPO=$(echo "$parent_json" | jq -r '.name')
    _UPSTREAM_URL="https://github.com/${_UPSTREAM_OWNER}/${_UPSTREAM_REPO}.git"

    _log_ok "Detected upstream: ${_UPSTREAM_OWNER}/${_UPSTREAM_REPO}"
    echo "$_UPSTREAM_URL"
}

# ---------------------------------------------------------------------------
# Prepare: add remote, fetch, create branch, attempt merge
# Returns 0 if merge is clean, 1 if conflicts need resolution, 2 on error
# ---------------------------------------------------------------------------
fork_sync_prepare() {
    local sync_branch="${1:-$FORK_SYNC_BRANCH_NAME}"
    FORK_SYNC_BRANCH_NAME="$sync_branch"

    fork_sync_check_prereqs || return 2

    # Save current branch
    _ORIGINAL_BRANCH=$(git branch --show-current)

    # Ensure upstream remote exists
    if ! git remote get-url upstream &>/dev/null; then
        if [[ -z "$_UPSTREAM_URL" ]]; then
            fork_sync_detect_upstream || return 2
        fi
        _log_info "Adding upstream remote: $_UPSTREAM_URL"
        git remote add upstream "$_UPSTREAM_URL"
    else
        _UPSTREAM_URL=$(git remote get-url upstream)
        _log_info "Upstream remote already configured: $_UPSTREAM_URL"
    fi

    # Fetch upstream
    _log_info "Fetching upstream/${FORK_SYNC_UPSTREAM_BRANCH}..."
    git fetch upstream "$FORK_SYNC_UPSTREAM_BRANCH" || {
        _log_err "Failed to fetch upstream/${FORK_SYNC_UPSTREAM_BRANCH}"
        return 2
    }

    # Check if there are new commits
    local behind_count
    behind_count=$(git rev-list --count "${FORK_SYNC_LOCAL_BRANCH}..upstream/${FORK_SYNC_UPSTREAM_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind_count" -eq 0 ]]; then
        _log_ok "Already up to date with upstream/${FORK_SYNC_UPSTREAM_BRANCH}"
        return 0
    fi
    _log_info "$behind_count new commit(s) from upstream"

    # Create sync branch from local branch
    if git show-ref --verify --quiet "refs/heads/$sync_branch"; then
        _log_warn "Branch '$sync_branch' already exists. Deleting and recreating."
        git branch -D "$sync_branch" 2>/dev/null || true
    fi

    git checkout "$FORK_SYNC_LOCAL_BRANCH" 2>/dev/null || {
        _log_err "Cannot checkout ${FORK_SYNC_LOCAL_BRANCH}"
        return 2
    }
    git checkout -b "$sync_branch" || {
        _log_err "Cannot create branch $sync_branch"
        return 2
    }
    _log_ok "Created branch: $sync_branch"

    # Attempt merge
    _log_info "Merging upstream/${FORK_SYNC_UPSTREAM_BRANCH}..."
    if git merge "upstream/${FORK_SYNC_UPSTREAM_BRANCH}" --no-edit 2>/dev/null; then
        _log_ok "Merge completed cleanly! No conflicts."
        return 0
    else
        # Collect conflicted files
        mapfile -t _CONFLICTED_FILES < <(git diff --name-only --diff-filter=U)

        if [[ ${#_CONFLICTED_FILES[@]} -eq 0 ]]; then
            _log_err "Merge failed but no conflicted files detected"
            return 2
        fi

        _log_warn "Merge conflicts in ${#_CONFLICTED_FILES[@]} file(s):"
        for f in "${_CONFLICTED_FILES[@]}"; do
            local conflict_count
            conflict_count=$(grep -c '<<<<<<<' "$f" 2>/dev/null || echo "0")
            _log_warn "  $f ($conflict_count conflict region(s))"
        done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# List all conflicts as structured output (JSON-like for AI consumption)
# ---------------------------------------------------------------------------
fork_sync_list_conflicts() {
    echo "{"
    echo "  \"conflicted_files\": ["

    local first=true
    for file in "${_CONFLICTED_FILES[@]}"; do
        local conflict_count
        conflict_count=$(grep -c '<<<<<<<' "$file" 2>/dev/null || echo "0")

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo "    {"
        echo "      \"file\": \"$file\","
        echo "      \"conflict_regions\": $conflict_count,"
        echo "      \"conflict_lines\": ["

        # List line numbers of conflict markers
        local marker_first=true
        while IFS=: read -r line_num _; do
            if [[ "$marker_first" == "true" ]]; then
                marker_first=false
            else
                echo ","
            fi
            echo -n "        $line_num"
        done < <(grep -n '<<<<<<<' "$file" 2>/dev/null)

        echo ""
        echo "      ]"
        echo -n "    }"
    done

    echo ""
    echo "  ],"
    echo "  \"total_files\": ${#_CONFLICTED_FILES[@]},"
    echo "  \"total_conflicts\": $(grep -rl '<<<<<<<' "${_CONFLICTED_FILES[@]}" 2>/dev/null | xargs grep -c '<<<<<<<' 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
    echo "}"
}

# ---------------------------------------------------------------------------
# Extract the Nth conflict region from a file (1-indexed)
# Outputs: HEAD side, separator, upstream side with context
# ---------------------------------------------------------------------------
fork_sync_extract_conflict() {
    local file="$1"
    local n="${2:-1}"

    if [[ ! -f "$file" ]]; then
        _log_err "File not found: $file"
        return 1
    fi

    local count=0
    local in_conflict=false
    local section=""  # "head", "divider", "upstream"

    while IFS= read -r line; do
        if [[ "$line" =~ ^\<\<\<\<\<\<\< ]]; then
            count=$((count + 1))
            if [[ $count -eq $n ]]; then
                in_conflict=true
                section="head"
                echo "=== CONFLICT #$n in $file ==="
                echo "--- YOUR CHANGES (HEAD) ---"
                continue
            fi
        fi

        if [[ "$in_conflict" == "true" ]]; then
            if [[ "$line" =~ ^======= ]]; then
                section="upstream"
                echo "--- UPSTREAM CHANGES ---"
                continue
            elif [[ "$line" =~ ^\>\>\>\>\>\>\> ]]; then
                echo "=== END CONFLICT #$n ==="
                return 0
            else
                echo "$line"
            fi
        fi
    done < "$file"

    if [[ $count -lt $n ]]; then
        _log_err "Only $count conflict(s) in $file, requested #$n"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verify no conflict markers remain in any previously-conflicted file
# ---------------------------------------------------------------------------
fork_sync_verify_resolved() {
    local has_markers=false
    local files_to_check=("${_CONFLICTED_FILES[@]}")

    # Also check all staged files if no explicit list
    if [[ ${#files_to_check[@]} -eq 0 ]]; then
        mapfile -t files_to_check < <(git diff --cached --name-only)
    fi

    for file in "${files_to_check[@]}"; do
        if [[ -f "$file" ]] && grep -qE '<<<<<<<|>>>>>>>' "$file" 2>/dev/null; then
            _log_err "Unresolved conflict markers in: $file"
            grep -n '<<<<<<<\|=======\|>>>>>>>' "$file"
            has_markers=true
        fi
    done

    if [[ "$has_markers" == "true" ]]; then
        return 1
    fi

    _log_ok "All conflicts resolved - no markers remaining"
    return 0
}

# ---------------------------------------------------------------------------
# Stage all conflicted files and commit the merge
# ---------------------------------------------------------------------------
fork_sync_commit() {
    local message="${1:-"merge: sync ${FORK_SYNC_LOCAL_BRANCH} with upstream/${FORK_SYNC_UPSTREAM_BRANCH}"}"

    # Verify first
    fork_sync_verify_resolved || {
        _log_err "Cannot commit - unresolved conflicts remain"
        return 1
    }

    # Stage all previously-conflicted files
    for file in "${_CONFLICTED_FILES[@]}"; do
        git add "$file"
    done

    # Also stage any other files that were part of the merge
    git add -u

    git commit -m "$message" || {
        _log_err "Commit failed"
        return 1
    }

    _log_ok "Merge committed on branch: $FORK_SYNC_BRANCH_NAME"
    _log_info "To complete the sync:"
    _log_info "  1. Test your commands on this branch"
    _log_info "  2. git checkout ${FORK_SYNC_LOCAL_BRANCH} && git merge ${FORK_SYNC_BRANCH_NAME}"
    return 0
}

# ---------------------------------------------------------------------------
# Abort: cancel merge and return to original branch
# ---------------------------------------------------------------------------
fork_sync_abort() {
    git merge --abort 2>/dev/null || true

    if [[ -n "$_ORIGINAL_BRANCH" ]]; then
        git checkout "$_ORIGINAL_BRANCH" 2>/dev/null || true
    fi

    if git show-ref --verify --quiet "refs/heads/$FORK_SYNC_BRANCH_NAME"; then
        git branch -D "$FORK_SYNC_BRANCH_NAME" 2>/dev/null || true
        _log_info "Deleted branch: $FORK_SYNC_BRANCH_NAME"
    fi

    _log_ok "Merge aborted, returned to: ${_ORIGINAL_BRANCH:-original branch}"
}

# ---------------------------------------------------------------------------
# Generate a summary of what upstream changed (for AI context)
# ---------------------------------------------------------------------------
fork_sync_upstream_summary() {
    local commit_count
    commit_count=$(git rev-list --count "${FORK_SYNC_LOCAL_BRANCH}..upstream/${FORK_SYNC_UPSTREAM_BRANCH}" 2>/dev/null || echo "0")

    echo "## Upstream Changes Summary"
    echo ""
    echo "**Commits**: $commit_count new commit(s) from upstream/${FORK_SYNC_UPSTREAM_BRANCH}"
    echo ""
    echo "### Recent Commits (newest first)"
    echo '```'
    git log --oneline "${FORK_SYNC_LOCAL_BRANCH}..upstream/${FORK_SYNC_UPSTREAM_BRANCH}" 2>/dev/null | head -30
    echo '```'
    echo ""
    echo "### Files Changed"
    echo '```'
    git diff --stat "${FORK_SYNC_LOCAL_BRANCH}...upstream/${FORK_SYNC_UPSTREAM_BRANCH}" 2>/dev/null | tail -20
    echo '```'
}

# ---------------------------------------------------------------------------
# Generate structured conflict report for AI processing
# ---------------------------------------------------------------------------
fork_sync_conflict_report() {
    echo "## Conflict Report"
    echo ""
    echo "**Total conflicted files**: ${#_CONFLICTED_FILES[@]}"
    echo ""

    for file in "${_CONFLICTED_FILES[@]}"; do
        local conflict_count
        conflict_count=$(grep -c '<<<<<<<' "$file" 2>/dev/null || echo "0")
        echo "### $file ($conflict_count conflict region(s))"
        echo ""

        for ((i = 1; i <= conflict_count; i++)); do
            echo '```'
            fork_sync_extract_conflict "$file" "$i"
            echo '```'
            echo ""
        done
    done
}

# ---------------------------------------------------------------------------
# Main entry point (when run as a script, not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        detect)
            fork_sync_detect_upstream
            ;;
        prepare)
            fork_sync_prepare "${2:-$FORK_SYNC_BRANCH_NAME}"
            ;;
        conflicts)
            # Re-populate _CONFLICTED_FILES from git state
            mapfile -t _CONFLICTED_FILES < <(git diff --name-only --diff-filter=U 2>/dev/null)
            fork_sync_list_conflicts
            ;;
        report)
            mapfile -t _CONFLICTED_FILES < <(git diff --name-only --diff-filter=U 2>/dev/null)
            fork_sync_conflict_report
            ;;
        verify)
            mapfile -t _CONFLICTED_FILES < <(git diff --cached --name-only 2>/dev/null)
            fork_sync_verify_resolved
            ;;
        commit)
            fork_sync_commit "${2:-}"
            ;;
        abort)
            fork_sync_abort
            ;;
        summary)
            fork_sync_upstream_summary
            ;;
        help|*)
            echo "fork_sync.sh - Sync a GitHub fork with its upstream"
            echo ""
            echo "Commands:"
            echo "  detect    Detect the upstream (parent) repository"
            echo "  prepare   Add remote, fetch, create sync branch, attempt merge"
            echo "  conflicts List conflicts as JSON (for AI processing)"
            echo "  report    Generate human-readable conflict report"
            echo "  verify    Check that all conflicts are resolved"
            echo "  commit    Stage and commit the resolved merge"
            echo "  abort     Cancel the merge and clean up"
            echo "  summary   Show upstream changes summary"
            echo ""
            echo "Environment:"
            echo "  FORK_SYNC_UPSTREAM_BRANCH  upstream branch (default: main)"
            echo "  FORK_SYNC_LOCAL_BRANCH     local branch (default: main)"
            echo "  FORK_SYNC_BRANCH_NAME      sync branch name (default: main-sync-fork)"
            ;;
    esac
fi
