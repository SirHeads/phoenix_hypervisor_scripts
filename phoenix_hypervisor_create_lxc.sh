#!/bin/bash
# Phoenix Hypervisor LXC Container Creation Script
# Creates and configures LXC containers for the Phoenix Hypervisor
# Prerequisites:
# - Proxmox VE environment
# - phoenix_hypervisor_common.sh sourced
# - phoenix_hypervisor_config.sh sourced
# Usage: ./phoenix_hypervisor_create_lxc.sh <lxc_id>
# Version: 1.7.4
# Author: Assistant

set -euo pipefail

# Source configuration first
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    echo "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh"
    exit 1
fi

# Source common functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
else
    echo "Common functions file not found: /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
    exit 1
fi

# --- Enhanced User Experience Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2
}

# --- Enhanced Container Creation ---
create_container() {
    local lxc_id="$1"
    
    if ! validate_lxc_id "$lxc_id"; then
        log_error "Invalid container ID format: $lxc_id"
        return 1
    fi
    
    log_info "Starting Phoenix Hypervisor container creation..."
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR CONTAINER CREATION"
    echo "==============================================="
    
    # Check if container already exists
    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_info "Container $lxc_id already exists, skipping creation..."
        return 0
    fi
    
    # Get configuration for this container
    local config
    config=$(jq -r ".lxc_configs.\"$lxc_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    if [[ "$config" == "null" ]]; then
        log_error "No configuration found for container ID: $lxc_id"
        return 1
    fi
    
    # Extract configuration parameters
    local name
    name=$(echo "$config" | jq -r '.name // "default"')
    
    local memory_mb
    memory_mb=$(echo "$config" | jq -r '.memory_mb // $DEFAULT_LXC_MEMORY_MB')
    
    local cores
    cores=$(echo "$config" | jq -r '.cores // $DEFAULT_LXC_CORES')
    
    local template
    template=$(echo "$config" | jq -r '.template // ""')
    
    local storage_pool
    storage_pool=$(echo "$config" | jq -r '.storage_pool // $DEFAULT_LXC_STORAGE_POOL')
    
    local storage_size_gb
    storage_size_gb=$(echo "$config" | jq -r '.storage_size_gb // $DEFAULT_LXC_STORAGE_SIZE_GB')
    
    local network_config
    network_config=$(echo "$config" | jq -r '.network_config // $DEFAULT_LXC_NETWORK_CONFIG')
    
    local features
    features=$(echo "$config" | jq -r '.features // ""')
    
    # Create the container
    log_info "Creating container $lxc_id with name '$name'"
    
    # Set up LXC configuration parameters
    local create_args=()
    create_args+=("--vmtype" "kvm")
    create_args+=("--ostype" "ubuntu")
    create_args+=("--memory" "$memory_mb")
    create_args+=("--cores" "$cores")
    create_args+=("--net0" "name=eth0,bridge=vmbr0,firewall=1")
    create_args+=("--rootfs" "$storage_pool:$storage_size_gb")
    create_args+=("--hostname" "$name")
    
    # Add features if specified
    if [[ -n "$features" ]]; then
        # Process features string to add them properly
        local feature_list=()
        IFS=',' read -ra feature_array <<< "$features"
        for feature in "${feature_array[@]}"; do
            case "$feature" in
                "nesting")
                    create_args+=("--features" "nesting=1")
                    ;;
                "keyctl")
                    create_args+=("--features" "keyctl=1")
                    ;;
            esac
        done
    fi
    
    # Create the container using pct
    log_info "Creating LXC container $lxc_id..."
    if ! pct create "$lxc_id" "${create_args[@]}" >/dev/null 2>&1; then
        log_error "Failed to create container $lxc_id"
        return 1
    fi
    
    log_info "Container $lxc_id created successfully"
    
    # Configure additional settings
    if [[ -n "$network_config" ]]; then
        log_info "Configuring network for container $lxc_id..."
        # Network configuration would go here
    fi
    
    return 0
}

# --- Enhanced Main Function ---
main() {
    local lxc_id="$1"
    
    if [[ -z "$lxc_id" ]]; then
        log_error "No LXC ID provided. Usage: $0 <lxc_id>"
        exit 1
    fi
    
    log_info "Processing container $lxc_id..."
    
    # Validate container ID format
    if ! validate_lxc_id "$lxc_id"; then
        log_error "Invalid container ID format: $lxc_id"
        exit 1
    fi
    
    # Create the container
    if create_container "$lxc_id"; then
        log_info "Container $lxc_id created successfully"
        exit 0
    else
        log_error "Failed to create container $lxc_id"
        exit 1
    fi
}

# --- Execute Main Function ---
main "$@"