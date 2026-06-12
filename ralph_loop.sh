#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

# Note: CLAUDE_CODE_ENABLE_DANGEROUS_PERMISSIONS_IN_SANDBOX and IS_SANDBOX
# environment variables are NOT exported here. Tool restrictions are handled
# via --allowedTools flag in CLAUDE_CMD_ARGS, which is the proper approach.
# Exporting sandbox variables without a verified sandbox would be misleading.

# Issue #74: capture sandbox environment state BEFORE sourcing the libraries —
# lib/sandbox_docker.sh sets defaults for these at source time, so capturing
# after (like the main _env_* block below) would treat lib defaults as
# user-provided environment values and break .ralphrc overrides.
_env_SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-}"
_env_SANDBOX_DOCKER_IMAGE="${SANDBOX_DOCKER_IMAGE:-}"
_env_SANDBOX_DOCKER_MEMORY="${SANDBOX_DOCKER_MEMORY:-}"
_env_SANDBOX_DOCKER_CPUS="${SANDBOX_DOCKER_CPUS:-}"
_env_SANDBOX_DOCKER_NETWORK="${SANDBOX_DOCKER_NETWORK:-}"
# Issue #75: E2B sandbox environment state (lib/sandbox_e2b.sh sets defaults
# at source time, so these must be captured before the source block too)
_env_SANDBOX_E2B_TEMPLATE="${SANDBOX_E2B_TEMPLATE:-}"
_env_SANDBOX_E2B_SANDBOX_ID="${SANDBOX_E2B_SANDBOX_ID:-}"
_env_SANDBOX_E2B_TIMEOUT="${SANDBOX_E2B_TIMEOUT:-}"
_env_SANDBOX_E2B_KEEP_ALIVE="${SANDBOX_E2B_KEEP_ALIVE:-}"
_env_SANDBOX_E2B_MAX_COST="${SANDBOX_E2B_MAX_COST:-}"
_env_SANDBOX_E2B_COST_ALERT="${SANDBOX_E2B_COST_ALERT:-}"
_env_SANDBOX_E2B_COST_PER_HOUR="${SANDBOX_E2B_COST_PER_HOUR:-}"
# Issue #76: sandbox sync filter environment state (lib/sync.sh sets defaults
# at source time, so these must be captured before the source block too)
_env_SYNC_INCLUDE="${SYNC_INCLUDE:-}"
_env_SYNC_EXCLUDE="${SYNC_EXCLUDE:-}"
_env_SYNC_MAX_FILE_SIZE="${SYNC_MAX_FILE_SIZE:-}"
_env_SYNC_LARGE_FILE_ACTION="${SYNC_LARGE_FILE_ACTION:-}"

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh" || { echo "FATAL: Failed to source lib/date_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/timeout_utils.sh" || { echo "FATAL: Failed to source lib/timeout_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/response_analyzer.sh" || { echo "FATAL: Failed to source lib/response_analyzer.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/circuit_breaker.sh" || { echo "FATAL: Failed to source lib/circuit_breaker.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/file_protection.sh" || { echo "FATAL: Failed to source lib/file_protection.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/log_utils.sh" || { echo "FATAL: Failed to source lib/log_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/github_lifecycle.sh" || { echo "FATAL: Failed to source lib/github_lifecycle.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/sync.sh" || { echo "FATAL: Failed to source lib/sync.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/sandbox_docker.sh" || { echo "FATAL: Failed to source lib/sandbox_docker.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/sandbox_e2b.sh" || { echo "FATAL: Failed to source lib/sandbox_e2b.sh" >&2; exit 1; }

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
SLEEP_DURATION=3600     # 1 hour in seconds
LIVE_OUTPUT=false       # Show Claude Code output in real-time (streaming)
LIVE_LOG_FILE="$RALPH_DIR/live.log"  # Fixed file for live output monitoring
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_MAX_TOKENS_PER_HOUR="${MAX_TOKENS_PER_HOUR:-}"
_env_CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-}"
_env_CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-}"
_env_CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-}"
_env_CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-}"
_env_CLAUDE_SESSION_EXPIRY_HOURS="${CLAUDE_SESSION_EXPIRY_HOURS:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-}"
_env_CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-}"
_env_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
_env_CLAUDE_EFFORT="${CLAUDE_EFFORT:-}"
_env_RALPH_SHELL_INIT_FILE="${RALPH_SHELL_INIT_FILE:-}"
_env_ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-}"
_env_ENABLE_BACKUP="${ENABLE_BACKUP:-}"
_env_LIVE_SHOW_TOOL_ARGS="${LIVE_SHOW_TOOL_ARGS:-}"
_env_OPTIONAL_SECTIONS="${OPTIONAL_SECTIONS:-}"
# Issue #73: GitHub issue lifecycle configuration
_env_GITHUB_ISSUE="${GITHUB_ISSUE:-}"
_env_COMMENT_PROGRESS="${COMMENT_PROGRESS:-}"
_env_COMMENT_INTERVAL="${COMMENT_INTERVAL:-}"
_env_AUTO_CLOSE="${AUTO_CLOSE:-}"
_env_CLOSE_SUMMARY="${CLOSE_SUMMARY:-}"
_env_CREATE_PR="${CREATE_PR:-}"
_env_LINK_ISSUE="${LINK_ISSUE:-}"
_env_DRAFT_PR="${DRAFT_PR:-}"
_env_CREATE_FOLLOWUPS="${CREATE_FOLLOWUPS:-}"
_env_FOLLOWUP_LABEL="${FOLLOWUP_LABEL:-}"
_env_ADD_COMPLETION_LABELS="${ADD_COMPLETION_LABELS:-}"

# Now set defaults (only if not already set by environment)
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
MAX_TOKENS_PER_HOUR="${MAX_TOKENS_PER_HOUR:-0}"      # 0 = disabled; set to limit cumulative tokens/hour
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"

# Modern Claude CLI configuration (Phase 1.1)
CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-json}"
# Safe git subcommands only - broad Bash(git *) allows destructive commands like git clean/git rm (Issue #149)
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pytest)}"
CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-true}"
CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id" # Session ID persistence file
CLAUDE_MIN_VERSION="2.0.76"              # Minimum required Claude CLI version
CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-true}"  # Auto-update Claude CLI at startup
CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-claude}"     # Claude Code CLI command (default: global install)
CLAUDE_MODEL="${CLAUDE_MODEL:-}"                 # Model override (e.g. claude-sonnet-4-6); empty = CLI default
CLAUDE_EFFORT="${CLAUDE_EFFORT:-}"               # Effort level override (e.g. high, low); empty = CLI default
RALPH_SHELL_INIT_FILE="${RALPH_SHELL_INIT_FILE:-}" # Shell init file to source before running claude (e.g. ~/.zshrc)
DRY_RUN="${DRY_RUN:-false}"                      # Simulate loop without making actual Claude API calls
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-false}"  # Enable desktop notifications; set true or use --notify flag
ENABLE_BACKUP="${ENABLE_BACKUP:-false}"               # Enable automatic git backups before each loop; set true or use --backup flag
LIVE_SHOW_TOOL_ARGS="${LIVE_SHOW_TOOL_ARGS:-false}"  # Show tool arguments in live streaming output (file paths, commands, patterns)
# Issue #239: comma-separated fix_plan.md section titles whose unchecked items do NOT block the
# plan-complete exit (case-insensitive). Lets users mark truly optional/future work as non-blocking.
OPTIONAL_SECTIONS="${OPTIONAL_SECTIONS:-Optional,Future,Future Enhancements,Nice to Have}"
# Issue #73: GitHub issue lifecycle management (all opt-in; require --github-issue)
GITHUB_ISSUE="${GITHUB_ISSUE:-}"                       # Issue reference: N, #N, owner/repo#N, or URL
COMMENT_PROGRESS="${COMMENT_PROGRESS:-false}"          # Post progress comments during development
COMMENT_INTERVAL="${COMMENT_INTERVAL:-5}"              # Post a progress comment every N loops
AUTO_CLOSE="${AUTO_CLOSE:-false}"                      # Close the issue on graceful completion
CLOSE_SUMMARY="${CLOSE_SUMMARY:-false}"                # Post a summary comment on completion
CREATE_PR="${CREATE_PR:-false}"                        # Create a PR on completion
LINK_ISSUE="${LINK_ISSUE:-false}"                      # Add "Closes #N" to the PR body
DRAFT_PR="${DRAFT_PR:-false}"                          # Create the PR as a draft
CREATE_FOLLOWUPS="${CREATE_FOLLOWUPS:-false}"          # Open a follow-up issue for discovered TODOs
FOLLOWUP_LABEL="${FOLLOWUP_LABEL:-tech-debt}"          # Label applied to follow-up issues
ADD_COMPLETION_LABELS="${ADD_COMPLETION_LABELS:-}"     # Comma-separated labels added to the issue on close
# Issue #74: Docker sandbox execution (lib/sandbox_docker.sh sets the same
# defaults at source time; repeated here so the configuration surface is visible)
SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-}"                          # "" = host execution; "docker" = sandboxed
SANDBOX_DOCKER_IMAGE="${SANDBOX_DOCKER_IMAGE:-ralph-sandbox:latest}"  # Container image for sandboxed execution
SANDBOX_DOCKER_MEMORY="${SANDBOX_DOCKER_MEMORY:-4g}"              # Container memory limit
SANDBOX_DOCKER_CPUS="${SANDBOX_DOCKER_CPUS:-2}"                   # Container CPU limit
SANDBOX_DOCKER_NETWORK="${SANDBOX_DOCKER_NETWORK:-bridge}"        # none | bridge | host (bridge: Claude API reachable)
# Issue #75: E2B cloud sandbox execution (lib/sandbox_e2b.sh sets the same
# defaults at source time; repeated here so the configuration surface is visible)
SANDBOX_E2B_TEMPLATE="${SANDBOX_E2B_TEMPLATE:-base}"              # E2B template (custom templates can preinstall claude)
SANDBOX_E2B_SANDBOX_ID="${SANDBOX_E2B_SANDBOX_ID:-}"              # Reconnect to an existing sandbox instead of creating one
SANDBOX_E2B_TIMEOUT="${SANDBOX_E2B_TIMEOUT:-3600}"                # Sandbox session timeout in seconds
SANDBOX_E2B_KEEP_ALIVE="${SANDBOX_E2B_KEEP_ALIVE:-false}"         # Leave the sandbox running on exit (reuse via --sandbox-id)
SANDBOX_E2B_MAX_COST="${SANDBOX_E2B_MAX_COST:-}"                  # Stop gracefully once estimated cost reaches this USD amount
SANDBOX_E2B_COST_ALERT="${SANDBOX_E2B_COST_ALERT:-}"              # Warn once when estimated cost reaches this USD amount
SANDBOX_E2B_COST_PER_HOUR="${SANDBOX_E2B_COST_PER_HOUR:-0.10}"    # Estimated $/h used for cost tracking (see e2b.dev/pricing)
# Issue #76: sandbox sync filtering (lib/sync.sh sets the same defaults at
# source time; repeated here so the configuration surface is visible).
# Applies to --sandbox e2b only — the Docker bind mount shares the whole
# project in real time, so there is nothing to filter.
SYNC_INCLUDE="${SYNC_INCLUDE:-}"                                  # Comma-separated patterns; only matches upload (.ralph control files always go)
SYNC_EXCLUDE="${SYNC_EXCLUDE:-}"                                  # Comma-separated patterns excluded from upload AND download
SYNC_MAX_FILE_SIZE="${SYNC_MAX_FILE_SIZE:-10485760}"              # Upload size threshold in bytes (0 = unlimited)
SYNC_LARGE_FILE_ACTION="${SYNC_LARGE_FILE_ACTION:-warn}"          # warn (keep) or skip (drop) files over the threshold

# Session management configuration (Phase 1.2)
# Note: SESSION_EXPIRATION_SECONDS is defined in lib/response_analyzer.sh (86400 = 24 hours)
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CLAUDE_SESSION_EXPIRY_HOURS=${CLAUDE_SESSION_EXPIRY_HOURS:-24}

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "NotebookEdit"
)

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# _safe_count - Count regex matches in a file safely for bash arithmetic.
# Fixes #255, #251, #260 — `$(grep -cE … || echo "0")` can return:
#   - "0\n0" when grep has no matches AND fallback echo also fires
#   - "5\r" when file has CRLF line endings (Windows/macOS-edited files)
# Both cause `$((var + var))` arithmetic syntax errors.
# This helper normalizes output to a single integer with no whitespace.
# Usage: count=$(_safe_count "pattern" "$file")
_safe_count() {
    local pattern="$1"
    local file="$2"
    [[ ! -f "$file" ]] && { printf '0'; return 0; }
    local raw
    raw=$(grep -cE "$pattern" "$file" 2>/dev/null | tr -d '\r\n[:space:]' | head -c 10)
    # Validate result is a non-negative integer; fallback to 0
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%d' "$raw"
    else
        printf '0'
    fi
}

# _count_blocking_unchecked - Count unchecked "- [ ]" items that BLOCK the plan-complete exit.
# Issue #239: unchecked items under "Optional"/"Future" sections do NOT block exit, resolving
# the deadlock where Claude treats "Low Priority"/optional items as skippable while Ralph keeps
# looping waiting for them. A heading marks its section optional when the heading title matches
# (case-insensitive, trimmed) an entry in $OPTIONAL_SECTIONS (comma-separated). The optional
# context persists into deeper subsections and closes at the next same-or-higher-level heading.
# With no optional sections configured (or none present) this counts every unchecked item, so
# behavior is identical to the previous full-file count (backward compatible).
# Usage: count=$(_count_blocking_unchecked "$file")
_count_blocking_unchecked() {
    local file="$1"
    [[ ! -f "$file" ]] && { printf '0'; return 0; }
    local raw
    raw=$(awk -v sections="${OPTIONAL_SECTIONS:-}" '
        BEGIN {
            n = split(sections, arr, ",")
            for (i = 1; i <= n; i++) {
                s = arr[i]
                gsub(/^[ \t]+|[ \t]+$/, "", s)
                if (s != "") opt[tolower(s)] = 1
            }
        }
        # ATX heading (requires "# " — a space after the #s): track optional context by level
        /^[[:space:]]*#+[[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            level = 0
            while (substr(line, level + 1, 1) == "#") level++
            title = substr(line, level + 1)
            sub(/^[[:space:]]+/, "", title)
            sub(/[[:space:]]+$/, "", title)
            if (optional_active && level <= optional_level) optional_active = 0
            if (tolower(title) in opt) { optional_active = 1; optional_level = level }
            next
        }
        # Unchecked checkbox outside any optional section blocks exit
        !optional_active && /^[[:space:]]*- \[ \]/ { count++ }
        END { print count + 0 }
    ' "$file" 2>/dev/null | tr -d '\r\n[:space:]' | head -c 10)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%d' "$raw"
    else
        printf '0'
    fi
}

# .ralphrc configuration file
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - MAX_TOKENS_PER_HOUR (cumulative token limit per hour; 0 = disabled)
#   - CLAUDE_TIMEOUT_MINUTES
#   - CLAUDE_OUTPUT_FORMAT
#   - ALLOWED_TOOLS (mapped to CLAUDE_ALLOWED_TOOLS)
#   - SESSION_CONTINUITY (mapped to CLAUDE_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CLAUDE_SESSION_EXPIRY_HOURS)
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#   - CLAUDE_CODE_CMD (path or command for Claude Code CLI)
#   - CLAUDE_AUTO_UPDATE (auto-update Claude CLI at startup)
#   - RALPH_SHELL_INIT_FILE (shell init file to source before running claude)
#   - OPTIONAL_SECTIONS (fix_plan.md sections whose unchecked items don't block exit, Issue #239)
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
        CLAUDE_ALLOWED_TOOLS="$ALLOWED_TOOLS"
    fi
    if [[ -n "${SESSION_CONTINUITY:-}" ]]; then
        CLAUDE_USE_CONTINUE="$SESSION_CONTINUITY"
    fi
    if [[ -n "${SESSION_EXPIRY_HOURS:-}" ]]; then
        CLAUDE_SESSION_EXPIRY_HOURS="$SESSION_EXPIRY_HOURS"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore ONLY values that were explicitly set via environment variables
    # (not script defaults). The _env_* variables were captured BEFORE defaults were set.
    # If _env_* is non-empty, the user explicitly set it in their environment.
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_MAX_TOKENS_PER_HOUR" ]] && MAX_TOKENS_PER_HOUR="$_env_MAX_TOKENS_PER_HOUR"
    [[ -n "$_env_CLAUDE_TIMEOUT_MINUTES" ]] && CLAUDE_TIMEOUT_MINUTES="$_env_CLAUDE_TIMEOUT_MINUTES"
    [[ -n "$_env_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_env_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_env_CLAUDE_ALLOWED_TOOLS" ]] && CLAUDE_ALLOWED_TOOLS="$_env_CLAUDE_ALLOWED_TOOLS"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"
    [[ -n "$_env_CLAUDE_MODEL" ]] && CLAUDE_MODEL="$_env_CLAUDE_MODEL"
    [[ -n "$_env_CLAUDE_EFFORT" ]] && CLAUDE_EFFORT="$_env_CLAUDE_EFFORT"
    [[ -n "$_env_RALPH_SHELL_INIT_FILE" ]] && RALPH_SHELL_INIT_FILE="$_env_RALPH_SHELL_INIT_FILE"
    [[ -n "$_env_ENABLE_NOTIFICATIONS" ]] && ENABLE_NOTIFICATIONS="$_env_ENABLE_NOTIFICATIONS"
    [[ -n "$_env_ENABLE_BACKUP" ]] && ENABLE_BACKUP="$_env_ENABLE_BACKUP"
    [[ -n "$_env_LIVE_SHOW_TOOL_ARGS" ]] && LIVE_SHOW_TOOL_ARGS="$_env_LIVE_SHOW_TOOL_ARGS"
    [[ -n "$_env_OPTIONAL_SECTIONS" ]] && OPTIONAL_SECTIONS="$_env_OPTIONAL_SECTIONS"
    [[ -n "$_env_GITHUB_ISSUE" ]] && GITHUB_ISSUE="$_env_GITHUB_ISSUE"
    [[ -n "$_env_COMMENT_PROGRESS" ]] && COMMENT_PROGRESS="$_env_COMMENT_PROGRESS"
    [[ -n "$_env_COMMENT_INTERVAL" ]] && COMMENT_INTERVAL="$_env_COMMENT_INTERVAL"
    [[ -n "$_env_AUTO_CLOSE" ]] && AUTO_CLOSE="$_env_AUTO_CLOSE"
    [[ -n "$_env_CLOSE_SUMMARY" ]] && CLOSE_SUMMARY="$_env_CLOSE_SUMMARY"
    [[ -n "$_env_CREATE_PR" ]] && CREATE_PR="$_env_CREATE_PR"
    [[ -n "$_env_LINK_ISSUE" ]] && LINK_ISSUE="$_env_LINK_ISSUE"
    [[ -n "$_env_DRAFT_PR" ]] && DRAFT_PR="$_env_DRAFT_PR"
    [[ -n "$_env_CREATE_FOLLOWUPS" ]] && CREATE_FOLLOWUPS="$_env_CREATE_FOLLOWUPS"
    [[ -n "$_env_FOLLOWUP_LABEL" ]] && FOLLOWUP_LABEL="$_env_FOLLOWUP_LABEL"
    [[ -n "$_env_ADD_COMPLETION_LABELS" ]] && ADD_COMPLETION_LABELS="$_env_ADD_COMPLETION_LABELS"
    [[ -n "$_env_SANDBOX_PROVIDER" ]] && SANDBOX_PROVIDER="$_env_SANDBOX_PROVIDER"
    [[ -n "$_env_SANDBOX_DOCKER_IMAGE" ]] && SANDBOX_DOCKER_IMAGE="$_env_SANDBOX_DOCKER_IMAGE"
    [[ -n "$_env_SANDBOX_DOCKER_MEMORY" ]] && SANDBOX_DOCKER_MEMORY="$_env_SANDBOX_DOCKER_MEMORY"
    [[ -n "$_env_SANDBOX_DOCKER_CPUS" ]] && SANDBOX_DOCKER_CPUS="$_env_SANDBOX_DOCKER_CPUS"
    [[ -n "$_env_SANDBOX_DOCKER_NETWORK" ]] && SANDBOX_DOCKER_NETWORK="$_env_SANDBOX_DOCKER_NETWORK"
    [[ -n "$_env_SANDBOX_E2B_TEMPLATE" ]] && SANDBOX_E2B_TEMPLATE="$_env_SANDBOX_E2B_TEMPLATE"
    [[ -n "$_env_SANDBOX_E2B_SANDBOX_ID" ]] && SANDBOX_E2B_SANDBOX_ID="$_env_SANDBOX_E2B_SANDBOX_ID"
    [[ -n "$_env_SANDBOX_E2B_TIMEOUT" ]] && SANDBOX_E2B_TIMEOUT="$_env_SANDBOX_E2B_TIMEOUT"
    [[ -n "$_env_SANDBOX_E2B_KEEP_ALIVE" ]] && SANDBOX_E2B_KEEP_ALIVE="$_env_SANDBOX_E2B_KEEP_ALIVE"
    [[ -n "$_env_SANDBOX_E2B_MAX_COST" ]] && SANDBOX_E2B_MAX_COST="$_env_SANDBOX_E2B_MAX_COST"
    [[ -n "$_env_SANDBOX_E2B_COST_ALERT" ]] && SANDBOX_E2B_COST_ALERT="$_env_SANDBOX_E2B_COST_ALERT"
    [[ -n "$_env_SANDBOX_E2B_COST_PER_HOUR" ]] && SANDBOX_E2B_COST_PER_HOUR="$_env_SANDBOX_E2B_COST_PER_HOUR"
    [[ -n "$_env_SYNC_INCLUDE" ]] && SYNC_INCLUDE="$_env_SYNC_INCLUDE"
    [[ -n "$_env_SYNC_EXCLUDE" ]] && SYNC_EXCLUDE="$_env_SYNC_EXCLUDE"
    [[ -n "$_env_SYNC_MAX_FILE_SIZE" ]] && SYNC_MAX_FILE_SIZE="$_env_SYNC_MAX_FILE_SIZE"
    [[ -n "$_env_SYNC_LARGE_FILE_ACTION" ]] && SYNC_LARGE_FILE_ACTION="$_env_SYNC_LARGE_FILE_ACTION"

    RALPHRC_LOADED=true
    return 0
}

# validate_claude_command - Verify the Claude Code CLI is available
#
# Checks that CLAUDE_CODE_CMD resolves to an executable command.
# For npx-based commands, validates that npx is available.
# Returns 0 if valid, 1 if not found (with helpful error message).
#
validate_claude_command() {
    local cmd="$CLAUDE_CODE_CMD"

    # For npx-based commands, check that npx itself is available
    if [[ "$cmd" == npx\ * ]] || [[ "$cmd" == "npx" ]]; then
        if ! command -v npx &>/dev/null; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  NPX NOT FOUND                                            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}CLAUDE_CODE_CMD is set to use npx, but npx is not installed.${NC}"
            echo ""
            echo -e "${YELLOW}To fix this:${NC}"
            echo "  1. Install Node.js (includes npx): https://nodejs.org"
            echo "  2. Or install Claude Code globally:"
            echo "     npm install -g @anthropic-ai/claude-code"
            echo "     Then set in .ralphrc: CLAUDE_CODE_CMD=\"claude\""
            echo ""
            return 1
        fi
        return 0
    fi

    # For direct commands, check that the command exists
    if ! command -v "$cmd" &>/dev/null; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  CLAUDE CODE CLI NOT FOUND                                ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}The Claude Code CLI command '${cmd}' is not available.${NC}"
        echo ""
        echo -e "${YELLOW}Installation options:${NC}"
        echo "  1. Install globally (recommended):"
        echo "     npm install -g @anthropic-ai/claude-code"
        echo ""
        echo "  2. Use npx (no global install needed):"
        echo "     Add to .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
        echo ""
        echo -e "${YELLOW}Current configuration:${NC} CLAUDE_CODE_CMD=\"${cmd}\""
        echo ""
        echo -e "${YELLOW}After installation or configuration:${NC}"
        echo "  ralph --monitor  # Restart Ralph"
        echo ""
        return 1
    fi

    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Un-migrated pre-v0.10 flat structure: no .ralph/ yet, but an unambiguous Ralph
# control file (PROMPT.md or legacy @fix_plan.md/@AGENT.md) sits at the root.
# Generic names (logs/, AGENT.md, ...) are excluded to avoid false-positive halts
# on non-Ralph projects. Shared by the init guard and main()'s gate (Issue #41).
is_legacy_flat_structure() {
    [[ -d ".ralph" ]] && return 1
    [[ -f "PROMPT.md" ]] || [[ -f "@fix_plan.md" ]] || [[ -f "@AGENT.md" ]]
}

# Initialize directories. Skip for an un-migrated flat structure so main() can
# surface the migration message instead of masking the old layout (Issue #41).
if ! is_legacy_flat_structure; then
    mkdir -p "$LOG_DIR" "$DOCS_DIR"
fi

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Get the tmux base-index for windows (handles custom tmux configurations)
# Returns: the base window index (typically 0 or 1)
get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${base_index:-0}"
}

# Get the tmux pane-base-index (handles custom tmux configurations)
# Returns: the base pane index (typically 0 or 1)
# Many popular dotfiles set `setw -g pane-base-index 1` so panes number from 1.
get_tmux_pane_base_index() {
    local pane_base_index
    pane_base_index=$(tmux show-options -gwv pane-base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${pane_base_index:-0}"
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir="$(pwd)"

    # Get the tmux base-index / pane-base-index to handle custom configurations
    # (e.g. `set -g base-index 1`, `setw -g pane-base-index 1` — very common in
    # dotfiles). Without this, pane targets like `.0` don't exist and the Ralph
    # loop never starts, leaving empty panes. See: tmux pane-base-index.
    local base_win base_pane
    base_win=$(get_tmux_base_index)
    base_pane=$(get_tmux_pane_base_index)
    local pane0=$((base_pane + 0))   # Ralph loop (left)
    local pane1=$((base_pane + 1))   # Claude output (right-top)
    local pane2=$((base_pane + 2))   # Status monitor (right-bottom)

    log_status "INFO" "Setting up tmux session: $session_name"

    # Initialize live.log file
    echo "=== Ralph Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    # Create new tmux session detached (left pane - Ralph loop)
    tmux new-session -d -s "$session_name" -c "$project_dir"

    # Split window vertically (right side)
    tmux split-window -h -t "$session_name" -c "$project_dir"

    # Split right pane horizontally (top: Claude output, bottom: status)
    tmux split-window -v -t "$session_name:${base_win}.${pane1}" -c "$project_dir"

    # Right-top pane: Live Claude Code output
    tmux send-keys -t "$session_name:${base_win}.${pane1}" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane: Ralph status monitor
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:${base_win}.${pane2}" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.${pane2}" "'$ralph_home/ralph_monitor.sh'" Enter
    fi

    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    # Forward all CLI parameters that were set by the user
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi

    # Always use --live mode in tmux for real-time streaming
    ralph_cmd="$ralph_cmd --live"

    # Forward --calls if non-default
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    # Forward --prompt if non-default
    if [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    # Forward --output-format if non-default (default is json)
    if [[ "$CLAUDE_OUTPUT_FORMAT" != "json" ]]; then
        ralph_cmd="$ralph_cmd --output-format $CLAUDE_OUTPUT_FORMAT"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    # Forward --timeout if non-default (default is 15)
    if [[ "$CLAUDE_TIMEOUT_MINUTES" != "15" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CLAUDE_TIMEOUT_MINUTES"
    fi
    # Forward --allowed-tools if non-default
    # Safe git subcommands only - broad Bash(git *) allows destructive commands like git clean/git rm (Issue #149)
    if [[ "$CLAUDE_ALLOWED_TOOLS" != "Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pytest)" ]]; then
        ralph_cmd="$ralph_cmd --allowed-tools '$CLAUDE_ALLOWED_TOOLS'"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CLAUDE_USE_CONTINUE" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default (default is 24)
    if [[ "$CLAUDE_SESSION_EXPIRY_HOURS" != "24" ]]; then
        ralph_cmd="$ralph_cmd --session-expiry $CLAUDE_SESSION_EXPIRY_HOURS"
    fi
    # Forward --auto-reset-circuit if enabled
    if [[ "$CB_AUTO_RESET" == "true" ]]; then
        ralph_cmd="$ralph_cmd --auto-reset-circuit"
    fi
    # Forward --backup if enabled (Issue #23)
    if [[ "$ENABLE_BACKUP" == "true" ]]; then
        ralph_cmd="$ralph_cmd --backup"
    fi
    # Forward GitHub issue lifecycle flags (Issue #73) so --monitor preserves them
    if [[ -n "${GITHUB_ISSUE:-}" ]]; then
        ralph_cmd="$ralph_cmd --github-issue '$GITHUB_ISSUE'"
        [[ "$COMMENT_PROGRESS" == "true" ]] && ralph_cmd="$ralph_cmd --comment-progress"
        [[ "$COMMENT_INTERVAL" != "5" ]] && ralph_cmd="$ralph_cmd --comment-interval $COMMENT_INTERVAL"
        [[ "$AUTO_CLOSE" == "true" ]] && ralph_cmd="$ralph_cmd --auto-close"
        [[ "$CLOSE_SUMMARY" == "true" ]] && ralph_cmd="$ralph_cmd --close-summary"
        [[ "$CREATE_PR" == "true" ]] && ralph_cmd="$ralph_cmd --create-pr"
        [[ "$LINK_ISSUE" == "true" ]] && ralph_cmd="$ralph_cmd --link-issue"
        [[ "$DRAFT_PR" == "true" ]] && ralph_cmd="$ralph_cmd --draft-pr"
        [[ "$CREATE_FOLLOWUPS" == "true" ]] && ralph_cmd="$ralph_cmd --create-followups"
        [[ "$FOLLOWUP_LABEL" != "tech-debt" ]] && ralph_cmd="$ralph_cmd --followup-label '$FOLLOWUP_LABEL'"
        [[ -n "$ADD_COMPLETION_LABELS" ]] && ralph_cmd="$ralph_cmd --add-label '$ADD_COMPLETION_LABELS'"
    fi
    # Forward Docker sandbox flags (Issue #74) so --monitor preserves them.
    # Sub-flags forward independently of the provider: this runs BEFORE main()
    # loads .ralphrc, which may be what supplies SANDBOX_PROVIDER — the child
    # re-validates the sub-flag/provider pairing at its own startup.
    [[ -n "${SANDBOX_PROVIDER:-}" ]] && ralph_cmd="$ralph_cmd --sandbox $SANDBOX_PROVIDER"
    [[ "${SANDBOX_DOCKER_IMAGE:-ralph-sandbox:latest}" != "ralph-sandbox:latest" ]] && ralph_cmd="$ralph_cmd --sandbox-image '$SANDBOX_DOCKER_IMAGE'"
    [[ "${SANDBOX_DOCKER_MEMORY:-4g}" != "4g" ]] && ralph_cmd="$ralph_cmd --sandbox-memory $SANDBOX_DOCKER_MEMORY"
    [[ "${SANDBOX_DOCKER_CPUS:-2}" != "2" ]] && ralph_cmd="$ralph_cmd --sandbox-cpus $SANDBOX_DOCKER_CPUS"
    [[ "${SANDBOX_DOCKER_NETWORK:-bridge}" != "bridge" ]] && ralph_cmd="$ralph_cmd --sandbox-network $SANDBOX_DOCKER_NETWORK"
    # E2B sandbox flags (Issue #75) — same non-default forwarding rule
    [[ "${SANDBOX_E2B_TEMPLATE:-base}" != "base" ]] && ralph_cmd="$ralph_cmd --sandbox-template '$SANDBOX_E2B_TEMPLATE'"
    [[ -n "${SANDBOX_E2B_SANDBOX_ID:-}" ]] && ralph_cmd="$ralph_cmd --sandbox-id '$SANDBOX_E2B_SANDBOX_ID'"
    [[ "${SANDBOX_E2B_TIMEOUT:-3600}" != "3600" ]] && ralph_cmd="$ralph_cmd --sandbox-timeout $SANDBOX_E2B_TIMEOUT"
    [[ "${SANDBOX_E2B_KEEP_ALIVE:-false}" == "true" ]] && ralph_cmd="$ralph_cmd --sandbox-keep-alive"
    [[ -n "${SANDBOX_E2B_MAX_COST:-}" ]] && ralph_cmd="$ralph_cmd --sandbox-max-cost $SANDBOX_E2B_MAX_COST"
    [[ -n "${SANDBOX_E2B_COST_ALERT:-}" ]] && ralph_cmd="$ralph_cmd --sandbox-cost-alert $SANDBOX_E2B_COST_ALERT"
    # Sync filter flags (Issue #76). Monitor mode exits here before main()'s
    # validation ever runs, so explicit CLI --sync-* flags with the docker
    # provider must be rejected now — silently dropping them would make
    # --monitor behave differently from a plain run (CodeRabbit, PR #305).
    # Env-supplied SYNC_* with docker is merely not forwarded (a plain run
    # ignores it the same way); an empty provider may still become e2b via
    # the child's .ralphrc, so it forwards.
    if [[ "${SANDBOX_PROVIDER:-}" == "docker" ]]; then
        if [[ -n "${_cli_SYNC_INCLUDE:-}${_cli_SYNC_EXCLUDE:-}" ]]; then
            log_status "ERROR" "--sync-include/--sync-exclude do not apply to --sandbox docker (the bind mount shares the whole project in real time)"
            exit 1
        fi
    else
        [[ -n "${SYNC_INCLUDE:-}" ]] && ralph_cmd="$ralph_cmd --sync-include '$SYNC_INCLUDE'"
        [[ -n "${SYNC_EXCLUDE:-}" ]] && ralph_cmd="$ralph_cmd --sync-exclude '$SYNC_EXCLUDE'"
    fi

    # Chain tmux kill-session after the loop command so the entire tmux
    # session is torn down when the Ralph loop exits (graceful completion,
    # circuit breaker, error, or manual interrupt). Without this, the
    # tail -f and ralph_monitor.sh panes keep the session alive forever.
    # Issue: https://github.com/frankbria/ralph-claude-code/issues/176
    tmux send-keys -t "$session_name:${base_win}.${pane0}" "$ralph_cmd; tmux kill-session -t $session_name 2>/dev/null" Enter

    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:${base_win}.${pane0}"

    # Set pane titles (requires tmux 2.6+)
    tmux select-pane -t "$session_name:${base_win}.${pane0}" -T "Ralph Loop"
    tmux select-pane -t "$session_name:${base_win}.${pane1}" -T "Claude Output"
    tmux select-pane -t "$session_name:${base_win}.${pane2}" -T "Status"

    # Set window title
    tmux rename-window -t "$session_name:${base_win}" "Ralph: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph loop"
    log_status "INFO" "  Right-top:    Claude Code live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"

    exit 0
}

# Initialize call tracking
init_call_tracking() {
    # Debug logging removed for cleaner output
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counters if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "0" > "$TOKEN_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call and token counters reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    # Write to stderr so log messages don't interfere with function return values
    # 2>/dev/null suppresses "Input/output error" when tmux pty is broken (Issue #188)
    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2 2>/dev/null
    # Only append to the log file when its directory exists. Redirection-open
    # failures are emitted by the shell before `2>/dev/null` takes effect, so a
    # missing $LOG_DIR (e.g. the pre-migration flat-structure exit) would leak a
    # "No such file or directory" line without this guard (Issue #41).
    [[ -d "$LOG_DIR" ]] && echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log" 2>/dev/null
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    local tokens_used
    tokens_used=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
    # Issue #74: surface sandbox state for ralph-monitor (read before the
    # heredoc per the project convention — no lazy $() inside cat >)
    local sandbox_json='{"provider": "none"}'
    if [[ -n "${SANDBOX_PROVIDER:-}" ]] && declare -F get_sandbox_status >/dev/null 2>&1; then
        sandbox_json=$(get_sandbox_status)
    fi
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "tokens_used_this_hour": $tokens_used,
    "max_tokens_per_hour": $MAX_TOKENS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "sandbox": $sandbox_json,
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Send a desktop notification if ENABLE_NOTIFICATIONS is true
# Cross-platform: macOS (osascript), Linux (notify-send), fallback (terminal bell)
# Errors are suppressed so notification failures never break the loop.
send_notification() {
    local title="$1"
    local message="$2"

    [[ "$ENABLE_NOTIFICATIONS" == "true" ]] || return 0

    # Strip double quotes to prevent osascript AppleScript string breakage
    local safe_title="${title//\"/}"
    local safe_message="${message//\"/}"

    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$safe_message\" with title \"$safe_title\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null || true
    else
        printf '\a\n'
    fi
}

# Extract token usage from a Claude output file
# Handles both Claude CLI format (metadata.usage) and stream-json result format (.usage)
# Outputs total tokens (input + output), or 0 on failure
extract_token_usage() {
    local output_file=$1
    if [[ ! -f "$output_file" ]]; then
        echo "0"
        return
    fi
    local tokens
    tokens=$(jq -r '
        ((.usage.input_tokens // .metadata.usage.input_tokens // 0) |
         if type == "number" then . else 0 end) +
        ((.usage.output_tokens // .metadata.usage.output_tokens // 0) |
         if type == "number" then . else 0 end)
    ' "$output_file" 2>/dev/null)
    echo "${tokens:-0}"
}

# Accumulate token usage after a Claude invocation
update_token_count() {
    local output_file=$1
    local new_tokens
    new_tokens=$(extract_token_usage "$output_file")
    if [[ "$new_tokens" -gt 0 ]] 2>/dev/null; then
        local current
        current=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
        echo $(( current + new_tokens )) > "$TOKEN_COUNT_FILE"
        log_status "INFO" "Tokens this hour: $((current + new_tokens))${MAX_TOKENS_PER_HOUR:+/$MAX_TOKENS_PER_HOUR} (+${new_tokens})"
    fi
}

# Check if we can make another call
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call — invocation limit reached
    fi

    # Check token limit only when configured (MAX_TOKENS_PER_HOUR > 0)
    if [[ "${MAX_TOKENS_PER_HOUR:-0}" -gt 0 ]] 2>/dev/null; then
        local tokens_used=0
        tokens_used=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
        if [[ $tokens_used -ge $MAX_TOKENS_PER_HOUR ]]; then
            return 1  # Cannot make call — token limit reached
        fi
    fi

    return 0  # Can make call
}

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Track loop execution metrics to logs/metrics.jsonl (Issue #21)
# Arguments: loop_num duration_seconds success(true|false) calls_made
track_metrics() {
    local loop_num=$1
    local duration=$2
    local success=$3
    local calls=$4

    local ts
    ts=$(get_iso_timestamp)
    local metrics_file="$LOG_DIR/metrics.jsonl"

    mkdir -p "$LOG_DIR"
    printf '{"timestamp":"%s","loop":%d,"duration":%d,"success":%s,"calls":%d}\n' \
        "$ts" "$loop_num" "$duration" "$success" "$calls" >> "$metrics_file"
}

# Print a one-line metrics summary from logs/metrics.jsonl (Issue #21)
print_metrics_summary() {
    local metrics_file="$LOG_DIR/metrics.jsonl"
    [[ -f "$metrics_file" ]] || return 0
    command -v jq &>/dev/null || return 0

    local summary
    summary=$(jq -s '{
        total_loops: length,
        successful: (map(select(.success==true)) | length),
        avg_duration: (if length > 0 then (map(.duration) | add) / length else 0 end),
        total_calls: (map(.calls) | add // 0)
    }' "$metrics_file" 2>/dev/null)
    [[ -n "$summary" ]] && log_status "INFO" "Metrics summary: $summary"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    local tokens_used=$(cat "$TOKEN_COUNT_FILE" 2>/dev/null || echo "0")
    local limit_reason="calls: $calls_made/$MAX_CALLS_PER_HOUR"
    if [[ "${MAX_TOKENS_PER_HOUR:-0}" -gt 0 ]]; then
        limit_reason="$limit_reason, tokens: $tokens_used/$MAX_TOKENS_PER_HOUR"
    fi
    log_status "WARN" "Rate limit reached ($limit_reason). Waiting for reset..."
    send_notification "Ralph - Rate Limit" "Rate limit reached ($limit_reason). Waiting for reset..."

    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counters
    echo "0" > "$CALL_COUNT_FILE"
    echo "0" > "$TOKEN_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # Diagnostic logging for exit signal check (Issue #194)
    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "DEBUG" "Exit check: test_loops=$recent_test_loops done_signals=$recent_done_signals completion_indicators=$recent_completion_indicators"

    # Check for exit conditions

    # 0. Permission denials (highest priority - Issue #101)
    # When Claude Code is denied permission to run commands, halt immediately
    # to allow user to update .ralphrc ALLOWED_TOOLS configuration.
    # Exception (Issue #243): if every denial is a Bash compound command whose
    # base is already covered by ALLOWED_TOOLS, the denial is a Claude CLI
    # limitation rather than a real permission gap — log an advisory and continue.
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local has_permission_denials=$(jq -r '.analysis.has_permission_denials // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        local has_compound_limitation=$(jq -r '.analysis.has_compound_command_limitation // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")

        if [[ "$has_compound_limitation" == "true" ]]; then
            local compound_count=$(jq -r '.analysis.compound_command_count // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
            local denied_cmds=$(jq -r '.analysis.denied_commands | join(", ")' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "unknown")
            log_status "WARN" "⚠️  Claude CLI denied $compound_count compound command(s) but the base command is already in ALLOWED_TOOLS: $denied_cmds"
            log_status "WARN" "This is a Claude CLI matching limitation (pipes/redirects bypass Bash(cmd *) patterns). Loop continues."
            # Fall through — do not halt
        elif [[ "$has_permission_denials" == "true" ]]; then
            local denied_count=$(jq -r '.analysis.permission_denial_count // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
            local denied_cmds=$(jq -r '.analysis.denied_commands | join(", ")' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "unknown")
            log_status "WARN" "🚫 Permission denied for $denied_count command(s): $denied_cmds"
            log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
            echo "permission_denied"
            return 0
        fi
    fi

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Safety circuit breaker - force exit after 5 consecutive EXIT_SIGNAL=true responses
    # Note: completion_indicators only accumulates when Claude explicitly sets EXIT_SIGNAL=true
    # (not based on confidence score). This safety breaker catches cases where Claude signals
    # completion 5+ times but the normal exit path (completion_indicators >= 2 + EXIT_SIGNAL=true)
    # didn't trigger for some reason. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Claude explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in .response_analysis represents Claude's explicit intent.
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi
    
    # 5. Check fix_plan.md for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    # Valid patterns: "- [ ]" (uncompleted) and "- [x]" or "- [X]" (completed)
    # Issue #239: unchecked items under OPTIONAL_SECTIONS (Optional/Future/...) do NOT block
    # exit, so _count_blocking_unchecked is used instead of a full-file unchecked count.
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        # Use _safe_count to avoid arithmetic crash on CRLF / no-match (issues #255, #251, #260)
        local uncompleted_items
        local completed_items
        uncompleted_items=$(_count_blocking_unchecked "$RALPH_DIR/fix_plan.md")
        completed_items=$(_safe_count "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md")
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

# Compare two semver strings: returns 0 if ver1 >= ver2, 1 if ver1 < ver2
# Uses sequential major→minor→patch comparison (safe for any patch number)
compare_semver() {
    local ver1="$1" ver2="$2"
    local v1_major v1_minor v1_patch
    local v2_major v2_minor v2_patch

    IFS='.' read -r v1_major v1_minor v1_patch <<< "$ver1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$ver2"

    v1_major=${v1_major:-0}; v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
    v2_major=${v2_major:-0}; v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}

    if [[ $v1_major -gt $v2_major ]]; then return 0; fi
    if [[ $v1_major -lt $v2_major ]]; then return 1; fi
    if [[ $v1_minor -gt $v2_minor ]]; then return 0; fi
    if [[ $v1_minor -lt $v2_minor ]]; then return 1; fi
    if [[ $v1_patch -lt $v2_patch ]]; then return 1; fi
    return 0
}

# Check Claude CLI version for compatibility with modern flags
check_claude_version() {
    local version
    version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
        return 0
    fi

    if ! compare_semver "$version" "$CLAUDE_MIN_VERSION"; then
        log_status "WARN" "Claude CLI version $version < $CLAUDE_MIN_VERSION. Some modern features may not work."
        log_status "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
        return 1
    fi

    log_status "INFO" "Claude CLI version $version (>= $CLAUDE_MIN_VERSION) - modern features enabled"
    return 0
}

# Check for Claude CLI updates and attempt auto-update (Issue #190)
check_claude_updates() {
    if [[ "${CLAUDE_AUTO_UPDATE:-true}" != "true" ]]; then
        return 0
    fi

    local installed_version
    installed_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$installed_version" ]]; then
        return 0
    fi

    # Query latest version from npm registry (with timeout to avoid hanging on flaky networks)
    local latest_version
    latest_version=$(portable_timeout 5s npm view @anthropic-ai/claude-code version 2>/dev/null)
    if [[ -z "$latest_version" ]]; then
        log_status "INFO" "Could not check for Claude CLI updates (npm registry unreachable)"
        return 0
    fi

    if [[ "$installed_version" == "$latest_version" ]]; then
        log_status "INFO" "Claude CLI is up to date ($installed_version)"
        return 0
    fi

    if compare_semver "$installed_version" "$latest_version"; then
        return 0
    fi

    # Auto-update attempt
    log_status "INFO" "Claude CLI update available: $installed_version → $latest_version. Attempting auto-update..."
    local update_output
    if update_output=$(npm update -g @anthropic-ai/claude-code 2>&1); then
        local new_version
        new_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_status "SUCCESS" "Claude CLI updated: $installed_version → ${new_version:-$latest_version}"
        return 0
    fi

    # Auto-update failed — warn with environment-specific guidance
    log_status "WARN" "Claude CLI auto-update failed ($installed_version → $latest_version)"
    [[ -n "$update_output" ]] && log_status "DEBUG" "npm output: $update_output"
    log_status "WARN" "Update manually: npm update -g @anthropic-ai/claude-code"
    log_status "WARN" "In Docker: rebuild your image to include the latest version"
    return 1
}

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi

            # Check for Bash(*) pattern - any Bash with parentheses is allowed
            if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return 1
        fi
    done

    return 0
}

# Build loop context for Claude Code session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix_plan.md
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    # Use _safe_count to avoid arithmetic issues with CRLF / no-match (issues #255, #251, #260)
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks
        incomplete_tasks=$(_safe_count "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md")
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    # Add circuit breaker state
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary (truncated)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary} "
        fi
    fi

    # If previous loop detected questions, inject corrective guidance (Issue #190 Bug 2)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_asking_questions
        prev_asking_questions=$(jq -r '.analysis.asking_questions // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        if [[ "$prev_asking_questions" == "true" ]]; then
            context+="IMPORTANT: You asked questions in the previous loop. This is a headless automation loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe default and proceed autonomously. "
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    # Get file modification time using capability detection
    # Handles macOS with Homebrew coreutils where stat flags differ
    local file_mtime

    # Try GNU stat first (Linux, macOS with Homebrew coreutils)
    if file_mtime=$(stat -c %Y "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Try BSD stat (native macOS)
    elif file_mtime=$(stat -f %m "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Fallback to date -r (most portable)
    elif file_mtime=$(date -r "$file" +%s 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    else
        file_mtime=""
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Claude session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CLAUDE_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Claude starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_claude_session() {
    if [[ -f "$CLAUDE_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CLAUDE_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CLAUDE_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CLAUDE_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it.
        # Issue #123: read through the shared format-tolerant reader so a JSON session
        # file (written by store_session_id / save_claude_session) resolves to the real
        # id, while legacy plain-text files still work. The reader keeps the #254
        # robustness (first line only, CR/whitespace stripped) in its plain fallback.
        local session_id
        session_id=$(read_session_id_file "$CLAUDE_SESSION_FILE")
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Claude session: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Claude session"
    echo ""
}

# Save session ID after successful execution
save_claude_session() {
    local output_file=$1

    # Guard: never persist a session from a response where is_error is true (Issue #134, #199)
    if [[ -f "$output_file" ]]; then
        local is_error
        is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
        if [[ "$is_error" == "true" ]]; then
            log_status "WARN" "Skipping session save — response has is_error:true"
            return 0
        fi
    fi

    # Try to extract session ID from JSON output
    # Fix #254: If output_file contains JSONL (multiple objects) or nested objects with
    # session_id at multiple paths, jq -r returns multi-line output. Take first non-empty
    # line and strip whitespace to guarantee a single clean ID gets passed to --resume.
    if [[ -f "$output_file" ]]; then
        local session_id
        session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null \
                     | grep -v '^$' \
                     | head -n 1 \
                     | tr -d '\r\n[:space:]')
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            # Issue #123: persist as canonical JSON so every write site agrees on format
            write_session_id_file "$session_id" "$CLAUDE_SESSION_FILE"
            log_status "INFO" "Saved Claude session: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # Also clear the Claude session file for consistency
    rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Clear response analysis to prevent stale EXIT_SIGNAL from previous session
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    # Log the session transition
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Global array for Claude command arguments (avoids shell injection)
declare -a CLAUDE_CMD_ARGS=()

# Build Claude CLI command with modern flags using array (shell-injection safe)
# Populates global CLAUDE_CMD_ARGS array for direct execution
# Uses -p flag with prompt content (Claude CLI does not have --prompt-file)
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    # Note: We do NOT use --dangerously-skip-permissions here. Tool permissions
    # are controlled via --allowedTools from CLAUDE_ALLOWED_TOOLS in .ralphrc.
    # This preserves the permission denial circuit breaker (Issue #101).
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    # Add model override (Issue #228)
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--model" "$CLAUDE_MODEL")
    fi

    # Add effort level override (Issue #228)
    if [[ -n "${CLAUDE_EFFORT:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--effort" "$CLAUDE_EFFORT")
    fi

    # Add output format flag
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Add allowed tools (each tool as separate array element)
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi

    # Add session continuity flag
    # IMPORTANT: Use --resume with explicit session ID instead of --continue
    # --continue resumes the "most recent session in current directory" which
    # can hijack active Claude Code sessions. --resume with a specific session ID
    # ensures we only resume Ralph's own sessions. (Issue #151)
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    fi
    # If no session_id, start fresh - Claude will generate a new session ID
    # which we'll capture via save_claude_session() for future loops

    # Add loop context as system prompt (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi

    # Read prompt file content and use -p flag
    # Note: Claude CLI uses -p for prompts, not --prompt-file (which doesn't exist)
    # Array-based approach maintains shell injection safety
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")

    # Diagnostic logging (Issue #154): when RALPH_VERBOSE=true, dump the exact
    # argv that will be passed to Claude CLI — minus the prompt body, which is
    # noisy and may contain secrets. Lets users verify --allowedTools entries
    # actually reach Claude (e.g., when investigating Bash(git *) denials).
    if [[ "${RALPH_VERBOSE:-false}" == "true" ]]; then
        local -a redacted_args=()
        local skip_prompt=false
        for arg in "${CLAUDE_CMD_ARGS[@]}"; do
            if [[ "$skip_prompt" == "true" ]]; then
                redacted_args+=("<prompt:${#arg} chars>")
                skip_prompt=false
                continue
            fi
            if [[ "$arg" == "-p" ]]; then
                redacted_args+=("$arg")
                skip_prompt=true
                continue
            fi
            redacted_args+=("$arg")
        done
        log_status "DEBUG" "Claude argv (${#CLAUDE_CMD_ARGS[@]} args): ${redacted_args[*]}"
    fi
}

# create_backup - Create a git backup branch before a loop iteration (Issue #23)
#
# Creates a branch named `ralph-backup-loop-{N}-{timestamp}` and commits the
# current state with `--allow-empty` so a backup is recorded even when there
# are no staged changes. The function is a no-op when:
#   - ENABLE_BACKUP is not "true"
#   - The working directory is not a git repository
#
# Usage: create_backup <loop_count>
#
create_backup() {
    local loop_count="${1:-0}"

    [[ "$ENABLE_BACKUP" == "true" ]] || return 0

    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null 2>&1; then
        log_status "WARN" "Backup skipped: not a git repository"
        return 0
    fi

    local timestamp
    timestamp=$(date +%s)
    local branch_name="ralph-backup-loop-${loop_count}-${timestamp}"
    local stash_msg="Ralph backup before loop #${loop_count}"

    # Stash any staged/unstaged changes so checkout doesn't lose them
    local stashed=false
    if ! git stash push -u -m "$stash_msg" 2>/dev/null; then
        log_status "WARN" "Backup failed: could not stash local changes for loop #${loop_count}"
        return 0
    fi
    stashed=true

    if ! git checkout -b "$branch_name" -q 2>/dev/null; then
        log_status "WARN" "Backup failed: could not create branch $branch_name"
        git stash pop 2>/dev/null || true
        return 0
    fi

    if ! git add -A 2>/dev/null; then
        log_status "WARN" "Backup failed: could not stage files for loop #${loop_count}"
        git checkout - -q 2>/dev/null || true
        git stash pop 2>/dev/null || true
        return 0
    fi

    if ! git commit --allow-empty -q -m "$stash_msg" 2>/dev/null; then
        log_status "WARN" "Backup failed: commit failed for loop #${loop_count}"
        git checkout - -q 2>/dev/null || true
        git stash pop 2>/dev/null || true
        return 0
    fi

    # Return to the original branch and restore the stash
    if ! git checkout - -q 2>/dev/null; then
        log_status "WARN" "Backup: could not switch back from $branch_name — manual cleanup may be needed"
    fi

    if [[ "$stashed" == "true" ]]; then
        git stash pop 2>/dev/null || log_status "WARN" "Backup: stash pop failed — run 'git stash pop' to restore your changes"
    fi

    log_status "INFO" "Backup created: $branch_name"
    return 0
}

# rollback_to_backup - Roll back to a previously created backup branch (Issue #23)
#
# With no argument: lists all backup branches (newest first).
# With a branch name: checks out that branch.
#
# Usage: rollback_to_backup [branch_name]
#
rollback_to_backup() {
    local branch="${1:-}"

    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null 2>&1; then
        log_status "ERROR" "Rollback failed: not a git repository"
        return 1
    fi

    if [[ -z "$branch" ]]; then
        local backups
        backups=$(git branch --list "ralph-backup-loop-*" 2>/dev/null | sed 's/^[* ]*//' | sort -t- -k5,5 -rn)
        if [[ -z "$backups" ]]; then
            log_status "WARN" "No backup branches found"
            return 1
        fi
        echo "Available backups (newest first):"
        echo "$backups"
        return 0
    fi

    if ! git rev-parse --verify "$branch" &>/dev/null 2>&1; then
        log_status "ERROR" "Rollback failed: branch '$branch' not found"
        return 1
    fi

    git checkout "$branch" -q 2>/dev/null || {
        log_status "ERROR" "Rollback failed: could not checkout $branch"
        return 1
    }

    log_status "INFO" "Rolled back to: $branch"
    return 0
}

# wrap_claude_command_for_sandbox - Route CLAUDE_CMD_ARGS through the sandbox (Issues #74/#75)
#
# Replaces the global CLAUDE_CMD_ARGS array with its sandbox wrapping (`docker
# exec` or the E2B helper exec) so the Claude CLI runs inside the sandbox. The
# array-in/array-out shape keeps both execution paths (live stream-json
# pipeline and background mode) working unchanged. Returns 1 when no sandbox
# is running — callers must treat that as fatal rather than falling back to
# host execution.
wrap_claude_command_for_sandbox() {
    # Liveness + recovery first: a container can die between iterations (OOM
    # kill under --memory, daemon restart) and an E2B sandbox expires at its
    # session timeout — exec against a dead sandbox would burn loops until
    # the circuit breaker opens.
    case "$SANDBOX_PROVIDER" in
        docker)
            ensure_sandbox_container || return 1
            ;;
        e2b)
            ensure_e2b_sandbox || return 1
            ;;
        *)
            log_status "ERROR" "wrap_claude_command_for_sandbox: unsupported provider '$SANDBOX_PROVIDER'"
            return 1
            ;;
    esac
    # Inside the sandbox the CLI is always `claude` on PATH. Host-specific
    # CLAUDE_CODE_CMD values (absolute paths like /opt/homebrew/bin/claude,
    # npx wrappers) don't exist there, so argv[0] is rewritten.
    local -a sandbox_cmd=("${CLAUDE_CMD_ARGS[@]}")
    sandbox_cmd[0]="claude"
    if [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
        build_e2b_exec_args "${sandbox_cmd[@]}" || return 1
    else
        build_sandbox_exec_args "${sandbox_cmd[@]}" || return 1
    fi
    CLAUDE_CMD_ARGS=("${SANDBOX_EXEC_ARGS[@]}")
    return 0
}

# Main execution function
execute_claude_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    local calls_made=0

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    # Store in file for access by progress detection after Claude execution
    local loop_start_sha=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    # Dry-run mode: simulate execution without calling Claude API
    if [[ "$DRY_RUN" == "true" ]]; then
        log_status "INFO" "[DRY RUN] Skipping actual Claude Code execution"
        log_status "INFO" "[DRY RUN] Would execute: $CLAUDE_CODE_CMD with prompt: $PROMPT_FILE"
        log_status "INFO" "[DRY RUN] Output format: $CLAUDE_OUTPUT_FORMAT, Timeout: ${CLAUDE_TIMEOUT_MINUTES}m"
        log_status "INFO" "[DRY RUN] Simulating 2-second execution delay..."
        sleep 2
        log_status "INFO" "[DRY RUN] Simulation complete — no API call was made"
        return 0
    fi

    calls_made=$(increment_call_counter)
    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"

    # Build loop context (always, regardless of session mode)
    local loop_context=""
    loop_context=$(build_loop_context "$loop_count")
    if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Loop context: $loop_context"
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        session_id=$(init_claude_session)
    fi

    # Live mode requires JSON output (stream-json) — override text format
    if [[ "$LIVE_OUTPUT" == "true" && "$CLAUDE_OUTPUT_FORMAT" == "text" ]]; then
        log_status "WARN" "Live mode requires JSON output format. Overriding text → json for this session."
        CLAUDE_OUTPUT_FORMAT="json"
    fi

    # Build the Claude CLI command with modern flags
    local use_modern_cli=false

    if build_claude_command "$PROMPT_FILE" "$loop_context" "$session_id"; then
        use_modern_cli=true
        log_status "INFO" "Using modern CLI mode (${CLAUDE_OUTPUT_FORMAT} output)"
    else
        log_status "WARN" "Failed to build modern CLI command, falling back to legacy mode"
        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    # Issues #74/#75: route execution through the sandbox. The user asked for
    # isolation, so a failure here is fatal — NEVER silently fall back to
    # executing Claude on the host.
    if [[ "$SANDBOX_PROVIDER" == "docker" || "$SANDBOX_PROVIDER" == "e2b" ]]; then
        if [[ "$use_modern_cli" != "true" ]]; then
            log_status "ERROR" "Sandbox mode requires the modern CLI command; refusing host-side legacy fallback"
            return 1
        fi
        if ! wrap_claude_command_for_sandbox; then
            log_status "ERROR" "Failed to wrap Claude command for sandbox execution"
            return 1
        fi
        if [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
            log_status "INFO" "☁️  Executing in E2B sandbox (template: $SANDBOX_E2B_TEMPLATE)"
        else
            log_status "INFO" "🐳 Executing in Docker sandbox (image: $SANDBOX_DOCKER_IMAGE)"
        fi
    fi

    # Execute Claude Code
    local exit_code=0

    # Initialize live.log for this execution
    echo -e "\n\n=== Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # LIVE MODE: Show streaming output in real-time using stream-json + jq
        # Based on: https://www.ytyng.com/en/blog/claude-stream-json-jq/
        #
        # Uses CLAUDE_CMD_ARGS from build_claude_command() to preserve:
        # - --allowedTools (tool permissions)
        # - --append-system-prompt (loop context)
        # - --continue (session continuity)
        # - -p (prompt content)

        # Check dependencies for live mode
        if ! command -v jq &> /dev/null; then
            log_status "ERROR" "Live mode requires 'jq' but it's not installed. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # Safety check: live mode requires a successfully built modern command
        if [[ "$use_modern_cli" != "true" || ${#CLAUDE_CMD_ARGS[@]} -eq 0 ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        log_status "INFO" "📺 Live output mode enabled - showing Claude Code streaming..."
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Claude Code Output ━━━━━━━━━━━━━━━━${NC}"

        # Modify CLAUDE_CMD_ARGS: replace --output-format value with stream-json
        # and add streaming-specific flags
        local -a LIVE_CMD_ARGS=()
        local skip_next=false
        for arg in "${CLAUDE_CMD_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                # Replace "json" with "stream-json" for output format
                LIVE_CMD_ARGS+=("stream-json")
                skip_next=false
            elif [[ "$arg" == "--output-format" ]]; then
                LIVE_CMD_ARGS+=("$arg")
                skip_next=true
            else
                LIVE_CMD_ARGS+=("$arg")
            fi
        done

        # Add streaming-specific flags (--verbose and --include-partial-messages)
        # These are required for stream-json to work properly
        LIVE_CMD_ARGS+=("--verbose" "--include-partial-messages")

        # jq filter: show text + tool summaries + sub-agent progress
        # Two sources of tool info:
        #   1. stream_event content_block_start: tool name (arrives at start of streaming)
        #   2. assistant messages: complete tool inputs (arrive after each turn)
        # We use assistant messages for tool details since stream deltas are fragments
        # jq filter overview:
        #   stream_event text_delta    → text as it streams (real-time)
        #   stream_event tool_use start→ "⚙ Bash..." (immediate, no args yet)
        #   assistant message          → "⚡ [Bash] actual command" (after turn, with full args)
        #   system task_started/progress→ agent status
        local jq_filter='
            if .type == "stream_event" then
                if .event.type == "content_block_delta" and .event.delta.type == "text_delta" then
                    .event.delta.text
                elif .event.type == "content_block_start" and .event.content_block.type == "tool_use" then
                    "\n⚙ " + .event.content_block.name + "..."
                elif .event.type == "content_block_stop" then
                    "\n"
                else
                    empty
                end
            elif .type == "assistant" then
                [.message.content[] |
                    if .type == "tool_use" then
                        # Tool argument details are opt-in via $show_args
                        # (passed as --argjson from LIVE_SHOW_TOOL_ARGS) to
                        # avoid logging raw commands/paths/patterns by default.
                        # Note: "Task" is the legacy name for the "Agent" tool
                        # (renamed in Claude Code v2.1.63); accept both.
                        "\n⚡ [" + .name + "] " + (
                            if $show_args then
                                (
                                    if .name == "Bash" then
                                        (.input.command // "")
                                    elif .name == "Read" or .name == "Write" or .name == "Edit" then
                                        (.input.file_path // "")
                                    elif .name == "Glob" or .name == "Grep" then
                                        (.input.pattern // "")
                                    elif .name == "Agent" or .name == "Task" then
                                        (.input.description // "")
                                    else
                                        ""
                                    end
                                ) | split("\n") | .[0] | .[0:120]
                            else
                                ""
                            end
                        ) + "\n"
                    else
                        empty
                    end
                ] | join("")
            elif .type == "system" and .subtype == "task_started" then
                "\n🚀 Agent: " + (.description // "started") + "\n"
            elif .type == "system" and .subtype == "task_progress" then
                "📌 " + (.description // "working...") + "\n"
            else
                empty
            end'

        # Execute with streaming, preserving all flags from build_claude_command()
        # No stdbuf: it uses DYLD_INSERT_LIBRARIES which crashes arm64e system binaries
        # on macOS Apple Silicon. Not needed anyway — claude streams per-event,
        # tee is unbuffered, and jq --unbuffered handles its own flushing.
        # Use portable_timeout for consistent timeout protection
        # stdin must be redirected from /dev/null: newer Claude CLI reads stdin even in -p mode
        # Redirect stderr to separate file to prevent Node.js warnings (e.g., UNDICI)
        # from corrupting the jq JSON pipeline (Issue #190)
        local stderr_file="${LOG_DIR}/claude_stderr_$(date '+%Y%m%d_%H%M%S').log"

        # Normalize LIVE_SHOW_TOOL_ARGS to strict JSON boolean for --argjson.
        # Accepts: true/yes/on/1 (case-insensitive) → true; everything else → false.
        local _show_args=false
        case "$(printf '%s' "${LIVE_SHOW_TOOL_ARGS:-false}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            true|yes|on|1) _show_args=true ;;
        esac

        portable_timeout ${timeout_seconds}s "${LIVE_CMD_ARGS[@]}" \
            < /dev/null 2>"$stderr_file" | tee "$output_file" | jq --unbuffered -j --argjson show_args "$_show_args" "$jq_filter" 2>>"$stderr_file" | tee "$LIVE_LOG_FILE"

        # Capture exit codes from pipeline
        local -a pipe_status=("${PIPESTATUS[@]}")

        # Primary exit code is from Claude/timeout (first command in pipeline)
        exit_code=${pipe_status[0]}

        # Log timeout events explicitly (exit code 124 from portable_timeout)
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "Claude Code execution timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes"
        fi

        # Log stderr if non-empty, clean up empty stderr files
        if [[ -s "$stderr_file" ]]; then
            log_status "WARN" "Claude CLI wrote to stderr (see: $stderr_file)"
        else
            rm -f "$stderr_file" 2>/dev/null
        fi

        # Check for tee failures (second command) - could break logging/session
        if [[ ${pipe_status[1]} -ne 0 ]]; then
            log_status "WARN" "Failed to write stream output to log file (exit code ${pipe_status[1]})"
        fi

        # Check for jq failures (third command) - warn but don't fail
        if [[ ${pipe_status[2]} -ne 0 ]]; then
            log_status "WARN" "jq filter had issues parsing some stream events (exit code ${pipe_status[2]})"
        fi

        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Output ━━━━━━━━━━━━━━━━━━━${NC}"

        # Extract session ID from stream-json output for session continuity
        # Stream-json format has session_id in the final "result" type message
        # Keep full stream output in _stream.log, extract session data separately
        if [[ -f "$output_file" ]]; then
            # Preserve full stream output for analysis (don't overwrite output_file)
            local stream_output_file="${output_file%.log}_stream.log"
            cp "$output_file" "$stream_output_file"

            # Extract the result message and convert to standard JSON format
            # Use flexible regex to match various JSON formatting styles
            # Matches: "type":"result", "type": "result", "type" : "result"
            local result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)

            if [[ -n "$result_line" ]]; then
                # Validate that extracted line is valid JSON before using it
                if echo "$result_line" | jq -e . >/dev/null 2>&1; then
                    # Write validated result as the output_file for downstream processing
                    # (save_claude_session and analyze_response expect JSON format)
                    echo "$result_line" > "$output_file"
                    log_status "INFO" "Extracted and validated session data from stream output"
                else
                    log_status "WARN" "Extracted result line is not valid JSON, keeping stream output"
                    # Restore original stream output
                    cp "$stream_output_file" "$output_file"
                fi
            else
                log_status "WARN" "Could not find result message in stream output"
                # Fallback: extract session ID from "type":"system" message (Issue #198)
                # The system message is always written first and survives truncation
                local system_line
                system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | tail -1)
                if [[ -n "$system_line" ]] && echo "$system_line" | jq -e . >/dev/null 2>&1; then
                    local fallback_session_id
                    fallback_session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null)
                    if [[ -n "$fallback_session_id" ]]; then
                        # Issue #123: persist as canonical JSON (was a bare echo)
                        write_session_id_file "$fallback_session_id" "$CLAUDE_SESSION_FILE"
                        log_status "INFO" "Extracted session ID from system message (timeout fallback)"
                    fi
                fi
                # Keep stream output as-is for debugging
            fi
        fi
    else
        # BACKGROUND MODE: Original behavior with progress monitoring
        if [[ "$use_modern_cli" == "true" ]]; then
            # Modern execution with command array (shell-injection safe)
            # Execute array directly without bash -c to prevent shell metacharacter interpretation
            # stdin must be redirected from /dev/null because newer Claude CLI versions
            # read from stdin even in -p (print) mode, causing SIGTTIN suspension
            # when the process is backgrounded
            if portable_timeout ${timeout_seconds}s "${CLAUDE_CMD_ARGS[@]}" < /dev/null > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process (modern mode)"
                # Fall back to legacy mode
                log_status "INFO" "Falling back to legacy mode..."
                use_modern_cli=false
            fi
        fi

        # Fall back to legacy stdin piping if modern mode failed or not enabled
        # Note: Legacy mode doesn't use --allowedTools, so tool permissions
        # will be handled by Claude Code's default permission system
        if [[ "$use_modern_cli" == "false" ]]; then
            if portable_timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process"
                return 1
            fi
        fi

        # Get PID and monitor progress
        local claude_pid=$!
        local progress_counter=0

        # Early failure detection: if the command doesn't exist or fails immediately,
        # the backgrounded process dies before the monitoring loop starts (Issue #97)
        sleep 1
        if ! kill -0 $claude_pid 2>/dev/null; then
            wait $claude_pid 2>/dev/null
            local early_exit=$?
            local early_output=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                early_output=$(tail -5 "$output_file" 2>/dev/null)
            fi
            log_status "ERROR" "❌ Claude Code process exited immediately (exit code: $early_exit)"
            if [[ -n "$early_output" ]]; then
                log_status "ERROR" "Output: $early_output"
            fi
            echo ""
            echo -e "${RED}Claude Code failed to start.${NC}"
            echo ""
            echo -e "${YELLOW}Possible causes:${NC}"
            echo "  - '${CLAUDE_CODE_CMD}' command not found or not executable"
            echo "  - Claude Code CLI not installed"
            echo "  - Authentication or configuration issue"
            echo ""
            echo -e "${YELLOW}To fix:${NC}"
            echo "  1. Verify Claude Code works: ${CLAUDE_CODE_CMD} --version"
            echo "  2. Or set a different command in .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
            echo ""
            return 1
        fi

        # Show progress while Claude Code is running
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            # Get last line from output if available
            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                # Copy to live.log for tmux monitoring
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi

            # Update progress file for monitor
            cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

            # Only log if verbose mode is enabled
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
                fi
            fi

            sleep 10
        done

        # Wait for the process to finish and get exit code
        wait $claude_pid
        exit_code=$?
    fi

    # Issue #75: pull changed files back from the cloud sandbox BEFORE the
    # analysis and git-based progress detection below, so sandbox-side work
    # counts as progress on the host. Runs on every exit path (success,
    # failure, timeout) — partial work must never be stranded in the cloud.
    if [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
        sync_e2b_artifacts_down || log_status "WARN" "E2B artifact sync failed for this iteration"
    fi

    if [ $exit_code -eq 0 ]; then
        # Check for is_error:true — API error despite exit code 0 (Issue #134, #199)
        # Claude CLI can return exit code 0 with is_error:true for API 400 errors,
        # OAuth token expiry, and tool use concurrency issues.
        # This check MUST happen before progress file write and save_claude_session.
        if [[ -f "$output_file" ]]; then
            local json_is_error
            json_is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
            if [[ "$json_is_error" == "true" ]]; then
                local error_msg
                error_msg=$(jq -r '.result // "unknown API error"' "$output_file" 2>/dev/null || echo "unknown API error")
                log_status "ERROR" "❌ Claude CLI returned is_error:true despite exit code 0: $error_msg"
                echo '{"status": "failed", "error": "is_error:true", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                # Reset session to prevent infinite retry with bad session ID
                if echo "$error_msg" | grep -qi "tool.use.concurrency\|concurrency"; then
                    reset_session "tool_use_concurrency_error"
                    log_status "WARN" "Session reset due to tool use concurrency error. Retrying with fresh session."
                else
                    reset_session "api_error_is_error_true"
                    log_status "WARN" "Session reset due to API error (is_error:true). Retrying with fresh session."
                fi
                return 1
            fi
        fi

        # Clear progress file (only after is_error check passes)
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Claude Code execution completed successfully"

        # Save session ID from JSON output (Phase 1.1)
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Accumulate token usage for hourly limit tracking (Issue #223)
        update_token_count "$output_file"

        # Analyze the response
        log_status "INFO" "🔍 Analyzing Claude Code response..."
        analyze_response "$output_file" "$loop_count"
        local analysis_exit_code=$?

        if [[ $analysis_exit_code -eq 0 ]]; then
            # Update exit signals based on analysis
            update_exit_signals

            # Log analysis summary
            log_analysis_summary
        else
            log_status "WARN" "Response analysis failed (exit $analysis_exit_code); skipping signal updates"
            rm -f "$RESPONSE_ANALYSIS_FILE"
        fi

        # Get file change count for circuit breaker
        # Fix #141: Detect both uncommitted changes AND committed changes
        local files_changed=0
        local loop_start_sha=""
        local current_sha=""

        if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
            loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
        fi

        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

            # Check if commits were made (HEAD changed)
            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                # Commits were made - count union of committed files AND working tree changes
                # This catches cases where Claude commits some files but still has other modified files
                files_changed=$(
                    {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null           # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
                [[ "$VERBOSE_PROGRESS" == "true" ]] && log_status "DEBUG" "Detected $files_changed unique files changed (commits + working tree) since loop start"
            else
                # No commits - check for uncommitted changes (staged + unstaged)
                files_changed=$(
                    {
                        git diff --name-only 2>/dev/null                # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        # Layer 1: Timeout guard — exit code 124 is a timeout, not an API limit
        # Issue #198: Check for productive work before treating as failure
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "⏱️ Claude Code execution timed out (not an API limit)"

            # Issues #74/#75: a host-side timeout kills only the local exec
            # client; reap the orphaned process inside the sandbox (container
            # restart / remote pkill) so the next iteration starts clean
            if [[ "$SANDBOX_PROVIDER" == "docker" ]]; then
                handle_sandbox_timeout
            elif [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
                handle_e2b_sandbox_timeout
            fi

            # Check git for actual changes made during the timed-out execution
            local timeout_loop_start_sha=""
            local timeout_current_sha=""
            local timeout_files_changed=0

            if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
                timeout_loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
            fi

            if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
                timeout_current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

                if [[ -n "$timeout_loop_start_sha" && -n "$timeout_current_sha" && "$timeout_loop_start_sha" != "$timeout_current_sha" ]]; then
                    timeout_files_changed=$(
                        {
                            git diff --name-only "$timeout_loop_start_sha" "$timeout_current_sha" 2>/dev/null
                            git diff --name-only HEAD 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                else
                    timeout_files_changed=$(
                        {
                            git diff --name-only 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                fi
            fi

            if [[ $timeout_files_changed -gt 0 ]]; then
                # Productive timeout — work was done despite the timeout
                log_status "INFO" "⏱️ Timeout but $timeout_files_changed file(s) changed — treating iteration as productive"
                echo '{"status": "timed_out_productive", "files_changed": '$timeout_files_changed', "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                # Save session ID (fallback already populated by Step 1 if stream was truncated)
                if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
                    save_claude_session "$output_file"
                fi

                # Run analysis pipeline on whatever output exists
                log_status "INFO" "🔍 Analyzing response from productive timeout..."
                analyze_response "$output_file" "$loop_count"
                local timeout_analysis_exit=$?

                if [[ $timeout_analysis_exit -eq 0 ]]; then
                    update_exit_signals
                    log_analysis_summary
                else
                    # Clear stale response analysis to prevent next loop from reusing
                    # old EXIT_SIGNAL, permission-denial, or question-detection state
                    log_status "WARN" "Timeout response analysis failed (exit $timeout_analysis_exit); clearing stale analysis"
                    rm -f "$RESPONSE_ANALYSIS_FILE"
                fi

                # Feed circuit breaker with progress data
                local timeout_output_length
                timeout_output_length=$(wc -c < "$output_file" 2>/dev/null || echo "0")
                record_loop_result "$loop_count" "$timeout_files_changed" "false" "$timeout_output_length"
                local timeout_circuit_result=$?

                if [[ $timeout_circuit_result -ne 0 ]]; then
                    log_status "WARN" "Circuit breaker opened - halting execution"
                    return 3
                fi

                return 0
            else
                # Idle timeout — no work detected
                log_status "WARN" "⏱️ Timeout with no detectable progress"
                return 1
            fi
        fi  # end timeout

        # Layer 2: Structural JSON detection — check rate_limit_event for status:"rejected"
        # This is the definitive signal from the Claude CLI
        if grep -q '"rate_limit_event"' "$output_file" 2>/dev/null; then
            local last_rate_event
            last_rate_event=$(grep '"rate_limit_event"' "$output_file" | tail -1)
            if echo "$last_rate_event" | grep -qE '"status"\s*:\s*"rejected"'; then
                log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
                return 2  # Real API limit
            fi
        fi

        # Layer 3: Filtered text fallback — only check tail, excluding tool result lines
        # Filters out type:user, tool_result, and tool_use_id lines which contain echoed file content
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached"; then
            log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
            return 2  # API limit detected via text fallback
        fi

        # Layer 4: Extra Usage quota detection (Issue #100)
        # Claude Code "Extra Usage" mode uses a different error message:
        # "You're out of extra usage · resets 9pm"
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "out of extra usage"; then
            log_status "ERROR" "🚫 Claude Extra Usage quota exhausted"
            return 2  # Extra Usage limit detected
        fi

        log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
        return 1
    fi
}

# Cleanup function
cleanup() {
    local trap_exit_code=$?

    # Reentrancy guard — prevent double execution from EXIT + signal combination
    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    # Tear down the sandbox on any exit path so no orphaned containers, cloud
    # sandboxes (billing!), or credential files are left behind (Issues
    # #74/#75). Both cleanups are idempotent, so running here AND after the
    # main loop is safe.
    if [[ "${SANDBOX_PROVIDER:-}" == "docker" ]] && declare -F cleanup_docker_sandbox >/dev/null 2>&1; then
        cleanup_docker_sandbox
    elif [[ "${SANDBOX_PROVIDER:-}" == "e2b" ]] && declare -F cleanup_e2b_sandbox >/dev/null 2>&1; then
        cleanup_e2b_sandbox
    fi

    # Only record "interrupted" status for abnormal exits (non-zero exit code)
    # Normal exit (code 0) preserves the status already written by the main loop
    if [[ $loop_count -gt 0 && $trap_exit_code -ne 0 ]]; then
        log_status "INFO" "Ralph loop interrupted. Cleaning up..."
        reset_session "manual_interrupt"
        update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    fi
    # No exit here — EXIT trap handles natural termination
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Check for an un-migrated old flat structure BEFORE anything else — including
    # Claude CLI validation — so the migration guidance fires regardless of whether
    # the CLI is installed. Uses the shared is_legacy_flat_structure helper so this
    # gate stays in lock-step with the directory-init guard (Issue #41).
    if is_legacy_flat_structure; then
        log_status "ERROR" "This project uses the old flat structure."
        echo ""
        echo "Ralph v0.10.0+ uses a .ralph/ subfolder to keep your project root clean."
        echo ""
        echo "To upgrade your project, run:"
        echo "  ralph-migrate"
        echo ""
        echo "This will move Ralph-specific files to .ralph/ while preserving src/ at root."
        echo "A backup will be created before migration."
        exit 1
    fi

    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
        fi
    fi
    # Re-apply CLI flags that must take priority over .ralphrc (Issue #23)
    # _cli_ENABLE_BACKUP is set only when --backup / -b was explicitly passed
    [[ "${_cli_ENABLE_BACKUP:-false}" == "true" ]] && ENABLE_BACKUP=true
    [[ "${_cli_LIVE_SHOW_TOOL_ARGS:-false}" == "true" ]] && LIVE_SHOW_TOOL_ARGS=true
    # GitHub issue lifecycle flags (Issue #73) — CLI overrides .ralphrc
    [[ -n "${_cli_GITHUB_ISSUE:-}" ]] && GITHUB_ISSUE="$_cli_GITHUB_ISSUE"
    [[ "${_cli_COMMENT_PROGRESS:-false}" == "true" ]] && COMMENT_PROGRESS=true
    [[ -n "${_cli_COMMENT_INTERVAL:-}" ]] && COMMENT_INTERVAL="$_cli_COMMENT_INTERVAL"
    [[ "${_cli_AUTO_CLOSE:-false}" == "true" ]] && AUTO_CLOSE=true
    [[ "${_cli_CLOSE_SUMMARY:-false}" == "true" ]] && CLOSE_SUMMARY=true
    [[ "${_cli_CREATE_PR:-false}" == "true" ]] && CREATE_PR=true
    [[ "${_cli_LINK_ISSUE:-false}" == "true" ]] && LINK_ISSUE=true
    [[ "${_cli_DRAFT_PR:-false}" == "true" ]] && DRAFT_PR=true
    [[ "${_cli_CREATE_FOLLOWUPS:-false}" == "true" ]] && CREATE_FOLLOWUPS=true
    [[ -n "${_cli_FOLLOWUP_LABEL:-}" ]] && FOLLOWUP_LABEL="$_cli_FOLLOWUP_LABEL"
    [[ -n "${_cli_ADD_COMPLETION_LABELS:-}" ]] && ADD_COMPLETION_LABELS="$_cli_ADD_COMPLETION_LABELS"
    # Docker sandbox flags (Issue #74) — CLI overrides .ralphrc
    [[ -n "${_cli_SANDBOX_PROVIDER:-}" ]] && SANDBOX_PROVIDER="$_cli_SANDBOX_PROVIDER"
    [[ -n "${_cli_SANDBOX_IMAGE:-}" ]] && SANDBOX_DOCKER_IMAGE="$_cli_SANDBOX_IMAGE"
    [[ -n "${_cli_SANDBOX_MEMORY:-}" ]] && SANDBOX_DOCKER_MEMORY="$_cli_SANDBOX_MEMORY"
    [[ -n "${_cli_SANDBOX_CPUS:-}" ]] && SANDBOX_DOCKER_CPUS="$_cli_SANDBOX_CPUS"
    [[ -n "${_cli_SANDBOX_NETWORK:-}" ]] && SANDBOX_DOCKER_NETWORK="$_cli_SANDBOX_NETWORK"
    # E2B sandbox flags (Issue #75) — CLI overrides .ralphrc
    [[ -n "${_cli_SANDBOX_E2B_TEMPLATE:-}" ]] && SANDBOX_E2B_TEMPLATE="$_cli_SANDBOX_E2B_TEMPLATE"
    [[ -n "${_cli_SANDBOX_E2B_SANDBOX_ID:-}" ]] && SANDBOX_E2B_SANDBOX_ID="$_cli_SANDBOX_E2B_SANDBOX_ID"
    [[ -n "${_cli_SANDBOX_E2B_TIMEOUT:-}" ]] && SANDBOX_E2B_TIMEOUT="$_cli_SANDBOX_E2B_TIMEOUT"
    [[ "${_cli_SANDBOX_E2B_KEEP_ALIVE:-false}" == "true" ]] && SANDBOX_E2B_KEEP_ALIVE=true
    [[ -n "${_cli_SANDBOX_E2B_MAX_COST:-}" ]] && SANDBOX_E2B_MAX_COST="$_cli_SANDBOX_E2B_MAX_COST"
    [[ -n "${_cli_SANDBOX_E2B_COST_ALERT:-}" ]] && SANDBOX_E2B_COST_ALERT="$_cli_SANDBOX_E2B_COST_ALERT"
    # Sync filter flags (Issue #76) — CLI overrides .ralphrc
    [[ -n "${_cli_SYNC_INCLUDE:-}" ]] && SYNC_INCLUDE="$_cli_SYNC_INCLUDE"
    [[ -n "${_cli_SYNC_EXCLUDE:-}" ]] && SYNC_EXCLUDE="$_cli_SYNC_EXCLUDE"

    # Sandbox sub-flags are meaningless without a provider, and each sub-flag
    # belongs to exactly one provider (Issues #74/#75). Checked here (not at
    # parse time) because .ralphrc may legitimately supply SANDBOX_PROVIDER
    # while the CLI only overrides e.g. the image or template.
    local _cli_docker_subflags="${_cli_SANDBOX_IMAGE:-}${_cli_SANDBOX_MEMORY:-}${_cli_SANDBOX_CPUS:-}${_cli_SANDBOX_NETWORK:-}"
    local _cli_e2b_subflags="${_cli_SANDBOX_E2B_TEMPLATE:-}${_cli_SANDBOX_E2B_SANDBOX_ID:-}${_cli_SANDBOX_E2B_TIMEOUT:-}${_cli_SANDBOX_E2B_MAX_COST:-}${_cli_SANDBOX_E2B_COST_ALERT:-}"
    [[ "${_cli_SANDBOX_E2B_KEEP_ALIVE:-false}" == "true" ]] && _cli_e2b_subflags+="keep-alive"
    if [[ -z "$SANDBOX_PROVIDER" && -n "${_cli_docker_subflags}${_cli_e2b_subflags}" ]]; then
        log_status "ERROR" "Sandbox sub-flags (--sandbox-image/--sandbox-template/...) require --sandbox <provider>"
        exit 1
    fi
    if [[ "$SANDBOX_PROVIDER" == "e2b" && -n "$_cli_docker_subflags" ]]; then
        log_status "ERROR" "--sandbox-image/--sandbox-memory/--sandbox-cpus/--sandbox-network require --sandbox docker"
        exit 1
    fi
    if [[ "$SANDBOX_PROVIDER" == "docker" && -n "$_cli_e2b_subflags" ]]; then
        log_status "ERROR" "--sandbox-template/--sandbox-id/--sandbox-timeout/--sandbox-keep-alive/--sandbox-max-cost/--sandbox-cost-alert require --sandbox e2b"
        exit 1
    fi
    # Sync filter flags only make sense where files are actually synced
    # (Issue #76): E2B uploads/downloads; the Docker rw bind mount shares the
    # whole project in real time, so there is nothing to filter there.
    local _cli_sync_subflags="${_cli_SYNC_INCLUDE:-}${_cli_SYNC_EXCLUDE:-}"
    if [[ -n "$_cli_sync_subflags" ]]; then
        if [[ "$SANDBOX_PROVIDER" == "docker" ]]; then
            log_status "ERROR" "--sync-include/--sync-exclude do not apply to --sandbox docker (the bind mount shares the whole project in real time)"
            exit 1
        elif [[ "$SANDBOX_PROVIDER" != "e2b" ]]; then
            log_status "ERROR" "--sync-include/--sync-exclude require --sandbox e2b"
            exit 1
        fi
    fi
    # Sync filter config can also arrive via env/.ralphrc — validate whenever
    # a provider that syncs files is active.
    if [[ "$SANDBOX_PROVIDER" == "e2b" ]] && ! validate_sync_config; then
        exit 1
    fi

    # SANDBOX_PROVIDER can arrive via env/.ralphrc, bypassing the CLI's parse-time
    # validation. An unsupported value (typo, not-yet-implemented provider) must
    # halt — silently executing on the host would defeat the requested isolation.
    if [[ -n "$SANDBOX_PROVIDER" && "$SANDBOX_PROVIDER" != "docker" && "$SANDBOX_PROVIDER" != "e2b" ]]; then
        log_status "ERROR" "Unsupported sandbox provider '$SANDBOX_PROVIDER' (supported: docker, e2b). Refusing host execution."
        exit 1
    fi

    # Source user shell init file if configured (e.g. ~/.zshrc for zsh environments)
    # This allows non-bash shells or non-standard setups to export PATH/env vars
    # needed by the claude command before validation runs.
    if [[ -n "${RALPH_SHELL_INIT_FILE:-}" ]]; then
        if [[ -f "$RALPH_SHELL_INIT_FILE" ]]; then
            # shellcheck source=/dev/null
            source "$RALPH_SHELL_INIT_FILE"
            log_status "INFO" "Sourced shell init file: $RALPH_SHELL_INIT_FILE"
        else
            log_status "WARN" "RALPH_SHELL_INIT_FILE not found: $RALPH_SHELL_INIT_FILE"
        fi
    fi

    # Validate Claude Code CLI is available before starting. In sandbox mode
    # Claude runs inside the container/cloud sandbox (which provides its own
    # CLI), so host validation/version checks are skipped (Issues #74/#75).
    if [[ "$SANDBOX_PROVIDER" == "docker" || "$SANDBOX_PROVIDER" == "e2b" ]]; then
        log_status "INFO" "Sandbox mode: skipping host Claude CLI validation (the sandbox provides the CLI)"
    else
        if ! validate_claude_command; then
            log_status "ERROR" "Claude Code CLI not found: $CLAUDE_CODE_CMD"
            exit 1
        fi

        # Check CLI version compatibility and auto-update (Issue #190)
        check_claude_version
        check_claude_updates
    fi

    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"

    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "$RALPH_DIR/fix_plan.md" ]] || [[ -d "$RALPH_DIR/specs" ]] || [[ -f "$RALPH_DIR/AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing .ralph/PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi

        echo ""
        echo "To fix this:"
        echo "  1. Enable Ralph in existing project: ralph-enable"
        echo "  2. Create a new project: ralph-setup my-project"
        echo "  3. Import existing requirements: ralph-import requirements.md"
        echo "  4. Navigate to an existing Ralph project directory"
        echo "  5. Or create .ralph/PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/, src/, etc."
        exit 1
    fi

    # Verify Ralph file integrity on startup (Issue #149)
    if ! validate_ralph_integrity; then
        log_status "ERROR" "Ralph integrity check failed - critical files missing"
        echo ""
        echo "$(get_integrity_report)"
        echo ""
        exit 1
    fi

    # Start the Docker sandbox before entering the loop (Issue #74). One
    # persistent container serves every iteration via docker exec. Any failure
    # is fatal — the user asked for isolation, so host fallback is forbidden.
    if [[ "$SANDBOX_PROVIDER" == "docker" ]]; then
        log_status "INFO" "🐳 Docker sandbox mode enabled (image: $SANDBOX_DOCKER_IMAGE, network: $SANDBOX_DOCKER_NETWORK)"
        if ! init_docker_sandbox || ! setup_docker_credentials || ! start_sandbox_container; then
            log_status "ERROR" "Docker sandbox setup failed — refusing to fall back to host execution"
            cleanup_docker_sandbox
            exit 1
        fi
    fi

    # Start the E2B cloud sandbox before entering the loop (Issue #75). One
    # sandbox serves every iteration; the project is uploaded once and changed
    # files sync back after each loop. Failure is fatal — no host fallback.
    if [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
        log_status "INFO" "☁️  E2B sandbox mode enabled (template: $SANDBOX_E2B_TEMPLATE, session timeout: ${SANDBOX_E2B_TIMEOUT}s)"
        if ! init_e2b_sandbox || ! start_e2b_sandbox; then
            log_status "ERROR" "E2B sandbox setup failed — refusing to fall back to host execution"
            cleanup_e2b_sandbox
            exit 1
        fi
    fi

    # Initialize session tracking before entering the loop
    init_session_tracking

    # Initialize GitHub issue lifecycle tracking if an issue was provided (Issue #73)
    if [[ -n "$GITHUB_ISSUE" ]]; then
        if init_github_lifecycle "$GITHUB_ISSUE"; then
            log_status "INFO" "GitHub issue lifecycle enabled for: $GITHUB_ISSUE"
        else
            log_status "WARN" "Disabling GitHub issue lifecycle (invalid reference): $GITHUB_ISSUE"
            GITHUB_ISSUE=""
        fi
    fi

    # Reset exit signals to prevent stale state from prior run causing premature exit (Issue #194)
    # This is unconditional: regardless of how the previous run ended (crash, SIGKILL, API limit exit),
    # every new ralph invocation starts with a clean exit-signal slate.
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null
    log_status "INFO" "Reset exit signals for fresh start"

    log_status "INFO" "Starting main loop..."

    while true; do
        loop_count=$((loop_count + 1))

        # Rotate log if it exceeds 10MB (Issue #18)
        rotate_logs

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Verify Ralph's critical files still exist (Issue #149)
        if ! validate_ralph_integrity; then
            # Ensure log directory exists for logging even if .ralph/ was deleted
            mkdir -p "$LOG_DIR" 2>/dev/null
            log_status "ERROR" "Ralph integrity check failed - critical files missing"
            echo ""
            echo "$(get_integrity_report)"
            echo ""
            reset_session "integrity_failure"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)" "integrity_failure" "halted" "files_deleted"
            break
        fi

        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            send_notification "Ralph - Circuit Breaker" "Circuit breaker opened - execution halted due to stagnation"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            # Handle permission_denied specially (Issue #101)
            if [[ "$exit_reason" == "permission_denied" ]]; then
                log_status "ERROR" "🚫 Permission denied - halting loop"
                reset_session "permission_denied"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "permission_denied" "halted" "permission_denied"

                # Display helpful guidance for resolving permission issues
                echo ""
                echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  PERMISSION DENIED - Loop Halted                          ║${NC}"
                echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}Claude Code was denied permission to execute commands.${NC}"
                echo ""
                echo -e "${YELLOW}To fix this:${NC}"
                echo "  1. Edit .ralphrc and update ALLOWED_TOOLS to include the required tools"
                echo "  2. Common patterns:"
                echo "     - Bash(npm *)     - All npm commands"
                echo "     - Bash(npm install) - Only npm install"
                echo "     - Bash(pnpm *)    - All pnpm commands"
                echo "     - Bash(yarn *)    - All yarn commands"
                echo ""
                echo -e "${YELLOW}After updating .ralphrc:${NC}"
                echo "  ralph --reset-session  # Clear stale session state"
                echo "  ralph --monitor        # Restart the loop"
                echo ""

                # Show current ALLOWED_TOOLS if .ralphrc exists
                if [[ -f ".ralphrc" ]]; then
                    local current_tools=$(grep "^ALLOWED_TOOLS=" ".ralphrc" 2>/dev/null | cut -d= -f2- | tr -d '"')
                    if [[ -n "$current_tools" ]]; then
                        echo -e "${BLUE}Current ALLOWED_TOOLS:${NC} $current_tools"
                        echo ""
                    fi
                fi

                break
            fi

            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            send_notification "Ralph - Complete" "Project completed! Exit reason: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"
            print_metrics_summary

            # GitHub issue lifecycle completion workflow (Issue #73): summary, PR,
            # follow-ups, close. Each step is opt-in and degrades gracefully.
            if [[ -n "$GITHUB_ISSUE" ]]; then
                lifecycle_on_completion
            fi

            break
        fi
        
        # Update status
        local calls_made
        calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Capture loop start time and pre-execution call count for metrics (Issue #21)
        local loop_start_epoch
        loop_start_epoch=$(get_epoch_seconds)
        local calls_before_exec="$calls_made"

        # Create backup branch before execution (Issue #23)
        create_backup "$loop_count"

        # Execute Claude Code
        execute_claude_code "$loop_count"
        local exec_result=$?

        # Record metrics for this loop (Issue #21)
        # Use per-loop call delta so total_calls remains accurate across hourly resets
        local loop_duration
        loop_duration=$(( $(get_epoch_seconds) - loop_start_epoch ))
        local loop_success="false"
        [ $exec_result -eq 0 ] && loop_success="true"
        local calls_after_exec
        calls_after_exec=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        local calls_this_loop=$(( calls_after_exec > calls_before_exec ? calls_after_exec - calls_before_exec : calls_after_exec ))
        track_metrics "$loop_count" "$loop_duration" "$loop_success" "$calls_this_loop"

        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"
            send_notification "Ralph - Loop Complete" "Loop #$loop_count completed successfully"

            # Post a GitHub progress comment every COMMENT_INTERVAL loops (Issue #73)
            if [[ -n "$GITHUB_ISSUE" ]]; then
                lifecycle_post_progress "$loop_count"
            fi

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            send_notification "Ralph - Circuit Breaker" "Circuit breaker opened - execution halted due to stagnation"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 Claude API 5-hour limit reached!"
            send_notification "Ralph - API Limit" "Claude API 5-hour usage limit reached. User action required."
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}A Claude API usage limit has been reached (5-hour plan limit or Extra Usage quota).${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice || true
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]]; then
                log_status "INFO" "User chose to exit. Exiting loop..."
                reset_session "api_limit_exit"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                # Auto-wait on timeout (empty choice) or explicit "1" — supports unattended operation
                log_status "INFO" "Waiting for API limit reset (auto-wait for unattended mode)..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            send_notification "Ralph - Error" "Claude Code execution failed. Check logs for details."
            sleep 30
        fi
        
        # Enforce the E2B cost budget between iterations (Issue #75): once the
        # estimated spend reaches --sandbox-max-cost, stop gracefully (artifacts
        # are already synced; cleanup below kills the sandbox to stop billing).
        if [[ "$SANDBOX_PROVIDER" == "e2b" ]] && ! check_e2b_cost_limits; then
            log_status "WARN" "💸 E2B cost limit reached — exiting gracefully"
            send_notification "Ralph - Cost Limit" "E2B sandbox cost limit reached. Loop stopped."
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)" "cost_limit" "stopped" "e2b_cost_limit"
            break
        fi

        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done

    # Tear down the sandbox on every normal loop exit (break paths). The
    # SIGINT/SIGTERM trap covers interrupts; cleanup is idempotent (Issues #74/#75).
    if [[ "$SANDBOX_PROVIDER" == "docker" ]]; then
        cleanup_docker_sandbox
    elif [[ "$SANDBOX_PROVIDER" == "e2b" ]]; then
        cleanup_e2b_sandbox
    fi
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Claude Code

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Show Claude Code output in real-time (auto-switches to JSON output)
    -t, --timeout MIN       Set Claude Code execution timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup (bypasses cooldown)
    --reset-session         Reset session state and exit (clears session continuity)
    --dry-run               Simulate loop execution without making actual Claude API calls
    -n, --notify            Enable desktop notifications for key events
    -b, --backup            Enable automatic git backup branch before each loop (requires git)
    --show-tool-args        Show tool arguments (commands, file paths) in live streaming output
    --rollback [BRANCH]     Roll back to a backup branch (lists available backups if no branch given)

Batch processing / issue queue (Issue #72; see 'ralph-queue --help'):
    --queue-status          Show the issue queue and exit
    --process-queue [--halt-on-failure]
                            Process pending queued issues sequentially and exit
    --resume-queue          Resume processing the remaining pending issues
    --queue-next            Print the id of the next ready queued issue
    --queue-clear           Remove all items from the queue
    --queue-remove <id|N>   Remove one item from the queue by id or issue number

GitHub issue lifecycle (Issue #73; all opt-in, require --github-issue):
    --github-issue REF      Track a GitHub issue (N, #N, owner/repo#N, or URL)
    --comment-progress      Post progress comments to the issue during development
    --comment-interval NUM  Post a progress comment every NUM loops (default: $COMMENT_INTERVAL)
    --auto-close            Close the issue on graceful completion
    --close-summary         Post a summary comment on completion
    --create-pr             Create a pull request on completion
    --link-issue            Add "Closes #N" to the PR body (with --create-pr)
    --draft-pr              Create the PR as a draft (with --create-pr)
    --create-followups      Open a follow-up issue for TODO/FIXME markers added during dev
    --followup-label LABEL  Label for follow-up issues (default: $FOLLOWUP_LABEL)
    --add-label LABEL       Label to add to the issue on close (repeatable)

Sandbox execution (Issues #74/#75; isolates Claude in a sandbox):
    --sandbox PROVIDER      Run Claude Code inside a sandbox: docker, e2b
                            (the supported provider set is final — see issues #79/#80)

  Docker provider sub-flags (--sandbox docker):
    --sandbox-image IMAGE   Container image (default: $SANDBOX_DOCKER_IMAGE)
                            Build the default: docker build -t ralph-sandbox .
    --sandbox-memory SIZE   Container memory limit (default: $SANDBOX_DOCKER_MEMORY)
    --sandbox-cpus NUM      Container CPU limit (default: $SANDBOX_DOCKER_CPUS)
    --sandbox-network MODE  Container network: none, bridge, host (default: $SANDBOX_DOCKER_NETWORK)
                            Note: 'none' blocks the Claude API — only for pre-authenticated images

  E2B cloud provider sub-flags (--sandbox e2b; needs E2B_API_KEY or ~/.ralph/e2b_api_key):
    --sandbox-template T    E2B template (default: $SANDBOX_E2B_TEMPLATE; custom templates can preinstall claude)
    --sandbox-id ID         Reconnect to an existing E2B sandbox instead of creating one
    --sandbox-timeout SECS  E2B session timeout in seconds (default: $SANDBOX_E2B_TIMEOUT)
    --sandbox-keep-alive    Leave the sandbox running on exit (reuse via --sandbox-id)
    --sandbox-max-cost USD  Stop gracefully once estimated cost reaches this amount
    --sandbox-cost-alert USD  Warn once when estimated cost reaches this amount
                            (rate via SANDBOX_E2B_COST_PER_HOUR in .ralphrc, default $SANDBOX_E2B_COST_PER_HOUR/h)

  Sync filter sub-flags (--sandbox e2b; Docker's bind mount syncs everything in real time):
    --sync-include PATTERNS Comma-separated patterns; only matching files upload
                            (.ralph control files always go), e.g. 'src/**,*.md'
    --sync-exclude PATTERNS Comma-separated patterns excluded from upload AND
                            download, e.g. '*.log,node_modules'
                            A .ralphignore file in the project root adds exclude
                            patterns; large-file policy via SYNC_MAX_FILE_SIZE /
                            SYNC_LARGE_FILE_ACTION in .ralphrc (default: warn at 10MB)

Modern CLI Options (Phase 1.1):
    --output-format FORMAT  Set Claude output format: json or text (default: $CLAUDE_OUTPUT_FORMAT)
                            Note: --live mode requires JSON and will auto-switch
    --allowed-tools TOOLS   Comma-separated list of allowed tools (default: $CLAUDE_ALLOWED_TOOLS)
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CLAUDE_SESSION_EXPIRY_HOURS)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.token_count: Cumulative token counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --live                # Show Claude Code output in real-time (streaming)
    $0 --live --verbose      # Live streaming + verbose logging
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --output-format text     # Use legacy text output format
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration

HELPEOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -l|--live)
            LIVE_OUTPUT=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CLAUDE_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            # Reset session state only
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CLAUDE_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CLAUDE_ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --no-continue)
            CLAUDE_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CLAUDE_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -n|--notify)
            ENABLE_NOTIFICATIONS=true
            shift
            ;;
        -b|--backup)
            ENABLE_BACKUP=true
            _cli_ENABLE_BACKUP=true
            shift
            ;;
        --show-tool-args)
            LIVE_SHOW_TOOL_ARGS=true
            _cli_LIVE_SHOW_TOOL_ARGS=true
            shift
            ;;
        --rollback)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            rollback_to_backup "${2:-}"
            exit $?
            ;;
        --github-issue)
            # GitHub issue lifecycle management (Issue #73)
            GITHUB_ISSUE="$2"
            _cli_GITHUB_ISSUE="$2"
            shift 2
            ;;
        --comment-progress)
            COMMENT_PROGRESS=true
            _cli_COMMENT_PROGRESS=true
            shift
            ;;
        --comment-interval)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                COMMENT_INTERVAL="$2"
                _cli_COMMENT_INTERVAL="$2"
            else
                echo "Error: --comment-interval must be a positive integer"
                exit 1
            fi
            shift 2
            ;;
        --auto-close)
            AUTO_CLOSE=true
            _cli_AUTO_CLOSE=true
            shift
            ;;
        --close-summary)
            CLOSE_SUMMARY=true
            _cli_CLOSE_SUMMARY=true
            shift
            ;;
        --create-pr)
            CREATE_PR=true
            _cli_CREATE_PR=true
            shift
            ;;
        --link-issue)
            LINK_ISSUE=true
            _cli_LINK_ISSUE=true
            shift
            ;;
        --draft-pr)
            DRAFT_PR=true
            _cli_DRAFT_PR=true
            shift
            ;;
        --create-followups)
            CREATE_FOLLOWUPS=true
            _cli_CREATE_FOLLOWUPS=true
            shift
            ;;
        --followup-label)
            FOLLOWUP_LABEL="$2"
            _cli_FOLLOWUP_LABEL="$2"
            shift 2
            ;;
        --add-label)
            # Repeatable: accumulate into a comma-separated list
            if [[ -n "$ADD_COMPLETION_LABELS" ]]; then
                ADD_COMPLETION_LABELS="${ADD_COMPLETION_LABELS},$2"
            else
                ADD_COMPLETION_LABELS="$2"
            fi
            _cli_ADD_COMPLETION_LABELS="$ADD_COMPLETION_LABELS"
            shift 2
            ;;
        --sandbox)
            # Sandbox execution (Issues #74/#75)
            case "${2:-}" in
                docker|e2b)
                    SANDBOX_PROVIDER="$2"
                    _cli_SANDBOX_PROVIDER="$2"
                    ;;
                daytona|cloudflare)
                    echo "Error: --sandbox $2 is not supported (additional providers are not planned — see issues #79, #80). Supported: docker, e2b"
                    exit 1
                    ;;
                *)
                    echo "Error: --sandbox requires a provider. Supported: docker, e2b"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --sandbox-image)
            if [[ -z "${2:-}" || ! "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]; then
                echo "Error: --sandbox-image requires a valid image reference (e.g. node:20)"
                exit 1
            fi
            SANDBOX_DOCKER_IMAGE="$2"
            _cli_SANDBOX_IMAGE="$2"
            shift 2
            ;;
        --sandbox-memory)
            if [[ ! "${2:-}" =~ ^[0-9]+[bkmgBKMG]?$ ]]; then
                echo "Error: --sandbox-memory must be a Docker memory limit (e.g. 4g, 512m)"
                exit 1
            fi
            SANDBOX_DOCKER_MEMORY="$2"
            _cli_SANDBOX_MEMORY="$2"
            shift 2
            ;;
        --sandbox-cpus)
            if [[ ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "Error: --sandbox-cpus must be numeric (e.g. 2 or 1.5)"
                exit 1
            fi
            SANDBOX_DOCKER_CPUS="$2"
            _cli_SANDBOX_CPUS="$2"
            shift 2
            ;;
        --sandbox-network)
            case "${2:-}" in
                none|bridge|host)
                    SANDBOX_DOCKER_NETWORK="$2"
                    _cli_SANDBOX_NETWORK="$2"
                    ;;
                *)
                    echo "Error: --sandbox-network must be none, bridge, or host"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --sandbox-template)
            # E2B sandbox sub-flags (Issue #75)
            if [[ -z "${2:-}" || ! "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
                echo "Error: --sandbox-template requires a valid E2B template name (e.g. base)"
                exit 1
            fi
            SANDBOX_E2B_TEMPLATE="$2"
            _cli_SANDBOX_E2B_TEMPLATE="$2"
            shift 2
            ;;
        --sandbox-id)
            if [[ -z "${2:-}" || ! "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
                echo "Error: --sandbox-id requires a valid E2B sandbox id (e.g. sbx_abc123)"
                exit 1
            fi
            SANDBOX_E2B_SANDBOX_ID="$2"
            _cli_SANDBOX_E2B_SANDBOX_ID="$2"
            shift 2
            ;;
        --sandbox-timeout)
            if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --sandbox-timeout must be a positive number of seconds (e.g. 3600)"
                exit 1
            fi
            SANDBOX_E2B_TIMEOUT="$2"
            _cli_SANDBOX_E2B_TIMEOUT="$2"
            shift 2
            ;;
        --sandbox-keep-alive)
            SANDBOX_E2B_KEEP_ALIVE=true
            _cli_SANDBOX_E2B_KEEP_ALIVE=true
            shift
            ;;
        --sandbox-max-cost)
            if [[ ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "Error: --sandbox-max-cost must be a dollar amount (e.g. 5.00)"
                exit 1
            fi
            SANDBOX_E2B_MAX_COST="$2"
            _cli_SANDBOX_E2B_MAX_COST="$2"
            shift 2
            ;;
        --sandbox-cost-alert)
            if [[ ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "Error: --sandbox-cost-alert must be a dollar amount (e.g. 2.00)"
                exit 1
            fi
            SANDBOX_E2B_COST_ALERT="$2"
            _cli_SANDBOX_E2B_COST_ALERT="$2"
            shift 2
            ;;
        --sync-include)
            # Sandbox sync filter flags (Issue #76)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --sync-include requires comma-separated patterns (e.g. 'src/**,*.md')"
                exit 1
            fi
            SYNC_INCLUDE="$2"
            _cli_SYNC_INCLUDE="$2"
            shift 2
            ;;
        --sync-exclude)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --sync-exclude requires comma-separated patterns (e.g. '*.log,node_modules')"
                exit 1
            fi
            SYNC_EXCLUDE="$2"
            _cli_SYNC_EXCLUDE="$2"
            shift 2
            ;;
        --queue-status)
            # Batch processing / issue queue management (Issue #72)
            exec "$SCRIPT_DIR/ralph_queue.sh" status
            ;;
        --process-queue)
            shift
            exec "$SCRIPT_DIR/ralph_queue.sh" process "$@"
            ;;
        --resume-queue)
            shift
            exec "$SCRIPT_DIR/ralph_queue.sh" resume "$@"
            ;;
        --queue-next)
            exec "$SCRIPT_DIR/ralph_queue.sh" next
            ;;
        --queue-clear)
            exec "$SCRIPT_DIR/ralph_queue.sh" clear
            ;;
        --queue-remove)
            exec "$SCRIPT_DIR/ralph_queue.sh" remove "${2:-}"
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
