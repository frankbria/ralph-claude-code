"""Tests for Ralph SDK structured response parsing."""

import json

from ralph_sdk.parsing import (
    RalphStatusBlock,
    _parse_json_block,
    _parse_jsonl_result,
    _parse_text_fallback,
    parse_ralph_status,
)
from ralph_sdk.status import RalphLoopStatus, WorkType


class TestRalphStatusBlock:
    def test_defaults(self):
        block = RalphStatusBlock()
        assert block.version == 1
        assert block.work_type == WorkType.UNKNOWN
        assert block.exit_signal is False

    def test_exit_signal_coercion(self):
        """EXIT_SIGNAL coerces true/True/TRUE/yes/1."""
        for truthy in ["true", "True", "TRUE", "yes", "1", True, 1]:
            block = RalphStatusBlock(exit_signal=truthy)
            assert block.exit_signal is True

        for falsy in ["false", "False", "no", "0", False, 0]:
            block = RalphStatusBlock(exit_signal=falsy)
            assert block.exit_signal is False

    def test_to_ralph_status(self):
        block = RalphStatusBlock(
            work_type="IMPLEMENTATION",
            completed_task="Built feature",
            exit_signal=True,
        )
        status = block.to_ralph_status()
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.completed_task == "Built feature"
        assert status.exit_signal is True
        assert status.status == RalphLoopStatus.COMPLETED

    def test_model_json_schema(self):
        schema = RalphStatusBlock.model_json_schema()
        assert "properties" in schema
        assert "version" in schema["properties"]


class TestParseJsonBlock:
    def test_parses_json_fenced_block(self):
        text = '''Some text before

```json
{
  "work_type": "TESTING",
  "completed_task": "Ran tests",
  "exit_signal": false,
  "progress_summary": "50% done"
}
```

Some text after'''
        status = _parse_json_block(text)
        assert status is not None
        assert status.work_type == WorkType.TESTING
        assert status.completed_task == "Ran tests"
        assert status.exit_signal is False

    def test_parses_without_json_lang_tag(self):
        text = '''```
{
  "work_type": "ANALYSIS",
  "completed_task": "Reviewed code",
  "exit_signal": true
}
```'''
        status = _parse_json_block(text)
        assert status is not None
        assert status.work_type == WorkType.ANALYSIS
        assert status.exit_signal is True

    def test_returns_none_for_no_block(self):
        assert _parse_json_block("no json here") is None

    def test_returns_none_for_invalid_json(self):
        text = '```json\n{invalid json}\n```'
        assert _parse_json_block(text) is None

    def test_uppercase_keys(self):
        """Handles UPPERCASE keys from agent output."""
        text = '''```json
{
  "WORK_TYPE": "IMPLEMENTATION",
  "COMPLETED_TASK": "Did stuff",
  "EXIT_SIGNAL": "True"
}
```'''
        status = _parse_json_block(text)
        assert status is not None
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.exit_signal is True


class TestParseJsonlResult:
    def test_parses_jsonl_result(self):
        jsonl = json.dumps({
            "type": "result",
            "result": "WORK_TYPE: IMPLEMENTATION\nCOMPLETED_TASK: Added form\nEXIT_SIGNAL: false",
        })
        status = _parse_jsonl_result(jsonl)
        assert status is not None
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.completed_task == "Added form"
        assert status.exit_signal is False

    def test_prefers_json_block_in_result(self):
        result_text = '''Here's the status:

```json
{"work_type": "TESTING", "exit_signal": true, "completed_task": "All tests pass"}
```'''
        jsonl = json.dumps({"type": "result", "result": result_text})
        status = _parse_jsonl_result(jsonl)
        assert status is not None
        assert status.work_type == WorkType.TESTING
        assert status.exit_signal is True

    def test_returns_none_for_no_result(self):
        assert _parse_jsonl_result("not jsonl") is None


class TestParseTextFallback:
    def test_extracts_fields(self):
        text = "WORK_TYPE: TESTING\nCOMPLETED_TASK: Ran unit tests\nEXIT_SIGNAL: true\n"
        status = _parse_text_fallback(text)
        assert status.work_type == WorkType.TESTING
        assert status.completed_task == "Ran unit tests"
        assert status.exit_signal is True

    def test_handles_escaped_newlines(self):
        text = "WORK_TYPE: IMPLEMENTATION\\nCOMPLETED_TASK: Built feature\\nEXIT_SIGNAL: false"
        status = _parse_text_fallback(text)
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.completed_task == "Built feature"

    def test_handles_missing_fields(self):
        status = _parse_text_fallback("just some output without status fields")
        assert status.work_type == WorkType.UNKNOWN
        assert status.exit_signal is False

    def test_case_insensitive(self):
        text = "work_type: DEBUGGING\nexit_signal: YES\n"
        status = _parse_text_fallback(text)
        assert status.work_type == WorkType.DEBUGGING
        assert status.exit_signal is True


class TestParseRalphStatus:
    def test_json_block_takes_priority(self):
        """JSON block strategy is tried first."""
        text = '''WORK_TYPE: TESTING

```json
{"work_type": "IMPLEMENTATION", "completed_task": "JSON wins", "exit_signal": false}
```'''
        status = parse_ralph_status(text)
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.completed_task == "JSON wins"

    def test_jsonl_fallback(self):
        jsonl = json.dumps({
            "type": "result",
            "result": "WORK_TYPE: DEBUGGING\nEXIT_SIGNAL: false",
        })
        status = parse_ralph_status(jsonl)
        assert status.work_type == WorkType.DEBUGGING

    def test_text_fallback(self):
        status = parse_ralph_status("WORK_TYPE: ANALYSIS\nEXIT_SIGNAL: true\n")
        assert status.work_type == WorkType.ANALYSIS
        assert status.exit_signal is True

    def test_empty_input(self):
        status = parse_ralph_status("")
        assert status.work_type == WorkType.UNKNOWN
        assert status.exit_signal is False
