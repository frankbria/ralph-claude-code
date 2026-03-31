#!/bin/bash

# Ralph Release Notes Drafter
# Generates formatted Markdown release notes from git history
# using conventional commit prefixes.

set -euo pipefail

# Resolve script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/changelog_utils.sh
source "${SCRIPT_DIR}/lib/changelog_utils.sh"

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

# Initialize and categorize
reset_buckets
if ! categorize_commits_in_range "$FROM_REF" "$TO_REF"; then
    echo "No commits found in range ${FROM_REF}..${TO_REF}" >&2
    exit 0
fi

# Output Markdown
echo "# ${VERSION_LABEL} (${RELEASE_DATE})"
echo ""
echo "Changes from \`${FROM_REF}\` to \`${TO_REF}\`."
echo ""

print_all_sections
