#!/bin/bash
# Sandbox File Synchronization Filtering for Ralph (Issue #76)
#
# Backend-agnostic filter layer applied to sandbox file synchronization.
# Consumed by lib/sandbox_e2b.sh (upload list + download extraction); the
# Docker provider needs no sync — its rw bind mount shares the project in
# real time by architecture.
#
# Pattern semantics (deliberately a SUBSET of gitignore, documented in
# docs/SANDBOX_SYNC.md):
#   - "name" (no slash)  -> matches the basename at any depth, or any whole
#                           path segment ("node_modules" anywhere)
#   - "*.ext"            -> glob against the basename at any depth
#   - "dir/"             -> the directory and everything under it; anchored
#                           only if the pattern body contains a slash
#   - "src/**", "src/*"  -> glob against the full relative path (bash [[ ]]
#                           matching: '*' crosses '/', so both forms match
#                           the whole subtree)
#   - "# comment", blank -> ignored
#   - "!negation"        -> NOT supported; such lines are dropped
#
# Filter pipeline:
#   upload   (sync_filter_file_list, NUL-separated):
#            include -> exclude -> .ralphignore -> large-file policy
#   download (sync_filter_download_list, newline-separated):
#            exclude -> .ralphignore only — include patterns are NOT applied
#            so artifacts created outside the include set still come back,
#            and the size policy is upload-only (sandbox files aren't local).

RALPHIGNORE_FILE="${RALPHIGNORE_FILE:-.ralphignore}"

# Sync filter configuration defaults (overridable via .ralphrc, env, or CLI)
SYNC_INCLUDE="${SYNC_INCLUDE:-}"                       # comma-separated patterns; empty = everything
SYNC_EXCLUDE="${SYNC_EXCLUDE:-}"                       # comma-separated patterns
SYNC_MAX_FILE_SIZE="${SYNC_MAX_FILE_SIZE:-10485760}"   # bytes; 0 = unlimited
SYNC_LARGE_FILE_ACTION="${SYNC_LARGE_FILE_ACTION:-warn}"  # warn | skip

# --- logging ----------------------------------------------------------------

# _sync_log <level> <message>
# Prefer the main script's log_status() when available; always to stderr so
# warnings never pollute the NUL/newline path streams on stdout.
_sync_log() {
    local level="$1"
    local message="$2"
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "$message" >&2
    else
        echo "[$level] $message" >&2
    fi
}

# --- validation ---------------------------------------------------------------

# validate_sync_config
# Sanity-check the sync filter configuration; rc 1 with an ERROR on bad values.
validate_sync_config() {
    if [[ "$SYNC_LARGE_FILE_ACTION" != "warn" && "$SYNC_LARGE_FILE_ACTION" != "skip" ]]; then
        _sync_log "ERROR" "SYNC_LARGE_FILE_ACTION must be 'warn' or 'skip' (got '$SYNC_LARGE_FILE_ACTION')"
        return 1
    fi
    if [[ ! "$SYNC_MAX_FILE_SIZE" =~ ^[0-9]+$ ]]; then
        _sync_log "ERROR" "SYNC_MAX_FILE_SIZE must be a byte count (got '$SYNC_MAX_FILE_SIZE'; 0 disables the limit)"
        return 1
    fi
    return 0
}

# --- pattern loading ----------------------------------------------------------

# load_ralphignore_patterns
# Print one pattern per line from $RALPHIGNORE_FILE: comments, blank lines and
# unsupported negation lines dropped; whitespace and CR line endings trimmed.
load_ralphignore_patterns() {
    [[ -f "$RALPHIGNORE_FILE" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* || "$line" == !* ]] && continue
        printf '%s\n' "$line"
    done < "$RALPHIGNORE_FILE"
    return 0
}

# _sync_split_patterns <comma-separated>
# Print one trimmed pattern per line.
_sync_split_patterns() {
    local IFS=','
    local p
    for p in $1; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done
    return 0
}

# --- pattern matching ---------------------------------------------------------

# _sync_path_matches_pattern <path> <pattern>
# rc 0 if the project-relative path matches the pattern (semantics above).
_sync_path_matches_pattern() {
    local path=$1 pattern=$2
    path="${path#./}"

    # Directory pattern: "logs/" -> the tree at any depth; "build/out/" -> anchored
    if [[ "$pattern" == */ ]]; then
        local dir="${pattern%/}"
        if [[ "$dir" == */* ]]; then
            [[ "$path" == $dir || "$path" == $dir/* ]] && return 0
        else
            [[ "$path" == $dir || "$path" == $dir/* || "$path" == */$dir/* || "$path" == */$dir ]] && return 0
        fi
        return 1
    fi

    # Path pattern: glob against the full relative path ('*' crosses '/')
    if [[ "$pattern" == */* ]]; then
        [[ "$path" == $pattern ]] && return 0
        return 1
    fi

    # Bare pattern: basename glob at any depth, or any whole path segment
    local base="${path##*/}"
    [[ "$base" == $pattern ]] && return 0
    [[ "$path" == $pattern/* || "$path" == */$pattern/* ]] && return 0
    return 1
}

# _sync_path_matches_list <path> <patterns-newline-separated>
# rc 0 if the path matches ANY pattern in the list (empty list never matches).
_sync_path_matches_list() {
    local path=$1 patterns=$2
    [[ -z "$patterns" ]] && return 1
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _sync_path_matches_pattern "$path" "$p" && return 0
    done <<< "$patterns"
    return 1
}

# --- file size ----------------------------------------------------------------

# _sync_file_size <path>
# Print the file size in bytes (0 if missing/unreadable). GNU stat with BSD
# fallback — same pattern as lib/log_utils.sh.
_sync_file_size() {
    local f=$1
    [[ -f "$f" ]] || { echo 0; return 0; }
    if stat -c%s "$f" > /dev/null 2>&1; then
        stat -c%s "$f"
    else
        stat -f%z "$f" 2>/dev/null || echo 0
    fi
}

# format_sync_size <bytes>
# Human-readable size: 512B / 2.0KB / 5.0MB / 1.5GB.
format_sync_size() {
    local bytes=${1:-0}
    awk -v b="$bytes" 'BEGIN{
        if (b >= 1073741824)    printf "%.1fGB", b/1073741824;
        else if (b >= 1048576)  printf "%.1fMB", b/1048576;
        else if (b >= 1024)     printf "%.1fKB", b/1024;
        else                    printf "%dB", b }'
}

# log_sync_summary <label> <file-count> <bytes>
# Human-readable sync progress summary, e.g. "Upload: 42 file(s) (1.0MB)".
log_sync_summary() {
    local label=$1 count=$2 bytes=${3:-0}
    _sync_log "INFO" "$label: $count file(s) ($(format_sync_size "$bytes"))"
}

# --- filters ------------------------------------------------------------------

# sync_filter_file_list  (upload side)
# stdin:  NUL-separated project-relative paths
# stdout: NUL-separated paths that survive include -> exclude -> .ralphignore
#         -> large-file policy. Warnings go to stderr. Size policy only
#         applies to paths that exist locally (manifest-only paths pass).
sync_filter_file_list() {
    local include_pats exclude_pats ignore_pats
    include_pats=$(_sync_split_patterns "$SYNC_INCLUDE")
    exclude_pats=$(_sync_split_patterns "$SYNC_EXCLUDE")
    ignore_pats=$(load_ralphignore_patterns)

    local size_limit=0
    [[ "$SYNC_MAX_FILE_SIZE" =~ ^[0-9]+$ ]] && size_limit=$SYNC_MAX_FILE_SIZE

    local path rel size
    while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        rel="${path#./}"
        if [[ -n "$include_pats" ]] && ! _sync_path_matches_list "$rel" "$include_pats"; then
            continue
        fi
        _sync_path_matches_list "$rel" "$exclude_pats" && continue
        _sync_path_matches_list "$rel" "$ignore_pats" && continue
        if (( size_limit > 0 )) && [[ -f "$rel" ]]; then
            size=$(_sync_file_size "$rel")
            if (( size > size_limit )); then
                if [[ "$SYNC_LARGE_FILE_ACTION" == "skip" ]]; then
                    _sync_log "WARN" "Skipping large file from sync: $rel ($(format_sync_size "$size") > $(format_sync_size "$size_limit") limit)"
                    continue
                fi
                _sync_log "WARN" "Large file in sync: $rel ($(format_sync_size "$size") > $(format_sync_size "$size_limit") limit; SYNC_LARGE_FILE_ACTION=skip to drop)"
            fi
        fi
        printf '%s\0' "$path"
    done
    return 0
}

# sync_filter_download_list  (download side)
# stdin:  newline-separated member paths (as listed by tar; ./ prefix kept)
# stdout: paths that survive exclude -> .ralphignore. Include patterns and the
#         size policy are intentionally NOT applied (see header).
sync_filter_download_list() {
    local exclude_pats ignore_pats
    exclude_pats=$(_sync_split_patterns "$SYNC_EXCLUDE")
    ignore_pats=$(load_ralphignore_patterns)

    local path rel
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        rel="${path#./}"
        _sync_path_matches_list "$rel" "$exclude_pats" && continue
        _sync_path_matches_list "$rel" "$ignore_pats" && continue
        printf '%s\n' "$path"
    done
    return 0
}
