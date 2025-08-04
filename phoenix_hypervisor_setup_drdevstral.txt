#!/bin/bash
# Phoenix Hypervisor DrDevstral Setup Script
# Configures an LXC container (e.g., 901 for drdevstral) with Docker, NVIDIA container runtime, and vLLM service.
# Uses JSON config for vLLM parameters.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - LXC created with GPU passthrough
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# Usage: ./phoenix_hypervisor_setup_drdevstral.sh <lxc_id>
# Version: 1.6.9 (Removed default LXC_ID, enhanced debugging)

set -euo pipefail

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check root privileges
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "$0: Starting phoenix_hypervisor_setup_drdevstral.sh"

# --- Validate LXC ID ---
LXC_ID="$1"
if [[ -z "$LXC_ID" ]]; then
    log "ERROR" "$0: LXC ID must be provided as an argument"
    exit 1
fi
if [[ -z "${LXC_CONFIGS[$LXC_ID]}" ]]; then
    log "ERROR" "$0: LXC ID $LXC_ID not found in LXC_CONFIGS"
    exit 1
fi
if [[ -z "${LXC_SETUP_SCRIPTS[$LXC_ID]}" ]]; then
    log "ERROR" "$0: No setup script defined for LXC $LXC_ID in LXC_SETUP_SCRIPTS"
    exit 1
fi
log "DEBUG" "$0: Valid LXC ID: $LXC_ID"

# --- Re-validate JSON config ---
validate_json_config "$PHOENIX_LXC_CONFIG_FILE"

# --- Ensure Hugging Face token ---
prompt_for_hf_token
if [[ -z "$HUGGING_FACE_HUB_TOKEN" ]]; then
    log "ERROR" "$0: HUGGING_FACE_HUB_TOKEN not set after prompting"
    exit 1
fi

# --- Marker file ---
MARKER_FILE="${HYPERVISOR_MARKER_DIR}/lxc_${LXC_ID}_setup_drdevstral.marker"
if is_script_completed "$MARKER_FILE"; then
    log "INFO" "$0: LXC $LXC_ID setup already completed. Skipping."
    exit 0
fi

# --- Parse LXC configuration ---
IFS='|' read -r name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type <<< "${LXC_CONFIGS[$LXC_ID]}"

log "DEBUG" "$0: LXC $LXC_ID config: name=$name, vllm_model=$vllm_model, tensor_parallel_size=$vllm_tensor_parallel_size"

# --- Validate required vLLM fields ---
required_fields=("vllm_model" "vllm_tensor_parallel_size" "vllm_max_model_len" "vllm_kv_cache_dtype" "vllm_shm_size" "vllm_gpu_count" "vllm_quantization" "vllm_quantization_config_type")
for field in "${required_fields[@]}"; do
    if [[ -z "${!field}" ]]; then
        log "ERROR" "$0: Missing required vLLM field '$field' for LXC $LXC_ID"
        exit 1
    fi
done

# --- Install system packages ---
log "INFO" "$0: Installing system packages in LXC $LXC_ID..."
execute_in_lxc "$LXC_ID" "apt-get update" || { log "ERROR" "$0: Failed to update package lists in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "apt-get install -y curl ca-certificates gnupg" || { log "ERROR" "$0: Failed to install system packages in LXC $LXC_ID"; exit 1; }
log "DEBUG" "$0: System packages installed in LXC $LXC_ID"

# --- Install Docker ---
log "INFO" "$0: Installing Docker in LXC $LXC_ID..."
execute_in_lxc "$LXC_ID" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg" || { log "ERROR" "$0: Failed to add Docker GPG key in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable' > /etc/apt/sources.list.d/docker.list" || { log "ERROR" "$0: Failed to add Docker repository in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io" || { log "ERROR" "$0: Failed to install Docker in LXC $LXC_ID"; exit 1; }
log "DEBUG" "$0: Docker installed in LXC $LXC_ID"

# --- Install NVIDIA container runtime ---
log "INFO" "$0: Installing NVIDIA container runtime in LXC $LXC_ID..."
execute_in_lxc "$LXC_ID" "curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | apt-key add -" || { log "ERROR" "$0: Failed to add NVIDIA container runtime GPG key in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "curl -s -L https://nvidia.github.io/nvidia-container-runtime/ubuntu20.04/nvidia-container-runtime.list > /etc/apt/sources.list.d/nvidia-container-runtime.list" || { log "ERROR" "$0: Failed to add NVIDIA container runtime repository in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "apt-get update && apt-get install -y nvidia-container-runtime" || { log "ERROR" "$0: Failed to install NVIDIA container runtime in LXC $LXC_ID"; exit 1; }
log "DEBUG" "$0: NVIDIA container runtime installed in LXC $LXC_ID"

# --- Validate NVIDIA container runtime ---
log "INFO" "$0: Validating NVIDIA container runtime in LXC $LXC_ID..."
if ! execute_in_lxc "$LXC_ID" "nvidia-container-cli info" > /dev/null; then
    log "ERROR" "$0: NVIDIA container runtime validation failed in LXC $LXC_ID"
    exit 1
fi
log "DEBUG" "$0: NVIDIA container runtime validated in LXC $LXC_ID"

# --- Pull and run vLLM Docker container ---
log "INFO" "$0: Pulling and running vLLM Docker container in LXC $LXC_ID..."
docker_cmd="docker run -d \
    --name vllm-$name \
    --gpus \"$vllm_gpu_count\" \
    --shm-size \"$vllm_shm_size\" \
    -e HUGGING_FACE_HUB_TOKEN=\"$HUGGING_FACE_HUB_TOKEN\" \
    -p 8000:8000 \
    vllm/vllm-openai:latest \
    --model \"$vllm_model\" \
    --tensor-parallel-size $vllm_tensor_parallel_size \
    --max-model-len $vllm_max_model_len \
    --kv-cache-dtype \"$vllm_kv_cache_dtype\" \
    --quantization \"$vllm_quantization\" \
    --quantization-config-type \"$vllm_quantization_config_type\""

log "DEBUG" "$0: Docker run command: $docker_cmd"
execute_in_lxc "$LXC_ID" "$docker_cmd" || { log "ERROR" "$0: Failed to run vLLM Docker container in LXC $LXC_ID"; exit 1; }
log "DEBUG" "$0: vLLM Docker container started in LXC $LXC_ID"

# --- Create systemd service ---
log "INFO" "$0: Creating vLLM systemd service in LXC $LXC_ID..."
systemd_service="[Unit]
Description=vLLM Service for $name
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/docker start vllm-$name
ExecStop=/usr/bin/docker stop vllm-$name
Restart=always

[Install]
WantedBy=multi-user.target"

execute_in_lxc "$LXC_ID" "echo '$systemd_service' > /etc/systemd/system/vllm-$name.service" || { log "ERROR" "$0: Failed to create vLLM systemd service file in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "systemctl daemon-reload" || { log "ERROR" "$0: Failed to reload systemd in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "systemctl enable vllm-$name.service" || { log "ERROR" "$0: Failed to enable vLLM service in LXC $LXC_ID"; exit 1; }
execute_in_lxc "$LXC_ID" "systemctl start vllm-$name.service" || { log "ERROR" "$0: Failed to start vLLM service in LXC $LXC_ID"; exit 1; }
log "DEBUG" "$0: vLLM systemd service created and started in LXC $LXC_ID"

# --- Mark setup as complete ---
mark_script_completed "$MARKER_FILE"
log "INFO" "$0: Completed phoenix_hypervisor_setup_drdevstral.sh for LXC $LXC_ID successfully"
exit 0