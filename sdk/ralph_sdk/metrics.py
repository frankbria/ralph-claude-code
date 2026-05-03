"""Ralph SDK Metrics Collection — SDK-OUTPUT-4.

Provides a Protocol-based metrics pipeline with two concrete implementations:

- **JsonlMetricsCollector**: Writes monthly JSONL files to ``.ralph/metrics/``
  (matches the CLI ``lib/metrics.sh`` format).
- **NullMetricsCollector**: No-op implementation for testing and embedding
  scenarios that don't need persistent metrics.
"""

from __future__ import annotations

import logging
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from pydantic import BaseModel, Field, ValidationError

logger = logging.getLogger("ralph.sdk.metrics")


# =============================================================================
# MetricEvent model
# =============================================================================

class MetricEvent(BaseModel):
    """A single metric data point recorded after an iteration or notable event.

    All fields are optional beyond ``event_type`` so callers can record partial
    events (e.g. an error event may lack ``tokens_in``).
    """
    timestamp: str = Field(default_factory=lambda: datetime.now(UTC).isoformat())
    event_type: str = ""
    loop_count: int = 0
    duration_seconds: float = 0.0
    work_type: str = ""
    files_changed: list[str] = Field(default_factory=list)
    tokens_in: int = 0
    tokens_out: int = 0
    model: str = ""
    cost_usd: float | None = None

    def to_jsonl_line(self) -> str:
        """Serialize to a single JSON line (no trailing newline)."""
        return self.model_dump_json()


# =============================================================================
# MetricsCollector Protocol
# =============================================================================

@runtime_checkable
class MetricsCollector(Protocol):
    """Abstract interface for metrics collection backends."""

    def record(self, event: MetricEvent) -> None:
        """Persist a single metric event."""
        ...

    def query(self, filter: dict[str, Any] | None = None) -> list[MetricEvent]:
        """Retrieve recorded events, optionally filtered.

        Supported filter keys (all optional):
        - ``event_type``: str — exact match on event_type
        - ``since``: str (ISO 8601) — events at or after this timestamp
        - ``until``: str (ISO 8601) — events at or before this timestamp
        - ``loop_count``: int — exact match on loop_count
        - ``work_type``: str — exact match on work_type
        """
        ...


# =============================================================================
# NullMetricsCollector — no-op for testing
# =============================================================================

class NullMetricsCollector:
    """No-op metrics collector for testing and embedding scenarios."""

    def record(self, event: MetricEvent) -> None:  # noqa: D102
        pass

    def query(self, filter: dict[str, Any] | None = None) -> list[MetricEvent]:  # noqa: D102
        return []


# =============================================================================
# JsonlMetricsCollector — monthly JSONL files in .ralph/metrics/
# =============================================================================

class JsonlMetricsCollector:
    """Writes metric events as JSONL to monthly files under ``.ralph/metrics/``.

    File naming matches the CLI ``lib/metrics.sh`` convention::

        .ralph/metrics/metrics-YYYY-MM.jsonl

    Thread-safety: single-writer assumption (one agent per project directory).
    """

    def __init__(self, ralph_dir: str | Path = ".ralph") -> None:
        self._metrics_dir = Path(ralph_dir) / "metrics"
        self._metrics_dir.mkdir(parents=True, exist_ok=True)

    # -- Protocol methods -----------------------------------------------------

    def record(self, event: MetricEvent) -> None:
        """Append a metric event to the current month's JSONL file."""
        path = self._current_file()
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write(event.to_jsonl_line() + "\n")
        except OSError:
            logger.debug("Failed to write metric event to %s", path, exc_info=True)

    def query(self, filter: dict[str, Any] | None = None) -> list[MetricEvent]:
        """Read and filter metric events from all monthly JSONL files.

        This scans every ``metrics-*.jsonl`` file in the metrics directory.
        For large histories, callers should use the ``since``/``until``
        filter keys to limit the scan.
        """
        events: list[MetricEvent] = []
        for path in sorted(self._metrics_dir.glob("metrics-*.jsonl")):
            try:
                with open(path, encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = MetricEvent.model_validate_json(line)
                            if self._matches_filter(event, filter):
                                events.append(event)
                        except (ValidationError, ValueError) as e:
                            # Skip malformed JSONL lines (partial writes from a
                            # crashed process); log at debug for diagnosis.
                            logger.debug("Skipping malformed metric line: %s", e)
                            continue
            except OSError:
                logger.debug("Failed to read metrics file %s", path, exc_info=True)
        return events

    # -- Private helpers ------------------------------------------------------

    def _current_file(self) -> Path:
        """Return the path to the current month's JSONL file."""
        month_str = time.strftime("%Y-%m")
        return self._metrics_dir / f"metrics-{month_str}.jsonl"

    @staticmethod
    def _matches_filter(event: MetricEvent, filter: dict[str, Any] | None) -> bool:
        """Check whether an event matches the given filter criteria."""
        if filter is None:
            return True

        if "event_type" in filter and event.event_type != filter["event_type"]:
            return False
        if "loop_count" in filter and event.loop_count != filter["loop_count"]:
            return False
        if "work_type" in filter and event.work_type != filter["work_type"]:
            return False
        if "since" in filter and event.timestamp < filter["since"]:
            return False
        if "until" in filter and event.timestamp > filter["until"]:
            return False

        return True
