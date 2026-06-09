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

# Non-root user: autonomous code execution should not run as root even inside
# the container (defense in depth alongside resource/network limits)
RUN useradd -m -s /bin/bash ralph
USER ralph

WORKDIR /workspace

# Keepalive default; ralph_loop.sh passes `sleep infinity` explicitly on
# `docker run` and executes Claude via `docker exec` per loop iteration.
CMD ["sleep", "infinity"]
