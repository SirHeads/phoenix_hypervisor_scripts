#!/bin/bash
# Common functions for Phoenix Hypervisor scripts
# Version: 1.7.11
# Author: Assistant

# --- Signal successful loading ---
export PHOENIX_HYPERVISOR_COMMON_LOADED=1

# --- Logging Functions ---
setup_logging() {
    local log_dir="/var/log/phoenix_hypervisor"
    local log_file="$log_dir/phoenix_hypervisor.log"
    local debug_log="$log_dir/phoenix_hypervisor_debug.log"

    # Ensure log directory exists and is writable
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        echo "[ERROR] Failed to create log directory: $log_dir" >&2
        exit 1
    fi
    if ! touch "$log_file" "$debug_log" 2>/dev/null; then
        echo "[ERROR] Failed to create log files: $log_file or $debug_log" >&2
        exit 1
    fi
    if ! chmod 644 "$log_file" "$debug_log" 2>/dev/null; then
        echo "[ERROR] Failed to set permissions on log files: $log_file or $debug_log" >&2
        exit 1
    fi
    if ! [ -w "$log_file" ] || ! [ -w "$debug_log" ]; then
        echo "[ERROR] Log files are not writable: $log_file or $debug_log" >&2
        exit 1
    fi

    # Initialize file descriptors with error handling
    if ! exec 3>>"$log_file"; then
        echo "[ERROR] Failed to open log file: $log_file" >&2
        exit 1
    fi
    if ! exec 4>>"$debug_log"; then
        echo "[ERROR] Failed to open debug log file: $debug_log" >&2
        exit 1
    fi
    if ! exec 5>&2; then
        echo "[ERROR] Failed to redirect stderr" >&2
        exit 1
    fi
    if ! exec 2>>"$debug_log"; then
        echo "[ERROR] Failed to redirect stderr to debug log: $debug_log" >&2
        exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Logging initialized to $log_file and debug to $debug_log" >&3
}

log_info() {
    local message="$1"
    if [[ -e /proc/self/fd/3 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" >&3
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" >&2
    fi
}

log_warn() {
    local message="$1"
    if [[ -e /proc/self/fd/4 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $message" >&4
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $message" >&2
    fi
}

log_error() {
    local message="$1"
    if [[ -e /proc/self/fd/4 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $message" >&4
    else
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

    if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
        declare -gA LXC_CONFIGS
    elif [[ "$(declare -p LXC_CONFIGS)" != "declare -A"* ]]; then
        log_error "load_hypervisor_config: LXC_CONFIGS variable exists but is not an associative array."
        return 1
    fi

    local container_ids
    if ! container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4); then
        log_error "load_hypervisor_config: Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        log_error "load_hypervisor_config: jq output: $container_ids"
        return 1
    fi

    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi

    local count=0
    while IFS= read -r id; do
        if [[ -n "$id" ]]; then
            local config_output
            config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4)
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

# --- GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID is required"
        return 1
    fi

    if declare -p LXC_CONFIGS >/dev/null 2>&1 && [[ -n "${LXC_CONFIGS[$container_id]:-}" ]]; then
        echo "$LXC_CONFIGS[$container_id]" | jq -r '.gpu_assignment // "none"'
    else
        if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jq >/dev/null; then
            jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE"
        else
            echo "none"
        fi
    fi
}

validate_gpu_assignment() {
    local container_id="$1"
    local gpu_assignment="$2"

    if [[ -z "$gpu_assignment" || "$gpu_assignment" == "none" ]]; then
        return 0
    fi

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

    if [[ -z "$lxc_id" || -z "$container_config" ]]; then
        log_error "create_lxc_container: Container ID and configuration are required"
        return 1
    fi

    if ! validate_container_config "$lxc_id" "$container_config"; then
        log_error "create_lxc_container: Configuration validation failed for container $lxc_id"
        return 1
    fi

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

    local ip_cidr gateway dns
    IFS=',' read -r ip_cidr gateway dns <<< "$network_config"

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

    local storage_size="${storage_size_gb}"

    log_info "Creating container $lxc_id ($name)..."
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

    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        if declare -f configure_lxc_gpu_passthrough >/dev/null 2>&1; then
            if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
                log_warn "Failed to configure GPU passthrough for container $lxc_id. Continuing with container creation."
            else
                log_info "GPU passthrough configured successfully for container $lxc_id"
            fi
        else
            log_warn "GPU passthrough function 'configure_lxc_gpu_passthrough' not found. Skipping GPU setup."
        fi
    else
        log_info "No GPU assignment for container $lxc_id, skipping GPU passthrough configuration."
    fi

    log_info "Container $lxc_id ($name) created successfully."
    return 0
}

# Initialize logging
setup_logging

log_info "phoenix_hypervisor_common.sh: Library loaded successfully."