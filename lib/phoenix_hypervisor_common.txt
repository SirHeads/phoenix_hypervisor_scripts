#!/usr/bin/env bash
# Common functions for Phoenix Hypervisor
# Provides shared utilities for container management, configuration loading, and system operations on Proxmox
# Version: 2.1.2 (Added authenticate_huggingface, completed GPU passthrough, ZFS validation, secure logging)
# Author: Assistant
# Integration: Supports LXC creation (e.g., Portainer server ID 999, AI containers 900-902) and AI workloads (e.g., vLLM, LLaMA CPP, Ollama)

# --- Signal successful loading ---
export PHOENIX_HYPERVISOR_COMMON_LOADED=1

# --- Logging Setup ---
PHOENIX_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_common.log"

mkdir -p "$PHOENIX_LOG_DIR" 2>/dev/null || {
    PHOENIX_LOG_DIR="/tmp"
    PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_common.log"
}
touch "$PHOENIX_LOG_FILE" 2>/dev/null || true
chmod 600 "$PHOENIX_LOG_FILE" 2>/dev/null || log_warn "Could not set permissions to 600 on $PHOENIX_LOG_FILE"

# --- Logging Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S %Z') $1" >> "$PHOENIX_LOG_FILE"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S %Z') $1" >> "$PHOENIX_LOG_FILE"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S %Z') $1" >&2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S %Z') $1" >> "$PHOENIX_LOG_FILE"
}

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S %Z') $1" >> "$PHOENIX_LOG_FILE"
    fi
}

# --- Configuration Loading ---
# Ensure the function definition line strictly adheres to the expected format for validation
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."
    log_info "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"
    local container_ids
    local count=0
    local config_output
    
    if ! command -v jq >/dev/null; then
        log_error "load_hypervisor_config: 'jq' command not found. Install jq (apt install jq)."
        return 1
    fi

    if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
        declare -gA LXC_CONFIGS
    elif [[ "$(declare -p LXC_CONFIGS)" != "declare -A"* ]]; then
        log_error "load_hypervisor_config: LXC_CONFIGS variable exists but is not an associative array."
        return 1
    fi

    if ! container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE"); then
        log_error "load_hypervisor_config: Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi

    while IFS= read -r id; do
        if [[ -n "$id" ]]; then
            if ! config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE"); then
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
    container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID is required"
        return 1
    fi

    gpu_assignment
    gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE")

    if [[ "$gpu_assignment" == "null" ]]; then
        gpu_assignment="none"
    fi

    echo "$gpu_assignment"
}

check_gpu_assignment() {
    container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "check_gpu_assignment: Container ID is required"
        return 1
    fi

    gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")

    if [[ "$gpu_assignment" != "none" && ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "check_gpu_assignment: Invalid GPU assignment format for container $container_id: $gpu_assignment"
        return 1
    fi

    if [[ "$gpu_assignment" == "none" ]]; then
        return 1 # No GPU assignment
    else
        return 0 # Has GPU assignment
    fi
}

configure_lxc_gpu_passthrough() {
    lxc_id="$1"
    gpu_assignment="$2"

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_assignment" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing required arguments (lxc_id or gpu_assignment)"
        return 1
    fi

    if [[ "$gpu_assignment" != "none" && ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "configure_lxc_gpu_passthrough: Invalid GPU assignment format for container $lxc_id: $gpu_assignment"
        return 1
    fi

    if [[ "$gpu_assignment" == "none" ]]; then
        log_info "configure_lxc_gpu_passthrough: Skipping GPU passthrough for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "configure_lxc_gpu_passthrough: Configuring GPU access for container $lxc_id with assignment: $gpu_assignment"

    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "configure_lxc_gpu_passthrough: Container $lxc_id is not running"
        return 1
    fi

    lxc_config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$lxc_config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: Container config file not found: $lxc_config_file"
        return 1
    fi

    # Validate NVIDIA driver version
    expected_version="${PHOENIX_NVIDIA_DRIVER_VERSION:-580.76.05}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        current_version
        current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>>"$PHOENIX_LOG_FILE")
        if [[ -z "$current_version" || "$current_version" != "$expected_version" ]]; then
            log_warn "configure_lxc_gpu_passthrough: NVIDIA driver version ($current_version) does not match expected ($expected_version)"
        fi
    else
        log_error "configure_lxc_gpu_passthrough: nvidia-smi not found. Install drivers from ${PHOENIX_NVIDIA_REPO_URL:-https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/  }"
        return 1
    fi

    # Validate GPU IDs
    available_gpus
    available_gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>>"$PHOENIX_LOG_FILE" | tr '\n' ',' | sed 's/,$//')
    IFS=',' read -ra requested_gpus <<< "$gpu_assignment"
    for gpu_id in "${requested_gpus[@]}"; do
        if ! echo "$available_gpus" | grep -q "\b$gpu_id\b"; then
            log_error "configure_lxc_gpu_passthrough: GPU ID $gpu_id not available (available: $available_gpus)"
            return 1
        fi
    done

    # Add GPU device configuration
    gpu_config=""
    for gpu_id in "${requested_gpus[@]}"; do
        gpu_config+="lxc.cgroup2.devices.allow: c 195:$gpu_id rwm\n"
        gpu_config+="lxc.cgroup2.devices.allow: c 510:$gpu_id rwm\n"
        gpu_config+="lxc.mount.entry: /dev/nvidia$gpu_id dev/nvidia$gpu_id none bind,optional,create=file\n"
    done
    gpu_config+="lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file\n"
    gpu_config+="lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file\n"

    # Append GPU config if not already present
    if ! grep -q "lxc.cgroup2.devices.allow: c 195:" "$lxc_config_file"; then
        echo -e "$gpu_config" >> "$lxc_config_file" || {
            log_error "configure_lxc_gpu_passthrough: Failed to append GPU config to $lxc_config_file"
            return 1
        }
        log_info "configure_lxc_gpu_passthrough: GPU passthrough configured in $lxc_config_file"
    else
        log_info "configure_lxc_gpu_passthrough: GPU passthrough already configured in $lxc_config_file"
    fi

    # Ensure NVIDIA runtime in container
    if ! pct_exec_with_retry "$lxc_id" bash -c "command -v nvidia-smi >/dev/null 2>&1"; then
        log_info "configure_lxc_gpu_passthrough: Installing NVIDIA runtime in container $lxc_id..."
        if ! pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y nvidia-driver-${expected_version%%.*}"; then
            log_error "configure_lxc_gpu_passthrough: Failed to install NVIDIA runtime in container $lxc_id"
            return 1
        fi
    fi

    log_info "configure_lxc_gpu_passthrough: GPU access configured for container $lxc_id"
    return 0
}

# --- Hugging Face Authentication ---
authenticate_huggingface() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "authenticate_huggingface: Container ID is required"
        return 1
    fi

    log_info "authenticate_huggingface: Validating Hugging Face authentication in container $lxc_id..."

    # Read Hugging Face token
    if [[ ! -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        log_error "authenticate_huggingface: Hugging Face token file missing: $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi

    permissions
    permissions=$(stat -c "%a" "$PHOENIX_HF_TOKEN_FILE")
    if [[ "$permissions" != "600" && "$permissions" != "640" ]]; then
        log_warn "authenticate_huggingface: Insecure permissions on $PHOENIX_HF_TOKEN_FILE ($permissions). Setting to 600."
        chmod 600 "$PHOENIX_HF_TOKEN_FILE" || log_error "authenticate_huggingface: Failed to set permissions on $PHOENIX_HF_TOKEN_FILE"
    fi

    hf_token
    hf_token=$(grep '^HF_TOKEN=' "$PHOENIX_HF_TOKEN_FILE" | cut -d'=' -f2-)
    if [[ -z "$hf_token" ]]; then
        log_error "authenticate_huggingface: HF_TOKEN not found in $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi

    # Install Hugging Face CLI if not present
    if ! pct_exec_with_retry "$lxc_id" bash -c "command -v huggingface-cli >/dev/null 2>&1"; then
        log_info "authenticate_huggingface: Installing Hugging Face CLI in container $lxc_id..."
        if ! pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y python3-pip && pip3 install huggingface_hub"; then
            log_error "authenticate_huggingface: Failed to install Hugging Face CLI in container $lxc_id"
            return 1
        fi
    fi

    # Set Hugging Face token in container
    if ! pct_exec_with_retry "$lxc_id" bash -c "huggingface-cli login --token '$hf_token'"; then
        log_error "authenticate_huggingface: Failed to login to Hugging Face in container $lxc_id"
        return 1
    fi

    # Determine AI framework (vLLM, LLaMA CPP, Ollama) from JSON config or fallback
    framework
    framework=$(jq -r ".lxc_configs.\"$lxc_id\".ai_framework // \"vllm\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ "$framework" == "null" ]]; then
        framework="vllm" # Default to vLLM for AI containers
    fi
    log_info "authenticate_huggingface: Using AI framework '$framework' for container $lxc_id"

    # Test model access based on framework
    case "$framework" in
        "vllm")
            # Test vLLM model access
            if ! pct_exec_with_retry "$lxc_id" bash -c "python3 -c 'from huggingface_hub import HfApi; api = HfApi(); api.model_info(\"meta-llama/Meta-Llama-3-8B\")'"; then
                log_error "authenticate_huggingface: Failed to access model info (meta-llama/Meta-Llama-3-8B) with vLLM in container $lxc_id"
                return 1
            fi
            ;;
        "llamacpp")
            # Test LLaMA CPP model access
            if ! pct_exec_with_retry "$lxc_id" bash -c "python3 -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id=\"meta-llama/Meta-Llama-3-8B\", local_dir=\"/tmp/test_model\", token=\"$hf_token\")'"; then
                log_error "authenticate_huggingface: Failed to access model (meta-llama/Meta-Llama-3-8B) with LLaMA CPP in container $lxc_id"
                return 1
            fi
            ;;
        "ollama")
            # Test Ollama model pull
            if ! pct_exec_with_retry "$lxc_id" bash -c "command -v ollama >/dev/null 2>&1 || (apt update && apt install -y curl && curl -fsSL https://ollama.com/install.sh   | sh) && ollama pull llama3"; then
                log_error "authenticate_huggingface: Failed to pull model (llama3) with Ollama in container $lxc_id"
                return 1
            fi
            ;;
        *)
            log_error "authenticate_huggingface: Unsupported AI framework '$framework' for container $lxc_id"
            return 1
            ;;
    esac

    log_info "authenticate_huggingface: Successfully authenticated with Hugging Face in container $lxc_id using framework '$framework'"
    return 0
}

# --- Container Creation Functions ---
create_lxc_container() {
    lxc_id="$1"
    container_config="$2"
    rollback="${3:-true}" # Use ROLLBACK_ON_FAILURE if not specified

    if [[ -z "$lxc_id" ]] || [[ -z "$container_config" ]]; then
        log_error "create_lxc_container: Missing required arguments (lxc_id or container_config)"
        return 1
    fi

    if [[ "$rollback" == "true" && "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
        rollback="true"
    else
        rollback="false"
    fi

    name memory_mb cores template storage_pool storage_size_gb network_config features
    name=$(echo "$container_config" | jq -r '.name')
    memory_mb=$(echo "$container_config" | jq -r '.memory_mb')
    cores=$(echo "$container_config" | jq -r '.cores')
    template=$(echo "$container_config" | jq -r '.template')
    storage_pool=$(echo "$container_config" | jq -r '.storage_pool')
    storage_size_gb=$(echo "$container_config" | jq -r '.storage_size_gb')
    network_config=$(echo "$container_config" | jq -c '.network_config')
    features=$(echo "$container_config" | jq -r '.features // "nesting=1"')

    if [[ ! "$memory_mb" =~ ^[0-9]+$ ]] || [[ "$memory_mb" -lt 512 ]]; then
        log_error "create_lxc_container: Invalid memory_mb value for container $lxc_id: $memory_mb"
        return 1
    fi
    if [[ ! "$cores" =~ ^[0-9]+$ ]] || [[ "$cores" -lt 1 ]]; then
        log_error "create_lxc_container: Invalid cores value for container $lxc_id: $cores"
        return 1
    fi
    if [[ ! "$storage_size_gb" =~ ^[0-9]+$ ]] || [[ "$storage_size_gb" -lt 10 ]]; then
        log_error "create_lxc_container: Invalid storage_size_gb value for container $lxc_id: $storage_size_gb"
        return 1
    fi

    if [[ "$storage_pool" == *"zfs"* ]] && command -v zfs >/dev/null 2>&1; then
        if ! zfs list "$storage_pool" >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
            log_error "create_lxc_container: ZFS pool $storage_pool not found for container $lxc_id"
            return 1
        fi
        log_info "create_lxc_container: ZFS pool $storage_pool verified for container $lxc_id"
    fi

    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_info "create_lxc_container: Container $lxc_id already exists, skipping creation."
        return 0
    fi

    log_info "create_lxc_container: Creating LXC container $lxc_id ($name) with $memory_mb MB RAM, $cores CPU cores, and $storage_size_gb GB storage..."

    if ! pct create "$lxc_id" "$template" \
        -rootfs "$storage_pool:$storage_size_gb" \
        -memory "$memory_mb" \
        -cores "$cores" \
        -features "$features" \
        -net0 "name=eth0,bridge=vmbr0,ip=$(echo "$network_config" | jq -r '.ip'),gw=$(echo "$network_config" | jq -r '.gw')" \
        -ostype "ubuntu" \
        -searchdomain "local" \
        -hostname "$name"; then
        log_error "create_lxc_container: Failed to create container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    if ! pct set "$lxc_id" \
        -description "$name (created by Phoenix Hypervisor)" \
        -nameserver "8.8.8.8"; then
        log_error "create_lxc_container: Failed to configure container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    if [[ "$gpu_assignment" != "none" ]]; then
        log_info "create_lxc_container: Configuring GPU access for container $lxc_id with assignment: $gpu_assignment"
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log_error "create_lxc_container: Failed to configure GPU access for container $lxc_id"
            if [[ "$rollback" == "true" ]]; then
                pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
            fi
            return 1
        fi
    fi

    if ! pct start "$lxc_id"; then
        log_error "create_lxc_container: Failed to start container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    log_info "create_lxc_container: Container $lxc_id ($name) created and started successfully."
    return 0
}

# --- Container Execution Functions ---
pct_exec_with_retry() {
    lxc_id="$1"
    shift
    command="$*"

    max_attempts=3
    attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if pct exec "$lxc_id" bash -c "$command"; then
            return 0
        else
            log_warn "pct_exec_with_retry: Attempt $attempt failed for container $lxc_id, command: $command"
            ((attempt++))
            sleep 2
        fi
    done

    log_error "pct_exec_with_retry: Failed after $max_attempts attempts for container $lxc_id"
    return 1
}

start_systemd_service_in_container() {
    lxc_id="$1"
    service_name="$2"

    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        log_error "start_systemd_service_in_container: Missing required arguments (lxc_id or service_name)"
        return 1
    fi

    log_info "start_systemd_service_in_container: Starting service '$service_name' in container $lxc_id..."

    exec_func="pct_exec_with_retry"
    if declare -f lxc-attach >/dev/null 2>&1; then
        exec_func="lxc-attach"
    fi

    if ! "$exec_func" "$lxc_id" systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        if ! "$exec_func" "$lxc_id" systemctl enable "$service_name"; then
            log_warn "start_systemd_service_in_container: Failed to enable service '$service_name' in container $lxc_id"
            return 1
        fi
    fi

    if ! "$exec_func" "$lxc_id" systemctl start "$service_name"; then
        log_warn "start_systemd_service_in_container: Failed to start service '$service_name' in container $lxc_id"
        return 1
    fi

    sleep 2
    if ! "$exec_func" "$lxc_id" systemctl is-active --quiet "$service_name"; then
        log_warn "start_systemd_service_in_container: Service '$service_name' in container $lxc_id is not running after start"
        return 1
    fi

    log_info "start_systemd_service_in_container: Successfully started service '$service_name' in container $lxc_id"
    return 0
}

# --- Container Validation Functions ---
validate_container_status() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_container_status: Missing lxc_id"
        return 1
    fi

    log_info "validate_container_status: Validating status of container $lxc_id..."

    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "validate_container_status: Container $lxc_id does not exist"
        return 1
    fi

    status
    status=$(pct status "$lxc_id" 2>/dev/null)
    if [[ "$status" != "status: running" ]]; then
        log_warn "validate_container_status: Container $lxc_id is not running (status: $status)"
        return 1
    fi

    if ! check_container_network "$lxc_id"; then
        log_warn "validate_container_status: Network validation failed for container $lxc_id"
        return 1
    fi

    log_info "validate_container_status: Container $lxc_id is valid and running properly"
    return 0
}

check_container_network() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "check_container_network: Missing lxc_id"
        return 1
    fi

    log_info "check_container_network: Checking network connectivity for container $lxc_id..."

    if ! pct_exec_with_retry "$lxc_id" ping -c 1 -W 5 10.0.0.1 >/dev/null 2>&1; then
        log_warn "check_container_network: Failed to reach gateway from container $lxc_id"
        return 1
    fi

    if [[ "$lxc_id" != "999" ]]; then
        if ! pct_exec_with_retry "$lxc_id" ping -c 1 -W 5 10.0.0.99 >/dev/null 2>&1; then
            log_warn "check_container_network: Container $lxc_id cannot reach Portainer server (10.0.0.99)"
        else
            log_info "check_container_network: Container $lxc_id can reach Portainer server (10.0.0.99)"
        fi
    fi

    if ! pct_exec_with_retry "$lxc_id" nslookup google.com >/dev/null 2>&1; then
        log_warn "check_container_network: DNS resolution failed in container $lxc_id"
        return 1
    fi

    log_info "check_container_network: Container $lxc_id has proper network connectivity"
    return 0
}

validate_portainer_network_in_container() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_portainer_network_in_container: Missing lxc_id"
        return 1
    fi

    container_ip
    container_ip=$(jq -r ".lxc_configs.\"$lxc_id\".network_config.ip" "$PHOENIX_LXC_CONFIG_FILE" | cut -d'/' -f1)
    if [[ -z "$container_ip" || "$container_ip" == "null" ]]; then
        log_error "validate_portainer_network_in_container: Failed to retrieve IP address for container $lxc_id"
        return 1
    fi

    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        log_info "validate_portainer_network_in_container: Validating Portainer agent $lxc_id connectivity to server (10.0.0.99:9443)"

        if ! pct_exec_with_retry "$lxc_id" timeout 5 bash -c "echo | openssl s_client -connect 10.0.0.99:9443 2>/dev/null | grep -q 'Verify return code:'"; then
            log_warn "validate_portainer_network_in_container: Failed to connect to Portainer server (10.0.0.99:9443) from agent $lxc_id"
        else
            log_info "validate_portainer_network_in_container: Successfully connected to Portainer server from agent $lxc_id"
        fi

        if command -v curl >/dev/null 2>&1; then
            if ! pct_exec_with_retry "$lxc_id" curl -s -k -m 5 "https://10.0.0.99:9443/api/status" >/dev/null; then
                log_warn "validate_portainer_network_in_container: Failed to access Portainer API (10.0.0.99:9443/api/status) from agent $lxc_id"
            else
                log_info "validate_portainer_network_in_container: Successfully accessed Portainer API from agent $lxc_id"
            fi
        else
            log_info "validate_portainer_network_in_container: curl not available, skipping Portainer API check for agent $lxc_id"
        fi
    fi

    if [[ "$lxc_id" == "999" ]]; then
        log_info "validate_portainer_network_in_container: Validating Portainer server $lxc_id accessibility ($container_ip:9443)"

        if ! pct_exec_with_retry "$lxc_id" timeout 5 bash -c "echo | openssl s_client -connect $container_ip:9443 2>/dev/null | grep -q 'Verify return code:'"; then
            log_warn "validate_portainer_network_in_container: Failed to connect to Portainer server ($container_ip:9443)"
        else
            log_info "validate_portainer_network_in_container: Successfully connected to Portainer server ($container_ip:9443)"
        fi

        if command -v curl >/dev/null 2>&1; then
            if ! pct_exec_with_retry "$lxc_id" curl -s -k -m 5 "https://$container_ip:9443/api/status" >/dev/null; then
                log_warn "validate_portainer_network_in_container: Failed to access Portainer API ($container_ip:9443/api/status)"
            else
                log_info "validate_portainer_network_in_container: Successfully accessed Portainer API ($container_ip:9443/api/status)"
            fi
        else
            log_info "validate_portainer_network_in_container: curl not available, skipping Portainer API check for server $lxc_id"
        fi
    fi

    return 0
}

# --- Container Utility Functions ---
ensure_container_running() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "ensure_container_running: Container ID is required"
        return 2
    fi

    if pct config "$lxc_id" >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
        status
        status=$(pct status "$lxc_id" 2>/dev/null)
        if [[ "$status" == "status: running" ]]; then
            log_info "ensure_container_running: Container $lxc_id is already running"
            return 0
        else
            log_info "ensure_container_running: Container $lxc_id is stopped, starting it..."
            if pct start "$lxc_id" >/dev/null 2>&1; then
                log_info "ensure_container_running: Successfully started container $lxc_id"
                return 0
            else
                log_error "ensure_container_running: Failed to start container $lxc_id"
                return 1
            fi
        fi
    else
        log_error "ensure_container_running: Container $lxc_id does not exist"
        return 1
    fi
}

# --- AI Workload Specific Functions ---
validate_ai_workload_config() {
    lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_ai_workload_config: Container ID is required"
        return 1
    fi

    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        log_info "validate_ai_workload_config: Validating resources for AI container $lxc_id (e.g., vLLM, LLaMA CPP, Ollama)"

        memory_mb cores storage_size_gb gpu_assignment
        memory_mb=$(jq -r ".lxc_configs.\"$lxc_id\".memory_mb" "$PHOENIX_LXC_CONFIG_FILE")
        cores=$(jq -r ".lxc_configs.\"$lxc_id\".cores" "$PHOENIX_LXC_CONFIG_FILE")
        storage_size_gb=$(jq -r ".lxc_configs.\"$lxc_id\".storage_size_gb" "$PHOENIX_LXC_CONFIG_FILE")
        gpu_assignment=$(jq -r ".lxc_configs.\"$lxc_id\".gpu_assignment" "$PHOENIX_LXC_CONFIG_FILE")

        if [[ "$memory_mb" -lt 32768 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low memory ($memory_mb MB) for AI workload (recommended: 32 GB)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient memory ($memory_mb MB)"
        fi

        if [[ "$cores" -lt 6 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low CPU cores ($cores) for AI workload (recommended: 6+)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient CPU cores ($cores)"
        fi

        if [[ "$storage_size_gb" -lt 64 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low storage ($storage_size_gb GB) for AI workload (recommended: 64+ GB)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient storage ($storage_size_gb GB)"
        fi

        if [[ "$gpu_assignment" == "none" ]]; then
            log_info "validate_ai_workload_config: Container $lxc_id has no GPU assignment (may be intentional for CPU-only workloads)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has GPU assignment ($gpu_assignment)"
        fi
    else
        log_info "validate_ai_workload_config: Container $lxc_id is not an AI container (900-902), skipping AI-specific validation"
    fi

    return 0
}

# --- Helper Functions ---
setup_logging() {
    if [[ -z "$PHOENIX_LOG_DIR" ]]; then
        PHOENIX_LOG_DIR="/var/log/phoenix_hypervisor"
        PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_common.log"
    fi

    mkdir -p "$PHOENIX_LOG_DIR" 2>/dev/null || {
        PHOENIX_LOG_DIR="/tmp"
        PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_common.log"
    }

    touch "$PHOENIX_LOG_FILE" 2>/dev/null || true
    chmod 600 "$PHOENIX_LOG_FILE" 2>/dev/null || log_warn "Could not set permissions to 600 on $PHOENIX_LOG_FILE"

    log_info "setup_logging: Logging initialized for phoenix_hypervisor_common.sh"
}

# --- Initialize Configuration ---
if [[ -z "$PHOENIX_LXC_CONFIG_FILE" ]]; then
    export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"
fi

if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
    if ! load_hypervisor_config; then
        log_error "phoenix_hypervisor_common.sh: Failed to load hypervisor configuration."
        exit 1
    fi
fi

# Setup logging
setup_logging

log_info "phoenix_hypervisor_common.sh: Library loaded successfully with Hugging Face authentication and AI workload support."