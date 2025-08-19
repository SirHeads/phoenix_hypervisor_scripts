#!/bin/bash
# Container-specific setup script for drdevstral (LXC ID 901)
# Installs NVIDIA drivers, toolkit, vLLM, and sets up the AI model
# Version: 1.8.13
# Author: Assistant

set -euo pipefail

# Reset terminal state on exit
trap 'stty sane; echo "Terminal reset"' EXIT

# --- Enhanced Sourcing ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
    echo "DEBUG: Sourced config from /usr/local/etc/phoenix_hypervisor_config.sh" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"
elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
    source ./phoenix_hypervisor_config.sh
    echo "DEBUG: Sourced config from ./phoenix_hypervisor_config.sh" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
    else
        echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
    fi
else
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
    exit 1
fi

# Set default for DEFAULT_VLLM_IMAGE if not defined
if [[ -z "${DEFAULT_VLLM_IMAGE:-}" ]]; then
    DEFAULT_VLLM_IMAGE="vllm/vllm-openai:cuda13"
    echo "DEBUG: DEFAULT_VLLM_IMAGE was unset, defaulting to $DEFAULT_VLLM_IMAGE" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"
fi
echo "DEBUG: DEFAULT_VLLM_IMAGE=$DEFAULT_VLLM_IMAGE" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"

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
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Required LXC NVIDIA functions file not found." >&2
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
    log_info "Validating container configuration for container_id=$container_id"

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq command not found."
        return 1
    fi

    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Config file does not exist: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Config file is not readable: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    local container_config
    container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "No configuration found for container $container_id in $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    local required_fields=(
        "name"
        "memory_mb"
        "cores"
        "template"
        "storage_pool"
        "storage_size_gb"
        "network_config"
        "features"
        "vllm_model"
        "vllm_api_port"
    )

    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field")
        if [[ -z "$value" || "$value" == "null" ]]; then
            log_error "Missing or invalid field '$field' for container $container_id"
            return 1
        fi
    done

    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    if [[ "$gpu_assignment" != "none" ]]; then
        if ! echo "$gpu_assignment" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
            log_error "Invalid GPU assignment format: $gpu_assignment (expected comma-separated numbers)"
            return 1
        fi
    fi

    local vllm_fields=(
        "vllm_tensor_parallel_size"
        "vllm_max_model_len"
        "vllm_kv_cache_dtype"
        "vllm_shm_size"
        "vllm_gpu_count"
        "vllm_gpu_memory_utilization"
        "vllm_dtype"
        "vllm_attention_backend"
        "vllm_nccl_so_path"
    )

    for field in "${vllm_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field // empty")
        if [[ -n "$value" ]]; then
            log_info "vLLM field '$field' present: $value"
        fi
    done

    log_info "Container $container_id configuration validated successfully."
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

# - Helper: Get Global Config Value -
get_global_config_value() {
    local field="$1"
    local value

    if ! command -v jq >/dev/null 2>&1; then
        log_error "get_global_config_value: 'jq' command not found."
        return 1
    fi

    value=$(jq -r ".$field // empty" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$value" || "$value" == "null" ]]; then
        log_error "get_global_config_value: Field '$field' not found or empty"
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
        log_info "Executing command in container $container_id (attempt $attempt/$max_attempts)..."
        if pct exec "$container_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$command
EOF
        then
            log_info "Command executed successfully in container $container_id"
            return 0
        else
            log_warn "Command failed in container $container_id. Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "Command failed after $max_attempts attempts in container $container_id"
    return 1
}

# - Build Custom vLLM Image -
build_custom_vllm_image() {
    local container_id="$1"
    local image_tag="${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13}"

    log_info "Building custom vLLM image $image_tag in container $container_id..."
    echo "Building custom vLLM image $image_tag for container $container_id... This may take several minutes."

    local dockerfile_cmd="set -e
    mkdir -p /root/vllm-build
    cd /root/vllm-build

    # Create a minimal Dockerfile
    cat <<'EOF' > Dockerfile
    # Use the official vLLM CUDA image as the base
    # Pinning to a specific tag is recommended for stability
    # Example alternative: FROM vllm/vllm-openai:v0.8.1
    FROM vllm/vllm-openai:latest

    # Switch to root user to install system packages
    USER root

    # Install common utilities if needed (usually already present)
    # RUN apt-get update && apt-get install -y --no-install-recommends \\
    #     curl wget git \\
    #     && rm -rf /var/lib/apt/lists/*

    # Install flashinfer via pip
    # Using --no-build-isolation can sometimes help if there are build environment conflicts,
    # but it's generally better to ensure dependencies are correct.
    # --extra-index-url is needed for flashinfer wheels.
    RUN pip install --upgrade pip && \\
        pip install flashinfer --extra-index-url https://flashinfer.ai/whl/cu121/torch2.4/

    # Optional: Install pyairports or outlines if needed by your specific use case
    # Be cautious with outlines versions if they caused issues before.
    # RUN pip install pyairports || echo \"Warning: pyairports installation failed\"
    # RUN pip install outlines==0.0.34 || echo \"Warning: outlines installation failed\"

    # Set the NCCL path environment variable
    # This tells vLLM where to look for NCCL *inside* the container.
    # It should match the path where NCCL is accessible within the official image context.
    # The official image likely already has NCCL, but setting this ensures consistency
    # with your configuration, especially if mounting from the host LXC filesystem.
    ENV VLLM_NCCL_SO_PATH=/usr/lib/x86_64-linux-gnu/libnccl.so

    # Switch back to the non-root user (usually 'vllm') for running the service
    # Check the base image's USER directive. vllm images often run as 'vllm'.
    # USER vllm

    # The base image's CMD is usually ['serve'], so we don't need to redefine it
    # unless we want to override default arguments.
    # CMD [\"serve\"]
    EOF

    echo '[INFO] Building custom vLLM image $image_tag from updated Dockerfile...'
    # Build the image
    if docker build -t $image_tag /root/vllm-build; then
        echo '[SUCCESS] Custom vLLM image $image_tag built successfully.'
        else
        echo '[ERROR] Failed to build custom vLLM image $image_tag.'
        exit 1
    fi
    "

    if ! pct_exec_with_retry "$container_id" "$dockerfile_cmd"; then
        log_error "build_custom_vllm_image: Failed to build custom vLLM image $image_tag in container $container_id"
        return 1
    fi

    log_info "Custom vLLM image $image_tag built successfully in container $container_id"
    echo "Custom vLLM image $image_tag build completed for container $container_id."
    return 0
}

# - Show Setup Information -
show_setup_info() {
    local container_id="$1"
    log_info "Displaying setup configuration for container $container_id..."

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
    local vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_api_port vllm_gpu_memory_utilization vllm_dtype vllm_attention_backend vllm_nccl_so_path
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || vllm_model="N/A"
    vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size") || vllm_tensor_parallel_size="N/A"
    vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len") || vllm_max_model_len="N/A"
    vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype") || vllm_kv_cache_dtype="N/A"
    vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size") || vllm_shm_size="N/A"
    vllm_gpu_count=$(get_container_config_value "$container_id" "vllm_gpu_count") || vllm_gpu_count="N/A"
    vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port") || vllm_api_port="N/A"
    vllm_gpu_memory_utilization=$(get_container_config_value "$container_id" "vllm_gpu_memory_utilization") || vllm_gpu_memory_utilization="N/A"
    vllm_dtype=$(get_container_config_value "$container_id" "vllm_dtype") || vllm_dtype="N/A"
    vllm_attention_backend=$(get_container_config_value "$container_id" "vllm_attention_backend") || vllm_attention_backend="N/A"
    vllm_nccl_so_path=$(get_container_config_value "$container_id" "vllm_nccl_so_path") || vllm_nccl_so_path="N/A"
    echo "Model Path: $vllm_model"
    echo "Tensor Parallel Size: $vllm_tensor_parallel_size"
    echo "Max Model Length: $vllm_max_model_len"
    echo "KV Cache Data Type: $vllm_kv_cache_dtype"
    echo "Shared Memory Size: $vllm_shm_size"
    echo "GPU Count: $vllm_gpu_count"
    echo "GPU Memory Utilization: $vllm_gpu_memory_utilization"
    echo "Data Type: $vllm_dtype"
    echo "Attention Backend: $vllm_attention_backend"
    echo "NCCL SO Path: $vllm_nccl_so_path"
    echo ""
    echo "GPU Assignment:"
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    echo "GPUs: $gpu_assignment"
    echo ""
    echo "NVIDIA Configuration:"
    local nvidia_driver_version nvidia_repo_url
    nvidia_driver_version=$(get_global_config_value "nvidia_driver_version") || nvidia_driver_version="N/A"
    nvidia_repo_url=$(get_global_config_value "nvidia_repo_url") || nvidia_repo_url="N/A"
    echo "NVIDIA Driver Version: $nvidia_driver_version"
    echo "NVIDIA Repository URL: $nvidia_repo_url"
    echo "==============================================="
    echo ""
}

# - Setup Container Environment -
setup_container_environment() {
    local container_id="$1"
    log_info "Setting up environment for container $container_id..."
    echo "Setting up base environment for container $container_id... This may take a few minutes."

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

    local network_check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
ping -c 4 8.8.8.8 || { echo '[ERROR] Network connectivity check failed'; exit 1; }
"
    if ! pct_exec_with_retry "$container_id" "$network_check_cmd"; then
        log_error "setup_container_environment: Network connectivity check failed for container $container_id"
        return 1
    fi
    log_info "Network connectivity verified for container $container_id"

    local setup_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Setting up locale...'
apt-get update -y --fix-missing
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Updating package lists... This may take a few minutes.'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Upgrading packages... This may take a few minutes.'
apt-get upgrade -y --fix-missing || { echo '[ERROR] Failed to upgrade packages'; exit 1; }
echo '[INFO] Installing base dependencies... This may take a few minutes.'
apt-get install -y python3 python3-pip git curl wget pipx nvtop || { echo '[ERROR] Failed to install base dependencies'; exit 1; }
echo '[INFO] Installing huggingface_hub...'
if /usr/bin/python3 -m pip install --user --break-system-packages huggingface_hub; then
    echo '[INFO] huggingface_hub installed via pip --user --break-system-packages'
    export PATH=\"/root/.local/bin:\$PATH\"
    if /usr/bin/python3 -c \"import huggingface_hub; print(f\\\"huggingface_hub version: {huggingface_hub.__version__}\\\")\"; then
        echo '[INFO] huggingface_hub import verified successfully'
    else
        echo '[ERROR] huggingface_hub module not importable after pip install --user --break-system-packages'
        exit 1
    fi
else
    echo '[ERROR] Failed to install huggingface_hub via pip --user --break-system-packages'
    if pipx install huggingface_hub; then
        echo '[WARN] Installed via pipx, verifying import might fail if library not in system path'
        pipx ensurepath
        export PATH=\"/root/.local/bin:\$PATH\"
    else
        echo '[ERROR] Failed to install huggingface_hub via pipx as well'
        exit 1
    fi
fi
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

    local nvidia_driver_version nvidia_repo_url
    nvidia_driver_version=$(get_global_config_value "nvidia_driver_version") || nvidia_driver_version="$NVIDIA_DRIVER_VERSION"
    nvidia_repo_url=$(get_global_config_value "nvidia_repo_url" | sed 's/[[:space:]]*$//') || nvidia_repo_url="$NVIDIA_REPO_URL"

    if ! install_docker_ce_in_container "$container_id"; then
        log_error "setup_nvidia_packages: Failed to install Docker-ce in container $container_id"
        return 1
    fi

    if ! setup_nvidia_repo_in_container "$container_id" "$nvidia_repo_url"; then
        log_error "setup_nvidia_packages: Failed to set up NVIDIA repositories in container $container_id"
        return 1
    fi

    if ! install_nvidia_userland_in_container "$container_id" "$nvidia_driver_version"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA driver in container $container_id"
        return 1
    fi

    if ! install_nvidia_toolkit_in_container "$container_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA Container Toolkit in container $container_id"
        return 1
    fi

    if ! configure_docker_nvidia_runtime "$container_id"; then
        log_error "setup_nvidia_packages: Failed to configure NVIDIA runtime in container $container_id"
        return 1
    fi

    if ! verify_lxc_gpu_access_in_container "$container_id" "$gpu_assignment"; then
        log_error "setup_nvidia_packages: Failed to verify GPU access in container $container_id"
        return 1
    fi

    log_info "NVIDIA packages and toolkit installed successfully for container $container_id"
    echo "NVIDIA packages and toolkit setup completed for container $container_id."
    return 0
}

# --- NEW FUNCTION: Install NCCL Library ---
install_nccl_library_in_container() {
    local lxc_id="$1"
    # Note: driver_version argument removed as it's not directly used for libnccl-dev versioning in standard repos for this case.
    # If specific CUDA/NCCL versioning is needed, logic would need adjustment.

    log_info "install_nccl_library_in_container: Installing NCCL library in container $lxc_id"

    # Command to install the NCCL development package inside the container
    # This places the library in /usr/lib/x86_64-linux-gnu/
    local install_cmd="
    set -e
    export DEBIAN_FRONTEND=noninteractive
    echo '[INFO] Updating package lists...'
    apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
    echo '[INFO] Installing libnccl-dev...'
    apt-get install -y libnccl-dev || { echo '[ERROR] Failed to install libnccl-dev'; exit 1; }

    # Check if the library file exists in the standard location after installation
    STANDARD_NCCL_PATH='/usr/lib/x86_64-linux-gnu/libnccl.so'
    if [[ -f \"\$STANDARD_NCCL_PATH\" ]]; then
        echo '[SUCCESS] libnccl-dev installed, libnccl.so found at \$STANDARD_NCCL_PATH.'
    elif [[ -L \"\$STANDARD_NCCL_PATH\" ]]; then # Check if it's a symlink
         echo '[SUCCESS] libnccl-dev installed, libnccl.so found (symlink) at \$STANDARD_NCCL_PATH.'
    else
        echo '[ERROR] libnccl-dev installed but libnccl.so not found in expected location (\$STANDARD_NCCL_PATH).'
        exit 1
    fi
    "

    # Execute the installation command inside the container
    if ! pct_exec_with_retry "$lxc_id" "$install_cmd"; then
        log_error "install_nccl_library_in_container: Failed to install NCCL library in container $lxc_id"
        return 1
    fi

    log_info "install_nccl_library_in_container: NCCL library installed successfully in container $lxc_id"
    return 0
}

# - Setup Model -
setup_model() {
    local container_id="$1"
    local vllm_model_raw
    vllm_model_raw=$(get_container_config_value "$container_id" "vllm_model") || {
        log_error "setup_model: Failed to retrieve vllm_model for container $container_id"
        return 1
    }
    # Extract the Hugging Face model ID from the path (e.g., /models/Qwen/Qwen2.5-Coder-7B-Instruct -> Qwen/Qwen2.5-Coder-7B-Instruct)
    local vllm_model_hf_id="${vllm_model_raw#/models/}"

    log_info "Setting up model $vllm_model_hf_id in container $container_id..."
    echo "Downloading model $vllm_model_hf_id for container $container_id... This may take several minutes."
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
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export PATH=\"/root/.local/bin:\$PATH\"
mkdir -p /models
# Check available disk space (needs ~20GB for Qwen2.5-Coder-7B-Instruct)
required_space=20000000  # 20GB in KB
available_space=\$(df -k /models | tail -1 | awk '{print \$4}')
if [ \$available_space -lt \$required_space ]; then
    echo \"[ERROR] Insufficient disk space in /models: \$available_space KB available, \$required_space KB required\"
    exit 1
fi
export HF_TOKEN=\"$hf_token\"
for i in 1 2 3; do
    echo \"[INFO] Attempting to download model $vllm_model_hf_id (attempt \$i)\"
    if huggingface-cli download --repo-type model --local-dir /models/$vllm_model_hf_id $vllm_model_hf_id; then
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
        log_error "setup_model: Failed to download model $vllm_model_hf_id in container $container_id"
        return 1
    fi
    log_info "Model $vllm_model_hf_id downloaded successfully in container $container_id"
    echo "Model $vllm_model_hf_id download completed for container $container_id."
    return 0
}

# - Setup vLLM Service -
setup_service() {
    local container_id="$1"
    local vllm_model_path=$(get_container_config_value "$container_id" "vllm_model")
    local vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port")
    local vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size" || echo "16g")
    local vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size")
    local vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len")
    local vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype")
    local vllm_gpu_memory_utilization=$(get_container_config_value "$container_id" "vllm_gpu_memory_utilization")
    local vllm_dtype=$(get_container_config_value "$container_id" "vllm_dtype")
    local vllm_attention_backend=$(get_container_config_value "$container_id" "vllm_attention_backend")
    local vllm_nccl_so_path=$(get_container_config_value "$container_id" "vllm_nccl_so_path")

    log_info "Setting up Docker-based vLLM service in container $container_id..."
    echo "Configuring vLLM Docker service for container $container_id..."

    local hf_token=""
    if [[ -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        hf_token=$(cat "$PHOENIX_HF_TOKEN_FILE" | tr -d ' \t\n\r')
        if [[ -z "$hf_token" ]]; then
            log_error "setup_service: Hugging Face token file is empty: $PHOENIX_HF_TOKEN_FILE"
            return 1
        fi
    else
        log_warn "setup_service: Hugging Face token file not found: $PHOENIX_HF_TOKEN_FILE. Proceeding without token."
    fi

    # Validate critical paths
    local validation_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! systemctl is-active --quiet docker; then
    echo '[ERROR] Docker service is not running'
    exit 1
fi
if [[ ! -d \"$vllm_model_path\" ]]; then
    echo '[ERROR] Model directory does not exist: $vllm_model_path'
    exit 1
fi
if [[ ! -f \"$vllm_nccl_so_path\" ]]; then
    echo '[ERROR] NCCL library not found at: $vllm_nccl_so_path'
    exit 1
fi
echo '[INFO] Docker service and critical paths validated'
"
    if ! pct_exec_with_retry "$container_id" "$validation_cmd"; then
        log_error "setup_service: Pre-service validation failed for container $container_id"
        return 1
    fi

    # Build the vLLM arguments string
    local vllm_args="--model $vllm_model_path"
    vllm_args+=" --tensor-parallel-size $vllm_tensor_parallel_size"
    vllm_args+=" --max-model-len $vllm_max_model_len"
    vllm_args+=" --kv-cache-dtype $vllm_kv_cache_dtype"
    vllm_args+=" --gpu-memory-utilization $vllm_gpu_memory_utilization"
    vllm_args+=" --dtype $vllm_dtype"
    vllm_args+=" --disable-custom-all-reduce"

    local service_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
mkdir -p /root/.cache/huggingface
mkdir -p $(dirname $vllm_nccl_so_path)
cat <<EOF > /etc/systemd/system/vllm-docker.service
[Unit]
Description=vLLM Docker Container
After=docker.service
Requires=docker.service

[Service]
ExecStart=
ExecStart=/usr/bin/docker run --rm --name vllm \\
    --runtime=nvidia \\
    --gpus all \\
    -v /root/.cache/huggingface:/root/.cache/huggingface \\
    -v /models:/models \\
    -v $(dirname $vllm_nccl_so_path):$(dirname $vllm_nccl_so_path) \\
    --env \"HUGGING_FACE_HUB_TOKEN=$hf_token\" \\
    --env \"VLLM_ATTENTION_BACKEND=$vllm_attention_backend\" \\
    --env \"VLLM_NCCL_SO_PATH=$vllm_nccl_so_path\" \\
    -p $vllm_api_port:8000 \\
    --ipc=host \\
    --shm-size=$vllm_shm_size \\
    ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13} \\
    serve $vllm_args

ExecStop=/usr/bin/docker stop vllm
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vllm-docker.service
for attempt in 1 2 3; do
    echo \"[INFO] Starting vLLM Docker service (attempt \$attempt/3)...\"
    systemctl start vllm-docker.service
    sleep 10
    if systemctl is-active --quiet vllm-docker.service; then
        echo '[SUCCESS] vLLM Docker service started successfully.'
        exit 0
    else
        echo '[WARN] vLLM Docker service failed to start, checking logs...'
        docker ps -a --filter 'name=vllm' || true
        docker logs vllm || true
        systemctl status vllm-docker.service || true
        sleep 5
    fi
done
echo '[ERROR] vLLM Docker service failed to start after 3 attempts.'
exit 1
"
    if ! pct_exec_with_retry "$container_id" "$service_cmd"; then
        log_error "setup_service: Failed to set up vLLM Docker service in container $container_id"
        return 1
    fi

    log_info "vLLM Docker service configured and started successfully in container $container_id"
    echo "vLLM Docker service configured and started for container $container_id."
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
        local docker_gpu_check="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:13.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
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
    local vllm_model_path
    vllm_model_path=$(get_container_config_value "$container_id" "vllm_model") || vllm_model_path=""
    if [[ -n "$vllm_model_path" ]]; then
        local model_check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if [[ -d \"$vllm_model_path\" ]]; then
    echo '[SUCCESS] Model directory exists: $vllm_model_path'
    exit 0
else
    echo '[ERROR] Model directory does not exist: $vllm_model_path'
    exit 1
fi
"
        if pct_exec_with_retry "$container_id" "$model_check_cmd"; then
            log_info "validate_final_setup: Model directory exists for $vllm_model_path in container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: Model directory check failed for $vllm_model_path in container $container_id"
            ((checks_failed++))
        fi
    else
        log_error "validate_final_setup: vLLM model path not specified for container $container_id"
        ((checks_failed++))
    fi

    local service_check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if systemctl is-active --quiet vllm-docker.service; then
    echo '[SUCCESS] vLLM Docker service is running'
    exit 0
else
    echo '[ERROR] vLLM Docker service is not running'
    docker ps -a --filter 'name=vllm' || true
    docker logs vllm || true
    systemctl status vllm-docker.service || true
    exit 1
fi
"
    if pct_exec_with_retry "$container_id" "$service_check_cmd"; then
        log_info "validate_final_setup: vLLM Docker service is running in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: vLLM Docker service check failed in container $container_id"
        ((checks_failed++))
    fi

    local docker_check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
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
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
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

    local image_check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if docker images ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13} | grep -q ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13}; then
    echo '[SUCCESS] Custom vLLM image ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13} is present'
    exit 0
else
    echo '[ERROR] Custom vLLM image ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13} is not present'
    exit 1
fi
"
    if pct_exec_with_retry "$container_id" "$image_check_cmd"; then
        log_info "validate_final_setup: Custom vLLM image ${DEFAULT_VLLM_IMAGE:-vllm/vllm-openai:cuda13} is present in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: Custom vLLM image check failed in container $container_id"
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
        log_error "phoenix_hypervisor_setup_drdevstral.sh: Container ID must be provided as an argument"
        echo "Usage: $0 <container_id>"
        exit 1
    fi

    if [[ "$container_id" != "901" ]]; then
        log_error "phoenix_hypervisor_setup_drdevstral.sh: This script is designed for container ID 901, got $container_id"
        exit 1
    fi

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP FOR CONTAINER $container_id"
    echo "==============================================="
    log_info "Starting drdevstral setup for container $container_id..."

    validate_dependencies
    validate_container_state "$container_id"

    local gpu_assignment
    gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then
        log_info "Checking permissions for /etc/pve/lxc/$container_id.conf..."
        if [[ ! -w "/etc/pve/lxc/$container_id.conf" ]]; then
            log_error "Cannot write to /etc/pve/lxc/$container_id.conf. Please ensure proper permissions or manually configure GPU passthrough."
            echo "Run: chmod 644 /etc/pve/lxc/$container_id.conf and chown root:pve /etc/pve/lxc/$container_id.conf"
            exit 1
        fi
        # Check if GPU passthrough is already configured
        local required_configs=(
            "dev0: /dev/dri/card0,gid=44"
            "dev1: /dev/dri/renderD128,gid=104"
            "dev2: /dev/nvidia0"
            "dev3: /dev/nvidia1"
            "dev4: /dev/nvidia-caps/nvidia-cap1"
            "dev5: /dev/nvidia-caps/nvidia-cap2"
            "dev6: /dev/nvidiactl"
            "dev7: /dev/nvidia-modeset"
            "dev8: /dev/nvidia-uvm-tools"
            "dev9: /dev/nvidia-uvm"
            "lxc.cgroup2.devices.allow: a"
            "lxc.cap.drop:"
            "swap: 512"
            "lxc.autodev: 1"
            "lxc.mount.auto: sys:rw"
        )
        local config_file="/etc/pve/lxc/$container_id.conf"
        local all_configs_present=true
        for config in "${required_configs[@]}"; do
            if ! grep -Fx "$config" "$config_file" >/dev/null; then
                all_configs_present=false
                break
            fi
        done
        if ! $all_configs_present; then
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
        else
            log_info "GPU passthrough already configured for container $container_id"
        fi
    fi

    validate_container "$container_id"
    show_setup_info "$container_id"
    setup_container_environment "$container_id" || { log_error "Container environment setup failed for $container_id"; exit 1; }
    setup_nvidia_packages "$container_id" || { log_error "Failed to install NVIDIA packages for $container_id"; exit 1; }
    install_nccl_library_in_container "$container_id" || handle_error "install_nccl_library_in_container"
    build_custom_vllm_image "$container_id" || { log_error "Failed to build custom vLLM image for $container_id"; exit 1; }
    setup_model "$container_id" || { log_error "Model setup failed for $container_id"; exit 1; }
    setup_service "$container_id" || { log_error "Service setup failed for $container_id"; exit 1; }
    validate_final_setup "$container_id" || log_warn "Final setup validation had warnings for $container_id"

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP COMPLETED"
    echo "==============================================="
    log_info "drdevstral setup completed successfully for $container_id"
    log_info "You can now check the service with: pct exec $container_id -- systemctl status vllm-docker.service"
    log_info "Test the model with: curl -X POST \"http://localhost:8000/v1/chat/completions\" -H \"Content-Type: application/json\" --data '{\"model\": \"Qwen/Qwen2.5-Coder-7B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Write a Python function to reverse a string.\"}]}'"
    echo "Check service status with: pct exec $container_id -- systemctl status vllm-docker.service"
    echo "To test the model, run: curl -X POST \"http://localhost:8000/v1/chat/completions\" -H \"Content-Type: application/json\" --data '{\"model\": \"Qwen/Qwen2.5-Coder-7B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Write a Python function to reverse a string.\"}]}'"
    echo "From the host, test with: curl -X POST \"http://10.0.0.111:8000/v1/chat/completions\" -H \"Content-Type: application/json\" --data '{\"model\": \"Qwen/Qwen2.5-Coder-7B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Write a Python function to reverse a string.\"}]}'"
    echo "==============================================="
}

main "$1"