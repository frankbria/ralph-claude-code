"""Tests for Ralph SDK custom tools."""

import json
import time
from pathlib import Path

import pytest

from ralph_sdk.tools import (
    RALPH_TOOLS,
    ralph_circuit_state_tool,
    ralph_rate_check_tool,
    ralph_status_tool,
    ralph_task_update_tool,
)


@pytest.fixture
def ralph_dir(tmp_path):
    """Create a minimal .ralph directory."""
    d = tmp_path / ".ralph"
    d.mkdir()
    return str(d)


class TestRalphStatusTool:
    @pytest.mark.asyncio
    async def test_writes_status_json(self, ralph_dir):
        result = await ralph_status_tool(
            work_type="IMPLEMENTATION",
            completed_task="Added login form",
            next_task="Add validation",
            progress_summary="50% complete",
            exit_signal=False,
            ralph_dir=ralph_dir,
        )
        assert result["ok"] is True
        status_file = Path(ralph_dir) / "status.json"
        assert status_file.exists()
        data = json.loads(status_file.read_text())
        assert data["WORK_TYPE"] == "IMPLEMENTATION"
        assert data["EXIT_SIGNAL"] is False

    @pytest.mark.asyncio
    async def test_exit_signal_sets_completed(self, ralph_dir):
        result = await ralph_status_tool(
            work_type="IMPLEMENTATION",
            completed_task="All done",
            progress_summary="Complete",
            exit_signal=True,
            ralph_dir=ralph_dir,
        )
        status_file = Path(ralph_dir) / "status.json"
        data = json.loads(status_file.read_text())
        assert data["EXIT_SIGNAL"] is True
        assert data["status"] == "COMPLETED"


class TestRalphRateCheckTool:
    @pytest.mark.asyncio
    async def test_fresh_state(self, ralph_dir):
        result = await ralph_rate_check_tool(ralph_dir=ralph_dir, max_calls_per_hour=100)
        assert result["ok"] is True
        assert result["calls_remaining"] == 100
        assert result["rate_limited"] is False

    @pytest.mark.asyncio
    async def test_at_limit(self, ralph_dir):
        (Path(ralph_dir) / ".call_count").write_text("100")
        (Path(ralph_dir) / ".last_reset").write_text(str(int(time.time())))
        result = await ralph_rate_check_tool(ralph_dir=ralph_dir, max_calls_per_hour=100)
        assert result["calls_remaining"] == 0
        assert result["rate_limited"] is True

    @pytest.mark.asyncio
    async def test_expired_resets(self, ralph_dir):
        (Path(ralph_dir) / ".call_count").write_text("100")
        (Path(ralph_dir) / ".last_reset").write_text(str(int(time.time()) - 7200))
        result = await ralph_rate_check_tool(ralph_dir=ralph_dir, max_calls_per_hour=100)
        # Elapsed > 3600 so counter is virtually reset — full quota available
        assert result["calls_remaining"] == 100


class TestRalphCircuitStateTool:
    @pytest.mark.asyncio
    async def test_default_closed(self, ralph_dir):
        result = await ralph_circuit_state_tool(ralph_dir=ralph_dir)
        assert result["ok"] is True
        assert result["state"] == "CLOSED"
        assert result["can_proceed"] is True

    @pytest.mark.asyncio
    async def test_open_blocks(self, ralph_dir):
        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        cb_file.write_text(json.dumps({"state": "OPEN", "no_progress_count": 3}))
        result = await ralph_circuit_state_tool(ralph_dir=ralph_dir)
        assert result["state"] == "OPEN"
        assert result["can_proceed"] is False

    @pytest.mark.asyncio
    async def test_half_open_allows(self, ralph_dir):
        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        cb_file.write_text(json.dumps({"state": "HALF_OPEN"}))
        result = await ralph_circuit_state_tool(ralph_dir=ralph_dir)
        assert result["state"] == "HALF_OPEN"
        assert result["can_proceed"] is True


class TestRalphTaskUpdateTool:
    @pytest.mark.asyncio
    async def test_complete_task(self, ralph_dir):
        fix_plan = Path(ralph_dir) / "fix_plan.md"
        fix_plan.write_text("# Fix Plan\n- [ ] Add login form\n- [ ] Add validation\n")
        result = await ralph_task_update_tool(
            task_description="Add login form",
            completed=True,
            ralph_dir=ralph_dir,
        )
        assert result["ok"] is True
        content = fix_plan.read_text()
        assert "- [x] Add login form" in content
        assert "- [ ] Add validation" in content

    @pytest.mark.asyncio
    async def test_reopen_task(self, ralph_dir):
        fix_plan = Path(ralph_dir) / "fix_plan.md"
        fix_plan.write_text("# Fix Plan\n- [x] Add login form\n")
        result = await ralph_task_update_tool(
            task_description="Add login form",
            completed=False,
            ralph_dir=ralph_dir,
        )
        assert result["ok"] is True
        content = fix_plan.read_text()
        assert "- [ ] Add login form" in content

    @pytest.mark.asyncio
    async def test_missing_task(self, ralph_dir):
        fix_plan = Path(ralph_dir) / "fix_plan.md"
        fix_plan.write_text("# Fix Plan\n- [ ] Add login form\n")
        result = await ralph_task_update_tool(
            task_description="Nonexistent task",
            completed=True,
            ralph_dir=ralph_dir,
        )
        assert result["ok"] is False

    @pytest.mark.asyncio
    async def test_missing_fix_plan(self, ralph_dir):
        result = await ralph_task_update_tool(
            task_description="Something",
            completed=True,
            ralph_dir=ralph_dir,
        )
        assert result["ok"] is False


class TestToolDefinitions:
    def test_all_tools_have_required_fields(self):
        for tool in RALPH_TOOLS:
            assert "name" in tool
            assert "description" in tool
            assert "input_schema" in tool
            assert "handler" in tool

    def test_tool_count(self):
        assert len(RALPH_TOOLS) == 4

    def test_tool_names(self):
        names = {t["name"] for t in RALPH_TOOLS}
        assert names == {"ralph_status", "ralph_rate_check", "ralph_circuit_state", "ralph_task_update"}
