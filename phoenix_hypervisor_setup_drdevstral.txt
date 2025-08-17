#!/bin/bash
# Container-specific setup script for drdevstral (LXC ID 901)
# Installs NVIDIA drivers, toolkit, vLLM, and sets up the AI model
# Version: 1.8.0
# Author: Assistant

set -euo pipefail
# Don't enable set -x here to avoid exposing secrets in logs

# Reset terminal state on exit to prevent corruption
trap 'stty sane; echo "Terminal reset"' EXIT

# --- Enhanced Sourcing ---
# Source configuration from the standard location
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    # Fallback to current directory if standard location not found (less ideal)
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
        else
            echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
        fi
    else
        echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
        exit 1
    fi
fi

# Source common functions from the standard location
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    else
        echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    fi
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from current directory. Prefer standard locations."
    else
        echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from current directory. Prefer standard locations." >&2
    fi
else
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Common functions file not found in standard locations." >&2
    exit 1
fi

# Source LXC NVIDIA functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh
elif [[ -f "./phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source ./phoenix_hypervisor_lxc_common_nvidia.sh
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced LXC NVIDIA functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
    else
        echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced LXC NVIDIA functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    fi
else
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Required LXC NVIDIA functions file (phoenix_hypervisor_lxc_common_nvidia.sh) not found." >&2
    exit 1
fi

# --- Logging Setup ---
setup_logging() {
    local log_dir="/var/log/phoenix_hypervisor"
    mkdir -p "$log_dir"
    touch "$HYPERVISOR_LOGFILE" "${HYPERVISOR_LOGFILE%.log}_debug.log"
    chmod 644 "$HYPERVISOR_LOGFILE" "${HYPERVISOR_LOGFILE%.log}_debug.log"
    if [[ ! -w "$HYPERVISOR_LOGFILE" ]] || [[ ! -w "${HYPERVISOR_LOGFILE%.log}_debug.log" ]]; then
        echo "[ERROR] Cannot write to log files: $HYPERVISOR_LOGFILE or ${HYPERVISOR_LOGFILE%.log}_debug.log" >&2
        exit 1
    fi
    exec 3>>"$HYPERVISOR_LOGFILE"
    exec 4>>"${HYPERVISOR_LOGFILE%.log}_debug.log"
}

setup_logging

# --- Dependency Validation ---
validate_dependencies() {
    log_info "Validating dependencies for container setup..."
    command -v jq >/dev/null 2>&1 || { log_error "jq not installed"; exit 1; }
    command -v pct >/dev/null 2>&1 || { log_error "pct not installed"; exit 1; }
    systemctl is-active --quiet apparmor || { log_error "apparmor service not active"; exit 1; }
    log_info "Dependencies validated successfully"
}

# --- Container State Validation ---
validate_container_state() {
    local container_id="$1"
    log_info "Validating container $container_id state..."
    if ! pct status "$container_id" | grep -q "running"; then
        log_info "Container $container_id is not running, attempting to start..."
        if ! retry_command 3 10 pct start "$container_id"; then
            log_error "Failed to start container $container_id"
            exit 1
        fi
    fi

    # Check if AppArmor unconfined profile is set properly
    if ! grep -q "lxc.apparmor.profile: unconfined" "/etc/pve/lxc/$container_id.conf"; then
        log_info "Adding AppArmor unconfined profile to container $container_id..."
        echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/$container_id.conf" || {
            log_error "Failed to set AppArmor profile for $container_id"
            exit 1
        }
        log_info "Restarting container $container_id to apply AppArmor profile..."
        pct stop "$container_id" || true
        sleep 5
        if ! retry_command 3 10 pct start "$container_id"; then
            log_error "Failed to restart container $container_id"
            exit 1
        fi
    else
        log_info "AppArmor unconfined profile already set for container $container_id"
    fi

    log_info "Container $container_id state validated successfully"
}

# --- Setup Functions ---

# - Validate Container Configuration -
validate_container() {
    local container_id="$1"
    log_info "DEBUG validate_container: Starting validation for container_id=$container_id"

    if ! command -v jq >/dev/null 2>&1; then
        log_error "DEBUG validate_container: 'jq' command not found."
        return 1
    fi

    log_info "DEBUG validate_container: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "DEBUG validate_container: Config file does not exist or is not a regular file."
        return 1
    fi
    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "DEBUG validate_container: Config file is not readable."
        return 1
    fi

    log_info "DEBUG validate_container: Fetching config for container $container_id"
    local container_config
    container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "DEBUG validate_container: No configuration found for container $container_id in $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    log_info "DEBUG validate_container: Container config fetched successfully: $container_config"

    local required_fields=(
        "name"
        "memory_mb"
        "cores"
        "template"
        "storage_pool"
        "storage_size_gb"
        "network_config"
        "features"
    )

    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field")
        if [[ -z "$value" || "$value" == "null" ]]; then
            log_error "DEBUG validate_container: Missing or invalid field '$field' for container $container_id"
            return 1
        fi
        log_info "DEBUG validate_container: Validated field '$field': $value"
    done

    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    log_info "DEBUG validate_container: GPU assignment: $gpu_assignment"
    if [[ "$gpu_assignment" != "none" ]]; then
        if ! echo "$gpu_assignment" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
            log_error "DEBUG validate_container: Invalid GPU assignment format: $gpu_assignment (expected comma-separated numbers, e.g., '0,1')"
            return 1
        fi
    fi

    local vllm_fields=(
        "vllm_model"
        "vllm_tensor_parallel_size"
        "vllm_max_model_len"
        "vllm_kv_cache_dtype"
        "vllm_shm_size"
        "vllm_gpu_count"
        "vllm_quantization"
        "vllm_quantization_config_type"
        "vllm_api_port"
    )

    for field in "${vllm_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field // empty")
        if [[ -n "$value" ]]; then
            log_info "DEBUG validate_container: vLLM field '$field' present: $value"
        fi
    done

    log_info "DEBUG validate_container: Container $container_id configuration validated successfully."
    return 0
}

# - Helper: Get Container Config Value -
get_container_config_value() {
    local container_id="$1"
    local field="$2"
    local value

    if ! command -v jq >/dev/null 2>&1; then
        log_error "get_container_config_value: 'jq' command not found."
        return 1
    fi

    value=$(jq -r ".lxc_configs.\"$container_id\".$field // empty" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$value" || "$value" == "null" ]]; then
        log_error "get_container_config_value: Field '$field' not found or empty for container $container_id"
        return 1
    fi
    echo "$value"
    return 0
}

# - Helper: Execute Command in Container with Retry -
pct_exec_with_retry() {
    local container_id="$1"
    local command="$2"
    local max_attempts=3
    local delay=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "pct_exec_with_retry: Executing command in container $container_id (attempt $attempt/$max_attempts)..."
        # Use heredoc to handle multi-line commands robustly
        if pct exec "$container_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$command
EOF
        then
            log_info "pct_exec_with_retry: Command executed successfully in container $container_id"
            return 0
        else
            log_warn "pct_exec_with_retry: Command failed in container $container_id. Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "pct_exec_with_retry: Command failed after $max_attempts attempts in container $container_id"
    return 1
}

# - Show Setup Information -
show_setup_info() {
    local container_id="$1"
    log_info "show_setup_info: Displaying setup configuration for container $container_id..."

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP CONFIGURATION"
    echo "==============================================="
    echo "Container ID: $container_id"
    local name memory_mb cores template storage_pool storage_size_gb network_config features
    name=$(get_container_config_value "$container_id" "name") || name="N/A"
    memory_mb=$(get_container_config_value "$container_id" "memory_mb") || memory_mb="N/A"
    cores=$(get_container_config_value "$container_id" "cores") || cores="N/A"
    template=$(get_container_config_value "$container_id" "template") || template="N/A"
    storage_pool=$(get_container_config_value "$container_id" "storage_pool") || storage_pool="N/A"
    storage_size_gb=$(get_container_config_value "$container_id" "storage_size_gb") || storage_size_gb="N/A"
    network_config=$(get_container_config_value "$container_id" "network_config") || network_config="N/A"
    features=$(get_container_config_value "$container_id" "features") || features="N/A"
    echo "Name: $name"
    echo "Memory: $memory_mb MB"
    echo "Cores: $cores"
    echo "Template: $template"
    echo "Storage Pool: $storage_pool"
    echo "Storage Size: $storage_size_gb GB"
    echo "Network Config: $network_config"
    echo "Features: $features"
    echo ""
    echo "vLLM Configuration:"
    local vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type vllm_api_port
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || vllm_model="N/A"
    vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size") || vllm_tensor_parallel_size="N/A"
    vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len") || vllm_max_model_len="N/A"
    vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype") || vllm_kv_cache_dtype="N/A"
    vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size") || vllm_shm_size="N/A"
    vllm_gpu_count=$(get_container_config_value "$container_id" "vllm_gpu_count") || vllm_gpu_count="N/A"
    vllm_quantization=$(get_container_config_value "$container_id" "vllm_quantization") || vllm_quantization="N/A"
    vllm_quantization_config_type=$(get_container_config_value "$container_id" "vllm_quantization_config_type") || vllm_quantization_config_type="N/A"
    vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port") || vllm_api_port="N/A"
    echo "Model: $vllm_model"
    echo "Tensor Parallel Size: $vllm_tensor_parallel_size"
    echo "Max Model Length: $vllm_max_model_len"
    echo "KV Cache Data Type: $vllm_kv_cache_dtype"
    echo "Shared Memory Size: $vllm_shm_size"
    echo "GPU Count: $vllm_gpu_count"
    echo "Quantization: $vllm_quantization"
    echo "Quantization Config Type: $vllm_quantization_config_type"
    echo "API Port: $vllm_api_port"
    echo ""
    echo "GPU Assignment:"
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    echo "GPUs: $gpu_assignment"
    echo "==============================================="
    echo ""
}

# - Setup Container Environment -
setup_container_environment() {
    local container_id="$1"
    log_info "Setting up environment for container $container_id..."
    echo "Setting up base environment for container $container_id... This may take a few minutes."

    # Start the container if not running
    local status
    status=$(pct status "$container_id" 2>/dev/null | grep 'status' | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_info "Starting container $container_id..."
        if ! pct start "$container_id"; then
            log_error "setup_container_environment: Failed to start container $container_id"
            return 1
        fi
        sleep 10
    fi

    # Check network connectivity
    local network_check_cmd="
set -e
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
ping -c 4 8.8.8.8 || { echo '[ERROR] Network connectivity check failed'; exit 1; }
"
    if ! pct_exec_with_retry "$container_id" "$network_check_cmd"; then
        log_error "setup_container_environment: Network connectivity check failed for container $container_id"
        return 1
    fi
    log_info "Network connectivity verified for container $container_id"

    # Update package lists and install base dependencies
    local setup_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
echo '[INFO] Updating package lists... This may take a few minutes.'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Upgrading packages... This may take a few minutes.'
apt-get upgrade -y --fix-missing || { echo '[ERROR] Failed to upgrade packages'; exit 1; }
echo '[INFO] Installing base dependencies... This may take a few minutes.'
apt-get install -y python3 python3-pip git curl wget docker.io nvtop || { echo '[ERROR] Failed to install base dependencies'; exit 1; }
if apt-cache show python3-huggingface-hub >/dev/null 2>&1; then
    apt-get install -y python3-huggingface-hub
else
    apt-get install -y pipx
    pipx install huggingface_hub
    pipx ensurepath
fi
systemctl start docker || true
systemctl enable docker || true
"
    if ! pct_exec_with_retry "$container_id" "$setup_cmd"; then
        log_error "setup_container_environment: Failed to install base dependencies in container $container_id"
        return 1
    fi

    log_info "Container environment setup completed for $container_id"
    echo "Base environment setup completed for container $container_id."
    return 0
}

# - Setup NVIDIA Packages and Toolkit -
setup_nvidia_packages() {
    local container_id="$1"
    log_info "Installing NVIDIA packages and toolkit in container $container_id..."
    echo "Installing NVIDIA packages and toolkit for container $container_id... This may take several minutes."

    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    if [[ "$gpu_assignment" == "none" ]]; then
        log_info "No GPU assignment for container $container_id, skipping NVIDIA package setup."
        return 0
    fi

    # Install CUDA keyring, NVIDIA driver, and container toolkit
    local nvidia_setup_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/cuda-archive-keyring.gpg ]]; then
    echo '[INFO] Downloading CUDA keyring...'
    wget -qO /etc/apt/keyrings/cuda-archive-keyring.gpg https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-archive-keyring.gpg || { echo '[ERROR] Failed to download CUDA keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/cuda.list ]]; then
    echo '[INFO] Setting up CUDA repository...'
    echo 'deb [signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /' | tee /etc/apt/sources.list.d/cuda.list > /dev/null
fi
echo '[INFO] Updating package lists... This may take a few minutes.'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
if ! dpkg -l | grep -q nvidia-open-580; then
    echo '[INFO] Installing NVIDIA open driver (580)... This may take a few minutes.'
    apt-get install -y --no-install-recommends nvidia-open-580 || { echo '[ERROR] Failed to install NVIDIA driver'; exit 1; }
fi
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    echo '[INFO] Installing NVIDIA Container Toolkit... This may take a few minutes.'
    apt-get install -y nvidia-container-toolkit || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; exit 1; }
fi
if ! dpkg -l | grep -q docker.io; then
    echo '[INFO] Installing Docker... This may take a few minutes.'
    apt-get install -y docker.io || { echo '[ERROR] Failed to install Docker'; exit 1; }
fi
"
    if ! pct_exec_with_retry "$container_id" "$nvidia_setup_cmd"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA packages in container $container_id"
        return 1
    fi

    # Configure NVIDIA runtime for Docker
    local nvidia_runtime_cmd="
set -e
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
fi
if [[ ! -f /etc/docker/daemon.json ]]; then
    echo '[INFO] Configuring NVIDIA runtime for Docker...'
    nvidia-ctk runtime configure --runtime=nvidia || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
    systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
fi
"
    if ! pct_exec_with_retry "$container_id" "$nvidia_runtime_cmd"; then
        log_error "setup_nvidia_packages: Failed to configure NVIDIA runtime for Docker in container $container_id"
        return 1
    fi

    # Verify GPU access
    if ! pct_exec_with_retry "$container_id" "nvidia-smi"; then
        log_error "setup_nvidia_packages: Failed to verify GPU access in container $container_id"
        return 1
    fi

    log_info "NVIDIA packages and toolkit installed successfully for container $container_id"
    echo "NVIDIA packages and toolkit setup completed for container $container_id."
    return 0
}

# - Setup Model -
setup_model() {
    local container_id="$1"
    local vllm_model
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || {
        log_error "setup_model: Failed to retrieve vllm_model for container $container_id"
        return 1
    }

    log_info "Setting up model $vllm_model in container $container_id..."
    echo "Downloading model $vllm_model for container $container_id... This may take several minutes."

    local hf_token=""
    if [[ -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        hf_token=$(cat "$PHOENIX_HF_TOKEN_FILE" | tr -d ' \t\n\r')
        if [[ -z "$hf_token" ]]; then
            log_error "setup_model: Hugging Face token file is empty: $PHOENIX_HF_TOKEN_FILE"
            return 1
        fi
    else
        log_warn "setup_model: Hugging Face token file not found: $PHOENIX_HF_TOKEN_FILE. Attempting model download without authentication."
    fi

    local model_cmd="
set -e
mkdir -p /models
export HF_TOKEN='$hf_token'
for i in 1 2 3; do
    echo \"[INFO] Attempting to download model $vllm_model (attempt \$i)\"
    if /usr/bin/python3 -m huggingface_hub download --repo-type model --local-dir /models/$vllm_model $vllm_model; then
        echo '[SUCCESS] Model downloaded successfully'
        exit 0
    else
        echo '[WARNING] Model download failed, retrying in 10 seconds...'
        sleep 10
    fi
done
echo '[ERROR] Failed to download model after 3 attempts'
exit 1
"
    if ! pct_exec_with_retry "$container_id" "$model_cmd"; then
        log_error "setup_model: Failed to download model $vllm_model in container $container_id"
        return 1
    fi

    log_info "Model $vllm_model downloaded successfully in container $container_id"
    echo "Model $vllm_model download completed for container $container_id."
    return 0
}

# - Setup vLLM Service -
setup_service() {
    local container_id="$1"
    local vllm_model=$(get_container_config_value "$container_id" "vllm_model")
    local vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size")
    local vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len")
    local vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype")
    local vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size")
    local vllm_gpu_count=$(get_container_config_value "$container_id" "vllm_gpu_count")
    local vllm_quantization=$(get_container_config_value "$container_id" "vllm_quantization")
    local vllm_quantization_config_type=$(get_container_config_value "$container_id" "vllm_quantization_config_type")
    local vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port")

    log_info "Setting up Docker-based vLLM service in container $container_id..."
    echo "Configuring vLLM Docker service for container $container_id..."

    # Ensure AppArmor configuration (already handled in validate_container_state, but keep for robustness)
    local apparmor_cmd="
set -e
if ! grep -q 'lxc.apparmor.profile: unconfined' /etc/pve/lxc/$container_id.conf; then
    echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/$container_id.conf
fi
"
    if ! pct_exec_with_retry "$container_id" "$apparmor_cmd"; then
        log_info "Could not update AppArmor config for container, continuing anyway..."
    fi

    local service_cmd="
set -e
cat <<EOF > /etc/systemd/system/vllm-docker.service
[Unit]
Description=vLLM Docker Container
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker run --rm --name vllm \\
    --gpus all \\
    --runtime=nvidia \\
    -p $vllm_api_port:8000 \\
    -v /models:/models \\
    --shm-size=$vllm_shm_size \\
    vllm/vllm-openai:latest \\
    --model /models/$vllm_model \\
    --tensor-parallel-size $vllm_tensor_parallel_size \\
    --max-model-len $vllm_max_model_len \\
    --kv-cache-dtype $vllm_kv_cache_dtype \\
    --gpu-memory-utilization 0.9 \\
    --quantization $vllm_quantization

ExecStop=/usr/bin/docker stop vllm
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vllm-docker.service
"
    if ! pct_exec_with_retry "$container_id" "$service_cmd"; then
        log_error "setup_service: Failed to set up vLLM Docker service in container $container_id"
        return 1
    fi

    log_info "vLLM Docker service configured successfully in container $container_id"
    echo "vLLM Docker service configured for container $container_id."
    return 0
}

# - Validate Final Setup -
validate_final_setup() {
    local container_id="$1"
    local checks_passed=0
    local checks_failed=0

    log_info "Validating final setup for container $container_id..."
    echo "Validating final setup for container $container_id..."

    local status
    status=$(pct status "$container_id" 2>/dev/null | grep 'status' | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        log_info "validate_final_setup: Container $container_id is running"
        ((checks_passed++))
    else
        log_error "validate_final_setup: Container $container_id is not running (status: $status)"
        ((checks_failed++))
    fi

    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    if [[ "$gpu_assignment" != "none" ]]; then
        if pct_exec_with_retry "$container_id" "nvidia-smi"; then
            log_info "validate_final_setup: GPU access verified for container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: GPU access verification failed for container $container_id"
            ((checks_failed++))
        fi
        # Verify NVIDIA Container Toolkit and Docker GPU access
        local docker_gpu_check="
set -e
if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:12.0-base nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] Docker GPU access verified'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed'
    exit 1
fi
"
        if pct_exec_with_retry "$container_id" "$docker_gpu_check"; then
            log_info "validate_final_setup: Docker GPU access verified for container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: Docker GPU access verification failed for container $container_id"
            ((checks_failed++))
        fi
    else
        log_info "validate_final_setup: No GPU assignment for container $container_id, skipping GPU check"
        ((checks_passed++))
    fi

    local vllm_model
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || vllm_model=""
    if [[ -n "$vllm_model" ]]; then
        local model_check_cmd="
set -e
if [[ -d \"/models/$vllm_model\" ]]; then
    echo '[SUCCESS] Model directory exists: /models/$vllm_model'
    exit 0
else
    echo '[ERROR] Model directory does not exist: /models/$vllm_model'
    exit 1
fi
"
        if pct_exec_with_retry "$container_id" "$model_check_cmd"; then
            log_info "validate_final_setup: Model directory exists for $vllm_model in container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: Model directory check failed for $vllm_model in container $container_id"
            ((checks_failed++))
        fi
    else
        log_error "validate_final_setup: vLLM model not specified for container $container_id"
        ((checks_failed++))
    fi

    local service_check_cmd="
set -e
if systemctl list-unit-files | grep -q 'vllm-docker.service'; then
    echo '[SUCCESS] vLLM Docker service is configured'
    exit 0
else
    echo '[ERROR] vLLM Docker service is not configured'
    exit 1
fi
"
    if pct_exec_with_retry "$container_id" "$service_check_cmd"; then
        log_info "validate_final_setup: vLLM Docker service is configured in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: vLLM Docker service configuration check failed in container $container_id"
        ((checks_failed++))
    fi

    local docker_check_cmd="
set -e
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo '[SUCCESS] Docker is installed and running'
    exit 0
else
    echo '[ERROR] Docker is not installed or not running'
    exit 1
fi
"
    if pct_exec_with_retry "$container_id" "$docker_check_cmd"; then
        log_info "validate_final_setup: Docker is installed and running in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: Docker check failed in container $container_id"
        ((checks_failed++))
    fi

    local nvtop_check_cmd="
set -e
if command -v nvtop >/dev/null 2>&1; then
    echo '[SUCCESS] nvtop is installed'
    exit 0
else
    echo '[ERROR] nvtop is not installed'
    exit 1
fi
"
    if pct_exec_with_retry "$container_id" "$nvtop_check_cmd"; then
        log_info "validate_final_setup: nvtop is installed in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: nvtop check failed in container $container_id"
        ((checks_failed++))
    fi

    log_info "validate_final_setup: Validation summary: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "validate_final_setup: Validation completed with $checks_failed failures. Check logs for details."
        return 1
    fi
    log_info "All validation checks passed for container $container_id"
    echo "All validation checks passed for container $container_id."
    return 0
}

# --- Main Execution ---
main() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Container ID must be provided as an argument"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Container ID must be provided as an argument" >&2
        fi
        echo "Usage: $0 <container_id>"
        exit 1
    fi

    if [[ "$container_id" != "901" ]]; then
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: This script is designed for container ID 901, got $container_id"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: This script is designed for container ID 901, got $container_id" >&2
        fi
        exit 1
    fi

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP FOR CONTAINER $container_id"
    echo "==============================================="
    log_info "Starting drdevstral setup for container $container_id..."

    log_info "Calling validate_dependencies..."
    validate_dependencies

    log_info "Calling validate_container_state..."
    validate_container_state "$container_id"

    # Configure GPU passthrough
    local gpu_assignment
    gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Configuring GPU passthrough for container $container_id..."
        if ! configure_lxc_gpu_passthrough "$container_id" "$gpu_assignment"; then
            log_error "Failed to configure GPU passthrough for container $container_id"
            exit 1
        fi
        log_info "Restarting container $container_id to apply GPU passthrough..."
        pct stop "$container_id" || true
        sleep 5
        if ! retry_command 3 10 pct start "$container_id"; then
            log_error "Failed to restart container $container_id after GPU passthrough"
            exit 1
        fi
    fi

    log_info "Calling validate_container..."
    validate_container "$container_id"

    log_info "Calling show_setup_info..."
    show_setup_info "$container_id"

    log_info "Calling setup_container_environment..."
    if ! setup_container_environment "$container_id"; then
        log_error "phoenix_hypervisor_setup_drdevstral.sh: Container environment setup failed for $container_id"
        exit 1
    fi

    log_info "Calling setup_nvidia_packages..."
    if ! setup_nvidia_packages "$container_id"; then
        log_error "phoenix_hypervisor_setup_drdevstral.sh: Failed to install NVIDIA packages for $container_id"
        exit 1
    fi

    log_info "Calling setup_model..."
    if ! setup_model "$container_id"; then
        log_error "phoenix_hypervisor_setup_drdevstral.sh: Model setup failed for $container_id"
        exit 1
    fi

    log_info "Calling setup_service..."
    if ! setup_service "$container_id"; then
        log_error "phoenix_hypervisor_setup_drdevstral.sh: Service setup failed for $container_id"
        exit 1
    fi

    log_info "Calling validate_final_setup..."
    if ! validate_final_setup "$container_id"; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Final setup validation had warnings for $container_id"
    fi

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP COMPLETED"
    echo "==============================================="
    log_info "drdevstral setup completed successfully for $container_id"
    log_info "You can now start the service with: pct exec $container_id -- systemctl start vllm-docker.service"
    log_info "Check status with: pct exec $container_id -- systemctl status vllm-docker.service"
    echo "You can now start the vLLM service with: pct exec $container_id -- systemctl start vllm-docker.service"
    echo "Check service status with: pct exec $container_id -- systemctl status vllm-docker.service"
    echo "==============================================="
}

# Call main function with the passed argument
main "$1"