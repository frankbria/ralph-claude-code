# Analysis: Supporting Gemini & GitHub Copilot in Ralph

## 1. Current Architecture vs. Required Architecture

Currently, **Ralph is a Supervisor**, not an Agent.
*   **Ralph's Job:** It watches `claude-code`, ensures it doesn't get stuck, manages its rate limits, and decides when to stop.
*   **Claude Code's Job:** It acts as the **Agent**. It reads files, thinks, decides to edit a file, runs `sed`/`git`, checks the result, and iterates.

**The "Agent Gap":**
Standard CLIs for Gemini (`gemini`) and GitHub Copilot (`gh copilot`) are primarily **Text-In/Text-Out** interfaces. They generate code snippets or explanations but **do not** natively execute tools (like writing files or running tests) in a continuous loop on your terminal.

To support them, Ralph cannot just "wrap" them. Ralph must **become the Agent Runtime**.

## 2. Transformation Required

To support non-agentic CLIs (like Gemini/Copilot), Ralph must expand its responsibilities:

| Feature | Current (Claude Code) | Proposed (Gemini/Copilot) |
| :--- | :--- | :--- |
| **Thinking** | Claude Code | Gemini / Copilot |
| **Tool Execution** | **Claude Code** | **Ralph (New)** |
| **Loop Management** | Ralph | Ralph |
| **State/Memory** | Claude Code | Ralph (New) |

## 3. Key Components to Build

### A. Provider Abstraction Layer (`lib/providers/`)
We need a standard interface for interacting with different AIs.
*   `init_session()`: Start a conversation.
*   `send_message(prompt, context)`: Send user input + file context.
*   `parse_response(output)`: Extract text content AND **Tool Calls**.

### B. Tool Execution Engine (`lib/tool_executor.sh`)
Since Gemini/Copilot won't edit files themselves, Ralph must do it.
*   **Protocol:** Define a format for the AI to request actions (e.g., XML tags like `<write_file path="...">content</write_file>` or JSON function calls).
*   **Executor:** A script that parses these requests and runs:
    *   `write_file`: create/update files.
    *   `run_command`: execute bash commands (with safety checks).
    *   `read_file`: read file content to feed back to the AI.

### C. Prompt Engineering (`templates/prompts/`)
*   **Claude:** Uses its built-in system prompt.
*   **Gemini/Copilot:** We must inject a **System Prompt** that teaches them:
    *   "You are an autonomous coding agent."
    *   "You have access to these tools: read_file, write_file..."
    *   "To use a tool, output this specific format..."

## 4. Implementation Steps

1.  **Refactor `ralph_loop.sh`**:
    *   Replace direct `claude` calls with `provider.send_message`.
    *   Add a check: Does the provider handle tools?
        *   **Yes (Claude):** Do nothing (current behavior).
        *   **No (Gemini):** Parse output -> Run `ToolExecutor` -> Feed result back to `provider.send_message`.

2.  **Create Provider Adapters**:
    *   `lib/providers/claude.sh`: Wraps existing logic.
    *   `lib/providers/gemini.sh`: Wraps `gemini-cli` (or API curl calls), handles JSON parsing.
    *   `lib/providers/copilot.sh`: Wraps `gh copilot suggest` (more complex due to interactive nature, might need `expect` or API usage).

3.  **Build the Runtime**:
    *   Implement `lib/tool_executor.sh`.
    *   Implement "Tool Feedback Loop" in `ralph_loop.sh`.

## 5. Conclusion
Making Ralph compatible with Gemini/Copilot is a **major architectural upgrade**. It moves Ralph from being a "Process Manager" to being a "ReAct (Reason+Act) Agent Framework".
