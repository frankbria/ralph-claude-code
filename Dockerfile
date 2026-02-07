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

# Install Ralph: run install.sh then create symlinks on PATH
# install.sh copies scripts to ~/.ralph but does not symlink into
# a custom INSTALL_DIR reliably, so we create the links manually.
RUN chmod +x /opt/ralph/install.sh \
    && cd /opt/ralph \
    && bash ./install.sh || true \
    && BIN="/home/ralph/.npm-global/bin" \
    && RALPH_HOME="/home/ralph/.ralph" \
    && ln -sf "$RALPH_HOME/ralph_loop.sh"              "$BIN/ralph" \
    && ln -sf "$RALPH_HOME/ralph_monitor.sh"           "$BIN/ralph-monitor" \
    && ln -sf "$RALPH_HOME/setup.sh"                   "$BIN/ralph-setup" \
    && ln -sf "$RALPH_HOME/ralph_import.sh"            "$BIN/ralph-import" \
    && ln -sf "$RALPH_HOME/migrate_to_ralph_folder.sh" "$BIN/ralph-migrate" \
    && ln -sf "$RALPH_HOME/ralph_enable.sh"            "$BIN/ralph-enable" \
    && ln -sf "$RALPH_HOME/ralph_enable_ci.sh"         "$BIN/ralph-enable-ci"

WORKDIR /workspace

# Health check - verify ralph is available
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD command -v ralph >/dev/null 2>&1 || exit 1

# Default entrypoint: interactive bash with ralph available
# Users can override with: docker run ... ralph --monitor
ENTRYPOINT ["/bin/bash"]
