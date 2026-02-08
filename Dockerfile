## =============================================================================
## Ralph for Claude Code - Docker Image
## Implements: Issue #74 - Phase 6.1 Local Docker Sandbox Execution
## =============================================================================
## Usage:
##   docker build -t ralph-claude-code .
##   docker run -it -v $(pwd):/workspace -v ~/.claude:/home/ralph/.claude ralph-claude-code
## =============================================================================

FROM ubuntu:22.04

LABEL maintainer="Ralph Contributors"
LABEL description="Ralph for Claude Code - Autonomous AI development loop"
LABEL org.opencontainers.image.source="https://github.com/frankbria/ralph-claude-code"
LABEL org.opencontainers.image.licenses="MIT"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    jq \
    tmux \
    coreutils \
    grep \
    sed \
    gawk \
    dos2unix \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 LTS (required for Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user 'ralph' and prepare directories (as root)
RUN useradd -m -s /bin/bash ralph \
    && mkdir -p /home/ralph/.npm-global \
    && mkdir -p /home/ralph/.claude \
    && mkdir -p /workspace \
    && chown -R ralph:ralph /home/ralph /workspace

# Switch to ralph user for npm global installs
USER ralph
WORKDIR /home/ralph

# Configure npm global directory (no sudo needed)
ENV NPM_CONFIG_PREFIX=/home/ralph/.npm-global
ENV PATH="/home/ralph/.npm-global/bin:${PATH}"

# Install Claude Code CLI globally for ralph user
RUN npm install -g @anthropic-ai/claude-code

# Copy Ralph source into the image
COPY --chown=ralph:ralph . /opt/ralph

# Fix Windows CRLF line endings (critical for cross-platform builds)
RUN find /opt/ralph -type f \( -name "*.sh" -o -name "*.bats" \) -exec dos2unix {} +

# Install Ralph: run install.sh then create wrapper scripts on PATH.
# Wrapper scripts are needed (instead of symlinks) because Ralph's
# shell scripts resolve lib/ paths relative to their own location
# via dirname $0. A symlink would resolve to the bin/ directory
# which doesn't contain lib/.
RUN chmod +x /opt/ralph/install.sh \
    && cd /opt/ralph \
    && bash ./install.sh || true \
    && BIN="/home/ralph/.npm-global/bin" \
    && RALPH_HOME="/home/ralph/.ralph" \
    && for cmd_pair in \
         "ralph:ralph_loop.sh" \
         "ralph-monitor:ralph_monitor.sh" \
         "ralph-setup:setup.sh" \
         "ralph-import:ralph_import.sh" \
         "ralph-migrate:migrate_to_ralph_folder.sh" \
         "ralph-enable:ralph_enable.sh" \
         "ralph-enable-ci:ralph_enable_ci.sh"; do \
         cmd="${cmd_pair%%:*}"; \
         script="${cmd_pair##*:}"; \
         printf '#!/bin/bash\nexec "%s/%s" "$@"\n' "$RALPH_HOME" "$script" > "$BIN/$cmd"; \
         chmod +x "$BIN/$cmd"; \
       done

WORKDIR /workspace

# Health check - verify ralph is available
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD command -v ralph >/dev/null 2>&1 || exit 1

# Default entrypoint: interactive bash with ralph available
# Users can override with: docker run ... ralph --monitor
ENTRYPOINT ["/bin/bash"]
