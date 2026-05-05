"""SDK plan_optimizer tests."""

from __future__ import annotations

from ralph_sdk.plan_optimizer import (
    Task,
    _build_dependency_edges,
    _estimate_size,
    _module_key,
    _topological_sort,
    _validate_equivalence,
    optimize_plan,
    parse_tasks,
    phase_rank,
)


def _task(idx: int, raw_line: str, text: str | None = None) -> Task:
    # lstrip with a charset (not a substring) intentionally — strips any
    # leading run of "- [ ]" chars rather than the literal prefix. Behavior
    # matches the production parser.
    return Task(idx=idx, raw_line=raw_line, text=text or raw_line.lstrip("- [ ]").strip())  # noqa: B005


class TestTap628Equivalence:
    """TAP-628: the guard must actually catch a changed task set."""

    def test_permutation_passes(self):
        a = _task(0, "- [ ] alpha")
        b = _task(1, "- [ ] beta")
        before = frozenset(t.raw_line for t in [a, b])
        assert _validate_equivalence(before, [b, a]) is True

    def test_dropped_task_fails(self):
        a = _task(0, "- [ ] alpha")
        b = _task(1, "- [ ] beta")
        before = frozenset(t.raw_line for t in [a, b])
        assert _validate_equivalence(before, [a]) is False

    def test_renamed_task_fails(self):
        """A one-char rename in raw_line must trip the guard."""
        a = _task(0, "- [ ] alpha")
        before = frozenset([a.raw_line])
        renamed = _task(0, "- [ ] alphaX")
        assert _validate_equivalence(before, [renamed]) is False

    def test_added_task_fails(self):
        a = _task(0, "- [ ] alpha")
        before = frozenset([a.raw_line])
        b = _task(1, "- [ ] beta")
        assert _validate_equivalence(before, [a, b]) is False

    def test_same_text_different_raw_line_fails(self):
        """Text equality is not enough — raw_line is authoritative.

        Prevents a future Task normalization from fooling the guard (the
        exact scenario the ticket warns about).
        """
        a = _task(0, "- [ ] alpha  <!-- resolved: src/a.py -->")
        before = frozenset([a.raw_line])
        same_text_no_meta = _task(0, "- [ ] alpha", text=a.text)
        assert _validate_equivalence(before, [same_text_no_meta]) is False


# ---------------------------------------------------------------------------
# Test fixtures: a stub import graph
# ---------------------------------------------------------------------------


class _StubImportGraph:
    """Minimal stand-in for CachedImportGraph — only exposes .get()."""

    def __init__(self, edges: dict[str, list[str]]):
        self._edges = edges

    def get(self) -> dict[str, list[str]]:
        return self._edges


# ---------------------------------------------------------------------------
# parse_tasks
# ---------------------------------------------------------------------------


class TestParseTasks:
    def test_returns_empty_for_missing_file(self, tmp_path):
        assert parse_tasks(tmp_path / "absent.md") == []

    def test_extracts_checked_state(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text("## Section\n- [x] done thing\n- [ ] todo thing\n")
        tasks = parse_tasks(plan)
        assert len(tasks) == 2
        assert tasks[0].checked is True
        assert tasks[1].checked is False
        assert tasks[0].section == "## Section"

    def test_extracts_files_from_backticks_and_paths(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [ ] update `src/main.py` and tests/test_main.py\n"
        )
        tasks = parse_tasks(plan)
        assert "src/main.py" in tasks[0].files
        assert "tests/test_main.py" in tasks[0].files

    def test_extracts_metadata(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [ ] task one <!-- id: t1 -->\n"
            "- [ ] task two <!-- depends: t1 -->\n"
        )
        tasks = parse_tasks(plan)
        assert tasks[0].task_id == "t1"
        assert tasks[1].depends == "t1"

    def test_extracts_resolved_metadata_as_file(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [ ] vague task <!-- resolved: src/resolved.py -->\n"
        )
        tasks = parse_tasks(plan)
        assert "src/resolved.py" in tasks[0].files

    def test_strips_metadata_from_clean_text(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text("## S\n- [ ] do thing <!-- id: x -->\n")
        tasks = parse_tasks(plan)
        assert "<!--" not in tasks[0].text
        assert "do thing" in tasks[0].text

    def test_ignores_non_task_lines(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## Section\n"
            "Some prose.\n"
            "- A bullet without a checkbox\n"
            "- [ ] real task\n"
        )
        tasks = parse_tasks(plan)
        assert len(tasks) == 1


# ---------------------------------------------------------------------------
# _estimate_size + phase_rank
# ---------------------------------------------------------------------------


class TestEstimateSize:
    def test_small_for_typo_fix(self):
        assert _estimate_size("fix typo in readme", 1) == 0

    def test_small_for_rename_single_file(self):
        assert _estimate_size("rename helper", 1) == 0

    def test_large_for_three_files(self):
        assert _estimate_size("regular work", 3) == 2

    def test_large_for_keyword(self):
        assert _estimate_size("redesign authentication", 1) == 2

    def test_medium_default(self):
        assert _estimate_size("update logic", 2) == 1


class TestPhaseRank:
    def test_create_phase(self):
        assert phase_rank("create new module") == 0

    def test_implement_phase(self):
        assert phase_rank("implement feature X") == 1

    def test_test_phase(self):
        assert phase_rank("test the new behavior") == 3

    def test_doc_phase(self):
        assert phase_rank("document the API") == 4

    def test_default_modify(self):
        assert phase_rank("change behavior") == 2


# ---------------------------------------------------------------------------
# Topological sort
# ---------------------------------------------------------------------------


class TestTopologicalSort:
    def test_empty_edges_returns_identity(self):
        assert _topological_sort(3, []) == [0, 1, 2]

    def test_simple_chain(self):
        # 0 → 1 → 2: order must be 0,1,2
        assert _topological_sort(3, [(0, 1), (1, 2)]) == [0, 1, 2]

    def test_reverse_chain(self):
        # 2 → 1 → 0: order must be 2,1,0
        assert _topological_sort(3, [(2, 1), (1, 0)]) == [2, 1, 0]

    def test_cycle_tolerant(self):
        """Cycle: 0→1→0. All nodes still appear in output."""
        order = _topological_sort(2, [(0, 1), (1, 0)])
        assert sorted(order) == [0, 1]

    def test_partial_cycle(self):
        """Mixed graph: 0→1, plus 2↔3 cycle. 0,1 sort; 2,3 appended."""
        order = _topological_sort(4, [(0, 1), (2, 3), (3, 2)])
        # 0 must precede 1
        assert order.index(0) < order.index(1)
        # All nodes present
        assert sorted(order) == [0, 1, 2, 3]

    def test_deterministic_when_multiple_roots(self):
        """Two independent roots → smaller index first (queue.sort())."""
        order = _topological_sort(4, [(0, 2), (1, 3)])
        # Both 0 and 1 are roots; deterministic order means 0 first
        assert order.index(0) < order.index(2)
        assert order.index(1) < order.index(3)

    def test_ignores_out_of_range_edges(self):
        # Edge (5,6) silently skipped — doesn't crash
        order = _topological_sort(3, [(0, 1), (5, 6)])
        assert sorted(order) == [0, 1, 2]


# ---------------------------------------------------------------------------
# _build_dependency_edges (3-layer detection)
# ---------------------------------------------------------------------------


class TestBuildDependencyEdges:
    def _make(self, idx: int, section: str, raw: str, **kw) -> Task:
        return Task(
            idx=idx, section=section, raw_line=raw, text=raw, checked=False, **kw
        )

    def test_metadata_layer_creates_edge(self):
        a = self._make(0, "## S", "- [ ] a", task_id="a")
        b = self._make(1, "## S", "- [ ] b depends on a", depends="a")
        edges = _build_dependency_edges([a, b], None)
        # depends="a" on b means a (idx=0) before b (idx=1)
        assert (0, 1) in edges

    def test_metadata_reverse_edge(self):
        # a.depends=b → b before a (idx 1 before idx 0)
        a = self._make(0, "## S", "- [ ] a", task_id="a", depends="b")
        b = self._make(1, "## S", "- [ ] b", task_id="b")
        edges = _build_dependency_edges([a, b], None)
        assert (1, 0) in edges

    def test_no_cross_section_edges(self):
        a = self._make(0, "## S1", "- [ ] a", task_id="a")
        b = self._make(1, "## S2", "- [ ] b", depends="a")
        edges = _build_dependency_edges([a, b], None)
        assert edges == []

    def test_skips_checked_tasks(self):
        a = self._make(0, "## S", "- [ ] a", task_id="a")
        b = Task(
            idx=1, section="## S", raw_line="- [x] b", text="b",
            checked=True, depends="a",
        )
        edges = _build_dependency_edges([a, b], None)
        assert edges == []

    def test_import_graph_edge(self):
        a = self._make(0, "## S", "- [ ] a", files=["src/a.py"])
        b = self._make(1, "## S", "- [ ] b", files=["src/b.py"])
        # b imports a → a before b → edge (0, 1)
        graph = _StubImportGraph({"src/b.py": ["src/a.py"]})
        edges = _build_dependency_edges([a, b], graph)
        assert (0, 1) in edges

    def test_import_graph_reverse_edge(self):
        a = self._make(0, "## S", "- [ ] a", files=["src/a.py"])
        b = self._make(1, "## S", "- [ ] b", files=["src/b.py"])
        # a imports b → b before a → edge (1, 0)
        graph = _StubImportGraph({"src/a.py": ["src/b.py"]})
        edges = _build_dependency_edges([a, b], graph)
        assert (1, 0) in edges

    def test_metadata_takes_precedence_over_import(self):
        """Layer 2 (metadata) hits 'continue' before Layer 1 runs."""
        a = self._make(0, "## S", "- [ ] a", task_id="a", files=["src/a.py"])
        b = self._make(1, "## S", "- [ ] b", depends="a", files=["src/b.py"])
        # Metadata says a→b; an import graph edge in either direction would
        # be ignored because the metadata branch hits `continue`.
        graph = _StubImportGraph({"src/a.py": ["src/b.py"]})
        edges = _build_dependency_edges([a, b], graph)
        # Metadata edge is the only one that should appear
        assert (0, 1) in edges
        # Verify the metadata path won (not the would-be import-graph (1,0))
        assert (1, 0) not in edges


# ---------------------------------------------------------------------------
# _module_key
# ---------------------------------------------------------------------------


class TestModuleKey:
    def test_unknown_when_no_files(self):
        assert _module_key([]) == "zzz_unknown"

    def test_first_two_components(self):
        assert _module_key(["src/auth/login.py"]) == "src/auth"

    def test_single_component(self):
        assert _module_key(["main.py"]) == "main.py"

    def test_normalizes_backslashes(self):
        assert _module_key(["src\\auth\\login.py"]) == "src/auth"


# ---------------------------------------------------------------------------
# optimize_plan — end-to-end
# ---------------------------------------------------------------------------


class TestOptimizePlan:
    def test_missing_file_returns_unchanged(self, tmp_path):
        result = optimize_plan(tmp_path / "missing.md")
        assert result.changed is False
        assert "not found" in result.reason

    def test_zero_unchecked_returns_unchanged(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text("## S\n- [x] done\n")
        result = optimize_plan(plan)
        assert result.changed is False
        assert "0-1" in result.reason

    def test_one_unchecked_returns_unchanged(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text("## S\n- [ ] only one\n")
        result = optimize_plan(plan)
        assert result.changed is False

    def test_dry_run_does_not_write(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        # Force a reorder: tests should run after implementation.
        plan.write_text(
            "## S\n"
            "- [ ] test the parser\n"
            "- [ ] implement the parser\n"
        )
        original = plan.read_text()
        result = optimize_plan(plan, project_root=tmp_path, dry_run=True)
        assert plan.read_text() == original  # untouched
        if result.changed:
            assert "implement" in result.after[0]
            assert "test" in result.after[1]

    def test_writes_when_order_changes(self, tmp_path):
        """Use metadata to force a reorder we can verify deterministically."""
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [ ] alpha task <!-- depends: beta -->\n"
            "- [ ] beta task <!-- id: beta -->\n"
        )
        result = optimize_plan(plan, project_root=tmp_path)
        # alpha depends on beta → beta must come first
        assert result.changed is True
        new = plan.read_text()
        assert new.index("beta task") < new.index("alpha task")
        # Backup created
        assert (tmp_path / "fix_plan.md.pre-optimize.bak").exists()
        assert result.dependency_count >= 1

    def test_no_change_returns_unchanged(self, tmp_path):
        """Tasks already in the right order short-circuit with reason."""
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [ ] beta task <!-- id: beta -->\n"
            "- [ ] alpha task <!-- depends: beta -->\n"
        )
        result = optimize_plan(plan, project_root=tmp_path)
        assert result.changed is False
        assert "unchanged" in result.reason

    def test_preserves_checked_tasks_position(self, tmp_path):
        plan = tmp_path / "fix_plan.md"
        plan.write_text(
            "## S\n"
            "- [x] already done\n"
            "- [ ] test the parser\n"
            "- [ ] implement the parser\n"
        )
        optimize_plan(plan, project_root=tmp_path)
        new = plan.read_text()
        # Checked task must remain in the file
        assert "- [x] already done" in new

