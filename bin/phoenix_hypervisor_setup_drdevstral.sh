#!/usr/bin/env bash

# phoenix_hypervisor_setup_drdevstral.sh
#
# Container-specific setup script for drdevstral (LXC ID 901)
# Installs NVIDIA drivers (580.76.05 via runfile), toolkit (12.8), Docker, vLLM, and sets up the AI model service.
# This script is intended to be called by phoenix_establish_hypervisor.sh after container creation.
#
# Version: 1.10.0 (Updated for Driver 580.76.05, CUDA 12.8, Refactored NVIDIA Setup)
# Author: Assistant

set -euo pipefail

# --- Terminal Handling ---
# Save terminal settings and ensure they are restored on exit or error
ORIGINAL_TERM_SETTINGS=$(stty -g 2>/dev/null) || ORIGINAL_TERM_SETTINGS=""
trap 'if [[ -n "$ORIGINAL_TERM_SETTINGS" ]]; then stty "$ORIGINAL_TERM_SETTINGS"; fi; echo "[INFO] Script interrupted. Terminal settings restored." >&2; exit 1' INT TERM ERR

# --- Argument Validation ---
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Usage: $0 <container_id>" >&2
    exit 1
fi

CONTAINER_ID="$1"
if [[ "$CONTAINER_ID" != "901" ]]; then
    echo "[ERROR] This script is designed for container ID 901, got $CONTAINER_ID" >&2
    exit 1
fi

# --- Configuration and Library Loading ---
# Determine script's directory for locating libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOENIX_LIB_DIR="/usr/local/lib/phoenix_hypervisor"
PHOENIX_BIN_DIR="/usr/local/bin/phoenix_hypervisor"

# Source Phoenix Hypervisor Configuration
PHOENIX_CONFIG_LOADED=0
for config_path in \
    "/usr/local/etc/phoenix_hypervisor_config.sh" \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_config.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_config.sh"; do
    if [[ -f "$config_path" ]]; then
        # shellcheck source=/dev/null
        source "$config_path"
        if [[ "${PHOENIX_HYPERVISOR_CONFIG_LOADED:-0}" -eq 1 ]]; then
            PHOENIX_CONFIG_LOADED=1
            echo "[INFO] Sourced Phoenix Hypervisor configuration from $config_path."
            break
        else
            echo "[WARN] Sourced $config_path, but PHOENIX_HYPERVISOR_CONFIG_LOADED not set correctly. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_CONFIG_LOADED -ne 1 ]]; then
    echo "[ERROR] Failed to load phoenix_hypervisor_config.sh from standard locations." >&2
    echo "[ERROR] Please ensure it's installed correctly." >&2
    exit 1
fi

# Set default for DEFAULT_VLLM_IMAGE if not defined
if [[ -z "${DEFAULT_VLLM_IMAGE:-}" ]]; then
    DEFAULT_VLLM_IMAGE="vllm/vllm-openai:cuda13"
    echo "[DEBUG] DEFAULT_VLLM_IMAGE was unset, defaulting to $DEFAULT_VLLM_IMAGE" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"
fi
echo "[DEBUG] DEFAULT_VLLM_IMAGE=$DEFAULT_VLLM_IMAGE" >> "${HYPERVISOR_LOGFILE%.log}_debug.log"

# Source Phoenix Hypervisor Common Functions
PHOENIX_COMMON_LOADED=0
for common_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_common.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_common.sh"; do
    if [[ -f "$common_path" ]]; then
        # shellcheck source=/dev/null
        source "$common_path"
        if declare -F log_info >/dev/null 2>&1; then
            PHOENIX_COMMON_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from $common_path."
            break
        else
            echo "[WARN] Sourced $common_path, but common functions not found. Trying next location."
        fi
    fi
done

# Fallback logging if common lib fails
if [[ $PHOENIX_COMMON_LOADED -ne 1 ]]; then
    echo "[WARN] phoenix_hypervisor_common.sh not loaded. Using minimal logging."
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
else
    # Initialize logging from the common library if loaded successfully
    setup_logging 2>/dev/null || true # Redirect potential early errors
fi

# Source NVIDIA LXC Common Functions
PHOENIX_NVIDIA_LOADED=0
for nvidia_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_nvidia.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_nvidia.sh"; do
    if [[ -f "$nvidia_path" ]]; then
        # shellcheck source=/dev/null
        source "$nvidia_path"
        if declare -F install_nvidia_driver_in_container_via_runfile >/dev/null 2>&1; then
            PHOENIX_NVIDIA_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced NVIDIA LXC common functions from $nvidia_path."
            break
        else
            log_warn "Sourced $nvidia_path, but NVIDIA functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_NVIDIA_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_nvidia.sh. Cannot proceed with NVIDIA setup."
fi

# --- Source New Common Libraries ---
# Source Base LXC Common Functions
PHOENIX_BASE_LOADED=0
for base_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_base.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_base.sh"; do
    if [[ -f "$base_path" ]]; then
        # shellcheck source=/dev/null
        source "$base_path"
        if declare -F pct_exec_with_retry >/dev/null 2>&1; then
            PHOENIX_BASE_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced Base LXC common functions from $base_path."
            break
        else
            log_warn "Sourced $base_path, but Base LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_BASE_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_base.sh. Cannot proceed with base LXC operations."
fi

# Source Docker LXC Common Functions
PHOENIX_DOCKER_LOADED=0
for docker_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_docker.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_docker.sh"; do
    if [[ -f "$docker_path" ]]; then
        # shellcheck source=/dev/null
        source "$docker_path"
        if declare -F install_docker_ce_in_container >/dev/null 2>&1; then
            PHOENIX_DOCKER_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced Docker LXC common functions from $docker_path."
            break
        else
            log_warn "Sourced $docker_path, but Docker LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_DOCKER_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_docker.sh. Cannot proceed with Docker operations."
fi

# Source Validation LXC Common Functions
PHOENIX_VALIDATION_LOADED=0
for validation_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_validation.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_validation.sh"; do
    if [[ -f "$validation_path" ]]; then
        # shellcheck source=/dev/null
        source "$validation_path"
        if declare -F validate_container_exists >/dev/null 2>&1; then
            PHOENIX_VALIDATION_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced Validation LXC common functions from $validation_path."
            break
        else
            log_warn "Sourced $validation_path, but Validation LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_VALIDATION_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_validation.sh. Cannot proceed with validation operations."
fi

# Source Systemd LXC Common Functions
PHOENIX_SYSTEMD_LOADED=0
for systemd_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_systemd.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_systemd.sh"; do
    if [[ -f "$systemd_path" ]]; then
        # shellcheck source=/dev/null
        source "$systemd_path"
        if declare -F create_systemd_service_in_container >/dev/null 2>&1; then
            PHOENIX_SYSTEMD_LOADED=1
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Sourced Systemd LXC common functions from $systemd_path."
            break
        else
            log_warn "Sourced $systemd_path, but Systemd LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_SYSTEMD_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_systemd.sh. Cannot proceed with systemd operations."
fi

# --- Helper Functions (Specific to this script) ---

# Get a specific value from the container configuration in the JSON file
# Usage: get_container_config_value <key>
get_container_config_value() {
    local key="$1"
    if [[ -z "$key" ]]; then
        log_error "get_container_config_value: Key cannot be empty"
    fi
    # Use jq to extract the value, returning "null" if not found
    jq -r ".lxc_configs.\"$CONTAINER_ID\".$key // \"null\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "null"
}

# Get a specific value from the global configuration in the JSON file
# Usage: get_global_config_value <key>
get_global_config_value() {
    local key="$1"
    if [[ -z "$key" ]]; then
        log_error "get_global_config_value: Key cannot be empty"
    fi
    # Use jq to extract the value, returning "null" if not found
    jq -r ".$key // \"null\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "null"
}

# --- Core Setup Functions ---

# 1. Validate Dependencies
validate_dependencies() {
    log_info "validate_dependencies: Checking for required commands..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "validate_dependencies: jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "validate_dependencies: pct not installed."
    fi
    log_info "validate_dependencies: All required commands found."
}

# 2. Validate Container State (adapted from original)
validate_container_state() {
    local lxc_id="$1"
    log_info "validate_container_state: Validating state for container $lxc_id..."

    # Check if container exists
    if ! validate_container_exists "$lxc_id"; then
        log_error "validate_container_state: Container $lxc_id does not exist."
    fi

    # Ensure container is running
    if ! ensure_container_running "$lxc_id"; then
        log_error "validate_container_state: Failed to ensure container $lxc_id is running."
    fi

    # Basic network check
    if ! check_container_network "$lxc_id"; then
        log_warn "validate_container_state: Network check failed. Attempting to set temporary DNS..."
        if ! set_temporary_dns "$lxc_id"; then
            log_error "validate_container_state: Failed to set temporary DNS for container $lxc_id."
        fi
        # Retry network check after setting DNS
        if ! check_container_network "$lxc_id"; then
            log_error "validate_container_state: Network check still failed after setting DNS for container $lxc_id."
        fi
    fi

    # Check and Configure GPU Passthrough
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "gpu_assignment")
    if [[ "$gpu_assignment" == "null" || "$gpu_assignment" == "none" || -z "$gpu_assignment" ]]; then
        log_info "validate_container_state: No GPU assignment found for container $lxc_id. Skipping GPU passthrough."
        return 0
    fi

    # Validate GPU assignment format
    if ! validate_gpu_assignment_format "$gpu_assignment"; then
        log_error "validate_container_state: Invalid GPU assignment format for container $lxc_id: $gpu_assignment"
    fi

    # Check if GPU passthrough is already configured by looking for a common entry
    local config_file="/etc/pve/lxc/${lxc_id}.conf"
    local gpu_configured
    gpu_configured=$(pct config "$lxc_id" | grep -c "lxc.cgroup2.devices.allow: c 195" || true)

    if [[ "$gpu_configured" -gt 0 ]]; then
        log_info "validate_container_state: GPU passthrough already configured for container $lxc_id."
    else
        log_info "validate_container_state: Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log_error "validate_container_state: Failed to configure GPU passthrough for container $lxc_id."
        fi
        log_info "validate_container_state: GPU passthrough configured. Restarting container $lxc_id to apply changes..."
        pct stop "$lxc_id" || true
        sleep 5
        if ! retry_command 3 10 pct start "$lxc_id"; then
            log_error "validate_container_state: Failed to restart container $lxc_id after GPU passthrough configuration."
        fi
        log_info "validate_container_state: Container $lxc_id restarted with GPU passthrough."
    fi
}

# 3. Setup NVIDIA Packages (UPDATED for project requirements)
setup_nvidia_packages() {
    local lxc_id="$1"
    log_info "setup_nvidia_packages: Installing NVIDIA components (Driver 580.76.05, CUDA 12.8) in container $lxc_id..."

    # --- NEW: Install NVIDIA driver 580.76.05 via runfile (no kernel module) ---
    log_info "setup_nvidia_packages: Installing NVIDIA driver 580.76.05 via runfile (no kernel module)..."
    if ! install_nvidia_driver_in_container_via_runfile "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA driver via runfile in container $lxc_id."
    fi

    # --- NEW: Install CUDA Toolkit 12.8 ---
    log_info "setup_nvidia_packages: Installing CUDA Toolkit 12.8..."
    if ! install_cuda_toolkit_12_8_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install CUDA Toolkit 12.8 in container $lxc_id."
    fi

    # --- Install NVIDIA Container Toolkit (nvidia-docker2) ---
    log_info "setup_nvidia_packages: Installing NVIDIA Container Toolkit..."
    if ! install_nvidia_toolkit_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA toolkit in container $lxc_id."
    fi

    # --- Configure Docker to use NVIDIA runtime ---
    log_info "setup_nvidia_packages: Configuring Docker NVIDIA runtime..."
    if ! configure_docker_nvidia_runtime "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to configure Docker NVIDIA runtime in container $lxc_id."
    fi

    # --- Verify basic GPU access inside the container ---
    log_info "setup_nvidia_packages: Verifying basic GPU access in container $lxc_id..."
    if ! verify_lxc_gpu_access_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Basic GPU access verification failed in container $lxc_id."
    fi

    # --- Verify CUDA Toolkit installation (nvcc) ---
    log_info "setup_nvidia_packages: Verifying CUDA Toolkit installation (nvcc) in container $lxc_id..."
    local nvcc_check_cmd="set -e
if command -v nvcc >/dev/null 2>&1; then
    nvcc_version=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
    echo \"[SUCCESS] nvcc found, version: \$nvcc_version\"
    exit 0
else
    echo '[ERROR] nvcc not found'
    exit 1
fi"

    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if ! $exec_func "$lxc_id" -- bash -c "$nvcc_check_cmd"; then
        log_error "setup_nvidia_packages: CUDA Toolkit verification (nvcc) failed in container $lxc_id."
    fi

    log_info "setup_nvidia_packages: NVIDIA components (Driver 580.76.05, CUDA 12.8) installed and verified successfully in container $lxc_id."
}


# 4. Setup Model (adapted from original)
setup_model() {
    local lxc_id="$1"
    log_info "setup_model: Setting up model for container $lxc_id..."

    local model_path
    model_path=$(get_container_config_value "vllm.model")
    if [[ "$model_path" == "null" || "$model_path" == "none" ]]; then
        log_info "setup_model: No model path specified in config for container $lxc_id. Skipping model setup."
        return 0
    fi

    # Check if model directory already exists
    if validate_path_in_container "$lxc_id" "$model_path"; then
        log_info "setup_model: Model path $model_path already exists in container $lxc_id. Skipping download."
        return 0
    fi

    # Install model download tools
    log_info "setup_model: Installing model download tools..."
    local install_tools_cmd="set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y --fix-missing
apt-get install -y python3-pip git
pip3 install huggingface_hub[cli] hf_transfer
pip3 install hfdownloader
echo '[SUCCESS] Model download tools installed.'
"
    if ! pct_exec_with_retry "$lxc_id" "$install_tools_cmd"; then
        log_error "setup_model: Failed to install model download tools in container $lxc_id."
    fi

    # Download the model
    log_info "setup_model: Downloading model to $model_path in container $lxc_id..."
    local download_model_cmd="set -e
export HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p '$(dirname "$model_path")'
cd '$(dirname "$model_path")'
echo '[INFO] Starting model download...'
hfdownloader -m '$model_path' -d '$model_path' -t '$PHOENIX_HF_TOKEN_FILE' -v
echo '[SUCCESS] Model download completed.'
"
    if ! pct_exec_with_retry "$lxc_id" "$download_model_cmd"; then
        log_error "setup_model: Failed to download model in container $lxc_id."
    fi

    log_info "setup_model: Model setup completed for container $lxc_id."
}

# 5. Build Custom vLLM Image (adapted from original)
build_custom_vllm_image() {
    local lxc_id="$1"
    log_info "build_custom_vllm_image: Building custom vLLM Docker image in container $lxc_id..."

    local vllm_image_tag="vllm-custom:latest"
    local dockerfile_path="/root/vllm_custom_dockerfile"

    # Define the Dockerfile content directly as a string
    # Based on default vLLM image, adding hf_transfer for faster model loading
    local dockerfile_content="FROM $DEFAULT_VLLM_IMAGE

# Install hf_transfer for faster model downloading
RUN pip install hf_transfer

# Set a default command (can be overridden)
CMD [\"python3\", \"--version\"]"

    # Write the Dockerfile content to a file inside the container
    local write_dockerfile_cmd="set -e
mkdir -p /root/vllm_build
cat << 'EOF_DOCKERFILE' > $dockerfile_path
$dockerfile_content
EOF_DOCKERFILE
echo '[INFO] Custom vLLM Dockerfile written to $dockerfile_path'"

    if ! pct_exec_with_retry "$lxc_id" "$write_dockerfile_cmd"; then
        log_error "build_custom_vllm_image: Failed to write Dockerfile in container $lxc_id."
    fi

    # Build the Docker image inside the container using the written Dockerfile
    if ! build_docker_image_in_container "$lxc_id" "$dockerfile_path" "$vllm_image_tag"; then
        log_error "build_custom_vllm_image: Failed to build custom vLLM Docker image in container $lxc_id."
    fi

    log_info "build_custom_vllm_image: Custom vLLM Docker image built successfully in container $lxc_id."
}

# 6. Setup vLLM Service (adapted from original)
setup_service() {
    local lxc_id="$1"
    log_info "setup_service: Setting up vLLM service in container $lxc_id..."

    # Get vLLM configuration from JSON
    local model_path
    local tensor_parallel_size
    local gpu_memory_utilization
    local max_model_len
    local attention_backend
    local kv_cache_dtype
    local dtype
    local port
    local nccl_path

    model_path=$(get_container_config_value "vllm.model")
    tensor_parallel_size=$(get_container_config_value "vllm.tensor_parallel_size")
    gpu_memory_utilization=$(get_container_config_value "vllm.gpu_memory_utilization")
    max_model_len=$(get_container_config_value "vllm.max_model_len")
    attention_backend=$(get_container_config_value "vllm.attention_backend")
    kv_cache_dtype=$(get_container_config_value "vllm.kv_cache_dtype")
    dtype=$(get_container_config_value "vllm.dtype")
    port=$(get_container_config_value "vllm.port")
    nccl_path="/usr/lib/x86_64-linux-gnu"

    # Validate essential parameters
    if [[ "$model_path" == "null" || "$model_path" == "none" ]]; then
        log_error "setup_service: Model path is required in the configuration for container $lxc_id."
    fi
    if [[ "$port" == "null" ]]; then
        log_error "setup_service: vLLM port is required in the configuration for container $lxc_id."
    fi

    # Set default values if not provided
    tensor_parallel_size=${tensor_parallel_size:-1}
    gpu_memory_utilization=${gpu_memory_utilization:-0.9}
    attention_backend=${attention_backend:-"FLASHINFER"}
    kv_cache_dtype=${kv_cache_dtype:-"auto"}
    dtype=${dtype:-"auto"}
    max_model_len=${max_model_len:-""} # Empty means no limit

    # Build Docker run command arguments
    local docker_args="--gpus all"
    docker_args+=" --shm-size=16G"
    docker_args+=" --ipc=host"
    docker_args+=" -p $port:$port"
    docker_args+=" -v $model_path:$model_path"
    docker_args+=" -v $nccl_path:$nccl_path"
    docker_args+=" -e NCCL_LIBRARY_PATH=$nccl_path/libnccl.so.2"

    # Build vLLM command arguments
    local vllm_args="--host 0.0.0.0"
    vllm_args+=" --port $port"
    vllm_args+=" --model $model_path"
    vllm_args+=" --tensor-parallel-size $tensor_parallel_size"
    vllm_args+=" --gpu-memory-utilization $gpu_memory_utilization"
    vllm_args+=" --attention-backend $attention_backend"
    vllm_args+=" --kv-cache-dtype $kv_cache_dtype"
    vllm_args+=" --dtype $dtype"
    if [[ -n "$max_model_len" ]]; then
        vllm_args+=" --max-model-len $max_model_len"
    fi

    # Define the systemd service content
    local service_content="[Unit]
Description=vLLM Docker Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=/bin/bash -c 'docker image inspect vllm-custom:latest > /dev/null || { echo \"Custom vLLM image not found\"; exit 1; }'
ExecStart=/usr/bin/docker run $docker_args vllm-custom:latest python3 -m vllm.entrypoints.openai.api_server $vllm_args
ExecStop=/usr/bin/docker stop -t 10 vllm-server
ExecStopPost=/usr/bin/docker rm -f vllm-server

[Install]
WantedBy=multi-user.target"

    # Create the systemd service file inside the container
    if ! create_systemd_service_in_container "$lxc_id" "vllm-docker" "$service_content"; then
        log_error "setup_service: Failed to create systemd service file in container $lxc_id."
    fi

    # Reload systemd daemon to recognize the new service
    if ! reload_systemd_daemon_in_container "$lxc_id"; then
        log_error "setup_service: Failed to reload systemd daemon in container $lxc_id."
    fi

    # Enable the service to start on boot
    if ! enable_systemd_service_in_container "$lxc_id" "vllm-docker"; then
        log_error "setup_service: Failed to enable systemd service in container $lxc_id."
    fi

    # Start the service
    log_info "setup_service: Starting vLLM service in container $lxc_id..."
    # Use retry logic for starting the service
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "setup_service: Attempting to start vLLM service (attempt $attempt/$max_attempts)..."
        if start_systemd_service_in_container "$lxc_id" "vllm-docker"; then
            log_info "setup_service: vLLM service started successfully in container $lxc_id."
            return 0
        else
            log_warn "setup_service: Failed to start vLLM service on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done
    log_error "setup_service: Failed to start vLLM service in container $lxc_id after $max_attempts attempts."
}

# 7. Final Validation (adapted from original)
validate_final_setup() {
    local lxc_id="$1"
    local checks_passed=0
    local checks_failed=0

    log_info "validate_final_setup: Validating final setup for container $lxc_id..."
    echo "Validating final setup for container $lxc_id..."

    # --- Check Container Status ---
    if validate_container_running "$lxc_id"; then
        log_info "validate_final_setup: Container $lxc_id is running"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Container $lxc_id is not running"
        ((checks_failed++)) || true
    fi

    # --- Check Docker Status ---
    local docker_check_cmd="set -e
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo '[SUCCESS] Docker is installed and running'
    exit 0
else
    echo '[ERROR] Docker is not installed or not running'
    exit 1
fi"
    if pct_exec_with_retry "$lxc_id" "$docker_check_cmd"; then
        log_info "validate_final_setup: Docker is installed and running in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check GPU Access via nvidia-smi ---
    local nvidia_smi_check="set -e
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] nvidia-smi command successful'
    exit 0
else
    echo '[ERROR] nvidia-smi command failed'
    exit 1
fi"
    if pct_exec_with_retry "$lxc_id" "$nvidia_smi_check"; then
        log_info "validate_final_setup: nvidia-smi check passed in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: nvidia-smi check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check GPU Access via Docker ---
    if verify_docker_gpu_access_in_container "$lxc_id"; then
        log_info "validate_final_setup: Docker GPU access verified for container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker GPU access verification failed for container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check Model Directory ---
    local model_path
    model_path=$(get_container_config_value "vllm.model")
    if [[ "$model_path" != "null" && "$model_path" != "none" ]]; then
        if validate_path_in_container "$lxc_id" "$model_path"; then
            log_info "validate_final_setup: Model directory $model_path exists in container $lxc_id"
            ((checks_passed++)) || true
        else
            log_error "validate_final_setup: Model directory $model_path does not exist in container $lxc_id"
            ((checks_failed++)) || true
        fi
    else
        log_info "validate_final_setup: No model path configured, skipping model directory check."
        ((checks_passed++)) || true # Consider this a pass if not configured
    fi

    # --- Check vLLM Service Status ---
    local service_status
    service_status=$(check_systemd_service_status_in_container "$lxc_id" "vllm-docker")
    if [[ "$service_status" == "active" ]]; then
        log_info "validate_final_setup: vLLM service is active in container $lxc_id"
        ((checks_passed++)) || true
    elif [[ "$service_status" == "inactive" ]]; then
        log_warn "validate_final_setup: vLLM service is inactive in container $lxc_id"
        ((checks_failed++)) || true
    elif [[ "$service_status" == "failed" ]]; then
        log_error "validate_final_setup: vLLM service has failed in container $lxc_id"
        ((checks_failed++)) || true
    else
        log_error "validate_final_setup: vLLM service status unknown or not found in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Summary ---
    log_info "validate_final_setup: Validation summary: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "validate_final_setup: Validation completed with $checks_failed failures. Check logs for details."
        return 1 # Indicate partial failure
    fi
    log_info "validate_final_setup: All validation checks passed for container $lxc_id"
    echo "All validation checks passed for container $lxc_id."
    return 0
}

# 8. Show Setup Information (adapted from original)
show_setup_info() {
    local lxc_id="$1"
    log_info "show_setup_info: Displaying setup information for container $lxc_id..."

    # Get configuration values for display
    local model_path
    local tensor_parallel_size
    local gpu_memory_utilization
    local attention_backend
    local kv_cache_dtype
    local dtype
    local port

    model_path=$(get_container_config_value "vllm.model")
    tensor_parallel_size=$(get_container_config_value "vllm.tensor_parallel_size")
    gpu_memory_utilization=$(get_container_config_value "vllm.gpu_memory_utilization")
    attention_backend=$(get_container_config_value "vllm.attention_backend")
    kv_cache_dtype=$(get_container_config_value "vllm.kv_cache_dtype")
    dtype=$(get_container_config_value "vllm.dtype")
    port=$(get_container_config_value "vllm.port")

    # Set defaults for display if not provided
    tensor_parallel_size=${tensor_parallel_size:-1}
    gpu_memory_utilization=${gpu_memory_utilization:-0.9}
    attention_backend=${attention_backend:-"FLASHINFER"}
    kv_cache_dtype=${kv_cache_dtype:-"auto"}
    dtype=${dtype:-"auto"}

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP COMPLETED FOR CONTAINER $lxc_id"
    echo "==============================================="
    echo "Model Path: $model_path"
    echo "Tensor Parallel Size: $tensor_parallel_size"
    echo "GPU Memory Utilization: $gpu_memory_utilization"
    echo "Attention Backend: $attention_backend"
    echo "KV Cache Dtype: $kv_cache_dtype"
    echo "Dtype: $dtype"
    echo "API Port: $port"
    echo ""
    echo "You can check the status of the vLLM service with:"
    echo "  pct exec $lxc_id -- systemctl status vllm-docker"
    echo ""
    echo "To enter the container:"
    echo "  pct enter $lxc_id"
    echo "==============================================="
}


# --- Main Execution ---
main() {
    local lxc_id="$1"

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR DRDEVSTRAL SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    # 1. Validate Dependencies
    validate_dependencies

    # 2. Validate Container State (Create if needed, Start, Network, GPU Passthrough)
    validate_container_state "$lxc_id"

    # === ORDER CORRECTED HERE ===
    # 4. Install Docker CE (NOW BEFORE NVIDIA Setup)
    log_info "Installing Docker CE in container $lxc_id..."
    if ! install_docker_ce_in_container "$lxc_id"; then
        log_error "Failed to install Docker CE in container $lxc_id."
    fi

    # 3. Setup NVIDIA Packages (Driver 580.76.05 via runfile, CUDA 12.8, Toolkit, Docker Runtime)
    # Now Docker is available when configure_docker_nvidia_runtime is called
    setup_nvidia_packages "$lxc_id"

    # 5. Setup Model (Download if path specified and doesn't exist)
    setup_model "$lxc_id"

    # 6. Build Custom vLLM Docker Image
    build_custom_vllm_image "$lxc_id"

    # 7. Setup vLLM Service (Systemd)
    setup_service "$lxc_id"

    # 8. Validate Final Setup
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi

    # 9. Show Setup Information
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR DRDEVSTRAL SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

# Run main function with the provided container ID
main "$CONTAINER_ID"