#!/usr/bin/env bats
# Unit Tests for the coverage job in test.yml (Issue #372)
#
# 1. kcov output dirs must be absolute. kcov preloads
#    <outdir>/libkcov_sowrapper.so; a relative outdir stops resolving once a
#    test cd's into its temp dir, and the LD_PRELOAD error on stderr fails
#    every exact-output assertion under kcov only.
# 2. The kcov build must set CMAKE_POLICY_VERSION_MINIMUM: kcov v42 declares a
#    minimum CMake below 3.5, which CMake 4 (ubuntu-latest) rejects outright.

load '../helpers/test_helper'

WORKFLOW="$BATS_TEST_DIRNAME/../../.github/workflows/test.yml"

@test "kcov build passes a CMake policy floor (CMake 4 compatibility)" {
    run grep -E '^[[:space:]]*cmake .*-DCMAKE_POLICY_VERSION_MINIMUM=3\.5' "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "COVERAGE_DIR is derived from an absolute path" {
    run grep -E '^[[:space:]]*COVERAGE_DIR="\$\(pwd\)/coverage"' "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "every kcov output dir is absolute (no bare relative coverage/ outdir)" {
    # The outdir is the first argument that follows the kcov option lines;
    # a line consisting only of a relative coverage/... path is the regression.
    run grep -E '^[[:space:]]+coverage/[A-Za-z0-9_-]+[[:space:]]*\\$' "$WORKFLOW"
    [ "$status" -ne 0 ]
    count=$(grep -cE '^[[:space:]]+"\$COVERAGE_DIR/[A-Za-z0-9_-]+"[[:space:]]*\\$' "$WORKFLOW")
    [ "$count" -eq 2 ]
}
