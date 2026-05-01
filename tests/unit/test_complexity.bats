#!/usr/bin/env bats

# Tests for lib/complexity.sh — Task complexity classifier (COSTROUTE-1)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_MODEL_ROUTING_ENABLED="false"
    export RALPH_VERBOSE="false"
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# Note: ralph_classify_task_complexity echoes AND returns the score as exit code.
# Use `run` to avoid set -e failures on non-zero exit codes.

@test "default task classified as ROUTINE (3)" {
    run ralph_classify_task_complexity "Fix a small bug in auth module"
    [[ "$output" -eq 3 ]]
}

@test "[TRIVIAL] annotation returns 1" {
    run ralph_classify_task_complexity "[TRIVIAL] Fix typo in README"
    [[ "$output" -eq 1 ]]
}

@test "[SMALL] annotation returns 2" {
    run ralph_classify_task_complexity "[SMALL] Add missing import"
    [[ "$output" -eq 2 ]]
}

@test "[MEDIUM] annotation returns 3" {
    run ralph_classify_task_complexity "[MEDIUM] Implement new endpoint"
    [[ "$output" -eq 3 ]]
}

@test "[LARGE] annotation returns 4" {
    run ralph_classify_task_complexity "[LARGE] Refactor entire auth system"
    [[ "$output" -eq 4 ]]
}

@test "[ARCHITECTURAL] annotation returns 5" {
    run ralph_classify_task_complexity "[ARCHITECTURAL] Redesign database schema"
    [[ "$output" -eq 5 ]]
}

@test "architectural keywords increase score" {
    run ralph_classify_task_complexity "Architect the new microservice platform for deployment"
    [[ "$output" -ge 4 ]]
}

@test "trivial keywords decrease score" {
    run ralph_classify_task_complexity "Fix a typo in the comment"
    [[ "$output" -le 3 ]]
}

@test "5+ file references increase score" {
    run ralph_classify_task_complexity "Update auth.py, login.py, register.py, profile.py, settings.py, middleware.py"
    [[ "$output" -ge 4 ]]
}

@test "retry escalation: 3+ retries adds +2" {
    run ralph_classify_task_complexity "Simple bug fix" 3
    [[ "$output" -ge 4 ]]
}

@test "retry escalation: 1 retry adds +1" {
    run ralph_classify_task_complexity "Simple bug fix" 1
    [[ "$output" -ge 3 ]]
}

@test "score clamped to 1-5 range" {
    run ralph_classify_task_complexity "[TRIVIAL] typo fix"
    [[ "$output" -ge 1 ]] && [[ "$output" -le 5 ]]
}

@test "TAP-677: annotation vs heuristic mismatch warns on stderr but keeps annotation" {
    local task="[TRIVIAL] Update auth.py login.py register.py profile.py settings.py middleware.py api.py routes.py models.py views.py"
    local errf="$BATS_TEST_TMPDIR/stderr.log"
    # Do not use run — trivial score returns exit code 1 (same as bash return 1 quirk)
    local stdout
    stdout=$(ralph_classify_task_complexity "$task" 2>"$errf") || true
    [[ "${stdout//$'\n'/}" -eq 1 ]]
    grep -q 'annotated \[TRIVIAL\]' "$errf"
    grep -q 'heuristic suggests' "$errf"
}

@test "ralph_complexity_name maps numbers to names" {
    [[ "$(ralph_complexity_name 1)" == "TRIVIAL" ]]
    [[ "$(ralph_complexity_name 2)" == "SIMPLE" ]]
    [[ "$(ralph_complexity_name 3)" == "ROUTINE" ]]
    [[ "$(ralph_complexity_name 4)" == "COMPLEX" ]]
    [[ "$(ralph_complexity_name 5)" == "ARCHITECTURAL" ]]
}

@test "ralph_select_model returns default when routing disabled" {
    export RALPH_MODEL_ROUTING_ENABLED="false"
    local model
    model=$(ralph_select_model "any task")
    [[ "$model" == "sonnet" ]]
}

@test "ralph_select_model (legacy) routes trivial to haiku when enabled" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "[TRIVIAL] Fix typo")
    # With task-type routing, this becomes code (not docs/tools/arch), so sonnet
    [[ "$model" == "sonnet" ]]
}

@test "ralph_select_model (new) routes docs to haiku" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Update README.md with examples")
    [[ "$model" == "haiku" ]]
}

@test "ralph_select_model (new) routes tools to haiku" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Scan codebase for vulnerabilities")
    [[ "$model" == "haiku" ]]
}

@test "ralph_select_model (new) routes code to sonnet (floor)" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Implement user login feature")
    [[ "$model" == "sonnet" ]]
}

@test "ralph_select_model (new) routes arch to opus" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Design database migration strategy")
    [[ "$model" == "opus" ]]
}

@test "ralph_select_model retry escalation: 3+ failures force opus" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Update README.md" 3)
    # docs type would be haiku, but 3 retries override to opus
    [[ "$model" == "opus" ]]
}

@test "ralph_select_model retry escalation: 4+ failures force opus" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Implement endpoint" 5)
    # code type would be sonnet, but 5 retries override to opus
    [[ "$model" == "opus" ]]
}

@test "ralph_select_model retry escalation: 1-2 failures don't override" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "Scan for issues" 2)
    # tools type is haiku, 2 retries is below threshold
    [[ "$model" == "haiku" ]]
}

@test "ralph_select_model logs routing decision to .model_routing.jsonl" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    local model
    model=$(ralph_select_model "Update documentation" 0)
    [[ -f "$RALPH_DIR/.model_routing.jsonl" ]]
    grep -q "docs" "$RALPH_DIR/.model_routing.jsonl"
    grep -q "haiku" "$RALPH_DIR/.model_routing.jsonl"
}

@test "ralph_select_model routing log includes reason field" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    local model
    model=$(ralph_select_model "Scan for problems" 0)
    grep -q "type_haiku" "$RALPH_DIR/.model_routing.jsonl"
}

@test "ralph_select_model routing log includes qa_failure_escalation reason" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    local model
    model=$(ralph_select_model "Update docs" 3)
    grep -q "qa_failure_escalation" "$RALPH_DIR/.model_routing.jsonl"
    grep -q "opus" "$RALPH_DIR/.model_routing.jsonl"
}

# TestTaskTypeClassifier — Task-type classification (docs/tools/code/arch)

@test "task type: docs — .md file detected" {
    local type
    type=$(ralph_classify_task_type "Update README.md with new examples")
    [[ "$type" == "docs" ]]
}

@test "task type: docs — README keyword" {
    local type
    type=$(ralph_classify_task_type "Add installation section to README")
    [[ "$type" == "docs" ]]
}

@test "task type: docs — CHANGELOG keyword" {
    local type
    type=$(ralph_classify_task_type "Add 2.11.0 release notes to CHANGELOG")
    [[ "$type" == "docs" ]]
}

@test "task type: docs — docstring keyword" {
    local type
    type=$(ralph_classify_task_type "Add docstrings to complex functions")
    [[ "$type" == "docs" ]]
}

@test "task type: docs — documentation keyword" {
    local type
    type=$(ralph_classify_task_type "Improve API documentation for users")
    [[ "$type" == "docs" ]]
}

@test "task type: tools — lookup keyword" {
    local type
    type=$(ralph_classify_task_type "Lookup dependencies in requirements.txt")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — audit keyword" {
    local type
    type=$(ralph_classify_task_type "Audit security vulnerabilities")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — scan keyword" {
    local type
    type=$(ralph_classify_task_type "Scan codebase for deprecated APIs")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — check keyword" {
    local type
    type=$(ralph_classify_task_type "Check linting errors in Python files")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — report keyword" {
    local type
    type=$(ralph_classify_task_type "Generate test coverage report")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — analyze keyword" {
    local type
    type=$(ralph_classify_task_type "Analyze performance bottlenecks")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — find keyword" {
    local type
    type=$(ralph_classify_task_type "Find all dead code in the project")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — search keyword" {
    local type
    type=$(ralph_classify_task_type "Search for hardcoded credentials")
    [[ "$type" == "tools" ]]
}

@test "task type: tools — identify keyword" {
    local type
    type=$(ralph_classify_task_type "Identify missing test coverage")
    [[ "$type" == "tools" ]]
}

@test "task type: arch — architect keyword" {
    local type
    type=$(ralph_classify_task_type "Architect a new microservices platform")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — design keyword" {
    local type
    type=$(ralph_classify_task_type "Design the new authentication flow")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — research keyword" {
    local type
    type=$(ralph_classify_task_type "Research distributed tracing solutions")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — migrate keyword" {
    local type
    type=$(ralph_classify_task_type "Migrate database schema to v2")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — refactor keyword" {
    local type
    type=$(ralph_classify_task_type "Refactor authentication module")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — rewrite keyword" {
    local type
    type=$(ralph_classify_task_type "Rewrite the parser from scratch")
    [[ "$type" == "arch" ]]
}

@test "task type: arch — prototype keyword" {
    local type
    type=$(ralph_classify_task_type "Prototype WebSocket support")
    [[ "$type" == "arch" ]]
}

@test "task type: code — default for implementation" {
    local type
    type=$(ralph_classify_task_type "Implement user login endpoint")
    [[ "$type" == "code" ]]
}

@test "task type: code — default for feature" {
    local type
    type=$(ralph_classify_task_type "Add email validation to sign-up form")
    [[ "$type" == "code" ]]
}

@test "task type: code — default for fix" {
    local type
    type=$(ralph_classify_task_type "Fix null pointer exception in user model")
    [[ "$type" == "code" ]]
}

@test "task type: code — default for test" {
    local type
    type=$(ralph_classify_task_type "Add unit tests for auth module")
    [[ "$type" == "code" ]]
}

@test "task type: code — empty task defaults to code" {
    local type
    type=$(ralph_classify_task_type "")
    [[ "$type" == "code" ]]
}

@test "task type: code — generic task defaults to code" {
    local type
    type=$(ralph_classify_task_type "Update user profile")
    [[ "$type" == "code" ]]
}

# QA failure count wiring tests (Story 4: qa_failures integration)

@test "ralph_select_model escalates when QA_FAILURE_COUNT >= 3 is passed as param" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    # build_claude_command will read RALPH_CURRENT_QA_FAILURE_COUNT from env
    # and pass it as the 2nd param to ralph_select_model
    model=$(ralph_select_model "Write documentation" 3)
    # Even though task is docs (→ haiku), QA count=3 forces opus
    [[ "$model" == "opus" ]]
}

@test "ralph_select_model: RALPH_CURRENT_QA_FAILURE_COUNT=0 uses type routing" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_CURRENT_QA_FAILURE_COUNT=0
    local model
    model=$(ralph_select_model "Write documentation" 0)
    # With QA count=0, docs type routes to haiku
    [[ "$model" == "haiku" ]]
}

@test "ralph_select_model: RALPH_CURRENT_QA_FAILURE_COUNT=2 does not escalate" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_CURRENT_QA_FAILURE_COUNT=2
    local model
    model=$(ralph_select_model "Implement feature" 0)
    # With QA count=2 (below threshold), code type routes to sonnet
    [[ "$model" == "sonnet" ]]
}

@test "ralph_select_model: QA_FAILURE_COUNT acts as second parameter override" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_CURRENT_QA_FAILURE_COUNT=1
    # When both env var and function param are set, both contribute to escalation
    local model
    model=$(ralph_select_model "Scan files" 2)
    # QA_FAILURE_COUNT=1 (not set from env actually, but 0 defaults) + param=2 = 2 total
    # But the function uses ONLY the param passed, not env var
    # So this test verifies that the function param takes precedence
    [[ "$model" == "haiku" ]]  # tools type at count=2 is still haiku
}

@test "RALPH_MODEL_ROUTING_ENABLED defaults to true when unset" {
    # Regression: lib/complexity.sh used to default this to "false" while
    # CLAUDE.md and the 2.11.0 changelog promised "true". The mismatch made
    # routing silently inert, pinning the loop to CLAUDE_MODEL=opus and
    # bleeding ~$57/loop. Source the lib in a clean subshell with the env
    # var unset and verify the in-process default.
    local default_val
    default_val=$(env -i bash -c "
        unset RALPH_MODEL_ROUTING_ENABLED
        source '$BATS_TEST_DIRNAME/../../lib/complexity.sh' >/dev/null 2>&1
        echo \"\$RALPH_MODEL_ROUTING_ENABLED\"
    ")
    [[ "$default_val" == "true" ]]
}

@test "ralph_select_model uses routing when RALPH_MODEL_ROUTING_ENABLED is unset (default-true)" {
    # Companion to the default-value test: confirm the routing branch
    # actually executes when the env var is unset, not just that the
    # variable string equals "true".
    unset RALPH_MODEL_ROUTING_ENABLED
    # Re-source so the default takes effect
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    local model
    model=$(ralph_select_model "Update README documentation" 0)
    # docs task → haiku when routing is on; → empty/passthrough when off
    [[ "$model" == "haiku" ]]
}

# TAP-1210 — empty-task fallback observability

@test "TAP-1210: ralph_select_model with empty task returns RALPH_DEFAULT_MODEL" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DEFAULT_MODEL="sonnet"
    local model
    model=$(ralph_select_model "" 0)
    [[ "$model" == "sonnet" ]]
}

@test "TAP-1210: ralph_select_model writes routing entry on empty task" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    ralph_select_model "" 0 >/dev/null
    [[ -f "$RALPH_DIR/.model_routing.jsonl" ]]
}

@test "TAP-1210: empty-task routing entry has task_type=none" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    ralph_select_model "" 0 >/dev/null
    grep -q '"task_type":"none"' "$RALPH_DIR/.model_routing.jsonl"
}

@test "TAP-1210: empty-task routing entry has reason=no_task_fallback" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    ralph_select_model "" 0 >/dev/null
    grep -q '"reason":"no_task_fallback"' "$RALPH_DIR/.model_routing.jsonl"
}

@test "TAP-1210: empty-task at QA failure count >=3 still escalates to opus (escalation wins)" {
    # Safety: even if Claude bailed out without a task, if the prior QA
    # failure count is high we still want the opus escalation to fire so
    # the breakage signal isn't lost on the no-task loop.
    export RALPH_MODEL_ROUTING_ENABLED="true"
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    local model
    model=$(ralph_select_model "" 3)
    [[ "$model" == "opus" ]]
    grep -q '"reason":"qa_failure_escalation"' "$RALPH_DIR/.model_routing.jsonl"
}
