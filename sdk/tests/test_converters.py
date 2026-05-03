"""Tests for Ralph SDK TaskPacket converters."""

import warnings

from ralph_sdk.converters import (
    ComplexityBand,
    ContextPack,
    IntentSpecInput,
    RiskFlag,
    TaskPacketInput,
    TrustTier,
    from_task_packet,
    from_task_packet_dict,
    get_max_turns,
    get_permission_mode,
)


class TestFromTaskPacket:
    def test_basic_conversion(self):
        packet = TaskPacketInput(
            id="tp-001",
            type="implementation",
            intent=IntentSpecInput(goal="Build a login form"),
        )
        task = from_task_packet(packet)
        assert "Build a login form" in task.prompt
        assert task.task_packet_id == "tp-001"
        assert task.task_packet_type == "implementation"

    def test_acceptance_criteria_appended(self):
        packet = TaskPacketInput(
            id="tp-002",
            intent=IntentSpecInput(
                goal="Build auth system",
                acceptance_criteria=["JWT tokens used", "Session timeout 24h"],
            ),
        )
        task = from_task_packet(packet)
        assert "Acceptance Criteria" in task.prompt
        assert "JWT tokens used" in task.prompt
        assert "Session timeout 24h" in task.prompt

    def test_constraints_become_instructions(self):
        packet = TaskPacketInput(
            id="tp-003",
            intent=IntentSpecInput(
                goal="Refactor module",
                constraints=["Must maintain backward compat", "No new dependencies"],
            ),
        )
        task = from_task_packet(packet)
        assert "Must maintain backward compat" in task.agent_instructions
        assert "No new dependencies" in task.agent_instructions

    def test_non_goals_become_exclusions(self):
        packet = TaskPacketInput(
            id="tp-004",
            intent=IntentSpecInput(
                goal="Fix bug",
                non_goals=["Add new features", "Refactor unrelated code"],
            ),
        )
        task = from_task_packet(packet)
        assert "DO NOT: Add new features" in task.agent_instructions
        assert "DO NOT: Refactor unrelated code" in task.agent_instructions

    def test_risk_flags_become_safety_constraints(self):
        packet = TaskPacketInput(
            id="tp-005",
            intent=IntentSpecInput(
                goal="Update auth",
                risk_flags=[
                    RiskFlag(category="security", severity="high", description="Handles PII"),
                    RiskFlag(category="performance", severity="low", description="Minor perf hit"),
                ],
            ),
        )
        task = from_task_packet(packet)
        assert "SAFETY: Handles PII" in task.agent_instructions
        # Low severity not included
        assert "Minor perf hit" not in task.agent_instructions

    def test_context_packs_included(self):
        packet = TaskPacketInput(
            id="tp-006",
            intent=IntentSpecInput(
                goal="Update module",
                context_packs=[
                    ContextPack(path="src/module.py", content="def foo(): pass"),
                ],
            ),
        )
        task = from_task_packet(packet)
        assert "src/module.py" in task.agent_instructions
        assert "def foo(): pass" in task.agent_instructions

    def test_loopback_context_prepended(self):
        packet = TaskPacketInput(
            id="tp-007",
            intent=IntentSpecInput(goal="Fix the failing test"),
            loopback_context="Previous attempt failed: TypeError on line 42",
        )
        task = from_task_packet(packet)
        assert "Retry Context" in task.prompt
        assert "TypeError on line 42" in task.prompt
        # Loopback comes before the goal
        assert task.prompt.index("Retry Context") < task.prompt.index("Fix the failing test")

    def test_loopback_override(self):
        packet = TaskPacketInput(
            id="tp-008",
            intent=IntentSpecInput(goal="Fix bug"),
            loopback_context="original context",
        )
        task = from_task_packet(packet, loopback_context="override context")
        assert "override context" in task.prompt
        assert "original context" not in task.prompt

    def test_expert_outputs_included(self):
        packet = TaskPacketInput(
            id="tp-009",
            intent=IntentSpecInput(goal="Implement feature"),
            expert_outputs=[
                {"agent": "reviewer", "output": "Code looks good, needs tests"},
            ],
        )
        task = from_task_packet(packet)
        assert "Expert Analysis" in task.prompt
        assert "reviewer" in task.prompt
        assert "needs tests" in task.prompt

    def test_complexity_max_turns(self):
        assert get_max_turns(ComplexityBand.LOW) == 20
        assert get_max_turns(ComplexityBand.MEDIUM) == 30
        assert get_max_turns(ComplexityBand.HIGH) == 50
        assert get_max_turns(ComplexityBand.UNKNOWN) == 30

    def test_trust_permission_mode(self):
        assert get_permission_mode(TrustTier.FULL) == "bypassPermissions"
        assert get_permission_mode(TrustTier.STANDARD) == "default"
        assert get_permission_mode(TrustTier.RESTRICTED) == "plan"


class TestDeprecatedFromTaskPacketDict:
    def test_deprecated_wrapper(self):
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            task = from_task_packet_dict({
                "id": "tp-legacy",
                "type": "fix",
            })
            assert len(w) == 1
            assert issubclass(w[0].category, DeprecationWarning)
            assert task.task_packet_id == "tp-legacy"


class TestModels:
    def test_task_packet_input_schema(self):
        schema = TaskPacketInput.model_json_schema()
        assert "properties" in schema
        assert "id" in schema["properties"]

    def test_intent_spec_schema(self):
        schema = IntentSpecInput.model_json_schema()
        assert "properties" in schema
        assert "goal" in schema["properties"]
