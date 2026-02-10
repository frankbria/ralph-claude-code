#!/bin/bash
set -e

# Default UID/GID matching typical Linux/macOS user
RALPH_UID=${RALPH_UID:-1000}
RALPH_GID=${RALPH_GID:-1000}

# Remap ralph user UID/GID to match host user (avoids file permission issues on bind mounts)
if [ "$(id -u ralph)" != "$RALPH_UID" ] || [ "$(id -g ralph)" != "$RALPH_GID" ]; then
    groupmod -g "$RALPH_GID" ralph 2>/dev/null || true
    usermod -u "$RALPH_UID" -g "$RALPH_GID" -d /home/ralph ralph 2>/dev/null || true
    chown -R ralph:ralph /home/ralph 2>/dev/null || true
fi

# Git safe.directory for mounted workspace
gosu ralph git config --global --add safe.directory /workspace 2>/dev/null || true

# Warn if API key is missing
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "WARNING: ANTHROPIC_API_KEY is not set. Ralph will not be able to call Claude."
    echo "Set it with: docker run -e ANTHROPIC_API_KEY=your-key ..."
    echo ""
fi

# Execute command as ralph user
exec gosu ralph "$@"
