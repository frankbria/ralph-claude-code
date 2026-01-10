# Ralph for Claude Code - Implementation Plan

**Version**: v0.9.8 | **Tests**: 276 passing (100% pass rate) | **CI/CD**: GitHub Actions

---

## Current Phase

### Phase 1: CLI Modernization (In Progress)

Phase 1 focuses on modernizing Ralph's CLI integration with Claude Code, including JSON output parsing, session management, and documentation.

**Status**: Core features complete (1.1-1.4), remaining items are documentation and bug fixes.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #51 | Phase 1.5: Implement session expiration for .claude_session_id | P2 | Open |
| #65 | Phase 1.8: Fix timeout command not found on MacOS | P2 | Open |
| #44 | Phase 1.6: Stream Claude output to log file in real-time | P3 | Open |
| #54 | Phase 1.7: Support custom API base / proxy configuration | P3 | Open |
| #24 | Phase 1.9: Create TESTING.md documentation | P3 | Open |
| #25 | Phase 1.10: Create CONTRIBUTING.md guide | P3 | Open |
| #26 | Phase 1.11: Update README with testing instructions | P3 | Open |
| #27 | Phase 1.12: Add badges to README | P3 | Open |

**Completed Phase 1 Issues**: #28 (CLI commands), #29 (JSON parsing), #30 (session management), #31 (ralph-import), #48 (security), #50 (input validation)

---

## Planned Development

### Phase 2: Agent SDK Integration (P2)

Migrate from CLI-only execution to a hybrid CLI/SDK architecture using Claude's Agent SDK.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #32 | Phase 2.1: Create Agent SDK proof of concept | P2 | Open |
| #33 | Phase 2.2: Define custom tools for Agent SDK | P2 | Open |
| #34 | Phase 2.3: Implement hybrid CLI/SDK architecture | P2 | Open |
| #35 | Phase 2.4: Document SDK migration strategy | P2 | Open |

---

### Phase 3: Configuration & Infrastructure (P2-P3)

Add configuration file support, infrastructure features, and advanced functionality.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #36 | Phase 3.1: Add JSON configuration file support | P2 | Open |
| #37 | Phase 3.2: Update installation for SDK support | P2 | Open |
| #18 | Phase 3.4: Implement log rotation feature | P2 | Open |
| #19 | Phase 3.5: Implement dry-run mode feature | P2 | Open |
| #20 | Phase 3.6: Implement config file support (.ralphrc) | P2 | Open |
| #38 | Phase 3.3: Create CLI and SDK documentation | P3 | Open |
| #21 | Phase 3.7: Implement metrics and analytics | P3 | Open |
| #22 | Phase 3.8: Implement notification system | P3 | Open |
| #23 | Phase 3.9: Implement backup and rollback system | P3 | Open |
| #64 | Phase 3.10: Monorepo support and .ralphrc enhancements | P3 | Open |

---

### Phase 4: Validation Testing (P2-P3)

Comprehensive testing for all new features and integration scenarios.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #14 | Phase 4.4: Implement tmux integration tests | P2 | Open |
| #15 | Phase 4.5: Implement monitor dashboard tests | P2 | Open |
| #16 | Phase 4.6: Implement status update tests | P2 | Open |
| #39 | Phase 4.1: Implement CLI enhancement tests | P3 | Open |
| #40 | Phase 4.2: Implement SDK integration tests | P3 | Open |
| #41 | Phase 4.3: Implement backward compatibility tests | P3 | Open |
| #17 | Phase 4.7: Implement E2E full loop tests | P3 | Open |

---

### Phase 5: GitHub Issue Integration (P4)

Enable Ralph to import development plans directly from GitHub issues.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #69 | Phase 5.1: Allow plan import from GitHub Issue | P4 | Open |
| #70 | Phase 5.2: Assess issue completeness and generate implementation plan | P4 | Open |
| #71 | Phase 5.3: Filter and select GitHub issues by metadata | P4 | Open |
| #72 | Phase 5.4: Batch processing and issue queue management | P4 | Open |
| #73 | Phase 5.5: Issue lifecycle management and completion workflows | P4 | Open |

**Summary**: Import single issues (#69), generate plans for incomplete issues (#70), filter by labels/assignees (#71), process multiple issues (#72), and manage issue lifecycle (#73).

---

### Phase 6: Sandbox Execution Environments (P4)

Run Ralph in isolated sandbox environments for security and reproducibility.

| Issue | Title | Priority | Status |
|-------|-------|----------|--------|
| #49 | Phase 6.0: Sandbox execution environments (umbrella) | P4 | Open |
| #74 | Phase 6.1: Local Docker Sandbox Execution | P4 | Open |
| #75 | Phase 6.2: E2B Cloud Sandbox Integration | P4 | Open |
| #76 | Phase 6.3: Sandbox File Synchronization | P4 | Open |
| #77 | Phase 6.4: Sandbox Security and Resource Policies | P4 | Open |
| #78 | Phase 6.5: Generic Sandbox Interface and Plugin Architecture | P4 | Open |
| #79 | Phase 6.6: Daytona Sandbox Integration | P4 | Open |
| #80 | Phase 6.7: Cloudflare Sandbox Integration | P4 | Open |

**First-class providers**: Docker (local), E2B, Daytona, Cloudflare
**Plugin-based** (via Phase 6.5): Gitpod, Codespaces, Modal, Replit, etc.

---

## Priority Legend

| Priority | Description | Target |
|----------|-------------|--------|
| **P0** | Critical - Foundation/Blocking | Immediate |
| **P1** | High - Core features | Near-term |
| **P2** | Medium - Important enhancements | Mid-term |
| **P3** | Low - Nice to have | When available |
| **P4** | Enhancements - New functionality | Future |

---

## Implementation Order

**Recommended sequence**:

1. **Phase 1 Completion** (P2-P3): Finish documentation and bug fixes
2. **Phase 3 Core** (P2): Log rotation, dry-run, config file support
3. **Phase 4 Testing** (P2): tmux, monitor, status tests
4. **Phase 2 SDK** (P2): Agent SDK integration (can run parallel with Phase 3)
5. **Phase 3 Advanced** (P3): Metrics, notifications, backup
6. **Phase 4 Validation** (P3): CLI, SDK, backward compatibility tests
7. **Phase 5 GitHub** (P4): GitHub issue integration
8. **Phase 6 Sandbox** (P4): Sandbox execution environments

---

## Test Coverage

**Current**: 276 tests across 11 test files (100% pass rate)

| Category | Tests | Files |
|----------|-------|-------|
| CLI Parsing | 27 | test_cli_parsing.bats |
| CLI Modern | 29 | test_cli_modern.bats |
| JSON Parsing | 36 | test_json_parsing.bats |
| Session Continuity | 26 | test_session_continuity.bats |
| Exit Detection | 20 | test_exit_detection.bats |
| Rate Limiting | 15 | test_rate_limiting.bats |
| Loop Execution | 20 | test_loop_execution.bats |
| Edge Cases | 20 | test_edge_cases.bats |
| Installation | 14 | test_installation.bats |
| Project Setup | 36 | test_project_setup.bats |
| PRD Import | 33 | test_prd_import.bats |

---

## Completed Development

<details>
<summary>Click to expand completed work</summary>

### Phase 1: CLI Modernization (Completed Issues)

| Issue | Title | Status |
|-------|-------|--------|
| #28 | Phase 1.1: Update CLI commands with modern options | Closed |
| #29 | Phase 1.2: Enhance response parsing for JSON output | Closed |
| #30 | Phase 1.3: Add session management for continuity | Closed |
| #31 | Phase 1.4: Update ralph-import with CLI enhancements | Closed |
| #48 | MAJOR-01: Enhance shell escaping to prevent command injection | Closed |
| #50 | MAJOR-02: Add input validation for --allowed-tools flag | Closed |

### Testing Issues (Completed)

| Issue | Title | Status |
|-------|-------|--------|
| #10 | Implement CLI parsing tests | Closed |
| #11 | Implement installation tests | Closed |
| #12 | Implement project setup tests | Closed |
| #13 | Implement PRD import tests | Closed |

### Bug Fixes (Completed)

| Issue | Title | Status |
|-------|-------|--------|
| #1 | Cannot find file ~/.ralph/lib/response_analyzer.sh | Closed |
| #2 | is_error: false triggers "error" circuit breaker incorrectly | Closed |
| #5 | Bug: date: illegal option -- d on macOS | Closed |
| #7 | Review codebase for updated Anthropic CLI | Closed |
| #42 | Windows: Git Bash windows spawn when running Ralph loop | Closed |
| #55 | --prompt-file flag does not exist in Claude Code CLI | Closed |

### Other Completed

| Issue | Title | Status |
|-------|-------|--------|
| #56 | Project featured in Awesome Claude Code! | Closed |
| #63 | Fix IMPLEMENTATION_PLAN | Closed |

</details>

---

## Version History

| Version | Key Changes |
|---------|-------------|
| v0.9.8 | Modern CLI for PRD import with JSON output |
| v0.9.7 | Session lifecycle management with auto-reset |
| v0.9.6 | JSON output and session management |
| v0.9.5 | PRD import tests (22 tests) |
| v0.9.4 | Project setup tests (36 tests) |
| v0.9.3 | Installation tests (14 tests) |
| v0.9.2 | Prompt file fix (-p flag) |
| v0.9.1 | Modern CLI commands (Phase 1.1) |
| v0.9.0 | Circuit breaker enhancements |

---

**Last Updated**: 2026-01-10
**Status**: Phase 1 in progress, Phases 2-6 planned
