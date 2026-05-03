"""Ralph SDK active circuit breaker — state machine with sliding window failure detection.

Replaces the passive check_circuit_breaker() with active state management:
- record_success() — HALF_OPEN -> CLOSED
- record_failure(reason) — sliding window detection, trip when threshold hit
- record_no_progress() — consecutive zero-work detection
- can_proceed() — OPEN -> HALF_OPEN after cooldown

Stall detectors (SDK-SAFETY-1):
- FastTripDetector — consecutive 0-tool-use runs completing in <30s
- DeferredTestDetector — consecutive TESTS_STATUS: DEFERRED loops
- ConsecutiveTimeoutDetector — consecutive timeout runs

State transitions:
  CLOSED -> OPEN (threshold failures or no-progress reached)
  OPEN -> HALF_OPEN (cooldown elapsed)
  HALF_OPEN -> CLOSED (success recorded)
  HALF_OPEN -> OPEN (failure recorded)
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from ralph_sdk.config import RalphConfig
from ralph_sdk.state import RalphStateBackend
from ralph_sdk.status import CircuitBreakerState, CircuitBreakerStateEnum

logger = logging.getLogger("ralph.sdk")


# =============================================================================
# SDK-SAFETY-1: Stall Detection
# =============================================================================


@dataclass
class StallDetectorResult:
    """Result from a stall detector check."""

    should_trip: bool = False
    should_warn: bool = False
    reason: str = ""
    count: int = 0
    threshold: int = 0


class FastTripDetector:
    """Detect consecutive 0-tool-use runs completing in <threshold seconds.

    When Claude completes a run very quickly without using any tools, it
    typically indicates a stall — the model is producing text-only responses
    without making progress. Trip the circuit breaker after
    MAX_CONSECUTIVE_FAST_FAILURES consecutive such runs.
    """

    def __init__(
        self,
        max_consecutive: int = 3,
        threshold_seconds: float = 30.0,
    ) -> None:
        self.max_consecutive = max_consecutive
        self.threshold_seconds = threshold_seconds
        self._consecutive_count: int = 0

    def record(self, duration_seconds: float, tool_use_count: int) -> StallDetectorResult:
        """Record an iteration and check for fast-trip condition.

        Args:
            duration_seconds: Wall-clock duration of the iteration.
            tool_use_count: Number of tool calls made during the iteration.

        Returns:
            StallDetectorResult with should_trip=True if threshold reached.
        """
        if tool_use_count == 0 and duration_seconds < self.threshold_seconds:
            self._consecutive_count += 1
            logger.debug(
                "FastTripDetector: fast failure %d/%d (%.1fs, 0 tools)",
                self._consecutive_count,
                self.max_consecutive,
                duration_seconds,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Fast trip: {self._consecutive_count} consecutive 0-tool-use "
                        f"runs completing in <{self.threshold_seconds}s"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive fast failure count."""
        return self._consecutive_count


class DeferredTestDetector:
    """Detect consecutive TESTS_STATUS: DEFERRED loops.

    When tests are deferred too many times in a row, the agent may be stuck
    in a loop where it never actually runs tests. Warn early and trip the
    circuit breaker if the pattern continues.
    """

    def __init__(
        self,
        warn_at: int = 5,
        max_consecutive: int = 10,
    ) -> None:
        self.warn_at = warn_at
        self.max_consecutive = max_consecutive
        self._consecutive_count: int = 0

    def record(self, tests_deferred: bool) -> StallDetectorResult:
        """Record whether tests were deferred this iteration.

        Args:
            tests_deferred: True if TESTS_STATUS was DEFERRED this iteration.

        Returns:
            StallDetectorResult with should_warn or should_trip set.
        """
        if tests_deferred:
            self._consecutive_count += 1
            logger.debug(
                "DeferredTestDetector: deferred %d/%d",
                self._consecutive_count,
                self.max_consecutive,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Deferred tests: {self._consecutive_count} consecutive "
                        f"TESTS_STATUS: DEFERRED loops (threshold: {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            if self._consecutive_count >= self.warn_at:
                return StallDetectorResult(
                    should_warn=True,
                    reason=(
                        f"Deferred tests warning: {self._consecutive_count} consecutive "
                        f"TESTS_STATUS: DEFERRED loops (trip at {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive deferred test count."""
        return self._consecutive_count


class ConsecutiveTimeoutDetector:
    """Detect consecutive timeout iterations.

    Multiple consecutive timeouts indicate the task may be too large or the
    agent is stuck in an unbounded operation. Trip the circuit breaker after
    MAX_CONSECUTIVE_TIMEOUTS.
    """

    def __init__(self, max_consecutive: int = 5) -> None:
        self.max_consecutive = max_consecutive
        self._consecutive_count: int = 0

    def record(self, timed_out: bool) -> StallDetectorResult:
        """Record whether this iteration timed out.

        Args:
            timed_out: True if the iteration ended due to timeout.

        Returns:
            StallDetectorResult with should_trip=True if threshold reached.
        """
        if timed_out:
            self._consecutive_count += 1
            logger.debug(
                "ConsecutiveTimeoutDetector: timeout %d/%d",
                self._consecutive_count,
                self.max_consecutive,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Consecutive timeouts: {self._consecutive_count} in a row "
                        f"(threshold: {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive timeout count."""
        return self._consecutive_count


class CircuitBreaker:
    """Active circuit breaker with sliding window failure detection.

    Matches lib/circuit_breaker.sh behavior for common scenarios while
    providing programmatic state management via the state backend.

    Integrates SDK-SAFETY-1 stall detectors (FastTrip, DeferredTest,
    ConsecutiveTimeout) which can independently trip the breaker.
    """

    def __init__(
        self,
        state_backend: RalphStateBackend,
        *,
        no_progress_threshold: int = 3,
        same_error_threshold: int = 5,
        cooldown_minutes: int = 30,
        auto_reset: bool = False,
        failure_window_minutes: int = 60,
        config: RalphConfig | None = None,
    ) -> None:
        self.state_backend = state_backend
        self.no_progress_threshold = no_progress_threshold
        self.same_error_threshold = same_error_threshold
        self.cooldown_minutes = cooldown_minutes
        self.auto_reset = auto_reset
        self.failure_window_minutes = failure_window_minutes

        # Sliding window: list of (timestamp, reason) tuples
        self._failure_window: list[tuple[float, str]] = []

        # SDK-SAFETY-1: Stall detectors (thresholds from config or defaults)
        _cfg = config or RalphConfig()
        self.fast_trip_detector = FastTripDetector(
            max_consecutive=_cfg.cb_max_consecutive_fast_failures,
            threshold_seconds=_cfg.cb_fast_failure_threshold_seconds,
        )
        self.deferred_test_detector = DeferredTestDetector(
            warn_at=_cfg.cb_deferred_tests_warn_at,
            max_consecutive=_cfg.cb_max_deferred_tests,
        )
        self.consecutive_timeout_detector = ConsecutiveTimeoutDetector(
            max_consecutive=_cfg.cb_max_consecutive_timeouts,
        )

    async def _load_state(self) -> CircuitBreakerState:
        """Load current state from backend."""
        data = await self.state_backend.read_circuit_breaker()
        if data:
            return CircuitBreakerState._from_state_dict(data)
        return CircuitBreakerState()

    async def _save_state(self, cb: CircuitBreakerState) -> None:
        """Save state to backend."""
        await self.state_backend.write_circuit_breaker(cb._to_state_dict())

    async def can_proceed(self) -> bool:
        """Check if the loop can proceed.

        Returns True if CLOSED or HALF_OPEN.
        If OPEN and cooldown has elapsed, transitions to HALF_OPEN.
        If auto_reset is True, bypasses cooldown.
        """
        cb = await self._load_state()

        if cb.state == CircuitBreakerStateEnum.CLOSED:
            return True

        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            return True

        # OPEN state — check cooldown
        if cb.state == CircuitBreakerStateEnum.OPEN:
            if self.auto_reset:
                cb.half_open()
                await self._save_state(cb)
                return True

            if cb.opened_at:
                try:
                    # TAP-630: use a tz-aware datetime.timestamp() instead of
                    # time.mktime — the latter treats the struct_time as local
                    # time and ignores tm_gmtoff on macOS/BSD/musl, shifting
                    # the cooldown by the local UTC offset.
                    opened_time = datetime.strptime(
                        cb.opened_at, "%Y-%m-%dT%H:%M:%S%z"
                    ).timestamp()
                except (ValueError, OverflowError):
                    # Can't parse timestamp, allow transition
                    opened_time = 0.0

                elapsed_minutes = (time.time() - opened_time) / 60
                if elapsed_minutes >= self.cooldown_minutes:
                    cb.half_open()
                    await self._save_state(cb)
                    return True

        return False

    async def record_success(self) -> None:
        """Record a successful iteration.

        HALF_OPEN -> CLOSED with counter reset.
        CLOSED -> stays CLOSED with counters reset.
        """
        cb = await self._load_state()

        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            cb.close()
        elif cb.state == CircuitBreakerStateEnum.CLOSED:
            # Reset progressive counters on success
            cb.no_progress_count = 0
            cb.same_error_count = 0
            cb.last_error = ""
            cb.last_transition = "CLOSED: success"

        # Clear sliding window on success
        self._failure_window.clear()

        # Reset stall detectors on success
        self.fast_trip_detector.reset()
        self.deferred_test_detector.reset()
        self.consecutive_timeout_detector.reset()

        await self._save_state(cb)

    async def record_failure(self, reason: str = "") -> None:
        """Record a failure.

        Uses sliding window: only failures within the window period count.
        If same_error_threshold reached, trips to OPEN.
        HALF_OPEN -> OPEN immediately on any failure.
        """
        cb = await self._load_state()
        now = time.time()

        # HALF_OPEN fails immediately back to OPEN
        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            cb.trip(reason)
            await self._save_state(cb)
            return

        # Add to sliding window
        self._failure_window.append((now, reason))

        # Prune old entries outside the window
        cutoff = now - (self.failure_window_minutes * 60)
        self._failure_window = [
            (ts, r) for ts, r in self._failure_window if ts >= cutoff
        ]

        # Count same errors in window
        if reason:
            same_count = sum(1 for _, r in self._failure_window if r == reason)
            cb.same_error_count = same_count

            if same_count >= self.same_error_threshold:
                cb.trip(f"Same error threshold ({self.same_error_threshold}): {reason}")
                await self._save_state(cb)
                return

        cb.last_error = reason
        cb.last_transition = f"CLOSED: failure recorded ({reason})"
        await self._save_state(cb)

    async def record_no_progress(self) -> None:
        """Record a zero-work iteration (no files changed, no tasks completed).

        Increments no_progress_count. Trips to OPEN when threshold reached.
        """
        cb = await self._load_state()
        cb.no_progress_count += 1

        if cb.no_progress_count >= self.no_progress_threshold:
            cb.trip(f"No progress threshold ({self.no_progress_threshold}) reached")
        else:
            cb.last_transition = f"CLOSED: no progress ({cb.no_progress_count}/{self.no_progress_threshold})"

        await self._save_state(cb)

    async def record_fast_iteration(
        self, duration_seconds: float, tool_use_count: int
    ) -> StallDetectorResult:
        """Record a fast iteration for stall detection (SDK-SAFETY-1).

        Delegates to FastTripDetector. Trips the circuit breaker if the
        consecutive fast-failure threshold is reached.

        Args:
            duration_seconds: Wall-clock duration of the iteration.
            tool_use_count: Number of tool calls made during the iteration.

        Returns:
            StallDetectorResult indicating whether the breaker was tripped.
        """
        result = self.fast_trip_detector.record(duration_seconds, tool_use_count)
        if result.should_trip:
            cb = await self._load_state()
            cb.trip(result.reason)
            await self._save_state(cb)
            logger.warning("Circuit breaker tripped: %s", result.reason)
        return result

    async def record_deferred_tests(self, tests_deferred: bool) -> StallDetectorResult:
        """Record a deferred-tests iteration for stall detection (SDK-SAFETY-1).

        Delegates to DeferredTestDetector. Warns at the warning threshold
        and trips the circuit breaker at the max threshold.

        Args:
            tests_deferred: True if TESTS_STATUS was DEFERRED this iteration.

        Returns:
            StallDetectorResult indicating warning or trip status.
        """
        result = self.deferred_test_detector.record(tests_deferred)
        if result.should_trip:
            cb = await self._load_state()
            cb.trip(result.reason)
            await self._save_state(cb)
            logger.warning("Circuit breaker tripped: %s", result.reason)
        elif result.should_warn:
            logger.warning("Stall warning: %s", result.reason)
        return result

    async def record_timeout(self, timed_out: bool) -> StallDetectorResult:
        """Record a timeout iteration for stall detection (SDK-SAFETY-1).

        Delegates to ConsecutiveTimeoutDetector. Trips the circuit breaker
        if the consecutive timeout threshold is reached.

        Args:
            timed_out: True if the iteration ended due to timeout.

        Returns:
            StallDetectorResult indicating whether the breaker was tripped.
        """
        result = self.consecutive_timeout_detector.record(timed_out)
        if result.should_trip:
            cb = await self._load_state()
            cb.trip(result.reason)
            await self._save_state(cb)
            logger.warning("Circuit breaker tripped: %s", result.reason)
        return result

    async def reset(self, reason: str = "manual") -> None:
        """Reset circuit breaker to CLOSED state."""
        cb = CircuitBreakerState()
        cb.last_transition = f"RESET: {reason}"
        self._failure_window.clear()
        # Reset all stall detectors
        self.fast_trip_detector.reset()
        self.deferred_test_detector.reset()
        self.consecutive_timeout_detector.reset()
        await self._save_state(cb)

    async def get_state(self) -> dict[str, Any]:
        """Get current state as a dictionary (includes stall detector counts)."""
        cb = await self._load_state()
        return {
            "state": cb.state.value,
            "no_progress_count": cb.no_progress_count,
            "same_error_count": cb.same_error_count,
            "last_error": cb.last_error,
            "opened_at": cb.opened_at,
            "last_transition": cb.last_transition,
            "can_proceed": cb.state in (CircuitBreakerStateEnum.CLOSED, CircuitBreakerStateEnum.HALF_OPEN),
            # SDK-SAFETY-1: Stall detector counters
            "consecutive_fast_failures": self.fast_trip_detector.consecutive_count,
            "consecutive_deferred_tests": self.deferred_test_detector.consecutive_count,
            "consecutive_timeouts": self.consecutive_timeout_detector.consecutive_count,
        }
