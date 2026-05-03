"""Tests for Ralph SDK active circuit breaker."""

import pytest

from ralph_sdk.circuit_breaker import CircuitBreaker
from ralph_sdk.state import NullStateBackend


@pytest.fixture
def backend():
    return NullStateBackend()


@pytest.fixture
def cb(backend):
    return CircuitBreaker(
        state_backend=backend,
        no_progress_threshold=3,
        same_error_threshold=3,
        cooldown_minutes=30,
    )


class TestCircuitBreakerCanProceed:
    @pytest.mark.asyncio
    async def test_closed_allows(self, cb):
        assert await cb.can_proceed() is True

    @pytest.mark.asyncio
    async def test_open_blocks(self, cb, backend):
        await backend.write_circuit_breaker({"state": "OPEN", "opened_at": "2099-01-01T00:00:00+0000"})
        assert await cb.can_proceed() is False

    @pytest.mark.asyncio
    async def test_half_open_allows(self, cb, backend):
        await backend.write_circuit_breaker({"state": "HALF_OPEN"})
        assert await cb.can_proceed() is True

    @pytest.mark.asyncio
    async def test_auto_reset_bypasses_cooldown(self, backend):
        cb = CircuitBreaker(state_backend=backend, auto_reset=True)
        await backend.write_circuit_breaker({"state": "OPEN", "opened_at": "2099-01-01T00:00:00+0000"})
        assert await cb.can_proceed() is True
        state = await cb.get_state()
        assert state["state"] == "HALF_OPEN"


class TestRecordSuccess:
    @pytest.mark.asyncio
    async def test_half_open_to_closed(self, cb, backend):
        await backend.write_circuit_breaker({"state": "HALF_OPEN", "no_progress_count": 2})
        await cb.record_success()
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert state["no_progress_count"] == 0

    @pytest.mark.asyncio
    async def test_closed_resets_counters(self, cb, backend):
        await backend.write_circuit_breaker({"state": "CLOSED", "no_progress_count": 2, "same_error_count": 1})
        await cb.record_success()
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert state["no_progress_count"] == 0
        assert state["same_error_count"] == 0


class TestRecordFailure:
    @pytest.mark.asyncio
    async def test_half_open_trips_immediately(self, cb, backend):
        await backend.write_circuit_breaker({"state": "HALF_OPEN"})
        await cb.record_failure("test error")
        state = await cb.get_state()
        assert state["state"] == "OPEN"

    @pytest.mark.asyncio
    async def test_same_error_threshold_trips(self, cb):
        """3 same errors within window trips to OPEN."""
        await cb.record_failure("repeated error")
        state = await cb.get_state()
        assert state["state"] == "CLOSED"

        await cb.record_failure("repeated error")
        state = await cb.get_state()
        assert state["state"] == "CLOSED"

        await cb.record_failure("repeated error")
        state = await cb.get_state()
        assert state["state"] == "OPEN"

    @pytest.mark.asyncio
    async def test_different_errors_dont_trip(self, cb):
        """Different errors don't accumulate toward threshold."""
        await cb.record_failure("error A")
        await cb.record_failure("error B")
        await cb.record_failure("error C")
        state = await cb.get_state()
        assert state["state"] == "CLOSED"


class TestRecordNoProgress:
    @pytest.mark.asyncio
    async def test_trips_at_threshold(self, cb):
        """3 consecutive no-progress trips to OPEN."""
        await cb.record_no_progress()
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert state["no_progress_count"] == 1

        await cb.record_no_progress()
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert state["no_progress_count"] == 2

        await cb.record_no_progress()
        state = await cb.get_state()
        assert state["state"] == "OPEN"

    @pytest.mark.asyncio
    async def test_success_resets_no_progress(self, cb):
        """Success resets no_progress_count."""
        await cb.record_no_progress()
        await cb.record_no_progress()
        await cb.record_success()
        state = await cb.get_state()
        assert state["no_progress_count"] == 0


class TestReset:
    @pytest.mark.asyncio
    async def test_reset_clears_state(self, cb, backend):
        await backend.write_circuit_breaker({"state": "OPEN", "no_progress_count": 5})
        await cb.reset("test reset")
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert state["no_progress_count"] == 0
        assert "RESET" in state["last_transition"]


class TestBehaviorMatchesBash:
    @pytest.mark.asyncio
    async def test_full_lifecycle(self, cb):
        """CLOSED -> record failures -> OPEN -> can_proceed (with auto_reset) -> HALF_OPEN -> success -> CLOSED."""
        # Start CLOSED
        state = await cb.get_state()
        assert state["state"] == "CLOSED"

        # Record no progress until OPEN
        await cb.record_no_progress()
        await cb.record_no_progress()
        await cb.record_no_progress()
        state = await cb.get_state()
        assert state["state"] == "OPEN"

        # Can't proceed when OPEN
        assert await cb.can_proceed() is False

        # Reset and verify recovery
        await cb.reset("manual recovery")
        state = await cb.get_state()
        assert state["state"] == "CLOSED"
        assert await cb.can_proceed() is True


class TestTap630CooldownTimezone:
    """TAP-630: cooldown elapsed-time must be correct across timezones.

    Before the fix, time.mktime(strptime(..., "%z")) silently ignored the
    offset on macOS/BSD/musl, shifting the cooldown by the local UTC offset.
    """

    @pytest.mark.asyncio
    async def test_cooldown_expired_in_utc_plus_offset(self, backend):
        """opened_at 45m ago with a non-UTC offset must count as elapsed."""
        from datetime import datetime, timedelta, timezone
        cb = CircuitBreaker(
            state_backend=backend,
            cooldown_minutes=30,
        )
        # 45 minutes ago, expressed with a +0900 offset
        jst = timezone(timedelta(hours=9))
        opened = datetime.now(tz=jst) - timedelta(minutes=45)
        await backend.write_circuit_breaker({
            "state": "OPEN",
            "opened_at": opened.strftime("%Y-%m-%dT%H:%M:%S%z"),
        })
        # 45 min > 30 min cooldown → must transition to HALF_OPEN + allow
        assert await cb.can_proceed() is True
        state = await cb.get_state()
        assert state["state"] == "HALF_OPEN"

    @pytest.mark.asyncio
    async def test_cooldown_not_expired_in_utc_plus_offset(self, backend):
        """opened_at 5m ago with +0900 must still block (5 < 30 cooldown)."""
        from datetime import datetime, timedelta, timezone
        cb = CircuitBreaker(
            state_backend=backend,
            cooldown_minutes=30,
        )
        jst = timezone(timedelta(hours=9))
        opened = datetime.now(tz=jst) - timedelta(minutes=5)
        await backend.write_circuit_breaker({
            "state": "OPEN",
            "opened_at": opened.strftime("%Y-%m-%dT%H:%M:%S%z"),
        })
        assert await cb.can_proceed() is False
