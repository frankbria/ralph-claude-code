"""Tests for ralph_sdk.agent_models — extracted models and helpers."""
from __future__ import annotations

from ralph_sdk.agent_models import (
    CancelResult,
    ContinueAsNewState,
    DecompositionHint,
    IterationRecord,
    ProgressSnapshot,
    TaskInput,
    TaskResult,
    compute_adaptive_timeout,
    detect_decomposition_needed,
)
from ralph_sdk.config import RalphConfig
from ralph_sdk.status import RalphStatus


class TestComputeAdaptiveTimeout:
    def test_empty_history_returns_min(self) -> None:
        assert compute_adaptive_timeout([]) == 5  # nosec B101  # pytest assertion

    def test_clamps_to_min(self) -> None:
        assert compute_adaptive_timeout([1.0, 2.0, 3.0], min_minutes=10) == 10  # nosec B101  # pytest assertion

    def test_clamps_to_max(self) -> None:
        # 100-minute durations × 2 multiplier → 200 min, clamped to max
        long_history = [6000.0] * 5
        assert compute_adaptive_timeout(long_history, max_minutes=30) == 30  # nosec B101  # pytest assertion

    def test_p95_calculation(self) -> None:
        # 20 samples of 1200s → P95 ≈ 1200s × 2 = 2400s = 40 min
        history = [1200.0] * 20
        result = compute_adaptive_timeout(history, multiplier=2.0, min_minutes=5, max_minutes=60)
        assert result == 40  # nosec B101  # pytest assertion


class TestDetectDecomposition:
    def test_no_factors_no_decompose(self) -> None:
        status = RalphStatus(next_task="trivial fix", progress_summary="")
        hint = detect_decomposition_needed(status, [], RalphConfig())
        assert hint.should_decompose is False  # nosec B101  # pytest assertion

    def test_two_factors_triggers_decompose(self) -> None:
        # previous_timeout + complexity keyword (HIGH bumps to >=4 with file boost)
        status = RalphStatus(
            next_task="refactor a.py , b.py , c.py , d.py , e.py , f.py , g.py , h.py",
            progress_summary="cross-cutting overhaul",
        )
        history = [IterationRecord(timed_out=True)]
        hint = detect_decomposition_needed(status, history, RalphConfig())
        assert hint.should_decompose is True  # nosec B101  # pytest assertion
        assert hint.suggested_split >= 2  # nosec B101  # pytest assertion
        assert hint.suggested_split <= 5  # nosec B101  # pytest assertion

    def test_consecutive_no_progress_counted(self) -> None:
        status = RalphStatus(next_task="ok")
        history = [
            IterationRecord(had_progress=False),
            IterationRecord(had_progress=False),
            IterationRecord(had_progress=False),
        ]
        # 3 no-progress + a complexity keyword → 2 factors
        status = RalphStatus(next_task="refactor everything")
        hint = detect_decomposition_needed(status, history, RalphConfig())
        assert hint.factors["consecutive_no_progress"] is True  # nosec B101  # pytest assertion


class TestTaskInput:
    def test_from_ralph_dir_missing(self, tmp_path) -> None:  # type: ignore[no-untyped-def]
        ti = TaskInput.from_ralph_dir(tmp_path / ".ralph")
        assert ti.prompt == ""  # nosec B101  # pytest assertion
        assert ti.fix_plan == ""  # nosec B101  # pytest assertion

    def test_from_ralph_dir_reads_files(self, tmp_path) -> None:  # type: ignore[no-untyped-def]
        d = tmp_path / ".ralph"
        d.mkdir()
        (d / "PROMPT.md").write_text("hello")
        (d / "fix_plan.md").write_text("- [ ] task")
        (d / "AGENT.md").write_text("agent")
        ti = TaskInput.from_ralph_dir(d)
        assert ti.prompt == "hello"  # nosec B101  # pytest assertion
        assert "task" in ti.fix_plan  # nosec B101  # pytest assertion
        assert ti.agent_instructions == "agent"  # nosec B101  # pytest assertion

    def test_from_task_packet(self) -> None:
        packet = {"id": "abc", "type": "story", "prompt": "p"}
        ti = TaskInput.from_task_packet(packet)
        assert ti.task_packet_id == "abc"  # nosec B101  # pytest assertion
        assert ti.task_packet_type == "story"  # nosec B101  # pytest assertion
        assert ti.prompt == "p"  # nosec B101  # pytest assertion


class TestTaskResult:
    def test_to_signal_includes_files(self) -> None:
        r = TaskResult(files_changed=["a.py"], exit_code=1)
        sig = r.to_signal()
        assert sig["type"] == "ralph_result"  # nosec B101  # pytest assertion
        assert sig["exit_code"] == 1  # nosec B101  # pytest assertion
        assert sig["files_changed"] == ["a.py"]  # nosec B101  # pytest assertion


class TestContinueAsNewState:
    def test_round_trip(self) -> None:
        s = ContinueAsNewState(current_task="t", progress="p", continued_from_loop=3)
        d = s.to_dict()
        s2 = ContinueAsNewState.from_dict(d)
        assert s2.current_task == "t"  # nosec B101  # pytest assertion
        assert s2.continued_from_loop == 3  # nosec B101  # pytest assertion


class TestModelDefaults:
    def test_decomposition_hint_defaults(self) -> None:
        h = DecompositionHint()
        assert h.should_decompose is False  # nosec B101  # pytest assertion
        assert h.suggested_split == 1  # nosec B101  # pytest assertion

    def test_iteration_record_defaults(self) -> None:
        r = IterationRecord()
        assert r.loop_count == 0  # nosec B101  # pytest assertion
        assert r.had_progress is False  # nosec B101  # pytest assertion

    def test_progress_snapshot_defaults(self) -> None:
        s = ProgressSnapshot()
        assert s.work_type == "UNKNOWN"  # nosec B101  # pytest assertion

    def test_cancel_result_defaults(self) -> None:
        c = CancelResult()
        assert c.was_forced is False  # nosec B101  # pytest assertion
        assert c.iterations_completed == 0  # nosec B101  # pytest assertion
