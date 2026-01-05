#!/bin/bash
# =============================================================================
# Ralph Loop - CLI Adapter Interface
# =============================================================================
# This file defines the interface that all CLI adapters must implement.
# Each adapter provides a bridge between Ralph Loop and a specific AI CLI tool.
#
# To create a custom adapter:
# 1. Copy adapter_template.sh to your_adapter.sh
# 2. Implement all required functions
# 3. Place in ~/.ralph/adapters/ or lib/adapters/
# =============================================================================

# -----------------------------------------------------------------------------
# REQUIRED FUNCTIONS - All adapters MUST implement these
# -----------------------------------------------------------------------------

# adapter_name()
# Returns the display name of the adapter
# @return: String - Human-readable adapter name
adapter_name() {
    echo "Base Adapter (Override Required)"
}

# adapter_id()
# Returns the unique identifier for this adapter
# @return: String - Lowercase identifier (e.g., "claude", "aider", "ollama")
adapter_id() {
    echo "base"
}

# adapter_version()
# Returns the adapter version
# @return: String - Semantic version (e.g., "1.0.0")
adapter_version() {
    echo "1.0.0"
}

# adapter_check()
# Verifies the CLI tool is installed and properly configured
# @return: 0 if ready, 1 if not available
adapter_check() {
    echo "Error: adapter_check() not implemented"
    return 1
}

# adapter_execute()
# Executes the CLI tool with the given prompt
# @param $1: prompt_file - Path to the prompt file
# @param $2: timeout_minutes - Execution timeout in minutes
# @param $3: verbose - "true" or "false" for verbose output
# @param $4: extra_args - Additional adapter-specific arguments (optional)
# @return: CLI output to stdout, exit code indicates success/failure
adapter_execute() {
    local prompt_file="$1"
    local timeout_minutes="${2:-15}"
    local verbose="${3:-false}"
    local extra_args="${4:-}"
    
    echo "Error: adapter_execute() not implemented"
    return 1
}

# adapter_parse_output()
# Parses CLI output to determine execution status
# @param $1: output - The CLI output to parse
# @return: "COMPLETE", "ERROR", "CONTINUE", or "RATE_LIMITED"
adapter_parse_output() {
    local output="$1"
    echo "CONTINUE"
}

# adapter_supports()
# Returns a comma-separated list of supported features
# @return: String - Feature list (e.g., "streaming,tools,vision")
adapter_supports() {
    echo "basic"
}

# -----------------------------------------------------------------------------
# OPTIONAL FUNCTIONS - Adapters MAY override these for enhanced functionality
# -----------------------------------------------------------------------------

# adapter_get_config()
# Returns adapter configuration as JSON
# @return: JSON string with adapter configuration
adapter_get_config() {
    cat << 'EOF'
{
    "max_context_tokens": 100000,
    "supports_tools": false,
    "supports_streaming": false,
    "supports_vision": false,
    "default_timeout": 15,
    "rate_limit_per_hour": 100
}
EOF
}

# adapter_get_models()
# Returns available models for this adapter
# @return: Newline-separated list of model names
adapter_get_models() {
    echo "default"
}

# adapter_set_model()
# Sets the model to use for execution
# @param $1: model_name - The model to use
# @return: 0 on success, 1 on failure
adapter_set_model() {
    local model_name="$1"
    return 0
}

# adapter_get_rate_limit_status()
# Returns current rate limit status
# @return: JSON with rate limit info or empty string if not applicable
adapter_get_rate_limit_status() {
    echo ""
}

# adapter_handle_rate_limit()
# Handles rate limit scenarios
# @param $1: wait_seconds - Suggested wait time
# @return: 0 to continue waiting, 1 to abort
adapter_handle_rate_limit() {
    local wait_seconds="${1:-60}"
    sleep "$wait_seconds"
    return 0
}

# adapter_cleanup()
# Performs any necessary cleanup after execution
# Called after each loop iteration
adapter_cleanup() {
    return 0
}

# adapter_get_install_command()
# Returns the command to install this CLI tool
# @return: String - Installation command
adapter_get_install_command() {
    echo "# No installation command available"
}

# adapter_get_documentation_url()
# Returns URL to adapter/CLI documentation
# @return: String - Documentation URL
adapter_get_documentation_url() {
    echo "https://github.com/pt-act/ralph-claude-code"
}

# -----------------------------------------------------------------------------
# ADAPTER LOADER UTILITIES
# -----------------------------------------------------------------------------

# Global variable to track loaded adapter
RALPH_LOADED_ADAPTER=""
RALPH_ADAPTER_PATH=""

# load_adapter()
# Loads an adapter by name
# @param $1: adapter_name - Name of adapter to load
# @return: 0 on success, 1 on failure
load_adapter() {
    local adapter_name="${1:-claude}"
    local adapter_file=""
    
    # Search paths for adapters
    local search_paths=(
        "$HOME/.ralph/adapters/${adapter_name}.sh"
        "${RALPH_INSTALL_DIR:-$HOME/.ralph}/lib/adapters/${adapter_name}.sh"
        "$(dirname "${BASH_SOURCE[0]}")/${adapter_name}.sh"
    )
    
    for path in "${search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            adapter_file="$path"
            break
        fi
    done
    
    if [[ -z "$adapter_file" ]]; then
        echo "Error: Adapter '$adapter_name' not found" >&2
        echo "Searched paths:" >&2
        for path in "${search_paths[@]}"; do
            echo "  - $path" >&2
        done
        return 1
    fi
    
    # Source the adapter
    # shellcheck source=/dev/null
    source "$adapter_file"
    
    RALPH_LOADED_ADAPTER="$adapter_name"
    RALPH_ADAPTER_PATH="$adapter_file"
    
    return 0
}

# list_available_adapters()
# Lists all available adapters
# @return: Newline-separated list of adapter names
list_available_adapters() {
    local adapters=()
    local search_paths=(
        "$HOME/.ralph/adapters"
        "${RALPH_INSTALL_DIR:-$HOME/.ralph}/lib/adapters"
        "$(dirname "${BASH_SOURCE[0]}")"
    )
    
    for dir in "${search_paths[@]}"; do
        if [[ -d "$dir" ]]; then
            for file in "$dir"/*.sh; do
                if [[ -f "$file" && "$(basename "$file")" != "adapter_interface.sh" && "$(basename "$file")" != "adapter_template.sh" ]]; then
                    local name
                    name=$(basename "$file" .sh)
                    # Avoid duplicates
                    if [[ ! " ${adapters[*]} " =~ " ${name} " ]]; then
                        adapters+=("$name")
                    fi
                fi
            done
        fi
    done
    
    printf '%s\n' "${adapters[@]}" | sort -u
}

# get_adapter_info()
# Gets detailed information about an adapter
# @param $1: adapter_name - Name of adapter
# @return: JSON with adapter information
get_adapter_info() {
    local adapter_name="$1"
    
    # Temporarily load adapter to get info
    local current_adapter="$RALPH_LOADED_ADAPTER"
    
    if load_adapter "$adapter_name" 2>/dev/null; then
        local name version supports config install_cmd doc_url
        name=$(adapter_name)
        version=$(adapter_version)
        supports=$(adapter_supports)
        config=$(adapter_get_config)
        install_cmd=$(adapter_get_install_command)
        doc_url=$(adapter_get_documentation_url)
        
        # Check if adapter is available
        local available="false"
        if adapter_check &>/dev/null; then
            available="true"
        fi
        
        cat << EOF
{
    "id": "$adapter_name",
    "name": "$name",
    "version": "$version",
    "available": $available,
    "supports": "$supports",
    "install_command": "$install_cmd",
    "documentation": "$doc_url",
    "config": $config
}
EOF
        
        # Restore previous adapter if any
        if [[ -n "$current_adapter" ]]; then
            load_adapter "$current_adapter" 2>/dev/null
        fi
        return 0
    else
        echo '{"error": "Adapter not found"}'
        return 1
    fi
}

# verify_adapter_interface()
# Verifies that an adapter implements required functions
# @param $1: adapter_name - Name of adapter to verify
# @return: 0 if valid, 1 if missing required functions
verify_adapter_interface() {
    local adapter_name="$1"
    local missing_functions=()
    local required_functions=(
        "adapter_name"
        "adapter_id"
        "adapter_version"
        "adapter_check"
        "adapter_execute"
        "adapter_parse_output"
        "adapter_supports"
    )
    
    if ! load_adapter "$adapter_name" 2>/dev/null; then
        echo "Error: Could not load adapter '$adapter_name'"
        return 1
    fi
    
    for func in "${required_functions[@]}"; do
        if ! declare -f "$func" > /dev/null 2>&1; then
            missing_functions+=("$func")
        fi
    done
    
    if [[ ${#missing_functions[@]} -gt 0 ]]; then
        echo "Error: Adapter '$adapter_name' is missing required functions:"
        printf '  - %s\n' "${missing_functions[@]}"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# AUTO-DETECTION AND FALLBACK SUPPORT
# -----------------------------------------------------------------------------

# detect_available_adapter()
# Automatically detects and returns the first available adapter
# @return: Name of first available adapter, or empty if none found
detect_available_adapter() {
    local preferred_order=("claude" "aider" "ollama")
    local all_adapters
    all_adapters=$(list_available_adapters)
    
    # First try preferred adapters in order
    for adapter in "${preferred_order[@]}"; do
        if echo "$all_adapters" | grep -q "^${adapter}$"; then
            if load_adapter "$adapter" 2>/dev/null && adapter_check &>/dev/null; then
                echo "$adapter"
                return 0
            fi
        fi
    done
    
    # Then try any other available adapter
    for adapter in $all_adapters; do
        # Skip already checked preferred adapters
        if [[ " ${preferred_order[*]} " =~ " ${adapter} " ]]; then
            continue
        fi
        
        if load_adapter "$adapter" 2>/dev/null && adapter_check &>/dev/null; then
            echo "$adapter"
            return 0
        fi
    done
    
    # No adapter available
    echo ""
    return 1
}

# load_adapter_with_fallback()
# Loads an adapter with fallback support
# @param $1: primary_adapter - Primary adapter to try
# @param $2: fallback_adapters - Comma-separated list of fallback adapters
# @return: 0 on success, 1 if all adapters failed
load_adapter_with_fallback() {
    local primary_adapter="$1"
    local fallback_adapters="${2:-}"
    
    # Try primary adapter first
    if load_adapter "$primary_adapter" 2>/dev/null && adapter_check &>/dev/null; then
        return 0
    fi
    
    echo "Warning: Primary adapter '$primary_adapter' not available" >&2
    
    # Try fallback adapters
    if [[ -n "$fallback_adapters" ]]; then
        IFS=',' read -ra fallbacks <<< "$fallback_adapters"
        for fallback in "${fallbacks[@]}"; do
            fallback=$(echo "$fallback" | xargs)  # Trim whitespace
            echo "Trying fallback adapter: $fallback" >&2
            
            if load_adapter "$fallback" 2>/dev/null && adapter_check &>/dev/null; then
                echo "Using fallback adapter: $fallback" >&2
                return 0
            fi
        done
    fi
    
    # Try auto-detection as last resort
    echo "Attempting auto-detection of available adapter..." >&2
    local detected
    detected=$(detect_available_adapter)
    
    if [[ -n "$detected" ]]; then
        echo "Auto-detected adapter: $detected" >&2
        load_adapter "$detected"
        return 0
    fi
    
    echo "Error: No available adapter found" >&2
    return 1
}

# get_adapter_capabilities()
# Returns structured capabilities of the current adapter
# @return: JSON object with adapter capabilities
get_adapter_capabilities() {
    local supports
    supports=$(adapter_supports)
    
    local has_streaming="false"
    local has_tools="false"
    local has_vision="false"
    local has_local="false"
    local has_offline="false"
    
    [[ "$supports" == *"streaming"* ]] && has_streaming="true"
    [[ "$supports" == *"tools"* ]] && has_tools="true"
    [[ "$supports" == *"vision"* ]] && has_vision="true"
    [[ "$supports" == *"local"* ]] && has_local="true"
    [[ "$supports" == *"offline"* ]] && has_offline="true"
    
    cat << EOF
{
    "adapter": "$(adapter_id)",
    "name": "$(adapter_name)",
    "version": "$(adapter_version)",
    "capabilities": {
        "streaming": $has_streaming,
        "tools": $has_tools,
        "vision": $has_vision,
        "local": $has_local,
        "offline": $has_offline
    },
    "raw_supports": "$supports"
}
EOF
}

# compare_adapters()
# Compares capabilities of multiple adapters
# @param $@: adapter names to compare
# @return: Comparison table
compare_adapters() {
    local adapters=("$@")
    
    printf "%-15s | %-10s | %-10s | %-10s | %-10s | %-10s\n" \
        "Adapter" "Streaming" "Tools" "Vision" "Local" "Available"
    printf "%-15s-+-%-10s-+-%-10s-+-%-10s-+-%-10s-+-%-10s\n" \
        "---------------" "----------" "----------" "----------" "----------" "----------"
    
    for adapter in "${adapters[@]}"; do
        if load_adapter "$adapter" 2>/dev/null; then
            local supports
            supports=$(adapter_supports)
            local available="No"
            adapter_check &>/dev/null && available="Yes"
            
            local streaming="No"
            local tools="No"
            local vision="No"
            local local_run="No"
            
            [[ "$supports" == *"streaming"* ]] && streaming="Yes"
            [[ "$supports" == *"tools"* ]] && tools="Yes"
            [[ "$supports" == *"vision"* ]] && vision="Yes"
            [[ "$supports" == *"local"* ]] && local_run="Yes"
            
            printf "%-15s | %-10s | %-10s | %-10s | %-10s | %-10s\n" \
                "$adapter" "$streaming" "$tools" "$vision" "$local_run" "$available"
        fi
    done
}