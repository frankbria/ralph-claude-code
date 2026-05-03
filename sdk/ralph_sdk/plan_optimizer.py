"""Fix plan task reordering engine.

Port of lib/plan_optimizer.sh to Python. Reorders unchecked tasks within
each section of fix_plan.md for optimal execution order.

Three-layer dependency detection:
  1. Import graph (highest confidence) — file A imports file B
  2. Explicit metadata (human override) — <!-- id: -->, <!-- depends: -->
  3. Phase convention (lowest priority) — create → implement → test → document

Topological sort for dependency ordering, then secondary sort by
module locality, phase, and size for stable grouping.

Semantic equivalence validation before write (Bazel-inspired).
"""

from __future__ import annotations

import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from ralph_sdk.import_graph import CachedImportGraph

# =============================================================================
# Task model
# =============================================================================

_FILE_PATTERN = re.compile(
    r"[a-zA-Z0-9_/./-]+\.(?:py|ts|tsx|js|jsx|sh|json|yaml|yml|toml|md|css|html|go|rs|rb|java)"
)
_BACKTICK_FILE = re.compile(r"`([^`]+\.[a-zA-Z]+)`")
_METADATA_ID = re.compile(r"<!--\s*id:\s*([a-zA-Z0-9_-]+)\s*-->")
_METADATA_DEPENDS = re.compile(r"<!--\s*depends:\s*([a-zA-Z0-9_-]+)\s*-->")
_METADATA_RESOLVED = re.compile(r"<!--\s*resolved:\s*([a-zA-Z0-9_/./-]+)\s*-->")
_CHECKBOX = re.compile(r"^- \[([xX ])\]\s*(.*)")
_SECTION = re.compile(r"^## (.+)")


@dataclass
class Task:
    """A parsed task from fix_plan.md."""

    idx: int = 0
    line_num: int = 0
    section: str = ""
    text: str = ""
    raw_line: str = ""
    checked: bool = False
    files: list[str] = field(default_factory=list)
    task_id: str = ""
    depends: str = ""
    size: int = 1  # 0=SMALL, 1=MEDIUM, 2=LARGE


# =============================================================================
# Parsing
# =============================================================================


def parse_tasks(fix_plan_path: str | Path) -> list[Task]:
    """Parse fix_plan.md into structured Task objects."""
    path = Path(fix_plan_path)
    if not path.exists():
        return []

    tasks: list[Task] = []
    current_section = ""

    for line_num, line in enumerate(path.read_text().splitlines(), 1):
        sec_match = _SECTION.match(line)
        if sec_match:
            current_section = sec_match.group(0)
            continue

        cb_match = _CHECKBOX.match(line)
        if not cb_match:
            continue

        checked = cb_match.group(1).lower() == "x"
        text = cb_match.group(2).strip()

        # Extract files from backtick references
        files: list[str] = []
        for m in _BACKTICK_FILE.finditer(text):
            files.append(m.group(1))

        # Extract bare file paths
        for m in _FILE_PATTERN.finditer(text):
            if m.group() not in files:
                files.append(m.group())

        # Extract resolved files from metadata
        resolved = _METADATA_RESOLVED.search(text)
        if resolved and resolved.group(1) not in files:
            files.append(resolved.group(1))

        # Extract metadata
        task_id_m = _METADATA_ID.search(text)
        depends_m = _METADATA_DEPENDS.search(text)

        # Clean text for comparison (strip metadata comments)
        clean_text = re.sub(r"<!--\s*[a-zA-Z]+:\s*[a-zA-Z0-9_./ -]+\s*-->", "", text).strip()
        clean_text = re.sub(r"\s+", " ", clean_text)

        # Size estimation
        size = _estimate_size(clean_text, len(files))

        tasks.append(Task(
            idx=len(tasks),
            line_num=line_num,
            section=current_section,
            text=clean_text,
            raw_line=line,
            checked=checked,
            files=files,
            task_id=task_id_m.group(1) if task_id_m else "",
            depends=depends_m.group(1) if depends_m else "",
            size=size,
        ))

    return tasks


def _estimate_size(text: str, file_count: int) -> int:
    """Inline size estimation: 0=SMALL, 1=MEDIUM, 2=LARGE."""
    lower = text.lower()
    if file_count <= 1 and re.search(
        r"rename|typo|config|comment|remove unused|fix.*import|bump.*version|update.*version",
        lower,
    ):
        return 0
    if file_count >= 3 or re.search(
        r"redesign|architect|cross.?module|new feature|security|integrate|migrate",
        lower,
    ):
        return 2
    return 1


# =============================================================================
# Phase ranking (SWE-bench agent convergence ordering)
# =============================================================================


def phase_rank(text: str) -> int:
    """Keyword-based phase rank.

    0 = create/setup/init/define/schema/scaffold
    1 = implement/add/build/write/develop
    2 = modify/refactor/update/fix/change (default)
    3 = test/spec/verify/validate
    4 = document/readme/comment/changelog/release
    """
    lower = text.lower()
    if re.search(r"create|setup|init|define|schema|scaffold|bootstrap", lower):
        return 0
    if re.search(r"implement|add|build|write|develop", lower):
        return 1
    if re.search(r"test|spec|verify|validate|assert", lower):
        return 3
    if re.search(r"doc|readme|comment|changelog|release", lower):
        return 4
    return 2  # modify/refactor/update/fix default


# =============================================================================
# Dependency detection + topological sort
# =============================================================================


def _build_dependency_edges(
    tasks: list[Task],
    graph: CachedImportGraph | None,
) -> list[tuple[int, int]]:
    """Three-layer dependency detection. Returns (before, after) index pairs."""
    edges: list[tuple[int, int]] = []
    unchecked = [t for t in tasks if not t.checked]

    for i, ti in enumerate(unchecked):
        for j, tj in enumerate(unchecked):
            if i >= j:
                continue
            # Never cross sections
            if ti.section != tj.section:
                continue

            # Layer 2: Explicit metadata (human override — highest priority)
            if tj.depends and tj.depends == ti.task_id:
                edges.append((ti.idx, tj.idx))
                continue
            if ti.depends and ti.depends == tj.task_id:
                edges.append((tj.idx, ti.idx))
                continue

            # Layer 1: Import graph
            if graph is not None:
                import_graph = graph.get()
                found = False
                for fi in ti.files:
                    if found:
                        break
                    for fj in tj.files:
                        # file_i imports file_j → task j before task i
                        if fj in import_graph.get(fi, []):
                            edges.append((tj.idx, ti.idx))
                            found = True
                            break
                        # file_j imports file_i → task i before task j
                        if fi in import_graph.get(fj, []):
                            edges.append((ti.idx, tj.idx))
                            found = True
                            break

    return edges


def _topological_sort(task_count: int, edges: list[tuple[int, int]]) -> list[int]:
    """Kahn's algorithm for topological sort. Cycle-tolerant (best-effort)."""
    if not edges:
        return list(range(task_count))

    adj: dict[int, list[int]] = {i: [] for i in range(task_count)}
    in_degree: dict[int, int] = {i: 0 for i in range(task_count)}

    for u, v in edges:
        if u in adj and v in in_degree:
            adj[u].append(v)
            in_degree[v] += 1

    queue = [n for n in range(task_count) if in_degree[n] == 0]
    order: list[int] = []

    while queue:
        queue.sort()  # deterministic
        node = queue.pop(0)
        order.append(node)
        for neighbor in adj.get(node, []):
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    # Handle cycles: add remaining nodes in original order
    if len(order) < task_count:
        remaining = [i for i in range(task_count) if i not in order]
        order.extend(remaining)

    return order


# =============================================================================
# Secondary sort
# =============================================================================


def _module_key(files: list[str]) -> str:
    """Extract primary module from file paths (first 2 path components)."""
    if not files:
        return "zzz_unknown"
    parts = files[0].replace("\\", "/").split("/")
    return "/".join(parts[:2]) if len(parts) >= 2 else parts[0]


def _sort_key(task: Task, topo_rank: int) -> tuple[int, str, int, int, int]:
    """Composite sort key: topo_rank, module, phase, size, original index."""
    return (
        topo_rank,
        _module_key(task.files),
        phase_rank(task.text),
        task.size,
        task.idx,
    )


# =============================================================================
# Validation
# =============================================================================


def _validate_equivalence(before_raw: frozenset[str], after: list[Task]) -> bool:
    """Verify task set is unchanged after reordering (Bazel-inspired).

    TAP-628: the previous implementation compared `sorted(t.text for t in
    before)` against `sorted(t.text for t in after)` where `after` was a
    permutation of the *same* Task objects — so the two sides were always
    identical and the guard could never trip. Snapshot raw_line from the
    pre-transform input as a frozenset so any dedup / filter / rename in the
    sort pipeline is caught.
    """
    if len(before_raw) != len(after):
        return False
    return before_raw == frozenset(t.raw_line for t in after)


# =============================================================================
# Public API
# =============================================================================


def optimize_plan(
    fix_plan_path: str | Path,
    project_root: str | Path | None = None,
    import_graph: CachedImportGraph | None = None,
    *,
    dry_run: bool = False,
) -> OptimizeResult:
    """Reorder unchecked tasks in fix_plan.md for optimal execution.

    Args:
        fix_plan_path: Path to fix_plan.md.
        project_root: Project root for import graph building (auto-detected if None).
        import_graph: Pre-built import graph (built automatically if None).
        dry_run: If True, return result without writing changes.

    Returns:
        OptimizeResult with before/after task lists and change summary.
    """
    fix_plan = Path(fix_plan_path)
    if not fix_plan.exists():
        return OptimizeResult(changed=False, reason="fix_plan.md not found")

    # Parse tasks
    tasks = parse_tasks(fix_plan)
    unchecked = [t for t in tasks if not t.checked]

    if len(unchecked) <= 1:
        return OptimizeResult(changed=False, reason="0-1 unchecked tasks, nothing to optimize")

    # Build import graph if not provided
    if import_graph is None and project_root is not None:
        import_graph = CachedImportGraph(project_root)

    # Build dependency edges and sort
    edges = _build_dependency_edges(tasks, import_graph)
    topo_order = _topological_sort(len(unchecked), edges)

    # Map topo_order back to task indices and apply secondary sort
    topo_rank_map = {unchecked[pos].idx: rank for rank, pos in enumerate(topo_order) if pos < len(unchecked)}

    # Snapshot invariant *before* any transformation (TAP-628)
    unchecked_raw = frozenset(t.raw_line for t in unchecked)

    reordered = sorted(
        unchecked,
        key=lambda t: _sort_key(t, topo_rank_map.get(t.idx, t.idx)),
    )

    # Validate semantic equivalence
    if not _validate_equivalence(unchecked_raw, reordered):
        return OptimizeResult(changed=False, reason="ABORT: task content changed during reorder")

    # Check if order actually changed
    if [t.idx for t in unchecked] == [t.idx for t in reordered]:
        return OptimizeResult(changed=False, reason="order unchanged after optimization")

    result = OptimizeResult(
        changed=True,
        reason=f"reordered {len(unchecked)} tasks ({len(edges)} dependency edges)",
        before=[t.text for t in unchecked],
        after=[t.text for t in reordered],
        dependency_count=len(edges),
    )

    if dry_run:
        return result

    # Write optimized plan
    _write_optimized(fix_plan, tasks, reordered)
    return result


def _write_optimized(fix_plan: Path, all_tasks: list[Task], reordered_unchecked: list[Task]) -> None:
    """Atomic write: backup + rebuild fix_plan.md with reordered tasks."""
    backup = fix_plan.with_suffix(".md.pre-optimize.bak")
    shutil.copy2(fix_plan, backup)

    lines = fix_plan.read_text().splitlines()
    _unchecked_lines = {t.line_num for t in reordered_unchecked}  # diagnostic / future use
    _checked_tasks = [t for t in all_tasks if t.checked]  # diagnostic / future use

    # Build section → ordered unchecked task lines
    section_order: dict[str, list[str]] = {}
    for t in reordered_unchecked:
        section_order.setdefault(t.section, []).append(t.raw_line)

    # Rebuild file: preserve headers, checked tasks, comments, blank lines
    # Replace unchecked tasks per section in new order
    output: list[str] = []
    current_section = ""
    section_inserted: set[str] = set()
    _skip_unchecked = False  # state placeholder for future per-section gating

    for _i, line in enumerate(lines, 1):
        sec_match = _SECTION.match(line)
        if sec_match:
            current_section = sec_match.group(0)
            output.append(line)
            continue

        cb_match = _CHECKBOX.match(line)
        if cb_match:
            checked = cb_match.group(1).lower() == "x"
            if checked:
                output.append(line)
            elif current_section not in section_inserted:
                # Insert all reordered unchecked tasks for this section
                for task_line in section_order.get(current_section, []):
                    output.append(task_line)
                section_inserted.add(current_section)
                # Skip the original unchecked line (replaced above)
            # else: skip remaining original unchecked lines
        else:
            output.append(line)

    tmp = fix_plan.with_suffix(".md.optimized.tmp")
    tmp.write_text("\n".join(output) + "\n")
    tmp.replace(fix_plan)


@dataclass
class OptimizeResult:
    """Result of plan optimization."""

    changed: bool = False
    reason: str = ""
    before: list[str] = field(default_factory=list)
    after: list[str] = field(default_factory=list)
    dependency_count: int = 0
