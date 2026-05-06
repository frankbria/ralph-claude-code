"""File dependency graph via AST parsing.

Port of lib/import_graph.sh to Python. Builds a file-level import graph
and caches it for use by the plan optimizer.

Language support:
  - Python: ast.parse() (zero external deps)
  - JS/TS: regex-based extraction (import/require)
  - Other: empty graph, falls back to directory proximity
"""

from __future__ import annotations

import ast
import json
import re
import time
from pathlib import Path

_SKIP_DIRS = {"node_modules", ".venv", "__pycache__", ".git", ".ralph", ".cache"}


_PY_MODULE_EXTS = (".py", "/__init__.py")


def _resolve_python_module(module: str, root: Path) -> str | None:
    """Map a dotted module path to its on-disk source relative to `root`."""
    mod_path = module.replace(".", "/")
    for ext in _PY_MODULE_EXTS:
        candidate = root / (mod_path + ext)
        if candidate.exists():
            return str(candidate.relative_to(root))
    return None


def _python_imports_for_node(node: ast.AST, root: Path) -> list[str]:
    if isinstance(node, ast.ImportFrom) and node.module:
        rel = _resolve_python_module(node.module, root)
        return [rel] if rel else []
    if isinstance(node, ast.Import):
        return [
            rel for alias in node.names
            if (rel := _resolve_python_module(alias.name, root)) is not None
        ]
    return []


def _python_file_deps(file_path: Path, root: Path) -> list[str]:
    tree = ast.parse(file_path.read_text(encoding="utf-8", errors="ignore"))
    deps: list[str] = []
    for node in ast.walk(tree):
        deps.extend(_python_imports_for_node(node, root))
    return sorted({d.replace("\\", "/") for d in deps})


def build_python_graph(project_root: Path) -> dict[str, list[str]]:
    """Build import graph for Python project via ast.parse().

    Returns a dict mapping relative file path to its sorted dependency paths.
    """
    root = project_root.resolve()
    graph: dict[str, list[str]] = {}
    for f in root.rglob("*.py"):
        if any(part in _SKIP_DIRS for part in f.parts):
            continue
        try:
            deps = _python_file_deps(f, root)
        except (SyntaxError, UnicodeDecodeError, OSError):
            continue
        rel = str(f.relative_to(root)).replace("\\", "/")
        graph[rel] = deps
    return graph


def build_js_graph(project_root: Path) -> dict[str, list[str]]:
    """Build import graph for JS/TS project via regex extraction.

    Returns:
        Dict mapping relative file path to list of relative dependency paths.
    """
    root = project_root.resolve()
    graph: dict[str, list[str]] = {}
    import_re = re.compile(
        r"""(?:import\s+.*?from\s+['"](.+?)['"]|require\(['"](.+?)['"]\))"""
    )
    js_extensions = ["*.js", "*.jsx", "*.ts", "*.tsx"]
    resolve_exts = ["", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.js"]

    for ext_pattern in js_extensions:
        for f in root.rglob(ext_pattern):
            if any(part in _SKIP_DIRS for part in f.parts):
                continue
            try:
                content = f.read_text(encoding="utf-8", errors="ignore")
                resolved: list[str] = []
                for m in import_re.finditer(content):
                    dep = m.group(1) or m.group(2)
                    if not dep.startswith("."):
                        continue  # skip bare package imports
                    candidate = (f.parent / dep).resolve()
                    for try_ext in resolve_exts:
                        full = Path(str(candidate) + try_ext)
                        if full.exists():
                            try:
                                resolved.append(str(full.relative_to(root)))
                            except ValueError:
                                pass
                            break
                graph[str(f.relative_to(root)).replace("\\", "/")] = sorted(
                    set(r.replace("\\", "/") for r in resolved)
                )
            except (UnicodeDecodeError, OSError):
                pass

    return graph


def build_import_graph(
    project_root: str | Path,
    project_type: str | None = None,
) -> dict[str, list[str]]:
    """Auto-detect project type and build import graph.

    Args:
        project_root: Path to the project root.
        project_type: Override auto-detection ("python", "javascript", etc.).

    Returns:
        Dict mapping file path to list of dependency file paths.
    """
    root = Path(project_root).resolve()

    if project_type is None:
        if (root / "pyproject.toml").exists() or (root / "setup.py").exists():
            project_type = "python"
        elif (root / "package.json").exists() or (root / "tsconfig.json").exists():
            project_type = "javascript"

    if project_type == "python":
        return build_python_graph(root)
    elif project_type in ("javascript", "typescript", "js", "ts"):
        return build_js_graph(root)
    return {}


class CachedImportGraph:
    """Import graph with JSON file caching and staleness detection.

    Args:
        project_root: Path to the project root.
        cache_path: Path to the cache file (default: .ralph/.import_graph.json).
        max_age_seconds: Cache staleness threshold (default: 3600 = 1 hour).
        project_type: Override auto-detection.
    """

    def __init__(
        self,
        project_root: str | Path,
        cache_path: str | Path | None = None,
        max_age_seconds: int = 3600,
        project_type: str | None = None,
    ) -> None:
        self.project_root = Path(project_root).resolve()
        self.cache_path = Path(
            cache_path or (self.project_root / ".ralph" / ".import_graph.json")
        )
        self.max_age_seconds = max_age_seconds
        self.project_type = project_type
        self._graph: dict[str, list[str]] | None = None

    def get(self) -> dict[str, list[str]]:
        """Get the import graph, rebuilding if stale or missing."""
        if self._graph is not None:
            return self._graph

        if self._is_cache_fresh():
            try:
                data = json.loads(self.cache_path.read_text())
                if isinstance(data, dict):
                    self._graph = data
                    return self._graph
            except (json.JSONDecodeError, OSError):
                pass

        self._graph = self.rebuild()
        return self._graph

    def rebuild(self) -> dict[str, list[str]]:
        """Force rebuild the import graph and update cache."""
        graph = build_import_graph(self.project_root, self.project_type)
        self._graph = graph
        try:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            self.cache_path.write_text(json.dumps(graph, indent=2))
        except OSError:
            pass
        return graph

    def invalidate(self) -> None:
        """Mark the cache as stale."""
        self._graph = None
        try:
            self.cache_path.unlink(missing_ok=True)
        except OSError:
            pass

    def imports(self, file_a: str, file_b: str) -> bool:
        """Check if file_a imports file_b."""
        graph = self.get()
        return file_b in graph.get(file_a, [])

    def _is_cache_fresh(self) -> bool:
        if not self.cache_path.exists():
            return False
        try:
            age = time.time() - self.cache_path.stat().st_mtime
            return age < self.max_age_seconds
        except OSError:
            return False
