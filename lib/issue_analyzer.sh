#!/usr/bin/env bash

# issue_analyzer.sh - GitHub issue completeness assessment (Issue #70)
#
# Scores a formatted issue PRD (markdown from format_issue_as_prd in
# ralph_import.sh) for implementation readiness. Scoring is deterministic —
# pure bash/grep heuristics, no Claude call — so results are reproducible
# and unit-testable. The caller uses the score to decide whether to generate
# an implementation plan before converting the issue to Ralph format.

# Default threshold below which plan generation is recommended
ISSUE_COMPLETENESS_THRESHOLD_DEFAULT=60

# assess_issue_completeness - Score an issue PRD for implementation detail
#
# Heuristic indicators (sum = 100):
#   +25  Acceptance criteria section (the strongest readiness signal)
#   +15  Task checklist items (- [ ] ...)
#   +15  Code blocks or API signatures (fenced ```)
#   +15  Technical structure (>= 3 "##" sections)
#   +15  Implementation guidance keywords (implement/architecture/steps/...)
#   +15  Sufficient detail (>= 150 words)
#
# Parameters:
#   $1 (prd_file)    - Markdown PRD file to assess
#   $2 (output_file) - Destination for the JSON analysis result
#   $3 (threshold)   - Optional score threshold for the recommendation
#                      (0-100, default: 60)
#
# Output JSON shape:
#   {
#     "confidence_score": 0-100,
#     "completeness_level": "high" | "medium" | "low",
#     "missing_elements": ["acceptance_criteria", ...],
#     "recommendation": "convert" | "generate_plan"
#   }
#
# Returns:
#   0 on success (analysis written), 1 on missing input or invalid threshold
#
assess_issue_completeness() {
    local prd_file=$1
    local output_file=$2
    local threshold="${3:-$ISSUE_COMPLETENESS_THRESHOLD_DEFAULT}"

    if [[ ! -f "$prd_file" ]]; then
        echo "ERROR: Issue PRD file not found: $prd_file" >&2
        return 1
    fi

    if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [[ "$threshold" -gt 100 ]]; then
        echo "ERROR: Completeness threshold must be a number 0-100, got: $threshold" >&2
        return 1
    fi

    local score=0
    local missing=()

    # Acceptance criteria section (+25)
    if grep -qiE '^#{1,6}[[:space:]]+acceptance criteria|^\*\*acceptance criteria' "$prd_file"; then
        score=$((score + 25))
    else
        missing+=("acceptance_criteria")
    fi

    # Task checklist items (+15)
    if grep -qE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' "$prd_file"; then
        score=$((score + 15))
    else
        missing+=("task_checklist")
    fi

    # Code blocks / API signatures (+15)
    if grep -qE '^[[:space:]]*```' "$prd_file"; then
        score=$((score + 15))
    else
        missing+=("code_examples")
    fi

    # Technical structure: >= 3 "##" sections (+15)
    local section_count
    section_count=$(grep -cE '^##[[:space:]]' "$prd_file" 2>/dev/null) || section_count=0
    if [[ "$section_count" -ge 3 ]]; then
        score=$((score + 15))
    else
        missing+=("technical_sections")
    fi

    # Implementation guidance keywords (+15)
    if grep -qiE '\b(implement|implementation|architecture|approach|steps?|technical|design|api|schema|endpoint|function)\b' "$prd_file"; then
        score=$((score + 15))
    else
        missing+=("implementation_guidance")
    fi

    # Sufficient detail: >= 150 words (+15)
    local word_count
    word_count=$(wc -w < "$prd_file" | tr -d '[:space:]')
    if [[ "$word_count" -ge 150 ]]; then
        score=$((score + 15))
    else
        missing+=("sufficient_detail")
    fi

    # Completeness level from score bands
    local level="low"
    if [[ "$score" -ge 80 ]]; then
        level="high"
    elif [[ "$score" -ge 40 ]]; then
        level="medium"
    fi

    local recommendation="generate_plan"
    if [[ "$score" -ge "$threshold" ]]; then
        recommendation="convert"
    fi

    # Build the missing_elements JSON array (entries are fixed identifiers,
    # no escaping needed)
    local missing_json="[]"
    if [[ ${#missing[@]} -gt 0 ]]; then
        local joined=""
        local element
        for element in "${missing[@]}"; do
            joined="${joined:+$joined, }\"$element\""
        done
        missing_json="[$joined]"
    fi

    cat > "$output_file" << EOF
{
    "confidence_score": $score,
    "completeness_level": "$level",
    "missing_elements": $missing_json,
    "recommendation": "$recommendation"
}
EOF
}

# log_issue_analysis - Print a human-readable summary of an analysis result
#
# Parameters:
#   $1 (analysis_file) - JSON file written by assess_issue_completeness
#
# Returns:
#   0 on success, 1 if the analysis file is missing or jq is unavailable
#
log_issue_analysis() {
    local analysis_file=$1

    if [[ ! -f "$analysis_file" ]]; then
        echo "ERROR: Analysis file not found: $analysis_file" >&2
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required to read the analysis result" >&2
        return 1
    fi

    local score level recommendation missing
    score=$(jq -r '.confidence_score' "$analysis_file")
    level=$(jq -r '.completeness_level' "$analysis_file")
    recommendation=$(jq -r '.recommendation' "$analysis_file")
    missing=$(jq -r '.missing_elements | join(", ")' "$analysis_file")

    echo "Issue Completeness Analysis"
    echo "  Score:          ${score}/100 (${level})"
    echo "  Recommendation: ${recommendation}"
    if [[ -n "$missing" ]]; then
        echo "  Missing:        ${missing}"
    fi
}
