"""Ralph SDK EvidenceBundle — output model compatible with TheStudio schema.

Converts TaskResult into a structured evidence bundle for TheStudio
orchestration, with best-effort test/lint result extraction.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime

from pydantic import BaseModel, Field

from ralph_sdk.agent import TaskResult


class TestEvidence(BaseModel):
    """Extracted test execution results."""
    framework: str = ""
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    errors: int = 0
    raw_output: str = ""


class LintEvidence(BaseModel):
    """Extracted lint/formatting results."""
    tool: str = ""
    errors: int = 0
    warnings: int = 0
    raw_output: str = ""


class EvidenceBundle(BaseModel):
    """Structured evidence bundle compatible with TheStudio schema.

    Contains the full result plus extracted test/lint evidence.
    """
    taskpacket_id: str = ""
    intent_version: str = ""
    loopback_attempt: int = 0
    status: str = "IN_PROGRESS"
    exit_signal: bool = False
    work_type: str = "UNKNOWN"
    completed_task: str = ""
    progress_summary: str = ""
    agent_summary: str = ""
    test_results: list[TestEvidence] = Field(default_factory=list)
    lint_results: list[LintEvidence] = Field(default_factory=list)
    files_modified: list[str] = Field(default_factory=list)
    loop_count: int = 0
    duration_seconds: float = 0.0
    correlation_id: str = ""
    exit_code: int = 0
    error: str = ""
    tokens_in: int = 0
    tokens_out: int = 0
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


def to_evidence_bundle(
    result: TaskResult,
    taskpacket_id: str = "",
    intent_version: str = "",
    loopback_attempt: int = 0,
) -> EvidenceBundle:
    """Convert TaskResult to EvidenceBundle.

    Extracts test and lint results from raw output using best-effort
    pattern matching for pytest/jest/ruff/eslint.
    """
    raw = result.output or ""

    test_results = _extract_test_results(raw)
    lint_results = _extract_lint_results(raw)

    return EvidenceBundle(
        taskpacket_id=taskpacket_id,
        intent_version=intent_version,
        loopback_attempt=loopback_attempt,
        status=result.status.status.value,
        exit_signal=result.status.exit_signal,
        work_type=result.status.work_type.value,
        completed_task=result.status.completed_task,
        progress_summary=result.status.progress_summary,
        agent_summary=raw,
        test_results=test_results,
        lint_results=lint_results,
        loop_count=result.loop_count,
        duration_seconds=result.duration_seconds,
        correlation_id=result.status.correlation_id,
        exit_code=result.exit_code,
        error=result.error,
        tokens_in=result.tokens_in,
        tokens_out=result.tokens_out,
    )


def _extract_test_results(output: str) -> list[TestEvidence]:
    """Best-effort extraction of test results from raw output."""
    results = []

    # pytest: "= X passed, Y failed, Z skipped in Ns =" (requires = delimiter or "in Xs")
    pytest_pattern = r'=+\s*(\d+)\s+passed(?:,\s*(\d+)\s+failed)?(?:,\s*(\d+)\s+skipped)?(?:,\s*(\d+)\s+error)?'
    for match in re.finditer(pytest_pattern, output, re.IGNORECASE):
        passed = int(match.group(1))
        failed = int(match.group(2) or 0)
        skipped = int(match.group(3) or 0)
        errors = int(match.group(4) or 0)
        results.append(TestEvidence(
            framework="pytest",
            total=passed + failed + skipped + errors,
            passed=passed,
            failed=failed,
            skipped=skipped,
            errors=errors,
            raw_output=match.group(0).strip(),
        ))

    # jest: "Tests:  X passed, Y failed, Z total" or "Test Suites: X passed"
    jest_pattern = r'Tests:\s+(?:(\d+)\s+failed,\s*)?(\d+)\s+passed(?:,\s*(\d+)\s+total)?'
    for match in re.finditer(jest_pattern, output, re.IGNORECASE):
        failed = int(match.group(1) or 0)
        passed = int(match.group(2))
        total = int(match.group(3) or (passed + failed))
        results.append(TestEvidence(
            framework="jest",
            total=total,
            passed=passed,
            failed=failed,
            raw_output=match.group(0).strip(),
        ))

    # BATS: "X tests, Y failures" or "ok X - test name"
    bats_pattern = r'(\d+)\s+tests?,\s*(\d+)\s+failures?'
    for match in re.finditer(bats_pattern, output, re.IGNORECASE):
        total = int(match.group(1))
        failed = int(match.group(2))
        results.append(TestEvidence(
            framework="bats",
            total=total,
            passed=total - failed,
            failed=failed,
            raw_output=match.group(0).strip(),
        ))

    return results


def _extract_lint_results(output: str) -> list[LintEvidence]:
    """Best-effort extraction of lint results from raw output."""
    results = []

    # ruff: "Found X errors" or "X errors fixed"
    ruff_pattern = r'(?:Found\s+)?(\d+)\s+error'
    ruff_warn_pattern = r'(\d+)\s+warning'
    for match in re.finditer(ruff_pattern, output):
        # Only match if "ruff" appears nearby
        context_start = max(0, match.start() - 200)
        context = output[context_start:match.end() + 100]
        if "ruff" in context.lower():
            errors = int(match.group(1))
            warns = 0
            warn_match = re.search(ruff_warn_pattern, context)
            if warn_match:
                warns = int(warn_match.group(1))
            results.append(LintEvidence(
                tool="ruff",
                errors=errors,
                warnings=warns,
                raw_output=match.group(0).strip(),
            ))

    # eslint: "X problems (Y errors, Z warnings)"
    eslint_pattern = r'(\d+)\s+problems?\s*\((\d+)\s+errors?,\s*(\d+)\s+warnings?\)'
    for match in re.finditer(eslint_pattern, output, re.IGNORECASE):
        results.append(LintEvidence(
            tool="eslint",
            errors=int(match.group(2)),
            warnings=int(match.group(3)),
            raw_output=match.group(0).strip(),
        ))

    return results
