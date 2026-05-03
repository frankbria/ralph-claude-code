"""Cross-session episodic and semantic memory for Ralph agents.

Port of lib/memory.sh to Python with async I/O and pluggable storage.

Episodic memory: records iteration outcomes (success/failure, work type,
    files changed, error summaries). Retrieves relevant episodes by keyword
    overlap with failure bias.

Semantic memory: project index (language, test runner, structure). Auto-detected
    from filesystem with configurable staleness threshold.

Memory decay: exponential scoring with age-based pruning (Ebbinghaus-inspired).
"""

from __future__ import annotations

import logging
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from pydantic import BaseModel, ValidationError

logger = logging.getLogger("ralph.sdk.memory")


# =============================================================================
# Models
# =============================================================================


class Episode(BaseModel):
    """A single iteration outcome recorded for future retrieval."""

    timestamp: str = ""
    task: str = ""
    outcome: str = "unknown"  # "success" | "failure"
    work_type: str = "UNKNOWN"
    files_changed: str = ""
    error_summary: str = ""
    loop_count: int = 0
    relevance: float = 0.0  # computed at retrieval time


class ProjectIndex(BaseModel):
    """Semantic memory: detected project characteristics."""

    generated_at: str = ""
    language: str = "unknown"
    test_runner: str = "unknown"
    file_count: int = 0
    top_directories: str = ""
    config_files: str = ""


# =============================================================================
# Storage Protocol
# =============================================================================


class MemoryBackend(Protocol):
    """Pluggable storage for memory episodes."""

    async def read_episodes(self) -> list[Episode]: ...
    async def write_episodes(self, episodes: list[Episode]) -> None: ...
    async def append_episode(self, episode: Episode) -> None: ...
    async def read_project_index(self) -> ProjectIndex | None: ...
    async def write_project_index(self, index: ProjectIndex) -> None: ...


# =============================================================================
# File-based Backend (default — matches bash JSONL behavior)
# =============================================================================


class FileMemoryBackend:
    """JSONL file-based memory storage, matching lib/memory.sh."""

    def __init__(self, memory_dir: str | Path) -> None:
        self._dir = Path(memory_dir)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._episodes_path = self._dir / "episodes.jsonl"
        self._index_path = self._dir / "project_index.json"

    async def read_episodes(self) -> list[Episode]:
        if not self._episodes_path.exists():
            return []
        episodes = []
        for line in self._episodes_path.read_text().splitlines():
            line = line.strip()
            if line:
                try:
                    episodes.append(Episode.model_validate_json(line))
                except (ValidationError, ValueError) as e:
                    # Skip malformed JSONL lines — index file is append-only
                    # and may contain partial writes from a crashed process.
                    logger.debug("Skipping malformed episode line: %s", e)
                    continue
        return episodes

    async def write_episodes(self, episodes: list[Episode]) -> None:
        lines = [ep.model_dump_json() for ep in episodes]
        self._episodes_path.write_text("\n".join(lines) + "\n" if lines else "")

    async def append_episode(self, episode: Episode) -> None:
        with self._episodes_path.open("a") as f:
            f.write(episode.model_dump_json() + "\n")

    async def read_project_index(self) -> ProjectIndex | None:
        if not self._index_path.exists():
            return None
        try:
            return ProjectIndex.model_validate_json(self._index_path.read_text())
        except (ValidationError, ValueError, OSError) as e:
            # Index regenerates on next write; treat read failure as "not present".
            logger.debug("ProjectIndex read failed (%s); will regenerate", e)
            return None

    async def write_project_index(self, index: ProjectIndex) -> None:
        self._index_path.write_text(index.model_dump_json(indent=2))


# =============================================================================
# Memory Manager
# =============================================================================


class MemoryManager:
    """Cross-session memory with episodic retrieval and decay.

    Args:
        backend: Storage backend (FileMemoryBackend or custom).
        max_episodes: Maximum episodes to retain (default 100).
        decay_days: Days before pruning old episodes (default 14).
        decay_factor: Per-day relevance decay multiplier (default 0.9).
    """

    def __init__(
        self,
        backend: MemoryBackend,
        *,
        max_episodes: int = 100,
        decay_days: int = 14,
        decay_factor: float = 0.9,
    ) -> None:
        self.backend = backend
        self.max_episodes = max_episodes
        self.decay_days = decay_days
        self.decay_factor = decay_factor

    # --- Episodic Memory ---

    async def record_episode(
        self,
        outcome: str,
        work_type: str = "UNKNOWN",
        completed_task: str = "",
        error_summary: str = "",
        files_changed: str = "",
        loop_count: int = 0,
    ) -> None:
        """Record an iteration outcome.

        Args:
            outcome: "success" or "failure".
            work_type: IMPLEMENTATION, TESTING, etc.
            completed_task: Description of what was done.
            error_summary: Error text if outcome is "failure".
            files_changed: Comma-separated list of changed files.
            loop_count: Current loop iteration number.
        """
        episode = Episode(
            timestamp=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            task=completed_task,
            outcome=outcome,
            work_type=work_type,
            files_changed=files_changed,
            error_summary=error_summary,
            loop_count=loop_count,
        )
        await self.backend.append_episode(episode)
        await self._enforce_max_episodes()

    async def get_relevant_episodes(
        self,
        task_text: str,
        max_results: int = 5,
    ) -> list[Episode]:
        """Retrieve episodes relevant to a task description.

        Scoring: keyword overlap + failure bias (+2 for failures).
        Results sorted by relevance descending.

        Args:
            task_text: Current task description to match against.
            max_results: Maximum episodes to return.

        Returns:
            List of Episode objects with relevance scores.
        """
        episodes = await self.backend.read_episodes()
        if not episodes:
            return []

        # Extract keywords from task
        keywords = set(
            w.lower()
            for w in re.findall(r"[a-zA-Z_][a-zA-Z0-9_]+", task_text)
        )
        if not keywords:
            return []

        scored: list[Episode] = []
        for ep in episodes:
            ep_text = f"{ep.task} {ep.files_changed} {ep.error_summary}".lower()
            ep_words = set(re.findall(r"[a-zA-Z_][a-zA-Z0-9_]+", ep_text))

            # Keyword overlap
            overlap = len(keywords & ep_words)
            if overlap == 0:
                continue

            # Failure bias
            failure_bonus = 2.0 if ep.outcome == "failure" else 0.0

            # Age decay
            age_days = self._episode_age_days(ep)
            decay = self.decay_factor ** age_days

            ep.relevance = (overlap + failure_bonus) * decay
            scored.append(ep)

        scored.sort(key=lambda e: e.relevance, reverse=True)
        return scored[:max_results]

    async def prune_stale(self) -> int:
        """Remove episodes older than decay_days. Returns count removed."""
        episodes = await self.backend.read_episodes()
        if not episodes:
            return 0

        cutoff = time.time() - (self.decay_days * 86400)
        kept = [ep for ep in episodes if self._episode_epoch(ep) >= cutoff]
        removed = len(episodes) - len(kept)

        if removed > 0:
            await self.backend.write_episodes(kept)
        return removed

    # --- Semantic Memory ---

    async def get_project_index(self) -> ProjectIndex | None:
        """Get the cached project index, or None if stale/missing."""
        return await self.backend.read_project_index()

    async def generate_project_index(self, project_root: str | Path) -> ProjectIndex:
        """Detect project characteristics and cache them.

        Args:
            project_root: Path to the project root directory.

        Returns:
            ProjectIndex with detected language, test runner, etc.
        """
        root = Path(project_root)
        index = ProjectIndex(
            generated_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            language=_detect_language(root),
            test_runner=_detect_test_runner(root),
            file_count=_count_files(root),
            top_directories=_detect_top_dirs(root),
            config_files=_detect_configs(root),
        )
        await self.backend.write_project_index(index)
        return index

    # --- Internal ---

    async def _enforce_max_episodes(self) -> None:
        episodes = await self.backend.read_episodes()
        if len(episodes) > self.max_episodes:
            await self.backend.write_episodes(episodes[-self.max_episodes :])

    @staticmethod
    def _episode_age_days(ep: Episode) -> float:
        try:
            ep_time = datetime.strptime(ep.timestamp, "%Y-%m-%dT%H:%M:%SZ")
            ep_time = ep_time.replace(tzinfo=UTC)
            return (datetime.now(UTC) - ep_time).total_seconds() / 86400
        except (ValueError, TypeError):
            return 0.0

    @staticmethod
    def _episode_epoch(ep: Episode) -> float:
        try:
            ep_time = datetime.strptime(ep.timestamp, "%Y-%m-%dT%H:%M:%SZ")
            ep_time = ep_time.replace(tzinfo=UTC)
            return ep_time.timestamp()
        except (ValueError, TypeError):
            return 0.0


# =============================================================================
# Project detection helpers
# =============================================================================


def _detect_language(root: Path) -> str:
    if (root / "package.json").exists() or list(root.glob("*.ts"))[:1]:
        return "javascript/typescript"
    if (root / "pyproject.toml").exists() or (root / "setup.py").exists():
        return "python"
    if (root / "go.mod").exists():
        return "go"
    if (root / "Cargo.toml").exists():
        return "rust"
    if (root / "pom.xml").exists() or (root / "build.gradle").exists():
        return "java"
    if list(root.glob("*.sh"))[:1]:
        return "bash"
    return "unknown"


def _detect_test_runner(root: Path) -> str:
    pkg = root / "package.json"
    if pkg.exists():
        try:
            text = pkg.read_text()
            if '"jest"' in text or '"vitest"' in text:
                return "jest" if '"jest"' in text else "vitest"
        except OSError as e:
            logger.debug("package.json read failed: %s", e)
    pyproj = root / "pyproject.toml"
    if pyproj.exists():
        try:
            if "pytest" in pyproj.read_text():
                return "pytest"
        except OSError as e:
            logger.debug("pyproject.toml read failed: %s", e)
    if list(root.glob("tests/*.bats"))[:1]:
        return "bats"
    if (root / "go.mod").exists():
        return "go test"
    return "unknown"


def _count_files(root: Path, max_depth: int = 3) -> int:
    skip = {".git", "node_modules", ".ralph", "__pycache__", ".cache", ".venv"}
    count = 0
    try:
        for item in root.rglob("*"):
            if item.is_file() and not any(p in item.parts for p in skip):
                count += 1
                if count > 10000:
                    break
    except (PermissionError, OSError):
        pass
    return count


def _detect_top_dirs(root: Path) -> str:
    skip = {"node_modules", ".git", ".ralph", "__pycache__", ".cache", ".venv"}
    dirs = []
    try:
        for item in sorted(root.iterdir()):
            if item.is_dir() and item.name not in skip and not item.name.startswith("."):
                dirs.append(item.name)
                if len(dirs) >= 10:
                    break
    except (PermissionError, OSError):
        pass
    return ",".join(dirs)


def _detect_configs(root: Path) -> str:
    candidates = [
        ".ralphrc", "ralph.config.json", "package.json", "pyproject.toml",
        "tsconfig.json", "Cargo.toml", "go.mod", "pom.xml",
    ]
    found = [c for c in candidates if (root / c).exists()]
    return ",".join(found)
