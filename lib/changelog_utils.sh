#!/bin/bash

# Shared utilities for changelog and release notes generation.
# Provides commit categorization, formatting, and section rendering
# used by both ralph_release_notes.sh and ralph_changelog.sh.

# Categorize a single commit line ("hash subject") and append to global buckets.
# Globals modified: FEATURES, FIXES, REFACTORING, CICD, CHORES, DOCS, OTHER
categorize_commit() {
    local line="$1"
    local hash="${line%% *}"
    local subject="${line#* }"

    # Skip merge commits
    if [[ "$subject" == Merge* ]]; then
        return
    fi

    # Extract PR number if present, e.g. (#123)
    local pr_number=""
    if [[ "$subject" =~ \(#([0-9]+)\) ]]; then
        pr_number="${BASH_REMATCH[1]}"
    fi

    # Determine category from conventional commit prefix
    local description="$subject"
    local category="other"

    if [[ "$subject" =~ ^feat(\(.*\))?:\ (.+) ]]; then
        category="feat"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^fix(\(.*\))?:\ (.+) ]]; then
        category="fix"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^refactor(\(.*\))?:\ (.+) ]]; then
        category="refactor"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^ci(\(.*\))?:\ (.+) ]]; then
        category="ci"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^chore(\(.*\))?:\ (.+) ]]; then
        category="chore"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^docs(\(.*\))?:\ (.+) ]]; then
        category="docs"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^test(\(.*\))?:\ (.+) ]]; then
        category="chore"
        description="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ ^perf(\(.*\))?:\ (.+) ]]; then
        category="feat"
        description="${BASH_REMATCH[2]}"
    fi

    # Build formatted entry
    local entry="- ${description}"
    if [[ -n "$pr_number" ]]; then
        entry="- ${description% (#${pr_number})} (#${pr_number})"
    fi
    entry="${entry} (\`${hash}\`)"

    case "$category" in
        feat)       FEATURES="${FEATURES}${entry}\n" ;;
        fix)        FIXES="${FIXES}${entry}\n" ;;
        refactor)   REFACTORING="${REFACTORING}${entry}\n" ;;
        ci)         CICD="${CICD}${entry}\n" ;;
        chore)      CHORES="${CHORES}${entry}\n" ;;
        docs)       DOCS="${DOCS}${entry}\n" ;;
        other)      OTHER="${OTHER}${entry}\n" ;;
    esac
}

# Reset all category buckets to empty.
reset_buckets() {
    FEATURES=""
    FIXES=""
    REFACTORING=""
    CICD=""
    CHORES=""
    DOCS=""
    OTHER=""
}

# Categorize all commits from a git log range into buckets.
# Args: $1=from_ref $2=to_ref
# Returns 1 if no commits found, 0 otherwise.
categorize_commits_in_range() {
    local from_ref="$1"
    local to_ref="$2"

    local commits
    commits=$(git log --pretty=format:"%h %s" "${from_ref}..${to_ref}" 2>/dev/null || true)

    if [[ -z "$commits" ]]; then
        return 1
    fi

    while IFS= read -r line; do
        categorize_commit "$line"
    done <<< "$commits"

    return 0
}

# Print a markdown section if items is non-empty.
# Args: $1=title $2=items
print_section() {
    local title="$1"
    local items="$2"
    if [[ -n "$items" ]]; then
        echo "## ${title}"
        echo ""
        echo -e "${items}"
    fi
}

# Print all non-empty sections in canonical order.
print_all_sections() {
    print_section "Features" "$FEATURES"
    print_section "Bug Fixes" "$FIXES"
    print_section "Refactoring" "$REFACTORING"
    print_section "CI/CD" "$CICD"
    print_section "Documentation" "$DOCS"
    print_section "Chores" "$CHORES"
    print_section "Other" "$OTHER"
}

# Check if any category bucket has content.
has_content() {
    [[ -n "$FEATURES" || -n "$FIXES" || -n "$REFACTORING" || \
       -n "$CICD" || -n "$CHORES" || -n "$DOCS" || -n "$OTHER" ]]
}
