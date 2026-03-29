#!/bin/bash

# Ralph Release Notes Drafter
# Generates formatted Markdown release notes from git history
# using conventional commit prefixes.

set -euo pipefail

# Defaults
FROM_REF=""
TO_REF="HEAD"
VERSION_LABEL=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate release notes from git history using conventional commits.

Options:
  --from REF    Start ref (default: latest git tag, or first commit if no tags)
  --to REF      End ref (default: HEAD)
  --version VER Version label for the header (default: derived from --to)
  -h, --help    Show this help message

Examples:
  $(basename "$0")                           # Last tag..HEAD
  $(basename "$0") --from v0.10.0 --to v0.11.0
  $(basename "$0") --from abc123 --version v1.0.0
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            FROM_REF="$2"
            shift 2
            ;;
        --to)
            TO_REF="$2"
            shift 2
            ;;
        --version)
            VERSION_LABEL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Resolve FROM_REF: use latest tag if not specified
if [[ -z "$FROM_REF" ]]; then
    FROM_REF=$(git describe --tags --abbrev=0 2>/dev/null || true)
    if [[ -z "$FROM_REF" ]]; then
        # No tags at all – use the root commit
        FROM_REF=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
    fi
fi

# Derive version label
if [[ -z "$VERSION_LABEL" ]]; then
    if [[ "$TO_REF" == "HEAD" ]]; then
        VERSION_LABEL="Unreleased"
    else
        VERSION_LABEL="$TO_REF"
    fi
fi

# Get today's date
RELEASE_DATE=$(date +%Y-%m-%d)

# Collect commits (one per line: hash subject)
COMMITS=$(git log --pretty=format:"%h %s" "${FROM_REF}..${TO_REF}" 2>/dev/null || true)

if [[ -z "$COMMITS" ]]; then
    echo "No commits found in range ${FROM_REF}..${TO_REF}" >&2
    exit 0
fi

# Category buckets
FEATURES=""
FIXES=""
REFACTORING=""
CICD=""
CHORES=""
DOCS=""
OTHER=""

# Categorize each commit
while IFS= read -r line; do
    hash="${line%% *}"
    subject="${line#* }"

    # Skip merge commits
    if [[ "$subject" == Merge* ]]; then
        continue
    fi

    # Extract PR number if present, e.g. (#123)
    pr_number=""
    if [[ "$subject" =~ \(#([0-9]+)\) ]]; then
        pr_number="${BASH_REMATCH[1]}"
    fi

    # Determine category from conventional commit prefix
    # Strip prefix to get the description
    description="$subject"
    category="other"

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
    entry="- ${description}"
    if [[ -n "$pr_number" ]]; then
        # Remove trailing (#NNN) from description if it's there
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
done <<< "$COMMITS"

# Output Markdown
echo "# ${VERSION_LABEL} (${RELEASE_DATE})"
echo ""
echo "Changes from \`${FROM_REF}\` to \`${TO_REF}\`."
echo ""

print_section() {
    local title="$1"
    local items="$2"
    if [[ -n "$items" ]]; then
        echo "## ${title}"
        echo ""
        echo -e "${items}"
    fi
}

print_section "Features" "$FEATURES"
print_section "Bug Fixes" "$FIXES"
print_section "Refactoring" "$REFACTORING"
print_section "CI/CD" "$CICD"
print_section "Documentation" "$DOCS"
print_section "Chores" "$CHORES"
print_section "Other" "$OTHER"
