---
globs: "*.py"
alwaysApply: false
---

# Python Quality Standards

When Python files are referenced, enforce these quality standards:

## 7 Scoring Categories

TappsMCP scores Python code across 7 categories (0-100 each):

1. **Complexity** - Cyclomatic complexity (radon cc / AST fallback)
2. **Security** - Bandit + pattern heuristics
3. **Maintainability** - Maintainability index (radon mi / AST fallback)
4. **Test Coverage** - Heuristic from matching test file existence
5. **Performance** - Halstead metrics, perflint anti-patterns, nested loops, large functions, deep nesting
6. **Structure** - Project layout (pyproject.toml, tests/, README, .git)
7. **DevEx** - Developer experience (docs, AGENTS.md, tooling config)

## Actions

- Call `tapps_quick_check(file_path)` on edited Python files
- Use `tapps_lookup_docs(library, topic)` before using unfamiliar library APIs
- Run `tapps_security_scan(file_path)` on security-sensitive changes
- Any category scoring below 70 needs immediate attention
- Call `tapps_score_file(file_path)` for full breakdown
