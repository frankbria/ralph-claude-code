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

        # No sections found — return as-is
        if not sections:
            return content

        # ----------------------------------------------------------
        # Locate the active section
        # ----------------------------------------------------------
        active_idx = -1

        if current_section is not None:
            # User-specified section — match by heading text (case-insensitive,
            # ignoring leading ``## `` markers).
            needle = current_section.strip().lstrip("#").strip().lower()
            for i, (heading, _body) in enumerate(sections):
                heading_text = heading.strip().lstrip("#").strip().lower()
                if heading_text == needle:
                    active_idx = i
                    break

        # Fallback / default: first section with unchecked items
        if active_idx == -1:
            for i, (_heading, body) in enumerate(sections):
                if any(re.match(r"\s*- \[ \]", line) for line in body):
                    active_idx = i
                    break

        # ----------------------------------------------------------
        # All items complete — summary + section shape (TAP-674).
        # The old behaviour collapsed to a single summary line, which
        # dropped section names and made end-of-campaign reasoning hard
        # for the dual-condition exit gate. Preserve the preamble and
        # emit one line per section so the agent can see what ran.
        # ----------------------------------------------------------
        if active_idx == -1:
            total_items = 0
            total_checked = 0
            section_summaries: list[str] = []
            for heading, body in sections:
                section_total = 0
                section_checked = 0
                for line in body:
                    if re.match(r"\s*- \[x\]", line, re.IGNORECASE):
                        section_total += 1
                        section_checked += 1
                    elif re.match(r"\s*- \[ \]", line):
                        section_total += 1
                total_items += section_total
                total_checked += section_checked
                if section_total > 0:
                    section_summaries.append(
                        f"{heading.rstrip()}  "
                        f"({section_checked}/{section_total} done)"
                    )
                elif heading.strip():
                    # Header with no items — still useful context
                    section_summaries.append(heading.rstrip())

            result_parts: list[str] = []
            if preamble_lines:
                result_parts.extend(preamble_lines)
                result_parts.append("")
            if section_summaries:
                result_parts.extend(section_summaries)
                result_parts.append("")
            if total_items > 0:
                result_parts.append(
                    f"({total_checked}/{total_items} tasks complete — all tasks done)"
                )
            return "\n".join(result_parts).rstrip()

        # ----------------------------------------------------------
        # Build output
        # ----------------------------------------------------------
        result_parts: list[str] = []

        # Preamble
        if preamble_lines:
            result_parts.extend(preamble_lines)
            result_parts.append("")

        # Summarize completed sections above the active one
        for i in range(active_idx):
            heading, body = sections[i]
            total_in_section = sum(
                1 for line in body
                if re.match(r"\s*- \[[xX ]\]", line)
            )
            checked_in_section = sum(
                1 for line in body
                if re.match(r"\s*- \[x\]", line, re.IGNORECASE)
            )
            if total_in_section > 0:
                section_title = heading.strip().lstrip("#").strip()  # noqa: F841 — preserved for future heading rewrite (TAP-542 follow-up)
                result_parts.append(
                    f"{heading.rstrip()}  ({checked_in_section}/{total_in_section} tasks complete)"
                )

        if active_idx > 0:
            result_parts.append("")

        # Active section heading
        active_heading, active_body = sections[active_idx]
        result_parts.append(active_heading)

        # Emit checked items as a summary, then unchecked items up to limit
        checked_in_section = 0
        total_in_section = 0
        unchecked_count = 0
        remaining_unchecked = 0

        for line in active_body:
            if re.match(r"\s*- \[x\]", line, re.IGNORECASE):
                checked_in_section += 1
                total_in_section += 1
            elif re.match(r"\s*- \[ \]", line):
                total_in_section += 1
                if unchecked_count < max_items:
                    if checked_in_section > 0 and unchecked_count == 0:
                        result_parts.append(
                            f"  ({checked_in_section}/{total_in_section} tasks complete in this section)"
                        )
                    result_parts.append(line)
                    unchecked_count += 1
                else:
                    remaining_unchecked += 1
            else:
                # Non-checkbox lines — include while within the unchecked window
                if unchecked_count > 0 and unchecked_count <= max_items:
                    result_parts.append(line)
                elif unchecked_count == 0:
                    if not re.match(r"\s*- \[x\]", line, re.IGNORECASE):
                        result_parts.append(line)

        # If only checked items existed (no unchecked emitted yet), still summarize
        if checked_in_section > 0 and unchecked_count == 0:
            result_parts.append(
                f"  ({checked_in_section}/{total_in_section} tasks complete in this section)"
            )

        if remaining_unchecked > 0:
            result_parts.append(f"  ... and {remaining_unchecked} more unchecked items")

        # Summarize sections below the active one
        sections_below = len(sections) - active_idx - 1
        if sections_below > 0:
            total_below = 0
            for i in range(active_idx + 1, len(sections)):
                _, body = sections[i]
                total_below += sum(
                    1 for line in body if re.match(r"\s*- \[ \]", line)
                )
            if total_below > 0:
                result_parts.append("")
                result_parts.append(
                    f"({sections_below} more sections below with {total_below} unchecked items)"
                )

        return "\n".join(result_parts)


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
