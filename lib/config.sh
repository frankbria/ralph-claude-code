#!/bin/bash
# =============================================================================
# Ralph Loop - Configuration Loading Utilities
# =============================================================================
# Provides shared helpers for loading Ralph configuration from:
#   - Global config:  ~/.ralphrc
#   - Project config: ./.ralphrc
#
# Configuration precedence (highest to lowest) is:
#   1. Command-line arguments
#   2. Project .ralphrc
#   3. Global ~/.ralphrc
#   4. Default values in scripts
#
# This helper is safe to source from any script. It only logs via log_status
# when that function is defined in the calling context.
# =============================================================================

# Loads configuration files if present.
# Global config (~/.ralphrc) is loaded first, then project config (./.ralphrc).
# Both files are sourced in the current shell so they can override defaults.
load_config() {
    local global_config="$HOME/.ralphrc"
    local project_config="./.ralphrc"

    if [[ -f "$global_config" ]]; then
        # shellcheck source=/dev/null
        source "$global_config"
        if declare -f log_status >/dev/null 2>&1; then
            log_status "INFO" "Loaded global config: ~/.ralphrc"
        fi
    fi

    if [[ -f "$project_config" ]]; then
        # shellcheck source=/dev/null
        source "$project_config"
        if declare -f log_status >/dev/null 2>&1; then
            log_status "INFO" "Loaded project config: .ralphrc"
        fi
    fi
}