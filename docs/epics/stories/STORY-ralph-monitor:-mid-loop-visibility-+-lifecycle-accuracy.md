# ralph-monitor: mid-loop visibility + lifecycle accuracy

## What

Fix three concrete UX bugs in ralph-monitor dashboard: false "LIKELY DEAD" warnings, missing issue/model display, and lack of mid-loop progress visibility.

## Where

* `ralph_monitor.sh:94`

## Why

During NLTlabsPE Loop 1, monitor showed "LIKELY DEAD" for 3+ minutes while Claude actively worked through TAP-1193 (fixed regex bug, committed to main) and TAP-1170 (ported validator + 16 unit tests, 366 lines added). Data was available (JSONL stream, Linear API), but the monitor surfaced none of it. False-DEAD warnings undermine user trust; missing issue/model context forces users to grep logs to know what's running. Also update templates/hooks/on-bash-command.sh and create .ralph/.current_issue.

## Acceptance

- [ ] "LIKELY DEAD" no longer fires when ralph_loop.sh PID is alive AND .ralph/live.log mtime is recent (< 60s); fires only when both status.json is stale (>180s) AND ralph loop process has exited
- [ ] "Working on:" and "Model:" rows always render — show "(awaiting first loop)" instead of hidden when fields are null
- [ ] When Claude calls mcp__plugin_linear_linear__* tool with an issue id, .ralph/.current_issue is written (TAP-NNNN), and ralph-monitor displays it in real time before on-stop fires
- [ ] Unit test in tests/unit/ covers new live-status freshness logic (PID alive + log mtime fallback)
- [ ] Manual test plan documented in PR description
