"""Version manifest reader for Ralph components.

Reads version.json (generated at build time by generate_version_manifest.sh)
to provide a single source of truth for all component versions at runtime.
"""

from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel

# Well-known locations for version.json, searched in order
_MANIFEST_SEARCH_PATHS = [
    Path("/workspace/version.json"),       # Docker container
    Path(__file__).resolve().parent.parent.parent / "version.json",  # SDK dev (repo root)
]


class VersionManifest(BaseModel):
    """All Ralph component versions from a single build."""

    ralph_loop: str = "unknown"
    ralph_sdk: str = "unknown"
    ralph_cli: str = "unknown"
    git_sha: str = "unknown"
    build_time: str = "unknown"


def get_versions(manifest_path: str | None = None) -> VersionManifest:
    """Load the version manifest from disk.

    Args:
        manifest_path: Explicit path to version.json. If None, searches
            well-known locations (Docker /workspace, then repo root).

    Returns:
        VersionManifest with all component versions. Fields default to
        "unknown" if the manifest is missing or a field is absent.
    """
    if manifest_path:
        path = Path(manifest_path)
        if path.is_file():
            return VersionManifest.model_validate_json(path.read_text())
        return VersionManifest()

    for path in _MANIFEST_SEARCH_PATHS:
        if path.is_file():
            return VersionManifest.model_validate_json(path.read_text())

    # Fallback: at least report the SDK version from __init__.py
    from ralph_sdk import __version__

    return VersionManifest(ralph_sdk=__version__)
