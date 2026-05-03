"""Ralph SDK structured response parsing — 3-strategy parse chain.

Strategies (tried in order):
1. JSON fenced code block — structured output from agent
2. JSONL stream result — from Claude CLI --output-format json
3. Text fallback — regex extraction of RALPH_STATUS fields
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from pydantic import BaseModel, field_validator

from ralph_sdk.status import RalphLoopStatus, RalphStatus, WorkType

logger = logging.getLogger("ralph.sdk.parsing")


class TestsStatus(str, __import__("enum").Enum):
    """Status of test execution."""
    UNKNOWN = "UNKNOWN"
    PASSED = "PASSED"
    FAILED = "FAILED"
    SKIPPED = "SKIPPED"
    DEFERRED = "DEFERRED"


class RalphStatusBlock(BaseModel):
    """Structured status block parsed from agent response.

    This is the expected JSON output format from the agent, containing
    all status fields plus a version marker.
    """
    version: int = 1
    work_type: WorkType = WorkType.UNKNOWN
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    tests_status: TestsStatus = TestsStatus.UNKNOWN

    @field_validator("exit_signal", mode="before")
    @classmethod
    def coerce_exit_signal(cls, v: Any) -> bool:
        """Coerce EXIT_SIGNAL from various truthy representations."""
        if isinstance(v, bool):
            return v
        if isinstance(v, str):
            return v.lower() in ("true", "yes", "1")
        if isinstance(v, (int, float)):
            return bool(v)
        return False

    def to_ralph_status(self) -> RalphStatus:
        """Convert to RalphStatus for backward compatibility."""
        return RalphStatus(
            work_type=self.work_type,
            completed_task=self.completed_task,
            next_task=self.next_task,
            progress_summary=self.progress_summary,
            exit_signal=self.exit_signal,
            status=RalphLoopStatus.COMPLETED if self.exit_signal else RalphLoopStatus.IN_PROGRESS,
        )


def parse_ralph_status(text: str) -> RalphStatus:
    """Parse response text using 3-strategy chain.

    1. JSON fenced block: ```json { "work_type": ... } ```
    2. JSONL result: {"type": "result", "result": "..."}
    3. Text fallback: WORK_TYPE: ... regex extraction
    """
    # Strategy 1: JSON fenced code block
    status = _parse_json_block(text)
    if status is not None:
        logger.debug("Parsed via JSON block strategy")
        return status

    # Strategy 2: JSONL result object
    status = _parse_jsonl_result(text)
    if status is not None:
        logger.debug("Parsed via JSONL strategy")
        return status

    # Strategy 3: Text fallback
    logger.debug("Falling back to text extraction")
    return _parse_text_fallback(text)


def _parse_json_block(text: str) -> RalphStatus | None:
    """Strategy 1: Extract JSON from fenced code block."""
    # Match ```json ... ``` or ``` ... ```
    pattern = r'```(?:json)?\s*\n({[^`]+})\s*\n```'
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        return None

    try:
        data = json.loads(match.group(1))
        # Normalize keys to lowercase
        normalized = {k.lower(): v for k, v in data.items()}
        block = RalphStatusBlock(**normalized)
        return block.to_ralph_status()
    except (json.JSONDecodeError, Exception) as e:
        logger.debug("JSON block parse failed: %s", e)
        return None


def _parse_jsonl_result(text: str) -> RalphStatus | None:
    """Strategy 2: Extract from JSONL stream result object."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                result_text = obj.get("result", "")
                if isinstance(result_text, str):
                    # Try JSON block within the result text
                    status = _parse_json_block(result_text)
                    if status is not None:
                        return status
                    # Fall through to text extraction on the result text
                    return _parse_text_fallback(result_text)
        except json.JSONDecodeError:
            continue
    return None


def _parse_text_fallback(text: str) -> RalphStatus:
    """Strategy 3: Regex extraction of RALPH_STATUS fields."""
    # Auto-unescape JSON-encoded \n (matching STREAM-3)
    text = text.replace("\\n", "\n")

    status = RalphStatus()

    field_patterns = {
        "work_type": r"WORK_TYPE:\s*(.+?)(?:\n|$)",
        "completed_task": r"COMPLETED_TASK:\s*(.+?)(?:\n|$)",
        "next_task": r"NEXT_TASK:\s*(.+?)(?:\n|$)",
        "progress_summary": r"PROGRESS_SUMMARY:\s*(.+?)(?:\n|$)",
        "exit_signal": r"EXIT_SIGNAL:\s*(.+?)(?:\n|$)",
    }

    for field_name, pattern in field_patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            value = match.group(1).strip()
            if field_name == "exit_signal":
                status.exit_signal = value.lower() in ("true", "yes", "1")
            elif field_name == "work_type":
                try:
                    status.work_type = WorkType(value.upper())
                except ValueError:
                    status.work_type = WorkType.UNKNOWN
            else:
                setattr(status, field_name, value)

    return status


def _handle_multi_result_jsonl(text: str) -> list[RalphStatus]:
    """Handle JSONL with multiple result objects (subagent filtering)."""
    results = []
    for line in text.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                result_text = obj.get("result", "")
                if isinstance(result_text, str):
                    status = _parse_text_fallback(result_text)
                    results.append(status)
        except json.JSONDecodeError:
            continue
    return results


# =============================================================================
# SDK-LIFECYCLE-3: Permission Denial Detection
# =============================================================================

# Patterns that indicate a user-fixable permission denial (bash command blocked
# by ALLOWED_TOOLS).  The user can resolve these by adding the tool to the
# allowed list.
_USER_FIXABLE_PATTERNS: list[re.Pattern[str]] = [
    re.compile(
        r"(?:tool|command)\s+(?:is\s+)?not\s+(?:allowed|permitted|in\s+allowed)",
        re.IGNORECASE,
    ),
    re.compile(
        r"Bash\(([^)]+)\)\s+(?:is\s+)?(?:not\s+allowed|blocked|denied)",
        re.IGNORECASE,
    ),
    re.compile(
        r"permission\s+denied.*?(?:Bash|tool)\s*\(",
        re.IGNORECASE,
    ),
    re.compile(
        r"not\s+in\s+(?:the\s+)?(?:allowed|permitted)\s+tools?\s+list",
        re.IGNORECASE,
    ),
]

# Patterns that indicate a scope-locked denial (built-in tool filesystem
# boundary, sandbox restriction).  These cannot be fixed by the user through
# config alone.
_SCOPE_LOCKED_PATTERNS: list[re.Pattern[str]] = [
    re.compile(
        r"outside\s+(?:the\s+)?(?:allowed|permitted)\s+(?:directory|directories|path|workspace)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:cannot|can't)\s+(?:access|read|write|modify)\s+files?\s+outside",
        re.IGNORECASE,
    ),
    re.compile(
        r"filesystem\s+(?:boundary|restriction|sandbox)",
        re.IGNORECASE,
    ),
    re.compile(
        r"path\s+(?:is\s+)?(?:not\s+allowed|restricted|blocked)",
        re.IGNORECASE,
    ),
]

# General permission denial indicators — used to detect that the message is
# about a denial in the first place.
_DENIAL_INDICATORS: list[re.Pattern[str]] = [
    re.compile(r"permission\s+denied", re.IGNORECASE),
    re.compile(
        r"(?:tool|command)\s+(?:was\s+)?(?:denied|blocked|rejected|not\s+allowed)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:cannot|can't|unable\s+to)\s+(?:use|run|execute|invoke)\s+(?:tool|command)",
        re.IGNORECASE,
    ),
]

# Pattern to extract tool name from denial messages.
_TOOL_NAME_PATTERN = re.compile(
    r"(?:tool|command)\s+[`'\"]?(\w+(?:\([^)]*\))?)[`'\"]?",
    re.IGNORECASE,
)


class PermissionDenialEvent(BaseModel):
    """A detected permission denial from Claude CLI output.

    Attributes:
        tool_name: The tool or command that was denied (e.g. ``"Bash(npm test)"``).
        denied_pattern: The pattern category that matched — one of
            ``"user_fixable"``, ``"scope_locked"``, or ``"unknown"``.
        is_user_fixable: True if the denial can be resolved by adding the tool
            to ``ALLOWED_TOOLS``; False for built-in filesystem boundary
            restrictions.
        raw_message: The raw line or message fragment containing the denial
            (truncated to 500 chars).
    """
    tool_name: str = ""
    denied_pattern: str = ""
    is_user_fixable: bool = False
    raw_message: str = ""


def detect_permission_denials(output: str) -> list[PermissionDenialEvent]:
    """Parse Claude's JSONL output for permission denial messages.

    Scans both raw text lines and JSONL ``result`` / ``content`` fields for
    denial indicators, then classifies each as user-fixable or scope-locked.

    Args:
        output: Raw stdout from the Claude CLI (may be JSONL or plain text).

    Returns:
        A deduplicated list of :class:`PermissionDenialEvent` instances.
    """
    denial_lines: list[str] = []

    # Collect candidate lines from JSONL content/result fields and raw text.
    for line in output.strip().splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        # Try JSONL parsing to extract nested text
        try:
            obj = json.loads(stripped)
            # result objects
            if obj.get("type") == "result":
                result_text = obj.get("result", "")
                if isinstance(result_text, str):
                    denial_lines.append(result_text)
            # content block text
            elif obj.get("type") in (
                "assistant", "content_block_delta", "content_block_stop",
            ):
                content = obj.get("content", "")
                if isinstance(content, str):
                    denial_lines.append(content)
                elif isinstance(content, list):
                    for item in content:
                        if isinstance(item, dict) and item.get("type") == "text":
                            denial_lines.append(item.get("text", ""))
            # Also check for error messages
            if obj.get("is_error"):
                error_text = obj.get("error", obj.get("result", ""))
                if isinstance(error_text, str):
                    denial_lines.append(error_text)
        except (json.JSONDecodeError, TypeError):
            # Not JSON — treat as raw text
            denial_lines.append(stripped)

    events: list[PermissionDenialEvent] = []
    seen_messages: set[str] = set()

    for text in denial_lines:
        # Check if this text contains any denial indicator
        has_denial = any(p.search(text) for p in _DENIAL_INDICATORS)
        if not has_denial:
            # Also check user-fixable and scope-locked patterns directly
            has_denial = (
                any(p.search(text) for p in _USER_FIXABLE_PATTERNS)
                or any(p.search(text) for p in _SCOPE_LOCKED_PATTERNS)
            )
        if not has_denial:
            continue

        # Deduplicate on the first 200 characters of the raw message
        dedup_key = text[:200]
        if dedup_key in seen_messages:
            continue
        seen_messages.add(dedup_key)

        # Classify: user-fixable vs scope-locked
        is_user_fixable = any(p.search(text) for p in _USER_FIXABLE_PATTERNS)
        is_scope_locked = any(p.search(text) for p in _SCOPE_LOCKED_PATTERNS)

        if is_scope_locked and not is_user_fixable:
            denied_pattern = "scope_locked"
            fixable = False
        elif is_user_fixable:
            denied_pattern = "user_fixable"
            fixable = True
        else:
            denied_pattern = "unknown"
            fixable = False

        # Extract tool name
        tool_name = ""
        tool_match = _TOOL_NAME_PATTERN.search(text)
        if tool_match:
            tool_name = tool_match.group(1)

        events.append(PermissionDenialEvent(
            tool_name=tool_name,
            denied_pattern=denied_pattern,
            is_user_fixable=fixable,
            raw_message=text[:500],  # Truncate to avoid huge messages
        ))

    return events


# ---------------------------------------------------------------------------
# SDK-OUTPUT-1: Structured files_changed extraction from JSONL tool_use
# ---------------------------------------------------------------------------

# Tool names whose `file_path` input parameter represents a changed file
_FILE_CHANGE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Pattern matching ``git add <path>`` arguments inside a Bash command string.
# Handles both ``Bash(git add ...)`` and plain ``git add ...`` invocations.
_GIT_ADD_PATTERN = re.compile(
    r"git\s+add\s+(?:-[A-Za-z]+\s+)*(.+)",
    re.IGNORECASE,
)

# Pattern matching ``git diff --name-only`` output lines (plain file paths,
# one per line).  Used to extract paths from tool_result content.
_DIFF_NAME_ONLY_TRIGGER = re.compile(
    r"git\s+diff\s+.*--name-only",
    re.IGNORECASE,
)


def extract_files_changed(text: str) -> list[str]:
    """Extract unique file paths from Claude JSONL output.

    Uses three complementary strategies:

    1. **Write/Edit/MultiEdit tool_use** — extracts ``file_path`` from the
       ``input`` dict of structured tool_use JSONL records.
    2. **Bash(git add) tool_use** — parses the ``command`` input of Bash
       tool_use records for ``git add <path>`` invocations.
    3. **git diff --name-only output** — when a Bash tool_use command
       contains ``git diff --name-only``, parses the corresponding
       ``tool_result`` content for file paths (one per line).

    Returns a deduplicated ``list[str]`` of file paths in first-seen order.
    """
    seen: dict[str, None] = {}  # ordered dict for dedup + order preservation

    # Track whether the last Bash tool_use was a ``git diff --name-only``
    # command, so we can harvest paths from the subsequent tool_result.
    _awaiting_diff_result = False

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        obj_type = obj.get("type", "")

        # ----- Strategy 3 (cont.): Harvest git diff --name-only results -----
        if _awaiting_diff_result and obj_type == "tool_result":
            _awaiting_diff_result = False
            result_content = obj.get("content", "")
            if isinstance(result_content, str):
                for diff_line in result_content.splitlines():
                    path = diff_line.strip()
                    if path and not path.startswith(("diff ", "index ", "---", "+++")):
                        seen.setdefault(path, None)
            continue

        if obj_type != "tool_use":
            # Reset diff-result tracking if we see a non-tool_use, non-tool_result
            if obj_type != "tool_result":
                _awaiting_diff_result = False
            continue

        tool_name = obj.get("name", "")
        tool_input = obj.get("input")
        if not isinstance(tool_input, dict):
            continue

        # ----- Strategy 1: Write / Edit / MultiEdit -----
        if tool_name in _FILE_CHANGE_TOOLS:
            file_path = tool_input.get("file_path")
            if isinstance(file_path, str) and file_path:
                seen.setdefault(file_path, None)
            continue

        # ----- Strategy 2: Bash(git add ...) -----
        if tool_name == "Bash":
            command = tool_input.get("command", "")
            if isinstance(command, str):
                git_add_match = _GIT_ADD_PATTERN.search(command)
                if git_add_match:
                    raw_paths = git_add_match.group(1).strip()
                    # Split on whitespace, but skip glob-only args like "."
                    for token in raw_paths.split():
                        token = token.strip("'\"")
                        if token and token not in (".", "-A", "--all", "-u", "--update"):
                            seen.setdefault(token, None)

                # ----- Strategy 3: Bash(git diff --name-only) -----
                if _DIFF_NAME_ONLY_TRIGGER.search(command):
                    _awaiting_diff_result = True

    return list(seen)
