"""Tests for ralph_sdk.cost — CostTracker, select_model, TokenRateLimiter."""

from __future__ import annotations

import time

import pytest

from ralph_sdk.cost import (
    DEFAULT_MODEL_MAP,
    DEFAULT_PRICING,
    AlertLevel,
    CostComplexityBand,
    CostTracker,
    ModelPricing,
    TokenRateLimiter,
    select_model,
)


class TestCostTrackerRecordIteration:
    def test_known_model_computes_usd(self):
        tracker = CostTracker()
        # 1M input + 1M output @ sonnet = $3 + $15 = $18
        cost = tracker.record_iteration("claude-sonnet-4-6", 1_000_000, 1_000_000)
        assert cost.input_usd == pytest.approx(3.0)
        assert cost.output_usd == pytest.approx(15.0)
        assert cost.total_usd == pytest.approx(18.0)
        assert cost.iteration == 1

    def test_unknown_model_zero_usd_but_tracks_tokens(self):
        tracker = CostTracker()
        cost = tracker.record_iteration("claude-mystery-9", 5000, 1000)
        assert cost.input_usd == 0.0
        assert cost.output_usd == 0.0
        assert cost.total_usd == 0.0
        assert cost.input_tokens == 5000
        assert cost.output_tokens == 1000

    def test_iteration_counter_increments(self):
        tracker = CostTracker()
        c1 = tracker.record_iteration("claude-haiku-4-5", 100, 50)
        c2 = tracker.record_iteration("claude-haiku-4-5", 200, 100)
        assert c1.iteration == 1
        assert c2.iteration == 2

    def test_currency_rounding_small_token_counts(self):
        """Small token counts produce tiny but non-zero costs."""
        tracker = CostTracker()
        # 100 input tokens @ haiku = 100/1M * $1 = $0.0001
        cost = tracker.record_iteration("claude-haiku-4-5", 100, 0)
        assert cost.input_usd == pytest.approx(0.0001)


class TestCostTrackerSession:
    def test_get_session_cost_aggregates(self):
        tracker = CostTracker()
        tracker.record_iteration("claude-sonnet-4-6", 1000, 500)
        tracker.record_iteration("claude-sonnet-4-6", 2000, 1000)
        tracker.record_iteration("claude-haiku-4-5", 500, 250)
        session = tracker.get_session_cost()
        assert session.iteration_count == 3
        assert session.total_input_tokens == 3500
        assert session.total_output_tokens == 1750
        assert session.total_usd > 0

    def test_per_model_breakdown(self):
        tracker = CostTracker()
        tracker.record_iteration("claude-sonnet-4-6", 1000, 500)
        tracker.record_iteration("claude-sonnet-4-6", 1000, 500)
        tracker.record_iteration("claude-haiku-4-5", 500, 250)
        session = tracker.get_session_cost()
        by_model = {m.model: m for m in session.by_model}
        assert by_model["claude-sonnet-4-6"].iterations == 2
        assert by_model["claude-sonnet-4-6"].input_tokens == 2000
        assert by_model["claude-haiku-4-5"].iterations == 1

    def test_pricing_property_returns_copy(self):
        tracker = CostTracker()
        p = tracker.pricing
        p["new-model"] = ModelPricing(input_per_1m=1.0, output_per_1m=2.0)
        # Mutating the returned dict must not affect the tracker
        assert "new-model" not in tracker.pricing


class TestCostTrackerBudget:
    def test_alert_none_below_warning(self):
        tracker = CostTracker()
        # ~$0.18 spend on a $100 budget = 0.18% < 50%
        tracker.record_iteration("claude-sonnet-4-6", 10_000, 5_000)
        status = tracker.check_budget(max_budget_usd=100.0)
        assert status.alert_level == AlertLevel.NONE
        assert status.percentage_used < 50.0

    def test_alert_warning_at_threshold(self):
        tracker = CostTracker()
        # $1.8 spend on a $3.0 budget = 60% → WARNING
        tracker.record_iteration("claude-sonnet-4-6", 100_000, 100_000)  # $0.30 + $1.50 = $1.80
        status = tracker.check_budget(max_budget_usd=3.0)
        assert status.alert_level == AlertLevel.WARNING
        assert 50.0 <= status.percentage_used < 80.0

    def test_alert_critical_at_threshold(self):
        tracker = CostTracker()
        # $1.8 spend on a $2.0 budget = 90% → CRITICAL
        tracker.record_iteration("claude-sonnet-4-6", 100_000, 100_000)
        status = tracker.check_budget(max_budget_usd=2.0)
        assert status.alert_level == AlertLevel.CRITICAL
        assert 80.0 <= status.percentage_used < 100.0

    def test_alert_exhausted_at_or_over_100pct(self):
        tracker = CostTracker()
        tracker.record_iteration("claude-sonnet-4-6", 1_000_000, 1_000_000)  # $18
        status = tracker.check_budget(max_budget_usd=10.0)
        assert status.alert_level == AlertLevel.EXHAUSTED
        assert status.remaining_usd == 0.0  # capped at 0

    def test_zero_budget_returns_none(self):
        tracker = CostTracker()
        tracker.record_iteration("claude-sonnet-4-6", 1000, 1000)
        status = tracker.check_budget(max_budget_usd=0.0)
        assert status.alert_level == AlertLevel.NONE
        assert status.max_budget_usd == 0.0

    def test_negative_budget_returns_none(self):
        tracker = CostTracker()
        status = tracker.check_budget(max_budget_usd=-1.0)
        assert status.alert_level == AlertLevel.NONE

    def test_custom_thresholds(self):
        tracker = CostTracker(budget_warning_pct=10.0, budget_critical_pct=20.0)
        # $0.18 on $1.0 = 18% → WARNING with custom thresholds (10/20)
        tracker.record_iteration("claude-sonnet-4-6", 10_000, 5_000)
        status = tracker.check_budget(max_budget_usd=1.0)
        assert status.alert_level == AlertLevel.WARNING


class TestSelectModel:
    def test_trivial_routes_to_haiku(self):
        assert select_model(CostComplexityBand.TRIVIAL) == "claude-haiku-4-5"

    def test_small_routes_to_haiku(self):
        assert select_model(CostComplexityBand.SMALL) == "claude-haiku-4-5"

    def test_medium_routes_to_sonnet(self):
        assert select_model(CostComplexityBand.MEDIUM) == "claude-sonnet-4-6"

    def test_large_routes_to_opus(self):
        assert select_model(CostComplexityBand.LARGE) == "claude-opus-4-7"

    def test_architectural_routes_to_opus(self):
        assert select_model(CostComplexityBand.ARCHITECTURAL) == "claude-opus-4-7"

    def test_retry_escalates_haiku_to_sonnet(self):
        assert select_model(CostComplexityBand.SMALL, retry_count=1) == "claude-sonnet-4-6"

    def test_retry_escalates_sonnet_to_opus(self):
        assert select_model(CostComplexityBand.MEDIUM, retry_count=1) == "claude-opus-4-7"

    def test_retry_caps_at_opus(self):
        assert select_model(CostComplexityBand.MEDIUM, retry_count=99) == "claude-opus-4-7"

    def test_opus_cannot_escalate_further(self):
        assert select_model(CostComplexityBand.LARGE, retry_count=5) == "claude-opus-4-7"

    def test_zero_retry_no_escalation(self):
        assert select_model(CostComplexityBand.SMALL, retry_count=0) == "claude-haiku-4-5"

    def test_negative_retry_no_escalation(self):
        # Defensive: negative retry treated as no retry
        assert select_model(CostComplexityBand.SMALL, retry_count=-1) == "claude-haiku-4-5"

    def test_custom_model_map(self):
        custom = {CostComplexityBand.SMALL: "claude-opus-4-7"}
        assert select_model(CostComplexityBand.SMALL, model_map=custom) == "claude-opus-4-7"

    def test_missing_band_in_map_falls_back_to_sonnet(self):
        # Map provided but missing the requested band → fallback is sonnet
        partial = {CostComplexityBand.LARGE: "claude-opus-4-7"}
        assert select_model(CostComplexityBand.SMALL, model_map=partial) == "claude-sonnet-4-6"

    def test_unknown_base_model_does_not_escalate(self):
        # Custom map points to an off-the-escalation-chain model
        custom = {CostComplexityBand.SMALL: "claude-mystery-9"}
        # No escalation possible → return base
        assert select_model(CostComplexityBand.SMALL, retry_count=3, model_map=custom) == "claude-mystery-9"


class TestTokenRateLimiter:
    def test_disabled_when_max_zero(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=0)
        limiter.record_tokens(1_000_000, 1_000_000)
        assert limiter.can_proceed() is True

    def test_under_limit_can_proceed(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=10_000)
        limiter.record_tokens(1000, 1000)
        assert limiter.can_proceed() is True

    def test_at_or_over_limit_blocks(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=1000)
        limiter.record_tokens(600, 500)  # 1100 > 1000
        assert limiter.can_proceed() is False

    def test_get_usage_reports_state(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=10_000)
        limiter.record_tokens(2000, 1000)
        usage = limiter.get_usage()
        assert usage.tokens_used_this_hour == 3000
        assert usage.limit == 10_000
        assert usage.can_proceed is True
        assert usage.reset_at > time.time()

    def test_window_resets_after_an_hour(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=1000)
        limiter.record_tokens(2000, 0)  # over limit
        assert limiter.can_proceed() is False
        # Backdate the window start to >1h ago
        limiter._window_start = time.time() - 3601  # noqa: SLF001
        # Reading state triggers window reset
        assert limiter.can_proceed() is True
        assert limiter.get_usage().tokens_used_this_hour == 0

    def test_negative_max_treated_as_disabled(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=-1)
        limiter.record_tokens(1_000_000, 1_000_000)
        assert limiter.can_proceed() is True


class TestDefaults:
    def test_default_pricing_has_known_models(self):
        assert "claude-sonnet-4-6" in DEFAULT_PRICING
        assert "claude-opus-4-7" in DEFAULT_PRICING
        assert "claude-haiku-4-5" in DEFAULT_PRICING

    def test_default_map_covers_all_bands(self):
        for band in CostComplexityBand:
            assert band in DEFAULT_MODEL_MAP
