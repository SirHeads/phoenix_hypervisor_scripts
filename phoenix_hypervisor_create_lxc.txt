#!/bin/bash
# Phoenix Hypervisor LXC Creation Script
# Creates a single LXC container based on provided arguments.
# Configures GPU passthrough, networking, and storage.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - /usr/local/etc/phoenix_lxc_configs.json configured with required fields
# - NVIDIA GPU(s) validated on the host
# Usage: ./phoenix_hypervisor_create_lxc.sh <lxc_id>
# Version: 1.7.3
# Author: Assistant
set -euo pipefail

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

prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

# --- Enhanced Logging Function ---
log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: HYPERVISOR_LOGFILE variable not set" >&2
        exit 1
    fi
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$HYPERVISOR_LOGFILE")
    mkdir -p "$log_dir" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to create log directory: $log_dir" >&2; exit 1; }
    # Log to file via fd 4
    if [[ ! -e /proc/self/fd/4 ]]; then
        exec 4>>"$HYPERVISOR_LOGFILE"
        chmod 600 "$HYPERVISOR_LOGFILE" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $0: Failed to set permissions on $HYPERVISOR_LOGFILE" >&2; }
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&4
    # Output INFO, WARN, ERROR to stderr for terminal visibility
    if [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&2
    fi
}

# --- Enhanced Main Function ---
main() {
    # Check if we have the required arguments
    if [[ $# -lt 1 ]]; then
        log_error "Usage: $0 <lxc_id>"
        echo ""
        echo "Example: $0 901"
        echo ""
        exit 1
    fi
    
    local lxc_id="$1"
    
    # Validate LXC ID
    if ! validate_lxc_id "$lxc_id"; then
        log_error "Invalid LXC ID format: $lxc_id"
        exit 1
    fi
    
    log_info "Starting LXC container creation for ID: $lxc_id"
    echo ""
    echo "==============================================="
    echo "CREATING LXC CONTAINER $lxc_id"
    echo "==============================================="
    echo ""
    
    # Check if already created
    local marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_created"
    if is_script_completed "$marker_file"; then
        log_info "LXC container $lxc_id already exists. Skipping creation."
        echo "Container $lxc_id already exists - skipping creation."
        echo ""
        exit 0
    fi
    
    # Confirm with user before proceeding
    read -p "Do you want to create LXC container $lxc_id? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Creation of LXC container $lxc_id cancelled by user."
        echo ""
        echo "Container creation cancelled for $lxc_id."
        echo ""
        exit 0
    fi
    
    echo ""
    echo "Creating container $lxc_id..."
    echo "----------------------------"
    
    # Load configuration for this specific container
    log_info "Loading configuration for LXC container $lxc_id..."
    local config_data
    if [[ -n "${LXC_CONFIGS[$lxc_id]:-}" ]]; then
        config_data="${LXC_CONFIGS[$lxc_id]}"
        log_info "Configuration loaded for LXC container $lxc_id"
    else
        log_error "No configuration found for LXC container $lxc_id"
        exit 1
    fi
    
    # Extract container details from JSON
    local name
    name=$(echo "$config_data" | jq -r '.name // empty')
    
    local memory_mb
    memory_mb=$(echo "$config_data" | jq -r '.memory_mb // empty')
    if [[ -z "$memory_mb" || "$memory_mb" == "null" ]]; then
        memory_mb="$DEFAULT_LXC_MEMORY_MB"
    fi
    
    local cores
    cores=$(echo "$config_data" | jq -r '.cores // empty')
    if [[ -z "$cores" || "$cores" == "null" ]]; then
        cores="$DEFAULT_LXC_CORES"
    fi
    
    local template
    template=$(echo "$config_data" | jq -r '.template // empty')
    if [[ -z "$template" || "$template" == "null" ]]; then
        template="$DEFAULT_LXC_TEMPLATE"
    fi
    
    local storage_pool
    storage_pool=$(echo "$config_data" | jq -r '.storage_pool // empty')
    if [[ -z "$storage_pool" || "$storage_pool" == "null" ]]; then
        storage_pool="$DEFAULT_LXC_STORAGE_POOL"
    fi
    
    local storage_size_gb
    storage_size_gb=$(echo "$config_data" | jq -r '.storage_size_gb // empty')
    if [[ -z "$storage_size_gb" || "$storage_size_gb" == "null" ]]; then
        storage_size_gb="$DEFAULT_LXC_STORAGE_SIZE_GB"
    fi
    
    local network_config
    network_config=$(echo "$config_data" | jq -r '.network_config // empty')
    if [[ -z "$network_config" || "$network_config" == "null" ]]; then
        network_config="$DEFAULT_LXC_NETWORK_CONFIG"
    fi
    
    local features
    features=$(echo "$config_data" | jq -r '.features // empty')
    if [[ -z "$features" || "$features" == "null" ]]; then
        features="$DEFAULT_LXC_FEATURES"
    fi
    
    # Show container configuration
    echo ""
    echo "Container Configuration:"
    echo "------------------------"
    echo "ID: $lxc_id"
    echo "Name: $name"
    echo "Memory: ${memory_mb} MB"
    echo "CPU Cores: $cores"
    echo "Template: $template"
    echo "Storage Pool: $storage_pool"
    echo "Storage Size: ${storage_size_gb} GB"
    echo "Network Config: $network_config"
    echo "Features: $features"
    echo ""
    
    # Validate storage pool exists
    log_info "Validating storage pool: $storage_pool"
    if ! pvesm status | grep -q "^$storage_pool.*active.*1"; then
        log_error "Storage pool $storage_pool is not active or does not exist"
        exit 1
    fi
    
    # Validate template exists
    log_info "Validating template: $template"
    if [[ ! -f "$template" ]]; then
        log_warn "Template file not found: $template"
        echo "Warning: Template file not found. Container creation may fail."
    fi
    
    # Check if container already exists
    log_info "Checking if container $lxc_id already exists..."
    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_warn "Container $lxc_id already exists"
        echo ""
        read -p "Do you want to recreate this container? (yes/no): " recreate_confirm
        if [[ "$recreate_confirm" != "yes" ]]; then
            log_info "Skipping recreation of existing container $lxc_id"
            echo "Container $lxc_id not recreated."
            echo ""
            exit 0
        fi
        
        # Stop and destroy existing container
        echo "Stopping existing container $lxc_id..."
        pct stop "$lxc_id" >/dev/null 2>&1 || true
        echo "Destroying existing container $lxc_id..."
        pct destroy "$lxc_id" --force >/dev/null 2>&1 || true
    fi
    
    # Create LXC container with progress indicators
    log_info "Creating LXC container $lxc_id..."
    
    echo "Creating LXC container with the following settings:"
    echo "- ID: $lxc_id"
    echo "- Name: $name"
    echo "- Memory: ${memory_mb} MB"
    echo "- Cores: $cores"
    echo "- Template: $template"
    echo "- Storage Pool: $storage_pool"
    echo "- Storage Size: ${storage_size_gb} GB"
    echo ""
    
    # Create the container with a detailed command
    local create_cmd="pct create $lxc_id \
        --ostemplate \"$template\" \
        --memory $memory_mb \
        --cores $cores \
        --hostname \"$name\" \
        --net0 net0 \
        --features \"$features\" \
        --storage \"$storage_pool\" \
        --size \"${storage_size_gb}G\""
    
    echo "Executing command: $create_cmd"
    
    # Execute container creation
    if ! retry_command 3 10 "$create_cmd"; then
        log_error "Failed to create LXC container $lxc_id"
        exit 1
    fi
    
    log_info "Container $lxc_id created successfully"
    
    # Configure networking
    echo ""
    log_info "Configuring network settings for container $lxc_id..."
    
    local net_config="net0=name=eth0,bridge=vmbr0,gw=$network_config"
    if ! pct set "$lxc_id" --net0 "$net_config"; then
        log_warn "Failed to configure network for container $lxc_id"
    else
        log_info "Network configuration applied to container $lxc_id"
    fi
    
    # Configure GPU passthrough if needed
    local gpu_assignment
    gpu_assignment="${PHOENIX_GPU_ASSIGNMENTS[$lxc_id]:-}"
    
    if [[ -n "$gpu_assignment" ]]; then
        echo ""
        log_info "Configuring GPU passthrough for container $lxc_id..."
        
        # Validate GPU assignment
        if ! validate_gpu_assignment "$lxc_id" "$gpu_assignment"; then
            log_warn "GPU assignment validation failed for container $lxc_id"
            echo "Skipping GPU passthrough configuration."
        else
            if configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
                log_info "GPU passthrough configured for container $lxc_id"
            else
                log_warn "Failed to configure GPU passthrough for container $lxc_id"
            fi
        fi
    else
        log_info "No GPU assignment found for container $lxc_id, skipping GPU configuration"
    fi
    
    # Start the container
    echo ""
    log_info "Starting container $lxc_id..."
    
    if ! pct start "$lxc_id"; then
        log_error "Failed to start LXC container $lxc_id"
        exit 1
    fi
    
    # Wait for container to fully start
    echo "Waiting for container $lxc_id to fully start..."
    sleep 5
    
    # Verify container is running
    if pct status "$lxc_id" | grep -q "status: running"; then
        log_info "Container $lxc_id is now running"
        
        # Show container information
        echo ""
        echo "Container Information:"
        echo "----------------------"
        echo "ID: $lxc_id"
        echo "Status: Running"
        echo "Name: $name"
        echo "Memory: ${memory_mb} MB"
        echo "CPU Cores: $cores"
        echo ""
        
        # Show network information
        local ip_address
        ip_address=$(pct exec "$lxc_id" -- ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
        if [[ -n "$ip_address" ]]; then
            echo "IP Address: $ip_address"
        else
            echo "IP Address: Not available (container may still be initializing)"
        fi
        
    else
        log_warn "Container $lxc_id may not have started properly"
    fi
    
    # Mark completion
    mark_script_completed "$marker_file"
    log_info "LXC container $lxc_id creation completed successfully"
    
    echo ""
    echo "==============================================="
    echo "CONTAINER CREATION COMPLETED SUCCESSFULLY!"
    echo "==============================================="
    echo ""
}

# --- Enhanced Validation Functions ---
validate_lxc_id() {
    local lxc_id="$1"
    
    # Check if it's a valid numeric ID
    if ! [[ "$lxc_id" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Check if ID is in valid range (typically 100-999 for containers)
    if [[ "$lxc_id" -lt 100 ]] || [[ "$lxc_id" -gt 999 ]]; then
        log_warn "LXC ID $lxc_id is outside typical range (100-999)"
    fi
    
    return 0
}

validate_gpu_assignment() {
    local lxc_id="$1"
    local gpu_indices="$2"
    
    log_info "Validating GPU assignment for container $lxc_id: $gpu_indices"
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "nvidia-smi not found. Cannot validate GPU assignment."
        return 1
    fi
    
    # Get number of GPUs
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
    
    if [[ "$gpu_count" -eq 0 ]]; then
        log_warn "No NVIDIA GPUs detected. Cannot validate GPU assignment."
        return 1
    fi
    
    # Validate each GPU index
    IFS=',' read -ra indices <<< "$gpu_indices"
    for index in "${indices[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_warn "Invalid GPU index: $index"
            return 1
        fi
        
        if [[ "$index" -ge "$gpu_count" ]]; then
            log_warn "GPU index $index exceeds available GPUs ($gpu_count)"
            return 1
        fi
    done
    
    log_info "GPU assignment validation passed for container $lxc_id: $gpu_indices"
    return 0
}

# --- Enhanced GPU Passthrough Configuration ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2"
    
    log_info "Configuring GPU passthrough for LXC container $lxc_id using indices: '$gpu_indices'"
    
    # Check if we have the required tools
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "nvidia-smi not found. Cannot configure GPU passthrough."
        return 1
    fi
    
    # Get GPU details
    local gpu_details=()
    IFS=',' read -ra indices <<< "$gpu_indices"
    for index in "${indices[@]}"; do
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits -i "$index" | tr -d ' ')
        gpu_details+=("$gpu_name")
    done
    
    echo "Configuring GPU passthrough for container $lxc_id with GPUs: ${gpu_details[*]}"
    
    # Add GPU configuration to LXC config
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "LXC config file not found: $config_file"
        return 1
    fi
    
    # Add GPU device mappings
    local gpu_config=""
    for index in ${indices[@]}; do
        # For each GPU, we need to add it to the container's device configuration
        gpu_config="$gpu_config\nlxc.cgroup2.devices.allow: c 195:$index rwm"
    done
    
    # Write to config file
    echo -e "$gpu_config" >> "$config_file"
    
    log_info "GPU passthrough configured for container $lxc_id with indices: $gpu_indices"
    return 0
}

# --- Enhanced Retry Function ---
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd="$*"
    
    log_info "Executing command with retries (max $max_attempts attempts): $cmd"
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Attempt $attempt/$max_attempts: $cmd" >&2
        eval "$cmd"
        if [[ $? -eq 0 ]]; then
            log_info "Command succeeded on attempt $attempt"
            return 0
        fi
        log_warn "Command failed (attempt $attempt/$max_attempts): $cmd"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Command failed, retrying in $delay seconds..." >&2
        sleep "$delay"
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# --- Enhanced Marker Functions ---
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        grep -Fxq "$(basename "$0")" "$marker_file" 2>/dev/null
        return $?
    fi
    return 1
}

mark_script_completed() {
    local marker_file="$1"
    local script_name=$(basename "$0")
    
    # Ensure marker directory exists
    mkdir -p "$(dirname "$marker_file")"
    
    # Add to marker file
    echo "$script_name" >> "$marker_file"
    chmod 600 "$marker_file"
    
    log_info "Marked script $script_name as completed for container $lxc_id"
}

# --- Enhanced Error Handling ---
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# --- Execute Main Function ---
main "$@"