#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers, toolkit, and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh)
# Version: 1.8.4
# Author: Assistant

# --- Enhanced Sourcing of Dependencies ---
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

# - Install Docker-ce in Container -
install_docker_ce_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_docker_ce_in_container: Missing lxc_id"
        return 1
    fi

    log_info "Installing Docker-ce in container $lxc_id..."
    echo "Installing Docker-ce in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v docker >/dev/null 2>&1 && dpkg -l | grep -q docker-ce; then
    echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$check_cmd
EOF
    then
        log_info "Docker-ce already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Removing conflicting Docker packages...'
apt-get remove -y docker docker-engine docker.io containerd runc || true
apt-get update -y --fix-missing
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg   | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu   noble stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Installing Docker-ce...'
apt-get install -y docker-ce docker-ce-cli containerd.io || { echo '[ERROR] Failed to install Docker-ce'; exit 1; }
systemctl enable docker
systemctl start docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo '[SUCCESS] Docker-ce installed successfully in container $lxc_id.'
else
    echo '[ERROR] Docker-ce verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempting Docker-ce installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$install_cmd
EOF
        then
            log_info "Docker-ce installed successfully in container $lxc_id"
            echo "Docker-ce installation completed for container $lxc_id."
            return 0
        else
            log_warn "Docker-ce installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Setup NVIDIA Repository in Container -
setup_nvidia_repo_in_container() {
    local lxc_id="$1"
    local nvidia_repo_url="$2"
    if [[ -z "$lxc_id" ]] || [[ -z "$nvidia_repo_url" ]]; then
        log_error "setup_nvidia_repo_in_container: Missing lxc_id or nvidia_repo_url"
        return 1
    fi

    log_info "Setting up NVIDIA CUDA repository in container $lxc_id..."
    echo "Setting up NVIDIA CUDA repository in container $lxc_id... This may take a moment."

    local repo_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Setting up locale...'
apt-get update -y --fix-missing
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
    echo '[INFO] Downloading NVIDIA Container Toolkit keyring...'
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey   | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg || { echo '[ERROR] Failed to download NVIDIA Container Toolkit keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
    echo '[INFO] Setting up NVIDIA Container Toolkit repository...'
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list   | \
        sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
fi
if [[ ! -f /etc/apt/keyrings/cuda-archive-keyring.gpg ]]; then
    echo '[INFO] Downloading CUDA keyring...'
    wget -qO /etc/apt/keyrings/cuda-archive-keyring.gpg ${nvidia_repo_url}cuda-archive-keyring.gpg || { echo '[ERROR] Failed to download CUDA keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/cuda.list ]]; then
    echo '[INFO] Setting up CUDA repository...'
    echo 'deb [signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] ${nvidia_repo_url} /' | tee /etc/apt/sources.list.d/cuda.list > /dev/null
fi
echo '[INFO] Updating package lists... This may take a few minutes.'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempting NVIDIA repository setup (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$repo_cmd
EOF
        then
            log_info "NVIDIA CUDA and Container Toolkit repositories setup completed for container $lxc_id"
            echo "NVIDIA repositories setup completed for container $lxc_id."
            return 0
        else
            log_warn "NVIDIA repository setup failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "setup_nvidia_repo_in_container: Failed to set up NVIDIA repositories in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Install NVIDIA Userland Driver in Container -
install_nvidia_userland_in_container() {
    local lxc_id="$1"
    local driver_version="$2"

    if [[ -z "$lxc_id" ]] || [[ -z "$driver_version" ]]; then
        log_error "install_nvidia_userland_in_container: Missing lxc_id or driver_version"
        return 1
    fi

    log_info "Installing NVIDIA userland driver (version $driver_version) in container $lxc_id..."
    echo "Installing NVIDIA driver in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if dpkg -l | grep -q nvidia-driver-${driver_version%%.*}; then
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
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Installing NVIDIA driver ($driver_version)... This may take a few minutes.'
apt-get install -y --no-install-recommends nvidia-driver-${driver_version%%.*} || { echo '[ERROR] Failed to install NVIDIA driver'; exit 1; }
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader | grep -q \"$driver_version\"; then
    echo '[SUCCESS] NVIDIA driver installed successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA driver verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempting NVIDIA driver installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$install_cmd
EOF
        then
            log_info "NVIDIA userland driver installed successfully in container $lxc_id"
            echo "NVIDIA driver installation completed for container $lxc_id."
            return 0
        else
            log_warn "NVIDIA driver installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_nvidia_userland_in_container: Failed to install NVIDIA driver in container $lxc_id after $max_attempts attempts"
    return 1
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
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
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
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Installing NVIDIA Container Toolkit... This may take a few minutes.'
apt-get install -y --no-install-recommends nvidia-container-toolkit nvidia-container-toolkit-base || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; exit 1; }
if command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[INFO] Configuring NVIDIA runtime for Docker...'
    nvidia-ctk runtime configure --runtime=docker || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
    systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
    echo '[SUCCESS] NVIDIA Container Toolkit installed and configured successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA Container Toolkit verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempting NVIDIA Container Toolkit installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$install_cmd
EOF
        then
            log_info "NVIDIA Container Toolkit installed successfully in container $lxc_id"
            echo "NVIDIA Container Toolkit installation completed for container $lxc_id."
            return 0
        else
            log_warn "NVIDIA Container Toolkit installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_nvidia_toolkit_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Configure NVIDIA Runtime for Docker -
configure_docker_nvidia_runtime() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    log_info "Configuring NVIDIA runtime for Docker in container $lxc_id..."
    echo "Configuring NVIDIA runtime for Docker in container $lxc_id... This may take a moment."

    local config_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[INFO] NVIDIA runtime already configured.'
    exit 0
fi
echo '[INFO] Configuring NVIDIA runtime for Docker...'
nvidia-ctk runtime configure --runtime=docker || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
echo '[INFO] Restarting Docker service...'
systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
sleep 5
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[SUCCESS] NVIDIA runtime configured successfully.'
else
    echo '[ERROR] NVIDIA runtime verification failed.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempting NVIDIA runtime configuration (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash <<EOF 2>&1 | tee -a "$HYPERVISOR_LOGFILE"
$config_cmd
EOF
        then
            log_info "NVIDIA runtime configured successfully for container $lxc_id"
            echo "NVIDIA runtime configuration completed for container $lxc_id."
            return 0
        else
            log_warn "NVIDIA runtime configuration failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id after $max_attempts attempts"
    return 1
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
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo '[SUCCESS] GPUs detected in container $lxc_id.'
        nvidia-smi --query-gpu=count,driver_version,cuda_version --format=csv,noheader | head -n 1
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
        local docker_check="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
if ! docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[ERROR] NVIDIA runtime not configured in Docker.'
    exit 1
fi
if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:13.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
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
    local gpu_indices="$2"

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
    local gpu_indices="$2"

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing lxc_id or gpu_indices"
        return 1
    fi

    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ -f "$config_file" ]]; then
        chmod u+w "$config_file"
    else
        log_error "configure_lxc_gpu_passthrough: LXC config file not found: $config_file"
        return 1
    fi

    log_info "Adding GPU passthrough entries to $config_file for GPUs: $gpu_indices"

    # --- Cleanup existing GPU-related entries ---
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 195/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 235/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 236/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 237/d' "$config_file"
    sed -i '/^lxc\.cap\.drop:/d' "$config_file"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$config_file"
    sed -i '/^dev[0-9]*:/d' "$config_file"
    sed -i '/^swap: /d' "$config_file"
    sed -i '/^lxc\.autodev:/d' "$config_file"
    sed -i '/^lxc\.mount\.auto:/d' "$config_file"
    # --- End Cleanup ---

    # --- Add essential static devices ---
    # DRI devices (often needed for graphics/CUDA)
    echo "dev0: /dev/dri/card0,gid=44" >> "$config_file"
    echo "dev1: /dev/dri/renderD128,gid=104" >> "$config_file"
    local dev_index=2
    # --- End Static Devices ---

    # --- Add GPU-specific devices dynamically ---
    IFS=',' read -ra INDICES <<< "$gpu_indices"
    for index in "${INDICES[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "configure_lxc_gpu_passthrough: Invalid GPU index: $index (must be numeric)"
            return 1
        fi
        # Add the core NVIDIA device node for the GPU
        echo "dev$dev_index: /dev/nvidia$index" >> "$config_file"
        ((dev_index++))
    done

    # Add common NVIDIA capability devices if they exist on the host
    # Check and add nvidia-caps devices
    if [[ -e "/dev/nvidia-caps/nvidia-cap1" ]]; then
        echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap1" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-caps/nvidia-cap1 not found on host, skipping."
    fi

    if [[ -e "/dev/nvidia-caps/nvidia-cap2" ]]; then
        echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap2" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-caps/nvidia-cap2 not found on host, skipping."
    fi

    # Add core control devices if they exist on the host
    if [[ -e "/dev/nvidiactl" ]]; then
        echo "dev$dev_index: /dev/nvidiactl" >> "$config_file"
        ((dev_index++))
    else
        log_error "configure_lxc_gpu_passthrough: Critical device /dev/nvidiactl not found on host!"
        # This is likely a critical error, but we'll warn and continue for robustness
    fi

    # --- MODIFICATION: Check for nvidia-modeset existence ---
    if [[ -e "/dev/nvidia-modeset" ]]; then
        echo "dev$dev_index: /dev/nvidia-modeset" >> "$config_file"
        ((dev_index++))
        log_info "configure_lxc_gpu_passthrough: Added /dev/nvidia-modeset to container config."
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-modeset not found on host, skipping passthrough for this device."
        # Do not add the line if the device doesn't exist
    fi
    # --- END MODIFICATION ---

    # Add UVM devices if they exist on the host
    if [[ -e "/dev/nvidia-uvm-tools" ]]; then
        echo "dev$dev_index: /dev/nvidia-uvm-tools" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-uvm-tools not found on host, skipping."
    fi

    if [[ -e "/dev/nvidia-uvm" ]]; then
        echo "dev$dev_index: /dev/nvidia-uvm" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-uvm not found on host, skipping."
    fi
    # --- End GPU-specific Devices ---

    # --- Add final LXC configuration options ---
    echo "lxc.cgroup2.devices.allow: a" >> "$config_file"
    echo "lxc.cap.drop:" >> "$config_file" # Explicitly drop no capabilities, might need adjustment
    echo "swap: 512" >> "$config_file"
    echo "lxc.autodev: 1" >> "$config_file"
    echo "lxc.mount.auto: sys:rw" >> "$config_file"
    # --- End Final Options ---

    chmod u-w "$config_file"

    log_info "GPU passthrough configuration updated for container $lxc_id (GPUs: $gpu_indices)"
    return 0
}

# Signal that this library has been loaded
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."