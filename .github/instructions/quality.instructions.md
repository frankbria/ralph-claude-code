<!-- tapps-generated: v3.8.0 -->
---
applyTo: "**/*.py"
---

# Python Quality Standards

All Python files in this project are evaluated by TappsMCP across 7 quality
categories: complexity, security, maintainability, test coverage, performance,
structure, and developer experience.

## Requirements

- Functions should have cyclomatic complexity <= 10
- No function should exceed 50 lines (excluding docstrings and blank lines)
- All public functions and methods must have type annotations
- Use `pathlib.Path` for file paths, not string concatenation
- Use `structlog` for logging, never `print()` or bare `logging`
- All file I/O must go through the path validator for sandboxing

## Security

- Never use `eval()` or `exec()` with non-literal arguments
- Never use `pickle.loads()` on untrusted data
- Never use `subprocess` with `shell=True` and user input
- Never hardcode passwords, API keys, or tokens
- Always use parameterized queries for database operations
