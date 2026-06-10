# Default Ralph sandbox image (Issue #74)
#
# Used by `ralph --sandbox docker`: Ralph's loop stays on the host and runs the
# Claude Code CLI inside a container built from this image, with the project
# bind-mounted at /workspace. The image only needs the Claude CLI plus common
# development tooling — Ralph itself is NOT installed in the container.
#
# Build:  docker build -t ralph-sandbox .
# Custom: FROM ralph-sandbox:latest, then add your project's toolchain
#         (or point --sandbox-image at any image with `claude` on PATH).

FROM node:20-slim

# Common development tooling for autonomous loops (git for commits, jq for
# JSON, python3 + pip for Python projects, curl/ca-certificates for installs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    procps \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI — the execution engine the sandbox runs
RUN npm install -g @anthropic-ai/claude-code

# Non-root default user: reuse the base image's `node` user (uid 1000) rather
# than useradd-ing a new one, which would land at uid 1001 and break writes to
# bind mounts owned by a uid-1000 host user. At runtime ralph_loop.sh overrides
# this anyway with `--user "$(id -u):$(id -g)"` so workspace files keep host
# ownership; this USER is the safe default for manual `docker run` usage.
USER node

WORKDIR /workspace

# Keepalive default; ralph_loop.sh passes `sleep infinity` explicitly on
# `docker run` and executes Claude via `docker exec` per loop iteration.
CMD ["sleep", "infinity"]
