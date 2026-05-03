"""Tests for Ralph SDK status and circuit breaker (Pydantic v2 models)."""

from pathlib import Path

import pytest

from ralph_sdk.status import (
    CircuitBreakerState,
    CircuitBreakerStateEnum,
    RalphLoopStatus,
    RalphStatus,
    WorkType,
)


@pytest.fixture
def ralph_dir(tmp_path):
    d = tmp_path / ".ralph"
    d.mkdir()
    return str(d)


class TestRalphStatus:
    def test_defaults(self):
        s = RalphStatus()
        assert s.work_type == WorkType.UNKNOWN
        assert s.exit_signal is False
        assert s.status == RalphLoopStatus.IN_PROGRESS

    def test_to_dict(self):
        s = RalphStatus(work_type="TESTING", exit_signal=True)
        d = s.to_dict()
        assert d["WORK_TYPE"] == "TESTING"
        assert d["EXIT_SIGNAL"] is True

    def test_from_dict(self):
        s = RalphStatus.from_dict({
            "WORK_TYPE": "ANALYSIS",
            "EXIT_SIGNAL": True,
            "COMPLETED_TASK": "Reviewed code",
        })
        assert s.work_type == WorkType.ANALYSIS
        assert s.exit_signal is True
        assert s.completed_task == "Reviewed code"

    def test_save_and_load(self, ralph_dir):
        s = RalphStatus(work_type="IMPLEMENTATION", completed_task="Did stuff", loop_count=5)
        s.save(ralph_dir)

        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == WorkType.IMPLEMENTATION
        assert loaded.completed_task == "Did stuff"
        assert loaded.loop_count == 5

    def test_load_missing(self, ralph_dir):
        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == WorkType.UNKNOWN

    def test_atomic_write(self, ralph_dir):
        """Temp file should be cleaned up after save."""
        s = RalphStatus(work_type="TESTING")
        s.save(ralph_dir)
        tmp_files = list(Path(ralph_dir).glob("*.tmp"))
        assert len(tmp_files) == 0

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = RalphStatus.model_json_schema()
        assert "properties" in schema
        assert "work_type" in schema["properties"]

    def test_enum_values(self):
        """Enums have expected values."""
        assert WorkType.IMPLEMENTATION.value == "IMPLEMENTATION"
        assert RalphLoopStatus.COMPLETED.value == "COMPLETED"


class TestCircuitBreakerState:
    def test_defaults(self):
        cb = CircuitBreakerState()
        assert cb.state == CircuitBreakerStateEnum.CLOSED
        assert cb.no_progress_count == 0

    def test_trip(self):
        cb = CircuitBreakerState()
        cb.trip("No progress detected")
        assert cb.state == CircuitBreakerStateEnum.OPEN
        assert cb.last_error == "No progress detected"
        assert cb.opened_at != ""

    def test_half_open(self):
        cb = CircuitBreakerState(state="OPEN")
        cb.half_open()
        assert cb.state == CircuitBreakerStateEnum.HALF_OPEN

    def test_close(self):
        cb = CircuitBreakerState(state="HALF_OPEN", no_progress_count=3)
        cb.close()
        assert cb.state == CircuitBreakerStateEnum.CLOSED
        assert cb.no_progress_count == 0

    def test_reset(self):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=5)
        cb.reset("manual")
        assert cb.state == CircuitBreakerStateEnum.CLOSED
        assert cb.no_progress_count == 0

    def test_save_and_load(self, ralph_dir):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=3)
        cb.trip("test error")
        cb.save(ralph_dir)

        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == CircuitBreakerStateEnum.OPEN
        assert loaded.no_progress_count == 3

    def test_load_missing(self, ralph_dir):
        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == CircuitBreakerStateEnum.CLOSED

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = CircuitBreakerState.model_json_schema()
        assert "properties" in schema
        assert "state" in schema["properties"]
