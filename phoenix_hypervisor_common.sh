#!/bin/bash
# Common functions for Phoenix Hypervisor
# Provides reusable functions for logging, GPU handling, LXC creation, etc.
# Version: 1.7.4
# Author: Assistant
# --- Logging Functions ---
log_message() {
    local level="$1"
    local message="$2"
    # Log to file if PHOENIX_HYPERVISOR_LOGFILE is set and directory/file is writable
    if [[ -n "${PHOENIX_HYPERVISOR_LOGFILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$PHOENIX_HYPERVISOR_LOGFILE" 2>/dev/null)"
        # Check if log_dir is writable or create it if it doesn't exist
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || true
        fi
        if [[ -w "$log_dir" && (-f "$PHOENIX_HYPERVISOR_LOGFILE" && -w "$PHOENIX_HYPERVISOR_LOGFILE" || ! -f "$PHOENIX_HYPERVISOR_LOGFILE") ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$PHOENIX_HYPERVISOR_LOGFILE" 2>/dev/null
        fi
    fi
    # Always echo to stdout/stderr
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}
log_info() {
    log_message "INFO" "$1"
}
log_warn() {
    log_message "WARN" "$1" >&2 # Send warnings to stderr
}
log_error() {
    log_message "ERROR" "$1" >&2 # Send errors to stderr
}
# --- GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID cannot be empty"
        return 1
    fi
    # Get GPU assignment from the main configuration file
    # This relies on PHOENIX_LXC_CONFIG_FILE being set (from phoenix_hypervisor_config.sh)
    if command -v jq >/dev/null 2>&1 && [[ -n "${PHOENIX_LXC_CONFIG_FILE:-}" ]] && [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        local gpu_assignment
        gpu_assignment=$(jq -r '.lxc_configs["'$container_id'"].gpu_assignment // "none"' "$PHOENIX_LXC_CONFIG_FILE" 2>&1)
        if [[ $? -ne 0 ]]; then
            log_error "get_gpu_assignment: Failed to parse GPU assignment for container $container_id: $gpu_assignment"
            return 1
        fi
        echo "$gpu_assignment"
        return 0
    else
        log_warn "get_gpu_assignment: jq not available or config file not found/readable, returning default GPU assignment"
        echo "none"
        return 0
    fi
}
# --- GPU Validation ---
validate_gpu_assignment() {
    local container_id="$1"
    local gpu_assignment="$2"
    # Skip validation if no GPUs assigned or explicitly "none"
    if [[ -z "$gpu_assignment" ]] || [[ "$gpu_assignment" == "none" ]]; then
        return 0
    fi
    # Validate that GPU indices are numeric and properly formatted
    IFS=',' read -ra indices <<< "$gpu_assignment"
    for index in "${indices[@]}"; do
        # Check if index is a valid non-negative integer
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "validate_gpu_assignment: Invalid GPU index '$index' in assignment for container $container_id"
            return 1
        fi
        # Optional: Check if index is within a reasonable range (e.g., 0-15)
        # if [[ "$index" -gt 15 ]]; then
        #     log_warn "validate_gpu_assignment: GPU index '$index' for container $container_id seems unusually high."
        # fi
    done
    return 0
}
# --- GPU Passthrough Configuration ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_assignment="$2"
    if [[ -z "$lxc_id" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC ID cannot be empty"
        return 1
    fi
    if [[ -z "$gpu_assignment" ]] || [[ "$gpu_assignment" == "none" ]]; then
        log_info "No GPU assignment for $lxc_id, skipping GPU passthrough"
        return 0
    fi
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "LXC config file not found: $config_file"
        return 1
    fi
    # Remove existing GPU-related entries for idempotency
    sed -i '/^lxc\.cgroup2\.devices\.allow.*195/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow.*235/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow.*236/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow.*237/d' "$config_file"
    sed -i '/^lxc\.mount\.entry.*nvidia/d' "$config_file"
    sed -i '/^lxc\.mount\.entry.*dri/d' "$config_file"
    # Add cgroup and mount entries
    echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$config_file"  # nvidia-uvm
    echo "lxc.cgroup2.devices.allow: c 235:* rwm" >> "$config_file"  # renderD*
    echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> "$config_file"
    IFS=',' read -ra gpus <<< "$gpu_assignment"
    for gpu in "${gpus[@]}"; do
        echo "lxc.cgroup2.devices.allow: c 10:144 rwm" >> "$config_file"  # Misc for NVENC if needed
        echo "lxc.cgroup2.devices.allow: c 236:$gpu rwm" >> "$config_file"  # nvidiactl variant
        echo "lxc.mount.entry: /dev/nvidia$gpu dev/nvidia$gpu none bind,optional,create=file" >> "$config_file"
    done
    echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file" >> "$config_file"
    echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file" >> "$config_file"
    echo "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file" >> "$config_file"
    pct reboot "$lxc_id"  # Apply changes
    log_info "GPU passthrough configured for $lxc_id (GPUs: $gpu_assignment)"
}
# --- Container Creation Functions ---
create_lxc_container() {
    local lxc_id="$1"
    local container_config="$2"
    
    # Extract configuration parameters from JSON
    local name=$(echo "$container_config" | jq -r '.name')
    local memory_mb=$(echo "$container_config" | jq -r '.memory_mb')
    local cores=$(echo "$container_config" | jq -r '.cores')
    local template=$(echo "$container_config" | jq -r '.template')
    local storage_pool=$(echo "$container_config" | jq -r '.storage_pool')
    local storage_size_gb=$(echo "$container_config" | jq -r '.storage_size_gb')
    local network_config=$(echo "$container_config" | jq -r '.network_config')
    local features=$(echo "$container_config" | jq -r '.features')
    local gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    
    # Validate required parameters
    if [[ -z "$name" || "$name" == "null" ]]; then
        log_error "Invalid or missing 'name' for container $lxc_id"
        return 1
    fi
    
    # Convert storage size to proper format (GB to GiB)
    local storage_size="${storage_size_gb}G"
    
    # Create LXC container
    log_info "Creating container $lxc_id ($name)..."
    if ! pct create "$lxc_id" "$template" \
        --hostname "$name" \
        --memory "$memory_mb" \
        --cores "$cores" \
        --rootfs "$storage_pool:$storage_size" \
        --net0 "name=eth0,bridge=vmbr0,ip=$network_config" \
        --features "$features"; then
        log_error "Failed to create LXC container $lxc_id"
        return 1
    fi
    
    # Configure GPU passthrough if assigned
    if [[ "$gpu_assignment" != "none" ]]; then
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log_error "Failed to configure GPU passthrough for container $lxc_id"
            return 1
        fi
    fi
    
    log_info "Container $lxc_id created successfully"
    return 0
}

# --- Container Config Validation ---
validate_container_config() {
    local container_id="$1"
    local container_config="$2"
    if [[ -z "$container_id" ]]; then
        log_error "validate_container_config: Container ID cannot be empty"
        return 1
    fi
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "validate_container_config: Container config is empty or null"
        return 1
    fi
    # Extract and validate key fields (example)
    local name=$(echo "$container_config" | jq -r '.name')
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

# --- Hypervisor Configuration Loading ---
# Define the load_hypervisor_config function
# NOTE: This function is NO LONGER called automatically when the script is sourced.
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."
    log_info "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"
    # Check if jq is installed
    if ! command -v jq >/dev/null; then
        log_error "load_hypervisor_config: jq is not installed. Please install it (e.g., apt install jq)."
        return 1
    fi
    # Check PHOENIX_LXC_CONFIG_FILE
    if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
        log_error "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE is not set. Please source phoenix_hypervisor_config.sh."
        return 1
    fi
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "load_hypervisor_config: Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "load_hypervisor_config: Configuration file is not readable: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    # Validate JSON structure
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then # Redirect stderr for cleaner logs on failure
        log_error "load_hypervisor_config: Configuration file is not valid JSON: $PHOENIX_LXC_CONFIG_FILE"
        log_error "load_hypervisor_config: jq output: $(jq empty "$PHOENIX_LXC_CONFIG_FILE" 2>&1)"
        return 1
    fi
    # Ensure LXC_CONFIGS is an associative array
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
# --- Utility Functions ---
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
# --- Signal successful loading ---
# This flag helps scripts that source this file know it's been loaded
export PHOENIX_HYPERVISOR_COMMON_LOADED=1
# --- REMOVED ---
# The block that automatically called load_hypervisor_config during sourcing
# has been removed. The main script (phoenix_establish_hypervisor.sh) is now
# responsible for calling it explicitly.
# --- END REMOVED ---