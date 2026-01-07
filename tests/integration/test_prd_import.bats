#!/usr/bin/env bats
# Integration Tests for PRD Import

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/fixtures.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-import-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export RALPH_IMPORT="${BATS_TEST_DIRNAME}/../../ralph_import.sh"

    # Provide a lightweight ralph-setup stub so ralph_import can create projects
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/ralph-setup" << 'EOF'
#!/bin/bash
project_name="${1:-my-project}"
mkdir -p "$project_name/specs" "$project_name/src" "$project_name/examples" "$project_name/logs" "$project_name/docs/generated"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/ralph-setup"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "ralph-import creates project structure from markdown PRD" {
    create_sample_prd_md "sample-prd.md"

    run bash "$RALPH_IMPORT" sample-prd.md task-app
    assert_success

    assert_dir_exists "task-app"
    assert_file_exists "task-app/PROMPT.md"
    assert_file_exists "task-app/@fix_plan.md"
    assert_dir_exists "task-app/specs"

    run grep "Task Management Web App" "task-app/@fix_plan.md"
    assert_success
}

@test "ralph-import uses filename as default project name" {
    create_sample_prd_md "project-doc.md"

    run bash "$RALPH_IMPORT" project-doc.md
    assert_success

    assert_dir_exists "project-doc"
    assert_file_exists "project-doc/PROMPT.md"
    assert_file_exists "project-doc/@fix_plan.md"
}

@test "ralph-import supports JSON PRD files" {
    create_sample_prd_json "sample-prd.json"

    run bash "$RALPH_IMPORT" sample-prd.json json-project
    assert_success

    assert_dir_exists "json-project"
    assert_file_exists "json-project/specs/requirements.md"
    run grep "Task Management App" "json-project/specs/requirements.md"
    assert_success
}

@test "ralph-import errors on missing source file" {
    run bash "$RALPH_IMPORT" nonexistent-file.md
    assert_failure
}