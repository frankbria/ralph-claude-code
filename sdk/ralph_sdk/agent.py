"""Ralph SDK Agent — Agent SDK proof of concept replicating ralph_loop.sh core loop.

Dual-mode: standalone CLI + TheStudio embedded.
All agent methods are async. Use run_sync() for CLI synchronous execution.

SDK-SAFETY-2: Task decomposition detection via 4-factor heuristic.
SDK-SAFETY-3: Completion indicator decay — reset stale done signals
              when productive work occurs without exit_signal.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import re
import signal
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from pydantic import BaseModel, Field, field_validator

from ralph_sdk.config import RalphConfig, RalphConfigError
from ralph_sdk.context import (
    ContextManager,
    PromptCacheStats,
    estimate_tokens,
    split_prompt,
)
from ralph_sdk.cost import AlertLevel, CostTracker, TokenRateLimiter
from ralph_sdk.import_graph import CachedImportGraph
from ralph_sdk.metrics import MetricEvent, MetricsCollector, NullMetricsCollector
from ralph_sdk.parsing import (
    detect_permission_denials,
    extract_files_changed,
    parse_ralph_status,
)
from ralph_sdk.plan_optimizer import optimize_plan
from ralph_sdk.state import FileStateBackend, RalphStateBackend
from ralph_sdk.status import (
    CircuitBreakerState,
    ErrorCategory,
    RalphStatus,
    classify_error,
)
from ralph_sdk.tools import (
    RALPH_TOOLS,
    ralph_circuit_state_tool,
    ralph_rate_check_tool,
    ralph_status_tool,
    ralph_task_update_tool,
)

logger = logging.getLogger("ralph.sdk")



# =============================================================================
# SDK-SAFETY-2: Task Decomposition Detection
# =============================================================================


@dataclass(frozen=True)
class DecompositionHint:
    """Hint that a task should be decomposed into smaller sub-tasks.

    Produced by detect_decomposition_needed() when the 4-factor heuristic
    determines the current task is too large for a single iteration.
    """

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


def detect_decomposition_needed(
    status: RalphStatus,
    iteration_history: list[IterationRecord],
    config: RalphConfig | None = None,
) -> DecompositionHint:
    """Detect whether the current task should be decomposed (SDK-SAFETY-2).

    Uses a 4-factor heuristic:
    1. file_count >= threshold (default 5) -- task touches many files
    2. previous timeout -- last iteration timed out
    3. complexity >= threshold (default 4) -- high inferred complexity
    4. consecutive_no_progress >= threshold (default 3) -- stuck in a rut

    Returns a DecompositionHint when 2+ factors are true.

    Args:
        status: Current iteration's parsed RalphStatus.
        iteration_history: List of past IterationRecords (most recent last).
        config: Optional RalphConfig for threshold overrides.

    Returns:
        DecompositionHint with should_decompose, reason, and suggested_split.
    """
    cfg = config or RalphConfig()

    # Factor 1: File count (estimate from status next_task or progress_summary)
    file_count = _estimate_file_count(status)
    factor_file_count = file_count >= cfg.decomposition_file_count_threshold

    # Factor 2: Previous timeout
    factor_previous_timeout = False
    if iteration_history:
        factor_previous_timeout = iteration_history[-1].timed_out

    # Factor 3: Complexity (estimate from status)
    complexity = _estimate_complexity(status)
    factor_complexity = complexity >= cfg.decomposition_complexity_threshold

    # Factor 4: Consecutive no-progress
    consecutive_no_progress = 0
    for record in reversed(iteration_history):
        if not record.had_progress:
            consecutive_no_progress += 1
        else:
            break
    factor_no_progress = consecutive_no_progress >= cfg.decomposition_no_progress_threshold

    factors = {
        "file_count": factor_file_count,
        "previous_timeout": factor_previous_timeout,
        "complexity": factor_complexity,
        "consecutive_no_progress": factor_no_progress,
    }
    active_count = sum(1 for v in factors.values() if v)

    if active_count >= 2:
        reasons: list[str] = []
        if factor_file_count:
            reasons.append(f"file_count={file_count}>={cfg.decomposition_file_count_threshold}")
        if factor_previous_timeout:
            reasons.append("previous iteration timed out")
        if factor_complexity:
            reasons.append(f"complexity={complexity}>={cfg.decomposition_complexity_threshold}")
        if factor_no_progress:
            reasons.append(
                f"consecutive_no_progress={consecutive_no_progress}"
                f">={cfg.decomposition_no_progress_threshold}"
            )

        # Suggest splitting based on file count or a reasonable default
        suggested_split = max(2, file_count // cfg.decomposition_file_count_threshold + 1)
        suggested_split = min(suggested_split, 5)  # Cap at 5 sub-tasks

        return DecompositionHint(
            should_decompose=True,
            reason=f"Decomposition recommended ({active_count}/4 factors): {'; '.join(reasons)}",
            suggested_split=suggested_split,
            factors=factors,
        )

    return DecompositionHint(factors=factors)


def _estimate_file_count(status: RalphStatus) -> int:
    """Estimate the number of files involved from status text.

    Looks for file path patterns in next_task and progress_summary.
    """
    text = f"{status.next_task} {status.progress_summary}"
    # Match common file path patterns (e.g., src/foo.py, lib/bar.sh)
    file_patterns = re.findall(
        r'(?:^|[\s,])([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,10})(?:[\s,]|$)',
        text,
    )
    # Deduplicate
    return len(set(file_patterns))


def _estimate_complexity(status: RalphStatus) -> int:
    """Estimate task complexity from status text on a 1-5 scale.

    Uses keyword heuristics from the progress summary and next task.
    """
    text = f"{status.next_task} {status.progress_summary}".lower()

    complexity = 1  # Baseline

    # High-complexity indicators
    high_keywords = [
        "refactor", "architect", "redesign", "migration", "overhaul",
        "rewrite", "breaking change", "cross-cutting",
    ]
    medium_keywords = [
        "implement", "integrate", "complex", "multiple", "several",
        "significant", "extensive", "large",
    ]

    for keyword in high_keywords:
        if keyword in text:
            complexity += 2
            break

    for keyword in medium_keywords:
        if keyword in text:
            complexity += 1
            break

    # Multi-file references boost complexity
    file_count = _estimate_file_count(status)
    if file_count >= 8:
        complexity += 2
    elif file_count >= 4:
        complexity += 1

    return min(complexity, 5)


# =============================================================================
# Abstract Interface (SDK-3: Hybrid Architecture)
# =============================================================================

class TracerProtocol(Protocol):
    """Minimal OpenTelemetry-style tracer surface used by the agent.

    Defined as a Protocol so callers can inject any tracer (real OTel,
    a no-op stub, a test double) without importing OTel here. Only the
    `start_as_current_span` context-manager surface is touched today.
    """

    def start_as_current_span(self, name: str, **kwargs: Any) -> Any: ...


class RalphAgentInterface(Protocol):
    """Abstract interface for Ralph agent implementations (CLI and SDK)."""

    async def run_iteration(self, prompt: str, context: dict[str, Any]) -> RalphStatus:
        """Execute a single loop iteration."""
        ...

    async def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
        """Evaluate exit conditions (dual-condition gate)."""
        ...

    async def check_rate_limit(self) -> bool:
        """Check if within rate limits. Returns True if OK to proceed."""
        ...

    async def check_circuit_breaker(self) -> bool:
        """Check circuit breaker state. Returns True if OK to proceed."""
        ...


# =============================================================================
# Task Input/Output (SDK-3: TheStudio compatibility)
# =============================================================================

class TaskInput(BaseModel, frozen=True):
    """Union type for task input — handles fix_plan.md and TheStudio TaskPackets.

    In standalone mode: reads from fix_plan.md + PROMPT.md
    In TheStudio mode: receives TaskPacket with structured fields
    """
    prompt: str = ""
    fix_plan: str = ""
    agent_instructions: str = ""
    # TheStudio fields (populated when embedded)
    task_packet_id: str = ""
    task_packet_type: str = ""
    task_packet_payload: dict[str, Any] = Field(default_factory=dict)

    @field_validator("prompt")
    @classmethod
    def validate_prompt(cls, v: str) -> str:
        """Prompt must be non-empty when provided for execution (validated at use site)."""
        return v

    @field_validator("task_packet_payload")
    @classmethod
    def validate_payload(cls, v: dict[str, Any]) -> dict[str, Any]:
        """Payload must be a dict."""
        return v

    @classmethod
    def from_ralph_dir(cls, ralph_dir: str | Path = ".ralph") -> TaskInput:
        """Load task input from .ralph/ directory (standalone mode)."""
        ralph_path = Path(ralph_dir)
        prompt = ""
        fix_plan = ""
        agent_instructions = ""

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


# =============================================================================
# SDK-OUTPUT-3: Structured Progress Snapshot
# =============================================================================

class ProgressSnapshot(BaseModel):
    """Point-in-time snapshot of agent progress.

    SDK-OUTPUT-3: Updated after each iteration; queryable via
    ``RalphAgent.get_progress()``.
    """
    loop_count: int = 0
    work_type: str = "UNKNOWN"
    current_task: str = ""
    elapsed_seconds: float = 0.0
    circuit_breaker_state: str = "CLOSED"
    session_id: str = ""
    files_modified_this_loop: list[str] = Field(default_factory=list)


# =============================================================================
# SDK-CONTEXT-3: Continue-As-New State
# =============================================================================

class ContinueAsNewState(BaseModel):
    """Essential state preserved across session rotations.

    SDK-CONTEXT-3: When a session exceeds max_session_iterations or
    max_session_age_minutes, the agent saves this state and starts a fresh
    session. This prevents context window bloat while preserving progress.
    """
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


# =============================================================================
# SDK-LIFECYCLE-1: Cancel Result Model
# =============================================================================

class CancelResult(BaseModel):
    """Result returned by ``RalphAgent.cancel()`` after hardened cancellation.

    SDK-LIFECYCLE-1: Captures any partial output from the Claude subprocess
    that was interrupted, the number of completed iterations at the time of
    cancellation, and whether a forced kill (SIGKILL) was required.

    Attributes:
        partial_output: Any stdout captured from the interrupted subprocess,
            or None if no output was available.
        iterations_completed: Number of full loop iterations completed before
            the cancel was requested.
        was_forced: True if the subprocess did not terminate within the grace
            period and a SIGKILL was required.
    """
    partial_output: str | None = None
    iterations_completed: int = 0
    was_forced: bool = False


# =============================================================================
# SDK-LIFECYCLE-2: Adaptive Timeout Computation
# =============================================================================

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

    Args:
        history: List of recent iteration durations in seconds.
        multiplier: Safety multiplier applied to the P95 latency.
        min_minutes: Floor for the returned timeout.
        max_minutes: Ceiling for the returned timeout.

    Returns:
        Timeout value in **minutes**, clamped to the specified range.
    """
    if not history:
        return min_minutes

    sorted_durations = sorted(history)
    n = len(sorted_durations)

    # P95 index -- use linear interpolation for fractional index
    p95_idx = 0.95 * (n - 1)
    lower = int(math.floor(p95_idx))
    upper = min(lower + 1, n - 1)
    fraction = p95_idx - lower
    p95_seconds = sorted_durations[lower] + fraction * (
        sorted_durations[upper] - sorted_durations[lower]
    )

    timeout_minutes = int(math.ceil((p95_seconds * multiplier) / 60.0))
    return max(min_minutes, min(timeout_minutes, max_minutes))


# =============================================================================
# SDK Agent Implementation (SDK-1: Proof of Concept)
# =============================================================================

class RalphAgent:
    """Ralph Agent SDK implementation — replicates ralph_loop.sh core loop in Python.

    Core loop: Read PROMPT.md + fix_plan.md -> invoke Claude -> parse response ->
    check exit conditions -> repeat.

    All loop methods are async. Use run_sync() for synchronous CLI execution.

    Supports three operational modes:
    - Standalone CLI: `ralph` (bash loop, unchanged)
    - Standalone SDK: `ralph --sdk` (this class)
    - TheStudio embedded: RalphAgent used as Primary Agent

    Cancel semantics (SDK-LIFECYCLE-1):
        Calling ``cancel()`` sets the ``_cancelled`` flag and, if a Claude
        subprocess is currently running, sends SIGTERM (or terminates on
        Windows), waits ``cancel_grace_seconds``, then sends SIGKILL if the
        process has not exited.  ``cancel()`` returns a ``CancelResult`` with
        any partial output captured, the iteration count, and whether a forced
        kill was needed.  It never raises.

    Adaptive timeout (SDK-LIFECYCLE-2):
        When ``adaptive_timeout_enabled`` is True in config, the agent tracks
        the wall-clock duration of each iteration.  Once
        ``adaptive_timeout_min_samples`` iterations have been recorded, the
        timeout for subsequent iterations is computed via
        ``compute_adaptive_timeout()`` using the P95 latency of the history
        window.  Until enough samples are collected, the static
        ``timeout_minutes`` from config is used.
    """

    def __init__(
        self,
        config: RalphConfig | None = None,
        project_dir: str | Path = ".",
        state_backend: RalphStateBackend | None = None,
        correlation_id: str | None = None,
        tracer: TracerProtocol | None = None,
        metrics_collector: MetricsCollector | None = None,
    ) -> None:
        self.config = config or RalphConfig.load(project_dir)
        self.project_dir = Path(project_dir).resolve()
        self.ralph_dir = self.project_dir / self.config.ralph_dir
        self.loop_count = 0
        self.start_time = 0.0
        self.session_id = ""
        self._completion_indicators = 0
        self._running = False
        self._last_tokens_in = 0
        self._last_tokens_out = 0

        # SDK-LIFECYCLE-1: Cancellation state
        self._cancelled = False
        self._current_proc: asyncio.subprocess.Process | None = None
        self._last_partial_output: str | None = None
        # TAP-675: Reference to the event loop running `self.run()`.
        # Captured at run() entry so `cancel()` can schedule work on the
        # correct loop from any thread, without calling deprecated
        # asyncio.get_event_loop() and without guessing via is_running().
        self._loop: asyncio.AbstractEventLoop | None = None

        # SDK-LIFECYCLE-2: Iteration duration history for adaptive timeout
        self._iteration_durations: list[float] = []

        # Correlation ID — auto-generated UUID if not provided
        self.correlation_id = correlation_id or str(uuid.uuid4())

        # Optional OpenTelemetry tracer (guarded import)
        self.tracer = tracer

        # SDK-OUTPUT-4: Metrics collector — NullMetricsCollector by default
        self.metrics_collector: MetricsCollector = metrics_collector or NullMetricsCollector()

        # SDK-OUTPUT-3: Progress snapshot — updated after each iteration
        self._progress: ProgressSnapshot = ProgressSnapshot()

        # SDK-OUTPUT-1: Files changed in the last iteration (populated by run_iteration)
        self._last_iteration_files: list[str] = []

        # SDK-SAFETY-2: Iteration history for decomposition detection
        self._iteration_history: list[IterationRecord] = []

        # SDK-SAFETY-3: Completion indicators stored as a list for decay support
        self._completion_indicator_list: list[str] = []

        # SDK-SAFETY-2: Pending decomposition hint to inject into next prompt
        self._pending_decomposition_hint: DecompositionHint | None = None

        # State backend — FileStateBackend by default
        self.state_backend: RalphStateBackend = state_backend or FileStateBackend(self.ralph_dir)

        # SDK-CONTEXT-1: Progressive context loading
        self._context_manager = ContextManager()

        # SDK-CONTEXT-2: Prompt cache optimization
        self._prompt_cache_stats = PromptCacheStats()

        # SDK-CONTEXT-3: Session lifecycle tracking
        self._session_iteration_count = 0
        self._session_start_time = 0.0

        # SDK-COST-1: Cost tracker with configurable thresholds
        self._cost_tracker = CostTracker(
            budget_warning_pct=self.config.budget_warning_pct,
            budget_critical_pct=self.config.budget_critical_pct,
        )

        # SDK-COST-3: Token-based rate limiter
        self._token_rate_limiter = TokenRateLimiter(
            max_tokens_per_hour=self.config.max_tokens_per_hour,
        )

        # Ensure .ralph directory exists
        self.ralph_dir.mkdir(parents=True, exist_ok=True)
        (self.ralph_dir / "logs").mkdir(exist_ok=True)

    # -------------------------------------------------------------------------
    # Sync wrapper for CLI mode
    # -------------------------------------------------------------------------

    def run_sync(self) -> TaskResult:
        """Synchronous wrapper around async run() for CLI mode.

        Uses asyncio.run() to execute the async loop. This is the entry point
        for `ralph --sdk` and `python -m ralph_sdk`.
        """
        return asyncio.run(self.run())

    def cancel(self) -> CancelResult:
        """Request graceful cancellation of the running loop.

        SDK-LIFECYCLE-1: Hardened cancel semantics.

        Sets the ``_cancelled`` flag so the main loop exits after the current
        iteration.  If a Claude subprocess is currently running, sends SIGTERM
        (or ``terminate()`` on Windows), waits up to ``cancel_grace_seconds``
        for it to exit, then sends SIGKILL if necessary.

        Safe to call from another thread or an async timeout handler.
        Never raises -- always returns a ``CancelResult``.

        Returns:
            A ``CancelResult`` containing any partial output captured from the
            interrupted subprocess, the number of iterations completed, and
            whether a forced kill was required.
        """
        self._cancelled = True
        self._running = False

        was_forced = False
        partial_output: str | None = None
        proc = self._current_proc

        if proc is not None and proc.returncode is None:
            grace = self.config.cancel_grace_seconds

            # Send SIGTERM (Unix) or terminate (Windows)
            try:
                if sys.platform != "win32":
                    try:
                        proc.send_signal(signal.SIGTERM)
                    except (ProcessLookupError, OSError):
                        pass
                else:
                    try:
                        proc.terminate()
                    except (ProcessLookupError, OSError):
                        pass
            except Exception:
                # Broad: cancel() must never propagate from a cleanup path —
                # the caller is asking us to stop, not to discover new errors.
                logger.exception("Failed to send termination signal")

            # Wait for graceful exit (TAP-675: use get_running_loop() +
            # stored loop reference instead of deprecated get_event_loop()).
            async def _deferred_kill() -> None:
                nonlocal was_forced
                try:
                    await asyncio.wait_for(proc.wait(), timeout=grace)
                except TimeoutError:
                    try:
                        proc.kill()
                        was_forced = True
                    except (ProcessLookupError, OSError):
                        pass

            try:
                # Case A: we're being called from within the agent's own loop.
                # `asyncio.get_running_loop()` returns it; schedule directly.
                current_loop = asyncio.get_running_loop()
                if self._loop is not None and current_loop is self._loop:
                    current_loop.create_task(_deferred_kill())
                else:
                    # Running inside some other loop than the agent's.
                    # Fall through to the cross-thread path below.
                    raise RuntimeError("cancel called from a different loop")
            except RuntimeError:
                # Case B: no running loop in this thread (sync context or
                # supervisor thread). Use the agent's stored loop via
                # call_soon_threadsafe so scheduling is thread-safe.
                agent_loop = self._loop
                if agent_loop is not None and not agent_loop.is_closed():
                    try:
                        agent_loop.call_soon_threadsafe(
                            lambda: agent_loop.create_task(_deferred_kill())
                        )
                    except RuntimeError:
                        # Loop is closed/stopping -- fall back to sync kill.
                        try:
                            proc.kill()
                            was_forced = True
                        except (ProcessLookupError, OSError):
                            pass
                else:
                    # No loop at all (agent never started) -- synchronous kill.
                    try:
                        proc.kill()
                        was_forced = True
                    except (ProcessLookupError, OSError):
                        pass

            # Try to capture partial output (best-effort)
            try:
                if proc.stdout and hasattr(proc.stdout, "_buffer"):
                    partial_output = bytes(proc.stdout._buffer).decode(
                        "utf-8", errors="replace"
                    )
            except (AttributeError, OSError, UnicodeDecodeError) as e:
                # Best-effort buffer read; failure here just means the
                # subprocess closed mid-decode. Surface at debug for triage.
                logger.debug("partial_output capture failed: %s", e)

        # Fallback to last captured partial output
        if partial_output is None:
            partial_output = self._last_partial_output

        logger.info(
            "Cancel requested: iterations=%d, was_forced=%s",
            self.loop_count,
            was_forced,
        )

        return CancelResult(
            partial_output=partial_output,
            iterations_completed=self.loop_count,
            was_forced=was_forced,
        )

    # -------------------------------------------------------------------------
    # SDK-LIFECYCLE-2: Adaptive Timeout
    # -------------------------------------------------------------------------

    def _get_effective_timeout_seconds(self) -> float:
        """Return the timeout to use for the next iteration, in seconds.

        SDK-LIFECYCLE-2: If adaptive timeout is enabled and enough samples
        have been collected, uses ``compute_adaptive_timeout()`` with the
        configured multiplier and bounds.  Otherwise falls back to the static
        ``timeout_minutes`` from config.
        """
        cfg = self.config
        if (
            cfg.adaptive_timeout_enabled
            and len(self._iteration_durations) >= cfg.adaptive_timeout_min_samples
        ):
            adaptive_minutes = compute_adaptive_timeout(
                history=self._iteration_durations,
                multiplier=cfg.adaptive_timeout_multiplier,
                min_minutes=cfg.adaptive_timeout_min_minutes,
                max_minutes=cfg.adaptive_timeout_max_minutes,
            )
            logger.debug(
                "Adaptive timeout: %d min (from %d samples)",
                adaptive_minutes,
                len(self._iteration_durations),
            )
            return adaptive_minutes * 60.0

        return cfg.timeout_minutes * 60.0

    # -------------------------------------------------------------------------
    # SDK-OUTPUT-3: Progress Snapshot
    # -------------------------------------------------------------------------

    def get_progress(self) -> ProgressSnapshot:
        """Return a point-in-time snapshot of agent progress.

        SDK-OUTPUT-3: Updated after each iteration.  Safe to call from any
        thread while the loop is running.
        """
        return self._progress.model_copy()

    # -------------------------------------------------------------------------
    # SDK-COST: Cost and Token accessors
    # -------------------------------------------------------------------------

    @property
    def cost_tracker(self) -> CostTracker:
        """Return the cost tracker for external session cost / budget queries."""
        return self._cost_tracker

    @property
    def token_rate_limiter(self) -> TokenRateLimiter:
        """Return the token rate limiter for external usage queries."""
        return self._token_rate_limiter

    # -------------------------------------------------------------------------
    # Core Loop (async, replicates ralph_loop.sh main())
    # -------------------------------------------------------------------------

    async def run(self) -> TaskResult:
        """Execute the autonomous loop until exit conditions are met."""
        self.start_time = time.time()
        self._running = True
        self._cancelled = False
        # TAP-675: Capture the loop we're running on so cancel() from another
        # thread can schedule work safely via call_soon_threadsafe.
        self._loop = asyncio.get_running_loop()

        # TAP-1104: hard-fail if Claude CLI is older than the agent contract
        # requires. Mirror of bash check_claude_version (ralph_loop.sh:1645);
        # SDK refuses to start rather than silently producing wrong commands.
        await self._preflight_claude_version()

        logger.info("Ralph SDK starting (v%s) [%s]", self.config.model, self.correlation_id,
                     extra={"correlation_id": self.correlation_id})
        logger.info("Project: %s (%s)", self.config.project_name, self.config.project_type,
                     extra={"correlation_id": self.correlation_id})

        # Load session
        await self._load_session()

        # SDK-CONTEXT-3: Initialize session lifecycle tracking
        self._session_iteration_count = 0
        self._session_start_time = time.time()
        await self._initialize_session_metadata()

        # Reset circuit breaker counters (matching bash behavior)
        cb_data = await self.state_backend.read_circuit_breaker()
        cb = CircuitBreakerState._from_state_dict(cb_data) if cb_data else CircuitBreakerState()
        cb.no_progress_count = 0
        cb.same_error_count = 0
        await self.state_backend.write_circuit_breaker(cb._to_state_dict())

        # PLANOPT: Optimize fix_plan.md before first iteration
        if self.config.optimize_plan:
            try:
                fix_plan_path = self.ralph_dir / "fix_plan.md"
                if fix_plan_path.exists():
                    graph = CachedImportGraph(
                        self.project_dir,
                        max_age_seconds=self.config.optimize_plan_cache_seconds,
                        project_type=self.config.project_type or None,
                    )
                    opt_result = optimize_plan(
                        fix_plan_path,
                        project_root=self.project_dir,
                        import_graph=graph,
                    )
                    if opt_result.changed:
                        logger.info(
                            "Plan optimized: %s",
                            opt_result.reason,
                            extra={"correlation_id": self.correlation_id},
                        )
            except Exception as exc:
                logger.debug("Plan optimization skipped: %s", exc)

        result = TaskResult()
        all_files_changed: dict[str, None] = {}  # ordered dedup across iterations

        try:
            while self._running:
                self.loop_count += 1
                logger.info("Loop iteration %d", self.loop_count)

                # Rate limit check (invocation-based)
                if not await self.check_rate_limit():
                    logger.warning("Rate limit reached, waiting for reset")
                    result.error = "Rate limit reached"
                    result.status.error_category = ErrorCategory.RATE_LIMITED
                    break

                # SDK-COST-3: Token-based rate limit check
                if not self._token_rate_limiter.can_proceed():
                    usage = self._token_rate_limiter.get_usage()
                    logger.warning(
                        "Token rate limit reached: %d/%d tokens this hour",
                        usage.tokens_used_this_hour,
                        usage.limit,
                    )
                    result.error = "Token rate limit reached"
                    break

                # SDK-COST-1: Budget check before iteration
                if self.config.max_budget_usd > 0:
                    budget = self._cost_tracker.check_budget(self.config.max_budget_usd)
                    if budget.alert_level == AlertLevel.EXHAUSTED:
                        logger.warning(
                            "Budget exhausted: $%.4f / $%.2f (%.1f%%)",
                            budget.total_spent_usd,
                            budget.max_budget_usd,
                            budget.percentage_used,
                        )
                        result.error = "Budget exhausted"
                        break
                    elif budget.alert_level == AlertLevel.CRITICAL:
                        logger.warning(
                            "Budget CRITICAL: $%.4f / $%.2f (%.1f%%)",
                            budget.total_spent_usd,
                            budget.max_budget_usd,
                            budget.percentage_used,
                        )
                    elif budget.alert_level == AlertLevel.WARNING:
                        logger.info(
                            "Budget WARNING: $%.4f / $%.2f (%.1f%%)",
                            budget.total_spent_usd,
                            budget.max_budget_usd,
                            budget.percentage_used,
                        )

                # Circuit breaker check
                if not await self.check_circuit_breaker():
                    logger.warning("Circuit breaker OPEN, stopping")
                    result.error = "Circuit breaker open"
                    break

                # Dry run check
                if self.config.dry_run:
                    logger.info("Dry run mode — skipping API call")
                    status = RalphStatus(
                        status="DRY_RUN",
                        work_type="DRY_RUN",
                        loop_count=self.loop_count,
                        correlation_id=self.correlation_id,
                    )
                    await self.state_backend.write_status(status.to_dict())
                    result.status = status
                    break

                # Load task input
                task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))
                if not task_input.prompt and not task_input.fix_plan:
                    logger.error("No PROMPT.md or fix_plan.md found")
                    result.error = "No task input found"
                    break

                # Execute one iteration
                iteration_status = await self.run_iteration(task_input)

                # SDK-CONTEXT-3: Session lifecycle — track and check for rotation
                self._session_iteration_count += 1
                if await self._should_rotate_session():
                    logger.info(
                        "Session rotation triggered at iteration %d (session iterations=%d)",
                        self.loop_count,
                        self._session_iteration_count,
                    )
                    await self._rotate_session(iteration_status)

                # SDK-OUTPUT-1: Accumulate files_changed across iterations
                for fp in self._last_iteration_files:
                    all_files_changed.setdefault(fp, None)

                # SDK-SAFETY-2: Record iteration history and check decomposition
                self._record_iteration_history(iteration_status)

                hint = detect_decomposition_needed(
                    iteration_status,
                    self._iteration_history,
                    self.config,
                )
                if hint.should_decompose:
                    logger.warning(
                        "SDK-SAFETY-2: %s (suggested_split=%d)",
                        hint.reason,
                        hint.suggested_split,
                    )
                    self._pending_decomposition_hint = hint

                # Check exit conditions (dual-condition gate)
                if await self.should_exit(iteration_status, self.loop_count):
                    logger.info("Exit conditions met after %d loops", self.loop_count)
                    result.status = iteration_status
                    break

                # Brief pause between iterations
                await asyncio.sleep(2)

        except KeyboardInterrupt:
            logger.info("Interrupted by user")
            result.error = "User interrupt"
        except Exception as e:
            logger.exception("Unexpected error in loop")
            result.error = str(e)
            # SDK-OUTPUT-2: Classify the exception
            result.status.error_category = classify_error(exception=e)
        finally:
            self._running = False
            result.loop_count = self.loop_count
            result.duration_seconds = time.time() - self.start_time
            result.tokens_in = self._last_tokens_in
            result.tokens_out = self._last_tokens_out
            result.files_changed = list(all_files_changed)

            # SDK-COST-1: Attach session cost summary
            session_cost = self._cost_tracker.get_session_cost()
            result.total_cost_usd = session_cost.total_usd

        return result

    async def run_iteration(
        self,
        task_input: TaskInput | None = None,
        system_prompt: str | None = None,
    ) -> RalphStatus:
        """Execute a single loop iteration via Claude Code CLI.

        Uses asyncio.create_subprocess_exec() with asyncio.wait_for() timeout.

        Args:
            task_input: Task input to process. Loads from .ralph/ if None.
            system_prompt: Optional system prompt passed through to Claude CLI
                via --system-prompt flag.
        """
        if task_input is None:
            task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))

        # Build the prompt for this iteration
        prompt = self._build_iteration_prompt(task_input)

        # SDK-SAFETY-2: Inject decomposition hint into prompt if pending
        if self._pending_decomposition_hint and self._pending_decomposition_hint.should_decompose:
            hint = self._pending_decomposition_hint
            prompt += (
                f"\n\n## Decomposition Advisory\n\n"
                f"**{hint.reason}**\n\n"
                f"Consider splitting this work into ~{hint.suggested_split} smaller sub-tasks "
                f"before proceeding. Focus on one logical unit of change per iteration."
            )
            self._pending_decomposition_hint = None  # Consumed

        # Build Claude CLI command
        cmd = self._build_claude_command(prompt, system_prompt=system_prompt)

        logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")

        iteration_start = time.time()

        # SDK-LIFECYCLE-2: Compute effective timeout (adaptive or static)
        timeout_seconds = self._get_effective_timeout_seconds()

        # Execute Claude CLI asynchronously
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.project_dir),
            )

            # SDK-LIFECYCLE-1: Track current subprocess for cancel()
            self._current_proc = proc

            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(),
                timeout=timeout_seconds,
            )

            # SDK-LIFECYCLE-1: Clear subprocess reference
            self._current_proc = None

            stdout = stdout_bytes.decode("utf-8", errors="replace") if stdout_bytes else ""
            stderr = stderr_bytes.decode("utf-8", errors="replace") if stderr_bytes else ""
            returncode = proc.returncode or 0

            # SDK-LIFECYCLE-1: Stash partial output for cancel()
            self._last_partial_output = stdout if stdout else None

            # SDK-LIFECYCLE-2: Record iteration duration for adaptive timeout
            iteration_duration_for_history = time.time() - iteration_start
            self._iteration_durations.append(iteration_duration_for_history)
            if len(self._iteration_durations) > _ADAPTIVE_TIMEOUT_HISTORY_SIZE:
                self._iteration_durations = self._iteration_durations[
                    -_ADAPTIVE_TIMEOUT_HISTORY_SIZE:
                ]

            # Increment call count
            await self._increment_call_count()

            # Parse response (also extracts session_id and token counts)
            status = self._parse_response(stdout, returncode)
            status.loop_count = self.loop_count
            status.session_id = self.session_id
            status.correlation_id = self.correlation_id

            # SDK-COST-1: Record cost for this iteration
            if not self._tokens_extracted:
                # TAP-662: distinguish "no usage block" from "0 tokens used"
                logger.warning(
                    "No token counts in CLI output; cost for this iteration not recorded"
                )
            elif self._last_tokens_in or self._last_tokens_out:
                self._cost_tracker.record_iteration(
                    model=self.config.model,
                    input_tokens=self._last_tokens_in,
                    output_tokens=self._last_tokens_out,
                )

            # SDK-COST-3: Record tokens for rate limiting
            self._token_rate_limiter.record_tokens(
                self._last_tokens_in,
                self._last_tokens_out,
            )

            # SDK-OUTPUT-2: Classify errors on non-zero exit codes
            if returncode != 0:
                status.error_category = classify_error(
                    exit_code=returncode,
                    output=stdout + stderr,
                )

            # SDK-OUTPUT-1: Extract files_changed from JSONL tool_use records
            iteration_files = extract_files_changed(stdout)

            # SDK-LIFECYCLE-3: Detect permission denials
            denials = detect_permission_denials(stdout)
            if denials:
                status.permission_denials = denials
                logger.info(
                    "Detected %d permission denial(s): %s",
                    len(denials),
                    ", ".join(
                        f"{d.tool_name}({d.denied_pattern})"
                        for d in denials
                    ),
                )

            await self.state_backend.write_status(status.to_dict())

            # Persist extracted session_id for continuity across restarts
            if self.session_id:
                await self._save_session()

            # SDK-CONTEXT-3: Update session metadata
            await self._update_session_metadata()

            # SDK-OUTPUT-3: Update progress snapshot
            self._update_progress(status, iteration_files)

            # SDK-OUTPUT-4: Record metrics
            iteration_duration = time.time() - iteration_start
            self._record_iteration_metrics(
                status=status,
                files_changed=iteration_files,
                duration_seconds=iteration_duration,
            )

            # Log output
            self._log_output(stdout, stderr, self.loop_count)

            # Stash iteration files on the result so callers of run() can access them
            self._last_iteration_files = iteration_files

            return status

        except TimeoutError:
            timeout_minutes_used = timeout_seconds / 60.0
            logger.warning(
                "Claude CLI timed out after %.1f minutes", timeout_minutes_used,
            )
            # SDK-LIFECYCLE-1: Clear subprocess reference
            self._current_proc = None
            # Kill the orphaned subprocess to prevent resource leaks
            try:
                proc.kill()
                await proc.wait()
            except (ProcessLookupError, OSError) as e:
                # Process already dead or wait() race — both are benign on
                # the timeout path; everything else has already given up.
                logger.debug("post-timeout proc cleanup: %s", e)
            status = RalphStatus(
                status="TIMEOUT",
                work_type="UNKNOWN",
                error=f"Timeout after {timeout_minutes_used:.0f} minutes",
                loop_count=self.loop_count,
                error_category=ErrorCategory.TIMEOUT,
            )
            await self.state_backend.write_status(status.to_dict())
            self._update_progress(status, [])
            return status

        except FileNotFoundError:
            self._current_proc = None
            logger.error("Claude CLI not found: %s", self.config.claude_code_cmd)
            return RalphStatus(
                status="ERROR",
                error=f"Claude CLI not found: {self.config.claude_code_cmd}",
                error_category=ErrorCategory.TOOL_UNAVAILABLE,
            )

    async def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
        """Dual-condition exit gate (matching bash implementation).

        Requires BOTH:
        1. completion_indicators >= 2 (NLP heuristics)
        2. EXIT_SIGNAL: true (explicit from Claude)

        SDK-SAFETY-3: Completion indicator decay -- when productive work
        occurs (files_modified > 0 or tasks_completed > 0) AND exit_signal
        is False, reset completion_indicators to prevent stale done signals
        from combining with later signals for premature exit.
        """
        # SDK-SAFETY-3: Decay stale completion indicators on productive work
        # without exit signal. This prevents premature exit when Claude said
        # "done" earlier but then continued making real progress.
        files_modified = len(self._last_iteration_files)
        tasks_completed = 1 if status.completed_task else 0

        if (files_modified > 0 or tasks_completed > 0) and not status.exit_signal:
            if self._completion_indicators > 0:
                logger.debug(
                    "SDK-SAFETY-3: Resetting %d completion indicators "
                    "(productive work without exit_signal: %d files, %d tasks)",
                    self._completion_indicators,
                    files_modified,
                    tasks_completed,
                )
                self._completion_indicators = 0
                self._completion_indicator_list.clear()

        if status.exit_signal:
            self._completion_indicators += 1
            self._completion_indicator_list.append("exit_signal")

        # Check for completion phrases in progress summary
        completion_phrases = [
            "all tasks complete",
            "all tasks done",
            "nothing left",
            "no remaining tasks",
            "work is complete",
            "all items checked",
        ]
        summary_lower = status.progress_summary.lower()
        if any(phrase in summary_lower for phrase in completion_phrases):
            self._completion_indicators += 1
            self._completion_indicator_list.append("completion_phrase")

        # Dual condition: need both indicators and explicit exit signal
        return self._completion_indicators >= 2 and status.exit_signal

    async def check_rate_limit(self) -> bool:
        """Check if within rate limits via state backend."""
        call_count = await self.state_backend.read_call_count()
        last_reset = await self.state_backend.read_last_reset()
        now = int(time.time())
        elapsed = now - last_reset if last_reset > 0 else 3600
        remaining = max(0, self.config.max_calls_per_hour - call_count)
        # If the hour has elapsed, we're not rate limited
        if elapsed >= 3600:
            return True
        return remaining > 0

    async def check_circuit_breaker(self) -> bool:
        """Check circuit breaker via state backend — returns True if OK to proceed."""
        cb_data = await self.state_backend.read_circuit_breaker()
        state = cb_data.get("state", "CLOSED")
        return state in ("CLOSED", "HALF_OPEN")

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    def _build_iteration_prompt(self, task_input: TaskInput) -> str:
        """Build the prompt for one iteration with progressive context loading.

        SDK-CONTEXT-1: Trims fix_plan.md to the active section to reduce tokens.
        SDK-CONTEXT-2: Splits into stable/dynamic parts and tracks cache stats.
        """
        parts = []
        if task_input.prompt:
            parts.append(task_input.prompt)
        if task_input.fix_plan:
            # SDK-CONTEXT-1: Progressive context loading — trim fix_plan
            trimmed_plan = self._context_manager.trim_fix_plan(task_input.fix_plan)
            token_estimate = estimate_tokens(trimmed_plan)
            logger.debug(
                "Fix plan trimmed: %d -> %d chars (~%d tokens)",
                len(task_input.fix_plan),
                len(trimmed_plan),
                token_estimate,
            )
            parts.append(f"\n\n## Current Fix Plan\n\n{trimmed_plan}")
        if task_input.agent_instructions:
            parts.append(f"\n\n## Build/Run Instructions\n\n{task_input.agent_instructions}")

        full_prompt = "\n".join(parts)

        # SDK-CONTEXT-2: Prompt cache optimization — split and track
        loop_context = {
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "session_iteration": self._session_iteration_count,
        }
        prompt_parts = split_prompt(full_prompt, loop_context)
        is_hit = self._prompt_cache_stats.record(prompt_parts.prefix_hash)
        logger.debug(
            "Prompt cache %s (hit_rate=%.1f%%, prefix_hash=%s)",
            "HIT" if is_hit else "MISS",
            self._prompt_cache_stats.hit_rate * 100,
            prompt_parts.prefix_hash[:8],
        )

        return prompt_parts.full_prompt()

    async def _preflight_claude_version(self) -> None:
        """Verify Claude CLI >= config.claude_min_version, else raise.

        TAP-1104: SDK only supports agent mode. The `--agent` flag landed in
        Claude CLI 2.1.0; older binaries will silently ignore it and fall
        back to legacy `-p` mode, which is the failure the bash side already
        deleted via ADR-0006. We detect at startup and refuse to proceed.

        Network/exec errors degrade to a WARN log (matches bash behavior at
        ralph_loop.sh:1649-1652) — never raise on "could not detect".
        """
        try:
            proc = await asyncio.create_subprocess_exec(
                self.config.claude_code_cmd, "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5.0)
        except (TimeoutError, FileNotFoundError, OSError) as e:
            logger.warning("Cannot detect Claude CLI version (%s); assuming compatible", e)
            return

        match = re.search(rb"(\d+)\.(\d+)\.(\d+)", stdout)
        if not match:
            logger.warning("Cannot parse Claude CLI version from %r; assuming compatible", stdout[:80])
            return

        installed = tuple(int(g) for g in match.groups())
        required = tuple(
            int(g) for g in (self.config.claude_min_version.split(".") + ["0", "0", "0"])[:3]
        )
        if installed < required:
            raise RalphConfigError(
                f"Claude CLI version {'.'.join(map(str, installed))} is older than "
                f"required {self.config.claude_min_version}. Agent mode (--agent) "
                f"requires CLI >= 2.1.0. Upgrade with: "
                f"npm update -g @anthropic-ai/claude-code"
            )

    def _build_claude_command(
        self,
        prompt: str,
        system_prompt: str | None = None,
    ) -> list[str]:
        """Build Claude CLI command (matching bash build_claude_command())."""
        cmd = [self.config.claude_code_cmd]

        # TAP-1104: agent mode is the only execution path. The
        # `--allowedTools` flag is incompatible with `--agent` and is
        # therefore intentionally not emitted; tool surface is set by the
        # agent file's `tools:` allowlist + `disallowedTools:` blocklist.
        cmd.extend(["--agent", self.config.agent_name])

        # System prompt (for TheStudio DeveloperRoleConfig injection)
        if system_prompt:
            cmd.extend(["--system-prompt", system_prompt])

        # Prompt
        cmd.extend(["-p", prompt])

        # Output format
        cmd.extend(["--output-format", self.config.output_format])

        # Session continuity
        if self.config.session_continuity and self.session_id:
            cmd.extend(["--continue", self.session_id])

        # Max turns
        cmd.extend(["--max-turns", str(self.config.max_turns)])

        return cmd

    def _parse_response(self, stdout: str, return_code: int) -> RalphStatus:
        """Parse Claude CLI response using 3-strategy chain (JSON block -> JSONL -> text).

        Delegates to ralph_sdk.parsing.parse_ralph_status for the actual parsing,
        with session_id extraction handled here.
        """
        status = RalphStatus()

        if return_code != 0:
            status.status = "ERROR"
            status.error = f"Claude CLI exited with code {return_code}"
            return status

        # Extract session_id from JSONL before parsing status
        self._extract_session_id(stdout)

        # Use the 3-strategy parse chain
        return parse_ralph_status(stdout)

    def _extract_session_id(self, stdout: str) -> None:
        """Extract session_id and token counts from JSONL result objects."""
        self._last_tokens_in = 0
        self._last_tokens_out = 0
        self._tokens_extracted = False
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("type") == "result":
                    if "session_id" in obj:
                        self.session_id = obj["session_id"]
                    # Claude Code emits token counts nested under "usage".
                    usage = obj.get("usage") or {}
                    self._last_tokens_in += usage.get("input_tokens", 0)
                    self._last_tokens_out += usage.get("output_tokens", 0)
                    self._tokens_extracted = True
                    return
            except json.JSONDecodeError:
                continue

    async def _load_session(self) -> None:
        """Load session ID via state backend."""
        self.session_id = await self.state_backend.read_session_id()

    async def _save_session(self) -> None:
        """Save session ID via state backend."""
        await self.state_backend.write_session_id(self.session_id)

    async def _increment_call_count(self) -> None:
        """Increment API call counter via state backend (matching bash rate limiting)."""
        now = int(time.time())
        last_reset = await self.state_backend.read_last_reset()

        if now - last_reset >= 3600:
            # Reset counter
            await self.state_backend.write_call_count(1)
            await self.state_backend.write_last_reset(now)
        else:
            # Increment
            count = await self.state_backend.read_call_count()
            await self.state_backend.write_call_count(count + 1)

    def _log_output(self, stdout: str, stderr: str, loop_count: int) -> None:
        """Log Claude output to .ralph/logs/."""
        log_dir = self.ralph_dir / "logs"
        log_dir.mkdir(exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        log_file = log_dir / f"claude_output_{loop_count:04d}_{timestamp}.log"
        try:
            with open(log_file, "w", encoding="utf-8") as f:
                f.write(f"=== Loop {loop_count} — {timestamp} ===\n")
                f.write(f"=== STDOUT ===\n{stdout}\n")
                if stderr:
                    f.write(f"=== STDERR ===\n{stderr}\n")
        except OSError:
            pass

    # -------------------------------------------------------------------------
    # SDK-SAFETY-2: Iteration history tracking
    # -------------------------------------------------------------------------

    def _record_iteration_history(self, status: RalphStatus) -> None:
        """Record an IterationRecord for decomposition detection.

        SDK-SAFETY-2: Builds up iteration_history so that
        detect_decomposition_needed() can evaluate the 4-factor heuristic.
        """
        files_modified = len(self._last_iteration_files)
        tasks_completed = 1 if status.completed_task else 0
        had_progress = files_modified > 0 or tasks_completed > 0
        timed_out = str(status.status).upper() == "TIMEOUT"

        record = IterationRecord(
            loop_count=self.loop_count,
            files_modified=files_modified,
            tasks_completed=tasks_completed,
            timed_out=timed_out,
            complexity=_estimate_complexity(status),
            file_count=_estimate_file_count(status),
            had_progress=had_progress,
        )
        self._iteration_history.append(record)

        # Keep only last 20 records to bound memory
        if len(self._iteration_history) > 20:
            self._iteration_history = self._iteration_history[-20:]

    # -------------------------------------------------------------------------
    # SDK-OUTPUT-3: Progress snapshot update
    # -------------------------------------------------------------------------

    def _update_progress(
        self,
        status: RalphStatus,
        files_modified: list[str],
    ) -> None:
        """Update the internal progress snapshot after an iteration.

        SDK-OUTPUT-3: Called at the end of each run_iteration() so that
        ``get_progress()`` always reflects the latest state.
        """
        self._progress = ProgressSnapshot(
            loop_count=self.loop_count,
            work_type=status.work_type.value if hasattr(status.work_type, "value") else str(status.work_type),
            current_task=status.next_task or status.completed_task,
            elapsed_seconds=time.time() - self.start_time if self.start_time else 0.0,
            circuit_breaker_state=status.circuit_breaker_state,
            session_id=self.session_id,
            files_modified_this_loop=files_modified,
        )

    # -------------------------------------------------------------------------
    # SDK-OUTPUT-4: Metrics recording
    # -------------------------------------------------------------------------

    def _record_iteration_metrics(
        self,
        status: RalphStatus,
        files_changed: list[str],
        duration_seconds: float,
    ) -> None:
        """Record a MetricEvent for the completed iteration.

        SDK-OUTPUT-4: Delegates to the configured MetricsCollector.
        """
        event = MetricEvent(
            event_type="iteration_complete",
            loop_count=self.loop_count,
            duration_seconds=round(duration_seconds, 3),
            work_type=status.work_type.value if hasattr(status.work_type, "value") else str(status.work_type),
            files_changed=files_changed,
            tokens_in=self._last_tokens_in,
            tokens_out=self._last_tokens_out,
            model=self.config.model,
        )
        try:
            self.metrics_collector.record(event)
        except Exception:
            # Broad: metrics is observability — a backend bug must never
            # crash the agent loop. Surface stack at debug for triage.
            logger.exception("Failed to record metrics")

    # -------------------------------------------------------------------------
    # SDK-CONTEXT-3: Session Lifecycle Management
    # -------------------------------------------------------------------------

    async def _initialize_session_metadata(self) -> None:
        """Initialize or load session metadata for lifecycle tracking."""
        metadata = await self.state_backend.read_session_metadata()
        if metadata and self.session_id:
            # Check session expiry
            created_at = metadata.get("created_at", 0)
            expiry_seconds = self.config.session_expiry_hours * 3600
            if created_at and (time.time() - created_at) > expiry_seconds:
                logger.info(
                    "Session expired (age=%.1fh, TTL=%dh) — rotating",
                    (time.time() - created_at) / 3600,
                    self.config.session_expiry_hours,
                )
                await self._expire_session()
                return

            # Resume existing session
            self._session_iteration_count = metadata.get("iteration_count", 0)
            self._session_start_time = metadata.get("created_at", time.time())
        else:
            # New session
            await self.state_backend.write_session_metadata({
                "session_id": self.session_id,
                "created_at": time.time(),
                "iteration_count": 0,
                "correlation_id": self.correlation_id,
            })

    async def _should_rotate_session(self) -> bool:
        """Check if the current session should be rotated (continue-as-new).

        SDK-CONTEXT-3: Returns True if max iterations or max age exceeded.
        """
        if not self.config.continue_as_new_enabled:
            return False

        # Check iteration count
        if self._session_iteration_count >= self.config.max_session_iterations:
            logger.debug(
                "Session rotation: iteration limit reached (%d >= %d)",
                self._session_iteration_count,
                self.config.max_session_iterations,
            )
            return True

        # Check session age
        session_age_minutes = (time.time() - self._session_start_time) / 60
        if session_age_minutes >= self.config.max_session_age_minutes:
            logger.debug(
                "Session rotation: age limit reached (%.1f >= %d minutes)",
                session_age_minutes,
                self.config.max_session_age_minutes,
            )
            return True

        return False

    async def _rotate_session(self, last_status: RalphStatus) -> None:
        """Perform session rotation: save essential state, clear session, start fresh.

        SDK-CONTEXT-3: Continue-As-New pattern — preserves progress while
        starting a fresh context window.

        TAP-671: When the circuit breaker is non-CLOSED at rotation time,
        the session is being reset because Claude's side is unhealthy.
        Carrying the old session_id through continue-as-new would mislead
        any downstream consumer into thinking --continue is still viable.
        Blank it out so the next iteration uses a truly fresh session.
        """
        old_session_id = self.session_id

        # Check CB state so we can decide whether to carry session_id forward
        cb_data = await self.state_backend.read_circuit_breaker()
        cb_state = (cb_data or {}).get("state", "CLOSED")
        carry_session_id = cb_state == "CLOSED"

        # Build continue-as-new state
        continue_state = ContinueAsNewState(
            current_task=last_status.next_task or last_status.completed_task,
            progress=last_status.progress_summary,
            key_findings=[],
            continued_from_loop=self.loop_count,
            previous_session_id=old_session_id if carry_session_id else "",
        )
        await self.state_backend.write_continue_as_new_state(continue_state.to_dict())

        # Record old session in history — tag the reason when rotation was
        # triggered with a tripped CB so post-mortem queries can find these.
        history_reason = (
            "continue_as_new_cb_open" if not carry_session_id else "continue_as_new"
        )
        await self.state_backend.append_session_history({
            "session_id": old_session_id,
            "started_at": self._session_start_time,
            "ended_at": time.time(),
            "iteration_count": self._session_iteration_count,
            "loop_count_at_end": self.loop_count,
            "reason": history_reason,
            "cb_state_at_rotation": cb_state,
            "correlation_id": self.correlation_id,
        })

        # Clear session to force a new one on next iteration
        self.session_id = ""
        await self.state_backend.write_session_id("")

        # Reset session-level counters
        self._session_iteration_count = 0
        self._session_start_time = time.time()

        # Write fresh metadata
        await self.state_backend.write_session_metadata({
            "session_id": "",
            "created_at": time.time(),
            "iteration_count": 0,
            "correlation_id": self.correlation_id,
            "continued_from": old_session_id,
        })

        # Reset prompt cache (new session = new prefix)
        self._prompt_cache_stats = PromptCacheStats()

        logger.info(
            "Session rotated: %s -> (new) after %d session iterations",
            old_session_id[:12] + "..." if old_session_id else "(none)",
            continue_state.continued_from_loop,
        )

    async def _expire_session(self) -> None:
        """Handle session expiry: archive and clear.

        SDK-CONTEXT-3: Called when session exceeds session_expiry_hours TTL.
        """
        old_session_id = self.session_id

        # Record in history
        if old_session_id:
            await self.state_backend.append_session_history({
                "session_id": old_session_id,
                "started_at": self._session_start_time,
                "ended_at": time.time(),
                "iteration_count": self._session_iteration_count,
                "reason": "expired",
                "correlation_id": self.correlation_id,
            })

        # Clear session
        self.session_id = ""
        await self.state_backend.write_session_id("")
        self._session_iteration_count = 0
        self._session_start_time = time.time()

        # Write fresh metadata
        await self.state_backend.write_session_metadata({
            "session_id": "",
            "created_at": time.time(),
            "iteration_count": 0,
            "correlation_id": self.correlation_id,
            "expired_from": old_session_id,
        })

        logger.info("Session expired and cleared: %s", old_session_id[:12] + "..." if old_session_id else "(none)")

    async def _update_session_metadata(self) -> None:
        """Update session metadata after each iteration."""
        await self.state_backend.write_session_metadata({
            "session_id": self.session_id,
            "created_at": self._session_start_time,
            "iteration_count": self._session_iteration_count,
            "correlation_id": self.correlation_id,
            "last_updated": time.time(),
        })

    def get_prompt_cache_stats(self) -> PromptCacheStats:
        """Return current prompt cache statistics.

        SDK-CONTEXT-2: Useful for observability and debugging cache behavior.
        """
        return self._prompt_cache_stats.model_copy()

        # -------------------------------------------------------------------------
    # TheStudio Adapter (SDK-3)
    # -------------------------------------------------------------------------

    async def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
        """Process a TheStudio TaskPacket and return a Signal.

        Converts TaskPacket -> TaskInput, runs iteration, returns TaskResult as Signal.
        """
        task_input = TaskInput.from_task_packet(packet)
        status = await self.run_iteration(task_input)
        result = TaskResult(
            status=status,
            loop_count=self.loop_count,
            duration_seconds=time.time() - self.start_time if self.start_time else 0,
        )
        return result.to_signal()

    # -------------------------------------------------------------------------
    # Tool handlers (for Agent SDK tool registration)
    # -------------------------------------------------------------------------

    async def handle_tool_call(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        """Dispatch tool calls to appropriate async handlers."""
        if tool_name == "ralph_status":
            return await ralph_status_tool(
                ralph_dir=str(self.ralph_dir), **tool_input
            )
        elif tool_name == "ralph_rate_check":
            return await ralph_rate_check_tool(
                ralph_dir=str(self.ralph_dir),
                max_calls_per_hour=self.config.max_calls_per_hour,
            )
        elif tool_name == "ralph_circuit_state":
            return await ralph_circuit_state_tool(
                ralph_dir=str(self.ralph_dir),
            )
        elif tool_name == "ralph_task_update":
            return await ralph_task_update_tool(
                ralph_dir=str(self.ralph_dir), **tool_input
            )
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}

    def get_tool_definitions(self) -> list[dict[str, Any]]:
        """Return tool definitions for Agent SDK registration."""
        return [
            {k: v for k, v in tool.items() if k != "handler"}
            for tool in RALPH_TOOLS
        ]
