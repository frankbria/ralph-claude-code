"""Tests for Ralph SDK Agent (async + Pydantic v2 models)."""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from ralph_sdk.agent import RalphAgent, TaskInput, TaskResult
from ralph_sdk.config import RalphConfig, RalphConfigError
from ralph_sdk.state import NullStateBackend
from ralph_sdk.status import CircuitBreakerState, RalphLoopStatus, RalphStatus, WorkType


@pytest.fixture
def project_dir(tmp_path):
    """Create a minimal Ralph project."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "logs").mkdir()
    (ralph_dir / "PROMPT.md").write_text("Build a login form")
    (ralph_dir / "fix_plan.md").write_text("- [ ] Add login form\n- [ ] Add validation\n")
    (ralph_dir / "AGENT.md").write_text("Run: npm test")
    return tmp_path


@pytest.fixture
def config():
    return RalphConfig(dry_run=True, project_name="test-project")


class TestTaskInput:
    def test_from_ralph_dir(self, project_dir):
        task = TaskInput.from_ralph_dir(str(project_dir / ".ralph"))
        assert "login form" in task.prompt
        assert "Add login form" in task.fix_plan
        assert "npm test" in task.agent_instructions

    def test_from_ralph_dir_missing(self, tmp_path):
        ralph_dir = tmp_path / ".ralph"
        ralph_dir.mkdir()
        task = TaskInput.from_ralph_dir(str(ralph_dir))
        assert task.prompt == ""
        assert task.fix_plan == ""

    def test_from_task_packet(self):
        packet = {
            "id": "task-123",
            "type": "implementation",
            "prompt": "Build feature X",
            "fix_plan": "- [ ] Step 1",
        }
        task = TaskInput.from_task_packet(packet)
        assert task.task_packet_id == "task-123"
        assert task.prompt == "Build feature X"

    def test_frozen(self):
        """TaskInput is immutable (frozen)."""
        task = TaskInput(prompt="test")
        with pytest.raises(Exception):
            task.prompt = "changed"

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = TaskInput.model_json_schema()
        assert "properties" in schema
        assert "prompt" in schema["properties"]


class TestTaskResult:
    def test_to_signal(self):
        status = RalphStatus(work_type="IMPLEMENTATION", exit_signal=True)
        result = TaskResult(status=status, loop_count=5, duration_seconds=120.5)
        signal = result.to_signal()
        assert signal["type"] == "ralph_result"
        assert signal["loop_count"] == 5
        assert signal["task_result"]["EXIT_SIGNAL"] is True

    def test_model_json_schema(self):
        """Pydantic model_json_schema() works."""
        schema = TaskResult.model_json_schema()
        assert "properties" in schema


class TestRalphAgent:
    def test_init(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert agent.loop_count == 0
        assert agent.ralph_dir == project_dir / ".ralph"

    def test_dry_run(self, project_dir, config):
        """Dry run via run_sync() — async loop with dry_run=True."""
        config.dry_run = True
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = agent.run_sync()
        assert result.status.status == RalphLoopStatus.DRY_RUN
        assert result.loop_count == 1

    def test_dry_run_with_null_backend(self, project_dir, config):
        """Dry run with NullStateBackend creates no extra files."""
        config.dry_run = True
        null_backend = NullStateBackend()
        agent = RalphAgent(config=config, project_dir=project_dir, state_backend=null_backend)
        result = agent.run_sync()
        assert result.status.status == RalphLoopStatus.DRY_RUN

    @pytest.mark.asyncio
    async def test_should_exit_requires_dual_condition(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)

        # EXIT_SIGNAL alone is not enough
        status = RalphStatus(exit_signal=True, progress_summary="Still working")
        assert await agent.should_exit(status, 1) is False

        # EXIT_SIGNAL + completion phrase = exit
        status2 = RalphStatus(exit_signal=True, progress_summary="All tasks complete")
        assert await agent.should_exit(status2, 2) is True

    @pytest.mark.asyncio
    async def test_check_rate_limit_ok(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert await agent.check_rate_limit() is True

    @pytest.mark.asyncio
    async def test_check_circuit_breaker_ok(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert await agent.check_circuit_breaker() is True

    @pytest.mark.asyncio
    async def test_check_circuit_breaker_open(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        cb = CircuitBreakerState(state="OPEN")
        cb.save(str(project_dir / ".ralph"))
        assert await agent.check_circuit_breaker() is False

    def test_parse_jsonl_response(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        jsonl = json.dumps({
            "type": "result",
            "result": "WORK_TYPE: IMPLEMENTATION\nCOMPLETED_TASK: Added form\nPROGRESS_SUMMARY: 50% done\nEXIT_SIGNAL: false",
            "session_id": "sess-123",
        })
        status = agent._parse_response(jsonl, 0)
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.completed_task == "Added form"
        assert status.exit_signal is False
        assert agent.session_id == "sess-123"

    def test_parse_text_fallback(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        text = "Some output...\nWORK_TYPE: TESTING\nEXIT_SIGNAL: true\n"
        status = agent._parse_response(text, 0)
        assert status.work_type == WorkType.TESTING
        assert status.exit_signal is True

    def test_parse_error_return_code(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        status = agent._parse_response("", 1)
        assert status.status == RalphLoopStatus.ERROR

    @pytest.mark.asyncio
    async def test_handle_tool_call(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = await agent.handle_tool_call("ralph_circuit_state", {})
        assert result["ok"] is True
        assert result["state"] == "CLOSED"

    @pytest.mark.asyncio
    async def test_handle_unknown_tool(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = await agent.handle_tool_call("nonexistent", {})
        assert result["ok"] is False

    def test_get_tool_definitions(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        tools = agent.get_tool_definitions()
        assert len(tools) == 4
        # No handler in output (SDK registration doesn't need it)
        for tool in tools:
            assert "handler" not in tool

    @pytest.mark.asyncio
    async def test_process_task_packet(self, project_dir, config):
        config.dry_run = False
        agent = RalphAgent(config=config, project_dir=project_dir)
        agent.start_time = 1000.0

        with patch.object(agent, 'run_iteration', new_callable=AsyncMock) as mock_iter:
            mock_iter.return_value = RalphStatus(work_type="IMPLEMENTATION")
            signal = await agent.process_task_packet({
                "id": "task-1",
                "prompt": "Do something",
            })
            assert signal["type"] == "ralph_result"

    def test_build_claude_command(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        cmd = agent._build_claude_command("test prompt")
        assert cmd[0] == "claude"
        assert "--agent" in cmd
        assert "ralph" in cmd
        assert "-p" in cmd
        assert "--output-format" in cmd
        assert "--max-turns" in cmd

    def test_run_sync_wrapper(self, project_dir, config):
        """run_sync() provides synchronous access to async run()."""
        config.dry_run = True
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = agent.run_sync()
        assert result.loop_count == 1


class TestExtractSessionId:
    """Regression coverage for TAP-621: tokens live under obj['usage']."""

    def _agent(self, project_dir, config):
        return RalphAgent(config=config, project_dir=project_dir)

    def test_tokens_extracted_from_usage_nested(self, project_dir, config):
        agent = self._agent(project_dir, config)
        stdout = json.dumps({
            "type": "result",
            "session_id": "abc-123",
            "usage": {"input_tokens": 1234, "output_tokens": 567},
        })
        agent._extract_session_id(stdout)
        assert agent.session_id == "abc-123"
        assert agent._last_tokens_in == 1234
        assert agent._last_tokens_out == 567

    def test_missing_usage_does_not_raise(self, project_dir, config):
        agent = self._agent(project_dir, config)
        stdout = json.dumps({"type": "result", "session_id": "abc-456"})
        agent._extract_session_id(stdout)
        assert agent.session_id == "abc-456"
        assert agent._last_tokens_in == 0
        assert agent._last_tokens_out == 0

    def test_top_level_input_tokens_ignored(self, project_dir, config):
        """Top-level input_tokens/output_tokens must NOT be summed (pre-TAP-621 bug)."""
        agent = self._agent(project_dir, config)
        stdout = json.dumps({
            "type": "result",
            "session_id": "abc-789",
            "input_tokens": 9999,
            "output_tokens": 9999,
            "usage": {"input_tokens": 1, "output_tokens": 2},
        })
        agent._extract_session_id(stdout)
        assert agent._last_tokens_in == 1
        assert agent._last_tokens_out == 2


class TestTAP1104AgentMode:
    """TAP-1104: SDK only supports agent mode; legacy use_agent flag deleted."""

    def _agent(self, project_dir, config):
        return RalphAgent(config=config, project_dir=project_dir)

    def test_use_agent_field_removed(self):
        """RalphConfig must not expose a use_agent attribute."""
        cfg = RalphConfig()
        assert not hasattr(cfg, "use_agent")
        # And the export round-trip must not include the legacy key.
        assert "useAgent" not in cfg.to_dict()

    def test_command_always_emits_agent(self, project_dir, config):
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command("hello")
        assert "--agent" in cmd
        assert cmd[cmd.index("--agent") + 1] == config.agent_name

    def test_command_never_emits_allowedtools(self, project_dir, config):
        config.allowed_tools = ["Read", "Write", "Bash(git *)"]
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command("hello")
        assert "--allowedTools" not in cmd

    def test_min_version_is_2_1_0(self):
        assert RalphConfig().claude_min_version == "2.1.0"

    @pytest.mark.asyncio
    async def test_preflight_raises_on_old_cli(self, project_dir, config, monkeypatch):
        agent = self._agent(project_dir, config)

        async def fake_exec(*args, **kwargs):
            proc = MagicMock()
            proc.communicate = AsyncMock(return_value=(b"2.0.50 (Claude Code)\n", b""))
            return proc

        monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
        with pytest.raises(RalphConfigError, match="2.1.0"):
            await agent._preflight_claude_version()

    @pytest.mark.asyncio
    async def test_preflight_passes_on_new_cli(self, project_dir, config, monkeypatch):
        agent = self._agent(project_dir, config)

        async def fake_exec(*args, **kwargs):
            proc = MagicMock()
            proc.communicate = AsyncMock(return_value=(b"2.5.1 (Claude Code)\n", b""))
            return proc

        monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
        await agent._preflight_claude_version()  # no raise

    @pytest.mark.asyncio
    async def test_preflight_warns_when_cannot_detect(self, project_dir, config, monkeypatch):
        agent = self._agent(project_dir, config)

        async def fake_exec(*args, **kwargs):
            raise FileNotFoundError("claude not on PATH")

        monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
        await agent._preflight_claude_version()  # no raise — degrades to warn


class TestModelRouting:
    """Per-task complexity model routing wired into _build_claude_command."""

    def _agent(self, project_dir, config):
        return RalphAgent(config=config, project_dir=project_dir)

    def test_routing_disabled_uses_config_model(self, project_dir, config):
        config.model_routing_enabled = False
        config.model = "claude-sonnet-4-6"
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command(
            "prompt", task_text="[ARCHITECTURAL] Redesign database schema"
        )
        assert "--model" in cmd
        assert cmd[cmd.index("--model") + 1] == "claude-sonnet-4-6"

    def test_routing_enabled_trivial_to_haiku(self, project_dir, config):
        config.model_routing_enabled = True
        config.model = "claude-sonnet-4-6"
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command("prompt", task_text="[TRIVIAL] Fix typo")
        assert cmd[cmd.index("--model") + 1] == config.model_map_trivial

    def test_routing_enabled_architectural_to_opus(self, project_dir, config):
        config.model_routing_enabled = True
        config.model = "claude-sonnet-4-6"
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command(
            "prompt", task_text="[ARCHITECTURAL] Redesign database schema"
        )
        assert cmd[cmd.index("--model") + 1] == config.model_map_architectural

    def test_routing_enabled_empty_task_falls_back(self, project_dir, config):
        config.model_routing_enabled = True
        config.model = "claude-sonnet-4-6"
        agent = self._agent(project_dir, config)
        cmd = agent._build_claude_command("prompt", task_text="")
        assert cmd[cmd.index("--model") + 1] == "claude-sonnet-4-6"

    def test_extract_next_task_skips_checked(self, project_dir, config):
        agent = self._agent(project_dir, config)
        task = TaskInput(fix_plan="- [x] Done one\n- [ ] Real next task\n- [ ] Later")
        assert agent._extract_next_task_text(task) == "Real next task"

    def test_extract_next_task_empty_when_no_unchecked(self, project_dir, config):
        agent = self._agent(project_dir, config)
        task = TaskInput(fix_plan="- [x] Done\n- [x] Also done\n")
        assert agent._extract_next_task_text(task) == ""
