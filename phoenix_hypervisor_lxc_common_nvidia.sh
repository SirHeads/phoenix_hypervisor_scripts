#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers, toolkit, and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh)
# Version: 1.8.0
# Author: Assistant

# --- Enhanced Sourcing of Dependencies ---
# This script is intended to be sourced, not executed.
# It relies on functions and variables from phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh
# The sourcing script should handle sourcing the main dependencies.
# However, we add a check to ensure critical dependencies are available if sourced independently.

if ! declare -f log_info > /dev/null 2>&1; then
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/bin/phoenix_hypervisor_common.sh
        echo "[WARN] phoenix_hypervisor_lxc_common_nvidia.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    else
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Required function 'log_info' not found and common functions file could not be sourced." >&2
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Please ensure phoenix_hypervisor_common.sh is sourced before sourcing this file." >&2
        return 1
    fi
fi

# --- NVIDIA Functions for LXC Containers ---

# - Setup NVIDIA Repository in Container -
setup_nvidia_repo_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "setup_nvidia_repo_in_container: Missing lxc_id"
        return 1
    fi

    log_info "Setting up NVIDIA CUDA repository in container $lxc_id..."
    echo "Setting up NVIDIA CUDA repository in container $lxc_id... This may take a moment."

    local repo_cmd="
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
"
    if ! pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$repo_cmd
EOF
    then
        log_error "setup_nvidia_repo_in_container: Failed to set up NVIDIA repository in container $lxc_id"
        return 1
    fi

    log_info "NVIDIA CUDA repository setup completed for container $lxc_id"
    echo "NVIDIA CUDA repository setup completed for container $lxc_id."
    return 0
}

# - Install NVIDIA Userland Driver in Container -
install_nvidia_userland_in_container() {
    local lxc_id="$1"
    local driver_version="580" # Fixed to match user-provided command

    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_userland_in_container: Missing lxc_id"
        return 1
    fi

    log_info "Installing NVIDIA userland driver (version $driver_version) in container $lxc_id..."
    echo "Installing NVIDIA driver in container $lxc_id... This may take a few minutes."

    # Check if driver is already installed
    local check_cmd="
if dpkg -l | grep -q nvidia-open-$driver_version; then
    echo '[SUCCESS] NVIDIA driver $driver_version already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$check_cmd
EOF
    then
        log_info "NVIDIA driver $driver_version already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
echo '[INFO] Installing NVIDIA open driver ($driver_version)... This may take a few minutes.'
apt-get install -y --no-install-recommends nvidia-open-$driver_version || { echo '[ERROR] Failed to install NVIDIA driver'; exit 1; }
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] NVIDIA driver installed successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA driver verification failed in container $lxc_id.'
    exit 1
fi
"
    if ! pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$install_cmd
EOF
    then
        log_error "install_nvidia_userland_in_container: Failed to install NVIDIA driver in container $lxc_id"
        return 1
    fi

    log_info "NVIDIA userland driver installed successfully in container $lxc_id"
    echo "NVIDIA driver installation completed for container $lxc_id."
    return 0
}

# - Install NVIDIA Container Toolkit in Container -
install_nvidia_toolkit_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_toolkit_in_container: Missing lxc_id"
        return 1
    fi

    log_info "Installing NVIDIA Container Toolkit in container $lxc_id..."
    echo "Installing NVIDIA Container Toolkit in container $lxc_id... This may take a few minutes."

    local check_cmd="
if dpkg -l | grep -q nvidia-container-toolkit; then
    echo '[SUCCESS] NVIDIA Container Toolkit already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$check_cmd
EOF
    then
        log_info "NVIDIA Container Toolkit already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
echo '[INFO] Installing NVIDIA Container Toolkit... This may take a few minutes.'
apt-get install -y nvidia-container-toolkit || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; exit 1; }
if command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[SUCCESS] NVIDIA Container Toolkit installed successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA Container Toolkit verification failed in container $lxc_id.'
    exit 1
fi
"
    if ! pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$install_cmd
EOF
    then
        log_error "install_nvidia_toolkit_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id"
        return 1
    fi

    log_info "NVIDIA Container Toolkit installed successfully in container $lxc_id"
    echo "NVIDIA Container Toolkit installation completed for container $lxc_id."
    return 0
}

# - Configure NVIDIA Runtime for Docker -
configure_docker_nvidia_runtime() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    log_info "Configuring NVIDIA runtime for Docker in container $lxc_id..."
    echo "Configuring NVIDIA runtime for Docker in container $lxc_id..."

    local config_cmd="
set -e
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
fi
if [[ ! -f /etc/docker/daemon.json ]]; then
    echo '[INFO] Configuring NVIDIA runtime for Docker...'
    nvidia-ctk runtime configure --runtime=nvidia || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
    systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
    echo '[SUCCESS] NVIDIA runtime configured successfully.'
else
    echo '[INFO] NVIDIA runtime already configured.'
fi
"
    if ! pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$config_cmd
EOF
    then
        log_error "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id"
        return 1
    fi

    log_info "NVIDIA runtime configured successfully for container $lxc_id"
    echo "NVIDIA runtime configuration completed for container $lxc_id."
    return 0
}

# - Detect GPUs Inside Container -
detect_gpus_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "detect_gpus_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "Detecting GPUs in container $lxc_id..."
    echo "Checking GPU access in container $lxc_id..."

    local check_cmd="
set -e
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo '[SUCCESS] GPUs detected in container $lxc_id.'
        nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -n 1
        exit 0
    else
        echo '[ERROR] nvidia-smi command failed inside container $lxc_id.'
        exit 1
    fi
else
    echo '[ERROR] nvidia-smi not found inside container $lxc_id.'
    exit 1
fi
"
    local result
    result=$(pct exec "$lxc_id" -- bash <<EOF 2>&1
$check_cmd
EOF
)
    local exit_code=$?

    log_info "detect_gpus_in_container output: $result"
    log_info "detect_gpus_in_container exit code: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        log_info "GPUs detected successfully in container $lxc_id"
        # Additional check for NVIDIA Container Toolkit in Docker
        local docker_check="
set -e
if command -v docker >/dev/null 2>&1 && docker run --rm --gpus all --runtime=nvidia nvidia/cuda:12.0-base nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] Docker GPU access verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed in container $lxc_id.'
    exit 1
fi
"
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$docker_check
EOF
        then
            log_info "Docker GPU access verified successfully in container $lxc_id"
            return 0
        else
            log_warn "Docker GPU access verification failed in container $lxc_id"
            return 1
        fi
    else
        log_warn "GPU detection failed in container $lxc_id. Output: $result"
        return 1
    fi
}

# - Verify LXC GPU Access Inside Container -
verify_lxc_gpu_access_in_container() {
    local lxc_id="$1"
    local gpu_indices="$2" # Not actively used in the provided logic, but kept for signature consistency

    if [[ -z "$lxc_id" ]]; then
        log_error "verify_lxc_gpu_access_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "Verifying GPU access/passthrough for container $lxc_id..."

    if detect_gpus_in_container "$lxc_id"; then
        log_info "GPU access verified successfully for container $lxc_id."
        return 0
    else
        log_error "Failed to verify GPU access for container $lxc_id."
        return 1
    fi
}

# - Configures GPU passthrough by modifying the LXC config file directly -
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2" # e.g., "0,1"

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing lxc_id or gpu_indices"
        return 1
    fi

    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC config file not found: $config_file"
        return 1
    fi

    log_info "Adding GPU passthrough entries to $config_file for GPUs: $gpu_indices"

    # Remove any existing GPU-related entries to avoid duplicates
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 195/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 235/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 236/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 237/d' "$config_file"
    sed -i '/^lxc\.cap\.drop:/d' "$config_file"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$config_file"
    sed -i '/^dev[0-9]*:/d' "$config_file"
    sed -i '/^swap: /d' "$config_file"

    # Add device entries for GPU and related devices
    echo "dev0: /dev/dri/card0,gid=44" >> "$config_file"
    echo "dev1: /dev/dri/renderD128,gid=104" >> "$config_file"
    local dev_index=2
    IFS=',' read -ra INDICES <<< "$gpu_indices"
    for index in "${INDICES[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "configure_lxc_gpu_passthrough: Invalid GPU index: $index (must be numeric)"
            return 1
        fi
        echo "dev$dev_index: /dev/nvidia$index" >> "$config_file"
        ((dev_index++))
    done
    echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap1" >> "$config_file"
    ((dev_index++))
    echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap2" >> "$config_file"
    ((dev_index++))
    echo "dev$dev_index: /dev/nvidiactl" >> "$config_file"
    ((dev_index++))
    echo "dev$dev_index: /dev/nvidia-modeset" >> "$config_file"
    ((dev_index++))
    echo "dev$dev_index: /dev/nvidia-uvm-tools" >> "$config_file"
    ((dev_index++))
    echo "dev$dev_index: /dev/nvidia-uvm" >> "$config_file"

    # Add additional configuration to match provided working setup
    echo "lxc.cgroup2.devices.allow: a" >> "$config_file"
    echo "lxc.cap.drop:" >> "$config_file"
    echo "swap: 512" >> "$config_file"

    log_info "GPU passthrough configured for container $lxc_id (GPUs: $gpu_indices)"
    return 0
}

# Signal that this library has been loaded
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."