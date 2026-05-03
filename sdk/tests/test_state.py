"""Tests for Ralph SDK pluggable state backend (async)."""

import pytest

from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend


@pytest.fixture
def ralph_dir(tmp_path):
    d = tmp_path / ".ralph"
    d.mkdir()
    return d


class TestFileStateBackend:
    def test_implements_protocol(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        assert isinstance(backend, RalphStateBackend)

    @pytest.mark.asyncio
    async def test_status_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        data = {"WORK_TYPE": "TESTING", "EXIT_SIGNAL": False}
        await backend.write_status(data)
        loaded = await backend.read_status()
        assert loaded["WORK_TYPE"] == "TESTING"

    @pytest.mark.asyncio
    async def test_circuit_breaker_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        data = {"state": "OPEN", "no_progress_count": 3}
        await backend.write_circuit_breaker(data)
        loaded = await backend.read_circuit_breaker()
        assert loaded["state"] == "OPEN"
        assert loaded["no_progress_count"] == 3

    @pytest.mark.asyncio
    async def test_call_count_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_call_count(42)
        assert await backend.read_call_count() == 42

    @pytest.mark.asyncio
    async def test_last_reset_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_last_reset(1234567890)
        assert await backend.read_last_reset() == 1234567890

    @pytest.mark.asyncio
    async def test_session_id_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_session_id("sess-abc-123")
        assert await backend.read_session_id() == "sess-abc-123"

    @pytest.mark.asyncio
    async def test_fix_plan_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        content = "- [ ] Task 1\n- [x] Task 2\n"
        await backend.write_fix_plan(content)
        loaded = await backend.read_fix_plan()
        assert "Task 1" in loaded
        assert "Task 2" in loaded

    @pytest.mark.asyncio
    async def test_read_missing_returns_defaults(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        assert await backend.read_status() == {}
        assert await backend.read_circuit_breaker() == {}
        assert await backend.read_call_count() == 0
        assert await backend.read_last_reset() == 0
        assert await backend.read_session_id() == ""
        assert await backend.read_fix_plan() == ""

    @pytest.mark.asyncio
    async def test_atomic_write_no_tmp_files(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_status({"test": True})
        tmp_files = list(ralph_dir.glob("*.tmp"))
        assert len(tmp_files) == 0


class TestNullStateBackend:
    def test_implements_protocol(self):
        backend = NullStateBackend()
        assert isinstance(backend, RalphStateBackend)

    @pytest.mark.asyncio
    async def test_status_round_trip(self):
        backend = NullStateBackend()
        data = {"WORK_TYPE": "TESTING", "EXIT_SIGNAL": False}
        await backend.write_status(data)
        loaded = await backend.read_status()
        assert loaded["WORK_TYPE"] == "TESTING"

    @pytest.mark.asyncio
    async def test_circuit_breaker_round_trip(self):
        backend = NullStateBackend()
        data = {"state": "OPEN", "no_progress_count": 3}
        await backend.write_circuit_breaker(data)
        loaded = await backend.read_circuit_breaker()
        assert loaded["state"] == "OPEN"

    @pytest.mark.asyncio
    async def test_call_count_round_trip(self):
        backend = NullStateBackend()
        await backend.write_call_count(42)
        assert await backend.read_call_count() == 42

    @pytest.mark.asyncio
    async def test_session_id_round_trip(self):
        backend = NullStateBackend()
        await backend.write_session_id("sess-xyz")
        assert await backend.read_session_id() == "sess-xyz"

    @pytest.mark.asyncio
    async def test_creates_no_files(self, tmp_path):
        """NullStateBackend must not create any files."""
        backend = NullStateBackend()
        await backend.write_status({"test": True})
        await backend.write_circuit_breaker({"state": "OPEN"})
        await backend.write_call_count(10)
        await backend.write_last_reset(12345)
        await backend.write_session_id("sess")
        await backend.write_fix_plan("plan")

        # No files should exist in tmp_path
        assert list(tmp_path.iterdir()) == []

    @pytest.mark.asyncio
    async def test_read_defaults(self):
        backend = NullStateBackend()
        assert await backend.read_status() == {}
        assert await backend.read_circuit_breaker() == {}
        assert await backend.read_call_count() == 0
        assert await backend.read_last_reset() == 0
        assert await backend.read_session_id() == ""
        assert await backend.read_fix_plan() == ""


class TestTap625AtomicWrites:
    """TAP-625: every FileStateBackend text writer goes through _atomic_write.

    A SIGTERM between truncate and write must not leave a zero-byte counter
    that silently reads back as 0 (rate-limit bypass).
    """

    @pytest.mark.asyncio
    async def test_call_count_uses_atomic_write(self, ralph_dir, monkeypatch):
        import ralph_sdk.state as state_mod
        backend = state_mod.FileStateBackend(ralph_dir)
        seen: list[str] = []

        async def spy(self, path, content):
            seen.append(path.name)
            return await state_mod.FileStateBackend._atomic_write_impl(self, path, content) if False else None  # noqa
        # Replace _atomic_write to record the path
        async def recorder(path, content):
            seen.append(path.name)
            # Also actually write, so round-trip tests below still pass
            path.write_text(content, encoding="utf-8")

        monkeypatch.setattr(backend, "_atomic_write", recorder)
        await backend.write_call_count(5)
        await backend.write_last_reset(1700000000)
        await backend.write_session_id("abc")
        await backend.write_fix_plan("- [ ] one\n")

        assert ".call_count" in seen
        assert ".last_reset" in seen
        assert ".claude_session_id" in seen
        assert "fix_plan.md" in seen

    @pytest.mark.asyncio
    async def test_write_text_helper_is_gone(self):
        """The non-atomic helper must not exist — callers can't regress to it."""
        from ralph_sdk.state import FileStateBackend
        assert not hasattr(FileStateBackend, "_write_text")

    @pytest.mark.asyncio
    async def test_atomic_write_produces_old_or_new_never_empty(self, ralph_dir, monkeypatch):
        """Simulate an interrupted aiofiles write during _atomic_write.

        Because _atomic_write writes to a tmp file and only then renames,
        an exception mid-write must leave the target file at its prior
        contents — never truncated.
        """
        from ralph_sdk.state import FileStateBackend
        backend = FileStateBackend(ralph_dir)
        target = ralph_dir / ".call_count"
        target.write_text("42\n")

        # Make the aiofiles write blow up after opening the tmp file.
        import aiofiles
        original_open = aiofiles.open

        def exploding_open(*args, **kwargs):
            class Boom:
                async def __aenter__(self):
                    return self
                async def __aexit__(self, *a):
                    return False
                async def write(self, *a, **k):
                    raise OSError("simulated SIGTERM")
            return Boom()

        monkeypatch.setattr(aiofiles, "open", exploding_open)
        with pytest.raises(IOError):
            await backend.write_call_count(99)
        # Target must still contain the old value — not be empty.
        assert target.read_text() == "42\n"
