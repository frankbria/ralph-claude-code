"""Tests for ralph_sdk.import_graph."""
from __future__ import annotations

from pathlib import Path

from ralph_sdk.import_graph import (
    CachedImportGraph,
    build_import_graph,
    build_js_graph,
    build_python_graph,
)


def _write(p: Path, body: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body, encoding="utf-8")


class TestBuildPythonGraph:
    def test_resolves_import_from(self, tmp_path: Path) -> None:
        _write(tmp_path / "pkg" / "__init__.py", "")
        _write(tmp_path / "pkg" / "sub" / "__init__.py", "")
        _write(tmp_path / "pkg" / "a.py", "from pkg.sub import b\n")
        _write(tmp_path / "pkg" / "sub" / "b.py", "x = 1\n")
        graph = build_python_graph(tmp_path)
        # ImportFrom resolves node.module (`pkg.sub`) → pkg/sub/__init__.py
        assert "pkg/sub/__init__.py" in graph["pkg/a.py"]  # nosec B101  # pytest assertion

    def test_resolves_plain_import(self, tmp_path: Path) -> None:
        _write(tmp_path / "lib.py", "x = 1\n")
        _write(tmp_path / "main.py", "import lib\n")
        graph = build_python_graph(tmp_path)
        assert graph["main.py"] == ["lib.py"]  # nosec B101  # pytest assertion

    def test_skips_dunder_dirs(self, tmp_path: Path) -> None:
        _write(tmp_path / "__pycache__" / "ignored.py", "import sys\n")
        _write(tmp_path / "real.py", "x = 1\n")
        graph = build_python_graph(tmp_path)
        assert "real.py" in graph  # nosec B101  # pytest assertion
        assert all("__pycache__" not in k for k in graph)  # nosec B101  # pytest assertion

    def test_handles_syntax_error_silently(self, tmp_path: Path) -> None:
        _write(tmp_path / "broken.py", "def x(:\n")
        _write(tmp_path / "ok.py", "y = 1\n")
        graph = build_python_graph(tmp_path)
        assert "broken.py" not in graph  # nosec B101  # pytest assertion
        assert "ok.py" in graph  # nosec B101  # pytest assertion

    def test_unresolvable_import_dropped(self, tmp_path: Path) -> None:
        _write(tmp_path / "main.py", "import nonexistent_pkg\n")
        graph = build_python_graph(tmp_path)
        assert graph["main.py"] == []  # nosec B101  # pytest assertion


class TestBuildJsGraph:
    def test_resolves_relative_import(self, tmp_path: Path) -> None:
        _write(tmp_path / "lib.ts", "export const x = 1;\n")
        _write(tmp_path / "main.ts", "import {x} from './lib';\n")
        graph = build_js_graph(tmp_path)
        assert "lib.ts" in graph["main.ts"]  # nosec B101  # pytest assertion

    def test_skips_bare_package_imports(self, tmp_path: Path) -> None:
        _write(tmp_path / "main.ts", "import React from 'react';\n")
        graph = build_js_graph(tmp_path)
        assert graph["main.ts"] == []  # nosec B101  # pytest assertion


class TestBuildImportGraphAutoDetect:
    def test_detects_python_via_pyproject(self, tmp_path: Path) -> None:
        _write(tmp_path / "pyproject.toml", "[project]\nname='x'\n")
        _write(tmp_path / "main.py", "import os\n")
        graph = build_import_graph(tmp_path)
        assert "main.py" in graph  # nosec B101  # pytest assertion

    def test_detects_js_via_package_json(self, tmp_path: Path) -> None:
        _write(tmp_path / "package.json", "{}")
        _write(tmp_path / "main.ts", "x = 1;\n")
        graph = build_import_graph(tmp_path)
        assert "main.ts" in graph  # nosec B101  # pytest assertion

    def test_unknown_returns_empty(self, tmp_path: Path) -> None:
        assert build_import_graph(tmp_path) == {}  # nosec B101  # pytest assertion


class TestCachedImportGraph:
    def test_rebuild_writes_cache(self, tmp_path: Path) -> None:
        _write(tmp_path / "pyproject.toml", "[project]\nname='x'\n")
        _write(tmp_path / "main.py", "x = 1\n")
        cache = tmp_path / ".ralph" / ".import_graph.json"
        c = CachedImportGraph(tmp_path, cache_path=cache)
        c.rebuild()
        assert cache.exists()  # nosec B101  # pytest assertion

    def test_get_uses_cache_when_fresh(self, tmp_path: Path) -> None:
        _write(tmp_path / "pyproject.toml", "[project]\nname='x'\n")
        _write(tmp_path / "main.py", "x = 1\n")
        c = CachedImportGraph(tmp_path)
        first = c.get()
        # Mutate disk; in-memory cache should mask it
        _write(tmp_path / "main.py", "import os\n")
        assert c.get() == first  # nosec B101  # pytest assertion

    def test_invalidate_clears_cache(self, tmp_path: Path) -> None:
        _write(tmp_path / "pyproject.toml", "[project]\nname='x'\n")
        _write(tmp_path / "main.py", "x = 1\n")
        c = CachedImportGraph(tmp_path)
        c.rebuild()
        assert c.cache_path.exists()  # nosec B101  # pytest assertion
        c.invalidate()
        assert not c.cache_path.exists()  # nosec B101  # pytest assertion

    def test_imports_check(self, tmp_path: Path) -> None:
        _write(tmp_path / "pyproject.toml", "[project]\nname='x'\n")
        _write(tmp_path / "lib.py", "x = 1\n")
        _write(tmp_path / "main.py", "import lib\n")
        c = CachedImportGraph(tmp_path)
        assert c.imports("main.py", "lib.py") is True  # nosec B101  # pytest assertion
        assert c.imports("main.py", "missing.py") is False  # nosec B101  # pytest assertion
