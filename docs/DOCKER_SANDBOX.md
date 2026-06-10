# Docker Sandbox Execution

`ralph --sandbox docker` runs the Claude Code CLI inside an isolated Docker
container instead of directly on your machine (Issue #74, first slice of the
Phase 6.0 sandbox epic #49).

## Architecture

Ralph's orchestration stays on the host; only Claude's execution is
containerized:

```
HOST                                      CONTAINER (persistent)
ralph_loop.sh ── docker exec ──────────▶  claude -p "..." (per iteration)
  ├─ rate limiting / circuit breaker        │
  ├─ response analysis / exit detection     ▼
  ├─ status.json (ralph-monitor)          /workspace  ◀── bind mount (rw) ── project dir
  └─ cleanup on exit / Ctrl+C
```

- **One persistent container** is started before the loop (`docker run -d ...
  sleep infinity`) and reused by every iteration via `docker exec` — no
  per-loop startup cost, and Claude's in-container session state survives
  across iterations (session continuity works).
- **The project directory is bind-mounted read-write at `/workspace`**, so
  file changes land on the host immediately. No file synchronization layer is
  needed (cloud-sandbox sync is Issue #76).
- **`ralph-monitor` works unchanged** — `status.json` is written host-side and
  gains a `sandbox` field (`provider`, `container_id`, `status`).
- **No silent fallback**: if sandbox setup fails (no Docker, missing image,
  bad config), Ralph exits with an error rather than running Claude on the
  host you asked it to protect.

## Setup

Docker must be installed and the daemon running. Build the default image:

```bash
# From a source checkout
docker build -t ralph-sandbox .

# Or from a global install (install.sh copies the Dockerfile to ~/.ralph)
docker build -t ralph-sandbox ~/.ralph
```

The default image is `node:20-slim` plus git, jq, python3, and the Claude Code
CLI, with the base image's non-root `node` user as the default. At runtime the
container is started with `--user "$(id -u):$(id -g)"`, so everything Claude
writes to the bind-mounted workspace keeps your host ownership and the seeded
`0600` credential files stay readable.

## CLI reference

| Flag | Default | Description |
|------|---------|-------------|
| `--sandbox docker` | (off) | Enable Docker sandbox execution |
| `--sandbox-image IMAGE` | `ralph-sandbox:latest` | Container image (must have `claude` on PATH) |
| `--sandbox-memory SIZE` | `4g` | Memory limit (`docker run --memory` format) |
| `--sandbox-cpus NUM` | `2` | CPU limit (decimals allowed, e.g. `1.5`) |
| `--sandbox-network MODE` | `bridge` | `none`, `bridge`, or `host` |

`e2b`, `daytona`, and `cloudflare` providers are planned (issues #75, #79,
#80) and currently rejected with a clear error. The sub-flags require a
provider (either `--sandbox docker` or `SANDBOX_PROVIDER` in `.ralphrc`).

`.ralphrc` equivalents (CLI flags override):

```bash
SANDBOX_PROVIDER="docker"
SANDBOX_DOCKER_IMAGE="ralph-sandbox:latest"
SANDBOX_DOCKER_MEMORY="4g"
SANDBOX_DOCKER_CPUS="2"
SANDBOX_DOCKER_NETWORK="bridge"
```

Environment variables of the same names take precedence over `.ralphrc`, and
`--monitor` (tmux) forwards all sandbox flags to the loop pane.

## Credentials

Handled by `setup_docker_credentials()` in `lib/sandbox_docker.sh`, in order:

1. **`ANTHROPIC_API_KEY` set** — written to a `0600` env-file in a per-run
   runtime directory under `/tmp` (deliberately **outside** the bind-mounted
   project, so the sandboxed process cannot read it as a workspace file and it
   can never be swept into a commit) and passed via `docker run --env-file`.
   The value is never logged; the file is deleted on cleanup. (`docker secret`
   is not used — it requires Swarm mode and does not work with plain
   `docker run`.)
2. **Host `~/.claude/.credentials.json` exists** — *copied* into a
   container-scoped directory in the same runtime dir, mounted as the
   container's `HOME`. The container can refresh its own session state there
   without ever touching the host's real `~/.claude`. Removed on cleanup.
3. **Neither** — a warning is logged and the loop continues (useful for
   custom images with authentication baked in).

## Network modes

- `bridge` (default) — container can reach the Claude API; normal isolation
  from the host network.
- `host` — shares the host network namespace; less isolation, occasionally
  needed for localhost services.
- `none` — full network isolation. **This blocks the Claude API**, so it only
  makes sense for images that route through a proxy or have offline tooling;
  the help text and docs call this out.

## Lifecycle and failure handling

- **Startup**: `init_docker_sandbox` (config validation, daemon check, image
  presence check with build/pull guidance) → `setup_docker_credentials` →
  `start_sandbox_container`. Any failure aborts the run.
- **Per iteration**: the built Claude command array is wrapped as
  `docker exec -i -w /workspace <container> claude ...`. Both `--live`
  (stream-json) and background modes work through the wrapper.
- **Timeout (exit 124)**: the host-side timeout kills only the `docker exec`
  client; the container is restarted (`docker restart -t 5`) to reap the
  orphaned in-container process before the next iteration.
- **Exit**: the container is stopped and removed, and credential artifacts are
  deleted — on graceful completion, circuit-breaker halt, errors, and
  SIGINT/SIGTERM. Cleanup is idempotent.
- **State**: `.ralph/.docker_sandbox_state` (JSON, atomic temp+`mv` writes)
  tracks image, limits, container id, and status.

## Custom images

Any image with the Claude CLI on `PATH` works:

```dockerfile
FROM ralph-sandbox:latest
USER root
RUN pip3 install --break-system-packages numpy pandas
USER node
```

```bash
docker build -t my-ml-sandbox .
ralph --sandbox docker --sandbox-image my-ml-sandbox
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Docker daemon is not reachable` | Start the Docker service (`sudo systemctl start docker`, or Docker Desktop) |
| `Sandbox image 'ralph-sandbox:latest' not found` | `docker build -t ralph-sandbox ~/.ralph` (or the repo root) |
| Claude auth errors inside the container | Export `ANTHROPIC_API_KEY`, or log in on the host first so `~/.claude/.credentials.json` exists |
| Loop hangs then times out with `--sandbox-network none` | Expected — `none` blocks the Claude API; use `bridge` |
| Orphaned container after a hard kill (`kill -9`) | `docker ps --filter name=ralph-sandbox` then `docker rm -f <id>`; normal exits and Ctrl+C clean up automatically |
