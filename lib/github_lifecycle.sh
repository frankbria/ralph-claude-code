#!/bin/bash
# GitHub Issue Lifecycle Management for Ralph (Issue #73)
#
# Closes the loop on GitHub issue workflows: posts progress comments during
# development, and on graceful completion generates a summary, creates a PR
# linked to the issue, opens follow-up issues for discovered TODOs, and closes
# the issue with optional labels.
#
# Design notes:
#   - Uses the `gh` CLI exclusively (consistent with ralph_import.sh /
#     ralph_queue.sh), NOT raw REST + GITHUB_TOKEN.
#   - State lives in $RALPH_DIR/.github_lifecycle_state (JSON), mutated through
#     a temp file + mv so a crashed jq never leaves half-written state — the
#     same convention as lib/queue_manager.sh / lib/circuit_breaker.sh.
#   - Every GitHub operation degrades gracefully: a failure (e.g. missing
#     permission) is logged and returns non-zero, but the orchestration helpers
#     always return 0 so the development loop never crashes on a lifecycle hiccup.

# Source date utilities for cross-platform ISO timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"
GITHUB_LIFECYCLE_STATE_FILE="${GITHUB_LIFECYCLE_STATE_FILE:-$RALPH_DIR/.github_lifecycle_state}"

# --- logging ----------------------------------------------------------------

# _lifecycle_log <level> <message>
# Prefer the main script's log_status() when available; otherwise fall back to
# stderr so the lib is usable (and testable) standalone.
_lifecycle_log() {
    local level="$1"
    local message="$2"
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "$message" >&2
    else
        echo "[$level] $message" >&2
    fi
}

# --- reference parsing ------------------------------------------------------

# parse_issue_reference <ref>
# Accepts: bare "42", "#42", "owner/repo#42", or a full issue URL.
# Prints "<number>\t<repo>" where <repo> is empty for bare/#N forms (meaning
# "the current repo", which gh infers from the git remote).
# Returns 1 if no issue number can be extracted.
parse_issue_reference() {
    local ref="$1"
    local number="" repo=""

    if [[ "$ref" =~ ^https?://github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then
        repo="${BASH_REMATCH[1]}"
        number="${BASH_REMATCH[2]}"
    elif [[ "$ref" =~ ^([^/]+/[^/#]+)#([0-9]+)$ ]]; then
        repo="${BASH_REMATCH[1]}"
        number="${BASH_REMATCH[2]}"
    elif [[ "$ref" =~ ^#?([0-9]+)$ ]]; then
        number="${BASH_REMATCH[1]}"
    else
        return 1
    fi

    printf '%s\t%s\n' "$number" "$repo"
    return 0
}

# --- gh wrappers (each degrades gracefully) ---------------------------------

# gh_issue_comment <number> <repo> <body>
gh_issue_comment() {
    local number="$1" repo="$2" body="$3"
    local args=("issue" "comment" "$number" "--body-file" "-")
    [[ -n "$repo" ]] && args+=("--repo" "$repo")
    if ! printf '%s\n' "$body" | gh "${args[@]}" >/dev/null 2>&1; then
        _lifecycle_log "WARN" "🚫 Could not post comment to issue #${number}${repo:+ ($repo)} — check gh auth / permissions"
        return 1
    fi
    _lifecycle_log "INFO" "💬 Posted comment to issue #${number}"
    return 0
}

# gh_close_issue <number> <repo>
gh_close_issue() {
    local number="$1" repo="$2"
    local args=("issue" "close" "$number")
    [[ -n "$repo" ]] && args+=("--repo" "$repo")
    if ! gh "${args[@]}" >/dev/null 2>&1; then
        _lifecycle_log "WARN" "🚫 Could not close issue #${number}${repo:+ ($repo)} — check gh auth / permissions"
        return 1
    fi
    _lifecycle_log "INFO" "✅ Closed issue #${number}"
    return 0
}

# gh_add_labels <number> <repo> <labels_csv>
gh_add_labels() {
    local number="$1" repo="$2" labels="$3"
    [[ -z "$labels" ]] && return 0
    local args=("issue" "edit" "$number" "--add-label" "$labels")
    [[ -n "$repo" ]] && args+=("--repo" "$repo")
    if ! gh "${args[@]}" >/dev/null 2>&1; then
        _lifecycle_log "WARN" "🚫 Could not add labels '$labels' to issue #${number} — check gh auth / permissions"
        return 1
    fi
    _lifecycle_log "INFO" "🏷️  Added labels '$labels' to issue #${number}"
    return 0
}

# gh_create_pr <title> <body> <draft:true|false> <repo>
# Prints the created PR URL on success.
gh_create_pr() {
    local title="$1" body="$2" draft="$3" repo="$4"
    local args=("pr" "create" "--title" "$title" "--body-file" "-")
    [[ "$draft" == "true" ]] && args+=("--draft")
    [[ -n "$repo" ]] && args+=("--repo" "$repo")
    local url
    if ! url=$(printf '%s\n' "$body" | gh "${args[@]}" 2>/dev/null); then
        _lifecycle_log "WARN" "🚫 Could not create PR — check the branch is pushed and gh has permission"
        return 1
    fi
    _lifecycle_log "INFO" "🔀 Created PR: ${url}"
    printf '%s\n' "$url"
    return 0
}

# gh_create_issue <title> <body> <labels_csv> <repo>
# Prints the created issue URL on success.
gh_create_issue() {
    local title="$1" body="$2" labels="$3" repo="$4"
    local args=("issue" "create" "--title" "$title" "--body-file" "-")
    [[ -n "$labels" ]] && args+=("--label" "$labels")
    [[ -n "$repo" ]] && args+=("--repo" "$repo")
    local url
    if ! url=$(printf '%s\n' "$body" | gh "${args[@]}" 2>/dev/null); then
        _lifecycle_log "WARN" "🚫 Could not create follow-up issue '$title' — check gh auth / permissions"
        return 1
    fi
    _lifecycle_log "INFO" "📌 Created follow-up issue: ${url}"
    printf '%s\n' "$url"
    return 0
}

# --- state management -------------------------------------------------------

# _lifecycle_apply <jq_program> [extra jq options...]
# Atomically transform the state file, always refreshing updated_at. The program
# may reference $now (the new timestamp).
_lifecycle_apply() {
    local program=$1
    shift
    local now tmp
    now=$(get_iso_timestamp)
    [[ -f "$GITHUB_LIFECYCLE_STATE_FILE" ]] || return 1
    tmp=$(mktemp "${GITHUB_LIFECYCLE_STATE_FILE}.XXXXXX") || return 1
    if jq --arg now "$now" "$@" "($program) | .updated_at = \$now" "$GITHUB_LIFECYCLE_STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$GITHUB_LIFECYCLE_STATE_FILE"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# lifecycle_get <jq_filter>  -> read a value from the state file (raw output)
lifecycle_get() {
    [[ -f "$GITHUB_LIFECYCLE_STATE_FILE" ]] || { echo ""; return 1; }
    jq -r "$1 // empty" "$GITHUB_LIFECYCLE_STATE_FILE" 2>/dev/null
}

# init_github_lifecycle <issue_ref> [title]
# Parses the reference, writes initial lifecycle state, and exports
# GITHUB_ISSUE_NUMBER / GITHUB_ISSUE_REPO for the rest of the run.
# Returns 1 (without writing state) if the reference is unparseable.
init_github_lifecycle() {
    local ref="$1" title="${2:-}"
    local parsed number repo
    if ! parsed=$(parse_issue_reference "$ref"); then
        _lifecycle_log "WARN" "Invalid --github-issue reference: '$ref' (expected N, #N, owner/repo#N, or an issue URL)"
        return 1
    fi
    number=$(printf '%s' "$parsed" | cut -f1)
    repo=$(printf '%s' "$parsed" | cut -f2)

    GITHUB_ISSUE_NUMBER="$number"
    GITHUB_ISSUE_REPO="$repo"

    mkdir -p "$(dirname "$GITHUB_LIFECYCLE_STATE_FILE")" 2>/dev/null
    local now start_sha
    now=$(get_iso_timestamp)
    # Capture HEAD at the start of the run so follow-up TODO scanning covers every
    # commit Ralph makes during development, not just the last one (empty if not a repo).
    start_sha=$(git rev-parse HEAD 2>/dev/null) || start_sha=""
    # Write through a temp file + mv so an interrupted init never leaves a
    # truncated/corrupt state file (same atomicity as _lifecycle_apply).
    local tmp
    tmp=$(mktemp "${GITHUB_LIFECYCLE_STATE_FILE}.XXXXXX" 2>/dev/null) || {
        _lifecycle_log "WARN" "Could not initialize GitHub lifecycle state file"
        return 1
    }
    if jq -n \
        --arg number "$number" \
        --arg repo "$repo" \
        --arg title "$title" \
        --arg now "$now" \
        --arg start_sha "$start_sha" \
        '{
            issue: { number: ($number | tonumber), repo: $repo, title: $title },
            lifecycle: {
                initialized_at: $now,
                start_sha: $start_sha,
                last_progress_comment: null,
                progress_comments_posted: 0,
                completion_detected_at: null,
                pr_created: false,
                pr_url: null,
                issue_closed: false,
                followups_created: []
            },
            updated_at: $now
        }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$GITHUB_LIFECYCLE_STATE_FILE"
    else
        rm -f "$tmp"
        _lifecycle_log "WARN" "Could not initialize GitHub lifecycle state file"
        return 1
    fi

    _lifecycle_log "INFO" "🔗 GitHub issue lifecycle tracking #${number}${repo:+ ($repo)}"
    return 0
}

# --- content generators -----------------------------------------------------

# _fix_plan_file -> path to the active fix_plan.md
_fix_plan_file() {
    echo "${RALPH_DIR}/fix_plan.md"
}

# generate_progress_comment <loop_count>
# Markdown progress update: completed vs remaining tasks (from fix_plan.md),
# files changed so far, and the loop number.
generate_progress_comment() {
    local loop_count="$1"
    local plan
    plan="$(_fix_plan_file)"

    local completed remaining
    completed=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$plan" 2>/dev/null | tr -d '[:space:]'); completed="${completed:-0}"
    remaining=$(grep -cE "^[[:space:]]*- \[ \]" "$plan" 2>/dev/null | tr -d '[:space:]'); remaining="${remaining:-0}"

    local files
    files=$(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null)
    files=$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)
    local file_lines
    if [[ -n "$files" ]]; then
        file_lines=$(printf '%s\n' "$files" | head -20 | sed 's/^/- `/; s/$/`/')
    else
        file_lines="_No tracked changes since last commit._"
    fi

    cat <<EOF
## 🔄 Ralph progress update — loop #${loop_count}

**Tasks:** ${completed} completed, ${remaining} remaining (in \`fix_plan.md\`)

### Files changed
${file_lines}

---
*Posted automatically by Ralph's autonomous development loop.*
EOF
}

# generate_completion_summary
# Markdown summary posted when the issue is closed / PR is opened.
generate_completion_summary() {
    local plan
    plan="$(_fix_plan_file)"

    local completed_tasks
    completed_tasks=$(grep -E "^[[:space:]]*- \[[xX]\]" "$plan" 2>/dev/null | sed 's/^[[:space:]]*//' | head -30)
    [[ -z "$completed_tasks" ]] && completed_tasks="_(no completed tasks recorded)_"

    local diffstat
    diffstat=$(git diff --shortstat HEAD~1 2>/dev/null)
    [[ -z "$diffstat" ]] && diffstat=$(git diff --shortstat 2>/dev/null)
    [[ -z "$diffstat" ]] && diffstat="(no diff stats available)"

    cat <<EOF
## ✅ Ralph completed development

### Completed tasks
${completed_tasks}

### Changes
${diffstat}

---
*Posted automatically by Ralph's autonomous development loop.*
EOF
}

# scan_for_todos
# Scan lines ADDED since the lifecycle start SHA (all commits made during the run
# plus the working tree) for TODO/FIXME/HACK/XXX markers. Falls back to the last
# commit + working tree when no start SHA is recorded (e.g. lib used standalone).
# Prints one "<file>: <marker text>" per line (deduplicated) so the follow-up
# issue points reviewers at where each marker lives.
scan_for_todos() {
    local base diff
    base=$(lifecycle_get '.lifecycle.start_sha' 2>/dev/null)
    if [[ -n "$base" ]] && git rev-parse --quiet --verify "$base^{commit}" >/dev/null 2>&1; then
        # Diff the start SHA against the working tree: covers every commit + uncommitted change.
        diff=$(git diff -U0 "$base" 2>/dev/null)
    else
        diff=$(git diff -U0 HEAD 2>/dev/null; git diff -U0 --cached 2>/dev/null; git diff -U0 HEAD~1 HEAD 2>/dev/null)
    fi
    # Track the current file from "+++ b/<path>" headers and prefix each marker.
    # POSIX awk (no IGNORECASE): match on an upper-cased copy, slice from the
    # original line to preserve the marker's text verbatim.
    printf '%s\n' "$diff" | awk '
        function first_marker(s,   kws, n, i, idx, best) {
            n = split("TODO FIXME HACK XXX", kws, " ")
            best = 0
            for (i = 1; i <= n; i++) {
                idx = index(s, kws[i])
                if (idx > 0 && (best == 0 || idx < best)) best = idx
            }
            return best
        }
        /^\+\+\+ / { file = $2; sub(/^b\//, "", file); next }
        /^\+/ {
            p = first_marker(toupper($0))
            if (p > 0) {
                txt = substr($0, p)
                sub(/[[:space:]]+$/, "", txt)
                print (file == "" ? "" : file ": ") txt
            }
        }
    ' | sort -u
}

# --- orchestration (always returns 0: graceful degradation) -----------------

# lifecycle_post_progress <loop_count>
# Posts a progress comment when COMMENT_PROGRESS=true and the loop number is a
# multiple of COMMENT_INTERVAL. No-op otherwise. Never fails the loop.
lifecycle_post_progress() {
    local loop_count="$1"
    [[ "${COMMENT_PROGRESS:-false}" == "true" ]] || return 0
    [[ -n "${GITHUB_ISSUE_NUMBER:-}" ]] || return 0

    local interval="${COMMENT_INTERVAL:-5}"
    [[ "$interval" =~ ^[0-9]+$ ]] && [[ "$interval" -gt 0 ]] || interval=5
    [[ $((loop_count % interval)) -eq 0 ]] || return 0

    local body
    body="$(generate_progress_comment "$loop_count")"
    if gh_issue_comment "$GITHUB_ISSUE_NUMBER" "${GITHUB_ISSUE_REPO:-}" "$body"; then
        _lifecycle_apply '.lifecycle.last_progress_comment = $now
            | .lifecycle.progress_comments_posted += 1' >/dev/null 2>&1 || true
    fi
    return 0
}

# lifecycle_on_completion
# Runs the completion workflow in order: summary comment, PR creation, follow-up
# issues, then issue close (+ labels). Each step is guarded by its own flag and
# degrades gracefully. Never fails the loop.
lifecycle_on_completion() {
    [[ -n "${GITHUB_ISSUE_NUMBER:-}" ]] || return 0
    local number="$GITHUB_ISSUE_NUMBER"
    local repo="${GITHUB_ISSUE_REPO:-}"

    _lifecycle_apply '.lifecycle.completion_detected_at = $now' >/dev/null 2>&1 || true

    local summary
    summary="$(generate_completion_summary)"

    # 1. Summary comment (when closing with a summary, or always if requested)
    if [[ "${CLOSE_SUMMARY:-false}" == "true" ]]; then
        gh_issue_comment "$number" "$repo" "$summary" || true
    fi

    # 2. Pull request linked to the issue.
    # Refuse to operate on the default/protected branch: pushing it would land the
    # work directly on the base instead of proposing it in a PR (codex P1).
    if [[ "${CREATE_PR:-false}" == "true" ]]; then
        local branch="" default_branch=""
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
        default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || default_branch=""
        [[ -z "$default_branch" ]] && default_branch="main"
        if [[ -z "$branch" || "$branch" == "HEAD" || "$branch" == "$default_branch" || "$branch" == "main" || "$branch" == "master" ]]; then
            _lifecycle_log "WARN" "Skipping PR creation: current branch ('${branch:-detached HEAD}') is the default/protected branch. Run Ralph on a feature branch to open a PR."
        else
            local title
            title="$(lifecycle_get '.issue.title')"
            [[ -z "$title" ]] && title="Ralph: resolve issue #${number}"
            local pr_body="$summary"
            if [[ "${LINK_ISSUE:-false}" == "true" ]]; then
                pr_body="$summary"$'\n\n'"Closes #${number}"
            fi
            # Best-effort push of the feature branch so gh has something to open a PR from.
            _lifecycle_log "INFO" "⬆️  Pushing '$branch' to origin for PR creation"
            git push -u origin "$branch" >/dev/null 2>&1 || true
            local pr_url
            if pr_url=$(gh_create_pr "$title" "$pr_body" "${DRAFT_PR:-false}" "$repo"); then
                _lifecycle_apply '.lifecycle.pr_created = true | .lifecycle.pr_url = $url' \
                    --arg url "$pr_url" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 3. Follow-up issues for discovered TODOs (grouped into one issue)
    if [[ "${CREATE_FOLLOWUPS:-false}" == "true" ]]; then
        local todos
        todos="$(scan_for_todos)"
        if [[ -n "$todos" ]]; then
            local fbody
            fbody="$(cat <<EOF
Follow-up work discovered while resolving #${number}:

$(printf '%s\n' "$todos" | sed 's/^/- /')

---
*Auto-generated by Ralph from TODO/FIXME markers added during development.*
EOF
)"
            local furl
            if furl=$(gh_create_issue "Follow-up: TODOs from #${number}" "$fbody" "${FOLLOWUP_LABEL:-tech-debt}" "$repo"); then
                _lifecycle_apply '.lifecycle.followups_created += [$url]' \
                    --arg url "$furl" >/dev/null 2>&1 || true
            fi
        else
            _lifecycle_log "INFO" "No TODO/FIXME markers found for follow-up issues"
        fi
    fi

    # 4. Close the issue (+ optional completion labels).
    # Note: with both --auto-close and --link-issue, the issue is closed here AND
    # would be auto-closed again when the "Closes #N" PR merges. GitHub treats the
    # second close as a no-op; this is intentional so an --auto-close run closes the
    # issue immediately rather than waiting on the merge.
    if [[ "${AUTO_CLOSE:-false}" == "true" ]]; then
        if [[ -n "${ADD_COMPLETION_LABELS:-}" ]]; then
            gh_add_labels "$number" "$repo" "$ADD_COMPLETION_LABELS" || true
        fi
        if gh_close_issue "$number" "$repo"; then
            _lifecycle_apply '.lifecycle.issue_closed = true' >/dev/null 2>&1 || true
        fi
    fi

    return 0
}
