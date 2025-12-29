# Ralph Architecture

**Last Updated**: December 2025  
**Purpose**: Architectural overview and design patterns for Ralph contributors

---

## System Overview

Ralph is an autonomous AI development loop orchestrator that runs Claude Code iteratively until project completion. It implements intelligent safeguards (circuit breaker, rate limiting, exit detection) to prevent infinite loops and API waste.

**Core Goal**: Complete software projects with minimal human intervention while preventing token waste and runaway execution.

---

## Architecture Diagram

```text
┌─────────────────────────────────────────────────────────────┐
│                     Ralph Main Loop                          │
│                    (ralph_loop.sh)                          │
└──────────┬──────────────────────────────────────────────────┘
           │
           ├──> Circuit Breaker Check (lib/circuit_breaker.sh)
           │    └──> State: CLOSED / HALF_OPEN / OPEN
           │
           ├──> Rate Limit Check (.call_count, .last_reset)
           │    └──> Max calls/hour enforcement
           │
           ├──> Execute Claude Code (PROMPT.md input)
           │    └──> Timeout: configurable (default 15min)
           │
           ├──> Response Analysis (lib/response_analyzer.sh)
           │    ├──> Parse RALPH_STATUS block
           │    ├──> Detect completion keywords
           │    ├──> Calculate confidence score
           │    └──> Set EXIT_SIGNAL
           │
           ├──> Update Exit Signals (.exit_signals)
           │    ├──> test_only_loops array
           │    ├──> done_signals array
           │    └──> completion_indicators array
           │
           ├──> Record Loop Result (circuit_breaker.sh)
           │    ├──> Track files changed
           │    ├──> Track errors
           │    └──> Update circuit state
           │
           └──> Check Exit Conditions
                ├──> should_exit_gracefully()
                └──> should_halt_execution()
```

---

## Core Components

### 1. Main Loop (`ralph_loop.sh`)

**Responsibilities:**

- Orchestrate the autonomous development cycle
- Manage rate limiting and API calls
- Execute Claude Code with timeout protection
- Coordinate between circuit breaker and response analyzer
- Handle graceful exits and error conditions

**Key Functions:**

- `init_call_tracking()` - Initialize rate limiting state
- `execute_claude_code()` - Run Claude Code with timeout
- `can_make_call()` - Check rate limit
- `increment_call_counter()` - Track API usage
- `should_exit_gracefully()` - Detect completion
- `wait_for_reset()` - Countdown to hourly reset

**State Files:**

- `.call_count` - API calls made this hour
- `.last_reset` - Timestamp of last reset
- `status.json` - Current loop status
- `progress.json` - Real-time progress tracking

---

### 2. Response Analyzer (`lib/response_analyzer.sh`)

**Responsibilities:**

- Parse Claude Code output for signals
- Detect project completion
- Calculate confidence scores
- Identify test-only loops
- Track progress via file changes

**Analysis Patterns:**

**Structured Output** (Preferred):

```text
---RALPH_STATUS---
STATUS: COMPLETE | IN_PROGRESS | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: true | false
RECOMMENDATION: <summary>
---END_RALPH_STATUS---
```

**Natural Language Fallback**:

- Completion keywords: "done", "complete", "finished", "all tasks complete"
- Test patterns: "bun test", "bats", "pytest", "jest"
- Stuck indicators: "error", "failed", "cannot", "unable to"
- No-work patterns: "nothing to do", "no changes", "already implemented"

**Key Functions:**

- `analyze_response()` - Main analysis orchestrator
- `update_exit_signals()` - Populate rolling window arrays
- `detect_stuck_loop()` - Identify repeated errors
- `log_analysis_summary()` - Human-readable output

**State Files:**

- `.response_analysis` - Latest analysis results
- `.exit_signals` - Rolling window (last 5) of signals
- `.last_output_length` - Track output trends

---

### 3. Circuit Breaker (`lib/circuit_breaker.sh`)

**Responsibilities:**

- Prevent runaway loops (stagnation detection)
- Track progress across loops
- Manage state transitions (CLOSED → HALF_OPEN → OPEN)
- Provide recovery guidance

**States:**

**CLOSED** (Normal Operation)

- Loops execute normally
- Monitoring for issues

**HALF_OPEN** (Recovery Mode)

- After recent issues detected
- Testing if problem is resolved
- One failure → OPEN, success → CLOSED

**OPEN** (Execution Halted)

- Stagnation detected (no progress for 3+ loops)
- Same error repeated 5+ times
- Output declining >70%
- Requires manual reset or investigation

**Thresholds:**

```bash
CB_NO_PROGRESS_THRESHOLD=3       # Loops with no file changes
CB_SAME_ERROR_THRESHOLD=5        # Same error repeated
CB_OUTPUT_DECLINE_THRESHOLD=70   # Output size decline %
```

**Key Functions:**

- `init_circuit_breaker()` - Initialize state
- `record_loop_result()` - Track loop outcome
- `should_halt_execution()` - Check if OPEN
- `reset_circuit_breaker()` - Manual reset
- `show_circuit_status()` - Display current state

**State Files:**

- `.circuit_breaker_state` - Current state and counters
- `.circuit_breaker_history` - Historical events log

---

### 4. Monitoring (`ralph_monitor.sh`)

**Responsibilities:**

- Real-time dashboard display
- Log aggregation and formatting
- Status tracking
- API usage visualization

**Display Sections:**

1. Header with loop count and status
2. API usage bar (calls/hour)
3. Recent log entries (last 20)
4. Current file being processed
5. Exit condition indicators

**Update Frequency**: 2 seconds

---

## Design Patterns

### 1. Circuit Breaker Pattern

**Intent**: Prevent cascading failures and resource waste

**Implementation**:

- Monitor loop outcomes (files changed, errors, output size)
- Open circuit when thresholds exceeded
- Half-open state for recovery testing
- Fail-fast to avoid token waste

**Benefits**:

- Prevents infinite loops
- Saves API tokens
- Provides actionable feedback
- Graceful degradation

---

### 2. Rolling Window Analysis

**Intent**: Detect trends over recent loops

**Implementation**:

- Keep last 5 signals in arrays
- Analyze patterns (test-only, done signals, completion)
- Trigger exits based on trends, not single events

**Benefits**:

- Robust to noise
- Catches sustained patterns
- Prevents premature exits

---

### 3. Semantic Response Analysis

**Intent**: Understand Claude Code output without strict schemas

**Implementation**:

- Prefer structured RALPH_STATUS blocks
- Fall back to keyword detection
- Calculate confidence scores
- Combine multiple signal types

**Benefits**:

- Works with current Claude Code
- Robust to output variations
- Progressive enhancement (structured → keywords)

---

### 4. State-Based Rate Limiting

**Intent**: Respect API limits across script restarts

**Implementation**:

- Persist call count to `.call_count` file
- Track hourly reset via `.last_reset` timestamp
- Automatic reset on hour boundary
- Countdown display during waits

**Benefits**:

- Survives script restarts
- Clear user feedback
- Prevents accidental overuse

---

## Data Flow

### Successful Loop

```text
1. Ralph reads PROMPT.md
2. Circuit breaker check → CLOSED (continue)
3. Rate limit check → OK (48/100 calls)
4. Execute Claude Code (timeout: 15min)
5. Claude modifies 3 files, runs tests, outputs status
6. Response analyzer:
   - Finds RALPH_STATUS block
   - STATUS: IN_PROGRESS
   - FILES_MODIFIED: 3
   - Confidence: 20 (work continues)
   - EXIT_SIGNAL: false
7. Update exit signals (no exit condition)
8. Circuit breaker records: 3 files changed (CLOSED)
9. Increment call count: 49/100
10. Continue to next loop
```

### Completion Detection

```text
1. Loop executes successfully
2. Response analyzer finds:
   - RALPH_STATUS: COMPLETE
   - EXIT_SIGNAL: true
   OR
   - Keyword "all tasks complete"
   - Keyword "project ready"
   - Confidence: 100
3. Update exit signals: done_signals array
4. Next loop checks should_exit_gracefully()
5. Found: 2 consecutive done signals
6. Ralph exits with summary
7. Status: "completed"
```

### Circuit Breaker Opens

```text
1. Loop 1: 0 files changed
2. Loop 2: 0 files changed
3. Loop 3: 0 files changed
4. Circuit breaker detects: 3 loops with no progress
5. Circuit state → OPEN
6. Next loop: should_halt_execution() returns true
7. Ralph displays guidance:
   - Check PROMPT.md for clarity
   - Review @fix_plan.md for actionable tasks
   - Check logs for errors
8. Ralph exits with code 1
9. User runs: ralph --reset-circuit (after fixes)
```

---

## Extension Points

### Adding New Exit Conditions

**Location**: `ralph_loop.sh::should_exit_gracefully()`

**Steps**:

1. Add detection logic
2. Return exit reason string
3. Update STATUS.md documentation
4. Add tests in `tests/unit/test_exit_detection.bats`

**Example**:

```bash
# Check for custom marker file
if [[ -f ".ralph-complete" ]]; then
    echo "custom_marker"
    return 0
fi
```

---

### Adding Response Analysis Patterns

**Location**: `lib/response_analyzer.sh::analyze_response()`

**Steps**:

1. Define keyword array
2. Add grep pattern check
3. Adjust confidence score
4. Update tests

**Example**:

```bash
# Detect deployment-ready signals
DEPLOY_KEYWORDS=("deployed" "production ready" "release candidate")
for keyword in "${DEPLOY_KEYWORDS[@]}"; do
    if grep -qi "$keyword" "$output_file"; then
        ((confidence_score += 25))
        is_deployment_ready=true
        break
    fi
done
```

---

## Testing Strategy

### Unit Tests

- Individual function behavior
- State file manipulation
- Threshold calculations
- Edge cases (missing files, corrupted JSON)

### Integration Tests

- Multi-loop scenarios
- Circuit breaker state transitions
- Exit condition detection
- Rate limit enforcement

### End-to-End Tests

- Complete project workflows
- Real Claude Code execution (mocked)
- Full state persistence
- Error recovery paths

**Test Files**:

- `tests/unit/test_rate_limiting.bats` (35 tests)
- `tests/unit/test_exit_detection.bats` (20 tests)
- `tests/integration/test_loop_execution.bats` (25 tests)
- `tests/integration/test_edge_cases.bats` (15 tests)

---

## Performance Considerations

**Loop Execution Time**:

- Typical: 2-5 minutes per loop
- Max (with timeout): 15 minutes per loop
- Circuit breaker opens after 3 stagnant loops (~15-45 min)

**Memory Usage**:

- Bash scripts: <10MB
- Log files: grows over time (implement rotation)
- State files: <1KB each

**API Usage**:

- Default limit: 100 calls/hour
- Configurable via `--calls` flag
- Typical project: 20-50 calls to completion

---

## Security Considerations

**No Credentials in Git**:

- `.call_count`, `.last_reset` ignored
- `status.json` ignored
- Logs ignored (may contain code)

**Command Injection Protection**:

- All file paths validated
- No `eval` usage
- Proper quoting in bash

**API Key Management**:

- Claude Code CLI handles auth
- Ralph doesn't touch credentials
- Respects Claude's security model

---

## Future Architecture

**v1.1+ Enhancements**:

- Plugin system for custom analyzers
- Multiple Claude instances in parallel
- Distributed loop execution
- Centralized monitoring dashboard
- Event-driven architecture (webhooks)

---

**For implementation details, see [CONTRIBUTING.md](../CONTRIBUTING.md)**
