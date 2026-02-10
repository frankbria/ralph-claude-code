# Docker Setup (Windows & Cross-Platform)

Ralph runs natively on Linux and macOS. For **Windows** users (or anyone who prefers containerized execution), Ralph can run inside a Docker container with full functionality.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows/macOS) or Docker Engine (Linux)
- Windows users: Docker Desktop must use the **WSL 2 backend** (default on modern installations)
- **Docker Desktop must be running** before executing any `docker` commands. Look for the Docker whale icon in your system tray (Windows) or menu bar (macOS).
- Your `ANTHROPIC_API_KEY`

## Quick Start

### 1. Build the image

From the Ralph repository root:

```bash
docker build -t ralph-claude-code .
```

### 2. Run Ralph in your project

```bash
cd /path/to/your-project

docker run -it --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -v "$(pwd):/workspace" \
  ralph-claude-code \
  ralph --monitor
```

**Windows PowerShell:**

```powershell
cd C:\path\to\your-project

docker run -it --rm `
  -e ANTHROPIC_API_KEY="$env:ANTHROPIC_API_KEY" `
  -v "${PWD}:/workspace" `
  ralph-claude-code `
  ralph --monitor
```

## Using Docker Compose

The repository includes a `docker-compose.yml` for convenience:

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Run Ralph
docker compose run --rm ralph ralph --monitor
```

To customize, edit `docker-compose.yml`. Uncomment the volume mounts for git config and SSH keys if you need git push from inside the container:

```yaml
volumes:
  - ./:/workspace
  - ~/.gitconfig:/home/ralph/.gitconfig:ro
  - ~/.ssh:/home/ralph/.ssh:ro
```

## Convenience Wrapper Scripts

The `docker/` directory contains wrapper scripts that handle volume mounts, UID mapping, and API key forwarding automatically:

**Linux/macOS/WSL:**
```bash
./docker/ralph-docker --monitor
./docker/ralph-docker --live --verbose
```

**Windows PowerShell:**
```powershell
.\docker\ralph-docker.ps1 --monitor
.\docker\ralph-docker.ps1 --live --verbose
```

## File Permissions (UID/GID Mapping)

When Docker mounts your project directory, files created inside the container need to have the correct ownership on the host. The container supports `RALPH_UID` and `RALPH_GID` environment variables:

```bash
docker run -it --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e RALPH_UID="$(id -u)" \
  -e RALPH_GID="$(id -g)" \
  -v "$(pwd):/workspace" \
  ralph-claude-code \
  ralph --monitor
```

The wrapper scripts (`docker/ralph-docker`) set these automatically.

## Git Integration

To enable git commits and pushes from inside the container, mount your git configuration:

```bash
docker run -it --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -v "$(pwd):/workspace" \
  -v "$HOME/.gitconfig:/home/ralph/.gitconfig:ro" \
  -v "$HOME/.ssh:/home/ralph/.ssh:ro" \
  ralph-claude-code \
  ralph --monitor
```

## Running Tests Inside Docker

```bash
# Run all tests
docker run --rm ralph-claude-code bash -c 'cd /opt/ralph-claude-code && npm test'

# Run specific test suite
docker run --rm ralph-claude-code bash -c 'cd /opt/ralph-claude-code && npm run test:unit'
```

## Windows-Specific Notes

### Line Endings

The repository includes a `.gitattributes` file that forces LF line endings for all shell scripts. This prevents Windows' CRLF line endings from corrupting bash scripts. If you clone the repository on Windows, this is handled automatically.

If you encounter `\r` errors when running scripts, ensure `.gitattributes` is respected:

```bash
git config core.autocrlf input
git rm --cached -r .
git reset --hard
```

### Volume Mount Performance

For best performance on Windows, store your projects in the WSL 2 filesystem rather than the Windows filesystem:

```
# Faster (WSL filesystem)
\\wsl$\Ubuntu\home\user\my-project

# Slower (Windows filesystem mounted in WSL)
/mnt/c/Users/user/my-project
```

### PowerShell Environment Variables

```powershell
# Set API key for current session
$env:ANTHROPIC_API_KEY = "sk-ant-..."

# Or persist across sessions
[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "sk-ant-...", "User")
```

## Troubleshooting

### "error during connect: docker daemon is not running"

Docker Desktop is not started. On Windows, launch Docker Desktop from the Start menu and wait until the whale icon in the system tray shows "Docker Desktop is running". On macOS, launch it from Applications. On Linux, start the daemon with `sudo systemctl start docker`.

### "ANTHROPIC_API_KEY is not set"

The container warns if no API key is provided. Pass it with `-e ANTHROPIC_API_KEY=...`.

### Permission denied on mounted files

Set `RALPH_UID` and `RALPH_GID` to match your host user (see File Permissions section above).

### tmux not working

Ensure you run the container with `-it` flags (interactive + TTY). Without TTY, tmux cannot create sessions. Use `ralph` without `--monitor` in non-interactive environments.

### Container can't access the network

Docker Desktop may need network access enabled. Check Docker Desktop settings and firewall rules.

## What's in the Container

The Docker image includes all Ralph dependencies:

| Component | Version |
|-----------|---------|
| Debian | bookworm-slim |
| Bash | 5.2+ |
| Node.js | 20 LTS |
| jq | Latest |
| Git | Latest |
| tmux | Latest |
| GNU coreutils | Latest |
| Claude Code CLI | Latest |
