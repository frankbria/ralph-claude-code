"""Tests for TAP-674: ContextManager.trim_fix_plan preserves preamble and
section headings when the plan is fully checked, instead of collapsing to
a one-line summary."""

from ralph_sdk.context import ContextManager


def test_all_checked_preserves_preamble_and_sections():
    plan = """# Project fix plan

This is the preamble. It contains critical project context that must
survive trimming so end-of-campaign reasoning still has something to
reference.

## Phase 1 — Foundations
- [x] Set up repo
- [x] Add CI

## Phase 2 — Feature work
- [x] Implement login
- [x] Implement logout
- [x] Write tests
"""
    cm = ContextManager()
    trimmed = cm.trim_fix_plan(plan)

    # Preamble must survive
    assert "This is the preamble" in trimmed  # nosec B101  # pytest assertion
    assert "end-of-campaign reasoning" in trimmed  # nosec B101  # pytest assertion

    # Section headings must survive
    assert "Phase 1 — Foundations" in trimmed  # nosec B101  # pytest assertion
    assert "Phase 2 — Feature work" in trimmed  # nosec B101  # pytest assertion

    # Per-section completion counts must be present
    assert "(2/2 done)" in trimmed  # nosec B101  # pytest assertion
    assert "(3/3 done)" in trimmed  # nosec B101  # pytest assertion

    # Overall summary line still present
    assert "5/5 tasks complete" in trimmed  # nosec B101  # pytest assertion


def test_all_checked_empty_sections_header_only():
    plan = """# Campaign done
## Final phase
## Wrap-up
"""
    cm = ContextManager()
    trimmed = cm.trim_fix_plan(plan)

    # Preamble
    assert "Campaign done" in trimmed  # nosec B101  # pytest assertion
    # Headers with no items still appear
    assert "Final phase" in trimmed  # nosec B101  # pytest assertion
    assert "Wrap-up" in trimmed  # nosec B101  # pytest assertion


def test_mixed_checked_unchecked_still_uses_normal_path():
    """When the plan has unchecked items, the all-checked branch should
    NOT trigger — verify trim_fix_plan delegates to its normal flow."""
    plan = """# In-progress plan

## Active work
- [x] Finished item
- [ ] Not done yet

## Later
- [ ] Future task
"""
    cm = ContextManager()
    trimmed = cm.trim_fix_plan(plan)

    # Should not contain the "all tasks done" marker
    assert "all tasks done" not in trimmed  # nosec B101  # pytest assertion


def test_all_checked_without_preamble():
    """No preamble still works — section summaries + overall summary."""
    plan = """## Phase A
- [x] first
- [x] second
"""
    cm = ContextManager()
    trimmed = cm.trim_fix_plan(plan)

    assert "Phase A" in trimmed  # nosec B101  # pytest assertion
    assert "(2/2 done)" in trimmed  # nosec B101  # pytest assertion
    assert "2/2 tasks complete" in trimmed  # nosec B101  # pytest assertion
