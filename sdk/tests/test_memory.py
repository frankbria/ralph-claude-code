"""Tests for ralph_sdk.memory — Episode/ProjectIndex, FileMemoryBackend, MemoryManager."""

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta

import pytest

from ralph_sdk.memory import (
    Episode,
    FileMemoryBackend,
    MemoryManager,
    ProjectIndex,
    _detect_configs,
    _detect_language,
    _detect_test_runner,
    _detect_top_dirs,
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------


def _ts(days_ago: float = 0) -> str:
    """Format an ISO-8601 timestamp `days_ago` days before now."""
    moment = datetime.now(UTC) - timedelta(days=days_ago)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


# ----------------------------------------------------------------------------
# FileMemoryBackend
# ----------------------------------------------------------------------------


class TestFileMemoryBackend:
    async def test_round_trip_episodes(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        ep = Episode(timestamp=_ts(), task="task-a", outcome="success", loop_count=1)
        await backend.append_episode(ep)
        loaded = await backend.read_episodes()
        assert len(loaded) == 1
        assert loaded[0].task == "task-a"
        assert loaded[0].outcome == "success"

    async def test_read_missing_returns_empty(self, tmp_path):
        backend = FileMemoryBackend(tmp_path / "fresh")
        assert await backend.read_episodes() == []

    async def test_skips_malformed_jsonl_lines(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        ep = Episode(timestamp=_ts(), task="ok", outcome="success")
        await backend.append_episode(ep)
        # Inject a junk line
        with backend._episodes_path.open("a") as f:  # noqa: SLF001
            f.write("not valid json\n")
            f.write("\n")  # blank — should be skipped silently
        loaded = await backend.read_episodes()
        assert len(loaded) == 1
        assert loaded[0].task == "ok"

    async def test_write_episodes_overwrites(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        await backend.append_episode(Episode(task="a"))
        await backend.append_episode(Episode(task="b"))
        await backend.write_episodes([Episode(task="c")])
        loaded = await backend.read_episodes()
        assert [ep.task for ep in loaded] == ["c"]

    async def test_write_empty_truncates(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        await backend.append_episode(Episode(task="a"))
        await backend.write_episodes([])
        assert await backend.read_episodes() == []

    async def test_project_index_round_trip(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        idx = ProjectIndex(language="python", test_runner="pytest", file_count=42)
        await backend.write_project_index(idx)
        loaded = await backend.read_project_index()
        assert loaded is not None
        assert loaded.language == "python"
        assert loaded.file_count == 42

    async def test_project_index_missing_returns_none(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        assert await backend.read_project_index() is None

    async def test_project_index_corrupt_returns_none(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        backend._index_path.write_text("not json")  # noqa: SLF001
        assert await backend.read_project_index() is None


# ----------------------------------------------------------------------------
# MemoryManager — episodic
# ----------------------------------------------------------------------------


class TestRecordEpisode:
    async def test_records_with_metadata(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await mgr.record_episode(
            outcome="success",
            work_type="IMPLEMENTATION",
            completed_task="add login",
            files_changed="auth.py",
            loop_count=5,
        )
        eps = await backend.read_episodes()
        assert len(eps) == 1
        assert eps[0].outcome == "success"
        assert eps[0].work_type == "IMPLEMENTATION"
        assert eps[0].loop_count == 5
        assert eps[0].timestamp  # non-empty ISO-8601

    async def test_enforces_max_episodes_cap(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend, max_episodes=3)
        for i in range(5):
            await mgr.record_episode(outcome="success", completed_task=f"t{i}")
        eps = await backend.read_episodes()
        assert len(eps) == 3
        # Oldest dropped — last 3 retained
        assert [ep.task for ep in eps] == ["t2", "t3", "t4"]


class TestGetRelevantEpisodes:
    async def test_returns_keyword_matches(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await backend.append_episode(
            Episode(timestamp=_ts(), task="fix login bug", outcome="success")
        )
        await backend.append_episode(
            Episode(timestamp=_ts(), task="rewrite payment flow", outcome="success")
        )
        results = await mgr.get_relevant_episodes("login form")
        assert len(results) == 1
        assert "login" in results[0].task

    async def test_failure_bias(self, tmp_path):
        """Failures score higher than successes for the same overlap."""
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await backend.append_episode(
            Episode(timestamp=_ts(), task="login work", outcome="success")
        )
        await backend.append_episode(
            Episode(timestamp=_ts(), task="login work", outcome="failure")
        )
        results = await mgr.get_relevant_episodes("login")
        assert len(results) == 2
        # Failure must outrank success
        assert results[0].outcome == "failure"
        assert results[0].relevance > results[1].relevance

    async def test_age_decay(self, tmp_path):
        """Older episodes score lower than fresher ones with same overlap."""
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend, decay_factor=0.5)
        await backend.append_episode(
            Episode(timestamp=_ts(days_ago=10), task="login", outcome="success")
        )
        await backend.append_episode(
            Episode(timestamp=_ts(days_ago=0), task="login", outcome="success")
        )
        results = await mgr.get_relevant_episodes("login")
        # Fresher one (smaller age) should rank first
        assert results[0].relevance > results[1].relevance

    async def test_empty_when_no_episodes(self, tmp_path):
        mgr = MemoryManager(FileMemoryBackend(tmp_path))
        assert await mgr.get_relevant_episodes("anything") == []

    async def test_empty_when_no_keywords(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await backend.append_episode(Episode(timestamp=_ts(), task="login"))
        # Punctuation-only task text yields no keywords
        assert await mgr.get_relevant_episodes("...") == []

    async def test_no_overlap_excluded(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await backend.append_episode(Episode(timestamp=_ts(), task="payment"))
        results = await mgr.get_relevant_episodes("login")
        assert results == []

    async def test_max_results_cap(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        for i in range(10):
            await backend.append_episode(
                Episode(timestamp=_ts(), task=f"login work {i}", outcome="success")
            )
        results = await mgr.get_relevant_episodes("login", max_results=3)
        assert len(results) == 3

    async def test_malformed_timestamp_does_not_crash(self, tmp_path):
        """Episode with bad timestamp gets age=0, still returned."""
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend)
        await backend.append_episode(Episode(timestamp="not-a-date", task="login"))
        results = await mgr.get_relevant_episodes("login")
        assert len(results) == 1


class TestPruneStale:
    async def test_removes_old_episodes(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend, decay_days=14)
        await backend.append_episode(
            Episode(timestamp=_ts(days_ago=20), task="old")
        )
        await backend.append_episode(
            Episode(timestamp=_ts(days_ago=1), task="fresh")
        )
        removed = await mgr.prune_stale()
        assert removed == 1
        remaining = await backend.read_episodes()
        assert len(remaining) == 1
        assert remaining[0].task == "fresh"

    async def test_returns_zero_when_empty(self, tmp_path):
        mgr = MemoryManager(FileMemoryBackend(tmp_path))
        assert await mgr.prune_stale() == 0

    async def test_no_writes_when_nothing_stale(self, tmp_path):
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend, decay_days=14)
        await backend.append_episode(Episode(timestamp=_ts(days_ago=1), task="fresh"))
        mtime_before = backend._episodes_path.stat().st_mtime  # noqa: SLF001
        time.sleep(0.01)  # ensure mtime resolution
        removed = await mgr.prune_stale()
        assert removed == 0
        mtime_after = backend._episodes_path.stat().st_mtime  # noqa: SLF001
        assert mtime_before == mtime_after  # file untouched

    async def test_malformed_timestamp_treated_as_stale(self, tmp_path):
        """Episodes with epoch=0 are older than any cutoff → pruned."""
        backend = FileMemoryBackend(tmp_path)
        mgr = MemoryManager(backend, decay_days=1)
        await backend.append_episode(Episode(timestamp="bad", task="x"))
        removed = await mgr.prune_stale()
        assert removed == 1


# ----------------------------------------------------------------------------
# MemoryManager — semantic / project index
# ----------------------------------------------------------------------------


class TestProjectIndex:
    async def test_get_returns_none_when_missing(self, tmp_path):
        mgr = MemoryManager(FileMemoryBackend(tmp_path))
        assert await mgr.get_project_index() is None

    async def test_generate_python_project(self, tmp_path):
        (tmp_path / "pyproject.toml").write_text("[tool.pytest]\n")
        (tmp_path / "src").mkdir()
        (tmp_path / "src" / "main.py").write_text("x=1")
        mgr = MemoryManager(FileMemoryBackend(tmp_path))
        idx = await mgr.generate_project_index(tmp_path)
        assert idx.language == "python"
        assert idx.test_runner == "pytest"
        assert idx.file_count >= 1
        # Cached
        cached = await mgr.get_project_index()
        assert cached is not None
        assert cached.language == "python"

    async def test_generate_javascript_project(self, tmp_path):
        (tmp_path / "package.json").write_text('{"devDependencies": {"jest": "^29"}}')
        mgr = MemoryManager(FileMemoryBackend(tmp_path))
        idx = await mgr.generate_project_index(tmp_path)
        assert idx.language == "javascript/typescript"
        assert idx.test_runner == "jest"


# ----------------------------------------------------------------------------
# Project-detection helpers (auto-detection)
# ----------------------------------------------------------------------------


class TestDetectionHelpers:
    def test_detect_language_python(self, tmp_path):
        (tmp_path / "pyproject.toml").write_text("")
        assert _detect_language(tmp_path) == "python"

    def test_detect_language_setup_py(self, tmp_path):
        (tmp_path / "setup.py").write_text("")
        assert _detect_language(tmp_path) == "python"

    def test_detect_language_javascript(self, tmp_path):
        (tmp_path / "package.json").write_text("{}")
        assert _detect_language(tmp_path) == "javascript/typescript"

    def test_detect_language_typescript_files(self, tmp_path):
        (tmp_path / "main.ts").write_text("")
        assert _detect_language(tmp_path) == "javascript/typescript"

    def test_detect_language_go(self, tmp_path):
        (tmp_path / "go.mod").write_text("")
        assert _detect_language(tmp_path) == "go"

    def test_detect_language_rust(self, tmp_path):
        (tmp_path / "Cargo.toml").write_text("")
        assert _detect_language(tmp_path) == "rust"

    def test_detect_language_java(self, tmp_path):
        (tmp_path / "pom.xml").write_text("")
        assert _detect_language(tmp_path) == "java"

    def test_detect_language_bash(self, tmp_path):
        (tmp_path / "tool.sh").write_text("#!/bin/bash")
        assert _detect_language(tmp_path) == "bash"

    def test_detect_language_unknown(self, tmp_path):
        assert _detect_language(tmp_path) == "unknown"

    def test_detect_test_runner_vitest(self, tmp_path):
        (tmp_path / "package.json").write_text('{"devDependencies": {"vitest": "^1"}}')
        assert _detect_test_runner(tmp_path) == "vitest"

    def test_detect_test_runner_bats(self, tmp_path):
        bats_dir = tmp_path / "tests"
        bats_dir.mkdir()
        (bats_dir / "thing.bats").write_text("")
        assert _detect_test_runner(tmp_path) == "bats"

    def test_detect_test_runner_go(self, tmp_path):
        (tmp_path / "go.mod").write_text("")
        assert _detect_test_runner(tmp_path) == "go test"

    def test_detect_test_runner_unknown(self, tmp_path):
        assert _detect_test_runner(tmp_path) == "unknown"

    def test_detect_top_dirs_skips_hidden_and_known(self, tmp_path):
        (tmp_path / "src").mkdir()
        (tmp_path / "tests").mkdir()
        (tmp_path / ".git").mkdir()  # hidden, must skip
        (tmp_path / "node_modules").mkdir()  # in skip set
        result = _detect_top_dirs(tmp_path)
        names = result.split(",")
        assert "src" in names
        assert "tests" in names
        assert ".git" not in names
        assert "node_modules" not in names

    def test_detect_configs_finds_known(self, tmp_path):
        (tmp_path / "pyproject.toml").write_text("")
        (tmp_path / ".ralphrc").write_text("")
        result = _detect_configs(tmp_path)
        assert "pyproject.toml" in result
        assert ".ralphrc" in result


# ----------------------------------------------------------------------------
# Models
# ----------------------------------------------------------------------------


class TestModels:
    def test_episode_defaults(self):
        ep = Episode()
        assert ep.outcome == "unknown"
        assert ep.work_type == "UNKNOWN"
        assert ep.relevance == 0.0

    def test_project_index_defaults(self):
        idx = ProjectIndex()
        assert idx.language == "unknown"
        assert idx.test_runner == "unknown"


@pytest.fixture(autouse=True)
def _reset():
    """Placeholder autouse fixture — keeps each test isolated."""
    yield
