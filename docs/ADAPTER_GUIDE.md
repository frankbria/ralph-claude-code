# Ralph Loop - Adapter Development Guide

This guide explains how to create custom adapters for Ralph Loop, enabling support for any AI CLI tool.

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Adapter Interface](#adapter-interface)
4. [Creating a Custom Adapter](#creating-a-custom-adapter)
5. [Testing Your Adapter](#testing-your-adapter)
6. [Best Practices](#best-practices)
7. [Built-in Adapters](#built-in-adapters)
8. [Troubleshooting](#troubleshooting)

---

## Overview

Ralph Loop uses an adapter pattern to support multiple AI CLI tools. Each adapter implements a standardized interface that allows Ralph to execute commands, parse output, and detect completion regardless of the underlying CLI tool.

### Architecture

```text
┌─────────────────────────────────────────────────────────┐
│                     Ralph Loop                          │
│                         │                               │
│              ┌──────────┴──────────┐                   │
│              │   Adapter Interface │                   │
│              │  (adapter_interface.sh)                 │
│              └──────────┬──────────┘                   │
│     ┌───────────┬───────┼───────┬───────────┐         │
│     ▼           ▼       ▼       ▼           ▼         │
│ ┌───────┐ ┌─────────┐ ┌──────┐ ┌──────┐ ┌────────┐   │
│ │Claude │ │  Aider  │ │Ollama│ │Cursor│ │ Custom │   │
│ │ Code  │ │         │ │      │ │      │ │Adapter │   │
│ └───────┘ └─────────┘ └──────┘ └──────┘ └────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Key Concepts

- **Adapter**: A bash script that implements the adapter interface for a specific CLI tool
- **Adapter Interface**: A set of required functions that each adapter must implement
- **Adapter Registry**: A JSON file listing available adapters and their metadata

---

## Quick Start

1. **Copy the template**:
   ```bash
   cp lib/adapters/adapter_template.sh lib/adapters/my_tool.sh
   ```

2. **Edit the adapter**:
   ```bash
   # Update these variables
   ADAPTER_ID="my_tool"
   ADAPTER_DISPLAY_NAME="My Custom Tool"
   ADAPTER_CLI_COMMAND="mytool"
   ```

3. **Implement required functions** (see below)

4. **Test your adapter**:
   ```bash
   ralph --adapter my_tool --adapter-check
   ralph --adapter my_tool --dry-run
   ```

---

## Adapter Interface

### Required Functions

Every adapter **must** implement these functions:

#### `adapter_name()`
Returns the human-readable display name.

```bash
adapter_name() {
    echo "My Custom Tool"
}
```

#### `adapter_id()`
Returns a unique lowercase identifier.

```bash
adapter_id() {
    echo "my_tool"
}
```

#### `adapter_version()`
Returns the adapter version (semantic versioning).

```bash
adapter_version() {
    echo "1.0.0"
}
```

#### `adapter_check()`
Verifies the CLI tool is installed and properly configured.
Returns 0 if ready, 1 if not available.

```bash
adapter_check() {
    if command -v mytool &> /dev/null; then
        return 0
    else
        echo "Error: mytool not found. Install with: brew install mytool"
        return 1
    fi
}
```

#### `adapter_execute()`
Executes the CLI tool with the given prompt.

**Parameters:**
- `$1`: prompt_file - Path to the prompt file
- `$2`: timeout_minutes - Execution timeout in minutes
- `$3`: verbose - "true" or "false"
- `$4`: extra_args - Additional arguments (optional)

```bash
adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"
    
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    
    timeout "${timeout_minutes}m" mytool --message "$prompt_content" 2>&1
    return $?
}
```

#### `adapter_parse_output()`
Parses CLI output to determine execution status.
Returns one of: `COMPLETE`, `ERROR`, `CONTINUE`, `RATE_LIMITED`

```bash
adapter_parse_output() {
    local output="$1"
    
    if echo "$output" | grep -qiE "all tasks complete"; then
        echo "COMPLETE"
    elif echo "$output" | grep -qiE "rate limit"; then
        echo "RATE_LIMITED"
    elif echo "$output" | grep -qiE "^error:"; then
        echo "ERROR"
    else
        echo "CONTINUE"
    fi
}
```

#### `adapter_supports()`
Returns comma-separated list of supported features.

```bash
adapter_supports() {
    echo "streaming,multi-model,code-editing"
}
```

### Optional Functions

These functions have default implementations but can be overridden:

| Function | Purpose | Default |
|----------|---------|--------|
| `adapter_get_config()` | Returns JSON config | Basic config |
| `adapter_get_models()` | Lists available models | "default" |
| `adapter_set_model()` | Sets active model | No-op |
| `adapter_get_rate_limit_status()` | Rate limit info | Empty |
| `adapter_handle_rate_limit()` | Handle rate limits | Sleep |
| `adapter_cleanup()` | Post-execution cleanup | No-op |
| `adapter_get_install_command()` | Installation command | Generic help |
| `adapter_get_documentation_url()` | Docs URL | Ralph repo |

---

## Creating a Custom Adapter

### Step 1: Create the Adapter File

```bash
#!/bin/bash
# ~/.ralph/adapters/my_tool.sh or lib/adapters/my_tool.sh

ADAPTER_ID="my_tool"
ADAPTER_DISPLAY_NAME="My Tool"
ADAPTER_VERSION="1.0.0"
ADAPTER_CLI_COMMAND="mytool"

# Required functions
adapter_name() { echo "$ADAPTER_DISPLAY_NAME"; }
adapter_id() { echo "$ADAPTER_ID"; }
adapter_version() { echo "$ADAPTER_VERSION"; }

adapter_check() {
    if ! command -v "$ADAPTER_CLI_COMMAND" &> /dev/null; then
        echo "Error: $ADAPTER_CLI_COMMAND not installed"
        return 1
    fi
    return 0
}

adapter_execute() {
    local prompt_file="$1"
    local timeout="${2:-15}"
    
    timeout "${timeout}m" "$ADAPTER_CLI_COMMAND" --input "$prompt_file"
}

adapter_parse_output() {
    local output="$1"
    
    # Customize these patterns for your tool
    if echo "$output" | grep -qiE "complete|done|finished"; then
        echo "COMPLETE"
    elif echo "$output" | grep -qiE "error|failed"; then
        echo "ERROR"
    else
        echo "CONTINUE"
    fi
}

adapter_supports() {
    echo "streaming,custom-feature"
}

# Optional: Custom configuration
adapter_get_config() {
    cat << 'EOF'
{
    "max_context_tokens": 50000,
    "supports_streaming": true,
    "default_timeout": 10
}
EOF
}

adapter_get_install_command() {
    echo "pip install my-tool"
}
```

### Step 2: Place the Adapter

Adapters are discovered from these locations (in order):
1. `~/.ralph/adapters/` - User custom adapters
2. `$RALPH_INSTALL_DIR/lib/adapters/` - Installation directory
3. `lib/adapters/` - Local development

### Step 3: Configure (Optional)

Add configuration to `~/.ralphrc` or `.ralphrc`:

```bash
# Default adapter
RALPH_ADAPTER="my_tool"

# Tool-specific settings
MY_TOOL_API_KEY="xxx"
MY_TOOL_MODEL="default"
```

### Step 4: Test

```bash
# Check if adapter loads
ralph --adapter my_tool --adapter-check

# Preview execution
ralph --adapter my_tool --dry-run

# Run with monitoring
ralph --adapter my_tool --monitor
```

---

## Testing Your Adapter

### Unit Tests

Create a test file at `tests/unit/test_my_adapter.bats`:

```bash
#!/usr/bin/env bats

load '../test_helper'

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/adapters/adapter_interface.sh"
}

@test "my_adapter: loads successfully" {
    run load_adapter "my_tool"
    [ "$status" -eq 0 ]
}

@test "my_adapter: returns correct name" {
    load_adapter "my_tool"
    run adapter_name
    [ "$output" = "My Tool" ]
}

@test "my_adapter: parse_output detects completion" {
    load_adapter "my_tool"
    run adapter_parse_output "Task complete!"
    [ "$output" = "COMPLETE" ]
}
```

### Run Tests

```bash
# Run adapter tests
bats tests/unit/test_adapters.bats

# Run specific adapter test
bats tests/unit/test_my_adapter.bats
```

### Verify Interface Compliance

```bash
# In bash
source lib/adapters/adapter_interface.sh
verify_adapter_interface "my_tool"
```

---

## Best Practices

### 1. Output Parsing

Be careful with output parsing to avoid false positives:

```bash
adapter_parse_output() {
    local output="$1"
    
    # BAD: Too broad, matches "error" anywhere
    # if echo "$output" | grep -qi "error"; then
    
    # GOOD: Match specific patterns
    if echo "$output" | grep -qE "^Error:|^FATAL:"; then
        echo "ERROR"
        return 0
    fi
    
    # Check for JSON false positives
    # Skip lines like '"is_error": false'
    if echo "$output" | grep -v '"[^"]*error[^"]*":' | grep -qiE "error occurred"; then
        echo "ERROR"
        return 0
    fi
    
    echo "CONTINUE"
}
```

### 2. Timeout Handling

Always use timeouts to prevent hangs:

```bash
adapter_execute() {
    local timeout_minutes="${2:-15}"
    local timeout_seconds=$((timeout_minutes * 60))
    
    # Use timeout command
    timeout "$timeout_seconds" mytool ...
    
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        echo "Error: Command timed out after $timeout_minutes minutes"
    fi
    return $exit_code
}
```

### 3. Environment Configuration

Support configuration through environment variables:

```bash
ADAPTER_MODEL="${MY_TOOL_MODEL:-default}"
ADAPTER_API_KEY="${MY_TOOL_API_KEY:-}"

adapter_check() {
    if [[ -z "$ADAPTER_API_KEY" ]]; then
        echo "Warning: MY_TOOL_API_KEY not set"
    fi
    # ...
}
```

### 4. Error Messages

Provide helpful error messages:

```bash
adapter_check() {
    if ! command -v mytool &> /dev/null; then
        echo "Error: mytool not found"
        echo "Install with: $(adapter_get_install_command)"
        echo "Documentation: $(adapter_get_documentation_url)"
        return 1
    fi
}
```

### 5. Cleanup

Implement cleanup for resources:

```bash
adapter_cleanup() {
    # Remove temp files
    rm -f /tmp/mytool_session_* 2>/dev/null
    
    # Close connections
    mytool --disconnect 2>/dev/null
    
    return 0
}
```

---

## Built-in Adapters

### Claude Code (`claude`)

**Default adapter** for Anthropic's Claude Code CLI.

```bash
# Installation
npm install -g @anthropic-ai/claude-code

# Configuration
RALPH_CLAUDE_TOOLS="Edit,Write,Bash,Read,Glob"
RALPH_CLAUDE_MODEL="claude-sonnet-4-20250514"

# Usage
ralph --adapter claude --monitor
```

**Features**: streaming, tools, vision, 200k context

### Aider (`aider`)

AI pair programming supporting multiple models.

```bash
# Installation
pip install aider-chat

# Configuration
RALPH_AIDER_MODEL="gpt-4-turbo"  # or claude-3-opus, ollama/*

# Usage
ralph --adapter aider --monitor
```

**Features**: multi-model, git-integration, local-models

### Ollama (`ollama`)

Local LLMs for fully offline operation.

```bash
# Installation
curl -fsSL https://ollama.ai/install.sh | sh
ollama pull codellama

# Configuration
RALPH_OLLAMA_MODEL="codellama"

# Usage
ralph --adapter ollama --monitor
```

**Features**: local, offline, no-rate-limit

---

## Troubleshooting

### Adapter Not Found

```
Error: Adapter 'my_tool' not found
```

**Solution**: Ensure the adapter file is in a discoverable location:
- `~/.ralph/adapters/my_tool.sh`
- `lib/adapters/my_tool.sh`

### Adapter Check Failed

```
Error: Adapter 'my_tool' check failed
```

**Solution**: Run the check manually to see details:
```bash
ralph --adapter my_tool --adapter-check
```

### Missing Functions

```
Error: Adapter 'my_tool' is missing required functions:
  - adapter_execute
  - adapter_parse_output
```

**Solution**: Implement all required functions (see [Adapter Interface](#adapter-interface))

### Parse Output Issues

If Ralph isn't detecting completion/errors correctly:

1. Check your `adapter_parse_output()` patterns
2. Use `--verbose` to see raw output
3. Test parsing manually:
   ```bash
   source lib/adapters/my_tool.sh
   adapter_parse_output "Your test output here"
   ```

---

## Contributing

If you create an adapter for a popular CLI tool, consider contributing it!

1. Place adapter in `lib/adapters/`
2. Add tests in `tests/unit/test_<adapter>.bats`
3. Update `lib/adapters/registry.json`
4. Submit a PR

See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.
