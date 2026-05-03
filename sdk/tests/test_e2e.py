"""End-to-end integration test — TaskPacket -> RalphAgent(NullStateBackend) -> EvidenceBundle.

This is the V2-1 acceptance test: full pipeline from TheStudio TaskPacket
through Ralph agent to EvidenceBundle output, using NullStateBackend.
"""


from ralph_sdk.agent import RalphAgent, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.converters import (
    ComplexityBand,
    IntentSpecInput,
    TaskPacketInput,
    from_task_packet,
    get_max_turns,
)
from ralph_sdk.evidence import to_evidence_bundle
from ralph_sdk.state import NullStateBackend
from ralph_sdk.status import RalphLoopStatus, RalphStatus


class TestE2ETaskPacketToEvidenceBundle:
    """V2-1: Full pipeline TaskPacket -> RalphAgent(NullStateBackend) -> EvidenceBundle."""

    def test_full_pipeline_dry_run(self, tmp_path):
        """Full pipeline with dry run — no API calls needed."""
        # 1. Create TaskPacket
        packet = TaskPacketInput(
            id="tp-e2e-001",
            type="implementation",
            intent=IntentSpecInput(
                goal="Add login form with email and password fields",
                constraints=["Use React", "No external auth libraries"],
                acceptance_criteria=["Form renders", "Validation works", "Tests pass"],
                non_goals=["Backend auth", "OAuth integration"],
                complexity=ComplexityBand.MEDIUM,
            ),
        )

        # 2. Convert to TaskInput
        task_input = from_task_packet(packet)
        assert "login form" in task_input.prompt
        assert task_input.task_packet_id == "tp-e2e-001"
        assert "DO NOT: Backend auth" in task_input.agent_instructions
        assert "Acceptance Criteria" in task_input.prompt
        assert get_max_turns(packet.intent.complexity) == 30

        # 3. Create agent with NullStateBackend and dry_run
        ralph_dir = tmp_path / ".ralph"
        ralph_dir.mkdir()
        (ralph_dir / "logs").mkdir()
        (ralph_dir / "PROMPT.md").write_text(task_input.prompt)
        (ralph_dir / "fix_plan.md").write_text("- [ ] Build login form\n")

        config = RalphConfig(dry_run=True, project_name="e2e-test")
        null_backend = NullStateBackend()
        agent = RalphAgent(
            config=config,
            project_dir=tmp_path,
            state_backend=null_backend,
        )

        # 4. Run agent (dry run)
        result = agent.run_sync()
        assert result.status.status == RalphLoopStatus.DRY_RUN
        assert result.loop_count == 1
        assert agent.correlation_id  # Auto-generated UUID

        # 5. Convert to EvidenceBundle
        bundle = to_evidence_bundle(
            result,
            taskpacket_id=packet.id,
            intent_version="v1",
            loopback_attempt=0,
        )
        assert bundle.taskpacket_id == "tp-e2e-001"
        assert bundle.intent_version == "v1"
        assert bundle.loop_count == 1
        assert bundle.correlation_id == agent.correlation_id

        # 6. Verify JSON round-trip
        json_str = bundle.model_dump_json()
        loaded = bundle.model_validate_json(json_str)
        assert loaded.taskpacket_id == bundle.taskpacket_id
        assert loaded.status == bundle.status

    def test_pipeline_with_loopback(self, tmp_path):
        """Retry pipeline with loopback context."""
        packet = TaskPacketInput(
            id="tp-retry-001",
            type="fix",
            intent=IntentSpecInput(goal="Fix the TypeError in auth module"),
            loopback_context="Previous attempt: TypeError at line 42, missing null check",
            loopback_attempt=2,
        )

        task_input = from_task_packet(packet)
        assert "Retry Context" in task_input.prompt
        assert "TypeError at line 42" in task_input.prompt

        bundle = to_evidence_bundle(
            TaskResult(
                status=RalphStatus(work_type="DEBUGGING", completed_task="Fixed null check"),
                loop_count=1,
            ),
            taskpacket_id=packet.id,
            loopback_attempt=packet.loopback_attempt,
        )
        assert bundle.loopback_attempt == 2
        assert bundle.work_type == "DEBUGGING"

    def test_null_backend_creates_no_files(self, tmp_path):
        """NullStateBackend doesn't write state files during E2E run."""
        ralph_dir = tmp_path / ".ralph"
        ralph_dir.mkdir()
        (ralph_dir / "logs").mkdir()
        (ralph_dir / "PROMPT.md").write_text("Test prompt")
        (ralph_dir / "fix_plan.md").write_text("- [ ] Task\n")

        config = RalphConfig(dry_run=True)
        null_backend = NullStateBackend()
        agent = RalphAgent(config=config, project_dir=tmp_path, state_backend=null_backend)
        agent.run_sync()

        # Only the files we created should exist — no status.json, no .circuit_breaker_state
        state_files = {"status.json", ".circuit_breaker_state", ".call_count", ".last_reset", ".claude_session_id"}
        existing = {f.name for f in ralph_dir.iterdir() if f.is_file()}
        assert existing & state_files == set()


class TestImports:
    """V2-2: Pydantic TaskInput is default import."""

    def test_top_level_imports(self):
        from ralph_sdk import (
            RalphAgent,
            TaskInput,
        )
        # All importable
        assert TaskInput is not None
        assert RalphAgent is not None
