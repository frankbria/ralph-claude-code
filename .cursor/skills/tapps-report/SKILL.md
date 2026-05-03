---
name: tapps-report
description: >-
  Generate a quality report across Python files in the project.
  Scores multiple files and presents an aggregate summary.
mcp_tools:
  - tapps_report
---

Generate a quality report using TappsMCP:

1. Call `tapps_report` with an optional file path
2. If no file path, a project-wide report scores up to 20 files
3. Present results in a table: file | score | pass/fail | top issue
4. Highlight any files scoring below the quality gate threshold
5. Suggest priority fixes for the lowest-scoring files
