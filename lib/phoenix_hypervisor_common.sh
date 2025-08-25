#!/bin/bash
# Common functions for Phoenix Hypervisor scripts
# Version: 1.7.17 (Updated authenticate_registry to use PHOENIX_DOCKER_TOKEN_FILE, added authenticate_huggingface)
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
        if ! mkdir -p "$log_dir"; then
            echo "[ERROR] setup_logging: Failed to create log directory '$log_dir'. Check permissions for parent directory '$(dirname "$log_dir")'." >&2
            exit 1
        fi
        chmod 755 "$log_dir" || echo "[WARN] setup_logging: Could not set permissions (755) for '$log_dir'."
        log_info "Log directory '$log_dir' created successfully."
    else
        log_info "Log directory '$log_dir' already exists."
    fi

    # --- Robust File Creation and Permission Setting ---
    for logfile in "$log_file" "$debug_log"; do
        if [[ ! -f "$logfile" ]]; then
            log_info "Log file '$logfile' does not exist. Attempting to create..."
            if ! touch "$logfile"; then
                echo "[ERROR] setup_logging: Failed to create log file '$logfile'. Check permissions for directory '$log_dir'." >&2
                exit 1
            fi
            if ! chmod 644 "$logfile"; then
                echo "[WARN] setup_logging: Failed to set permissions (644) on log file '$logfile'." >&2
            fi
            log_info "Log file '$logfile' created successfully."
        else
            log_info "Log file '$logfile' already exists."
            if ! chmod 644 "$logfile" 2>/dev/null; then
                echo "[WARN] setup_logging: Could not set/verify permissions (644) for existing log file '$logfile'." >&2
            fi
        fi
    done

    # --- Check Writability ---
    if ! [ -w "$log_file" ] || ! [ -w "$debug_log" ]; then
        echo "[ERROR] setup_logging: Log files are not writable: '$log_file' or '$debug_log'. Check ownership and permissions for directory '$log_dir' and the files themselves." >&2
        exit 1
    fi
    log_info "Log files are confirmed writable."

    # --- Initialize File Descriptors ---
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    exec 5>&- 2>/dev/null || true

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

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Logging initialized to $log_file and debug to $debug_log" >&3
    log_info "Logging system fully initialized."
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

# --- Source Docker LXC Common Functions ---
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_docker.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_docker.sh
    log_info "phoenix_hypervisor_common.sh: Sourced Docker LXC common functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_lxc_common_docker.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_lxc_common_docker.sh
    log_warn "phoenix_hypervisor_common.sh: Sourced Docker LXC functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
elif [[ -f "./phoenix_hypervisor_lxc_common_docker.sh" ]]; then
    source ./phoenix_hypervisor_lxc_common_docker.sh
    log_warn "phoenix_hypervisor_common.sh: Sourced Docker LXC functions from current directory. Prefer standard locations."
else
    log_warn "phoenix_hypervisor_common.sh: Docker LXC common functions file not found. Docker-related operations may fail."
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
            if ! config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4); then
                log_error "load_hypervisor_config: Failed to load config for container ID $id"
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

# --- Docker Management Functions ---
# --- UPDATED: Use PHOENIX_DOCKER_TOKEN_FILE for Docker Hub authentication ---
authenticate_registry() {
    local lxc_id="$1"
    log_info "Authenticating with external Docker registry in container $lxc_id..."

    # Validate input
    if [[ -z "$lxc_id" ]]; then
        log_error "authenticate_registry: Container ID is required"
        return 1
    fi

    # Check for credential file
    if [[ ! -f "$PHOENIX_DOCKER_TOKEN_FILE" ]]; then
        log_error "authenticate_registry: Credential file $PHOENIX_DOCKER_TOKEN_FILE not found"
        return 1
    fi

    # Read credentials
    local username token
    username=$(grep '^DOCKER_HUB_USERNAME=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
    token=$(grep '^DOCKER_HUB_TOKEN=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
    if [[ -z "$username" || -z "$token" ]]; then
        log_error "authenticate_registry: Missing DOCKER_HUB_USERNAME or DOCKER_HUB_TOKEN in $PHOENIX_DOCKER_TOKEN_FILE"
        return 1
    fi

    # Authenticate with registry using retry_command
    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "docker login -u '$username' -p '$token' $EXTERNAL_REGISTRY_URL"; then
        log_error "authenticate_registry: Failed to authenticate with registry $EXTERNAL_REGISTRY_URL in container $lxc_id"
        return 1
    fi

    log_info "Successfully authenticated with registry $EXTERNAL_REGISTRY_URL in container $lxc_id"
    return 0
}

# --- NEW: Authenticate with Hugging Face for vLLM image pulls ---
authenticate_huggingface() {
    local lxc_id="$1"
    log_info "Authenticating with Hugging Face in container $lxc_id..."

    # Validate input
    if [[ -z "$lxc_id" ]]; then
        log_error "authenticate_huggingface: Container ID is required"
        return 1
    fi

    # Check for credential file
    if [[ ! -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        log_error "authenticate_huggingface: Credential file $PHOENIX_HF_TOKEN_FILE not found"
        return 1
    fi

    # Read Hugging Face token
    local token
    token=$(grep '^HF_TOKEN=' "$PHOENIX_HF_TOKEN_FILE" | cut -d'=' -f2-)
    if [[ -z "$token" ]]; then
        log_error "authenticate_huggingface: Missing HF_TOKEN in $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi

    # Authenticate with Hugging Face (e.g., for vLLM model/image pulls)
    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "echo '$token' | docker login huggingface.co -u 'user' --password-stdin"; then
        log_error "authenticate_huggingface: Failed to authenticate with huggingface.co in container $lxc_id"
        return 1
    fi

    log_info "Successfully authenticated with huggingface.co in container $lxc_id"
    return 0
}

# --- Install Portainer Agent in container ---
install_portainer_agent() {
    local lxc_id="$1"
    log_info "Installing Portainer Agent in container $lxc_id..."

    if [[ -z "$lxc_id" ]]; then
        log_error "install_portainer_agent: Container ID is required"
        return 1
    fi

    if ! declare -f install_docker_ce_in_container >/dev/null 2>&1; then
        log_error "install_portainer_agent: Docker installation function 'install_docker_ce_in_container' not found"
        return 1
    fi
    if ! install_docker_ce_in_container "$lxc_id"; then
        log_error "install_portainer_agent: Failed to install Docker in container $lxc_id"
        return 1
    fi

    local agent_cmd="docker run -d -p $PORTAINER_AGENT_PORT:$PORTAINER_AGENT_PORT --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/agent:latest --env AGENT_CLUSTER_ADDR=$PORTAINER_SERVER_IP"
    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "$agent_cmd"; then
        log_error "install_portainer_agent: Failed to run Portainer Agent in container $lxc_id"
        return 1
    fi

    if ! retry_command 3 5 pct exec "$lxc_id" -- bash -c "docker ps -q -f name=portainer_agent | grep -q ."; then
        log_error "install_portainer_agent: Portainer Agent is not running in container $lxc_id"
        return 1
    fi

    log_info "Portainer Agent installed and running in container $lxc_id"
    return 0
}

# --- Install Docker CE with NVIDIA Container Toolkit ---
install_docker_ce_in_container() {
    local lxc_id="$1"
    log_info "Installing Docker CE and NVIDIA Container Toolkit in container $lxc_id..."

    if [[ -z "$lxc_id" ]]; then
        log_error "install_docker_ce_in_container: Container ID is required"
        return 1
    fi

    local docker_install_cmd=$(cat << 'EOF'
apt-get update && \
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release && \
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
apt-get update && \
apt-get install -y docker-ce docker-ce-cli containerd.io
EOF
    )
    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "$docker_install_cmd"; then
        log_error "install_docker_ce_in_container: Failed to install Docker CE in container $lxc_id"
        return 1
    fi

    if ! retry_command 3 5 pct exec "$lxc_id" -- bash -c "systemctl enable docker && systemctl start docker"; then
        log_error "install_docker_ce_in_container: Failed to enable/start Docker service in container $lxc_id"
        return 1
    fi

    local nvidia_toolkit_cmd=$(cat << 'EOF'
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu24.04/libnvidia-container.list | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
apt-get update && \
apt-get install -y nvidia-container-toolkit && \
nvidia-ctk runtime configure --runtime=docker && \
systemctl restart docker
EOF
    )
    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "$nvidia_toolkit_cmd"; then
        log_error "install_docker_ce_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id"
        return 1
    fi

    if ! retry_command 3 5 pct exec "$lxc_id" -- bash -c "docker version"; then
        log_error "install_docker_ce_in_container: Docker installation validation failed in container $lxc_id"
        return 1
    fi

    log_info "Docker CE and NVIDIA Container Toolkit installed successfully in container $lxc_id"
    return 0
}

# --- LXC Container Management ---
create_lxc_container() {
    local lxc_id="$1"
    local container_config="$2"
    local is_core_container="$3"

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
    network_config=$(echo "$container_config" | jq -c '.network_config')
    local features
    features=$(echo "$container_config" | jq -r '.features // "nesting=1"')
    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    local static_ip
    static_ip=$(echo "$container_config" | jq -r '.static_ip // empty')
    local mac_address
    mac_address=$(echo "$container_config" | jq -r '.mac_address // empty')

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

    local net_name net_bridge net_ip net_gw net_dns
    if [[ "$(echo "$network_config" | jq -r 'type')" == "object" ]]; then
        net_name=$(echo "$network_config" | jq -r '.name')
        net_bridge=$(echo "$network_config" | jq -r '.bridge')
        net_ip=$(echo "$network_config" | jq -r '.ip')
        net_gw=$(echo "$network_config" | jq -r '.gw')
    else
        log_warn "create_lxc_container: Legacy string-based network_config detected for container $lxc_id, attempting to parse..."
        local net_config_str=$(echo "$container_config" | jq -r '.network_config')
        if [[ -z "$net_config_str" || "$net_config_str" == "null" ]]; then
            log_error "create_lxc_container: Invalid or missing network_config for container $lxc_id"
            return 1
        fi
        net_name="eth0"
        net_bridge="vmbr0"
        IFS=',' read -r net_ip net_gw net_dns <<< "$net_config_str"
    fi

    if [[ -z "$net_name" || "$net_name" == "null" || ! "$net_name" =~ ^[a-zA-Z0-9]+$ ]]; then
        log_error "create_lxc_container: Invalid or missing network name for container $lxc_id: '$net_name'. Must be alphanumeric."
        return 1
    fi
    if [[ -z "$net_bridge" || "$net_bridge" == "null" || ! "$net_bridge" =~ ^[a-zA-Z0-9]+$ ]]; then
        log_error "create_lxc_container: Invalid or missing bridge name for container $lxc_id: '$net_bridge'. Must be alphanumeric."
        return 1
    fi
    if [[ -z "$net_ip" || "$net_ip" == "null" || ! "$net_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "create_lxc_container: Invalid or missing IP for container $lxc_id: '$net_ip'. Expected format: x.x.x.x/yy"
        return 1
    fi
    if [[ -z "$net_gw" || "$net_gw" == "null" || ! "$net_gw" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "create_lxc_container: Invalid or missing gateway for container $lxc_id: '$net_gw'. Expected format: x.x.x.x"
        return 1
    fi

    if [[ -n "$static_ip" && "$static_ip" != "null" && "$static_ip" != "empty" ]]; then
        if [[ ! "$static_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            log_error "create_lxc_container: Invalid static_ip format for container $lxc_id: '$static_ip'. Expected format: x.x.x.x/yy"
            return 1
        fi
        net_ip="$static_ip"
        log_info "create_lxc_container: Using static_ip for container $lxc_id: $net_ip"
    fi

    local net0="name=$net_name,bridge=$net_bridge,ip=$net_ip,gw=$net_gw"
    if [[ -n "$mac_address" && "$mac_address" != "null" && "$mac_address" != "empty" ]]; then
        if [[ ! "$mac_address" =~ ^([0-9A-Fa-f]{2}:){5}([0-9A-Fa-f]{2})$ ]]; then
            log_error "create_lxc_container: Invalid MAC address format for container $lxc_id: '$mac_address'. Expected format: xx:xx:xx:xx:xx:xx"
            return 1
        fi
        local first_octet=$(echo "$mac_address" | cut -d':' -f1)
        if [[ $((16#${first_octet} & 1)) -eq 1 ]]; then
            log_error "create_lxc_container: MAC address $mac_address is not unicast for container $lxc_id (first octet: $first_octet)"
            return 1
        fi
        net0="$net0,hwaddr=$mac_address"
        log_info "create_lxc_container: Using custom MAC address for container $lxc_id: $mac_address"
    fi
    log_info "create_lxc_container: Constructed net0 string: $net0"

    local nameserver="${net_dns:-8.8.8.8}"
    if [[ -n "$nameserver" && "$nameserver" != "null" && ! "$nameserver" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "create_lxc_container: Invalid nameserver for container $lxc_id: '$nameserver'. Expected format: x.x.x.x"
        return 1
    fi

    log_info "Creating container $lxc_id ($name)..."
    local pct_create_cmd=(pct create "$lxc_id" "$template"
        --hostname "$name"
        --memory "$memory_mb"
        --cores "$cores"
        --storage "$storage_pool"
        --rootfs "$storage_size_gb"
        --net0 "$net0"
        --nameserver "$nameserver"
    )

    if [[ -n "$features" && "$features" != "null" && "$features" != "empty" ]]; then
        pct_create_cmd+=(--features "$features")
    fi

    if ! retry_command 3 10 "${pct_create_cmd[@]}"; then
        log_error "create_lxc_container: Failed to create LXC container $lxc_id"
        return 1
    fi

    log_info "Starting container $lxc_id..."
    if ! retry_command 5 5 pct start "$lxc_id"; then
        log_error "create_lxc_container: Failed to start container $lxc_id"
        return 1
    fi

    local max_attempts=5
    local attempt=1
    local status=""
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Checking container $lxc_id status (attempt $attempt/$max_attempts)..."
        status=$(pct status "$lxc_id" 2>/dev/null)
        if [[ "$status" == "status: running" ]]; then
            log_info "Container $lxc_id is running."
            break
        else
            log_warn "Container $lxc_id not yet running (status: $status). Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    if [[ "$status" != "status: running" ]]; then
        log_error "Container $lxc_id failed to start after $max_attempts attempts (status: $status)."
        return 1
    fi

    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        if declare -f configure_lxc_gpu_passthrough >/dev/null 2>&1; then
            if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
                log_warn "create_lxc_container: Failed to configure GPU passthrough for container $lxc_id. Continuing with container creation."
            else
                log_info "create_lxc_container: GPU passthrough configured successfully for container $lxc_id"
            fi
        else
            log_warn "create_lxc_container: GPU passthrough function 'configure_lxc_gpu_passthrough' not found. Skipping GPU setup."
        fi
    else
        log_info "create_lxc_container: No GPU assignment for container $lxc_id, skipping GPU passthrough configuration."
    fi

    log_info "create_lxc_container: Container $lxc_id ($name) created and started successfully."
    return 0
}

# Initialize logging
setup_logging

log_info "phoenix_hypervisor_common.sh: Library loaded successfully."