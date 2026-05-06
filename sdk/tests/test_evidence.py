"""Tests for Ralph SDK EvidenceBundle output."""


from ralph_sdk.agent import TaskResult
from ralph_sdk.evidence import (
    EvidenceBundle,
    _extract_lint_results,
    _extract_test_results,
    to_evidence_bundle,
)
from ralph_sdk.status import RalphStatus


class TestToEvidenceBundle:
    def test_basic_conversion(self):
        status = RalphStatus(
            work_type="IMPLEMENTATION",
            completed_task="Built feature",
            progress_summary="50% done",
            exit_signal=False,
            correlation_id="corr-123",
        )
        result = TaskResult(
            status=status,
            exit_code=0,
            output="Some output",
            loop_count=3,
            duration_seconds=45.0,
        )
        bundle = to_evidence_bundle(result, taskpacket_id="tp-1", intent_version="v1")
        assert bundle.taskpacket_id == "tp-1"  # nosec B101  # pytest assertion
        assert bundle.intent_version == "v1"  # nosec B101  # pytest assertion
        assert bundle.status == "IN_PROGRESS"  # nosec B101  # pytest assertion
        assert bundle.work_type == "IMPLEMENTATION"  # nosec B101  # pytest assertion
        assert bundle.completed_task == "Built feature"  # nosec B101  # pytest assertion
        assert bundle.agent_summary == "Some output"  # nosec B101  # pytest assertion
        assert bundle.correlation_id == "corr-123"  # nosec B101  # pytest assertion
        assert bundle.loop_count == 3  # nosec B101  # pytest assertion

    def test_json_round_trip(self):
        bundle = EvidenceBundle(
            taskpacket_id="tp-1",
            status="COMPLETED",
            exit_signal=True,
        )
        json_str = bundle.model_dump_json()
        loaded = EvidenceBundle.model_validate_json(json_str)
        assert loaded.taskpacket_id == "tp-1"  # nosec B101  # pytest assertion
        assert loaded.exit_signal is True  # nosec B101  # pytest assertion

    def test_schema(self):
        schema = EvidenceBundle.model_json_schema()
        assert "properties" in schema  # nosec B101  # pytest assertion
        assert "taskpacket_id" in schema["properties"]  # nosec B101  # pytest assertion


class TestExtractTestResults:
    def test_pytest_output(self):
        output = "========================= 42 passed, 3 failed, 1 skipped in 12.34s ========================="
        results = _extract_test_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].framework == "pytest"  # nosec B101  # pytest assertion
        assert results[0].passed == 42  # nosec B101  # pytest assertion
        assert results[0].failed == 3  # nosec B101  # pytest assertion
        assert results[0].skipped == 1  # nosec B101  # pytest assertion
        assert results[0].total == 46  # nosec B101  # pytest assertion

    def test_pytest_all_passed(self):
        output = "====== 100 passed in 5.00s ======"
        results = _extract_test_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].passed == 100  # nosec B101  # pytest assertion
        assert results[0].failed == 0  # nosec B101  # pytest assertion

    def test_jest_output(self):
        output = "Tests:  2 failed, 48 passed, 50 total"
        results = _extract_test_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].framework == "jest"  # nosec B101  # pytest assertion
        assert results[0].passed == 48  # nosec B101  # pytest assertion
        assert results[0].failed == 2  # nosec B101  # pytest assertion
        assert results[0].total == 50  # nosec B101  # pytest assertion

    def test_bats_output(self):
        output = "30 tests, 2 failures"
        results = _extract_test_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].framework == "bats"  # nosec B101  # pytest assertion
        assert results[0].total == 30  # nosec B101  # pytest assertion
        assert results[0].failed == 2  # nosec B101  # pytest assertion
        assert results[0].passed == 28  # nosec B101  # pytest assertion

    def test_no_test_output(self):
        results = _extract_test_results("just some regular output with no test results")
        assert len(results) == 0  # nosec B101  # pytest assertion


class TestExtractLintResults:
    def test_eslint_output(self):
        output = "✖ 15 problems (10 errors, 5 warnings)"
        results = _extract_lint_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].tool == "eslint"  # nosec B101  # pytest assertion
        assert results[0].errors == 10  # nosec B101  # pytest assertion
        assert results[0].warnings == 5  # nosec B101  # pytest assertion

    def test_ruff_output(self):
        output = "Running ruff check...\nFound 3 errors"
        results = _extract_lint_results(output)
        assert len(results) == 1  # nosec B101  # pytest assertion
        assert results[0].tool == "ruff"  # nosec B101  # pytest assertion
        assert results[0].errors == 3  # nosec B101  # pytest assertion

    def test_no_lint_output(self):
        results = _extract_lint_results("just some regular output")
        assert len(results) == 0  # nosec B101  # pytest assertion
