# Implementation Plan: Multi-Provider Support

This plan outlines the steps to transform Ralph into a multi-provider agent framework.

## Phase 1: Modularization (The "Socket")
**Goal:** Abstract the hardcoded `claude` commands into a plugin system.

- [ ] **Create `lib/providers/` directory.**
- [ ] **Create `lib/providers/base.sh`:** Define the interface (functions `provider_init`, `provider_chat`, `provider_parse`).
- [ ] **Create `lib/providers/claude.sh`:** Move current `claude` CLI logic here.
- [ ] **Update `ralph_loop.sh`**:
    - Load the selected provider script based on `RALPH_PROVIDER` env var.
    - Replace `execute_claude_code` with generic `execute_provider_loop`.

## Phase 2: The Agent Runtime (The "Brain")
**Goal:** Enable Ralph to execute tools for "dumb" LLMs.

- [ ] **Design Tool Protocol:** Define how LLMs should request actions (e.g., Markdown code blocks or XML).
    - Example:
      ```xml
      <tool name="write_file">
      <path>src/main.py</path>
      <content>print("hello")</content>
      </tool>
      ```
- [ ] **Create `lib/tool_executor.sh`:**
    - Function `extract_tool_calls(llm_output)`
    - Function `execute_tool(name, args)`
    - Safety checks (prevent `rm -rf /`).
- [ ] **Create `templates/system_prompts/generic_agent.md`:**
    - A master prompt that explains available tools and the output format to the LLM.

## Phase 3: Gemini Adapter
**Goal:** Connect Google Gemini.

- [ ] **Prerequisite:** Install `gemini` CLI or use `curl` with API Key.
- [ ] **Create `lib/providers/gemini.sh`:**
    - Implement `provider_chat`:
        - Construct payload with `templates/system_prompts/generic_agent.md` + User Prompt + History.
        - Call API.
    - Implement `provider_parse`:
        - Extract text.
        - Detect if tool calls are present.

## Phase 4: GitHub Copilot Adapter
**Goal:** Connect GitHub Copilot.

- [ ] **Investigation:** Determine best CLI entry point (`gh copilot` vs raw API).
- [ ] **Create `lib/providers/copilot.sh`:**
    - Similar adaptation as Gemini.
    - *Note:* Copilot often refuses "system prompts" in CLI. May require "User" role spoofing.

## Phase 5: Configuration Update
**Goal:** User-friendly switching.

- [ ] **Update `ralph-setup` / `ralph-enable`:**
    - Ask "Which AI provider do you want to use?"
    - Generate `.ralphrc` with `RALPH_PROVIDER=gemini`.
- [ ] **Update `.ralphrc` template:** Add provider configuration sections.

## Estimated Effort
- **Phase 1:** 2 days (Refactoring)
- **Phase 2:** 3-4 days (Security & Logic)
- **Phase 3:** 1-2 days (Integration)
- **Total:** ~1-2 weeks for a robust MVP.
