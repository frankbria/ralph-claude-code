#!/bin/bash

set -e

# From: https://code.claude.com/docs/en/settings#tools-available-to-claude
RESOURCE_ALL_CLAUDE_TOOLS=(
    AskUserQuestion
    Bash
    TaskOutput
    Edit
    ExitPlanMode
    Glob
    Grep
    KillShell
    MCPSearch
    NotebookEdit
    Read
    Skill
    Task
    TaskCreate
    TaskGet
    TaskList
    TaskUpdate
    # WebFetch
    WebSearch
    Write
)

RESOURCE_ALLOW_TOOLS_QUICK=("${RESOURCE_ALL_CLAUDE_TOOLS[@]}")
RESOURCE_ALLOW_TOOLS_QUICK+=(
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "Bash(java *)"
    "Bash(jq *)"
    "Bash(sed *)"
    "Bash(tr *)"
    "Bash(head *)"
    "Bash(cat *)"
)
