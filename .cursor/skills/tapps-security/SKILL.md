---
name: tapps-security
description: >-
  Run a comprehensive security audit on a Python file including vulnerability scanning
  and dependency CVE checks.
mcp_tools:
  - tapps_security_scan
  - tapps_dependency_scan
---

Run a comprehensive security audit using TappsMCP:

1. Call `tapps_security_scan` on the target file to detect vulnerabilities
2. Call `tapps_dependency_scan` to check for known CVEs in dependencies
3. Group all findings by severity (critical, high, medium, low)
4. Suggest a prioritized fix order starting with the highest-severity issues
