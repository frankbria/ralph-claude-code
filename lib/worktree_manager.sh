#!/usr/bin/env bash

# worktree_manager.sh - Git worktree lifecycle management for Ralph Claude
# Creates isolated worktrees per loop iteration, runs quality gates, merges on success.
#
# Lifecycle:
#   1. worktree_init()              - Validate git, compute paths, gitignore
#   2. worktree_create(loop, task)  - Create branch + worktree, sync .ralph/
#   3. [execute claude in worktree]
#   4. worktree_run_quality_gates() - Auto-detect and run lint/test/build
#   5. worktree_merge()             - Auto-commit + squash/merge/rebase to main
#   6. worktree_cleanup()           - Remove worktree, sync state back, prune
#
# Worktree path: <project_root>/<project_name>-worktrees/<task_id>/
#
# Version: 0.1.0

# Configuration (overridable from .ralphrc)
WORKTREE_ENABLED="${WORKTREE_ENABLED:-true}"
WORKTREE_MERGE_STRATEGY="${WORKTREE_MERGE_STRATEGY:-squash}"   # squash|merge|rebase
WORKTREE_QUALITY_GATES="${WORKTREE_QUALITY_GATES:-auto}"       # auto|none|"cmd1;cmd2"
WORKTREE_AUTO_CLEANUP="${WORKTREE_AUTO_CLEANUP:-true}"
WORKTREE_BRANCH_PREFIX="${WORKTREE_BRANCH_PREFIX:-ralph-claude}"
WORKTREE_AUTO_COMMIT="${WORKTREE_AUTO_COMMIT:-true}"

# Internal state
_WT_BASE_DIR=""
_WT_CURRENT_PATH=""
_WT_CURRENT_BRANCH=""
_WT_MAIN_BRANCH=""
_WT_PROJECT_NAME=""
_WT_MAIN_DIR=""

# =============================================================================
# INITIALIZATION
# =============================================================================

# Validate git repo, compute paths, ensure gitignore entry
# Must be called once before any other worktree functions
# Returns: 0 on success, 1 on error
worktree_init() {
    if [[ "$WORKTREE_ENABLED" != "true" ]]; then
        return 0
    fi

    if ! command -v git &>/dev/null; then
        echo "ERROR: git is not installed. Worktree mode requires git." >&2
        return 1
    fi

    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "ERROR: Not a git repository. Worktree mode requires git." >&2
        return 1
    fi

    # Ensure we're not already inside a worktree (prevent nesting)
    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    if [[ "$git_common_dir" != "$git_dir" && "$git_common_dir" != "." ]]; then
        echo "ERROR: Already inside a git worktree. Cannot nest worktrees." >&2
        return 1
    fi

    # Ensure working tree is clean enough to branch from
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo "WARN: Uncommitted changes in main working tree. Worktree will branch from current HEAD." >&2
    fi

    _WT_MAIN_DIR="$(pwd)"
    _WT_PROJECT_NAME=$(basename "$_WT_MAIN_DIR")

    # Detect main branch
    _WT_MAIN_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$_WT_MAIN_BRANCH" ]]; then
        _WT_MAIN_BRANCH=$(git config init.defaultBranch 2>/dev/null || echo "main")
    fi

    # Worktree base: ../<project_name>-worktrees/ (sibling to the project directory)
    _WT_BASE_DIR="$(cd "${_WT_MAIN_DIR}/.." && pwd)/${_WT_PROJECT_NAME}-worktrees"
    mkdir -p "$_WT_BASE_DIR"

    # No gitignore needed — worktrees dir is a sibling outside the project root

    return 0
}

# =============================================================================
# CREATE
# =============================================================================

# Create a new worktree + branch for a loop iteration
# Args:
#   $1 - loop_count: Current loop number
#   $2 - task_id: Optional task identifier (default: loop-<N>-<timestamp>)
# Outputs: Absolute path to the created worktree on stdout
# Returns: 0 on success, 1 on failure
worktree_create() {
    local loop_count=$1
    local task_id="${2:-loop-${loop_count}-$(date +%s)}"

    if [[ -z "$_WT_BASE_DIR" ]]; then
        echo "ERROR: worktree_init() must be called first" >&2
        return 1
    fi

    _WT_CURRENT_BRANCH="${WORKTREE_BRANCH_PREFIX}/${task_id}"
    _WT_CURRENT_PATH="${_WT_BASE_DIR}/${task_id}"

    # Clean up stale worktree at this path
    if [[ -d "$_WT_CURRENT_PATH" ]]; then
        git worktree remove "$_WT_CURRENT_PATH" --force 2>/dev/null || true
        rm -rf "$_WT_CURRENT_PATH" 2>/dev/null || true
    fi

    # Delete stale branch with same name
    if git show-ref --verify --quiet "refs/heads/${_WT_CURRENT_BRANCH}" 2>/dev/null; then
        git branch -D "$_WT_CURRENT_BRANCH" 2>/dev/null || true
    fi

    # Prune any dead worktree references
    git worktree prune 2>/dev/null || true

    # Create worktree with new branch off HEAD
    if ! git worktree add -b "$_WT_CURRENT_BRANCH" "$_WT_CURRENT_PATH" HEAD >/dev/null 2>&1; then
        echo "ERROR: Failed to create worktree at $_WT_CURRENT_PATH" >&2
        _WT_CURRENT_PATH=""
        _WT_CURRENT_BRANCH=""
        return 1
    fi

    # Sync entire .ralph/ directory into worktree (gitignored, so not in worktree by default)
    # Copy everything: specs/, docs/, constitution.md, PROMPT.md, fix_plan.md, AGENT.md, etc.
    # Without full context the AI agent may navigate back to the main project directory.
    if [[ -d "${_WT_MAIN_DIR}/.ralph" ]]; then
        cp -R "${_WT_MAIN_DIR}/.ralph" "$_WT_CURRENT_PATH/.ralph"
        # Ensure logs and docs dirs exist (may not be in source if empty)
        mkdir -p "$_WT_CURRENT_PATH/.ralph/logs"
        mkdir -p "$_WT_CURRENT_PATH/.ralph/docs/generated"
        # Clear stale state files that shouldn't carry over between worktrees
        rm -f "$_WT_CURRENT_PATH/.ralph/.call_count" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.last_reset" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.exit_signals" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.response_analysis" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.circuit_breaker_state" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.devin_session_id" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.codex_session_id" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/.claude_session_id" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/status.json" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/progress.json" 2>/dev/null
        rm -f "$_WT_CURRENT_PATH/.ralph/live.log" 2>/dev/null
    fi

    # Copy .ralphrc if present
    if [[ -f "${_WT_MAIN_DIR}/.ralphrc" ]]; then
        cp "${_WT_MAIN_DIR}/.ralphrc" "$_WT_CURRENT_PATH/.ralphrc"
    fi

    echo "$_WT_CURRENT_PATH"
    return 0
}

# =============================================================================
# ACCESSORS
# =============================================================================

worktree_get_path() {
    echo "${_WT_CURRENT_PATH:-}"
}

worktree_get_branch() {
    echo "${_WT_CURRENT_BRANCH:-}"
}

worktree_get_main_branch() {
    echo "${_WT_MAIN_BRANCH:-}"
}

worktree_get_base_dir() {
    echo "${_WT_BASE_DIR:-}"
}

worktree_is_active() {
    [[ -n "$_WT_CURRENT_PATH" && -d "$_WT_CURRENT_PATH" ]]
}

# =============================================================================
# QUALITY GATES
# =============================================================================

# Auto-detect quality gate commands from project files
# Args:
#   $1 - workdir: Directory to scan for project config
# Outputs: Semicolon-separated list of commands on stdout
_detect_quality_gates() {
    local workdir="${1:-.}"
    local gates=()

    if [[ -f "$workdir/package.json" ]]; then
        local pkg_manager="npm"
        if [[ -f "$workdir/pnpm-lock.yaml" ]]; then
            pkg_manager="pnpm"
        elif [[ -f "$workdir/bun.lockb" ]] || [[ -f "$workdir/bun.lock" ]]; then
            pkg_manager="bun"
        elif [[ -f "$workdir/yarn.lock" ]]; then
            pkg_manager="yarn"
        fi

        if jq -e '.scripts.lint' "$workdir/package.json" &>/dev/null; then
            gates+=("$pkg_manager run lint")
        fi
        if jq -e '.scripts.typecheck' "$workdir/package.json" &>/dev/null; then
            gates+=("$pkg_manager run typecheck")
        fi
        if jq -e '.scripts.test' "$workdir/package.json" &>/dev/null; then
            gates+=("$pkg_manager test")
        fi
        if jq -e '.scripts.build' "$workdir/package.json" &>/dev/null; then
            gates+=("$pkg_manager run build")
        fi
    fi

    # Python
    if [[ -f "$workdir/pyproject.toml" ]] || [[ -f "$workdir/pytest.ini" ]] || [[ -f "$workdir/setup.py" ]]; then
        if [[ -f "$workdir/pyproject.toml" ]] && grep -q "ruff" "$workdir/pyproject.toml" 2>/dev/null; then
            gates+=("ruff check .")
        fi
        gates+=("pytest")
    fi

    # Go
    if [[ -f "$workdir/go.mod" ]]; then
        gates+=("go vet ./...")
        gates+=("go test ./...")
    fi

    # Rust
    if [[ -f "$workdir/Cargo.toml" ]]; then
        gates+=("cargo clippy")
        gates+=("cargo test")
    fi

    # Makefile
    if [[ -f "$workdir/Makefile" ]]; then
        if grep -q "^lint:" "$workdir/Makefile" 2>/dev/null; then
            gates+=("make lint")
        fi
        if grep -q "^test:" "$workdir/Makefile" 2>/dev/null; then
            gates+=("make test")
        fi
    fi

    local IFS=";"
    echo "${gates[*]}"
}

# Run quality gates in the current worktree
# Returns: 0 if all pass, 1 if any fail
worktree_run_quality_gates() {
    local workdir="${_WT_CURRENT_PATH}"

    if [[ -z "$workdir" || ! -d "$workdir" ]]; then
        echo "ERROR: No active worktree for quality gates" >&2
        return 1
    fi

    if [[ "$WORKTREE_QUALITY_GATES" == "none" ]]; then
        echo "QUALITY_GATES: Skipped (disabled)" >&2
        return 0
    fi

    local gates_str
    if [[ "$WORKTREE_QUALITY_GATES" == "auto" ]]; then
        gates_str=$(_detect_quality_gates "$workdir")
        if [[ -z "$gates_str" ]]; then
            echo "QUALITY_GATES: No gates auto-detected, passing" >&2
            return 0
        fi
    else
        gates_str="$WORKTREE_QUALITY_GATES"
    fi

    echo "QUALITY_GATES: Running in $workdir" >&2

    local failed=0
    local passed=0
    local total=0
    local gate_results=""

    IFS=";" read -ra gate_cmds <<< "$gates_str"

    for cmd in "${gate_cmds[@]}"; do
        cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$cmd" ]] && continue

        total=$((total + 1))
        echo "QUALITY_GATE[$total]: $cmd" >&2

        local gate_output
        local gate_exit=0
        gate_output=$(cd "$workdir" && eval "$cmd" 2>&1) || gate_exit=$?

        if [[ $gate_exit -eq 0 ]]; then
            passed=$((passed + 1))
            echo "QUALITY_GATE[$total]: PASSED" >&2
            gate_results+="PASS: $cmd\n"
        else
            failed=$((failed + 1))
            echo "QUALITY_GATE[$total]: FAILED (exit $gate_exit)" >&2
            echo "QUALITY_GATE[$total]: Output: $(echo "$gate_output" | tail -5)" >&2
            gate_results+="FAIL: $cmd (exit $gate_exit)\n"
        fi
    done

    echo "QUALITY_GATES: $passed/$total passed, $failed failed" >&2

    # Write gate results to worktree .ralph for reference
    printf "%b" "$gate_results" > "$workdir/.ralph/.quality_gate_results" 2>/dev/null || true

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# AUTO-COMMIT
# =============================================================================

# Commit any uncommitted changes in the worktree
# Args:
#   $1 - message: Commit message
# Returns: 0 if committed or nothing to commit, 1 on error
worktree_auto_commit() {
    local message="${1:-ralph-claude: auto-commit work}"
    local workdir="$_WT_CURRENT_PATH"

    if [[ -z "$workdir" || ! -d "$workdir" ]]; then
        return 0
    fi

    (
        cd "$workdir" || return 1

        # Check for uncommitted changes
        if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
            return 0
        fi

        git add -A 2>/dev/null
        git commit -m "$message" 2>/dev/null
    )
}

# =============================================================================
# MERGE
# =============================================================================

# Merge worktree branch back to main branch
# Args:
#   $1 - strategy: Override merge strategy (optional, defaults to WORKTREE_MERGE_STRATEGY)
# Returns: 0 on success, 1 on failure
worktree_merge() {
    local strategy="${1:-$WORKTREE_MERGE_STRATEGY}"
    local branch="$_WT_CURRENT_BRANCH"
    local main_branch="$_WT_MAIN_BRANCH"
    local workdir="$_WT_CURRENT_PATH"

    if [[ -z "$branch" ]]; then
        echo "ERROR: No active worktree branch to merge" >&2
        return 1
    fi

    # Auto-commit any remaining uncommitted changes
    if [[ "$WORKTREE_AUTO_COMMIT" == "true" ]]; then
        worktree_auto_commit "ralph-claude: auto-commit from ${branch}" 2>/dev/null || true
    fi

    # Count commits ahead of main
    local ahead_count
    ahead_count=$(git rev-list --count "${main_branch}..${branch}" 2>/dev/null || echo "0")

    if [[ "$ahead_count" -eq 0 ]]; then
        echo "MERGE: No new commits on $branch, nothing to merge" >&2
        return 0
    fi

    echo "MERGE: $branch -> $main_branch ($strategy, $ahead_count commit(s))" >&2

    # Ensure we're on main branch in the main worktree
    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [[ "$current_branch" != "$main_branch" ]]; then
        git checkout "$main_branch" 2>/dev/null || {
            echo "ERROR: Could not switch to $main_branch for merge" >&2
            return 1
        }
    fi

    # Reset .ralph/fix_plan.md to HEAD to avoid merge conflicts caused by the
    # in-progress marker [~] written by pick_next_task before worktree creation.
    # worktree_cleanup will sync the updated fix_plan.md back from the worktree.
    if [[ -f ".ralph/fix_plan.md" ]] && ! git diff --quiet HEAD -- .ralph/fix_plan.md 2>/dev/null; then
        git checkout HEAD -- .ralph/fix_plan.md 2>/dev/null || true
    fi

    local merge_exit=0
    case "$strategy" in
        squash)
            git merge --squash "$branch" 2>/dev/null
            merge_exit=$?
            if [[ $merge_exit -eq 0 ]]; then
                git commit -m "ralph-claude: squash merge from ${branch} ($ahead_count commits)" 2>/dev/null
                merge_exit=$?
            fi
            ;;
        merge)
            git merge --no-ff "$branch" -m "ralph-claude: merge from ${branch}" 2>/dev/null
            merge_exit=$?
            ;;
        rebase)
            git rebase "$branch" 2>/dev/null
            merge_exit=$?
            ;;
        *)
            echo "ERROR: Unknown merge strategy: $strategy" >&2
            return 1
            ;;
    esac

    if [[ $merge_exit -ne 0 ]]; then
        echo "MERGE: FAILED - conflicts or errors. Aborting merge." >&2
        git merge --abort 2>/dev/null || true
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    echo "MERGE: Successfully merged $branch into $main_branch" >&2
    return 0
}

# =============================================================================
# CLEANUP
# =============================================================================

# Sync worktree state back to main project, remove worktree, optionally delete branch
# Args:
#   $1 - delete_branch: "true" to delete the branch, "false" to preserve it (default: WORKTREE_AUTO_CLEANUP)
# Returns: 0
worktree_cleanup() {
    local delete_branch="${1:-$WORKTREE_AUTO_CLEANUP}"
    local workdir="$_WT_CURRENT_PATH"
    local branch="$_WT_CURRENT_BRANCH"

    if [[ -z "$workdir" ]]; then
        return 0
    fi

    # Sync .ralph state back to main project (fix_plan.md may have been updated by claude)
    if [[ -f "$workdir/.ralph/fix_plan.md" ]]; then
        cp "$workdir/.ralph/fix_plan.md" "${_WT_MAIN_DIR}/.ralph/fix_plan.md" 2>/dev/null || true
    fi
    if [[ -f "$workdir/.ralph/AGENT.md" ]]; then
        cp "$workdir/.ralph/AGENT.md" "${_WT_MAIN_DIR}/.ralph/AGENT.md" 2>/dev/null || true
    fi

    # Copy quality gate results for reference
    if [[ -f "$workdir/.ralph/.quality_gate_results" ]]; then
        cp "$workdir/.ralph/.quality_gate_results" "${_WT_MAIN_DIR}/.ralph/.quality_gate_results" 2>/dev/null || true
    fi

    # Remove the worktree
    if [[ -d "$workdir" ]]; then
        git worktree remove "$workdir" --force 2>/dev/null || true
        if [[ -d "$workdir" ]]; then
            rm -rf "$workdir" 2>/dev/null || true
            git worktree prune 2>/dev/null || true
        fi
    fi

    # Delete the branch if auto-cleanup is enabled
    if [[ "$delete_branch" == "true" && -n "$branch" ]]; then
        git branch -D "$branch" 2>/dev/null || true
    fi

    _WT_CURRENT_PATH=""
    _WT_CURRENT_BRANCH=""

    return 0
}

# Remove all stale worktrees and prune
worktree_cleanup_all() {
    git worktree prune 2>/dev/null || true

    if [[ -n "$_WT_BASE_DIR" && -d "$_WT_BASE_DIR" ]]; then
        local count
        count=$(find "$_WT_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ "$count" -eq 0 ]]; then
            rmdir "$_WT_BASE_DIR" 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# STATUS / MONITORING
# =============================================================================

# Get worktree status as JSON for monitor integration
worktree_get_status() {
    local wt_active="false"
    if worktree_is_active; then
        wt_active="true"
    fi

    jq -n \
        --argjson enabled "$([ "$WORKTREE_ENABLED" = "true" ] && echo true || echo false)" \
        --argjson active "$wt_active" \
        --arg base_dir "${_WT_BASE_DIR:-}" \
        --arg current_path "${_WT_CURRENT_PATH:-}" \
        --arg current_branch "${_WT_CURRENT_BRANCH:-}" \
        --arg main_branch "${_WT_MAIN_BRANCH:-}" \
        --arg merge_strategy "$WORKTREE_MERGE_STRATEGY" \
        --arg quality_gates "$WORKTREE_QUALITY_GATES" \
        '{
            enabled: $enabled,
            active: $active,
            base_dir: $base_dir,
            current_path: $current_path,
            current_branch: $current_branch,
            main_branch: $main_branch,
            merge_strategy: $merge_strategy,
            quality_gates: $quality_gates
        }'
}
