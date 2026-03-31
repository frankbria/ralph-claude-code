#!/bin/bash

# Ralph Changelog Synthesizer
# Generates a complete CHANGELOG.md from conventional commits across all git tags.

set -euo pipefail

# Resolve script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/changelog_utils.sh
source "${SCRIPT_DIR}/lib/changelog_utils.sh"

# Defaults
OUTPUT_FILE="CHANGELOG.md"
UNRELEASED_ONLY=false
FROM_TAG=""
FORMAT="markdown"
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate a full CHANGELOG.md from git history using conventional commits.

Options:
  --output FILE         Output file (default: CHANGELOG.md)
  --unreleased-only     Only generate the Unreleased section
  --from-tag TAG        Start from this tag (skip older tags)
  --format FORMAT       Output format: markdown (default)
  --dry-run             Print to stdout instead of writing file
  -h, --help            Show this help message

Examples:
  $(basename "$0")                            # Full changelog to CHANGELOG.md
  $(basename "$0") --dry-run                  # Preview to stdout
  $(basename "$0") --unreleased-only          # Only unreleased changes
  $(basename "$0") --output docs/CHANGES.md   # Custom output path
  $(basename "$0") --from-tag v1.0.0          # Only from v1.0.0 onwards
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --unreleased-only)
            UNRELEASED_ONLY=true
            shift
            ;;
        --from-tag)
            FROM_TAG="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
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

# Validate format
if [[ "$FORMAT" != "markdown" ]]; then
    echo "Error: Unsupported format '$FORMAT'. Only 'markdown' is supported." >&2
    exit 1
fi

# Collect all tags sorted by version (newest first)
get_sorted_tags() {
    git tag --sort=-version:refname 2>/dev/null
}

# Generate a single version section.
# Args: $1=version_label $2=from_ref $3=to_ref $4=date
generate_version_section() {
    local version_label="$1"
    local from_ref="$2"
    local to_ref="$3"
    local release_date="$4"

    reset_buckets
    if ! categorize_commits_in_range "$from_ref" "$to_ref"; then
        return
    fi

    if ! has_content; then
        return
    fi

    echo "# ${version_label} (${release_date})"
    echo ""
    print_all_sections
}

# Get the date of a tag or HEAD
get_ref_date() {
    local ref="$1"
    if [[ "$ref" == "HEAD" ]]; then
        date +%Y-%m-%d
    else
        git log -1 --format=%ai "$ref" 2>/dev/null | cut -d' ' -f1
    fi
}

# Main generation logic
generate_changelog() {
    local all_tags
    all_tags=$(get_sorted_tags)

    # Convert to array
    local -a tags=()
    if [[ -n "$all_tags" ]]; then
        while IFS= read -r tag; do
            tags+=("$tag")
        done <<< "$all_tags"
    fi

    # Apply --from-tag filter: keep only FROM_TAG and newer tags.
    # Tags are sorted newest-first, so include from start until FROM_TAG.
    # Track the tag just after FROM_TAG (older) as boundary for the oldest section.
    local from_tag_predecessor=""
    if [[ -n "$FROM_TAG" && ${#tags[@]} -gt 0 ]]; then
        local -a filtered_tags=()
        local found_from=false
        for tag in "${tags[@]}"; do
            if [[ "$found_from" == true ]]; then
                # This tag is older than FROM_TAG — use it as predecessor
                from_tag_predecessor="$tag"
                break
            fi
            filtered_tags+=("$tag")
            if [[ "$tag" == "$FROM_TAG" ]]; then
                found_from=true
            fi
        done
        if [[ "$found_from" == false ]]; then
            echo "Warning: Tag '$FROM_TAG' not found. Generating full changelog." >&2
        else
            tags=("${filtered_tags[@]}")
        fi
    fi

    local has_output=false

    # Unreleased section: latest_tag..HEAD (or root..HEAD if no tags)
    if [[ ${#tags[@]} -eq 0 ]]; then
        # No tags at all: root..HEAD
        local root_commit
        root_commit=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
        if [[ -n "$root_commit" ]]; then
            local section
            section=$(generate_version_section "Unreleased" "$root_commit" "HEAD" "$(date +%Y-%m-%d)")
            if [[ -n "$section" ]]; then
                echo "$section"
                has_output=true
            fi
        fi
    else
        # Unreleased: latest_tag..HEAD
        local latest_tag="${tags[0]}"
        local section
        section=$(generate_version_section "Unreleased" "$latest_tag" "HEAD" "$(date +%Y-%m-%d)")
        if [[ -n "$section" ]]; then
            echo "$section"
            has_output=true
        fi

        if [[ "$UNRELEASED_ONLY" == true ]]; then
            if [[ "$has_output" == false ]]; then
                echo "No unreleased changes found." >&2
            fi
            return
        fi

        # Tag-to-tag sections
        local i
        for (( i=0; i < ${#tags[@]}; i++ )); do
            local current_tag="${tags[$i]}"
            local prev_ref

            if (( i + 1 < ${#tags[@]} )); then
                prev_ref="${tags[$((i + 1))]}"
            elif [[ -n "$from_tag_predecessor" ]]; then
                # --from-tag active: use the predecessor tag as boundary
                prev_ref="$from_tag_predecessor"
            else
                # Oldest tag: from root commit
                prev_ref=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
            fi

            local tag_date
            tag_date=$(get_ref_date "$current_tag")

            section=$(generate_version_section "$current_tag" "$prev_ref" "$current_tag" "$tag_date")
            if [[ -n "$section" ]]; then
                if [[ "$has_output" == true ]]; then
                    echo ""
                fi
                echo "$section"
                has_output=true
            fi
        done
    fi

    if [[ "$UNRELEASED_ONLY" == true && "$has_output" == false ]]; then
        echo "No unreleased changes found." >&2
    fi

    if [[ "$has_output" == false && "$UNRELEASED_ONLY" == false ]]; then
        echo "No changes found in repository history." >&2
    fi
}

# Execute
output=$(generate_changelog)

if [[ "$DRY_RUN" == true ]]; then
    if [[ -n "$output" ]]; then
        echo "$output"
    fi
else
    if [[ -n "$output" ]]; then
        echo "$output" > "$OUTPUT_FILE"
        echo "Changelog written to ${OUTPUT_FILE}" >&2
    fi
fi
