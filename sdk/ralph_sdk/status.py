"""Ralph status management — reads/writes status.json compatible with bash loop."""

from __future__ import annotations

import asyncio
import json
import os
import time
from enum import Enum
from pathlib import Path
from typing import TYPE_CHECKING, Any

from pydantic import BaseModel, ConfigDict, Field

if TYPE_CHECKING:
    pass


class RalphLoopStatus(str, Enum):
    """Status of the Ralph loop iteration."""
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    ERROR = "ERROR"
    TIMEOUT = "TIMEOUT"
    DRY_RUN = "DRY_RUN"


class WorkType(str, Enum):
    """Type of work performed in a loop iteration."""
    UNKNOWN = "UNKNOWN"
    IMPLEMENTATION = "IMPLEMENTATION"
    TESTING = "TESTING"
    ANALYSIS = "ANALYSIS"
    PLANNING = "PLANNING"
    DEBUGGING = "DEBUGGING"
    DRY_RUN = "DRY_RUN"


class CircuitBreakerStateEnum(str, Enum):
    """Circuit breaker state values."""
    CLOSED = "CLOSED"
    HALF_OPEN = "HALF_OPEN"
    OPEN = "OPEN"


class ErrorCategory(str, Enum):
    """Categorization of errors encountered during loop execution.

    SDK-OUTPUT-2: Structured error categories for programmatic error handling.
    """
    PERMISSION_DENIED = "PERMISSION_DENIED"
    TIMEOUT = "TIMEOUT"
    PARSE_FAILURE = "PARSE_FAILURE"
    TOOL_UNAVAILABLE = "TOOL_UNAVAILABLE"
    SYSTEM_CRASH = "SYSTEM_CRASH"
    RATE_LIMITED = "RATE_LIMITED"
    UNKNOWN = "UNKNOWN"


_EXCEPTION_CATEGORIES: tuple[tuple[type[BaseException], ErrorCategory], ...] = (
    (TimeoutError, ErrorCategory.TIMEOUT),
    (asyncio.TimeoutError, ErrorCategory.TIMEOUT),
    (PermissionError, ErrorCategory.PERMISSION_DENIED),
    (FileNotFoundError, ErrorCategory.TOOL_UNAVAILABLE),
    (json.JSONDecodeError, ErrorCategory.PARSE_FAILURE),
    (ValueError, ErrorCategory.PARSE_FAILURE),
)

_EXIT_CODE_CATEGORIES: dict[int, ErrorCategory] = {
    124: ErrorCategory.TIMEOUT,            # Standard Unix timeout
    126: ErrorCategory.PERMISSION_DENIED,  # Cannot execute
    127: ErrorCategory.TOOL_UNAVAILABLE,   # Command not found
    137: ErrorCategory.SYSTEM_CRASH,       # SIGKILL
    139: ErrorCategory.SYSTEM_CRASH,       # SIGSEGV
}

_OUTPUT_SENTINELS: tuple[tuple[ErrorCategory, tuple[str, ...]], ...] = (
    (ErrorCategory.RATE_LIMITED, ("rate limit", "rate_limit", "429", "too many requests")),
    (ErrorCategory.PERMISSION_DENIED, ("permission denied", "access denied", "eacces")),
    (ErrorCategory.TIMEOUT, ("timeout", "timed out", "deadline exceeded")),
    (ErrorCategory.TOOL_UNAVAILABLE, ("tool not available", "tool_unavailable", "unknown tool")),
    (ErrorCategory.SYSTEM_CRASH, ("segfault", "core dumped", "fatal error", "panic")),
    (ErrorCategory.PARSE_FAILURE, ("json", "parse error", "unexpected token", "decode")),
)


def _classify_exception(exception: BaseException) -> ErrorCategory | None:
    for exc_type, category in _EXCEPTION_CATEGORIES:
        if isinstance(exception, exc_type):
            return category
    return None


def _classify_exit_code(exit_code: int) -> ErrorCategory | None:
    return _EXIT_CODE_CATEGORIES.get(exit_code)


def _classify_output(output: str) -> ErrorCategory | None:
    output_lower = output.lower()
    for category, sentinels in _OUTPUT_SENTINELS:
        if any(s in output_lower for s in sentinels):
            return category
    return None


def classify_error(
    exit_code: int | None = None,
    output: str = "",
    exception: BaseException | None = None,
) -> ErrorCategory:
    """Classify an error into an ErrorCategory based on exit code, output, and exception type.

    SDK-OUTPUT-2: Deterministic classification helper — no ML, no heuristics on
    freeform text beyond known sentinel strings from the CLI.
    """
    if exception is not None and (cat := _classify_exception(exception)) is not None:
        return cat
    if exit_code is not None and (cat := _classify_exit_code(exit_code)) is not None:
        return cat
    if (cat := _classify_output(output)) is not None:
        return cat
    if (exit_code is not None and exit_code != 0) or exception is not None:
        return ErrorCategory.UNKNOWN
    return ErrorCategory.UNKNOWN


class RalphStatus(BaseModel):
    """Structured status compatible with on-stop.sh -> status.json format."""

    model_config = ConfigDict(validate_assignment=True)

    work_type: WorkType = WorkType.UNKNOWN
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: RalphLoopStatus = RalphLoopStatus.IN_PROGRESS
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    correlation_id: str = ""
    error: str = ""
    error_category: ErrorCategory | None = None

    # SDK-LIFECYCLE-3: Permission denial events detected during iteration.
    # Typed as list[Any] at runtime to avoid circular import with parsing.py;
    # at type-check time the annotation resolves to list[PermissionDenialEvent].
    permission_denials: list[Any] = Field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary matching status.json schema."""
        d = {
            "WORK_TYPE": self.work_type.value,
            "COMPLETED_TASK": self.completed_task,
            "NEXT_TASK": self.next_task,
            "PROGRESS_SUMMARY": self.progress_summary,
            "EXIT_SIGNAL": self.exit_signal,
            "status": self.status.value,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "circuit_breaker_state": self.circuit_breaker_state,
            "correlation_id": self.correlation_id,
            "error": self.error,
        }
        if self.error_category is not None:
            d["error_category"] = self.error_category.value
        if self.permission_denials:
            d["permission_denials"] = [
                pd.model_dump() if hasattr(pd, "model_dump") else pd
                for pd in self.permission_denials
            ]
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
        """Create from status.json dictionary."""
        error_cat_raw = data.get("error_category")
        error_cat: ErrorCategory | None = None
        if error_cat_raw is not None:
            try:
                error_cat = ErrorCategory(error_cat_raw)
            except ValueError:
                error_cat = ErrorCategory.UNKNOWN
        return cls(
            work_type=data.get("WORK_TYPE", "UNKNOWN"),
            completed_task=data.get("COMPLETED_TASK", ""),
            next_task=data.get("NEXT_TASK", ""),
            progress_summary=data.get("PROGRESS_SUMMARY", ""),
            exit_signal=data.get("EXIT_SIGNAL", False),
            status=data.get("status", "IN_PROGRESS"),
            timestamp=data.get("timestamp", ""),
            loop_count=data.get("loop_count", 0),
            session_id=data.get("session_id", ""),
            circuit_breaker_state=data.get("circuit_breaker_state", "CLOSED"),
            correlation_id=data.get("correlation_id", ""),
            error=data.get("error", ""),
            error_category=error_cat,
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> RalphStatus:
        """Load status from .ralph/status.json or via state backend.

        Note: When using an async backend, use load_async() instead.
        This method only supports sync file reads (no backend).
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                # Already in async context — caller must use load_async()
                raise RuntimeError(
                    "Cannot call sync load() with async backend from async context. "
                    "Use load_async() instead."
                )
            data = asyncio.run(backend.read_status())
            return cls.from_dict(data) if data else cls()

        status_file = Path(ralph_dir) / "status.json"
        if not status_file.exists():
            return cls()
        try:
            data = json.loads(status_file.read_text(encoding="utf-8"))
            return cls.from_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> None:
        """Write status atomically to .ralph/status.json or via state backend.

        Note: When using an async backend, use save_async() instead.
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync save() with async backend from async context. "
                    "Use save_async() instead."
                )
            asyncio.run(backend.write_status(self.to_dict()))
            return

        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        status_file = ralph_dir / "status.json"
        tmp_file = status_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps(self.to_dict(), indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(status_file)
        finally:
            # Clean up temp file if replace failed (WSL/NTFS compat)
            tmp_file.unlink(missing_ok=True)


class CircuitBreakerState(BaseModel):
    """Circuit breaker state compatible with .circuit_breaker_state JSON."""

    model_config = ConfigDict(validate_assignment=True)

    state: CircuitBreakerStateEnum = CircuitBreakerStateEnum.CLOSED
    no_progress_count: int = 0
    same_error_count: int = 0
    last_error: str = ""
    opened_at: str = ""
    last_transition: str = ""

    def _to_state_dict(self) -> dict[str, Any]:
        """Export as dictionary for state backend."""
        return {
            "state": self.state.value,
            "no_progress_count": self.no_progress_count,
            "same_error_count": self.same_error_count,
            "last_error": self.last_error,
            "opened_at": self.opened_at,
            "last_transition": self.last_transition,
        }

    @classmethod
    def _from_state_dict(cls, data: dict[str, Any]) -> CircuitBreakerState:
        """Create from state dict."""
        return cls(
            state=data.get("state", "CLOSED"),
            no_progress_count=data.get("no_progress_count", 0),
            same_error_count=data.get("same_error_count", 0),
            last_error=data.get("last_error", ""),
            opened_at=data.get("opened_at", ""),
            last_transition=data.get("last_transition", ""),
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> CircuitBreakerState:
        """Load from .ralph/.circuit_breaker_state or via state backend.

        Note: When using an async backend, use asyncio.run() or call backend directly.
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync load() with async backend from async context."
                )
            data = asyncio.run(backend.read_circuit_breaker())
            return cls._from_state_dict(data) if data else cls()

        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        if not cb_file.exists():
            return cls()
        try:
            data = json.loads(cb_file.read_text(encoding="utf-8"))
            return cls._from_state_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> None:
        """Write circuit breaker state atomically or via state backend."""
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync save() with async backend from async context."
                )
            asyncio.run(backend.write_circuit_breaker(self._to_state_dict()))
            return

        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        cb_file = ralph_dir / ".circuit_breaker_state"
        tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps(self._to_state_dict(), indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(cb_file)
        finally:
            tmp_file.unlink(missing_ok=True)

    def trip(self, reason: str = "") -> None:
        """Transition to OPEN state."""
        self.state = CircuitBreakerStateEnum.OPEN
        self.opened_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.last_error = reason
        self.last_transition = f"OPEN: {reason}"

    def half_open(self) -> None:
        """Transition to HALF_OPEN (cooldown expired)."""
        self.state = CircuitBreakerStateEnum.HALF_OPEN
        self.last_transition = "HALF_OPEN: cooldown expired"

    def close(self) -> None:
        """Transition to CLOSED (recovery successful)."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = "CLOSED: recovery successful"

    def reset(self, reason: str = "manual") -> None:
        """Reset to initial state."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = f"RESET: {reason}"
