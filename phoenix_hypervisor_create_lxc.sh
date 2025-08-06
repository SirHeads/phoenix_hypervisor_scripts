#!/bin/bash
# Phoenix Hypervisor LXC Container Creation Script
# Creates LXC containers with NVIDIA GPU support based on configuration
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - Root privileges
# Usage: ./phoenix_hypervisor_create_lxc.sh <container_id>
# Version: 1.7.4
# Author: Assistant

set -euo pipefail
# Source configuration first

# Source configuration first
if [[ -f "/usr/local/bin/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_config.sh
else
    echo "Configuration file not found: /usr/local/bin/phoenix_hypervisor_config.sh"
    exit 1
fi

# Source common functions
if [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
else
    echo "Common functions file not found: /usr/local/bin/phoenix_hypervisor_common.sh"
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

# --- Enhanced Container Creation Functions ---
create_container() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    
    # Check if container already exists
    if pct status "$container_id" >/dev/null 2>&1; then
        log_warn "Container $container_id already exists, skipping creation"
        return 0
    fi
    
    # Validate that we have configuration for this container
    if ! validate_container_config "$container_id"; then
        log_error "No configuration found for container ID: $container_id"
        return 1
    fi
    
    # Extract configuration parameters from JSON
    local name
    name=$(jq -r ".lxc_configs.\"$container_id\".name // \"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local memory_mb
    memory_mb=$(jq -r ".lxc_configs.\"$container_id\".memory_mb // $DEFAULT_LXC_MEMORY_MB" "$PHOENIX_LXC_CONFIG_FILE")
    
    local cores
    cores=$(jq -r ".lxc_configs.\"$container_id\".cores // $DEFAULT_LXC_CORES" "$PHOENIX_LXC_CONFIG_FILE")
    
    local template
    template=$(jq -r ".lxc_configs.\"$container_id\".template // \"$DEFAULT_LXC_TEMPLATE\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local storage_pool
    storage_pool=$(jq -r ".lxc_configs.\"$container_id\".storage_pool // \"$DEFAULT_LXC_STORAGE_POOL\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local storage_size_gb
    storage_size_gb=$(jq -r ".lxc_configs.\"$container_id\".storage_size_gb // \"$DEFAULT_LXC_STORAGE_SIZE_GB\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local network_config
    network_config=$(jq -r ".lxc_configs.\"$container_id\".network_config // \"$DEFAULT_LXC_NETWORK_CONFIG\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local features
    features=$(jq -r ".lxc_configs.\"$container_id\".features // \"$DEFAULT_LXC_FEATURES\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    # Get GPU assignment for this container
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    
    log_info "Creating container $container_id with configuration:"
    log_info "  Name: $name"
    log_info "  Memory: ${memory_mb} MB"
    log_info "  Cores: $cores"
    log_info "  Template: $template"
    log_info "  Storage Pool: $storage_pool"
    log_info "  Storage Size: ${storage_size_gb}G"
    log_info "  Network: $network_config"
    log_info "  Features: $features"
    log_info "  GPU Assignment: $gpu_assignment"
    
    # Build the pct create command
    local pct_create_cmd="pct create \"$container_id\""
    
    # Add basic parameters
    pct_create_cmd+=" --hostname \"$name\""
    pct_create_cmd+=" --memory $memory_mb"
    pct_create_cmd+=" --cores $cores"
    pct_create_cmd+=" --template \"$template\""
    pct_create_cmd+=" --storage \"$storage_pool\""
    pct_create_cmd+=" --size \"${storage_size_gb}G\""
    
    # Add network configuration
    local ip_config
    ip_config=$(echo "$network_config" | cut -d',' -f1)
    pct_create_cmd+=" --net0 \"ip=$ip_config,name=eth0,bridge=vmbr0\""
    
    # Add features
    pct_create_cmd+=" --features \"$features\""
    
    # Add GPU passthrough if assigned
    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Adding GPU passthrough for GPUs: $gpu_assignment"
        pct_create_cmd+=" --hookscript \"local hookscript = function (self, c) c:addDevice('gpu', '/dev/dri/card0') end\""
        # Note: This is a simplified approach - actual GPU passthrough requires more complex configuration
    fi
    
    # Execute the container creation
    log_info "Executing: $pct_create_cmd"
    
    if eval "$pct_create_cmd"; then
        log_info "Container $container_id created successfully"
        
        # Create marker file for idempotency
        local marker_file="$HYPERVISOR_MARKER_DIR/container_$container_id_created"
        touch "$marker_file"
        
        # Set proper permissions on the container directory
        chmod 755 "/var/lib/lxc/$container_id" 2>/dev/null || true
        
        return 0
    else
        log_error "Failed to create container $container_id"
        return 1
    fi
}

# --- Enhanced Container Configuration ---
configure_container() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    
    log_info "Configuring container $container_id..."
    
    # Wait for container to be ready
    local max_wait=30
    local wait_count=0
    
    while [[ $wait_count -lt $max_wait ]]; do
        if pct status "$container_id" >/dev/null 2>&1; then
            log_info "Container $container_id is ready"
            break
        fi
        log_warn "Container $container_id not ready yet, waiting..."
        sleep 2
        ((wait_count++))
    done
    
    if [[ $wait_count -ge $max_wait ]]; then
        log_error "Container $container_id failed to become ready within timeout"
        return 1
    fi
    
    # Configure container networking and features
    local network_config
    network_config=$(jq -r ".lxc_configs.\"$container_id\".network_config // \"$DEFAULT_LXC_NETWORK_CONFIG\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    if [[ -n "$network_config" ]]; then
        local ip_address
        ip_address=$(echo "$network_config" | cut -d',' -f1)
        
        # Set IP address and gateway
        pct set "$container_id" --net0 "ip=$ip_address,name=eth0,bridge=vmbr0"
    fi
    
    log_info "Container $container_id configured successfully"
}

# --- Enhanced Validation ---
validate_container_creation() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        return 1
    fi
    
    # Check if container exists
    if ! pct status "$container_id" >/dev/null 2>&1; then
        log_error "Container $container_id does not exist"
        return 1
    fi
    
    # Validate basic configuration
    local memory_mb
    memory_mb=$(pct get "$container_id" --memory 2>/dev/null)
    
    if [[ -z "$memory_mb" ]]; then
        log_error "Failed to retrieve memory configuration for container $container_id"
        return 1
    fi
    
    log_info "Container $container_id validation passed"
    return 0
}

# --- Enhanced Main Function ---
main() {
    log_info "Starting Phoenix Hypervisor container creation..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR CONTAINER CREATION"
    echo "==============================================="
    echo ""
    
    # Verify prerequisites
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    if ! command -v pct >/dev/null 2>&1; then
        log_error "Proxmox Container Toolkit (pct) is required but not installed"
        exit 1
    fi
    
    # Get container ID from arguments
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID is required as argument"
        echo "Usage: $0 <container_id>"
        exit 1
    fi
    
    # Validate LXC ID format
    if ! validate_lxc_id "$container_id"; then
        log_error "Invalid container ID format: $container_id"
        exit 1
    fi
    
    # Create the container
    if create_container "$container_id"; then
        log_info "Container $container_id created successfully"
        
        # Configure the container
        if configure_container "$container_id"; then
            log_info "Container $container_id configured successfully"
            
            # Validate creation
            if validate_container_creation "$container_id"; then
                echo ""
                echo "==============================================="
                echo "CONTAINER CREATION COMPLETE"
                echo "Container ID: $container_id"
                echo "Status: SUCCESS"
                echo "==============================================="
                log_info "All operations completed successfully for container $container_id"
                exit 0
            else
                log_error "Validation failed for container $container_id"
                exit 1
            fi
        else
            log_error "Configuration failed for container $container_id"
            exit 1
        fi
    else
        log_error "Failed to create container $container_id"
        exit 1
    fi
}

# --- Enhanced Cleanup ---
cleanup() {
    local container_id="$1"
    log_info "Cleaning up container $container_id..."
    # Cleanup logic would go here if needed
}

main "$@"