<!-- tapps-generated: v3.8.0 -->
---
applyTo: "**/security/**"
---

# Security Module Standards

Files in the security module have elevated quality requirements.

## Requirements

- All functions must have comprehensive type annotations
- Security-critical functions must have unit tests with edge cases
- No `# type: ignore` comments without an inline justification
- Input validation must occur at every external boundary
- All cryptographic operations must use well-tested libraries (not hand-rolled)
- Secret scanning patterns must cover: API keys, tokens, passwords, private keys
