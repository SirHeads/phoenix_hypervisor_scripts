#!/bin/bash
# Common functions for Phoenix Hypervisor scripts
# Version: 1.7.12 (Fixed Premature CUDA Validation)
# Author: Assistant

# --- Signal successful loading ---
export PHOENIX_HYPERVISOR_COMMON_LOADED=1

# --- Logging Functions ---
setup_logging() {
    local log_dir="/var/log/phoenix_hypervisor"
    local log_file="$log_dir/phoenix_hypervisor.log"
    local debug_log="$log_dir/phoenix_hypervisor_debug.log"

    # --- Robust Directory Creation ---
    if [[ ! -d "$log_dir" ]]; then
        log_info "Log directory '$log_dir' does not exist. Attempting to create..."
        # Use mkdir -p and check the exit status directly
        if ! mkdir -p "$log_dir"; then
            echo "[ERROR] setup_logging: Failed to create log directory '$log_dir'. Check permissions for parent directory '$(dirname "$log_dir")'." >&2
            exit 1
        fi
        # Set directory permissions
        chmod 755 "$log_dir" || echo "[WARN] setup_logging: Could not set permissions (755) for '$log_dir'."
        log_info "Log directory '$log_dir' created successfully."
    else
        log_info "Log directory '$log_dir' already exists."
    fi

    # --- Robust File Creation and Permission Setting ---
    for logfile in "$log_file" "$debug_log"; do
        if [[ ! -f "$logfile" ]]; then
            log_info "Log file '$logfile' does not exist. Attempting to create..."
            # Touch the file and check the exit status
            if ! touch "$logfile"; then
                echo "[ERROR] setup_logging: Failed to create log file '$logfile'. Check permissions for directory '$log_dir'." >&2
                exit 1
            fi
            # Set file permissions
            if ! chmod 644 "$logfile"; then
                echo "[WARN] setup_logging: Failed to set permissions (644) on log file '$logfile'." >&2
            fi
            log_info "Log file '$logfile' created successfully."
        else
            log_info "Log file '$logfile' already exists."
            # Ensure permissions are correct even if file exists
            if ! chmod 644 "$logfile" 2>/dev/null; then
                echo "[WARN] setup_logging: Could not set/verify permissions (644) for existing log file '$logfile'." >&2
            fi
        fi
    done

    # --- Check Writability ---
    # Check if log files are writable after creation/permission setting
    if ! [ -w "$log_file" ] || ! [ -w "$debug_log" ]; then
        echo "[ERROR] setup_logging: Log files are not writable: '$log_file' or '$debug_log'. Check ownership and permissions for directory '$log_dir' and the files themselves." >&2
        exit 1
    fi
    log_info "Log files are confirmed writable."

    # --- Initialize File Descriptors ---
    # Close FDs if they were previously opened (defensive)
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    exec 5>&- 2>/dev/null || true

    # Initialize file descriptors with explicit error checking
    if ! exec 3>>"$log_file"; then
        echo "[ERROR] setup_logging: Failed to open main log file descriptor (fd 3) for '$log_file'." >&2
        exit 1
    fi
    log_info "Main log file descriptor (fd 3) opened for '$log_file'."

    if ! exec 4>>"$debug_log"; then
        echo "[ERROR] setup_logging: Failed to open debug log file descriptor (fd 4) for '$debug_log'." >&2
        exec 3>&- # Close fd 3 if fd 4 fails
        exit 1
    fi
    log_info "Debug log file descriptor (fd 4) opened for '$debug_log'."

    # Redirect script's stderr (fd 2) to the debug log (fd 4)
    # Save original stderr to fd 5 first
    if ! exec 5>&2; then
        echo "[ERROR] setup_logging: Failed to save original stderr to file descriptor 5." >&2
        exec 3>&- # Close fd 3
        exec 4>&- # Close fd 4
        exit 1
    fi
    log_info "Original stderr saved to file descriptor 5."

    if ! exec 2>&4; then
        echo "[ERROR] setup_logging: Failed to redirect script's stderr (fd 2) to debug log '$debug_log'." >&2
        exec 3>&- # Close fd 3
        exec 4>&- # Close fd 4
        exec 5>&- # Close fd 5
        exit 1
    fi
    log_info "Script's stderr redirected to debug log (fd 4)."

    # Log successful initialization to the main log file (fd 3)
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Logging initialized to $log_file and debug to $debug_log" >&3
    log_info "Logging system fully initialized."
}

log_info() {
    local message="$1"
    if [[ -e /proc/self/fd/3 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" >&3
    else
        # Fallback to stderr if fd 3 is not available (e.g., before setup_logging or on error)
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" >&2
    fi
}

log_warn() {
    local message="$1"
    if [[ -e /proc/self/fd/4 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $message" >&4
    else
        # Fallback to stderr if fd 4 is not available
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $message" >&2
    fi
}

log_error() {
    local message="$1"
    if [[ -e /proc/self/fd/4 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $message" >&4
    else
        # Fallback to stderr if fd 4 is not available (critical, as this is where errors should go)
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $message" >&2
    fi
    exit 1
}

# --- Utility Functions ---
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: $*"
        if "$@"; then
            log_info "Command succeeded: $*"
            return 0
        else
            log_warn "retry_command: Command failed (attempt $attempt/$max_attempts). Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "retry_command: Command failed after $max_attempts attempts: $*"
    return 1
}

# --- CRITICAL FIX: REMOVED validate_cuda_version CALL ---
# The function validate_cuda_version() is NOT removed, but its premature call
# inside create_lxc_container has been removed.
# validate_cuda_version() should only be called by specific container setup
# scripts AFTER the NVIDIA driver/CUDA toolkit has been installed inside the container.
# ---
# validate_cuda_version() {
#     local lxc_id="$1"
#     log_info "Validating CUDA version for container $lxc_id..."
#     if ! pct exec "$lxc_id" -- nvcc --version | grep -q "${CUDA_VERSION}"; then
#         log_error "CUDA version mismatch in container $lxc_id. Expected ${CUDA_VERSION}."
#     fi
#     log_info "CUDA version ${CUDA_VERSION} validated successfully for container $lxc_id."
# }
# ---

validate_environment() {
    log_info "Validating environment..."
    if ! systemctl is-active --quiet apparmor; then
        log_warn "apparmor service not active."
    fi
    log_info "Environment validation completed."
}

# --- Source NVIDIA LXC Common Functions ---
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

# --- Container Configuration Validation ---
validate_container_config() {
    local container_id="$1"
    local container_config="$2"

    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "validate_container_config: Container config is empty or null"
        return 1
    fi

    local name
    name=$(echo "$container_config" | jq -r '.name')
    if [[ -z "$name" || "$name" == "null" ]]; then
        log_error "validate_container_config: Missing or invalid 'name' for container $container_id"
        return 1
    fi

    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    if ! validate_gpu_assignment "$container_id" "$gpu_assignment"; then
        log_error "validate_container_config: Invalid GPU assignment for container $container_id"
        return 1
    fi

    return 0
}

# --- Hypervisor Configuration Loading ---
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."
    log_info "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"

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

    local container_ids
    # Parse container IDs, sending potential jq errors to the debug log (fd 4)
    if ! container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4); then
        log_error "load_hypervisor_config: Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        # The actual jq error should be in the debug log due to 2>&4 redirection above
        return 1
    fi

    # Check if any configurations were found
    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0 # Not an error, just a warning
    fi

    local count=0
    # Iterate through the parsed IDs
    while IFS= read -r id; do
        # Ensure the ID is not empty (defensive check)
        if [[ -n "$id" ]]; then
            local config_output
            # Extract the specific container config, sending jq errors to debug log
            if ! config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4); then
                log_error "load_hypervisor_config: Failed to load config for container ID $id"
                return 1
            fi
            # Store the config in the global associative array
            LXC_CONFIGS["$id"]="$config_output"
            ((count++))
        fi
    done <<< "$container_ids" # Use here-string for the loop

    log_info "load_hypervisor_config: Loaded $count LXC configurations"
    return 0
}

# --- GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"
    # Validate input
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID is required"
        return 1
    fi

    # Check if the global LXC_CONFIGS array is loaded and contains the key
    if declare -p LXC_CONFIGS >/dev/null 2>&1 && [[ -n "${LXC_CONFIGS[$container_id]:-}" ]]; then
        # Extract gpu_assignment from the loaded config in the array
        echo "$LXC_CONFIGS[$container_id]" | jq -r '.gpu_assignment // "none"'
    else
        # Fallback: If LXC_CONFIGS is not loaded or key is missing,
        # directly query the JSON file using jq (slower but works independently)
        if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jq >/dev/null; then
            jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE"
        else
            # If jq or file is missing, default to "none"
            echo "none"
        fi
    fi
}

validate_gpu_assignment() {
    local container_id="$1"
    local gpu_assignment="$2"

    # If no assignment or explicitly "none", it's valid
    if [[ -z "$gpu_assignment" || "$gpu_assignment" == "none" ]]; then
        return 0
    fi

    # Validate the format: comma-separated numbers (e.g., "0", "1", "0,1")
    if [[ ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "validate_gpu_assignment: Invalid GPU assignment format for container $container_id: '$gpu_assignment'. Expected comma-separated GPU indices (e.g., '0', '1', '0,1') or 'none'."
        return 1
    fi

    return 0
}

# --- LXC Container Management ---
create_lxc_container() {
    local lxc_id="$1"
    local container_config="$2"

    # Validate required inputs
    if [[ -z "$lxc_id" || -z "$container_config" ]]; then
        log_error "create_lxc_container: Container ID and configuration are required"
        return 1
    fi

    # Validate the provided configuration JSON
    if ! validate_container_config "$lxc_id" "$container_config"; then
        log_error "create_lxc_container: Configuration validation failed for container $lxc_id"
        return 1
    fi

    # --- Extract configuration parameters using jq ---
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
    # --- End Extract Parameters ---

    # --- Parse Network Configuration ---
    local ip_cidr gateway dns
    # Split the network_config string by commas
    IFS=',' read -r ip_cidr gateway dns <<< "$network_config"

    # Validate IP/CIDR format (basic regex)
    if [[ ! "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log_error "Invalid IP/CIDR format in network_config: $ip_cidr"
        return 1
    fi
    # Validate Gateway format (basic regex)
    if [[ ! "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Gateway format in network_config: $gateway"
        return 1
    fi
    # Validate DNS format (basic regex)
    if [[ ! "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid DNS format in network_config: $dns"
        return 1
    fi
    # --- End Parse Network ---

    # --- Validate Required Fields (Double-check after jq parsing) ---
    # Although validate_container_config checks 'name', checking again here is defensive.
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
    # --- End Validate Fields ---

    # Prepare storage size argument for pct (just the number, unit assumed GB)
    local storage_size="${storage_size_gb}"

    # --- Create the LXC Container ---
    log_info "Creating container $lxc_id ($name)..."
    # Use retry_command to attempt container creation
    if ! retry_command 3 10 pct create "$lxc_id" "$template" \
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
    # --- End Create Container ---

    # --- Configure GPU Passthrough (if assigned) ---
    # Check if a GPU assignment exists and is not "none"
    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        # Check if the NVIDIA configuration function is available
        if declare -f configure_lxc_gpu_passthrough >/dev/null 2>&1; then
            # Call the function to configure GPU passthrough
            if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
                # Log a warning but don't fail the entire container creation
                log_warn "Failed to configure GPU passthrough for container $lxc_id. Continuing with container creation."
            else
                log_info "GPU passthrough configured successfully for container $lxc_id"
            fi
        else
            # Warn if the function isn't found (e.g., NVIDIA lib not sourced)
            log_warn "GPU passthrough function 'configure_lxc_gpu_passthrough' not found. Skipping GPU setup."
        fi
    else
        log_info "No GPU assignment for container $lxc_id, skipping GPU passthrough configuration."
    fi
    # --- End GPU Configuration ---

    # --- CRITICAL FIX APPLIED HERE ---
    # The call to validate_cuda_version has been REMOVED from this point.
    # CUDA validation should happen in the specific container setup scripts
    # (e.g., phoenix_hypervisor_setup_drdevstral.sh, phoenix_hypervisor_setup_drcuda.sh)
    # AFTER the NVIDIA driver and CUDA toolkit have been installed inside the container.
    # ---
    # validate_cuda_version "$lxc_id" # <-- THIS LINE WAS REMOVED
    # ---
    # --- End Critical Fix ---

    # --- Finalize ---
    log_info "Container $lxc_id ($name) created successfully."
    return 0
    # --- End Finalize ---
}

# Initialize logging
setup_logging

log_info "phoenix_hypervisor_common.sh: Library loaded successfully."
