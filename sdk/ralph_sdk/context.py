"""Ralph SDK Context Management — progressive loading and prompt cache optimization.

SDK-CONTEXT-1: Progressive Context Loading — trims fix_plan.md to current epic section.
SDK-CONTEXT-2: Prompt Cache Optimization — splits prompts into stable/dynamic parts.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any

from pydantic import BaseModel, Field

# =============================================================================
# SDK-CONTEXT-1: Progressive Context Loading
# =============================================================================


class ContextManager:
    """Manages progressive loading of fix_plan.md content.

    Trims fix_plan content to include only the current epic section (## heading)
    plus the next N unchecked items, summarizing completed sections to reduce
    token usage.
    """

    def __init__(self, max_unchecked_items: int = 5) -> None:
        self.max_unchecked_items = max_unchecked_items

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    @staticmethod
    def estimate_tokens(text: str) -> int:
        """Estimate token count using the 4-char heuristic.

        Convenience method — delegates to the module-level
        :func:`estimate_tokens` so callers can use either form.
        """
        return estimate_tokens(text)

    # ------------------------------------------------------------------
    # trim_fix_plan — SDK-parity signature (Issue #226)
    # ------------------------------------------------------------------

    def trim_fix_plan(
        self,
        plan_content: str,
        current_section: str | None = None,
        max_items: int = 10,
    ) -> str:
        """Trim fix_plan.md to the active section with progressive summarization.

        Identifies the current epic section, includes only the current + next
        N unchecked items, and summarizes completed sections as
        "N/M tasks complete".

        Matches ``ralph_build_progressive_context()`` from
        ``lib/context_management.sh`` (CTXMGMT-1).

        Args:
            plan_content: Full fix_plan.md content.
            current_section: Optional section heading text (without ``##``)
                to force as the active section.  When *None*, the first
                section containing unchecked items is used.
            max_items: Maximum number of unchecked items to include
                from the active section (default 10, matching
                ``RALPH_MAX_PLAN_ITEMS``).

        Returns:
            Trimmed content with completed sections summarized.
        """
        if not plan_content or not plan_content.strip():
            return plan_content

        effective_max = max_items if max_items > 0 else self.max_unchecked_items

        return self._trim_sections(plan_content, current_section, effective_max)

    # ------------------------------------------------------------------
    # Internal implementation
    # ------------------------------------------------------------------

    @staticmethod
    def _parse_sections(
        content: str,
        section_marker: str = "##",
    ) -> tuple[list[str], list[tuple[str, list[str]]]]:
        """Parse markdown content into preamble and sections.

        Returns:
            (preamble_lines, sections) where each section is
            ``(heading_line, body_lines)``.
        """
        lines = content.splitlines()

        sections: list[tuple[str, list[str]]] = []
        current_heading = ""
        current_body: list[str] = []
        preamble_lines: list[str] = []

        for line in lines:
            if line.strip().startswith(section_marker) and not line.strip().startswith(
                section_marker + "#"
            ):
                # TAP-674: content before the first ##-heading is the
                # preamble, not an anonymous section. The previous branch
                # structure was unreachable (same predicate on both arms)
                # and silently folded preamble into a blank-heading section
                # which was then dropped downstream.
                if current_heading:
                    sections.append((current_heading, current_body))
                elif current_body:
                    preamble_lines = current_body
                current_heading = line
                current_body = []
            else:
                current_body.append(line)

        if current_heading:
            sections.append((current_heading, current_body))
        elif current_body and not preamble_lines:
            # Document has no ##-headings at all — treat entire doc as preamble
            preamble_lines = current_body

        return preamble_lines, sections

    def _trim_sections(
        self,
        content: str,
        current_section: str | None,
        max_items: int,
    ) -> str:
        """Core trimming logic shared by all calling paths."""
        preamble_lines, sections = self._parse_sections(content)
        if not sections:
            return content

        active_idx = _locate_active_section(sections, current_section)

        if active_idx == -1:
            return _format_all_complete_summary(preamble_lines, sections)
        return _format_active_section(preamble_lines, sections, active_idx, max_items)


# ---- Module-level helpers extracted from _trim_sections ----------------------

_UNCHECKED = re.compile(r"\s*- \[ \]")
_CHECKED = re.compile(r"\s*- \[x\]", re.IGNORECASE)
_CHECKBOX = re.compile(r"\s*- \[[xX ]\]")


def _normalize_heading(text: str) -> str:
    return text.strip().lstrip("#").strip().lower()


def _section_has_unchecked(body: list[str]) -> bool:
    return any(_UNCHECKED.match(line) for line in body)


def _count_section(body: list[str]) -> tuple[int, int]:
    """Return (total_items, checked_items) for a section body."""
    total = checked = 0
    for line in body:
        if _CHECKED.match(line):
            total += 1
            checked += 1
        elif _UNCHECKED.match(line):
            total += 1
    return total, checked


def _locate_active_section(
    sections: list[tuple[str, list[str]]],
    current_section: str | None,
) -> int:
    """Return the index of the active section, or -1 if all are complete."""
    if current_section is not None:
        needle = _normalize_heading(current_section)
        for i, (heading, _body) in enumerate(sections):
            if _normalize_heading(heading) == needle:
                return i
    for i, (_heading, body) in enumerate(sections):
        if _section_has_unchecked(body):
            return i
    return -1


def _format_all_complete_summary(
    preamble_lines: list[str],
    sections: list[tuple[str, list[str]]],
) -> str:
    """Render the section shape when every task is complete (TAP-674)."""
    total_items = total_checked = 0
    section_summaries: list[str] = []
    for heading, body in sections:
        section_total, section_checked = _count_section(body)
        total_items += section_total
        total_checked += section_checked
        if section_total > 0:
            section_summaries.append(
                f"{heading.rstrip()}  ({section_checked}/{section_total} done)"
            )
        elif heading.strip():
            section_summaries.append(heading.rstrip())

    parts: list[str] = []
    if preamble_lines:
        parts.extend(preamble_lines)
        parts.append("")
    if section_summaries:
        parts.extend(section_summaries)
        parts.append("")
    if total_items > 0:
        parts.append(
            f"({total_checked}/{total_items} tasks complete — all tasks done)"
        )
    return "\n".join(parts).rstrip()


def _summarize_completed_section(heading: str, body: list[str]) -> str | None:
    """Render a one-line summary for a section above the active one."""
    total = sum(1 for line in body if _CHECKBOX.match(line))
    checked = sum(1 for line in body if _CHECKED.match(line))
    if total == 0:
        return None
    return f"{heading.rstrip()}  ({checked}/{total} tasks complete)"


def _emit_active_body(
    body: list[str], max_items: int, parts: list[str]
) -> int:
    """Emit lines from the active section body. Returns remaining_unchecked count."""
    checked = total = unchecked_count = remaining = 0
    for line in body:
        if _CHECKED.match(line):
            checked += 1
            total += 1
            continue
        if _UNCHECKED.match(line):
            total += 1
            if unchecked_count < max_items:
                if checked > 0 and unchecked_count == 0:
                    parts.append(
                        f"  ({checked}/{total} tasks complete in this section)"
                    )
                parts.append(line)
                unchecked_count += 1
            else:
                remaining += 1
            continue
        # Non-checkbox lines: include while inside the unchecked window
        if 0 < unchecked_count <= max_items:
            parts.append(line)
        elif unchecked_count == 0 and not _CHECKED.match(line):
            parts.append(line)

    if checked > 0 and unchecked_count == 0:
        parts.append(f"  ({checked}/{total} tasks complete in this section)")
    return remaining


def _format_active_section(
    preamble_lines: list[str],
    sections: list[tuple[str, list[str]]],
    active_idx: int,
    max_items: int,
) -> str:
    parts: list[str] = []
    if preamble_lines:
        parts.extend(preamble_lines)
        parts.append("")

    for heading, body in sections[:active_idx]:
        summary = _summarize_completed_section(heading, body)
        if summary:
            parts.append(summary)
    if active_idx > 0:
        parts.append("")

    active_heading, active_body = sections[active_idx]
    parts.append(active_heading)

    remaining = _emit_active_body(active_body, max_items, parts)
    if remaining > 0:
        parts.append(f"  ... and {remaining} more unchecked items")

    sections_below = len(sections) - active_idx - 1
    if sections_below > 0:
        total_below = sum(
            1
            for _heading, body in sections[active_idx + 1:]
            for line in body
            if _UNCHECKED.match(line)
        )
        if total_below > 0:
            parts.append("")
            parts.append(
                f"({sections_below} more sections below with {total_below} unchecked items)"
            )

    return "\n".join(parts)


def estimate_tokens(text: str) -> int:
    """Estimate token count using the 4-char heuristic (~250 tokens per 1K chars).

    This is a fast approximation. Actual tokenization varies by model,
    but 4 chars/token is a reasonable average for English text + code.

    Args:
        text: Input text to estimate tokens for.

    Returns:
        Estimated token count.
    """
    if not text:
        return 0
    return max(1, len(text) // 4)


# =============================================================================
# SDK-CONTEXT-2: Prompt Cache Optimization
# =============================================================================


class PromptParts(BaseModel):
    """Split prompt into stable prefix (cacheable) and dynamic suffix.

    The stable_prefix contains identity, build instructions, and tool permissions
    that rarely change between iterations. The dynamic_suffix contains loop count,
    progress updates, and current task details that change every iteration.

    Splitting allows API-level prompt caching to reuse the prefix across calls.
    """

    stable_prefix: str = Field(
        default="",
        description="Stable content: identity, build instructions, tool permissions",
    )
    dynamic_suffix: str = Field(
        default="",
        description="Dynamic content: loop count, progress, current task",
    )
    prefix_hash: str = Field(
        default="",
        description="SHA-256 hash of stable_prefix for cache validation",
    )

    def full_prompt(self) -> str:
        """Reconstruct the full prompt from parts."""
        if self.stable_prefix and self.dynamic_suffix:
            return f"{self.stable_prefix}\n\n{self.dynamic_suffix}"
        return self.stable_prefix or self.dynamic_suffix


class PromptCacheStats(BaseModel):
    """Tracks prompt cache hit/miss statistics."""

    cache_hits: int = 0
    cache_misses: int = 0
    last_prefix_hash: str = ""

    @property
    def hit_rate(self) -> float:
        """Cache hit rate as a fraction (0.0 to 1.0)."""
        total = self.cache_hits + self.cache_misses
        if total == 0:
            return 0.0
        return self.cache_hits / total

    def record(self, prefix_hash: str) -> bool:
        """Record a cache lookup and return whether it was a hit.

        Args:
            prefix_hash: Hash of the current stable prefix.

        Returns:
            True if this was a cache hit (prefix unchanged), False otherwise.
        """
        if prefix_hash == self.last_prefix_hash and self.last_prefix_hash:
            self.cache_hits += 1
            return True
        else:
            self.cache_misses += 1
            self.last_prefix_hash = prefix_hash
            return False


def _compute_prefix_hash(text: str) -> str:
    """Compute SHA-256 hash of text for cache validation."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def split_prompt(full_prompt: str, loop_context: dict[str, Any] | None = None) -> PromptParts:
    """Split a full prompt into stable prefix and dynamic suffix.

    The split point is determined by looking for dynamic markers in the prompt:
    - "## Current Fix Plan" — the fix plan section is dynamic
    - "## Loop Context" or "Loop:" — iteration-specific context
    - "## Progress" — progress updates

    Everything before the first dynamic marker is the stable prefix.
    Everything from the first dynamic marker onward is the dynamic suffix.

    If loop_context is provided, it is appended to the dynamic suffix.

    Args:
        full_prompt: The complete prompt text.
        loop_context: Optional dict with loop-specific context
            (loop_count, progress_summary, etc.).

    Returns:
        PromptParts with stable_prefix, dynamic_suffix, and prefix_hash.
    """
    if not full_prompt:
        return PromptParts()

    # Dynamic section markers (order matters — first match wins)
    dynamic_markers = [
        "\n## Current Fix Plan",
        "\n## Loop Context",
        "\n## Progress",
        "\nLoop:",
        "\nIteration:",
    ]

    split_idx = len(full_prompt)
    for marker in dynamic_markers:
        idx = full_prompt.find(marker)
        if idx != -1 and idx < split_idx:
            split_idx = idx

    stable_prefix = full_prompt[:split_idx].rstrip()
    dynamic_suffix = full_prompt[split_idx:].lstrip("\n")

    # Append loop context if provided
    if loop_context:
        context_lines = ["\n## Loop Context"]
        for key, value in loop_context.items():
            context_lines.append(f"- {key}: {value}")
        dynamic_suffix += "\n".join(context_lines)

    prefix_hash = _compute_prefix_hash(stable_prefix) if stable_prefix else ""

    return PromptParts(
        stable_prefix=stable_prefix,
        dynamic_suffix=dynamic_suffix,
        prefix_hash=prefix_hash,
    )
