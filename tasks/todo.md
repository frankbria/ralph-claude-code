# Issue #138: feat: automate version and test count badges via GitHub Actions

## Plan

## Problem

Version badges in README.md and CLAUDE.md require manual updates, leading to drift between actual state and documented state. This was caught during PR #137 review where badges showed `v0.10.1` and `310 tests` instead of `v0.11.2` and `440 tests`.

## Proposed Solution

Implement a GitHub Actions workflow that automatically updates badges after:
1. Test suite runs (update test count)
2. Releases are published (update version)

### Implementation Plan

**Phase 1: Test Count Automation**

Create `.github/workflows/update-badges.yml`:

```yaml
name: Update Badges

on:
  push:
    branches: [main]
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]

jobs:
  update-badges:
    runs-on: ubuntu-latest
    if: github.event.workflow_run.conclusion == 'success' || github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          
      - name: Install dependencies
        run: npm ci
      
      - name: Get test count
        run: |
          TEST_COUNT=$(npm test 2>&1 | grep -c "^ok " || echo "0")
          echo "TEST_COUNT=$TEST_COUNT" >> $GITHUB_ENV
          
      - name: Update badges if changed
        run: |
          # Update README.md test badge
          sed -i "s/tests-[0-9]*%20passing/tests-${TEST_COUNT}%20passing/" README.md
          
          # Update CLAUDE.md test count
          sed -i "s/Tests\*\*: [0-9]* passing/Tests**: ${TEST_COUNT} passing/" CLAUDE.md
          
      - name: Check for changes
        id: changes
        run: |
          if git diff --quiet; then
            echo "changed=false" >> $GITHUB_OUTPUT
          else
            echo "changed=true" >> $GITHUB_OUTPUT
          fi
          
      - name: Commit changes
        if: steps.changes.outputs.changed == 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add README.md CLAUDE.md
          git commit -m "chore: update test count badge to ${TEST_COUNT}"
          git push
```

**Phase 2: Version Automation (Future)**

When GitHub Releases are adopted:
- Trigger on `release: [published]`
- Extract version from release tag
- Update version badges in README.md, CLAUDE.md
- Consider using shields.io dynamic badges: `![Version](https://img.shields.io/github/v/release/frankbria/ralph-claude-code)`

### Files to Update

| File | Badge Type | Current Format |
|------|-----------|----------------|
| README.md | Version | `![Version](https://img.shields.io/badge/version-X.X.X-blue)` |
| README.md | Tests | `![Tests](https://img.shields.io/badge/tests-XXX%20passing-green)` |
| CLAUDE.md | Both | `**Version**: vX.X.X \| **Tests**: XXX passing` |

### Acceptance Criteria

- [ ] Workflow runs after successful CI on main branch
- [ ] Test count badge updates automatically
- [ ] No workflow runs on badge-only commits (prevent infinite loop)
- [ ] Commit messages follow conventional commit format

### Future Enhancements

- [ ] Integrate with GitHub Releases for version automation
- [ ] Consider switching to dynamic shields.io badges
- [ ] Add badge for code coverage percentage

## Related

- PR #137 - Manual badge update that prompted this issue

## Acceptance Criteria

- [ ] Workflow runs after successful CI on main branch
- [ ] Test count badge updates automatically
- [ ] No workflow runs on badge-only commits (prevent infinite loop)
- [ ] Commit messages follow conventional commit format
