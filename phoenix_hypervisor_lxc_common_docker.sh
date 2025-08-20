#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_docker.sh
#
# Common functions for Docker operations inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)

# --- Docker Installation ---

# Install Docker Community Edition inside an LXC container
# Usage: install_docker_ce_in_container <container_id>
install_docker_ce_in_container() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "install_docker_ce_in_container: Missing lxc_id"
        return 1
    fi

    "$log_func" "install_docker_ce_in_container: Installing Docker-ce in container $lxc_id..."
    echo "Installing Docker-ce in container $lxc_id... This may take a few minutes."

    local check_cmd="set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v docker >/dev/null 2>&1 && dpkg -l| grep -q docker-ce; then
    echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
    exit 0
fi
exit 1"

    # Check if Docker is already installed
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>/dev/null; then
        "$log_func" "install_docker_ce_in_container: Docker-ce already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Removing conflicting Docker packages...'
apt-get remove -y docker docker-engine docker.io containerd runc || true
apt-get update -y --fix-missing
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg| gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# Use 'noble' codename for Ubuntu 24.04/24.10 compatibility
echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
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
fi"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "install_docker_ce_in_container: Attempting Docker-ce installation (attempt $attempt/$max_attempts)..."
        # Execute the installation command inside the container
        # Note: HYPERVISOR_LOGFILE is assumed from config, fallback to /dev/null if not set
        local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
        if pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1 | tee -a "$log_file"; then
            "$log_func" "install_docker_ce_in_container: Docker-ce installed successfully in container $lxc_id"
            echo "Docker-ce installation completed for container $lxc_id."
            return 0
        else
            # Use log_warn if available, otherwise fallback
            local warn_func="log_warn"
            if ! declare -F log_warn >/dev/null 2>&1; then
                warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
            fi
            "$warn_func" "install_docker_ce_in_container: Docker-ce installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    "$error_func" "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after $max_attempts attempts"
    return 1
}


# --- Docker Image Management ---

# Build a Docker image inside an LXC container from a Dockerfile path
# Usage: build_docker_image_in_container <container_id> <dockerfile_path> <image_tag>
build_docker_image_in_container() {
    local lxc_id="$1"
    local dockerfile_path="$2"
    local image_tag="$3"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$dockerfile_path" ]] || [[ -z "$image_tag" ]]; then
        "$error_func" "build_docker_image_in_container: Missing lxc_id, dockerfile_path, or image_tag"
        return 1
    fi

    "$log_func" "build_docker_image_in_container: Building Docker image $image_tag in container $lxc_id from $dockerfile_path..."
    echo "Building Docker image $image_tag in container $lxc_id... This may take a few minutes."

    local check_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag already exists in container $lxc_id.'
    exit 0
fi
exit 1"

    # Check if the image already exists
    # Note: HYPERVISOR_LOGFILE is assumed from config, fallback to /dev/null if not set
    local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "$log_file"; then
        "$log_func" "build_docker_image_in_container: Docker image $image_tag already exists in container $lxc_id."
        return 0
    fi

    local build_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
echo '[INFO] Building Docker image $image_tag...'
# Change to the directory containing the Dockerfile
cd \"\$(dirname $dockerfile_path)\" || { echo '[ERROR] Failed to change directory'; exit 1; }
docker build -t $image_tag -f $dockerfile_path . || { echo '[ERROR] Failed to build Docker image $image_tag'; exit 1; }
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag built successfully in container $lxc_id.'
else
    echo '[ERROR] Docker image $image_tag verification failed in container $lxc_id.'
    exit 1
fi"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "build_docker_image_in_container: Attempting Docker image build (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$build_cmd" 2>&1 | tee -a "$log_file"; then
            "$log_func" "build_docker_image_in_container: Docker image $image_tag built successfully in container $lxc_id"
            echo "Docker image build completed for $image_tag in container $lxc_id."
            return 0
        else
            # Use log_warn if available, otherwise fallback
            local warn_func="log_warn"
            if ! declare -F log_warn >/dev/null 2>&1; then
                warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
            fi
            "$warn_func" "build_docker_image_in_container: Docker image build failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    "$error_func" "build_docker_image_in_container: Failed to build Docker image $image_tag in container $lxc_id after $max_attempts attempts"
    return 1
}


# --- Docker Runtime Configuration ---

# Configure the NVIDIA runtime for Docker inside an LXC container
# Usage: configure_docker_nvidia_runtime <container_id>
configure_docker_nvidia_runtime() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    "$log_func" "configure_docker_nvidia_runtime: Configuring NVIDIA runtime for Docker in container $lxc_id..."
    echo "Configuring NVIDIA runtime for Docker in container $lxc_id... This may take a moment."

    local config_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[INFO] NVIDIA runtime already configured.'
    exit 0
fi
exit 1"

    # Check if NVIDIA runtime is already configured
    # Note: HYPERVISOR_LOGFILE is assumed from config, fallback to /dev/null if not set
    local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
    if pct exec "$lxc_id" -- bash -c "$config_cmd" 2>&1 | tee -a "$log_file"; then
        "$log_func" "configure_docker_nvidia_runtime: NVIDIA runtime already configured in container $lxc_id."
        return 0
    fi

    local configure_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
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
fi"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "configure_docker_nvidia_runtime: Attempting NVIDIA runtime configuration (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$configure_cmd" 2>&1 | tee -a "$log_file"; then
            "$log_func" "configure_docker_nvidia_runtime: NVIDIA runtime configured successfully in container $lxc_id"
            echo "NVIDIA runtime configuration completed for container $lxc_id."
            return 0
        else
            # Use log_warn if available, otherwise fallback
            local warn_func="log_warn"
            if ! declare -F log_warn >/dev/null 2>&1; then
                warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
            fi
            "$warn_func" "configure_docker_nvidia_runtime: NVIDIA runtime configuration failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    "$error_func" "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id after $max_attempts attempts"
    return 1
}


# --- Docker Validation ---

# Verify basic Docker GPU access inside an LXC container by running a simple CUDA container
# Usage: verify_docker_gpu_access_in_container <container_id> [cuda_image_tag]
verify_docker_gpu_access_in_container() {
    local lxc_id="$1"
    local cuda_image_tag="${2:-nvidia/cuda:12.4.1-base-ubuntu22.04}" # Default fallback image

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "verify_docker_gpu_access_in_container: Container ID cannot be empty"
        return 1
    fi

    "$log_func" "verify_docker_gpu_access_in_container: Verifying Docker GPU access in container $lxc_id using image $cuda_image_tag..."

    local docker_check="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
if ! docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[ERROR] NVIDIA runtime not configured in Docker.'
    exit 1
fi
echo '[INFO] Testing Docker GPU access with nvidia-smi...'
if docker run --rm --gpus all --runtime=nvidia $cuda_image_tag nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] Docker GPU access verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed in container $lxc_id.'
    exit 1
fi"

    # Note: HYPERVISOR_LOGFILE is assumed from config, fallback to /dev/null if not set
    local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
    if pct exec "$lxc_id" -- bash -c "$docker_check" 2>&1 | tee -a "$log_file"; then
        "$log_func" "verify_docker_gpu_access_in_container: Docker GPU access verified successfully in container $lxc_id"
        return 0
    else
        "$warn_func" "verify_docker_gpu_access_in_container: Docker GPU access verification failed in container $lxc_id"
        return 1
    fi
}


echo "[INFO] phoenix_hypervisor_lxc_common_docker.sh: Library loaded successfully."
