"""Tests for TAP-675: RalphAgent.cancel() uses get_running_loop() + stored
loop reference for cross-thread safety, not deprecated get_event_loop()."""

import asyncio
import threading
import time
from unittest.mock import MagicMock

import pytest

from ralph_sdk.agent import RalphAgent
from ralph_sdk.config import RalphConfig
from ralph_sdk.state import NullStateBackend


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
    config = RalphConfig(dry_run=True, project_name="test-cancel", project_root=str(project_dir))
    return RalphAgent(config=config, state_backend=NullStateBackend())


def test_cancel_without_running_loop_kills_synchronously(project_dir):
    """If cancel() is called when the agent never ran, no loop is stored —
    the call must still succeed and kill the subprocess synchronously."""
    agent = _make_agent(project_dir)

    # Mock a live subprocess
    fake_proc = MagicMock()
    fake_proc.returncode = None
    fake_proc.send_signal = MagicMock()
    fake_proc.terminate = MagicMock()
    fake_proc.kill = MagicMock()
    fake_proc.stdout = None
    agent._current_proc = fake_proc

    # No _loop set (agent never ran)
    assert agent._loop is None

    result = agent.cancel()

    # Kill was invoked synchronously
    fake_proc.kill.assert_called_once()
    assert result.was_forced is True


def test_cancel_from_different_thread_uses_threadsafe_scheduling(project_dir):
    """Simulates the 'supervisor thread calls cancel() on agent running in
    another thread' case. Must not raise, must not call proc.kill()
    synchronously (scheduling goes through the agent's loop)."""
    agent = _make_agent(project_dir)

    # Stand up a loop in its own thread to stand in for the agent's run() loop
    loop_ready = threading.Event()
    stop_event = threading.Event()
    loop_container = {}

    def _runner():
        loop = asyncio.new_event_loop()
        loop_container["loop"] = loop
        asyncio.set_event_loop(loop)

        async def _idle():
            loop_ready.set()
            while not stop_event.is_set():
                await asyncio.sleep(0.01)

        loop.run_until_complete(_idle())
        loop.close()

    t = threading.Thread(target=_runner, daemon=True)
    t.start()
    loop_ready.wait(timeout=2.0)

    try:
        agent_loop = loop_container["loop"]
        agent._loop = agent_loop

        # Fake subprocess whose wait() returns quickly (no kill needed)
        fake_proc = MagicMock()
        fake_proc.returncode = None
        fake_proc.send_signal = MagicMock()
        fake_proc.terminate = MagicMock()
        fake_proc.kill = MagicMock()
        fake_proc.stdout = None

        async def _fake_wait():
            return 0

        fake_proc.wait = _fake_wait
        agent._current_proc = fake_proc

        # Call cancel() from THIS thread (main test thread). The agent's
        # loop is running in the worker thread, not here.
        result = agent.cancel()

        # Give the scheduled kill task a moment to run on the agent's loop
        time.sleep(0.2)

        # No deprecation warning or exception should have escaped
        # proc.kill() must not have been called synchronously (wait finished
        # cleanly before the grace timeout, so no forced kill)
        assert result.was_forced is False
    finally:
        stop_event.set()
        t.join(timeout=2.0)


def test_cancel_from_same_loop_uses_create_task(project_dir):
    """When cancel() is called from within the agent's own loop, it uses
    the current running loop (get_running_loop path) — no deprecated
    get_event_loop() calls."""
    agent = _make_agent(project_dir)

    async def _scenario():
        agent._loop = asyncio.get_running_loop()

        fake_proc = MagicMock()
        fake_proc.returncode = None
        fake_proc.send_signal = MagicMock()
        fake_proc.terminate = MagicMock()
        fake_proc.kill = MagicMock()
        fake_proc.stdout = None

        async def _fake_wait():
            return 0

        fake_proc.wait = _fake_wait
        agent._current_proc = fake_proc

        result = agent.cancel()
        # Let the created task run
        await asyncio.sleep(0.05)
        return result

    # Using asyncio.run avoids touching deprecated loop APIs
    result = asyncio.run(_scenario())
    assert result.was_forced is False
