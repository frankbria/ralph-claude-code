#!/bin/bash

# lib/complexity.sh — Task classification + cost-aware model routing (Phase 14+)
#
# Dual classification system:
#   1. Complexity bands (5 levels): TRIVIAL, SIMPLE, ROUTINE, COMPLEX, ARCHITECTURAL
#   2. Task types (4 categories): docs, tools, code, arch
#
# Task-type routing (PRIMARY):
#   - docs: README, CHANGELOG, docstrings, .md files, documentation
#   - tools: lookups, audits, scans, reports, analysis
#   - code: implementation, features, tests, fixes (default)
#   - arch: architecture, design, research, migration, refactoring
#
# Configuration:
#   RALPH_MODEL_ROUTING_ENABLED=true   — Enable dynamic model selection (default: true)
#   RALPH_MODEL_TRIVIAL=haiku          — Model for trivial/simple tasks (deprecated; type-based preferred)
#   RALPH_MODEL_ROUTINE=sonnet         — Model for routine tasks (default)
#   RALPH_MODEL_COMPLEX=sonnet         — Model for complex tasks
#   RALPH_MODEL_ARCH=opus              — Model for architectural tasks
#   RALPH_DEFAULT_MODEL=sonnet         — Fallback model

RALPH_MODEL_ROUTING_ENABLED="${RALPH_MODEL_ROUTING_ENABLED:-true}"
RALPH_MODEL_TRIVIAL="${RALPH_MODEL_TRIVIAL:-haiku}"
RALPH_MODEL_ROUTINE="${RALPH_MODEL_ROUTINE:-sonnet}"
RALPH_MODEL_COMPLEX="${RALPH_MODEL_COMPLEX:-sonnet}"
RALPH_MODEL_ARCH="${RALPH_MODEL_ARCH:-opus}"
RALPH_DEFAULT_MODEL="${RALPH_DEFAULT_MODEL:-sonnet}"

# ralph_classify_task_complexity — Classify a task into 5 complexity levels
#
# Usage: ralph_classify_task_complexity "task description"
# Returns: 1 (TRIVIAL), 2 (SIMPLE), 3 (ROUTINE), 4 (COMPLEX), 5 (ARCHITECTURAL)
#
# Priority order:
# 1. Explicit size annotations [TRIVIAL], [SMALL], [MEDIUM], [LARGE], [ARCH] (honored; TAP-677 warns vs heuristic)
# 2. Heuristic: keywords, file count, multi-step, retry escalation (default base ROUTINE)
#
# _ralph_complexity_heuristic_score — Score without consulting annotations (TAP-677)
_ralph_complexity_heuristic_score() {
    local task_text="${1:-}"
    local retry_count="${2:-0}"
    local score=3
    local keyword_score=0

    if echo "$task_text" | grep -qiE 'architect|redesign|migrate|rewrite|overhaul|platform'; then
        keyword_score=$((keyword_score + 2))
        _complexity_debug "High-complexity keyword detected"
    fi

    if echo "$task_text" | grep -qiE 'refactor|integrate|implement|convert|restructure'; then
        keyword_score=$((keyword_score + 1))
        _complexity_debug "Medium-complexity keyword detected"
    fi

    if echo "$task_text" | grep -qiE 'typo|comment|rename|bump|version|trivial|simple fix'; then
        keyword_score=$((keyword_score - 1))
        _complexity_debug "Low-complexity keyword detected"
    fi

    score=$((score + keyword_score))

    local file_count
    file_count=$(echo "$task_text" | grep -oiE '[a-zA-Z0-9_/.-]+\.(py|js|ts|sh|go|rs|java|rb|c|cpp|h)' | sort -u | wc -l)
    if [[ "$file_count" -ge 10 ]]; then
        score=$((score + 2))
        _complexity_debug "File count: $file_count (10+ files → +2)"
    elif [[ "$file_count" -ge 5 ]]; then
        score=$((score + 1))
        _complexity_debug "File count: $file_count (5+ files → +1)"
    fi

    local step_count
    step_count=$(echo "$task_text" | grep -ciE '^\s*[-*]\s*\[.\]|step [0-9]|phase [0-9]|then |after that')
    if [[ "$step_count" -ge 5 ]]; then
        score=$((score + 1))
        _complexity_debug "Multi-step: $step_count steps detected"
    fi

    if [[ "$retry_count" -ge 3 ]]; then
        score=$((score + 2))
        _complexity_debug "Retry escalation: $retry_count retries → +2"
    elif [[ "$retry_count" -ge 1 ]]; then
        score=$((score + 1))
        _complexity_debug "Retry escalation: $retry_count retries → +1"
    fi

    [[ "$score" -lt 1 ]] && score=1
    [[ "$score" -gt 5 ]] && score=5

    echo "$score"
}

ralph_classify_task_complexity() {
    local task_text="${1:-}"
    local retry_count="${2:-0}"
    local ann_score=""
    local hscore

    hscore=$(_ralph_complexity_heuristic_score "$task_text" "$retry_count")

    if echo "$task_text" | grep -qiE '\[TRIVIAL\]'; then
        ann_score=1
        _complexity_debug "Annotation: TRIVIAL"
    elif echo "$task_text" | grep -qiE '\[SMALL\]'; then
        ann_score=2
        _complexity_debug "Annotation: SMALL"
    elif echo "$task_text" | grep -qiE '\[MEDIUM\]'; then
        ann_score=3
        _complexity_debug "Annotation: MEDIUM"
    elif echo "$task_text" | grep -qiE '\[LARGE\]'; then
        ann_score=4
        _complexity_debug "Annotation: LARGE"
    elif echo "$task_text" | grep -qiE '\[ARCH\]|\[ARCHITECTURAL\]'; then
        ann_score=5
        _complexity_debug "Annotation: ARCHITECTURAL"
    fi

    if [[ -n "$ann_score" ]]; then
        local diff=$((ann_score - hscore))
        [[ "$diff" -lt 0 ]] && diff=$((0 - diff))
        if [[ "$diff" -gt 1 ]]; then
            echo "[WARN] complexity: task annotated [$(ralph_complexity_name "$ann_score")] but heuristic suggests [$(ralph_complexity_name "$hscore")]" >&2
        fi
        _complexity_debug "Final score (annotation): $ann_score"
        echo "$ann_score"
        return "$ann_score"
    fi

    _complexity_debug "Final score: $hscore"
    echo "$hscore"
    return "$hscore"
}

# ralph_complexity_name — Convert numeric score to name
#
ralph_complexity_name() {
    case "${1:-3}" in
        1) echo "TRIVIAL" ;;
        2) echo "SIMPLE" ;;
        3) echo "ROUTINE" ;;
        4) echo "COMPLEX" ;;
        5) echo "ARCHITECTURAL" ;;
        *) echo "ROUTINE" ;;
    esac
}

# ralph_classify_task_type — Classify task by type for task-aware routing
#
# Usage: type=$(ralph_classify_task_type "task description")
# Returns: docs | tools | code | arch
#
# Classification priority:
#   1. docs: README, CHANGELOG, docstrings, .md files, documentation, comments, API docs
#   2. tools: lookups, audits, scans, reports, analysis, queries, finding/identifying
#   3. arch: architecture, design, research, migration, refactoring, prototyping
#   4. code: default (implementation, features, tests, fixes)
#
ralph_classify_task_type() {
    local task_text="${1:-}"

    if [[ -z "$task_text" ]]; then
        echo "code"
        return
    fi

    # Docs classification: .md, README, CHANGELOG, docs/, documentation, docstring, comment, API
    if echo "$task_text" | grep -qiE '\.md|readme|changelog|docs/|documentation|docstring|comment|api.?doc'; then
        _complexity_debug "Task type: docs"
        echo "docs"
        return
    fi

    # Tools classification: lookup, audit, scan, check, list, report, analyze, find, search, identify, query (word boundaries)
    if echo "$task_text" | grep -qiE '\b(lookup|audit|scan|check|list|report|analyze|find|search|identify|query)\b'; then
        _complexity_debug "Task type: tools"
        echo "tools"
        return
    fi

    # Arch classification: architect, design, research, migrate, refactor, rewrite, prototype, platform, infrastructure (word boundaries)
    if echo "$task_text" | grep -qiE '\b(architect|design|research|migrate|refactor|rewrite|prototype|platform|infrastructure|schema)\b'; then
        _complexity_debug "Task type: arch"
        echo "arch"
        return
    fi

    # Code classification: default
    _complexity_debug "Task type: code (default)"
    echo "code"
}

# ralph_select_model — Select model based on task type + retry escalation
#
# Usage: model=$(ralph_select_model "task text" retry_count)
#
# Returns model name string. If RALPH_MODEL_ROUTING_ENABLED=false,
# always returns RALPH_DEFAULT_MODEL.
#
# Routing logic (task-type primary):
#   - retry_count >= 3: force Opus (safety escalation for stuck tasks)
#   - docs/tools: Haiku (low cost, sufficient for lookups/analysis)
#   - code: Sonnet (floor, always; protects from under-spend)
#   - arch: Opus (research, design, migration)
#
ralph_select_model() {
    local task_text="${1:-}"
    local retry_count="${2:-0}"

    if [[ "$RALPH_MODEL_ROUTING_ENABLED" != "true" ]]; then
        echo "$RALPH_DEFAULT_MODEL"
        return 0
    fi

    local model
    local task_type
    local routing_reason=""

    # Escalation: 3+ consecutive failures on same task → force Opus
    if [[ "$retry_count" -ge 3 ]]; then
        model="opus"
        task_type="${task_type:-unknown}"
        routing_reason="qa_failure_escalation"
        _complexity_debug "Retry escalation: $retry_count failures → force Opus"
    elif [[ -z "$task_text" ]]; then
        # TAP-1210: empty-task fallback — Claude bailed out before picking
        # an issue (e.g. all backlog blocked, session resume short-circuit).
        # Still log a routing decision so .model_routing.jsonl is complete.
        model="$RALPH_DEFAULT_MODEL"
        task_type="none"
        routing_reason="no_task_fallback"
        _complexity_debug "Empty task text → fallback to RALPH_DEFAULT_MODEL"
    else
        # Task-type primary routing
        task_type=$(ralph_classify_task_type "$task_text")
        case "$task_type" in
            docs|tools)
                model="haiku"
                routing_reason="type_haiku"
                _complexity_debug "Task type [$task_type] → haiku"
                ;;
            code)
                model="sonnet"
                routing_reason="type_code"
                _complexity_debug "Task type [code] → sonnet (floor)"
                ;;
            arch)
                model="opus"
                routing_reason="type_arch"
                _complexity_debug "Task type [arch] → opus"
                ;;
            *)
                model="$RALPH_DEFAULT_MODEL"
                routing_reason="type_unknown"
                _complexity_debug "Unknown task type [$task_type] → fallback"
                ;;
        esac
    fi

    # Log routing decision with task type and retry context.
    # Compact (-c) so each decision is one line, matching the JSONL format
    # the observability queries in CLAUDE.md and the TAP-1210 contract expect.
    local routing_log="${RALPH_DIR:-.ralph}/.model_routing.jsonl"
    if command -v jq &>/dev/null; then
        local routing_entry
        routing_entry=$(jq -nc \
            --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            --arg task_type "${task_type:-unknown}" \
            --arg model "$model" \
            --arg retry "$retry_count" \
            --arg reason "$routing_reason" \
            '{timestamp: $ts, task_type: $task_type, model: $model, retry_count: ($retry | tonumber), reason: $reason}')
        echo "$routing_entry" >> "$routing_log" 2>/dev/null
    fi

    echo "$model"
}

# _complexity_debug — Internal debug logging
#
_complexity_debug() {
    if [[ "${RALPH_VERBOSE:-false}" == "true" ]] || [[ "${RALPH_DEBUG:-false}" == "true" ]]; then
        echo "[complexity] $*" >&2
    fi
}

# =============================================================================
# COSTROUTE-3: Prompt Cache Optimization
# =============================================================================

# RALPH_PROMPT_CACHE_ENABLED — Enable prompt structure optimization (default: false)
RALPH_PROMPT_CACHE_ENABLED="${RALPH_PROMPT_CACHE_ENABLED:-false}"

# ralph_build_cacheable_prompt — Structure prompt for maximum cache hits
#
# Reorders prompt sections so stable content comes first (cacheable prefix)
# and dynamic content (loop count, task progress) comes last.
#
# Structure:
#   [STABLE PREFIX — cached across iterations]
#   1. System identity (from PROMPT.md header)
#   2. Build/run instructions (from AGENT.md — rarely changes)
#   3. Tool permissions and constraints
#   4. RALPH_STATUS format specification
#   [DYNAMIC SUFFIX — changes each iteration]
#   5. Current progress (loop N, tasks done X/Y)
#   6. Active task from fix_plan.md
#   7. Previous iteration context (last recommendation)
#
# Usage: prompt=$(ralph_build_cacheable_prompt)
#
ralph_build_cacheable_prompt() {
    [[ "$RALPH_PROMPT_CACHE_ENABLED" != "true" ]] && return 1

    local ralph_dir="${RALPH_DIR:-.ralph}"
    local prompt_file="$ralph_dir/PROMPT.md"
    local agent_file="$ralph_dir/AGENT.md"
    local plan_file="$ralph_dir/fix_plan.md"
    local status_file="$ralph_dir/status.json"

    [[ ! -f "$prompt_file" ]] && return 1

    local output=""

    # === STABLE PREFIX (cacheable) ===
    output+="$(cat "$prompt_file" 2>/dev/null)

"

    if [[ -f "$agent_file" ]]; then
        output+="---
## Build & Run Instructions
$(cat "$agent_file" 2>/dev/null)

"
    fi

    # === CACHE BOUNDARY ===
    output+="---
## Current Iteration Context
"

    # Dynamic: Loop count and progress
    local loop_count=0
    local last_recommendation=""
    if [[ -f "$status_file" ]] && command -v jq &>/dev/null; then
        loop_count=$(jq -r '.loop_count // 0' "$status_file" 2>/dev/null || echo "0")
        last_recommendation=$(jq -r '.recommendation // ""' "$status_file" 2>/dev/null || echo "")
    fi

    output+="Loop iteration: $loop_count
"

    # Dynamic: Task progress
    if [[ -f "$plan_file" ]]; then
        local total done remaining
        total=$(grep -cE '^\s*- \[[xX ]\]' "$plan_file" 2>/dev/null) || total=0
        done=$(grep -cE '^\s*- \[[xX]\]' "$plan_file" 2>/dev/null) || done=0
        remaining=$((total - done))
        output+="Tasks: $done/$total complete, $remaining remaining
"
    fi

    # Dynamic: Last recommendation
    if [[ -n "$last_recommendation" ]]; then
        output+="Previous iteration note: $last_recommendation
"
    fi

    echo "$output"
}

# ralph_get_stable_prefix_hash — Hash the stable prefix for cache key tracking
#
# Returns a short hash of the prompt prefix. If the hash changes between
# iterations, it means the cache was likely invalidated.
#
ralph_get_stable_prefix_hash() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local prompt_file="$ralph_dir/PROMPT.md"
    local agent_file="$ralph_dir/AGENT.md"

    local combined=""
    [[ -f "$prompt_file" ]] && combined+=$(cat "$prompt_file")
    [[ -f "$agent_file" ]] && combined+=$(cat "$agent_file")

    # Use md5sum or shasum (cross-platform)
    if command -v md5sum &>/dev/null; then
        echo "$combined" | md5sum | cut -c1-8
    elif command -v shasum &>/dev/null; then
        echo "$combined" | shasum | cut -c1-8
    else
        echo "${#combined}"  # Fallback: just length
    fi
}
