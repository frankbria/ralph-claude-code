<!-- tapps-generated: v3.8.0 -->
---
applyTo: "tests/**"
---

# Testing Standards

## Requirements

- Tests must not make real HTTP requests — use mocks or `httpx.MockTransport`
- Tests must not read from or write to production configuration files
- Tests must not depend on global state without explicit setup/teardown
- Use `pytest` fixtures for shared setup, not `setUp()`/`tearDown()` methods
- Use `tmp_path` fixture for any file I/O in tests
- Tests should be deterministic — no random data without fixed seeds
- Mark slow tests (> 5 seconds) with `@pytest.mark.slow`
