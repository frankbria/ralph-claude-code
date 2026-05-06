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
        assert s.work_type == WorkType.UNKNOWN  # nosec B101  # pytest assertion
        assert s.exit_signal is False  # nosec B101  # pytest assertion
        assert s.status == RalphLoopStatus.IN_PROGRESS  # nosec B101  # pytest assertion

    def test_to_dict(self):
        s = RalphStatus(work_type="TESTING", exit_signal=True)
        d = s.to_dict()
        assert d["WORK_TYPE"] == "TESTING"  # nosec B101  # pytest assertion
        assert d["EXIT_SIGNAL"] is True  # nosec B101  # pytest assertion

    def test_from_dict(self):
        s = RalphStatus.from_dict({
            "WORK_TYPE": "ANALYSIS",
            "EXIT_SIGNAL": True,
            "COMPLETED_TASK": "Reviewed code",
        })
        assert s.work_type == WorkType.ANALYSIS  # nosec B101  # pytest assertion
        assert s.exit_signal is True  # nosec B101  # pytest assertion
        assert s.completed_task == "Reviewed code"  # nosec B101  # pytest assertion

    def test_save_and_load(self, ralph_dir):
        s = RalphStatus(work_type="IMPLEMENTATION", completed_task="Did stuff", loop_count=5)
        s.save(ralph_dir)

        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == WorkType.IMPLEMENTATION  # nosec B101  # pytest assertion
        assert loaded.completed_task == "Did stuff"  # nosec B101  # pytest assertion
        assert loaded.loop_count == 5  # nosec B101  # pytest assertion

    def test_load_missing(self, ralph_dir):
        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == WorkType.UNKNOWN  # nosec B101  # pytest assertion

    def test_atomic_write(self, ralph_dir):
        """Temp file should be cleaned up after save."""
        s = RalphStatus(work_type="TESTING")
        s.save(ralph_dir)
        tmp_files = list(Path(ralph_dir).glob("*.tmp"))
        assert len(tmp_files) == 0  # nosec B101  # pytest assertion

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = RalphStatus.model_json_schema()
        assert "properties" in schema  # nosec B101  # pytest assertion
        assert "work_type" in schema["properties"]  # nosec B101  # pytest assertion

    def test_enum_values(self):
        """Enums have expected values."""
        assert WorkType.IMPLEMENTATION.value == "IMPLEMENTATION"  # nosec B101  # pytest assertion
        assert RalphLoopStatus.COMPLETED.value == "COMPLETED"  # nosec B101  # pytest assertion


class TestCircuitBreakerState:
    def test_defaults(self):
        cb = CircuitBreakerState()
        assert cb.state == CircuitBreakerStateEnum.CLOSED  # nosec B101  # pytest assertion
        assert cb.no_progress_count == 0  # nosec B101  # pytest assertion

    def test_trip(self):
        cb = CircuitBreakerState()
        cb.trip("No progress detected")
        assert cb.state == CircuitBreakerStateEnum.OPEN  # nosec B101  # pytest assertion
        assert cb.last_error == "No progress detected"  # nosec B101  # pytest assertion
        assert cb.opened_at != ""  # nosec B101  # pytest assertion

    def test_half_open(self):
        cb = CircuitBreakerState(state="OPEN")
        cb.half_open()
        assert cb.state == CircuitBreakerStateEnum.HALF_OPEN  # nosec B101  # pytest assertion

    def test_close(self):
        cb = CircuitBreakerState(state="HALF_OPEN", no_progress_count=3)
        cb.close()
        assert cb.state == CircuitBreakerStateEnum.CLOSED  # nosec B101  # pytest assertion
        assert cb.no_progress_count == 0  # nosec B101  # pytest assertion

    def test_reset(self):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=5)
        cb.reset("manual")
        assert cb.state == CircuitBreakerStateEnum.CLOSED  # nosec B101  # pytest assertion
        assert cb.no_progress_count == 0  # nosec B101  # pytest assertion

    def test_save_and_load(self, ralph_dir):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=3)
        cb.trip("test error")
        cb.save(ralph_dir)

        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == CircuitBreakerStateEnum.OPEN  # nosec B101  # pytest assertion
        assert loaded.no_progress_count == 3  # nosec B101  # pytest assertion

    def test_load_missing(self, ralph_dir):
        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == CircuitBreakerStateEnum.CLOSED  # nosec B101  # pytest assertion

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = CircuitBreakerState.model_json_schema()
        assert "properties" in schema  # nosec B101  # pytest assertion
        assert "state" in schema["properties"]  # nosec B101  # pytest assertion
