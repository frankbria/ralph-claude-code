"""Tests for Ralph SDK configuration loading (Pydantic v2 model)."""

import json

import pytest
from pydantic import ValidationError

from ralph_sdk.config import RalphConfig


@pytest.fixture
def tmp_project(tmp_path):
    """Create a temporary project directory."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    return tmp_path


def test_default_config():
    """Default config has sane values."""
    config = RalphConfig()
    assert config.max_calls_per_hour == 200
    assert config.timeout_minutes == 15
    assert config.output_format == "json"
    assert config.session_continuity is True
    assert config.cb_cooldown_minutes == 30
    assert config.dry_run is False
    assert config.agent_name == "ralph"


def test_load_ralphrc(tmp_project):
    """Config loads from .ralphrc file."""
    ralphrc = tmp_project / ".ralphrc"
    ralphrc.write_text(
        'PROJECT_NAME="test-project"\n'
        'PROJECT_TYPE="typescript"\n'
        'MAX_CALLS_PER_HOUR=50\n'
        'CB_COOLDOWN_MINUTES=15\n'
        'DRY_RUN=true\n'
    )
    config = RalphConfig.load(tmp_project)
    assert config.project_name == "test-project"
    assert config.project_type == "typescript"
    assert config.max_calls_per_hour == 50
    assert config.cb_cooldown_minutes == 15
    assert config.dry_run is True


def test_load_json_config(tmp_project):
    """Config loads from ralph.config.json."""
    json_config = tmp_project / "ralph.config.json"
    json_config.write_text(json.dumps({
        "projectName": "json-project",
        "maxCallsPerHour": 75,
        "dryRun": True,
        "model": "claude-opus-4-20250514",
    }))
    config = RalphConfig.load(tmp_project)
    assert config.project_name == "json-project"
    assert config.max_calls_per_hour == 75
    assert config.dry_run is True
    assert config.model == "claude-opus-4-20250514"


def test_json_overrides_ralphrc(tmp_project):
    """JSON config takes precedence over .ralphrc."""
    ralphrc = tmp_project / ".ralphrc"
    ralphrc.write_text('MAX_CALLS_PER_HOUR=50\n')

    json_config = tmp_project / "ralph.config.json"
    json_config.write_text(json.dumps({"maxCallsPerHour": 75}))

    config = RalphConfig.load(tmp_project)
    assert config.max_calls_per_hour == 75


def test_env_overrides_all(tmp_project, monkeypatch):
    """Environment variables override both .ralphrc and JSON config."""
    ralphrc = tmp_project / ".ralphrc"
    ralphrc.write_text('MAX_CALLS_PER_HOUR=50\n')

    json_config = tmp_project / "ralph.config.json"
    json_config.write_text(json.dumps({"maxCallsPerHour": 75}))

    monkeypatch.setenv("MAX_CALLS_PER_HOUR", "200")
    config = RalphConfig.load(tmp_project)
    assert config.max_calls_per_hour == 200


def test_to_dict():
    """Config exports as dictionary."""
    config = RalphConfig(project_name="test", max_calls_per_hour=42)
    d = config.to_dict()
    assert d["projectName"] == "test"
    assert d["maxCallsPerHour"] == 42


def test_to_json():
    """Config exports as JSON string."""
    config = RalphConfig(project_name="test")
    j = config.to_json()
    data = json.loads(j)
    assert data["projectName"] == "test"


def test_allowed_tools_from_ralphrc(tmp_project):
    """Allowed tools parsed from comma-separated .ralphrc value."""
    ralphrc = tmp_project / ".ralphrc"
    ralphrc.write_text('ALLOWED_TOOLS="Write,Read,Edit"\n')
    config = RalphConfig.load(tmp_project)
    assert config.allowed_tools == ["Write", "Read", "Edit"]


def test_missing_config_files(tmp_project):
    """Config loads with defaults when no config files exist."""
    config = RalphConfig.load(tmp_project)
    assert config.project_name == "my-project"
    assert config.max_calls_per_hour == 200


def test_validation_ranges():
    """Pydantic validation rejects out-of-range values."""
    with pytest.raises(ValidationError):
        RalphConfig(max_calls_per_hour=0)
    with pytest.raises(ValidationError):
        RalphConfig(timeout_minutes=-1)
    with pytest.raises(ValidationError):
        RalphConfig(max_turns=0)
    with pytest.raises(ValidationError):
        RalphConfig(max_turns=201)


def test_model_json_schema():
    """Pydantic model_json_schema() works."""
    schema = RalphConfig.model_json_schema()
    assert "properties" in schema
    assert "max_calls_per_hour" in schema["properties"]
