"""SDK plan_optimizer tests."""



from ralph_sdk.plan_optimizer import Task, _validate_equivalence


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
