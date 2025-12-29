#!/bin/bash
# shellcheck disable=SC2155  # Declare and assign separately (intentional style choice)

# Response Analyzer Component for Ralph
# Analyzes Claude Code output to detect completion signals, test-only loops, and progress

# Response Analysis Functions
# Based on expert recommendations from Martin Fowler, Michael Nygard, Sam Newman

# Colors for output
BLUE='\033[0;34m'
NC='\033[0m'

# Analysis configuration (arrays defined for documentation/future use)
# shellcheck disable=SC2034
COMPLETION_KEYWORDS=("done" "complete" "finished" "all tasks complete" "project complete" "ready for review")
# shellcheck disable=SC2034
TEST_ONLY_PATTERNS=("bun test" "bats" "pytest" "jest" "cargo test" "go test" "running tests")
# shellcheck disable=SC2034
STUCK_INDICATORS=("error" "failed" "cannot" "unable to" "blocked")
NO_WORK_PATTERNS=("nothing to do" "no changes" "already implemented" "up to date")

# Analyze Claude Code response and extract signals
analyze_response() {
	local output_file=$1
	local loop_number=$2
	local analysis_result_file=${3:-".response_analysis"}

	# Initialize analysis result
	local has_completion_signal=false
	local is_test_only=false
	local is_stuck=false
	local has_progress=false
	local confidence_score=0
	local exit_signal=false
	local work_summary=""
	local files_modified=0

	# Read output file
	if [[ ! -f $output_file ]]; then
		echo "ERROR: Output file not found: $output_file"
		return 1
	fi

	local output_content=$(cat "$output_file")
	local output_length=${#output_content}

	# 1. Check for explicit structured output (if Claude follows schema)
	if grep -q -- "---RALPH_STATUS---" "$output_file"; then
		# Parse structured output
		local status=$(grep "STATUS:" "$output_file" | cut -d: -f2 | xargs)
		local exit_sig=$(grep "EXIT_SIGNAL:" "$output_file" | cut -d: -f2 | xargs)

		if [[ $exit_sig == "true" || $status == "COMPLETE" ]]; then
			has_completion_signal=true
			exit_signal=true
			confidence_score=100
		fi
	fi

	# 2. Detect completion keywords in natural language output
	for keyword in "${COMPLETION_KEYWORDS[@]}"; do
		if grep -qi "$keyword" "$output_file"; then
			has_completion_signal=true
			((confidence_score += 10))
			break
		fi
	done

	# 3. Detect test-only loops
	local test_command_count=0
	local implementation_count=0
	local error_count=0

	test_command_count=$(grep -c -i "running tests\|bun test\|bats\|pytest\|jest" "$output_file" 2>/dev/null | head -1 || echo "0")
	implementation_count=$(grep -c -i "implementing\|creating\|writing\|adding\|function\|class" "$output_file" 2>/dev/null | head -1 || echo "0")

	# Strip whitespace and ensure it's a number
	test_command_count=$(echo "$test_command_count" | tr -d '[:space:]')
	implementation_count=$(echo "$implementation_count" | tr -d '[:space:]')

	# Convert to integers with default fallback
	test_command_count=${test_command_count:-0}
	implementation_count=${implementation_count:-0}
	test_command_count=$((test_command_count + 0))
	implementation_count=$((implementation_count + 0))

	if [[ $test_command_count -gt 0 ]] && [[ $implementation_count -eq 0 ]]; then
		is_test_only=true
		work_summary="Test execution only, no implementation"
	fi

	# 4. Detect stuck/error loops
	error_count=$(grep -c -i "error\|failed\|cannot\|unable" "$output_file" 2>/dev/null | head -1 || echo "0")
	error_count=$(echo "$error_count" | tr -d '[:space:]')
	error_count=${error_count:-0}
	error_count=$((error_count + 0))

	if [[ $error_count -gt 5 ]]; then
		is_stuck=true
	fi

	# 5. Detect "nothing to do" patterns
	for pattern in "${NO_WORK_PATTERNS[@]}"; do
		if grep -qi "$pattern" "$output_file"; then
			has_completion_signal=true
			((confidence_score += 15))
			work_summary="No work remaining"
			break
		fi
	done

	# 6. Check for file changes (git integration)
	if command -v git &>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
		files_modified=$(git diff --name-only 2>/dev/null | wc -l)
		if [[ $files_modified -gt 0 ]]; then
			has_progress=true
			((confidence_score += 20))
		fi
	fi

	# 7. Analyze output length trends (detect declining engagement)
	if [[ -f ".last_output_length" ]]; then
		local last_length=$(cat ".last_output_length")
		local length_ratio=$((output_length * 100 / last_length))

		if [[ $length_ratio -lt 50 ]]; then
			# Output is less than 50% of previous - possible completion
			((confidence_score += 10))
		fi
	fi
	echo "$output_length" >".last_output_length"

	# 8. Extract work summary from output
	if [[ -z $work_summary ]]; then
		# Try to find summary in output
		work_summary=$(grep -i "summary\|completed\|implemented" "$output_file" | head -1 | cut -c 1-100)
		if [[ -z $work_summary ]]; then
			work_summary="Output analyzed, no explicit summary found"
		fi
	fi

	# 9. Determine exit signal based on confidence
	if [[ $confidence_score -ge 40 || $has_completion_signal == "true" ]]; then
		exit_signal=true
	fi

	# Write analysis results to file
	cat >"$analysis_result_file" <<EOF
{
    "loop_number": $loop_number,
    "timestamp": "$(date -Iseconds)",
    "output_file": "$output_file",
    "analysis": {
        "has_completion_signal": $has_completion_signal,
        "is_test_only": $is_test_only,
        "is_stuck": $is_stuck,
        "has_progress": $has_progress,
        "files_modified": $files_modified,
        "confidence_score": $confidence_score,
        "exit_signal": $exit_signal,
        "work_summary": "$work_summary",
        "output_length": $output_length
    }
}
EOF

	# Always return 0 (success) - callers should check the JSON result file
	# Returning non-zero would cause issues with set -e and test frameworks
	return 0
}

# Update exit signals file based on analysis
update_exit_signals() {
	local analysis_file=${1:-".response_analysis"}
	local exit_signals_file=${2:-".exit_signals"}

	if [[ ! -f $analysis_file ]]; then
		echo "ERROR: Analysis file not found: $analysis_file"
		return 1
	fi

	# Read analysis results
	local is_test_only=$(jq -r '.analysis.is_test_only' "$analysis_file")
	local has_completion_signal=$(jq -r '.analysis.has_completion_signal' "$analysis_file")
	local loop_number=$(jq -r '.loop_number' "$analysis_file")
	local has_progress=$(jq -r '.analysis.has_progress' "$analysis_file")

	# Read current exit signals
	local signals=$(cat "$exit_signals_file" 2>/dev/null || echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}')

	# Update test_only_loops array
	if [[ $is_test_only == "true" ]]; then
		signals=$(echo "$signals" | jq ".test_only_loops += [$loop_number]")
	else
		# Clear test_only_loops if we had implementation
		if [[ $has_progress == "true" ]]; then
			signals=$(echo "$signals" | jq '.test_only_loops = []')
		fi
	fi

	# Update done_signals array
	if [[ $has_completion_signal == "true" ]]; then
		signals=$(echo "$signals" | jq ".done_signals += [$loop_number]")
	fi

	# Update completion_indicators array (strong signals)
	local confidence=$(jq -r '.analysis.confidence_score' "$analysis_file")
	if [[ $confidence -ge 60 ]]; then
		signals=$(echo "$signals" | jq ".completion_indicators += [$loop_number]")
	fi

	# Keep only last 5 signals (rolling window)
	signals=$(echo "$signals" | jq '.test_only_loops = .test_only_loops[-5:]')
	signals=$(echo "$signals" | jq '.done_signals = .done_signals[-5:]')
	signals=$(echo "$signals" | jq '.completion_indicators = .completion_indicators[-5:]')

	# Write updated signals
	echo "$signals" >"$exit_signals_file"

	return 0
}

# Log analysis results in human-readable format
log_analysis_summary() {
	local analysis_file=${1:-".response_analysis"}

	if [[ ! -f $analysis_file ]]; then
		return 1
	fi

	local loop=$(jq -r '.loop_number' "$analysis_file")
	local exit_sig=$(jq -r '.analysis.exit_signal' "$analysis_file")
	local confidence=$(jq -r '.analysis.confidence_score' "$analysis_file")
	local test_only=$(jq -r '.analysis.is_test_only' "$analysis_file")
	local files_changed=$(jq -r '.analysis.files_modified' "$analysis_file")
	local summary=$(jq -r '.analysis.work_summary' "$analysis_file")

	echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${BLUE}║           Response Analysis - Loop #$loop                 ║${NC}"
	echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
	echo -e "${YELLOW}Exit Signal:${NC}      $exit_sig"
	echo -e "${YELLOW}Confidence:${NC}       $confidence%"
	echo -e "${YELLOW}Test Only:${NC}        $test_only"
	echo -e "${YELLOW}Files Changed:${NC}    $files_changed"
	echo -e "${YELLOW}Summary:${NC}          $summary"
	echo ""
}

# Detect if Claude is stuck (repeating same errors)
detect_stuck_loop() {
	local current_output=$1
	local history_dir=${2:-"logs"}

	# Get last 3 output files
	# shellcheck disable=SC2012  # ls -t is acceptable here for simple time-sorted listing
	local recent_outputs=$(ls -t "$history_dir"/claude_output_*.log 2>/dev/null | head -3)

	if [[ -z $recent_outputs ]]; then
		return 1 # Not enough history
	fi

	# Extract key errors from current output
	local current_errors=$(grep -i "error\|failed" "$current_output" 2>/dev/null | sort | uniq)

	if [[ -z $current_errors ]]; then
		return 1 # No errors
	fi

	# Check if same errors appear in all recent outputs
	local stuck_count=0
	while IFS= read -r output_file; do
		if grep -q "$current_errors" "$output_file" 2>/dev/null; then
			((stuck_count++))
		fi
	done <<<"$recent_outputs"

	if [[ $stuck_count -ge 3 ]]; then
		return 0 # Stuck on same error
	else
		return 1 # Making progress or different errors
	fi
}

# Export functions for use in ralph_loop.sh
export -f analyze_response
export -f update_exit_signals
export -f log_analysis_summary
export -f detect_stuck_loop
