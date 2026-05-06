"""Standalone models and helpers used by ralph_sdk.agent.

Split out from agent.py to keep the agent module focused on RalphAgent itself.
Re-exported from ralph_sdk.agent so existing imports continue to work.
"""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from pydantic import BaseModel, Field, field_validator

from ralph_sdk.config import RalphConfig
from ralph_sdk.status import RalphStatus

__all__ = [
    "DecompositionHint",
    "IterationRecord",
    "detect_decomposition_needed",
    "TracerProtocol",
    "RalphAgentInterface",
    "TaskInput",
    "TaskResult",
    "ProgressSnapshot",
    "ContinueAsNewState",
    "CancelResult",
    "compute_adaptive_timeout",
]


# ---------------------------------------------------------------------------
# SDK-SAFETY-2: Task Decomposition Detection
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DecompositionHint:
    """Hint that a task should be decomposed into smaller sub-tasks."""

    should_decompose: bool = False
    reason: str = ""
    suggested_split: int = 1
    factors: dict[str, bool] = field(default_factory=dict)


@dataclass
class IterationRecord:
    """Record of a single iteration's key metrics for history tracking."""

    loop_count: int = 0
    files_modified: int = 0
    tasks_completed: int = 0
    timed_out: bool = False
    complexity: int = 0
    file_count: int = 0
    had_progress: bool = False


def _estimate_file_count(status: RalphStatus) -> int:
    """Count distinct file paths referenced in next_task / progress_summary."""
    text = f"{status.next_task} {status.progress_summary}"
    file_patterns = re.findall(
        r'(?:^|[\s,])([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,10})(?:[\s,]|$)',
        text,
    )
    return len(set(file_patterns))


_HIGH_COMPLEXITY_KEYWORDS = (
    "refactor", "architect", "redesign", "migration", "overhaul",
    "rewrite", "breaking change", "cross-cutting",
)
_MEDIUM_COMPLEXITY_KEYWORDS = (
    "implement", "integrate", "complex", "multiple", "several",
    "significant", "extensive", "large",
)


def _estimate_complexity(status: RalphStatus) -> int:
    """Estimate task complexity from status text on a 1-5 scale."""
    text = f"{status.next_task} {status.progress_summary}".lower()
    complexity = 1
    if any(k in text for k in _HIGH_COMPLEXITY_KEYWORDS):
        complexity += 2
    if any(k in text for k in _MEDIUM_COMPLEXITY_KEYWORDS):
        complexity += 1
    file_count = _estimate_file_count(status)
    if file_count >= 8:
        complexity += 2
    elif file_count >= 4:
        complexity += 1
    return min(complexity, 5)


def _consecutive_no_progress(history: list[IterationRecord]) -> int:
    count = 0
    for record in reversed(history):
        if record.had_progress:
            break
        count += 1
    return count


def _decomposition_reasons(
    factors: dict[str, bool],
    file_count: int,
    complexity: int,
    no_progress: int,
    cfg: RalphConfig,
) -> list[str]:
    reasons: list[str] = []
    if factors["file_count"]:
        reasons.append(
            f"file_count={file_count}>={cfg.decomposition_file_count_threshold}"
        )
    if factors["previous_timeout"]:
        reasons.append("previous iteration timed out")
    if factors["complexity"]:
        reasons.append(
            f"complexity={complexity}>={cfg.decomposition_complexity_threshold}"
        )
    if factors["consecutive_no_progress"]:
        reasons.append(
            f"consecutive_no_progress={no_progress}"
            f">={cfg.decomposition_no_progress_threshold}"
        )
    return reasons


def detect_decomposition_needed(
    status: RalphStatus,
    iteration_history: list[IterationRecord],
    config: RalphConfig | None = None,
) -> DecompositionHint:
    """Detect whether the current task should be decomposed (SDK-SAFETY-2).

    Returns a DecompositionHint with should_decompose=True when 2+ of the
    4 factors (file_count, previous_timeout, complexity, no_progress) trip.
    """
    cfg = config or RalphConfig()
    file_count = _estimate_file_count(status)
    complexity = _estimate_complexity(status)
    no_progress = _consecutive_no_progress(iteration_history)
    previous_timeout = bool(iteration_history and iteration_history[-1].timed_out)

    factors = {
        "file_count": file_count >= cfg.decomposition_file_count_threshold,
        "previous_timeout": previous_timeout,
        "complexity": complexity >= cfg.decomposition_complexity_threshold,
        "consecutive_no_progress": no_progress >= cfg.decomposition_no_progress_threshold,
    }
    active_count = sum(1 for v in factors.values() if v)

    if active_count < 2:
        return DecompositionHint(factors=factors)

    reasons = _decomposition_reasons(factors, file_count, complexity, no_progress, cfg)
    suggested_split = max(2, file_count // cfg.decomposition_file_count_threshold + 1)
    suggested_split = min(suggested_split, 5)

    return DecompositionHint(
        should_decompose=True,
        reason=f"Decomposition recommended ({active_count}/4 factors): {'; '.join(reasons)}",
        suggested_split=suggested_split,
        factors=factors,
    )


# ---------------------------------------------------------------------------
# Abstract interfaces (SDK-3: Hybrid Architecture)
# ---------------------------------------------------------------------------


class TracerProtocol(Protocol):
    """Minimal OpenTelemetry-style tracer surface used by the agent.

    Protocol method parameters are prefixed with ``_`` to silence the
    vulture unused-name check; concrete implementations name them freely.
    """

    def start_as_current_span(self, _name: str) -> Any: ...


class RalphAgentInterface(Protocol):
    """Abstract interface for Ralph agent implementations (CLI and SDK)."""

    async def run_iteration(
        self, _prompt: str, _context: dict[str, Any]
    ) -> RalphStatus:
        """Execute a single loop iteration."""
        ...

    async def should_exit(
        self, _status: RalphStatus, _loop_count: int
    ) -> bool:
        """Evaluate exit conditions (dual-condition gate)."""
        ...

    async def check_rate_limit(self) -> bool:
        """Check if within rate limits. Returns True if OK to proceed."""
        ...

    async def check_circuit_breaker(self) -> bool:
        """Check circuit breaker state. Returns True if OK to proceed."""
        ...


# ---------------------------------------------------------------------------
# Task input/output (SDK-3: TheStudio compatibility)
# ---------------------------------------------------------------------------


class TaskInput(BaseModel, frozen=True):
    """Union type for task input — handles fix_plan.md and TheStudio TaskPackets."""

    prompt: str = ""
    fix_plan: str = ""
    agent_instructions: str = ""
    task_packet_id: str = ""
    task_packet_type: str = ""
    task_packet_payload: dict[str, Any] = Field(default_factory=dict)

    @field_validator("prompt")
    @classmethod
    def validate_prompt(cls, v: str) -> str:
        return v

    @field_validator("task_packet_payload")
    @classmethod
    def validate_payload(cls, v: dict[str, Any]) -> dict[str, Any]:
        return v

    @classmethod
    def from_ralph_dir(cls, ralph_dir: str | Path = ".ralph") -> TaskInput:
        """Load task input from .ralph/ directory (standalone mode)."""
        ralph_path = Path(ralph_dir)
        prompt = fix_plan = agent_instructions = ""

        prompt_file = ralph_path / "PROMPT.md"
        if prompt_file.exists():
            prompt = prompt_file.read_text(encoding="utf-8")

        fix_plan_file = ralph_path / "fix_plan.md"
        if fix_plan_file.exists():
            fix_plan = fix_plan_file.read_text(encoding="utf-8")

        agent_file = ralph_path / "AGENT.md"
        if agent_file.exists():
            agent_instructions = agent_file.read_text(encoding="utf-8")

        return cls(
            prompt=prompt,
            fix_plan=fix_plan,
            agent_instructions=agent_instructions,
        )

    @classmethod
    def from_task_packet(cls, packet: dict[str, Any]) -> TaskInput:
        """Load task input from TheStudio TaskPacket."""
        return cls(
            prompt=packet.get("prompt", ""),
            fix_plan=packet.get("fix_plan", ""),
            agent_instructions=packet.get("agent_instructions", ""),
            task_packet_id=packet.get("id", ""),
            task_packet_type=packet.get("type", ""),
            task_packet_payload=packet,
        )


class TaskResult(BaseModel):
    """Output compatible with status.json and TheStudio signals."""

    status: RalphStatus = Field(default_factory=RalphStatus)
    exit_code: int = 0
    output: str = ""
    error: str = ""
    loop_count: int = 0
    duration_seconds: float = 0.0
    tokens_in: int = 0
    tokens_out: int = 0
    files_changed: list[str] = Field(default_factory=list)
    total_cost_usd: float = 0.0

    def to_signal(self) -> dict[str, Any]:
        """Convert to TheStudio-compatible signal format."""
        return {
            "type": "ralph_result",
            "task_result": self.status.to_dict(),
            "exit_code": self.exit_code,
            "output": self.output,
            "error": self.error,
            "loop_count": self.loop_count,
            "duration_seconds": self.duration_seconds,
            "tokens_in": self.tokens_in,
            "tokens_out": self.tokens_out,
            "files_changed": self.files_changed,
            "total_cost_usd": self.total_cost_usd,
        }


class ProgressSnapshot(BaseModel):
    """Point-in-time snapshot of agent progress (SDK-OUTPUT-3)."""

    loop_count: int = 0
    work_type: str = "UNKNOWN"
    current_task: str = ""
    elapsed_seconds: float = 0.0
    circuit_breaker_state: str = "CLOSED"
    session_id: str = ""
    files_modified_this_loop: list[str] = Field(default_factory=list)


class ContinueAsNewState(BaseModel):
    """Essential state preserved across session rotations (SDK-CONTEXT-3)."""

    current_task: str = ""
    progress: str = ""
    key_findings: list[str] = Field(default_factory=list)
    continued_from_loop: int = 0
    previous_session_id: str = ""
    timestamp: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary for state backend."""
        return {
            "current_task": self.current_task,
            "progress": self.progress,
            "key_findings": self.key_findings,
            "continued_from_loop": self.continued_from_loop,
            "previous_session_id": self.previous_session_id,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ContinueAsNewState:
        """Create from state dict."""
        return cls(
            current_task=data.get("current_task", ""),
            progress=data.get("progress", ""),
            key_findings=data.get("key_findings", []),
            continued_from_loop=data.get("continued_from_loop", 0),
            previous_session_id=data.get("previous_session_id", ""),
            timestamp=data.get("timestamp", ""),
        )


class CancelResult(BaseModel):
    """Result returned by RalphAgent.cancel() (SDK-LIFECYCLE-1)."""

    partial_output: str | None = None
    iterations_completed: int = 0
    was_forced: bool = False


# ---------------------------------------------------------------------------
# SDK-LIFECYCLE-2: Adaptive timeout
# ---------------------------------------------------------------------------

# Maximum number of recent iteration durations to keep for P95 estimation.
_ADAPTIVE_TIMEOUT_HISTORY_SIZE = 50


def compute_adaptive_timeout(
    history: list[float],
    multiplier: float = 2.0,
    min_minutes: int = 5,
    max_minutes: int = 60,
) -> int:
    """Compute an adaptive timeout from recent iteration durations.

    Uses the P95 latency of *history* (in seconds) multiplied by *multiplier*,
    then clamps the result to [*min_minutes*, *max_minutes*].
    """
    if not history:
        return min_minutes

    sorted_durations = sorted(history)
    n = len(sorted_durations)
    p95_idx = 0.95 * (n - 1)
    lower = int(math.floor(p95_idx))
    upper = min(lower + 1, n - 1)
    fraction = p95_idx - lower
    p95_seconds = sorted_durations[lower] + fraction * (
        sorted_durations[upper] - sorted_durations[lower]
    )

    timeout_minutes = int(math.ceil((p95_seconds * multiplier) / 60.0))
    return max(min_minutes, min(timeout_minutes, max_minutes))
