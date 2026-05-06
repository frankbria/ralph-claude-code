"""Tests for TAP-671: _rotate_session must not carry a stale previous_session_id
forward when the circuit breaker is non-CLOSED at rotation time."""

import asyncio

import pytest

from ralph_sdk.agent import RalphAgent
from ralph_sdk.config import RalphConfig
from ralph_sdk.state import NullStateBackend
from ralph_sdk.status import RalphStatus


@pytest.fixture
def project_dir(tmp_path):
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "logs").mkdir()
    (ralph_dir / "PROMPT.md").write_text("test")
    (ralph_dir / "fix_plan.md").write_text("- [ ] task\n")
    (ralph_dir / "AGENT.md").write_text("test")
    return tmp_path


def _make_agent(project_dir):
    config = RalphConfig(
        dry_run=True, project_name="test-rotate", project_root=str(project_dir)
    )
    return RalphAgent(config=config, state_backend=NullStateBackend())


async def _rotate_with_cb_state(agent: RalphAgent, cb_state: str) -> dict:
    await agent.state_backend.write_circuit_breaker({"state": cb_state})
    status = RalphStatus(
        next_task="keep-going",
        completed_task="",
        progress_summary="2/5 done",
    )
    agent.session_id = "sess_abc123deadbeef"
    await agent._rotate_session(status)
    # Grab the continue-as-new state back
    return await agent.state_backend.read_continue_as_new_state() or {}


def test_cb_closed_carries_previous_session_id(project_dir):
    """Baseline: when CB is CLOSED, previous_session_id is carried forward."""
    agent = _make_agent(project_dir)

    async def run():
        return await _rotate_with_cb_state(agent, "CLOSED")

    state = asyncio.run(run())
    assert state.get("previous_session_id") == "sess_abc123deadbeef"  # nosec B101  # pytest assertion


def test_cb_open_blanks_previous_session_id(project_dir):
    """TAP-671: when CB is OPEN, the stale session id must not propagate."""
    agent = _make_agent(project_dir)

    async def run():
        return await _rotate_with_cb_state(agent, "OPEN")

    state = asyncio.run(run())
    assert state.get("previous_session_id") == ""  # nosec B101  # pytest assertion


def test_cb_half_open_blanks_previous_session_id(project_dir):
    """HALF_OPEN is also a non-CLOSED state that indicates recovery; safer to
    start clean."""
    agent = _make_agent(project_dir)

    async def run():
        return await _rotate_with_cb_state(agent, "HALF_OPEN")

    state = asyncio.run(run())
    assert state.get("previous_session_id") == ""  # nosec B101  # pytest assertion


def test_session_history_tags_cb_open_rotation(project_dir):
    """Post-mortem observability: the history entry records why rotation
    happened so operators can find CB-triggered rotations separately."""
    agent = _make_agent(project_dir)

    async def run():
        await agent.state_backend.write_circuit_breaker({"state": "OPEN"})
        status = RalphStatus(progress_summary="stuck")
        agent.session_id = "sess_xyz"
        await agent._rotate_session(status)
        history = await agent.state_backend.read_session_history()
        return history

    history = asyncio.run(run())
    assert any(  # nosec B101  # pytest assertion
        entry.get("reason") == "continue_as_new_cb_open"
        and entry.get("cb_state_at_rotation") == "OPEN"
        for entry in history
    ), f"Expected cb-open tagged entry; got {history!r}"
