# Ralph for Claude Code - Implementation Plan
## Test Coverage & Feature Completion Roadmap

**Goal**: Achieve 90%+ test coverage and implement missing critical features
**Timeline**: 6 weeks (ongoing)
**Current Coverage**: ~60% (75 tests passing: 15 rate limiting + 20 exit detection + 20 loop execution + 20 edge cases)
**Target Coverage**: 90%+
**Status**: Week 1-2 complete, Phase 1-2 enhancements complete, CI/CD operational

---

## 📅 Week 1: Test Infrastructure Setup

### Day 1-2: Foundation
- [x] Install BATS testing framework
  ```bash
  npm install -g bats
  npm install --save-dev bats-support bats-assert
  ```
- [x] Create test directory structure
  ```
  tests/
  ├── unit/
  │   ├── test_rate_limiting.bats ✅
  │   ├── test_exit_detection.bats ✅
  │   ├── test_cli_parsing.bats (NOT CREATED)
  │   └── test_status_updates.bats (NOT CREATED)
  ├── integration/
  │   ├── test_loop_execution.bats ✅ (not in original plan)
  │   ├── test_edge_cases.bats ✅ (not in original plan)
  │   ├── test_installation.bats (NOT CREATED)
  │   ├── test_project_setup.bats (NOT CREATED)
  │   ├── test_prd_import.bats (NOT CREATED)
  │   └── test_tmux_integration.bats (NOT CREATED)
  ├── e2e/ (NOT CREATED)
  │   ├── test_full_loop.bats
  │   └── test_graceful_exit.bats
  ├── helpers/ ✅
  │   ├── test_helper.bash ✅
  │   ├── mocks.bash ✅
  │   └── fixtures.bash ✅
  └── fixtures/ (helpers include fixture generation)
      ├── sample_prd.md
      ├── sample_fix_plan.md
      └── sample_status.json
  ```

### Day 3-4: Test Helpers & Mocks
- [x] Create `tests/helpers/test_helper.bash` ✅
  - Setup/teardown utilities ✅
  - Temp directory management ✅
  - Assertion helpers ✅
  - Color output stripping ✅
- [x] Create `tests/helpers/mocks.bash` ✅
  - Mock Claude Code CLI (`mock_claude_code()`) ✅
  - Mock tmux commands ✅
  - Mock date/time for deterministic tests ✅
  - Mock file I/O operations ✅
- [x] Create `tests/helpers/fixtures.bash` ✅
  - Sample PRD documents ✅
  - Sample @fix_plan.md files ✅
  - Sample status.json files ✅
  - Sample Claude Code responses ✅

### Day 5: First Tests & CI Setup
- [x] Write first 5 unit tests for rate limiting ✅ (15 tests written)
- [x] Set up GitHub Actions workflow ✅ (.github/workflows/test.yml)
  ```yaml
  # .github/workflows/test.yml
  name: Test Suite
  on: [push, pull_request]
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v3
        - run: npm install -g bats
        - run: bats tests/
  ```
- [x] Verify tests run successfully ✅ (75/75 tests passing)
- [ ] Document test running instructions in README (PARTIAL - needs update)

**Deliverables**:
- ✅ BATS installed and configured (package.json devDependencies)
- ✅ Test directory structure created (tests/unit, tests/integration, tests/helpers)
- ✅ Helper utilities and mocks written (test_helper.bash, mocks.bash, fixtures.bash)
- ✅ First 15 tests passing (exceeded target)
- ✅ CI/CD pipeline operational (.github/workflows/test.yml configured)
- **Coverage**: ~25% (better than target)

---

## 📅 Week 2: Phase 1 Unit Tests

### Day 1-2: Rate Limiting Tests (15 tests) ✅ COMPLETE
File: `tests/unit/test_rate_limiting.bats`

- [x] Test `can_make_call()` under limit ✅
- [x] Test `can_make_call()` at limit ✅
- [x] Test `can_make_call()` over limit ✅
- [x] Test `increment_call_counter()` from 0 ✅
- [x] Test `increment_call_counter()` near limit ✅
- [x] Test `init_call_tracking()` new hour reset ✅
- [x] Test `init_call_tracking()` same hour persistence ✅
- [x] Test `init_call_tracking()` missing files ✅
- [x] Test `wait_for_reset()` countdown accuracy ✅
- [x] Test `wait_for_reset()` counter reset ✅
- [x] Test call count persistence across restarts ✅
- [x] Test timestamp file format validation ✅
- [x] Test concurrent call counter updates ✅
- [x] Test rate limit with different MAX_CALLS values ✅
- [x] Test edge case: midnight hour rollover ✅

### Day 3-4: Exit Detection Tests (20 tests) ✅ COMPLETE
File: `tests/unit/test_exit_detection.bats`

- [x] Test `should_exit_gracefully()` no signals ✅
- [x] Test `should_exit_gracefully()` test saturation (3+ loops) ✅
- [x] Test `should_exit_gracefully()` done signals (2+) ✅
- [x] Test `should_exit_gracefully()` completion indicators (2+) ✅
- [x] Test `should_exit_gracefully()` @fix_plan all complete ✅
- [x] Test `should_exit_gracefully()` @fix_plan partial complete ✅
- [x] Test `should_exit_gracefully()` missing exit signals file ✅
- [x] Test `should_exit_gracefully()` corrupted JSON ✅
- [x] Test `should_exit_gracefully()` empty signals ✅
- [x] Test exit signals file initialization ✅
- [x] Test multiple exit conditions simultaneously ✅
- [x] Test exit condition thresholds (MAX_CONSECUTIVE_*) ✅
- [x] Test @fix_plan.md with no checkboxes ✅
- [x] Test @fix_plan.md with mixed completion ✅
- [x] Test @fix_plan.md missing file ✅
- [x] Test exit reason string formatting ✅
- [x] Test return codes for different exit types ✅
- [x] Test grep fallback for zero matches ✅
- [x] Test edge case: all tests marked complete ✅
- [x] Test edge case: malformed checkbox syntax ✅

### Day 5: CLI Parsing Tests (6 tests)
File: `tests/unit/test_cli_parsing.bats`

- [ ] Test `--help` flag output
- [ ] Test `--calls NUM` flag sets MAX_CALLS_PER_HOUR
- [ ] Test `--prompt FILE` flag sets PROMPT_FILE
- [ ] Test `--status` flag shows status
- [ ] Test `--monitor` flag enables tmux
- [ ] Test `--verbose` flag enables verbose mode
- [ ] Test `--timeout MIN` flag sets timeout
- [ ] Test invalid flag handling
- [ ] Test multiple flags combined
- [ ] Test flag order independence

**Deliverables**:
- ✅ 35 unit tests written and passing (15 rate limiting + 20 exit detection)
- ✅ All core logic tested
- ⚠️ CLI parsing tests NOT yet written (planned: 10 tests)
- **Coverage**: ~35%

---

## 📅 Week 3: Phase 2 Integration Tests Part 1

### Day 1-2: Installation Tests (10 tests)
File: `tests/integration/test_installation.bats`

- [ ] Test `install.sh` creates ~/.ralph directory
- [ ] Test `install.sh` creates ~/.local/bin commands
- [ ] Test `install.sh` copies templates correctly
- [ ] Test `install.sh` sets executable permissions
- [ ] Test `install.sh` detects missing dependencies
- [ ] Test `install.sh` PATH detection and warnings
- [ ] Test `install.sh uninstall` removes all files
- [ ] Test `install.sh uninstall` cleans up directories
- [ ] Test installation idempotency (run twice)
- [ ] Test installation from different directories

### Day 3: Project Setup Tests (8 tests)
File: `tests/integration/test_project_setup.bats`

- [ ] Test `ralph-setup` creates project directory
- [ ] Test `ralph-setup` creates all subdirectories
- [ ] Test `ralph-setup` copies templates from ~/.ralph
- [ ] Test `ralph-setup` initializes git repository
- [ ] Test `ralph-setup` creates README.md
- [ ] Test `ralph-setup` with custom project name
- [ ] Test `ralph-setup` with default project name
- [ ] Test `ralph-setup` from various working directories

### Day 4-5: PRD Import Tests (10 tests)
File: `tests/integration/test_prd_import.bats`

- [ ] Test `ralph-import` with .md file
- [ ] Test `ralph-import` with .txt file
- [ ] Test `ralph-import` with .json file
- [ ] Test `ralph-import` creates PROMPT.md
- [ ] Test `ralph-import` creates @fix_plan.md
- [ ] Test `ralph-import` creates specs/requirements.md
- [ ] Test `ralph-import` with custom project name
- [ ] Test `ralph-import` with auto-detected name
- [ ] Test `ralph-import` missing source file error
- [ ] Test `ralph-import` dependency check
- [ ] Mock Claude Code responses for conversion

**Deliverables**:
- ⚠️ 0 installation tests written (planned: 28 tests)
- ⚠️ Installation and setup workflows NOT yet tested
- **Note**: These tests are planned but not yet implemented
- **Coverage**: Still ~35% (no progress on Week 3 yet)

---

## 📅 Week 4: Phase 2 Integration Tests Part 2

### Day 1-2: tmux Integration Tests (12 tests)
File: `tests/integration/test_tmux_integration.bats`

- [ ] Test `setup_tmux_session()` creates session
- [ ] Test `setup_tmux_session()` splits panes
- [ ] Test `setup_tmux_session()` starts monitor in right pane
- [ ] Test `setup_tmux_session()` starts loop in left pane
- [ ] Test `setup_tmux_session()` sets window title
- [ ] Test `setup_tmux_session()` focuses correct pane
- [ ] Test `setup_tmux_session()` with custom flags
- [ ] Test `check_tmux_available()` when installed
- [ ] Test `check_tmux_available()` when missing
- [ ] Test session name generation uniqueness
- [ ] Test detach/reattach workflow
- [ ] Test multiple concurrent sessions

### Day 3: Monitor Dashboard Tests (8 tests)
File: `tests/integration/test_monitor.bats`

- [ ] Test `ralph_monitor.sh` reads status.json
- [ ] Test `ralph_monitor.sh` displays loop count
- [ ] Test `ralph_monitor.sh` displays API calls
- [ ] Test `ralph_monitor.sh` shows recent logs
- [ ] Test `ralph_monitor.sh` handles missing status file
- [ ] Test `ralph_monitor.sh` handles corrupted JSON
- [ ] Test `ralph_monitor.sh` progress indicator display
- [ ] Test `ralph_monitor.sh` cursor hide/show

### Day 4-5: Status Update Tests (6 tests)
File: `tests/unit/test_status_updates.bats`

- [ ] Test `update_status()` creates valid JSON
- [ ] Test `update_status()` includes all fields
- [ ] Test `update_status()` with exit reason
- [ ] Test `update_status()` timestamp format
- [ ] Test `update_status()` overwrites existing file
- [ ] Test `log_status()` writes to file and stdout

**Deliverables**:
- ⚠️ 0 tmux/monitor/status tests written (planned: 26 tests)
- ⚠️ Integration workflows NOT yet tested
- **Note**: These tests are planned but not yet implemented
- **Coverage**: Still ~35% (no progress on Week 4 yet)

---

## 📅 Week 5: Phase 3 Edge Cases & Features

### Day 1-2: Edge Case Tests (20 tests) ✅ COMPLETE
File: `tests/integration/test_edge_cases.bats` (Note: in integration/, not e2e/)

- [ ] Test file permission errors (read-only logs/)
- [ ] Test disk full scenarios
- [ ] Test corrupted .call_count file
- [ ] Test corrupted .exit_signals file
- [ ] Test corrupted status.json
- [ ] Test missing PROMPT.md file
- [ ] Test missing @fix_plan.md file
- [ ] Test concurrent ralph instances
- [ ] Test SIGINT/SIGTERM signal handling
- [ ] Test cleanup() function
- [ ] Test hour boundary transitions
- [ ] Test timezone changes
- [ ] Test very long loop counts
- [ ] Test API 5-hour limit detection
- [ ] Test user prompt timeout (30s)

### Day 3: Missing Features - Log Rotation
File: `ralph_loop.sh` (add after line 146)

- [ ] Implement `rotate_logs()` function
  ```bash
  rotate_logs() {
      local max_size=10485760  # 10MB
      local log_file="$LOG_DIR/ralph.log"

      if [[ -f "$log_file" ]]; then
          local size=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file")
          if [[ $size -gt $max_size ]]; then
              # Rotate logs (keep last 5)
              [[ -f "$log_file.4" ]] && rm "$log_file.4"
              [[ -f "$log_file.3" ]] && mv "$log_file.3" "$log_file.4"
              [[ -f "$log_file.2" ]] && mv "$log_file.2" "$log_file.3"
              [[ -f "$log_file.1" ]] && mv "$log_file.1" "$log_file.2"
              mv "$log_file" "$log_file.1"
              touch "$log_file"
              log_status "INFO" "Log rotated (size: $size bytes)"
          fi
      fi
  }
  ```
- [ ] Call `rotate_logs()` at start of each loop
- [ ] Write 5 tests for log rotation

### Day 4: Missing Features - Dry Run Mode
File: `ralph_loop.sh` (add to configuration section)

- [ ] Add `DRY_RUN=false` variable
- [ ] Add `--dry-run` flag to CLI parser
- [ ] Modify `execute_claude_code()` to skip execution
  ```bash
  execute_claude_code() {
      if [[ "$DRY_RUN" == "true" ]]; then
          log_status "INFO" "[DRY RUN] Would execute: $CLAUDE_CODE_CMD < $PROMPT_FILE"
          log_status "INFO" "[DRY RUN] Would increment counter to $((calls_made + 1))"
          sleep 2  # Simulate execution time
          return 0
      fi
      # ... existing implementation
  }
  ```
- [ ] Write 4 tests for dry-run mode

### Day 5: Missing Features - Config File Support
File: `ralph_loop.sh` (add before main())

- [ ] Implement `load_config()` function
  ```bash
  load_config() {
      # Load global config
      if [[ -f "$HOME/.ralphrc" ]]; then
          source "$HOME/.ralphrc"
          log_status "INFO" "Loaded global config: ~/.ralphrc"
      fi

      # Load project config (overrides global)
      if [[ -f ".ralphrc" ]]; then
          source ".ralphrc"
          log_status "INFO" "Loaded project config: .ralphrc"
      fi
  }
  ```
- [ ] Call `load_config()` at start of `main()`
- [ ] Create example config file
  ```bash
  # Example ~/.ralphrc
  MAX_CALLS_PER_HOUR=50
  CLAUDE_TIMEOUT_MINUTES=30
  VERBOSE_PROGRESS=true
  ```
- [ ] Write 6 tests for config file loading

**Deliverables**:
- ✅ 20 edge case tests written and passing (tests/integration/test_edge_cases.bats)
- ⚠️ Log rotation NOT implemented
- ⚠️ Dry-run mode NOT implemented
- ⚠️ Config file support NOT implemented
- **Note**: Week 5 features are planned but not yet implemented
- **Coverage**: ~60% (no additional coverage from unimplemented features)

---

## 📅 Week 6: Final Features & Documentation

### Day 1: Metrics & Analytics
File: `ralph_loop.sh` (add after execute_claude_code)

- [ ] Implement `track_metrics()` function
  ```bash
  track_metrics() {
      local loop_num=$1
      local duration=$2
      local success=$3
      local calls=$4

      cat >> "$LOG_DIR/metrics.jsonl" << EOF
  {"timestamp":"$(date -Iseconds)","loop":$loop_num,"duration":$duration,"success":$success,"calls":$calls}
  EOF
  }
  ```
- [ ] Track execution time for each loop
- [ ] Add metrics summary on exit
- [ ] Create `ralph-stats` command for analysis
  ```bash
  #!/bin/bash
  # Analyze metrics.jsonl and show statistics
  cat logs/metrics.jsonl | jq -s '
    {
      total_loops: length,
      successful: [.[] | select(.success == true)] | length,
      avg_duration: ([.[] | .duration] | add / length),
      total_calls: ([.[] | .calls] | add)
    }
  '
  ```
- [ ] Write 4 tests for metrics tracking

### Day 2: Notification System
File: `ralph_loop.sh` (add utilities section)

- [ ] Implement `send_notification()` function
  ```bash
  send_notification() {
      local title=$1
      local message=$2

      # macOS
      if command -v osascript &>/dev/null; then
          osascript -e "display notification \"$message\" with title \"$title\""
      fi

      # Linux with notify-send
      if command -v notify-send &>/dev/null; then
          notify-send "$title" "$message"
      fi

      # Fallback: terminal bell
      echo -e "\a"
  }
  ```
- [ ] Add notifications for:
  - Loop completion
  - Rate limit reached
  - API 5-hour limit
  - Graceful exit
  - Errors
- [ ] Add `--notify` flag to enable notifications
- [ ] Write 3 tests for notifications

### Day 3: Backup & Rollback
File: `ralph_loop.sh` (add before execute_claude_code)

- [ ] Implement `create_backup()` function
  ```bash
  create_backup() {
      if git rev-parse --git-dir > /dev/null 2>&1; then
          # Create backup branch
          local backup_branch="ralph-backup-loop-$loop_count-$(date +%s)"
          git branch "$backup_branch" 2>/dev/null || true

          # Commit current state
          git add -A
          git commit -m "Ralph backup before loop #$loop_count" --allow-empty || true

          log_status "INFO" "Backup created: $backup_branch"
      fi
  }
  ```
- [ ] Call `create_backup()` before risky operations
- [ ] Implement `rollback_to_backup()` function
- [ ] Add `--backup` flag to enable auto-backup
- [ ] Write 5 tests for backup/rollback

### Day 4: End-to-End Tests
File: `tests/e2e/test_full_loop.bats`

- [ ] Test complete loop execution (mocked Claude)
- [ ] Test multi-loop scenario (5 loops)
- [ ] Test graceful exit from completion
- [ ] Test graceful exit from test saturation
- [ ] Test resume after interruption
- [ ] Test rate limit wait cycle
- [ ] Test API 5-hour limit handling
- [ ] Test with all flags combined
- [ ] Test concurrent monitoring
- [ ] Test cleanup on exit

**Deliverables**:
- ⚠️ Metrics tracking NOT implemented
- ⚠️ Notification system NOT implemented
- ⚠️ Backup system NOT implemented
- ⚠️ 0 E2E tests written (tests/e2e/ directory doesn't exist)
- **Note**: Week 6 features are planned but not yet implemented
- **Coverage**: Still ~60%

### Day 5: Documentation & Polish

- [x] README.md is comprehensive and current ✅
- [ ] Update README.md with new features (when Week 5-6 features are implemented)
  - Testing instructions
  - Configuration file usage
  - Dry-run mode
  - Metrics analysis
  - Backup/rollback
- [ ] Create TESTING.md
  - How to run tests
  - How to write new tests
  - Test coverage requirements
  - CI/CD pipeline details
- [ ] Create CONTRIBUTING.md
  - Development setup
  - Code style guidelines
  - Test requirements
  - PR process
- [ ] Update CLAUDE.md with test info
- [ ] Add badges to README
  - Test coverage badge
  - CI/CD status badge
  - Version badge
- [ ] Create release notes for v1.0.0

**Deliverables**:
- ✅ README.md is comprehensive
- ⚠️ TESTING.md NOT created
- ⚠️ CONTRIBUTING.md NOT created
- ⚠️ NOT ready for v1.0.0 release (missing Week 3-6 implementation)

---

## 🎯 Final Checklist

### Test Coverage
- [ ] 90%+ overall test coverage achieved (Currently: ~60%)
- [x] ✅ Core critical paths tested (rate limiting, exit detection)
- [x] ✅ Edge cases covered (20 tests)
- [ ] Integration tests passing (only 40/~90 planned tests done)
- [ ] E2E tests passing (0 tests exist)

### Features
- [x] ✅ Circuit breaker implemented (lib/circuit_breaker.sh)
- [x] ✅ Response analyzer implemented (lib/response_analyzer.sh)
- [x] ✅ Date utilities implemented (lib/date_utils.sh)
- [ ] Log rotation NOT implemented
- [ ] Dry-run mode NOT implemented
- [ ] Config file support NOT implemented
- [ ] Metrics tracking NOT implemented
- [ ] Notifications NOT implemented
- [ ] Backup/rollback NOT implemented

### Documentation
- [x] ✅ README.md updated and comprehensive
- [x] ✅ CLAUDE.md detailed and current
- [ ] TESTING.md NOT created
- [ ] CONTRIBUTING.md NOT created
- [x] ✅ IMPLEMENTATION_PLAN.md tracking progress
- [x] ✅ Multiple completion/review documents exist

### Quality
- [x] ✅ All 75 tests passing
- [ ] Linting errors status unknown (no linter configured)
- [x] ✅ CI/CD pipeline configured (.github/workflows/test.yml)
- [ ] Code reviews needed for new features
- [ ] Release notes NOT prepared

---

## 📊 Success Metrics

| Metric | Original | Week 1 | Week 2 | Week 3 | Week 4 | Week 5 | Week 6 |
|--------|----------|--------|--------|--------|--------|--------|--------|
| Test Coverage | 0% | 25% | 35% | ~35% | ~35% | ~60% | 90%+ (target) |
| Total Tests | 0 | 15 | 35 | 35 | 35 | 75 | 140+ (target) |
| Features Complete | 85% | 85% | 85% | 85% | 85% | 88% | 98%+ (target) |

**Note**: Week 1-2 complete, Week 5 partially complete (edge case tests + lib modules). Weeks 3-4 and 6 not started.

---

## 🚀 Getting Started

To begin implementation:

```bash
# 1. Install BATS
npm install -g bats bats-support bats-assert

# 2. Create test structure
mkdir -p tests/{unit,integration,e2e,helpers,fixtures}

# 3. Start with Week 1, Day 1 tasks
# Follow this plan sequentially

# 4. Run tests as you go
bats tests/

# 5. Track progress
# Mark items complete in this file as you finish them
```

---

## 📝 Notes

- Each week builds on previous work
- Tests should be written before or alongside features
- All tests must pass before moving to next phase
- CI/CD pipeline must stay green
- Update documentation as features are added
- Regular code reviews recommended
- Track actual time vs estimates for future planning

---

**Last Updated**: 2025-12-31
**Status**: Week 1-2 Complete + Partial Week 5 (edge cases + lib modules). Weeks 3-4, 6 not started.
**Owner**: Development Team
**Reviewer**: To be assigned

---

## 📊 Implementation Status Summary

**SEE IMPLEMENTATION_STATUS.md FOR DETAILED PROGRESS**

### Completed (✅)
- Week 1: Test Infrastructure (100%) - BATS, helpers, mocks, CI/CD
- Week 2: Unit Tests (70%) - 35 tests (15 rate limiting + 20 exit detection), missing CLI parsing tests
- Week 5 (Partial): Edge Case Tests (20 tests) + Library Modules (circuit_breaker.sh, response_analyzer.sh, date_utils.sh)
- Phase 1-2 Enhancements: Response Analyzer + Circuit Breaker (beyond original plan)

### Current Stats (As of 2025-12-31)
- **75 tests written** (all passing: 15 rate + 20 exit + 20 loop + 20 edge)
- **~60% code coverage** (estimated, core paths well covered)
- **2,300+ lines of documentation** (README, CLAUDE.md, multiple review docs)
- **CI/CD operational** (.github/workflows/test.yml configured)
- **Library modules** (circuit_breaker, response_analyzer, date_utils)

### Remaining Work
- Week 2: CLI Parsing Tests (~10 tests)
- Week 3: Installation + Setup + PRD Import Tests (~28 tests)
- Week 4: tmux + Monitor + Status Tests (~26 tests)
- Week 5: Features (log rotation, dry-run, config file support) + tests (~15 tests)
- Week 6: Advanced Features (metrics, notifications, backup) + E2E tests (~25 tests)
- Documentation: TESTING.md, CONTRIBUTING.md
- Estimated remaining: ~4-5 weeks of work
