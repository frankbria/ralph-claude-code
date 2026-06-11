#!/usr/bin/env bats
# Unit tests for lib/sync.sh (Issue #76)
#
# Covers the backend-agnostic sandbox file-sync filter library:
# config validation, .ralphignore parsing, pattern matching semantics
# (basename, path-segment, anchored-path, directory patterns), the
# NUL-separated upload filter (include -> exclude -> .ralphignore -> size
# policy), the newline-separated download filter (exclude + .ralphignore
# only), large-file warn/skip policy, and human-readable size formatting.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/sync.XXXXXX")"
    cd "$TEST_DIR"

    # Clean filter configuration for every test
    export SYNC_INCLUDE=""
    export SYNC_EXCLUDE=""
    export SYNC_MAX_FILE_SIZE="10485760"
    export SYNC_LARGE_FILE_ACTION="warn"
    export RALPHIGNORE_FILE=".ralphignore"

    source "$PROJECT_ROOT/lib/sync.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Run a NUL-separated list of paths through sync_filter_file_list and print
# the surviving paths newline-separated (assertable with simple comparisons).
_filter() {
    printf '%s\0' "$@" | sync_filter_file_list | tr '\0' '\n'
}

_filter_download() {
    printf '%s\n' "$@" | sync_filter_download_list
}

# Bare `!` at bats test top level is exempt from errexit and silently passes
# (issue #303) — negate inside a helper whose return value IS checked.
refute_match() {
    if _sync_path_matches_pattern "$1" "$2"; then
        echo "expected '$1' NOT to match pattern '$2'" >&2
        return 1
    fi
    return 0
}

# --- validate_sync_config ----------------------------------------------------

@test "validate_sync_config: accepts the defaults" {
    run validate_sync_config
    assert_success
}

@test "validate_sync_config: accepts action=skip and size=0 (unlimited)" {
    SYNC_LARGE_FILE_ACTION="skip" SYNC_MAX_FILE_SIZE="0" run validate_sync_config
    assert_success
}

@test "validate_sync_config: rejects unknown large-file action" {
    SYNC_LARGE_FILE_ACTION="explode" run validate_sync_config
    assert_failure
    [[ "$output" == *"SYNC_LARGE_FILE_ACTION"* ]]
}

@test "validate_sync_config: rejects non-numeric max file size" {
    SYNC_MAX_FILE_SIZE="10MB" run validate_sync_config
    assert_failure
    [[ "$output" == *"SYNC_MAX_FILE_SIZE"* ]]
}

# --- load_ralphignore_patterns -----------------------------------------------

@test "load_ralphignore_patterns: missing file yields no patterns" {
    run load_ralphignore_patterns
    assert_success
    [[ -z "$output" ]]
}

@test "load_ralphignore_patterns: strips comments and blank lines" {
    cat > .ralphignore << 'EOF'
# build artifacts
dist/

*.log
EOF
    run load_ralphignore_patterns
    assert_success
    assert_equal "$output" "dist/
*.log"
}

@test "load_ralphignore_patterns: trims whitespace and CR line endings" {
    printf '  *.tmp  \r\nnode_modules/\r\n' > .ralphignore
    run load_ralphignore_patterns
    assert_success
    assert_equal "$output" "*.tmp
node_modules/"
}

@test "load_ralphignore_patterns: drops unsupported negation lines" {
    cat > .ralphignore << 'EOF'
*.log
!keep.log
EOF
    run load_ralphignore_patterns
    assert_success
    assert_equal "$output" "*.log"
}

# --- _sync_path_matches_pattern ----------------------------------------------

@test "pattern match: basename glob matches at any depth" {
    _sync_path_matches_pattern "deep/nested/file.log" "*.log"
    _sync_path_matches_pattern "file.log" "*.log"
    refute_match "file.txt" "*.log"
}

@test "pattern match: bare name matches any path segment" {
    _sync_path_matches_pattern "node_modules/pkg/index.js" "node_modules"
    _sync_path_matches_pattern "web/node_modules/pkg/index.js" "node_modules"
    refute_match "src/node_modules.md" "node_modules"
}

@test "pattern match: slash patterns anchor to the full path" {
    _sync_path_matches_pattern "src/lib/util.sh" "src/**"
    _sync_path_matches_pattern "src/main.sh" "src/*"
    refute_match "other/src/main.sh" "src/**"
}

@test "pattern match: directory pattern matches the tree at any depth" {
    _sync_path_matches_pattern "logs/run.txt" "logs/"
    _sync_path_matches_pattern "app/logs/run.txt" "logs/"
    refute_match "logsx/run.txt" "logs/"
}

@test "pattern match: anchored directory pattern stays anchored" {
    _sync_path_matches_pattern "build/out/a.o" "build/out/"
    refute_match "other/build/out/a.o" "build/out/"
}

@test "pattern match: leading ./ on the path is ignored" {
    _sync_path_matches_pattern "./src/main.sh" "src/**"
}

# --- sync_filter_file_list (upload) ------------------------------------------

@test "upload filter: passthrough when no patterns configured" {
    run _filter "src/a.sh" "docs/b.md"
    assert_success
    assert_equal "$output" "src/a.sh
docs/b.md"
}

@test "upload filter: include patterns restrict the list" {
    SYNC_INCLUDE="src/**,*.md"
    run _filter "src/a.sh" "README.md" "tests/t.bats"
    assert_success
    assert_equal "$output" "src/a.sh
README.md"
}

@test "upload filter: glob patterns survive a matching file in cwd (codex P2)" {
    # Pathname expansion during pattern splitting would turn "*.log" into
    # "debug.log" whenever a matching file exists in the project root,
    # silently un-filtering every other .log file
    echo "bait" > debug.log
    SYNC_EXCLUDE="*.log"
    run _filter "src/app.log" "src/keep.sh"
    assert_success
    assert_equal "$output" "src/keep.sh"
}

@test "download filter: glob patterns survive a matching file in cwd (codex P2)" {
    echo "bait" > debug.log
    SYNC_EXCLUDE="*.log"
    run _filter_download "src/app.log" "src/keep.sh"
    assert_success
    assert_equal "$output" "src/keep.sh"
}

@test "upload filter: exclude patterns drop matches" {
    SYNC_EXCLUDE="*.log,node_modules"
    run _filter "src/a.sh" "debug.log" "node_modules/x/y.js"
    assert_success
    assert_equal "$output" "src/a.sh"
}

@test "upload filter: exclude wins over include" {
    SYNC_INCLUDE="src/**"
    SYNC_EXCLUDE="*.tmp"
    run _filter "src/a.sh" "src/junk.tmp"
    assert_success
    assert_equal "$output" "src/a.sh"
}

@test "upload filter: .ralphignore patterns drop matches" {
    printf '*.secret\ndist/\n' > .ralphignore
    run _filter "src/a.sh" "creds.secret" "dist/bundle.js"
    assert_success
    assert_equal "$output" "src/a.sh"
}

@test "upload filter: preserves paths with spaces" {
    run _filter "src/my file.sh" "other.sh"
    assert_success
    assert_equal "$output" "src/my file.sh
other.sh"
}

@test "upload filter: large file is kept but warned with action=warn" {
    mkdir -p big && head -c 2048 /dev/zero > big/blob.bin
    SYNC_MAX_FILE_SIZE="1024"
    # The file survives the filter (stdout)...
    result=$(printf '%s\0' "big/blob.bin" | sync_filter_file_list 2>/dev/null | tr '\0' '\n')
    assert_equal "$result" "big/blob.bin"
    # ...and the warning lands on stderr
    warnings=$(printf '%s\0' "big/blob.bin" | sync_filter_file_list 2>&1 >/dev/null)
    [[ "$warnings" == *"big/blob.bin"* ]]
    [[ "$warnings" == *"arge file"* ]]
}

@test "upload filter: large file is dropped with action=skip" {
    mkdir -p big && head -c 2048 /dev/zero > big/blob.bin
    SYNC_MAX_FILE_SIZE="1024"
    SYNC_LARGE_FILE_ACTION="skip"
    result=$(printf '%s\0' "big/blob.bin" "small.txt" | sync_filter_file_list 2>/dev/null | tr '\0' '\n')
    assert_equal "$result" "small.txt"
}

@test "upload filter: size 0 disables the large-file policy" {
    mkdir -p big && head -c 2048 /dev/zero > big/blob.bin
    SYNC_MAX_FILE_SIZE="0"
    SYNC_LARGE_FILE_ACTION="skip"
    result=$(printf '%s\0' "big/blob.bin" | sync_filter_file_list 2>/dev/null | tr '\0' '\n')
    assert_equal "$result" "big/blob.bin"
}

@test "upload filter: size policy ignores paths that do not exist on disk" {
    SYNC_MAX_FILE_SIZE="1"
    SYNC_LARGE_FILE_ACTION="skip"
    result=$(printf '%s\0' "ghost/never-created.bin" | sync_filter_file_list 2>/dev/null | tr '\0' '\n')
    assert_equal "$result" "ghost/never-created.bin"
}

# --- sync_filter_download_list (download) ------------------------------------

@test "download filter: passthrough when no patterns configured" {
    run _filter_download "src/a.sh" "out/result.txt"
    assert_success
    assert_equal "$output" "src/a.sh
out/result.txt"
}

@test "download filter: applies exclude and .ralphignore patterns" {
    printf '*.cache\n' > .ralphignore
    SYNC_EXCLUDE="*.log"
    run _filter_download "src/a.sh" "noise.log" "x.cache"
    assert_success
    assert_equal "$output" "src/a.sh"
}

@test "download filter: include patterns are NOT applied (artifacts come back)" {
    SYNC_INCLUDE="src/**"
    run _filter_download "src/a.sh" "artifacts/new-output.json"
    assert_success
    assert_equal "$output" "src/a.sh
artifacts/new-output.json"
}

@test "download filter: preserves the original ./ prefix for tar member names" {
    SYNC_EXCLUDE="*.log"
    run _filter_download "./src/a.sh" "./noise.log"
    assert_success
    assert_equal "$output" "./src/a.sh"
}

# --- format_sync_size / log_sync_summary -------------------------------------

@test "format_sync_size: bytes, KB, MB, GB" {
    assert_equal "$(format_sync_size 512)" "512B"
    assert_equal "$(format_sync_size 2048)" "2.0KB"
    assert_equal "$(format_sync_size 5242880)" "5.0MB"
    assert_equal "$(format_sync_size 1610612736)" "1.5GB"
}

@test "log_sync_summary: emits count and human-readable size" {
    run log_sync_summary "Upload" 42 1048576
    assert_success
    [[ "$output" == *"Upload"* ]]
    [[ "$output" == *"42 file(s)"* ]]
    [[ "$output" == *"1.0MB"* ]]
}
