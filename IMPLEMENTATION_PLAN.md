# Ralph for Claude Code - Implementation Plan
## Test Coverage & Feature Completion Roadmap

**Goal**: Achieve 90%+ test coverage and implement missing critical features
**Timeline**: 6 weeks
**Current Coverage**: 0%
**Target Coverage**: 90%+

---

## 📅 Week 1: Test Infrastructure Setup

### Day 1-2: Foundation
- [ ] Install BATS testing framework
  ```bash
  npm install -g bats
  npm install --save-dev bats-support bats-assert
  ```
- [ ] Create test directory structure
  ```
  tests/
  ├── unit/
  │   ├── test_rate_limiting.bats
  │   ├── test_exit_detection.bats
  │   ├── test_cli_parsing.bats
  │   └── test_status_updates.bats
  ├── integration/
  │   ├── test_installation.bats
  │   ├── test_project_setup.bats
  │   ├── test_prd_import.bats
  │   └── test_tmux_integration.bats
  ├── e2e/
  │   ├── test_full_loop.bats
  │   └── test_graceful_exit.bats
  ├── helpers/
  │   ├── test_helper.bash
  │   ├── mocks.bash
  │   └── fixtures.bash
  └── fixtures/
      ├── sample_prd.md
      ├── sample_fix_plan.md
      └── sample_status.json
  ```

### Day 3-4: Test Helpers & Mocks
- [ ] Create `tests/helpers/test_helper.bash`
  - Setup/teardown utilities
  - Temp directory management
  - Assertion helpers
  - Color output stripping
- [ ] Create `tests/helpers/mocks.bash`
  - Mock Claude Code CLI (`mock_claude_code()`)
  - Mock tmux commands
  - Mock date/time for deterministic tests
  - Mock file I/O operations
- [ ] Create `tests/helpers/fixtures.bash`
  - Sample PRD documents
  - Sample @fix_plan.md files
  - Sample status.json files
  - Sample Claude Code responses

### Day 5: First Tests & CI Setup
- [ ] Write first 5 unit tests for rate limiting
- [ ] Set up GitHub Actions workflow
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
- [ ] Verify tests run successfully
- [ ] Document test running instructions in README

**Deliverables**:
- ✅ BATS installed and configured
- ✅ Test directory structure created
- ✅ Helper utilities and mocks written
- ✅ First 5 tests passing
- ✅ CI/CD pipeline operational
- **Coverage**: ~5%

---

## 📅 Week 2: Phase 1 Unit Tests

### Day 1-2: Rate Limiting Tests (15 tests)
File: `tests/unit/test_rate_limiting.bats`

- [ ] Test `can_make_call()` under limit
- [ ] Test `can_make_call()` at limit
- [ ] Test `can_make_call()` over limit
- [ ] Test `increment_call_counter()` from 0
- [ ] Test `increment_call_counter()` near limit
- [ ] Test `init_call_tracking()` new hour reset
- [ ] Test `init_call_tracking()` same hour persistence
- [ ] Test `init_call_tracking()` missing files
- [ ] Test `wait_for_reset()` countdown accuracy
- [ ] Test `wait_for_reset()` counter reset
- [ ] Test call count persistence across restarts
- [ ] Test timestamp file format validation
- [ ] Test concurrent call counter updates
- [ ] Test rate limit with different MAX_CALLS values
- [ ] Test edge case: midnight hour rollover

### Day 3-4: Exit Detection Tests (20 tests)
File: `tests/unit/test_exit_detection.bats`

- [ ] Test `should_exit_gracefully()` no signals
- [ ] Test `should_exit_gracefully()` test saturation (3+ loops)
- [ ] Test `should_exit_gracefully()` done signals (2+)
- [ ] Test `should_exit_gracefully()` completion indicators (2+)
- [ ] Test `should_exit_gracefully()` @fix_plan all complete
- [ ] Test `should_exit_gracefully()` @fix_plan partial complete
- [ ] Test `should_exit_gracefully()` missing exit signals file
- [ ] Test `should_exit_gracefully()` corrupted JSON
- [ ] Test `should_exit_gracefully()` empty signals
- [ ] Test exit signals file initialization
- [ ] Test multiple exit conditions simultaneously
- [ ] Test exit condition thresholds (MAX_CONSECUTIVE_*)
- [ ] Test @fix_plan.md with no checkboxes
- [ ] Test @fix_plan.md with mixed completion
- [ ] Test @fix_plan.md missing file
- [ ] Test exit reason string formatting
- [ ] Test return codes for different exit types
- [ ] Test grep fallback for zero matches
- [ ] Test edge case: all tests marked complete
- [ ] Test edge case: malformed checkbox syntax

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
- ✅ 41 unit tests written and passing
- ✅ All core logic tested
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
- ✅ 28 integration tests written and passing
- ✅ Installation and setup workflows tested
- **Coverage**: ~55%

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
- ✅ 26 integration tests written and passing
- ✅ All integration workflows tested
- **Coverage**: ~75%

---

## 📅 Week 5: Phase 3 Edge Cases & Features

### Day 1-2: Edge Case Tests (15 tests)
File: `tests/e2e/test_edge_cases.bats`

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
- ✅ 30 edge case tests written and passing
- ✅ Log rotation implemented and tested
- ✅ Dry-run mode implemented and tested
- ✅ Config file support implemented and tested
- **Coverage**: ~85%

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
- ✅ Metrics tracking implemented and tested
- ✅ Notification system implemented and tested
- ✅ Backup system implemented and tested
- ✅ 10 E2E tests written and passing
- **Coverage**: 90%+

### Day 5: Documentation & Polish

- [ ] Update README.md with new features
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
- ✅ Comprehensive documentation updated
- ✅ Testing guide created
- ✅ Contribution guide created
- ✅ Ready for v1.0.0 release

---

## 🎯 Final Checklist

### Test Coverage
- [ ] ✅ 90%+ overall test coverage achieved
- [ ] ✅ All critical paths tested
- [ ] ✅ Edge cases covered
- [ ] ✅ Integration tests passing
- [ ] ✅ E2E tests passing

### Features
- [ ] ✅ Log rotation implemented
- [ ] ✅ Dry-run mode working
- [ ] ✅ Config file support functional
- [ ] ✅ Metrics tracking operational
- [ ] ✅ Notifications working
- [ ] ✅ Backup/rollback tested

### Documentation
- [ ] ✅ README.md updated
- [ ] ✅ TESTING.md created
- [ ] ✅ CONTRIBUTING.md created
- [ ] ✅ IMPLEMENTATION_PLAN.md completed
- [ ] ✅ API documentation current

### Quality
- [ ] ✅ All tests passing
- [ ] ✅ No linting errors
- [ ] ✅ CI/CD pipeline green
- [ ] ✅ Code reviewed
- [ ] ✅ Release notes prepared

---

## 📊 Success Metrics

| Metric | Current | Week 1 | Week 2 | Week 3 | Week 4 | Week 5 | Week 6 |
|--------|---------|--------|--------|--------|--------|--------|--------|
| Test Coverage | 0% | 5% | 35% | 55% | 75% | 85% | 90%+ |
| Total Tests | 0 | 5 | 46 | 74 | 100 | 130 | 140+ |
| Features Complete | 85% | 85% | 85% | 88% | 90% | 95% | 98%+ |

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

**Last Updated**: 2025-09-30
**Status**: Ready for implementation
**Owner**: Development Team
**Reviewer**: To be assigned
