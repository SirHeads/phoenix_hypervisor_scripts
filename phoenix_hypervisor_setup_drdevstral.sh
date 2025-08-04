#!/bin/bash
# Phoenix Hypervisor Setup DrDevstral Script
# Configures the DrDevstral LXC container (ID specified as argument) with NVIDIA drivers, NVIDIA container toolkit, Docker, and vLLM for the DevStral model.
# Prerequisites:
# - Proxmox LXC container created with basic configuration
# - Internet access for package and Docker image downloads
# - NVIDIA GPUs available on the host
# - Root privileges
# Dependencies:
# - /usr/local/bin/phoenix_hypervisor_common.sh and /usr/local/bin/phoenix_hypervisor_config.sh available
# - jq installed for JSON parsing
# - /usr/local/etc/phoenix_lxc_configs.json available
# Usage: ./phoenix_hypervisor_setup_drdevstral.sh <lxc_id>
# Example: ./phoenix_hypervisor_setup_drdevstral.sh 901
# Version: 1.6.5 (Merged features for standardized GPU passthrough and vLLM with 8-bit quantization)

set -euo pipefail

# --- Default vLLM Parameters ---
VLLM_MODEL_DEFAULT="mistralai/Devstral-Small-2507"
VLLM_TENSOR_PARALLEL_SIZE_DEFAULT=2
VLLM_MAX_MODEL_LEN_DEFAULT=128000
VLLM_KV_CACHE_DTYPE_DEFAULT="fp8"
VLLM_SHM_SIZE_DEFAULT="10.24gb"
VLLM_GPU_COUNT_DEFAULT="all"
VLLM_QUANTIZATION_DEFAULT="bitsandbytes"
VLLM_QUANTIZATION_CONFIG_TYPE_DEFAULT="int8"
VLLM_ADDITIONAL_ARGS_DEFAULT=""

# --- Source common functions and configuration ---
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# --- Script Initialization ---
check_root
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

# Get LXC ID from command-line argument
VLLM_LXC_ID="$1"
if [[ -z "$VLLM_LXC_ID" ]]; then
    log "ERROR" "LXC ID not provided. Usage: $0 <lxc_id>"
    exit 1
fi
log "INFO" "Starting phoenix_hypervisor_setup_drdevstral.sh for LXC $VLLM_LXC_ID"

# Define the marker file path for this script's completion status
marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${VLLM_LXC_ID}_setup.marker"

# Skip if the setup has already been completed
if is_script_completed "$marker_file"; then
    log "INFO" "DrDevstral LXC $VLLM_LXC_ID already set up (marker found). Skipping setup."
    exit 0
fi

# --- Load LXC-Specific Config ---
config_string="${LXC_CONFIGS[$VLLM_LXC_ID]}"
if [[ -z "$config_string" ]]; then
    log "ERROR" "Configuration for LXC ID $VLLM_LXC_ID not found in LXC_CONFIGS array."
    exit 1
fi

# Parse the configuration string
# Order: name|memory_mb|cores|template|storage_pool|storage_size_gb|nvidia_pci_ids|network_config|features|gpu_assignment|vllm_model|vllm_tensor_parallel_size|vllm_max_model_len|vllm_kv_cache_dtype|vllm_shm_size|vllm_gpu_count|vllm_quantization|vllm_quantization_config_type
IFS='|' read -r \
    LXC_NAME \
    LXC_MEMORY_MB \
    LXC_CORES \
    LXC_TEMPLATE \
    LXC_STORAGE_POOL \
    LXC_STORAGE_SIZE_GB \
    LXC_NVIDIA_PCI_IDS \
    LXC_NETWORK_CONFIG \
    LXC_FEATURES \
    LXC_GPU_ASSIGNMENT \
    VLLM_MODEL \
    VLLM_TENSOR_PARALLEL_SIZE \
    VLLM_MAX_MODEL_LEN \
    VLLM_KV_CACHE_DTYPE \
    VLLM_SHM_SIZE \
    VLLM_GPU_COUNT \
    VLLM_QUANTIZATION \
    VLLM_QUANTIZATION_CONFIG_TYPE \
    <<< "$config_string"

# Override defaults with JSON config values
VLLM_MODEL="${VLLM_MODEL:-$VLLM_MODEL_DEFAULT}"
VLLM_TENSOR_PARALLEL_SIZE="${VLLM_TENSOR_PARALLEL_SIZE:-$VLLM_TENSOR_PARALLEL_SIZE_DEFAULT}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-$VLLM_MAX_MODEL_LEN_DEFAULT}"
VLLM_KV_CACHE_DTYPE="${VLLM_KV_CACHE_DTYPE:-$VLLM_KV_CACHE_DTYPE_DEFAULT}"
VLLM_SHM_SIZE="${VLLM_SHM_SIZE:-$VLLM_SHM_SIZE_DEFAULT}"
VLLM_GPU_COUNT="${VLLM_GPU_COUNT:-$VLLM_GPU_COUNT_DEFAULT}"
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-$VLLM_QUANTIZATION_DEFAULT}"
VLLM_QUANTIZATION_CONFIG_TYPE="${VLLM_QUANTIZATION_CONFIG_TYPE:-$VLLM_QUANTIZATION_CONFIG_TYPE_DEFAULT}"
VLLM_ADDITIONAL_ARGS="${VLLM_ADDITIONAL_ARGS:-$VLLM_ADDITIONAL_ARGS_DEFAULT}"

log "INFO" "Loaded vLLM config for LXC $VLLM_LXC_ID: model=$VLLM_MODEL, gpu_assignment=$LXC_GPU_ASSIGNMENT"

# --- Helper Functions ---
ensure_lxc_running() {
    local lxc_id="$1"
    local max_wait=120
    local wait_interval=5
    local elapsed=0

    log "INFO" "Ensuring LXC $lxc_id is running..."
    while [[ $elapsed -lt $max_wait ]]; do
        if pct status "$lxc_id" | grep -q "running"; then
            log "INFO" "LXC $lxc_id is running."
            return 0
        fi
        log "DEBUG" "LXC $lxc_id not running yet. Waiting $wait_interval seconds... (Elapsed: $elapsed/$max_wait)"
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done
    log "ERROR" "LXC $lxc_id did not start within $max_wait seconds."
    return 1
}

ensure_lxc_networking() {
    local lxc_id="$1"
    local max_wait=120
    local wait_interval=5
    local elapsed=0
    local ping_cmd="ping -c 1 -W 3 8.8.8.8"

    log "INFO" "Ensuring networking is available in LXC $lxc_id..."
    while [[ $elapsed -lt $max_wait ]]; do
        if execute_in_lxc "$lxc_id" "$ping_cmd" &>/dev/null; then
            log "INFO" "Networking is ready in LXC $lxc_id."
            return 0
        fi
        log "DEBUG" "Networking not ready in LXC $lxc_id. Waiting $wait_interval seconds... (Elapsed: $elapsed/$max_wait)"
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done
    log "ERROR" "Networking did not become ready in LXC $lxc_id within $max_wait seconds."
    return 1
}

install_base_packages_in_lxc() {
    local lxc_id="$1"
    log "INFO" "Installing base packages in LXC $lxc_id..."
    local update_cmd="apt-get update"
    local install_cmd="apt-get install -y curl wget gnupg lsb-release software-properties-common"

    if ! retry_command "execute_in_lxc $lxc_id '$update_cmd'"; then
        log "ERROR" "Failed to update package list in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$install_cmd'"; then
        log "ERROR" "Failed to install base packages in LXC $lxc_id."
        return 1
    fi
    log "INFO" "Base packages installed successfully in LXC $lxc_id."
    return 0
}

install_vllm_devstral_in_lxc() {
    local lxc_id="$1"
    log "INFO" "Installing vLLM and dependencies in LXC $lxc_id..."

    local nvidia_keyring_cmd="curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    local nvidia_repo_cmd="curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    local nvidia_install_cmd="apt-get update && apt-get install -y nvidia-container-toolkit"
    local docker_keyring_cmd="curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
    local docker_repo_cmd="echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"
    local docker_install_cmd="apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    local docker_nvidia_config_cmd="nvidia-ctk runtime configure --runtime=docker"
    local vllm_pull_cmd="docker pull vllm/vllm-openai:latest"

    if ! retry_command "execute_in_lxc $lxc_id '$nvidia_keyring_cmd'"; then
        log "ERROR" "Failed to add NVIDIA Container Toolkit GPG key in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$nvidia_repo_cmd'"; then
        log "ERROR" "Failed to add NVIDIA Container Toolkit repository in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$nvidia_install_cmd'"; then
        log "ERROR" "Failed to install NVIDIA Container Toolkit in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$docker_keyring_cmd'"; then
        log "ERROR" "Failed to add Docker GPG key in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$docker_repo_cmd'"; then
        log "ERROR" "Failed to add Docker repository in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$docker_install_cmd'"; then
        log "ERROR" "Failed to install Docker in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$docker_nvidia_config_cmd'"; then
        log "ERROR" "Failed to configure Docker with NVIDIA runtime in LXC $lxc_id."
        return 1
    fi
    if ! retry_command "execute_in_lxc $lxc_id '$vllm_pull_cmd'"; then
        log "WARN" "Failed to pull vLLM Docker image in LXC $lxc_id. Will attempt to pull on first run."
    fi
    log "INFO" "vLLM dependencies installed successfully in LXC $lxc_id."
    return 0
}

health_check_vllm_api() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1
    local curl_cmd="curl -sS -f http://localhost:8000/health"

    log "INFO" "Performing health check on vLLM API in LXC $lxc_id..."
    while [[ $attempt -le $max_attempts ]]; do
        if execute_in_lxc "$lxc_id" "$curl_cmd" >/dev/null 2>&1; then
            log "INFO" "vLLM API health check passed in LXC $lxc_id."
            return 0
        fi
        log "DEBUG" "vLLM API not ready in LXC $lxc_id (attempt $attempt/$max_attempts). Waiting 5 seconds..."
        sleep 5
        ((attempt++))
    done
    log "ERROR" "vLLM API health check failed in LXC $lxc_id after $max_attempts attempts."
    return 1
}

# --- Main Execution Flow ---
if ! ensure_lxc_running "$VLLM_LXC_ID"; then
    log "ERROR" "Cannot proceed, LXC $VLLM_LXC_ID is not running."
    exit 1
fi

if ! ensure_lxc_networking "$VLLM_LXC_ID"; then
    log "ERROR" "Cannot proceed, networking is not ready in LXC $VLLM_LXC_ID."
    exit 1
fi

if [[ -n "$LXC_GPU_ASSIGNMENT" ]]; then
    if ! configure_lxc_gpu_passthrough "$VLLM_LXC_ID" "$LXC_GPU_ASSIGNMENT"; then
        log "ERROR" "Failed to configure GPU passthrough for LXC $VLLM_LXC_ID."
        exit 1
    fi
else
    log "INFO" "No GPU assignment specified for LXC $VLLM_LXC_ID. Skipping GPU passthrough."
fi

if ! install_base_packages_in_lxc "$VLLM_LXC_ID"; then
    log "ERROR" "Failed to install base packages in LXC $VLLM_LXC_ID."
    exit 1
fi

if ! install_vllm_devstral_in_lxc "$VLLM_LXC_ID"; then
    log "ERROR" "Failed to install vLLM dependencies in LXC $VLLM_LXC_ID."
    exit 1
fi

log "INFO" "Creating vLLM service in LXC $VLLM_LXC_ID..."
vllm_service_cmd="cat > /etc/systemd/system/vllm.service << EOF
[Unit]
Description=vLLM Service
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker run --rm \\
  --runtime nvidia \\
  --gpus $VLLM_GPU_COUNT \\
  --shm-size $VLLM_SHM_SIZE \\
  -p 8000:8000 \\
  -v /root/.cache/huggingface:/root/.cache/huggingface \\
  --env HUGGING_FACE_HUB_TOKEN=\$HUGGING_FACE_HUB_TOKEN \\
  vllm/vllm-openai:latest \\
  --model $VLLM_MODEL \\
  --tensor-parallel-size $VLLM_TENSOR_PARALLEL_SIZE \\
  --max-model-len $VLLM_MAX_MODEL_LEN \\
  --kv-cache-dtype $VLLM_KV_CACHE_DTYPE \\
  --quantization $VLLM_QUANTIZATION \\
  --quantization_config.type $VLLM_QUANTIZATION_CONFIG_TYPE \\
  --host 0.0.0.0 \\
  --port 8000 \\
  --disable-log-requests \\
  $VLLM_ADDITIONAL_ARGS
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF"

if ! execute_in_lxc "$VLLM_LXC_ID" "$vllm_service_cmd"; then
    log "ERROR" "Failed to create vLLM service file in LXC $VLLM_LXC_ID."
    exit 1
fi

if ! execute_in_lxc "$VLLM_LXC_ID" "systemctl daemon-reload"; then
    log "ERROR" "Failed to reload systemd daemon in LXC $VLLM_LXC_ID."
    exit 1
fi
if ! execute_in_lxc "$VLLM_LXC_ID" "systemctl enable vllm.service"; then
    log "ERROR" "Failed to enable vLLM service in LXC $VLLM_LXC_ID."
    exit 1
fi
if ! execute_in_lxc "$VLLM_LXC_ID" "systemctl start vllm.service"; then
    log "ERROR" "Failed to start vLLM service in LXC $VLLM_LXC_ID."
    exit 1
fi

if ! health_check_vllm_api "$VLLM_LXC_ID"; then
    log "ERROR" "vLLM API health check failed for LXC $VLLM_LXC_ID."
    exit 1
fi

mark_script_completed "$marker_file"
log "INFO" "Completed phoenix_hypervisor_setup_drdevstral.sh for LXC $VLLM_LXC_ID successfully."
exit 0