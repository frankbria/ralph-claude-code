---
paths:
  - "**/security/**/*.py"
  - "**/auth/**/*.py"
  - "**/validators/**/*.py"
---
# Security Rules (TappsMCP)

Run `tapps_security_scan(file_path)` after editing any security-related file.

Use `tapps_lookup_docs(library, topic)` for security design decisions (e.g. `tapps_lookup_docs(library="cryptography", topic="symmetric encryption")` or `tapps_lookup_docs(library="oauth2", topic="PKCE")`).

## Mandatory Checks

- All file I/O must go through `security/path_validator.py`
- Never use `eval()`, `exec()`, or `pickle.loads()` on external input
- Never use `subprocess.run(shell=True)` with user-controlled input
- Use parameterized queries — no raw SQL string concatenation
- No hardcoded secrets, API keys, tokens, or passwords
- All retrieved content must pass through `security/content_safety.py`

## Subprocess Safety

- Only packages in `_ALLOWED_CHECKER_PACKAGES` may reach `subprocess.run`
- Always use explicit argument lists, not shell strings
- Set appropriate timeouts on all subprocess calls
