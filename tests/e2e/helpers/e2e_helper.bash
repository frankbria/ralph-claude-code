#!/usr/bin/env bash
# E2E Test Harness for Full Ralph Loop Execution (Issue #17)
#
# Unlike unit/integration tests (which source functions), this harness runs
# ralph_loop.sh as a TRUE SUBPROCESS with a real executable mock `claude` CLI.
# The mock lives on disk (not a bash function) so it survives the subprocess
# boundary, logs the argv of every invocation, and replays scripted JSON
# responses with optional side effects (file creation, fix_plan edits).
#
# Layout created by setup_e2e_project:
#   $E2E_DIR/
#   ├── bin/claude            # executable mock CLI
#   ├── mock/
#   │   ├── calls/.count      # mock invocation counter
#   │   ├── calls/argv_N.log  # argv of call N (one arg per line)
#   │   ├── responses/N.out   # stdout for call N (default.out as fallback)
#   │   ├── responses/N.exit  # exit code for call N (default 0)
#   │   ├── responses/N.sleep # seconds to sleep before responding
#   │   └── effects/N.sh      # side-effect script run (in project cwd) on call N
#   └── project/              # full Ralph project (git repo, .ralph/, .ralphrc)

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

# Cross-platform GNU timeout via the shared detection in lib/timeout_utils.sh
# (Linux: `timeout`; macOS: `gtimeout` from Homebrew coreutils). The harness
# invokes the binary directly rather than through portable_timeout() because
# it needs the --foreground/-k flags, which that wrapper does not pass through.
source "${BATS_TEST_DIRNAME}/../../lib/timeout_utils.sh"
# Soft-fail at load: unit tests of the assertion helpers (test_e2e_helper.bats)
# don't need a timeout binary, so missing coreutils must not abort the whole
# suite at source time. setup_e2e_project enforces the hard requirement.
if ! E2E_TIMEOUT_CMD="$(detect_timeout_command)"; then
    E2E_TIMEOUT_CMD=""
fi

# Create a complete temp Ralph project + mock claude CLI, and cd into it.
# Sets: E2E_DIR, MOCK_DIR, PROJECT_DIR
setup_e2e_project() {
    if [[ -z "$E2E_TIMEOUT_CMD" ]]; then
        echo "FATAL: E2E tests require GNU timeout (brew install coreutils on macOS)" >&2
        return 1
    fi

    E2E_DIR="$(mktemp -d)"
    MOCK_DIR="$E2E_DIR/mock"
    PROJECT_DIR="$E2E_DIR/project"
    mkdir -p "$MOCK_DIR"/{responses,effects,calls} "$E2E_DIR/bin" "$PROJECT_DIR"

    install_mock_claude

    cd "$PROJECT_DIR" || return 1
    git init -q
    git config user.email "e2e@test.local"
    git config user.name "E2E Test"

    # .ralph/ is gitignored so per-loop state writes (status.json, logs, analysis
    # files) never count as git progress — only deliberate src/ changes made by
    # mock side effects feed the circuit breaker's progress detection.
    printf '.ralph/\n' > .gitignore

    mkdir -p .ralph/logs src
    cat > .ralph/PROMPT.md << 'EOF'
# E2E Test Prompt
Work through .ralph/fix_plan.md one item at a time.
EOF
    e2e_fix_plan 3 0
    cat > .ralph/AGENT.md << 'EOF'
# Agent Instructions
Build: none. Test: none. This is an E2E fixture project.
EOF
    # Minimal .ralphrc: must exist for the integrity check; intentionally empty
    # of overrides so env vars and CLI flags drive each test's configuration.
    cat > .ralphrc << 'EOF'
# E2E test project configuration
EOF
    echo "fixture" > src/seed.txt
    git add -A
    git commit -qm "e2e: initial fixture project"

    # Subprocess configuration (env vars win over .ralphrc; defaults use :-)
    export CLAUDE_CODE_CMD="$E2E_DIR/bin/claude"
    export CLAUDE_AUTO_UPDATE=false          # never touch the npm registry
    export ENABLE_NOTIFICATIONS=false
    export ENABLE_BACKUP=false
    export CLAUDE_TIMEOUT_MINUTES=1
    export CLAUDE_USE_CONTINUE=false         # tests opt in to session continuity
    # Hermeticity: a developer's exported model/effort overrides would
    # otherwise leak extra flags into the mock's argv
    unset CLAUDE_MODEL CLAUDE_EFFORT
}

teardown_e2e_project() {
    # Kill any stray subprocesses anchored in the temp dir (background ralph,
    # sleeping mock claude), then remove the tree.
    if [[ -n "$E2E_DIR" && -d "$E2E_DIR" ]]; then
        pkill -9 -f "$E2E_DIR" 2>/dev/null || true
        cd /
        rm -rf "$E2E_DIR"
    fi
}

# Write the mock claude executable. Behavior per invocation:
#   --version            → prints a modern version and exits
#   anything else        → bumps call counter, logs argv, runs effects/N.sh
#                          (cwd = project dir), sleeps responses/N.sleep if
#                          present, cats responses/N.out (or default.out),
#                          exits with responses/N.exit (default 0)
install_mock_claude() {
    cat > "$E2E_DIR/bin/claude" << EOF
#!/usr/bin/env bash
MOCK_DIR="$MOCK_DIR"
EOF
    cat >> "$E2E_DIR/bin/claude" << 'EOF'
if [[ "$1" == "--version" ]]; then
    echo "2.99.0 (Claude Code)"
    exit 0
fi

n=$(( $(cat "$MOCK_DIR/calls/.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$MOCK_DIR/calls/.count"
printf '%s\n' "$@" > "$MOCK_DIR/calls/argv_${n}.log"

if [[ -f "$MOCK_DIR/effects/${n}.sh" ]]; then
    bash "$MOCK_DIR/effects/${n}.sh" >/dev/null 2>&1
fi

# ralph_loop.sh treats any process that exits within ~1s as an immediate
# startup failure (Issue #97 early-failure detection), so the mock must take
# realistically long. Override per call with responses/N.sleep.
if [[ -f "$MOCK_DIR/responses/${n}.sleep" ]]; then
    sleep "$(cat "$MOCK_DIR/responses/${n}.sleep")"
else
    sleep 1.5
fi

exit_code=0
if [[ -f "$MOCK_DIR/responses/${n}.exit" ]]; then
    exit_code=$(cat "$MOCK_DIR/responses/${n}.exit")
fi

if [[ -f "$MOCK_DIR/responses/${n}.out" ]]; then
    cat "$MOCK_DIR/responses/${n}.out"
elif [[ -f "$MOCK_DIR/responses/default.out" ]]; then
    cat "$MOCK_DIR/responses/default.out"
fi

exit "$exit_code"
EOF
    chmod +x "$E2E_DIR/bin/claude"

    # Default response: benign no-progress JSON. If a runaway loop makes more
    # calls than a test scripted, the circuit breaker halts it (and the outer
    # `timeout` wrapper is the final backstop).
    e2e_response_json "IN_PROGRESS" "false" "Analyzing the codebase structure." \
        > "$MOCK_DIR/responses/default.out"
}

# Build a flat Claude-CLI-format JSON response with an embedded RALPH_STATUS
# block (the format parse_json_response extracts EXIT_SIGNAL from).
# Usage: e2e_response_json STATUS EXIT_SIGNAL TEXT [SESSION_ID] [EXTRA_JQ_FIELDS]
#   EXTRA_JQ_FIELDS: optional jq object suffix, e.g. '+ {work_type: "TEST_ONLY"}'
e2e_response_json() {
    local status=$1
    local exit_signal=$2
    local text=$3
    local session_id=${4:-}
    local extra=${5:-}

    local result_text="$text

---RALPH_STATUS---
STATUS: $status
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 1
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: $exit_signal
RECOMMENDATION: none
---END_RALPH_STATUS---"

    jq -cn \
        --arg result "$result_text" \
        --arg sid "$session_id" \
        '{
            type: "result",
            subtype: "success",
            is_error: false,
            duration_ms: 1200,
            result: $result,
            usage: {input_tokens: 100, output_tokens: 50}
        }
        + (if $sid != "" then {session_id: $sid} else {} end)'"${extra:+ $extra}"
}

# Queue a response for mock call N.
# Usage: queue_response N STATUS EXIT_SIGNAL TEXT [SESSION_ID] [EXTRA_JQ_FIELDS]
queue_response() {
    local n=$1; shift
    e2e_response_json "$@" > "$MOCK_DIR/responses/${n}.out"
}

# Queue raw stdout + exit code for mock call N (for non-JSON failure scenarios).
# Usage: queue_raw_response N EXIT_CODE <<< "output text"
queue_raw_response() {
    local n=$1
    local exit_code=$2
    cat > "$MOCK_DIR/responses/${n}.out"
    echo "$exit_code" > "$MOCK_DIR/responses/${n}.exit"
}

# Queue a side-effect script for mock call N (runs with cwd = project dir).
# Usage: queue_effect N <<'EOF' ... EOF
queue_effect() {
    local n=$1
    cat > "$MOCK_DIR/effects/${n}.sh"
}

# Standard "productive work" effect: create + stage a src file (git progress
# for the circuit breaker) and check off the first open fix_plan item.
# Uses awk (not GNU `sed -i '0,...'`) so the effect runs on BSD/macOS too.
queue_productive_effect() {
    local n=$1
    queue_effect "$n" << EOF
echo "work from loop $n" > "src/work_${n}.txt"
git add "src/work_${n}.txt"
awk 'done != 1 && /^- \[ \]/ { sub(/^- \[ \]/, "- [x]"); done = 1 } { print }' \
    .ralph/fix_plan.md > .ralph/fix_plan.md.tmp \
    && mv .ralph/fix_plan.md.tmp .ralph/fix_plan.md
EOF
}

# Write .ralph/fix_plan.md with N unchecked and M checked items.
e2e_fix_plan() {
    local unchecked=${1:-3}
    local checked=${2:-0}
    {
        echo "# E2E Fix Plan"
        echo ""
        local i
        for ((i = 1; i <= checked; i++)); do
            echo "- [x] Completed task $i"
        done
        for ((i = 1; i <= unchecked; i++)); do
            echo "- [ ] Open task $i"
        done
    } > .ralph/fix_plan.md
}

# Record the hour a ralph run started / ended (Issue #285). File-based so the
# markers survive the subshell that bats `run` executes run_ralph in. Tests
# that invoke ralph_loop.sh directly (not via run_ralph) must call both
# themselves — e2e_mark_run_end as soon as the run is over, BEFORE asserting,
# so a boundary crossed while waiting to assert doesn't suppress the check.
e2e_mark_run_start() {
    date +%Y%m%d%H > "$E2E_DIR/.run_start_hour"
}

e2e_mark_run_end() {
    date +%Y%m%d%H > "$E2E_DIR/.run_end_hour"
}

# True if the clock crossed an hour boundary DURING the run (start marker vs
# end marker; falls back to the current hour when no end was recorded).
# init_call_tracking runs at the top of every loop iteration and zeroes
# .ralph/.call_count when the hour changes (the designed hourly rate-limit
# reset), so raw counter values are only assertable when this is false.
e2e_hour_rolled_over() {
    local start_hour=""
    if [[ -f "$E2E_DIR/.run_start_hour" ]]; then
        start_hour=$(cat "$E2E_DIR/.run_start_hour")
    fi
    local end_hour
    if [[ -f "$E2E_DIR/.run_end_hour" ]]; then
        end_hour=$(cat "$E2E_DIR/.run_end_hour")
    else
        end_hour=$(date +%Y%m%d%H)
    fi
    [[ -n "$start_hour" && "$start_hour" != "$end_hour" ]]
}

# Assert the raw .ralph/.call_count value — unless the run crossed an hour
# boundary, in which case the hourly reset legitimately zeroed it (Issue #285)
# and the check is skipped. mock_call_count remains the unconditional proof of
# how many times the CLI was invoked.
# Usage: assert_call_count EXPECTED
assert_call_count() {
    local expected=$1
    if e2e_hour_rolled_over; then
        echo "# raw .call_count assertion skipped: run crossed an hour boundary (Issue #285)"
        return 0
    fi
    assert_equal "$(cat .ralph/.call_count)" "$expected"
}

# Run ralph_loop.sh as a subprocess under a hard timeout (never hang CI).
# -k is required: ralph traps SIGTERM (cleanup handler) without exiting, so
# a plain `timeout` would deliver TERM and then wait forever.
# Usage: run_ralph [args...]   — use with bats `run`
run_ralph() {
    e2e_mark_run_start
    local rc=0
    "$E2E_TIMEOUT_CMD" --foreground -k 5 120 bash "$RALPH_SCRIPT" "$@" < /dev/null || rc=$?
    e2e_mark_run_end
    return $rc
}

# Number of times the mock claude was invoked.
mock_call_count() {
    cat "$MOCK_DIR/calls/.count" 2>/dev/null || echo 0
}

# Read a field from .ralph/status.json.
status_field() {
    jq -r ".$1" .ralph/status.json
}

# Poll a jq condition against status.json until true or timeout (seconds).
# Usage: wait_for_status '.status == "interrupted"' 25
wait_for_status() {
    local condition=$1
    local timeout_s=${2:-20}
    local waited=0
    while (( waited < timeout_s * 10 )); do
        if [[ -f .ralph/status.json ]] \
           && jq -e "$condition" .ralph/status.json >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}
