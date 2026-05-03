---
name: tapps-apply-files
description: >-
  Apply file operations from a TappsMCP content-return response.
  Used when the MCP server runs in Docker and cannot write files directly.
mcp_tools: []
---

When a TappsMCP or DocsMCP tool returns `content_return: true` with a `file_manifest`,
the server could not write files (Docker / read-only filesystem).  Apply the files:

1. Read `file_manifest.agent_instructions.persona` — adopt that role
2. If `backup_recommended` is true, warn the user that existing files may be overwritten
3. Sort files by `priority` (lowest first) — config files before content files
4. For each file in `file_manifest.files[]`:
   - **mode "create"**: Use the Write tool.  Create parent directories as needed.
   - **mode "overwrite"**: Use the Write tool to replace the file entirely.
   - **mode "merge"**: Read the existing file first, then apply the `content` as a
     replacement for the managed section.  The content is the pre-computed merge result;
     write it with the Write tool (the merge was already done server-side).
5. Write the `content` field **verbatim** — do not modify, reformat, or add comments
6. Follow `agent_instructions.verification_steps` after all files are written
7. Communicate any `agent_instructions.warnings` to the user
