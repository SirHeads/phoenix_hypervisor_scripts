#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Argument Parsing ---
# Check if we have a container ID argument
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Usage: $0 <container_id>" >&2
    exit 1
fi
container_id="$1"

# Validate that the container ID is numeric
if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid container ID: $container_id" >&2
    exit 1
fi
# --- END Argument Parsing ---

echo "[DEBUG] Script started. Checking jq availability..." >&2
# --- Enhanced jq Check ---
# Ensure jq is installed before proceeding
echo "[DEBUG] About to run 'command -v jq'..." >&2
if ! command -v jq >/dev/null 2>&1; then
    echo "[DEBUG] 'command -v jq' failed. PATH=$PATH, which jq=$(which jq 2>&1)" >&2
    echo "[ERROR] 'jq' command not found. Please install jq (apt install jq)." >&2
    exit 1
else
    echo "[DEBUG] 'command -v jq' succeeded." >&2
fi
echo "[DEBUG] Past jq check." >&2

# --- Load Configuration ---
# Load configuration for this specific container directly from JSON file
container_config=""
if command -v jq > /dev/null 2>&1; then
    container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        echo "[ERROR] No configuration found for container ID $container_id in $PHOENIX_LXC_CONFIG_FILE" >&2
        exit 1
    fi
else
    echo "[ERROR] 'jq' command not found. Please install jq (apt install jq)." >&2
    exit 1
fi

# Extract and validate template from JSON
template_path=$(echo "$container_config" | jq -r '.template')
if [[ -z "$template_path" || "$template_path" == "null" ]]; then
    echo "[ERROR] No template specified in configuration for container $container_id" >&2
    exit 1
fi
echo "[INFO] Using template: $template_path for container $container_id" >&2

# Validate template file existence
if ! test -f "$template_path"; then
    echo "[ERROR] Template file not found: $template_path" >&2
    exit 1
fi
echo "[DEBUG] Template file validated: $template_path" >&2

# --- Enhanced Sourcing of Dependencies ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
    else
        echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
        exit 1
    fi
fi

# Source common functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced common functions from current directory. Prefer standard locations." >&2
else
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2; }
    log_warn "phoenix_hypervisor_create_lxc.sh: Common functions file not found in standard locations. Using minimal logging."
fi

# --- Call the central creation function ---
if declare -f create_lxc_container > /dev/null; then
    if create_lxc_container "$container_id" "$container_config"; then
        log_info "phoenix_hypervisor_create_lxc.sh: Container $container_id created and configured successfully."

        # Try to get container codename for informational purposes, but don't fail if it's not available
        container_codename=$(pct exec "$container_id" -- bash -c "lsb_release -cs 2>/dev/null || echo 'unknown'")
        if [[ "$container_codename" != "unknown" ]]; then
            log_info "phoenix_hypervisor_create_lxc.sh: Container codename detected: $container_codename (template: $(echo "$container_config" | jq -r '.template'))"
        else
            log_info "phoenix_hypervisor_create_lxc.sh: Container codename not immediately available, continuing with setup"
        fi

        # Validate init system
        init_system=$(pct exec "$container_id" -- bash -c "ps -p 1 -o comm=" 2>/dev/null)
        if [[ $? -ne 0 || -z "$init_system" ]]; then
            log_error "phoenix_hypervisor_create_lxc.sh: Failed to retrieve init system for container $container_id."
            exit 1
        fi
        if [[ "$init_system" != "systemd" ]]; then
            log_error "phoenix_hypervisor_create_lxc.sh: Non-systemd init detected: $init_system. Docker requires systemd."
            exit 1
        fi
        log_info "phoenix_hypervisor_create_lxc.sh: Container init system: $init_system"

        log_info "phoenix_hypervisor_create_lxc.sh: Starting container $container_id..."
        if ! retry_command 3 10 pct start "$container_id"; then
            log_error "phoenix_hypervisor_create_lxc.sh: Failed to start container $container_id."
            exit 1
        fi
        log_info "phoenix_hypervisor_create_lxc.sh: Container $container_id started successfully."

        exit 0
    else
        log_error "phoenix_hypervisor_create_lxc.sh: Failed to create or configure container $container_id."
        exit 1
    fi
else
    if declare -f log_error > /dev/null 2>&1; then
        log_error "phoenix_hypervisor_create_lxc.sh: Required function 'create_lxc_container' not found in common.sh."
    else
        echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Required function 'create_lxc_container' not found in common.sh." >&2
    fi
    exit 1
fi