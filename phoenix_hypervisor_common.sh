#!/bin/bash

# Phoenix Hypervisor Common Functions Library
# Provides shared functions for hypervisor scripts
# Version: 1.7.4
# Author: Assistant

# - Signal successful loading -
# This flag helps scripts that source this file know it's been loaded
export PHOENIX_HYPERVISOR_COMMON_LOADED=1

# - Logging Functions -
# Basic logging functions (can be overridden by sourcing script)
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2
}

# - Utility Functions -

retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        else
            log_warn "retry_command: Command failed (attempt $attempt/$max_attempts). Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "retry_command: Command failed after $max_attempts attempts."
    return 1
}

# --- Source NVIDIA LXC Common Functions ---
# Source NVIDIA-specific LXC functions from the standard location
# This makes functions like configure_lxc_gpu_passthrough available to common.sh functions.
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh
    log_info "phoenix_hypervisor_common.sh: Sourced NVIDIA LXC common functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_lxc_common_nvidia.sh
    log_warn "phoenix_hypervisor_common.sh: Sourced NVIDIA LXC functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
elif [[ -f "./phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source ./phoenix_hypervisor_lxc_common_nvidia.sh
    log_warn "phoenix_hypervisor_common.sh: Sourced NVIDIA LXC functions from current directory. Prefer standard locations."
else
    log_warn "phoenix_hypervisor_common.sh: NVIDIA LXC common functions file not found. GPU passthrough configuration will be skipped if needed."
fi
# --- END Source NVIDIA LXC Common Functions ---

# - Container Configuration Validation -
validate_container_config() {
    local container_id="$1"
    local container_config="$2"

    # Check if config is empty or null
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "validate_container_config: Container config is empty or null"
        return 1
    fi

    # Extract and validate key fields (example)
    local name
    name=$(echo "$container_config" | jq -r '.name')
    if [[ -z "$name" || "$name" == "null" ]]; then
        log_error "validate_container_config: Missing or invalid 'name' for container $container_id"
        return 1
    fi

    # GPU assignment validation
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    if ! validate_gpu_assignment "$container_id" "$gpu_assignment"; then
        log_error "validate_container_config: Invalid GPU assignment for container $container_id"
        return 1
    fi

    # Add more validation checks here as needed (e.g., template path exists, storage pool valid)
    # For now, assume basic structure from jq check and GPU validation is sufficient.
    return 0
}

# - Hypervisor Configuration Loading -
# Define the load_hypervisor_config function
# NOTE: This function is NO LONGER called automatically when the script is sourced.
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."
    log_info "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"

    # Check if jq is installed
    if ! command -v jq >/dev/null; then
        log_error "load_hypervisor_config: 'jq' command not found. Please install jq (apt install jq)."
        return 1
    fi

    # Ensure LXC_CONFIGS is a global associative array
    if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
        declare -gA LXC_CONFIGS
    elif [[ "$(declare -p LXC_CONFIGS)" != "declare -A"* ]]; then
        log_error "load_hypervisor_config: LXC_CONFIGS variable exists but is not an associative array."
        return 1
    fi

    # Load container IDs
    local container_ids
    # Use --raw-output-null-on-error to handle potential null values gracefully
    if ! container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>&1); then
        log_error "load_hypervisor_config: Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        log_error "load_hypervisor_config: jq output: $container_ids"
        return 1
    fi

    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi

    local count=0
    # Use process substitution to avoid subshell issues with variable modification
    while IFS= read -r id; do
        if [[ -n "$id" ]]; then
            local config_output
            config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>&1)
            if [[ $? -ne 0 ]]; then
                log_error "load_hypervisor_config: Failed to load config for container ID $id: $config_output"
                return 1
            fi
            LXC_CONFIGS["$id"]="$config_output"
            ((count++))
        fi
    done <<< "$container_ids"

    log_info "load_hypervisor_config: Loaded $count LXC configurations"
    return 0
}

# - GPU Assignment Handling -
# Functions to manage GPU assignments for containers

# Function to get the assigned GPUs for a container ID
# Returns the raw assignment string (e.g., "0", "1", "0,1", "none")
get_gpu_assignment() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID is required"
        return 1
    fi

    # Check if LXC_CONFIGS is loaded and contains the key
    if declare -p LXC_CONFIGS >/dev/null 2>&1 && [[ -n "${LXC_CONFIGS[$container_id]:-}" ]]; then
        # Extract gpu_assignment from the stored JSON string for the container
        echo "$LXC_CONFIGS[$container_id]" | jq -r '.gpu_assignment // "none"'
    else
        # Fallback: Try to read directly from the config file if LXC_CONFIGS isn't available
        # This is useful for scripts that run independently (like create_lxc)
        if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jq >/dev/null; then
            jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE"
        else
            # If we can't determine, default to none
            echo "none"
        fi
    fi
}

# Function to validate a GPU assignment string for a container
# Checks if the assigned GPUs are available and correctly formatted
validate_gpu_assignment() {
    local container_id="$1"
    local gpu_assignment="$2"

    # If no assignment or explicitly none, it's valid
    if [[ -z "$gpu_assignment" || "$gpu_assignment" == "none" ]]; then
        return 0
    fi

    # Basic format check (comma-separated numbers)
    if [[ ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "validate_gpu_assignment: Invalid GPU assignment format for container $container_id: '$gpu_assignment'. Expected comma-separated GPU indices (e.g., '0', '1', '0,1') or 'none'."
        return 1
    fi

    # Check if assigned GPUs actually exist on the host
    # This requires detecting host GPUs first (outside scope of this validation function)
    # For now, assume basic format check is sufficient for validation purposes.
    # A more robust check would compare against a list of available host GPU indices.

    return 0
}

# - LXC Container Management -
# Functions to create, configure, and manage LXC containers

# Function to create and perform basic configuration of an LXC container
# Takes a container ID and its JSON configuration string as input
create_lxc_container() {
    local lxc_id="$1"
    local container_config="$2"

    # Validate input arguments
    if [[ -z "$lxc_id" || -z "$container_config" ]]; then
        log_error "create_lxc_container: Container ID and configuration are required"
        return 1
    fi

    # Validate the container configuration using the dedicated function
    if ! validate_container_config "$lxc_id" "$container_config"; then
        log_error "create_lxc_container: Configuration validation failed for container $lxc_id"
        return 1
    fi

    # Extract configuration parameters using jq
    local name
    name=$(echo "$container_config" | jq -r '.name')
    local memory_mb
    memory_mb=$(echo "$container_config" | jq -r '.memory_mb')
    local cores
    cores=$(echo "$container_config" | jq -r '.cores')
    local template
    template=$(echo "$container_config" | jq -r '.template')
    local storage_pool
    storage_pool=$(echo "$container_config" | jq -r '.storage_pool')
    local storage_size_gb
    storage_size_gb=$(echo "$container_config" | jq -r '.storage_size_gb')
    local network_config
    network_config=$(echo "$container_config" | jq -r '.network_config')
    local features
    features=$(echo "$container_config" | jq -r '.features')
    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')

    # --- Parse network_config ---
    # Expected format: "IP/CIDR,Gateway,DNS"
    # e.g., "10.0.0.111/24,10.0.0.1,8.8.8.8"
    local ip_cidr gateway dns
    IFS=',' read -r ip_cidr gateway dns <<< "$network_config"

    # Validate basic format (check if ip_cidr looks like IP/CIDR)
    if [[ ! "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log_error "Invalid IP/CIDR format in network_config: $ip_cidr"
        return 1
    fi
    if [[ ! "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Gateway format in network_config: $gateway"
        return 1
    fi
    if [[ ! "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid DNS format in network_config: $dns"
        return 1
    fi
    # --- End Parse network_config ---

    # Validate required parameters
    if [[ -z "$name" || "$name" == "null" ]]; then
        log_error "create_lxc_container: Missing 'name' for container $lxc_id"
        return 1
    fi
    if [[ -z "$memory_mb" || "$memory_mb" == "null" ]]; then
        log_error "create_lxc_container: Missing 'memory_mb' for container $lxc_id"
        return 1
    fi
    if [[ -z "$cores" || "$cores" == "null" ]]; then
        log_error "create_lxc_container: Missing 'cores' for container $lxc_id"
        return 1
    fi
    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "create_lxc_container: Missing 'template' for container $lxc_id"
        return 1
    fi
    if [[ -z "$storage_pool" || "$storage_pool" == "null" ]]; then
        log_error "create_lxc_container: Missing 'storage_pool' for container $lxc_id"
        return 1
    fi
    if [[ -z "$storage_size_gb" || "$storage_size_gb" == "null" ]]; then
        log_error "create_lxc_container: Missing 'storage_size_gb' for container $lxc_id"
        return 1
    fi
    if [[ -z "$network_config" || "$network_config" == "null" ]]; then
        log_error "create_lxc_container: Missing 'network_config' for container $lxc_id"
        return 1
    fi
    if [[ -z "$features" || "$features" == "null" ]]; then
        log_error "create_lxc_container: Missing 'features' for container $lxc_id"
        return 1
    fi

    # Convert storage size to integer GiB for pct
    local storage_size="${storage_size_gb}"

    # Create LXC container
    log_info "Creating container $lxc_id ($name)..."
    if ! pct create "$lxc_id" "$template" \
        --hostname "$name" \
        --memory "$memory_mb" \
        --cores "$cores" \
        --storage "$storage_pool" \
        --rootfs "$storage_size" \
        --net0 "name=eth0,bridge=vmbr0,ip=$ip_cidr,gw=$gateway" \
        --nameserver "$dns" \
        --features "$features"; then
        log_error "Failed to create LXC container $lxc_id"
        return 1
    fi

    # --- Configure GPU Passthrough ---
    # Delegate GPU configuration to a dedicated function if an assignment exists
    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        # --- DEBUG GPU FUNCTION CHECK ---
        log_info "DEBUG: Checking for configure_lxc_gpu_passthrough function..."
        if declare -f configure_lxc_gpu_passthrough > /dev/null 2>&1; then
            log_info "DEBUG: configure_lxc_gpu_passthrough function found."
        else
            log_warn "DEBUG: configure_lxc_gpu_passthrough function NOT found."
            # List available functions starting with 'configure' for debugging
            log_info "DEBUG: Available 'configure' functions: $(declare -F | grep configure || echo 'None found')"
            # Check if the library was sourced by looking for a unique function or variable
            if declare -f install_nvidia_driver_in_container > /dev/null 2>&1; then
                 log_info "DEBUG: install_nvidia_driver_in_container found, NVIDIA library seems sourced."
            else
                 log_warn "DEBUG: install_nvidia_driver_in_container NOT found, NVIDIA library might not be fully sourced."
            fi
        fi
        # --- END DEBUG GPU FUNCTION CHECK ---
        # Assuming a function configure_lxc_gpu_passthrough exists in this or another sourced file
        if declare -f configure_lxc_gpu_passthrough > /dev/null; then
            if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
                log_error "Failed to configure GPU passthrough for container $lxc_id"
                # Decide if this is a fatal error for container creation
                # For now, let's warn but continue, assuming manual fix is possible
                log_warn "Container $lxc_id created but GPU passthrough might be incomplete."
            else
                 log_info "GPU passthrough configured successfully for container $lxc_id"
            fi
        else
            log_warn "GPU passthrough function 'configure_lxc_gpu_passthrough' not found. Skipping GPU setup."
            log_warn "Container $lxc_id created but GPU passthrough will need manual configuration."
        fi
    else
        log_info "No GPU assignment for container $lxc_id, skipping GPU passthrough configuration."
    fi

    log_info "Container $lxc_id ($name) created successfully."
    return 0
}

# - REMOVED -
# The block that automatically called load_hypervisor_config during sourcing
# has been removed. The main script (phoenix_establish_hypervisor.sh) is now
# responsible for calling it explicitly.
# - END REMOVED -