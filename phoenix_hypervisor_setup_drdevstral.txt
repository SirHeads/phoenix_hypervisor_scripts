#!/bin/bash
# Phoenix Hypervisor DrDevstral Setup Script
# Configures an LXC container (e.g., 901 for drdevstral) with Docker, NVIDIA container runtime, and vLLM service.
# Uses arguments passed by the orchestrator (phoenix_establish_hypervisor.sh) for configuration.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - LXC created with GPU passthrough (handled by phoenix_hypervisor_create_lxc.sh)
# - phoenix_hypervisor_common.sh sourced
# - phoenix_hypervisor_config.sh sourced (for paths/defaults)
# Usage: ./phoenix_hypervisor_setup_drdevstral.sh <lxc_id> <name> <vllm_model> <vllm_tensor_parallel_size> <vllm_max_model_len> <vllm_kv_cache_dtype> <vllm_shm_size> <vllm_gpu_count> <vllm_quantization> <vllm_quantization_config_type> <vllm_api_port>
# Version: 1.7.3
# Author: Assistant
set -euo pipefail

# --- Source common functions and configuration ---
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# --- Check root privileges ---
log "INFO" "$0: Checking root privileges..."
check_root
log "INFO" "$0: Root check passed."

# --- Log start of script ---
log "INFO" "$0: Starting phoenix_hypervisor_setup_drdevstral.sh"

# --- Validate Arguments ---
if [[ $# -ne 11 ]]; then
    log "ERROR" "$0: Incorrect number of arguments. Expected 11, got $#"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Usage: $0 <lxc_id> <name> <vllm_model> <vllm_tensor_parallel_size> <vllm_max_model_len> <vllm_kv_cache_dtype> <vllm_shm_size> <vllm_gpu_count> <vllm_quantization> <vllm_quantization_config_type> <vllm_api_port>" >&2
    exit 1
fi

# Assign arguments
LXC_ID="$1"
LXC_NAME="$2"
VLLM_MODEL="$3"
VLLM_TENSOR_PARALLEL_SIZE="$4"
VLLM_MAX_MODEL_LEN="$5"
VLLM_KV_CACHE_DTYPE="$6"
VLLM_SHM_SIZE="$7"
VLLM_GPU_COUNT="$8"
VLLM_QUANTIZATION="$9"
VLLM_QUANTIZATION_CONFIG_TYPE="${10}"
VLLM_API_PORT="${11}"

# --- Validate LXC ID ---
if ! validate_lxc_id "$LXC_ID"; then
    log "ERROR" "$0: Invalid LXC ID format: '$LXC_ID'"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid LXC ID format: '$LXC_ID'." >&2
    exit 1
fi

# Ensure LXC config exists
if [[ -z "${LXC_CONFIGS[$LXC_ID]:-}" ]]; then
    log "ERROR" "$0: LXC ID $LXC_ID not found in LXC_CONFIGS."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LXC ID $LXC_ID not found in LXC_CONFIGS." >&2
    exit 1
fi
log "DEBUG" "$0: Valid LXC ID: $LXC_ID"

# --- Marker file ---
MARKER_FILE="${PHOENIX_HYPERVISOR_LXC_DRDEVSTRAL_MARKER/lxc_id/$LXC_ID}"
if is_script_completed "$MARKER_FILE"; then
    log "INFO" "$0: LXC $LXC_ID drdevstral setup already completed. Skipping."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $LXC_ID drdevstral setup already completed. Skipping." >&2
    exit 0
fi

# --- Ensure Hugging Face token ---
if [[ ! -t 0 ]] && [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    log "ERROR" "$0: Non-interactive environment detected and no HUGGING_FACE_HUB_TOKEN provided."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Non-interactive environment detected and no HUGGING_FACE_HUB_TOKEN provided." >&2
    exit 1
fi
if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    log "INFO" "$0: Prompting for Hugging Face token..."
    prompt_for_hf_token
    log "INFO" "$0: Hugging Face token set."
fi
if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    log "ERROR" "$0: HUGGING_FACE_HUB_TOKEN not set after prompting"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] HUGGING_FACE_HUB_TOKEN not set after prompting." >&2
    exit 1
fi

# --- Input Sanitization & Validation ---
sanitized_name=$(sanitize_input "$LXC_NAME")
if [[ "$sanitized_name" != "$LXC_NAME" ]]; then
    log "ERROR" "$0: LXC name '$LXC_NAME' for LXC $LXC_ID contains invalid characters."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LXC name '$LXC_NAME' for LXC $LXC_ID contains invalid characters." >&2
    exit 1
fi

required_fields=("VLLM_MODEL" "VLLM_TENSOR_PARALLEL_SIZE" "VLLM_MAX_MODEL_LEN" "VLLM_KV_CACHE_DTYPE" "VLLM_SHM_SIZE" "VLLM_GPU_COUNT" "VLLM_QUANTIZATION" "VLLM_QUANTIZATION_CONFIG_TYPE" "VLLM_API_PORT")
for field in "${required_fields[@]}"; do
    field_value="${!field}"
    if [[ -z "$field_value" ]]; then
        log "ERROR" "$0: Missing required vLLM field '$field' for LXC $LXC_ID"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Missing required vLLM field '$field' for LXC $LXC_ID." >&2
        exit 1
    fi
    sanitized_value=$(sanitize_input "$field_value")
    if [[ "$sanitized_value" != "$field_value" ]]; then
        log "ERROR" "$0: Field '$field' ('${field_value}') for LXC $LXC_ID contains invalid characters."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Field '$field' ('${field_value}') for LXC $LXC_ID contains invalid characters." >&2
        exit 1
    fi
done

# Validate numeric fields
if ! validate_numeric "$VLLM_TENSOR_PARALLEL_SIZE"; then
    log "ERROR" "$0: Invalid VLLM_TENSOR_PARALLEL_SIZE value for LXC $LXC_ID: '$VLLM_TENSOR_PARALLEL_SIZE'"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid VLLM_TENSOR_PARALLEL_SIZE value for LXC $LXC_ID: '$VLLM_TENSOR_PARALLEL_SIZE'." >&2
    exit 1
fi
if ! validate_numeric "$VLLM_MAX_MODEL_LEN"; then
    log "ERROR" "$0: Invalid VLLM_MAX_MODEL_LEN value for LXC $LXC_ID: '$VLLM_MAX_MODEL_LEN'"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid VLLM_MAX_MODEL_LEN value for LXC $LXC_ID: '$VLLM_MAX_MODEL_LEN'." >&2
    exit 1
fi
if ! validate_numeric "$VLLM_API_PORT"; then
    log "ERROR" "$0: Invalid VLLM_API_PORT value for LXC $LXC_ID: '$VLLM_API_PORT'"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid VLLM_API_PORT value for LXC $LXC_ID: '$VLLM_API_PORT'." >&2
    exit 1
fi
if [[ "$VLLM_API_PORT" -lt 1 ]] || [[ "$VLLM_API_PORT" -gt 65535 ]]; then
    log "ERROR" "$0: VLLM_API_PORT value for LXC $LXC_ID is out of range (1-65535): '$VLLM_API_PORT'"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] VLLM_API_PORT value for LXC $LXC_ID is out of range: '$VLLM_API_PORT'." >&2
    exit 1
fi

# --- Detect LXC OS version ---
log "INFO" "$0: Detecting LXC $LXC_ID OS version for repository configuration..."
os_codename=$(execute_in_lxc "$LXC_ID" "lsb_release -cs 2>/dev/null || grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'" 2>&1)
if [[ $? -ne 0 ]] || [[ -z "$os_codename" ]]; then
    log "WARN" "$0: Failed to detect OS codename in LXC $LXC_ID, falling back to 'noble'"
    os_codename="noble"
fi
log "DEBUG" "$0: Detected OS codename for LXC $LXC_ID: $os_codename"

# --- Install system packages ---
log "INFO" "$0: Installing system packages in LXC $LXC_ID..."
if ! execute_in_lxc "$LXC_ID" "apt-get update" 2>&1 | while read -r line; do log "DEBUG" "$0: apt-get update: $line"; done; then
    log "ERROR" "$0: Failed to update package lists in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to update package lists in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "apt-get install -y curl ca-certificates gnupg" 2>&1 | while read -r line; do log "DEBUG" "$0: apt-get install: $line"; done; then
    log "ERROR" "$0: Failed to install system packages in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to install system packages in LXC $LXC_ID." >&2
    exit 1
fi
log "INFO" "$0: System packages installed in LXC $LXC_ID"

# --- Install Docker ---
log "INFO" "$0: Installing Docker in LXC $LXC_ID..."
docker_keyring="/etc/apt/keyrings/docker.asc"
if ! execute_in_lxc "$LXC_ID" "mkdir -p /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg && gpg --dearmor -o $docker_keyring /tmp/docker.gpg && chmod 644 $docker_keyring" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker GPG key: $line"; done; then
    log "ERROR" "$0: Failed to add Docker GPG key in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to add Docker GPG key in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "echo 'deb [arch=$(dpkg --print-architecture) signed-by=$docker_keyring] https://download.docker.com/linux/ubuntu $os_codename stable' > /etc/apt/sources.list.d/docker.list" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker repo: $line"; done; then
    log "ERROR" "$0: Failed to add Docker repository in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to add Docker repository in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker install: $line"; done; then
    log "ERROR" "$0: Failed to install Docker in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to install Docker in LXC $LXC_ID." >&2
    exit 1
fi
log "INFO" "$0: Docker installed in LXC $LXC_ID"

# --- Configure Docker for NVIDIA runtime ---
log "INFO" "$0: Configuring Docker to use NVIDIA runtime in LXC $LXC_ID..."
docker_daemon_config='{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}'
escaped_daemon_config=$(printf '%q' "$docker_daemon_config")
if ! execute_in_lxc "$LXC_ID" "mkdir -p /etc/docker && echo $escaped_daemon_config > /etc/docker/daemon.json" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker daemon config: $line"; done; then
    log "ERROR" "$0: Failed to configure Docker daemon in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to configure Docker daemon in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "systemctl restart docker" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker restart: $line"; done; then
    log "ERROR" "$0: Failed to restart Docker service in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to restart Docker service in LXC $LXC_ID." >&2
    exit 1
fi
log "INFO" "$0: Docker configured with NVIDIA runtime in LXC $LXC_ID"

# --- Install NVIDIA Container Toolkit ---
log "INFO" "$0: Installing NVIDIA Container Toolkit in LXC $LXC_ID..."
nvidia_keyring="/etc/apt/keyrings/nvidia-container-toolkit.asc"
if ! execute_in_lxc "$LXC_ID" "mkdir -p /etc/apt/keyrings && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /tmp/nvidia.gpg && gpg --dearmor -o $nvidia_keyring /tmp/nvidia.gpg && chmod 644 $nvidia_keyring" 2>&1 | while read -r line; do log "DEBUG" "$0: NVIDIA GPG key: $line"; done; then
    log "ERROR" "$0: Failed to add NVIDIA Container Toolkit GPG key in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to add NVIDIA Container Toolkit GPG key in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "echo 'deb [signed-by=$nvidia_keyring] https://nvidia.github.io/libnvidia-container/stable/ubuntu22.04/$(dpkg --print-architecture) /' > /etc/apt/sources.list.d/nvidia-container-toolkit.list" 2>&1 | while read -r line; do log "DEBUG" "$0: NVIDIA repo: $line"; done; then
    log "ERROR" "$0: Failed to add NVIDIA Container Toolkit repository in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to add NVIDIA Container Toolkit repository in LXC $LXC_ID." >&2
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "apt-get update && apt-get install -y nvidia-container-toolkit nvidia-container-runtime" 2>&1 | while read -r line; do log "DEBUG" "$0: NVIDIA install: $line"; done; then
    log "ERROR" "$0: Failed to install NVIDIA Container Toolkit in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to install NVIDIA Container Toolkit in LXC $LXC_ID." >&2
    exit 1
fi
log "INFO" "$0: NVIDIA Container Toolkit installed in LXC $LXC_ID"

# --- Validate NVIDIA Container Toolkit ---
log "INFO" "$0: Validating NVIDIA Container Toolkit in LXC $LXC_ID..."
if ! execute_in_lxc "$LXC_ID" "nvidia-container-cli info" >/dev/null 2>&1; then
    log "ERROR" "$0: NVIDIA Container Toolkit validation failed in LXC $LXC_ID. Check GPU passthrough."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] NVIDIA Container Toolkit validation failed in LXC $LXC_ID." >&2
    exit 1
fi
log "INFO" "$0: NVIDIA Container Toolkit validated in LXC $LXC_ID"

# --- Pull and run vLLM Docker container ---
log "INFO" "$0: Pulling and running vLLM Docker container in LXC $LXC_ID on port $VLLM_API_PORT..."
docker_cmd="docker run -d \
    --name vllm-$sanitized_name \
    --gpus \"$VLLM_GPU_COUNT\" \
    --shm-size \"$VLLM_SHM_SIZE\" \
    -e HUGGING_FACE_HUB_TOKEN=\"$HUGGING_FACE_HUB_TOKEN\" \
    -p $VLLM_API_PORT:8000 \
    --ipc=host \
    vllm/vllm-openai:latest \
    --model \"$VLLM_MODEL\" \
    --tensor-parallel-size \"$VLLM_TENSOR_PARALLEL_SIZE\" \
    --max-model-len \"$VLLM_MAX_MODEL_LEN\" \
    --kv-cache-dtype \"$VLLM_KV_CACHE_DTYPE\" \
    --quantization \"$VLLM_QUANTIZATION\" \
    --quantization-config-type \"$VLLM_QUANTIZATION_CONFIG_TYPE\""
if ! execute_in_lxc "$LXC_ID" "$docker_cmd" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker run: $line"; done; then
    log "ERROR" "$0: Failed to run vLLM Docker container in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to run vLLM Docker container in LXC $LXC_ID." >&2
    execute_in_lxc "$LXC_ID" "docker logs vllm-$sanitized_name" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker logs: $line"; done || true
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    exit 1
fi
log "INFO" "$0: vLLM Docker container started in LXC $LXC_ID"

# --- Create systemd service ---
log "INFO" "$0: Creating vLLM systemd service in LXC $LXC_ID..."
read -r -d '' systemd_service_content <<EOF
[Unit]
Description=vLLM Service for $sanitized_name on port $VLLM_API_PORT
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/docker start vllm-$sanitized_name
ExecStop=/usr/bin/docker stop vllm-$sanitized_name
Restart=always
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
escaped_service_content=$(printf '%q' "$systemd_service_content")
if ! execute_in_lxc "$LXC_ID" "echo $escaped_service_content > /etc/systemd/system/vllm-$sanitized_name.service" 2>&1 | while read -r line; do log "DEBUG" "$0: systemd service write: $line"; done; then
    log "ERROR" "$0: Failed to create vLLM systemd service file in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to create vLLM systemd service file in LXC $LXC_ID." >&2
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "systemctl daemon-reload" 2>&1 | while read -r line; do log "DEBUG" "$0: systemctl daemon-reload: $line"; done; then
    log "ERROR" "$0: Failed to reload systemd in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to reload systemd in LXC $LXC_ID." >&2
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "systemctl enable vllm-$sanitized_name.service" 2>&1 | while read -r line; do log "DEBUG" "$0: systemctl enable: $line"; done; then
    log "ERROR" "$0: Failed to enable vLLM service in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to enable vLLM service in LXC $LXC_ID." >&2
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    exit 1
fi
if ! execute_in_lxc "$LXC_ID" "systemctl start vllm-$sanitized_name.service" 2>&1 | while read -r line; do log "DEBUG" "$0: systemctl start: $line"; done; then
    log "ERROR" "$0: Failed to start vLLM service in LXC $LXC_ID"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to start vLLM service in LXC $LXC_ID." >&2
    execute_in_lxc "$LXC_ID" "systemctl status vllm-$sanitized_name.service" 2>&1 | while read -r line; do log "DEBUG" "$0: systemctl status: $line"; done || true
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    execute_in_lxc "$LXC_ID" "systemctl disable vllm-$sanitized_name.service; rm -f /etc/systemd/system/vllm-$sanitized_name.service; systemctl daemon-reload" >/dev/null 2>&1 || true
    exit 1
fi
log "INFO" "$0: vLLM systemd service created and started in LXC $LXC_ID"

# --- Post-Deployment Health Check ---
log "INFO" "$0: Performing post-deployment health check for LXC $LXC_ID on port $VLLM_API_PORT..."
max_attempts=5
delay=10
attempt=1
health_check_passed=false
while [[ $attempt -le $max_attempts ]]; do
    log "INFO" "$0: Health check attempt $attempt/$max_attempts for LXC $LXC_ID..."
    if execute_in_lxc "$LXC_ID" "curl -f http://localhost:$VLLM_API_PORT/v1/health" >/dev/null 2>&1; then
        log "INFO" "$0: Health check passed for LXC $LXC_ID on attempt $attempt."
        health_check_passed=true
        break
    else
        log "WARN" "$0: Health check failed for LXC $LXC_ID on attempt $attempt. Waiting $delay seconds before retry..."
        execute_in_lxc "$LXC_ID" "docker logs vllm-$sanitized_name" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker logs: $line"; done || true
        sleep "$delay"
        ((attempt++))
    fi
done
if [[ "$health_check_passed" != true ]]; then
    log "ERROR" "$0: Health check failed for LXC $LXC_ID after $max_attempts attempts."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Health check failed for LXC $LXC_ID after $max_attempts attempts." >&2
    execute_in_lxc "$LXC_ID" "docker logs vllm-$sanitized_name" 2>&1 | while read -r line; do log "DEBUG" "$0: Docker logs: $line"; done || true
    execute_in_lxc "$LXC_ID" "docker stop vllm-$sanitized_name; docker rm vllm-$sanitized_name" >/dev/null 2>&1 || true
    execute_in_lxc "$LXC_ID" "systemctl disable vllm-$sanitized_name.service; rm -f /etc/systemd/system/vllm-$sanitized_name.service; systemctl daemon-reload" >/dev/null 2>&1 || true
    exit 1
fi

# --- Mark setup as complete ---
log "INFO" "$0: Marking drdevstral setup as complete for LXC $LXC_ID..."
mark_script_completed "$MARKER_FILE"
log "INFO" "$0: Completed phoenix_hypervisor_setup_drdevstral.sh for LXC $LXC_ID successfully"
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Phoenix Hypervisor drdevstral setup completed successfully for LXC $LXC_ID." >&2
exit 0