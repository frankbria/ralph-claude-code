# Ralph Specification Workshop Guide

**Based on**: Janet Gregory's "Three Amigos" collaborative testing approach
**Purpose**: Facilitate productive specification conversations for new Ralph features
**Audience**: Developers, Testers, Product Owners working on Ralph enhancements

---

## What is a Specification Workshop?

A specification workshop brings together three perspectives ("Three Amigos") to define features before implementation:

1. **Developer** (How to implement) - Technical feasibility and approach
2. **Tester** (How to verify) - Edge cases, validation, quality criteria
3. **Product Owner / User** (What's the value) - Business requirements and success criteria

**Goal**: Produce concrete, testable specifications that prevent bugs and misunderstandings.

---

## Workshop Template

### Feature: [Name]

**Participants**:
- Developer: [Name]
- Tester: [Name]
- Product Owner: [Name]
**Date**: YYYY-MM-DD
**Duration**: 30-60 minutes

---

## 1. User Story

**As a** [role]
**I want** [capability]
**So that** [benefit]

**Example**:
> As a Ralph user
> I want circuit breaker auto-recovery
> So that temporary issues don't require manual intervention

---

## 2. Acceptance Criteria (Product Owner)

What makes this feature "done" and valuable?

**Criteria**:
- [ ] [Measurable criterion 1]
- [ ] [Measurable criterion 2]
- [ ] [Measurable criterion 3]

**Example**:
- [x] Circuit breaker auto-recovers when progress resumes
- [x] User is notified of recovery via log message
- [x] Recovery happens within 1 loop iteration

---

## 3. Questions from Tester

What needs clarification? What could go wrong?

**Tester Questions**:
1. What happens if [edge case 1]?
2. How do we verify [behavior 2]?
3. What's the expected behavior when [scenario 3]?

**Answers**:
1. [Answer to question 1]
2. [Answer to question 2]
3. [Answer to question 3]

**Example**:
**Q**: What happens if circuit opens and closes rapidly (flapping)?
**A**: Circuit requires 2 stable loops in CLOSED before considering fully recovered

**Q**: How do we test auto-recovery?
**A**: Integration test: force HALF_OPEN state, simulate progress, verify CLOSED

---

## 4. Implementation Approach (Developer)

How will this be built? What are the technical constraints?

**Approach**:
- [High-level implementation strategy]
- [Key components to modify]
- [Dependencies or prerequisites]

**Constraints**:
- [Technical limitation 1]
- [Technical limitation 2]

**Example**:
**Approach**:
- Modify `record_loop_result()` to track recovery attempts
- Add `recovery_count` field to circuit breaker state
- Implement recovery validation logic in state transitions

**Constraints**:
- Must maintain backward compatibility with existing state files
- Recovery logic must not slow down normal loop execution

---

## 5. Specification by Example (All Participants)

Concrete scenarios using Given/When/Then format.

### Scenario 1: [Scenario Name]

**Given**:
- [Initial condition 1]
- [Initial condition 2]

**When**: [Action or trigger]

**Then**:
- [Expected outcome 1]
- [Expected outcome 2]

**And**:
- [Additional verification]

**Example**:

### Scenario 1: Auto-Recovery from HALF_OPEN

**Given**:
- Circuit breaker is in HALF_OPEN state
- consecutive_no_progress is 2
- last_progress_loop was loop #10

**When**: Loop #13 completes with 3 files changed

**Then**:
- Circuit breaker transitions to CLOSED state
- consecutive_no_progress resets to 0
- last_progress_loop updates to 13
- Log message: "✅ CIRCUIT BREAKER: Normal Operation - Progress detected, circuit recovered"

**And**:
- Circuit breaker history records the HALF_OPEN → CLOSED transition
- .circuit_breaker_state file contains state: "CLOSED"

---

### Scenario 2: [Another Scenario]

[Repeat format above for 3-5 key scenarios]

---

## 6. Edge Cases and Error Conditions (Tester-Led)

What unusual situations must be handled?

**Edge Cases**:
1. [Edge case 1] → [Expected behavior]
2. [Edge case 2] → [Expected behavior]
3. [Edge case 3] → [Expected behavior]

**Error Conditions**:
1. [Error condition 1] → [Error handling strategy]
2. [Error condition 2] → [Error handling strategy]

**Example**:

**Edge Cases**:
1. Circuit opens and closes in same second → Track transitions, no timestamp collision
2. Recovery during rate limit wait → Allow recovery, don't block on rate limit
3. File changes detected but tests fail → Don't consider full recovery, stay in HALF_OPEN

**Error Conditions**:
1. Circuit state file corrupted → Reinitialize to CLOSED, log warning
2. jq command not available → Fallback to manual parsing or disable circuit breaker

---

## 7. Test Strategy (Tester)

How will we verify this works?

**Unit Tests**:
- [ ] [Unit test 1]
- [ ] [Unit test 2]

**Integration Tests**:
- [ ] [Integration test 1]
- [ ] [Integration test 2]

**Manual Tests**:
- [ ] [Manual verification 1]

**Example**:

**Unit Tests**:
- [x] Test state transition logic: HALF_OPEN + progress → CLOSED
- [x] Test state persistence across function calls

**Integration Tests**:
- [x] Full loop cycle: trigger HALF_OPEN, simulate recovery, verify CLOSED
- [x] Verify log messages appear with correct formatting
- [x] Test recovery with real file changes via git

**Manual Tests**:
- [ ] Run ralph-monitor during recovery and observe state changes
- [ ] Verify .circuit_breaker_history contains transition records

---

## 8. Non-Functional Requirements

Performance, security, usability considerations.

**Performance**:
- [Requirement 1]
- [Requirement 2]

**Security**:
- [Requirement 1]

**Usability**:
- [Requirement 1]

**Example**:

**Performance**:
- Recovery detection must complete in < 100ms
- No memory leaks from repeated state transitions

**Security**:
- State files must not expose sensitive project information
- Circuit breaker must not bypass API rate limits

**Usability**:
- Recovery messages must be clear and actionable
- User should understand why recovery occurred

---

## 9. Definition of Done (All Participants)

When can we consider this feature complete?

**Checklist**:
- [ ] Code implemented and reviewed
- [ ] All unit tests passing
- [ ] All integration tests passing
- [ ] Edge cases handled and tested
- [ ] Documentation updated
- [ ] Examples added
- [ ] Manually tested in realistic scenario
- [ ] Merged to main branch

---

## 10. Follow-Up Actions

What needs to happen next?

**Action Items**:
- [ ] [Person] - [Action] - [Deadline]
- [ ] [Person] - [Action] - [Deadline]

**Example**:
- [x] Developer - Implement recovery logic - 2025-10-02
- [x] Tester - Write integration tests - 2025-10-02
- [x] Product Owner - Review and approve scenarios - 2025-10-03

---

## Example Workshop: Rate Limit Auto-Retry

**Feature**: Automatic retry on API rate limit errors

### 1. User Story

**As a** Ralph user
**I want** automatic retries on temporary API errors
**So that** transient issues don't stop my development workflow

### 2. Acceptance Criteria

- [x] Ralph detects "rate_limit_error" in Claude output
- [x] Ralph waits appropriate time before retry (5 minutes)
- [x] Ralph limits retries to 3 attempts
- [x] Ralph falls back to user prompt on persistent failure
- [x] Retry attempts are logged clearly

### 3. Questions from Tester

**Q**: What counts as a "rate limit error" vs other errors?
**A**: Specific string "rate_limit_error" or "429" status code in output

**Q**: Should retries count against hourly call limit?
**A**: Yes, retry attempts consume call quota

**Q**: What if user Ctrl+C during wait period?
**A**: Graceful shutdown, save state, allow resume

### 4. Implementation Approach

**Approach**:
- Add retry logic to `execute_claude_code()` function
- Implement exponential backoff (5 min → 10 min → 15 min)
- Store retry state in `.retry_state` file
- Add retry counter to status.json

**Constraints**:
- Must work with existing rate limit tracking
- Cannot bypass circuit breaker
- Retries must respect API 5-hour limit

### 5. Specification by Example

**Scenario 1: Successful Retry**

**Given**:
- Ralph executes Claude Code at loop #5
- Claude returns "rate_limit_error: please retry"
- Retry count is 0

**When**: Ralph detects the rate limit error

**Then**:
- Ralph logs "Rate limit detected, attempt 1/3. Waiting 5 minutes..."
- Ralph sleeps for 300 seconds
- Ralph retries Claude Code execution
- If successful: continues normally, resets retry count to 0

**Scenario 2: Persistent Failure**

**Given**:
- Ralph has retried 3 times already
- Each retry resulted in "rate_limit_error"

**When**: 4th execution also returns rate limit error

**Then**:
- Ralph logs "Retry limit exceeded (3 attempts)"
- Ralph prompts user: "Continue waiting? (y/n)"
- User decision determines next action (exit or continue)

### 6. Edge Cases

1. Rate limit error during first loop → Retry works immediately
2. User interrupts during wait → Clean shutdown, state preserved
3. Different error after retry → Handle as normal error, don't increment retry count
4. Rate limit resolves after 1st retry → Reset counter, continue normally

### 7. Test Strategy

**Unit Tests**:
- [x] Test retry detection logic
- [x] Test exponential backoff calculation
- [x] Test retry limit enforcement

**Integration Tests**:
- [x] Mock rate limit error, verify retry happens
- [x] Mock 3 failures, verify fallback to user prompt
- [x] Verify retry state persists across restarts

### 8. Definition of Done

- [x] Code implemented in ralph_loop.sh
- [x] Unit tests added to tests/unit/
- [x] Integration tests added to tests/integration/
- [x] Documentation updated in README.md
- [x] Manually tested with mock API errors
- [x] Merged to main

---

## Workshop Best Practices

### Before the Workshop
1. **Prepare**: Send user story to participants 24 hours ahead
2. **Context**: Provide relevant background (why this feature now?)
3. **Time-box**: Schedule 30-60 minutes max

### During the Workshop
1. **Focus**: One feature at a time
2. **Concrete**: Use real examples, not abstract descriptions
3. **Questions**: Encourage tester to ask "what could go wrong?"
4. **Document**: Capture decisions in real-time

### After the Workshop
1. **Summarize**: Send notes to all participants
2. **Track**: Create tasks for action items
3. **Reference**: Use scenarios for test cases

### Red Flags
❌ "We'll figure it out during implementation"
❌ "That's edge case, we'll handle it later"
❌ Vague acceptance criteria
❌ No concrete examples
❌ Skipping tester perspective

### Success Indicators
✅ Clear, testable scenarios
✅ Edge cases identified before coding
✅ All three perspectives represented
✅ Concrete examples, not abstractions
✅ Shared understanding among participants

---

## Template Files

### Quick Workshop Template (15 minutes)

```markdown
# Feature: [Name]

**User Story**: As [role], I want [capability] so that [benefit]

**Key Scenarios**:
1. Given [state], When [action], Then [outcome]
2. Given [state], When [action], Then [outcome]

**Edge Cases**:
- [Case 1] → [Behavior]
- [Case 2] → [Behavior]

**Tests**:
- [ ] [Test 1]
- [ ] [Test 2]

**Done When**:
- [ ] Implemented
- [ ] Tested
- [ ] Documented
```

---

## Resources

- **Three Amigos**: https://www.agilealliance.org/glossary/three-amigos/
- **Specification by Example** - Gojko Adzic
- **Agile Testing** - Lisa Crispin, Janet Gregory

---

**Last Updated**: 2025-10-01
**Status**: Phase 2 Complete
**Next**: Use this template for all new Ralph features
