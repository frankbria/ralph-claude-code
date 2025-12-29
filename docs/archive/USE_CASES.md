# Ralph Use Cases

**Author**: Based on Alistair Cockburn's use case methodology
**Date**: 2025-10-01
**Purpose**: Define actors, goals, and scenarios for Ralph autonomous development system

---

## System Overview

**System Name**: Ralph - Autonomous AI Development Loop
**System Goal**: Complete software project implementation with minimal human intervention and token waste
**Primary Actor**: Ralph (bash script orchestrating Claude Code)
**Supporting Actors**: Claude Code (AI development engine), Human Developer (initiator and reviewer)

---

## Actor Catalog

### Primary Actor: Ralph (Autonomous Agent)

**Type**: System
**Goal**: Execute development loops until project completion or circuit breaker opens
**Capabilities**:

- Execute Claude Code with PROMPT.md instructions
- Analyze Claude Code responses for completion signals
- Track file changes and progress
- Manage rate limits (100 calls/hour)
- Detect stagnation via circuit breaker
- Gracefully exit when work is complete

**Constraints**:

- Cannot modify project requirements
- Must respect API rate limits
- Cannot override circuit breaker when open
- Requires valid PROMPT.md and @fix_plan.md

---

### Supporting Actor: Claude Code

**Type**: AI System
**Goal**: Implement features, fix bugs, run tests per PROMPT.md instructions
**Capabilities**:

- Read/write/edit files
- Execute bash commands
- Run tests and analyze results
- Search codebase
- Output structured status reports

**Constraints**:

- 5-hour daily API limit
- Token context limits
- Cannot access external network (except via approved tools)
- Must follow PROMPT.md instructions

---

### Supporting Actor: Human Developer

**Type**: Human
**Goal**: Initiate Ralph, review results, intervene when needed
**Capabilities**:

- Create PROMPT.md and @fix_plan.md
- Start/stop Ralph execution
- Reset circuit breaker
- Review code changes
- Provide clarifications when blocked

**Constraints**:

- Not present during autonomous loop execution
- Cannot modify files while Ralph is running
- Must review changes before merging

---

## Use Case Hierarchy

### System Goal: Complete Project Implementation

**Sub-Goals**:

1. Execute development loops (UC-1)
2. Detect completion conditions (UC-2)
3. Prevent resource waste (UC-3)
4. Handle error conditions (UC-4)
5. Provide observability (UC-5)

---

## UC-1: Execute Development Loop

**Primary Actor**: Ralph
**Stakeholders**: Human Developer (wants progress), Claude Code (executor)
**Preconditions**:

- PROMPT.md exists and is valid
- @fix_plan.md exists with at least one task
- Claude Code CLI is installed and accessible
- git repository is initialized

**Success Guarantee** (Postcondition):

- One development task completed
- Files modified and committed (if changes made)
- Status tracked in logs and status.json
- Circuit breaker state updated
- Exit signals analyzed and recorded

**Main Success Scenario**:

1. Ralph reads PROMPT.md
2. Ralph checks circuit breaker state (must be CLOSED or HALF_OPEN)
3. Ralph verifies rate limit allows execution
4. Ralph executes Claude Code with PROMPT.md
5. Claude Code reads @fix_plan.md and selects task
6. Claude Code implements task (files modified)
7. Claude Code runs relevant tests
8. Claude Code outputs RALPH_STATUS block
9. Ralph analyzes Claude's response (analyze_response)
10. Ralph updates .exit_signals file (update_exit_signals)
11. Ralph records loop result in circuit breaker (record_loop_result)
12. Ralph increments call counter
13. Ralph logs completion to status.json and logs/
14. Ralph continues to next loop (if no exit condition)

**Extensions** (Alternative Flows):

**2a. Circuit breaker is OPEN**:

- 2a1. Ralph displays circuit breaker status
- 2a2. Ralph shows user guidance (check logs, reset, etc.)
- 2a3. Ralph exits with exit code 1
- USE CASE ENDS

**3a. Rate limit exceeded**:

- 3a1. Ralph calculates time until next hour reset
- 3a2. Ralph displays countdown timer
- 3a3. Ralph waits for reset
- 3a4. Ralph continues at step 4

**3b. API 5-hour limit reached**:

- 3b1. Ralph detects "rate limit" error in Claude output
- 3b2. Ralph prompts user: retry or exit?
- 3b3a. User chooses retry: wait 5 minutes, go to step 4
- 3b3b. User chooses exit: Ralph exits gracefully
- USE CASE ENDS

**4a. Claude Code execution fails**:

- 4a1. Ralph logs error to logs/ralph_error.log
- 4a2. Ralph updates status.json with "failed" status
- 4a3. Ralph continues to next loop (retry)
- 4a4. If 5 consecutive failures: circuit breaker opens
- Continue at step 2

**9a. Response analysis detects EXIT_SIGNAL=true**:

- 9a1. Ralph logs successful completion
- 9a2. Ralph updates status.json with "complete" status
- 9a3. Ralph displays completion summary
- 9a4. Ralph exits with exit code 0
- USE CASE ENDS

**11a. Circuit breaker opens (no progress detected)**:

- 11a1. Ralph logs circuit breaker opening
- 11a2. Ralph updates status.json with "circuit_open" status
- 11a3. Ralph displays guidance to user
- 11a4. Ralph exits with exit code 1
- USE CASE ENDS

**Frequency**: Occurs in loop until completion or exit condition
**Performance**: Each loop should complete in < 5 minutes under normal conditions

---

## UC-2: Detect Project Completion

**Primary Actor**: Ralph (via response_analyzer.sh)
**Stakeholders**: Human Developer (wants reliable exit), Claude Code (signals completion)
**Preconditions**:

- Development loop has executed (UC-1)
- Claude Code has produced output

**Success Guarantee**:

- Completion status accurately determined
- .exit_signals file updated with decision
- Confidence score calculated (0-100+)
- EXIT_SIGNAL set correctly (true/false)

**Main Success Scenario**:

1. Ralph reads Claude Code output file
2. Ralph checks for structured RALPH_STATUS block
3. Ralph finds STATUS: COMPLETE and EXIT_SIGNAL: true
4. Ralph sets confidence score to 100
5. Ralph sets exit_signal to true in .response_analysis
6. Ralph updates .exit_signals with done_signals array
7. Ralph triggers graceful exit in next loop check

**Extensions**:

**2a. No structured output found**:

- 2a1. Ralph searches for natural language completion keywords
- 2a2. If found: add +10 to confidence score
- 2a3. Ralph checks for "nothing to do" patterns
- 2a4. If found: add +15 to confidence score, set exit_signal=true
- Continue at step 6

**3a. STATUS shows IN_PROGRESS**:

- 3a1. Ralph checks WORK_TYPE field
- 3a2. If WORK_TYPE=TESTING for 3rd consecutive loop: mark as test_only
- 3a3. If FILES_MODIFIED=0 for 3rd consecutive loop: circuit breaker opens
- 3a4. Set exit_signal to false
- Continue at step 6

**3b. STATUS shows BLOCKED**:

- 3b1. Ralph increments blocked_loops counter
- 3b2. If blocked_loops >= 3: recommend human intervention
- 3b3. Set exit_signal to false
- Continue at step 6

**6a. Confidence score >= 40**:

- 6a1. Even without explicit EXIT_SIGNAL, set exit_signal=true
- 6a2. Log high confidence completion detection
- Continue at step 7

**Frequency**: After every development loop
**Performance**: Analysis should complete in < 1 second

---

## UC-3: Prevent Resource Waste (Circuit Breaker)

**Primary Actor**: Ralph (via circuit_breaker.sh)
**Stakeholders**: Human Developer (wants to avoid token waste)
**Preconditions**:

- Development loops are executing
- Circuit breaker is initialized

**Success Guarantee**:

- Runaway loops detected and halted
- Token waste minimized (< 1K wasted tokens)
- Clear user guidance provided on halt
- Circuit breaker state persisted across restarts

**Main Success Scenario**:

1. Ralph initializes circuit breaker to CLOSED state
2. After each loop, Ralph calls record_loop_result()
3. Ralph counts files_changed from git diff
4. Ralph detects has_errors from Claude output
5. Ralph calculates output_length
6. Circuit breaker updates consecutive_no_progress counter
7. consecutive_no_progress is 0 (progress detected)
8. Circuit breaker stays CLOSED
9. Ralph continues to next loop

**Extensions**:

**6a. No files changed (consecutive_no_progress increments)**:

- 6a1. consecutive_no_progress = 1
- 6a2. Circuit breaker stays CLOSED
- Continue at step 9

**6b. No files changed for 2nd consecutive loop**:

- 6b1. consecutive_no_progress = 2
- 6b2. Circuit breaker transitions to HALF_OPEN
- 6b3. Ralph logs "monitoring mode" warning
- Continue at step 9

**6c. No files changed for 3rd consecutive loop**:

- 6c1. consecutive_no_progress = 3
- 6c2. Circuit breaker transitions to OPEN
- 6c3. Ralph displays halt message with guidance
- 6c4. Ralph exits with exit code 1
- USE CASE ENDS

**6d. Same error detected for 5th consecutive loop**:

- 6d1. consecutive_same_error = 5
- 6d2. Circuit breaker transitions to OPEN
- 6d3. Reason: "Same error repeated in 5 consecutive loops"
- Continue at step 6c3

**7a. Files changed detected (recovery)**:

- 7a1. consecutive_no_progress resets to 0
- 7a2. If circuit was HALF_OPEN: transition to CLOSED
- 7a3. Ralph logs "circuit recovered"
- Continue at step 9

**Frequency**: After every development loop
**Performance**: Circuit breaker check < 100ms

---

## UC-4: Handle API Rate Limits

**Primary Actor**: Ralph
**Stakeholders**: Human Developer (wants uninterrupted execution)
**Preconditions**:

- Ralph is executing development loops
- Call tracking is initialized

**Success Guarantee**:

- API rate limits respected
- Call counter accurately tracked
- Hourly reset handled automatically
- User informed of wait times

**Main Success Scenario**:

1. Ralph checks current hour (YYYYMMDDHH format)
2. Ralph reads .last_reset timestamp
3. Current hour matches last_reset (same hour)
4. Ralph reads .call_count
5. call_count is 45 (< 100 limit)
6. Ralph allows execution
7. Ralph increments call_count to 46
8. Ralph writes updated count to .call_count
9. Execution proceeds

**Extensions**:

**3a. New hour detected (hour changed)**:

- 3a1. Ralph resets call_count to 0
- 3a2. Ralph writes current hour to .last_reset
- 3a3. Ralph logs "call counter reset for new hour"
- Continue at step 5

**5a. call_count equals or exceeds limit (100)**:

- 5a1. Ralph calculates seconds until next hour
- 5a2. Ralph displays countdown: "Rate limit reached. Waiting HH:MM:SS..."
- 5a3. Ralph sleeps for calculated duration
- 5a4. Ralph resets counter (go to step 3a1)
- Continue at step 6

**5b. Claude returns API rate limit error**:

- 5b1. Ralph detects "rate_limit_error" in output
- 5b2. Ralph prompts: "API 5-hour limit reached. Retry? (y/n)"
- 5b3a. User enters 'y': Ralph waits 5 minutes, retries
- 5b3b. User enters 'n': Ralph exits gracefully
- USE CASE ENDS

**Frequency**: Before every Claude Code execution
**Performance**: Rate limit check < 50ms

---

## UC-5: Provide Loop Monitoring

**Primary Actor**: ralph-monitor.sh
**Stakeholders**: Human Developer (wants real-time visibility)
**Preconditions**:

- Ralph is running (ralph_loop.sh)
- ralph-monitor started in separate terminal

**Success Guarantee**:

- Real-time status displayed and updated
- Loop count, rate limits, and progress visible
- Circuit breaker state shown
- Exit signals tracked

**Main Success Scenario**:

1. User starts ralph-monitor.sh in separate terminal
2. Monitor reads status.json every 2 seconds
3. Monitor displays loop count, status, timestamp
4. Monitor reads .call_count and shows "Calls: 45/100"
5. Monitor reads .circuit_breaker_state and shows state
6. Monitor reads .exit_signals and shows signal counts
7. Monitor detects status.json update
8. Monitor refreshes display with new data
9. Loop continues (go to step 2)

**Extensions**:

**3a. status.json doesn't exist yet**:

- 3a1. Monitor displays "Waiting for Ralph to start..."
- 3a2. Monitor sleeps 2 seconds
- Continue at step 2

**5a. Circuit breaker is OPEN**:

- 5a1. Monitor displays status in RED
- 5a2. Monitor shows reason for circuit opening
- 5a3. Monitor displays "Execution halted" message
- Continue at step 7

**7a. Ralph has exited**:

- 7a1. Monitor detects final status
- 7a2. Monitor displays completion summary
- 7a3. Monitor shows total loops, duration, exit reason
- 7a4. Monitor exits
- USE CASE ENDS

**Frequency**: Continuous until Ralph exits
**Performance**: Update latency < 2 seconds

---

## UC-6: Reset Circuit Breaker (Manual Intervention)

**Primary Actor**: Human Developer
**Stakeholders**: Ralph (needs manual reset to continue)
**Preconditions**:

- Circuit breaker is OPEN
- Ralph has halted execution
- User has reviewed logs and identified issue

**Success Guarantee**:

- Circuit breaker reset to CLOSED state
- Counters reset to 0
- Ralph can resume execution
- Reset reason logged

**Main Success Scenario**:

1. User identifies circuit breaker opened (from ralph-monitor or logs)
2. User reviews logs/ralph.log to understand cause
3. User fixes underlying issue (updates @fix_plan.md, fixes error, etc.)
4. User runs: `ralph --reset-circuit`
5. Ralph loads circuit_breaker.sh functions
6. Ralph calls reset_circuit_breaker("Manual reset by user")
7. Ralph sets state to CLOSED in .circuit_breaker_state
8. Ralph resets all counters to 0
9. Ralph logs "Circuit breaker reset to CLOSED state"
10. Ralph displays success message
11. User can now restart Ralph execution

**Extensions**:

**2a. User cannot determine cause from logs**:

- 2a1. User runs: `ralph --status` for additional info
- 2a2. User checks .circuit_breaker_history for state transitions
- 2a3. User reviews recent Claude output files
- Continue at step 3

**3a. Issue is in PROMPT.md or specs/**:

- 3a1. User edits PROMPT.md to clarify requirements
- 3a2. User updates specs/ with missing information
- 3a3. User commits changes
- Continue at step 4

**3b. Issue is configuration or environment**:

- 3b1. User installs missing dependencies
- 3b2. User fixes environment variables
- 3b3. User verifies configuration
- Continue at step 4

**Frequency**: As needed when circuit breaker opens
**Performance**: Reset is instantaneous

---

## Goal Hierarchy

```
SYSTEM GOAL: Complete project implementation with minimal token waste
├─ SUB-GOAL 1: Execute development loops (UC-1)
│  ├─ Success: Files changed, tests pass, tasks completed
│  └─ Failure: No files changed, tests fail, no progress
│
├─ SUB-GOAL 2: Detect when no more progress is possible (UC-2)
│  ├─ Success: Exit gracefully with completion summary
│  └─ Failure: Continue looping when work is done
│
├─ SUB-GOAL 3: Prevent resource waste (UC-3)
│  ├─ Success: Halt execution when stagnant
│  └─ Failure: Burn tokens in infinite loops
│
├─ SUB-GOAL 4: Respect API limits (UC-4)
│  ├─ Success: Wait for reset, continue seamlessly
│  └─ Failure: Exceed limits, API errors
│
└─ SUB-GOAL 5: Provide visibility (UC-5)
   ├─ Success: User has real-time status
   └─ Failure: Black box, no feedback
```

---

## Success Metrics

| Use Case | Success Criteria              | Target         |
| -------- | ----------------------------- | -------------- |
| UC-1     | Loop completion rate          | > 95%          |
| UC-1     | Average loop duration         | < 5 minutes    |
| UC-2     | Completion detection accuracy | > 90%          |
| UC-2     | False positive rate           | < 5%           |
| UC-3     | Circuit breaker trip time     | < 3 loops      |
| UC-3     | Token waste on stagnation     | < 1,000 tokens |
| UC-4     | Rate limit compliance         | 100%           |
| UC-4     | Wait time on limit            | Minimal        |
| UC-5     | Monitor update latency        | < 2 seconds    |
| UC-6     | Manual reset success          | 100%           |

---

## Non-Functional Requirements

### Reliability

- **Availability**: 99%+ when network and API available
- **Fault Tolerance**: Graceful handling of Claude API errors
- **Data Integrity**: No data loss on unexpected termination

### Performance

- **Response Time**: Status checks < 100ms
- **Throughput**: Support continuous operation for days
- **Scalability**: Handle projects with 100+ loops

### Usability

- **Learnability**: New users understand system in < 30 minutes
- **Error Messages**: Clear, actionable guidance on failures
- **Documentation**: Complete use cases and examples

### Security

- **Authentication**: Respects Claude API authentication
- **Authorization**: Operates only on authorized files
- **Data Privacy**: No sensitive data logged

---

## Glossary

| Term                  | Definition                                                  |
| --------------------- | ----------------------------------------------------------- |
| **Circuit Breaker**   | Pattern that prevents runaway loops by detecting stagnation |
| **Exit Signal**       | Indicator that Claude has completed all work                |
| **Loop**              | One iteration of Ralph executing Claude Code                |
| **Rate Limit**        | Maximum API calls allowed per hour (100)                    |
| **Response Analyzer** | Component that parses Claude output for signals             |
| **Stagnation**        | Condition where no progress is being made (no file changes) |
| **Test-Only Loop**    | Loop where only tests run, no implementation work           |

---

**Document Version**: 1.0
**Last Updated**: 2025-10-01
**Author**: Based on Alistair Cockburn's use case methodology
**Status**: Phase 2 Documentation - Complete
