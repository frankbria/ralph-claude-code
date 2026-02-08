# Running Ralph in Docker

> **Implements**: [Issue #74 - Phase 6.1 Local Docker Sandbox Execution](https://github.com/frankbria/ralph-claude-code/issues/74)

Run Ralph inside a Docker container for isolated execution. This provides sandboxing without cloud dependencies, full control over the execution environment, and **Windows support** via Docker Desktop.

## Prerequisites

- **Docker Desktop** (Windows, macOS, or Linux)
  - Windows: [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) with WSL2 backend
  - macOS: [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/)
  - Linux: Docker Engine or Docker Desktop
- **Claude Code authentication**: Either an Anthropic API key or Claude Max/Pro subscription

## Quick Start

### Build the Image

```bash
git clone https://github.com/frankbria/ralph-claude-code.git
cd ralph-claude-code
docker build -t ralph-claude-code .
```

### Authenticate with Claude

**Option A: Interactive login (Claude Max/Pro)**

```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -v ~/.claude:/home/ralph/.claude \
  ralph-claude-code

# Inside the container, run:
claude
# Follow the login prompts, then exit
```

Your auth credentials are saved in `~/.claude` on your host and will persist across container restarts.

**Option B: API key**

```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -e ANTHROPIC_API_KEY=sk-ant-api03-xxxxx \
  --entrypoint ralph \
  ralph-claude-code --monitor
```

### Run Ralph

```bash
# Navigate to your project
cd /path/to/my-project

# Start Ralph with live output
docker run -it --rm \
  -v $(pwd):/workspace \
  -v ~/.claude:/home/ralph/.claude \
  --entrypoint ralph \
  ralph-claude-code --live
```

## Docker Compose

The included `docker-compose.yml` provides three services:

| Service | Purpose | Command |
|---------|---------|---------|
| `ralph` | Interactive shell for setup and auth | `docker compose run --rm ralph` |
| `ralph-loop` | Autonomous development loop | `docker compose up ralph-loop` |
| `ralph-monitor` | Live monitoring dashboard | `docker compose up ralph-monitor` |

### First-Time Setup

```bash
# 1. Start interactive shell and authenticate
docker compose run --rm ralph

# Inside container:
claude  # authenticate
ralph-enable  # set up your project
exit

# 2. Start autonomous loop with monitoring
docker compose up ralph-loop ralph-monitor
```

### Environment Variables

Create a `.env` file in the project root:

```env
# Point to your project directory (default: current directory)
RALPH_PROJECT_DIR=./my-project

# Override Claude config location
CLAUDE_CONFIG_DIR=~/.claude

# Or use API key authentication
ANTHROPIC_API_KEY=sk-ant-api03-xxxxx
```

## Windows (PowerShell)

The `ralph-docker.ps1` script provides a native Windows experience:

```powershell
# First-time setup: build image + authenticate
.\ralph-docker.ps1 setup

# Start autonomous development
.\ralph-docker.ps1 start -Live

# Open monitoring dashboard
.\ralph-docker.ps1 monitor

# Interactive shell
.\ralph-docker.ps1 shell

# Check status
.\ralph-docker.ps1 status

# Stop everything
.\ralph-docker.ps1 stop
```

### PowerShell Options

```powershell
.\ralph-docker.ps1 start `
  -ProjectDir "C:\Users\me\my-app" `
  -Calls 50 `
  -Timeout 30 `
  -Live
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ProjectDir` | `.` | Project directory to mount |
| `-ApiKey` | (none) | Anthropic API key |
| `-Calls` | `100` | Max API calls per hour |
| `-Timeout` | `15` | Execution timeout (minutes) |
| `-Live` | `$false` | Enable live streaming output |

## Resource Limits

Control container resources with environment variables or docker run flags:

```bash
# Via environment
export DOCKER_MEMORY_LIMIT=4g
export DOCKER_CPU_LIMIT=2

# Via docker run
docker run -it --rm \
  --memory 4g \
  --cpus 2 \
  -v $(pwd):/workspace \
  -v ~/.claude:/home/ralph/.claude \
  --entrypoint ralph \
  ralph-claude-code --live
```

## Network Configuration

The container needs internet access for the Claude API. By default it uses Docker's bridge network.

```bash
# Full isolation (no network - will break Claude API calls)
docker run --network none ...

# Host networking (less isolation, better performance)
docker run --network host ...

# Default bridge (recommended)
docker run --network bridge ...
```

## Architecture

```
┌─────────────────────────────────┐
│        Host Machine             │
│  (Windows / macOS / Linux)      │
│                                 │
│  ~/.claude/  ←──── Auth creds   │
│  ~/my-project/ ←── Your code    │
│                                 │
│  ┌───────────────────────────┐  │
│  │   Docker Container        │  │
│  │   (Ubuntu 22.04)          │  │
│  │                           │  │
│  │   /home/ralph/.claude ──┐ │  │
│  │   /workspace ──────────┐│ │  │
│  │                        ││ │  │
│  │   ralph ←── loop       ││ │  │
│  │   ralph-monitor ←─ ui  ││ │  │
│  │   claude ←── CLI       ││ │  │
│  │                        ││ │  │
│  │   Node.js 20 + tmux    ││ │  │
│  │   + jq + git + bash 5  ││ │  │
│  └────────────────────────┘│ │  │
│           ▲  bind mounts   │ │  │
│           └────────────────┘ │  │
└──────────────────────────────┘  │
                                  │
        Claude API ◄──────────────┘
```

## Troubleshooting

### "Permission denied" on mounted files

On Linux, the container runs as user `ralph` (non-root). Ensure your project files are readable:

```bash
chmod -R a+rX ./my-project
```

### Auth not persisting across restarts

Make sure you're mounting `~/.claude`:

```bash
-v ~/.claude:/home/ralph/.claude
```

On Windows, this is `%USERPROFILE%\.claude`:

```powershell
-v "$env:USERPROFILE\.claude:/home/ralph/.claude"
```

### Container can't reach Claude API

Check Docker's network settings. The container needs outbound HTTPS access:

```bash
# Test from inside container
docker run --rm ralph-claude-code -c "curl -s https://api.anthropic.com"
```

### tmux not working in Docker

The container includes tmux but `ralph --monitor` mode requires a TTY. Always use `-it` flags:

```bash
docker run -it --rm ...  # -it is required for tmux
```

### Windows line endings (CRLF)

If you see `\r` errors, ensure your git config handles line endings:

```bash
git config --global core.autocrlf input
```

Or add a `.gitattributes` to your project:

```
*.sh text eol=lf
*.bats text eol=lf
```
