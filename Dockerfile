FROM debian:bookworm-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    jq \
    git \
    tmux \
    coreutils \
    curl \
    ca-certificates \
    gosu \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create ralph user
RUN groupadd -g 1000 ralph \
    && useradd -m -u 1000 -g ralph -s /bin/bash ralph

# Copy Ralph source
COPY . /opt/ralph-claude-code/

# Install Ralph as the ralph user
USER ralph
RUN cd /opt/ralph-claude-code && bash install.sh
ENV PATH="/home/ralph/.local/bin:${PATH}"

# Switch back to root for entrypoint (handles UID remapping)
USER root

# Copy entrypoint
COPY docker/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["ralph", "--help"]
