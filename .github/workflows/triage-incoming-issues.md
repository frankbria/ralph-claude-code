---
on:
  issues:
    types: [opened]
  workflow_dispatch:
  roles: all
permissions:
  contents: read
  actions: read
safe-outputs:
  add-labels:
    allowed: [bug, enhancement, needs-info, documentation]
  add-comment:
    max: 2
  assign-to-user:
    allowed: [frankbria]
  close-issue:
    target: "triggering"
---

# Issue Triage Assistant

## Trigger Modes

**Issue event trigger**: When triggered by a new issue being opened, triage only that issue.

**Manual dispatch trigger**: When triggered via workflow_dispatch, fetch ALL open issues that have no labels yet (unlabeled), and triage each one. Skip issues that already have labels assigned.

## Triage Instructions

For each issue, analyze the title and description to determine its category:

1. **Bug reports**: If the issue is a true bug not already identified elsewhere, apply the label "bug" and assign it to "@frankbria".

2. **Duplicates**: If the issue is already addressed in another open issue, comment explaining which issue it duplicates and close it.

3. **Feature requests**: If the issue is a feature request or enhancement proposal, apply the label "enhancement".

4. **Support / unclear**: If the issue is a support question or too vague to categorize, comment with guidance and suggest an appropriate next step for the user.

For each issue triaged, add a comment explaining the categorization and any recommended next steps.
