"""Ralph SDK custom tools — expose reliability features as Agent SDK tools.

These tools replace RALPH_STATUS text block parsing with structured tool calls
when running in SDK mode. CLI mode continues to use text-based approach.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any


async def ralph_status_tool(
    work_type: str = "UNKNOWN",
    completed_task: str = "",
    next_task: str = "",
    progress_summary: str = "",
    exit_signal: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Report status at end of each loop iteration.

    Called by the agent instead of writing a RALPH_STATUS text block.
    Writes to status.json in the same format as on-stop.sh hook.

    Args:
        work_type: IMPLEMENTATION, TESTING, ANALYSIS, PLANNING, DEBUGGING, UNKNOWN
        completed_task: Description of work completed this iteration.
        next_task: What should be done next iteration.
        progress_summary: Brief summary of overall progress.
        exit_signal: True if all work is complete and loop should exit.
        ralph_dir: Path to .ralph directory.

    Returns:
        Confirmation dict with the written status.
    """
    from ralph_sdk.status import RalphStatus

    status = RalphStatus.load(ralph_dir)
    status.work_type = work_type
    status.completed_task = completed_task
    status.next_task = next_task
    status.progress_summary = progress_summary
    status.exit_signal = exit_signal
    status.timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    status.status = "COMPLETED" if exit_signal else "IN_PROGRESS"
    status.save(ralph_dir)

    return {
        "ok": True,
        "status": status.to_dict(),
        "message": f"Status updated: {work_type} — exit_signal={exit_signal}",
    }


async def ralph_rate_check_tool(
    ralph_dir: str = ".ralph",
    max_calls_per_hour: int = 100,
) -> dict[str, Any]:
    """Check current rate limit status.

    Reads .call_count and .last_reset to determine remaining budget.

    Args:
        ralph_dir: Path to .ralph directory.
        max_calls_per_hour: Maximum calls allowed per hour.

    Returns:
        Rate limit status with remaining calls and reset time.
    """
    ralph_path = Path(ralph_dir)
    call_count_file = ralph_path / ".call_count"
    last_reset_file = ralph_path / ".last_reset"

    call_count = 0
    last_reset = 0

    if call_count_file.exists():
        try:
            call_count = int(call_count_file.read_text().strip())
        except (ValueError, OSError):
            pass

    if last_reset_file.exists():
        try:
            last_reset = int(last_reset_file.read_text().strip())
        except (ValueError, OSError):
            pass

    now = int(time.time())
    elapsed = now - last_reset if last_reset > 0 else 3600

    # If the hour has elapsed, counter is effectively reset
    if elapsed >= 3600:
        remaining = max_calls_per_hour
        reset_in = 0
        call_count = 0
    else:
        remaining = max(0, max_calls_per_hour - call_count)
        reset_in = max(0, 3600 - elapsed)

    return {
        "ok": True,
        "calls_used": call_count,
        "calls_remaining": remaining,
        "max_calls_per_hour": max_calls_per_hour,
        "reset_in_seconds": reset_in,
        "rate_limited": remaining <= 0,
    }


async def ralph_circuit_state_tool(
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Get current circuit breaker state.

    Reads .circuit_breaker_state to determine if loop should continue.

    Args:
        ralph_dir: Path to .ralph directory.

    Returns:
        Circuit breaker state information.
    """
    from ralph_sdk.status import CircuitBreakerState

    cb = CircuitBreakerState.load(ralph_dir)
    return {
        "ok": True,
        "state": cb.state.value,
        "no_progress_count": cb.no_progress_count,
        "same_error_count": cb.same_error_count,
        "last_error": cb.last_error,
        "opened_at": cb.opened_at,
        "can_proceed": cb.state.value in ("CLOSED", "HALF_OPEN"),
    }


async def ralph_task_update_tool(
    task_description: str,
    completed: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Update task status in fix_plan.md.

    Marks a checkbox item as complete or adds a new task.

    Args:
        task_description: The task text (without checkbox prefix).
        completed: Whether to mark as complete (checked).
        ralph_dir: Path to .ralph directory.

    Returns:
        Confirmation of the update.
    """
    fix_plan_path = Path(ralph_dir) / "fix_plan.md"
    if not fix_plan_path.exists():
        return {"ok": False, "error": "fix_plan.md not found"}

    content = fix_plan_path.read_text(encoding="utf-8")
    lines = content.splitlines()
    updated = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        # Match "- [ ] task" or "- [x] task" patterns
        if task_description in stripped:
            if completed:
                lines[i] = line.replace("- [ ]", "- [x]")
            else:
                lines[i] = line.replace("- [x]", "- [ ]")
            updated = True
            break

    if updated:
        fix_plan_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {
            "ok": True,
            "task": task_description,
            "completed": completed,
            "message": f"Task {'completed' if completed else 'reopened'}: {task_description}",
        }

    return {
        "ok": False,
        "error": f"Task not found in fix_plan.md: {task_description}",
    }


# Tool definitions for Agent SDK registration
RALPH_TOOLS = [
    {
        "name": "ralph_status",
        "description": "Report status at end of each loop iteration. Use instead of RALPH_STATUS text block.",
        "input_schema": {
            "type": "object",
            "properties": {
                "work_type": {
                    "type": "string",
                    "enum": ["IMPLEMENTATION", "TESTING", "ANALYSIS", "PLANNING", "DEBUGGING", "UNKNOWN"],
                    "description": "Type of work performed this iteration.",
                },
                "completed_task": {
                    "type": "string",
                    "description": "Description of work completed.",
                },
                "next_task": {
                    "type": "string",
                    "description": "What should be done next.",
                },
                "progress_summary": {
                    "type": "string",
                    "description": "Brief summary of overall progress.",
                },
                "exit_signal": {
                    "type": "boolean",
                    "description": "True if all work is complete and loop should exit.",
                },
            },
            "required": ["work_type", "completed_task", "progress_summary", "exit_signal"],
        },
        "handler": ralph_status_tool,
    },
    {
        "name": "ralph_rate_check",
        "description": "Check current API rate limit status — calls used, remaining, reset time.",
        "input_schema": {
            "type": "object",
            "properties": {},
        },
        "handler": ralph_rate_check_tool,
    },
    {
        "name": "ralph_circuit_state",
        "description": "Get circuit breaker state — whether loop can proceed or is tripped.",
        "input_schema": {
            "type": "object",
            "properties": {},
        },
        "handler": ralph_circuit_state_tool,
    },
    {
        "name": "ralph_task_update",
        "description": "Mark a task as complete or reopen it in fix_plan.md.",
        "input_schema": {
            "type": "object",
            "properties": {
                "task_description": {
                    "type": "string",
                    "description": "The task text (without checkbox prefix).",
                },
                "completed": {
                    "type": "boolean",
                    "description": "True to mark complete, false to reopen.",
                },
            },
            "required": ["task_description", "completed"],
        },
        "handler": ralph_task_update_tool,
    },
]
