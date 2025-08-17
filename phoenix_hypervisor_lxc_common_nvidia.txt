#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh)
# Version: 1.7.5
# Author: Assistant

# --- Enhanced Sourcing of Dependencies ---
# This script is intended to be sourced, not executed.
# It relies on functions and variables from phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh
# The sourcing script should handle sourcing the main dependencies.
# However, we can add a check to ensure critical dependencies are available if sourced independently (less ideal).

# Check if core common functions are available (basic check)
# Prefer standard locations for dependencies
if ! declare -f log_info > /dev/null 2>&1; then
    # If not, attempt to source from standard locations
    # Priority: 1. Standard lib location, 2. Standard bin location, 3. Fail
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/bin/phoenix_hypervisor_common.sh
        echo "[WARN] phoenix_hypervisor_lxc_common_nvidia.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    else
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Required function 'log_info' not found and common functions file could not be sourced." >&2
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Please ensure phoenix_hypervisor_common.sh is sourced before sourcing this file." >&2
        return 1 # Use return instead of exit when sourcing
    fi
fi

# --- NVIDIA Functions for LXC Containers ---

# - Install NVIDIA Driver Inside Container -
# This function installs the NVIDIA driver inside a running LXC container
# It checks for existing compatible drivers first
install_nvidia_driver_in_container() {
    local lxc_id="$1"
    local nvidia_driver_version="$2"
    local nvidia_runfile_url="$3"

    if [[ -z "$lxc_id" ]] || [[ -z "$nvidia_driver_version" ]] || [[ -z "$nvidia_runfile_url" ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: install_nvidia_driver_in_container: Missing required arguments (lxc_id, driver_version, runfile_url)"
        return 1
    fi

    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: Installing/checking NVIDIA driver version $nvidia_driver_version in container $lxc_id..."

    # Check if drivers are already installed and match the version
    if detect_gpus_in_container "$lxc_id"; then
        local existing_version
        existing_version=$(pct exec "$lxc_id" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ' | head -n 1)
        if [[ "$existing_version" == "$nvidia_driver_version" ]]; then
            log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: Compatible NVIDIA driver ($existing_version) already installed in container $lxc_id."
            return 0
        else
            log_warn "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA driver version mismatch in container $lxc_id (expected $nvidia_driver_version, found $existing_version). Reinstalling..."
            # Fall through to installation
        fi
    else
        log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA drivers not found or not working in container $lxc_id. Proceeding with installation."
    fi

    # Proceed with installation
    local runfile_name="NVIDIA-Linux-x86_64-$nvidia_driver_version.run"

    local install_cmd="
        set -e
        cd /tmp
        export DEBIAN_FRONTEND=noninteractive
        echo '[INFO] Updating package lists'
        apt-get update -y
        apt-get upgrade -y
        echo '[INFO] Checking network connectivity'
        ping -c 4 8.8.8.8 || { echo '[ERROR] Network connectivity check failed'; exit 1; }
        echo '[INFO] Downloading NVIDIA driver runfile: $runfile_name'
        wget -q -O '$runfile_name' '$nvidia_runfile_url'
        chmod +x '$runfile_name'
        echo '[INFO] Installing NVIDIA driver (userland only) in container $lxc_id...'
        # Run the installer silently, userland only, no kernel modules
        ./'$runfile_name' --silent --no-kernel-module --no-dkms --no-nouveau-check --no-opengl-files
        rm -f '$runfile_name'
        # Verify installation
        if command -v nvidia-smi >/dev/null 2>&1; then
            echo '[SUCCESS] NVIDIA driver installed successfully in container $lxc_id.'
            nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | tr -d ' '
        else
            echo '[ERROR] Failed to install NVIDIA drivers in container $lxc_id.'
            exit 1
        fi
    "

    local output
    output=$(pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1)
    local exit_code=$?

    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: install_nvidia_driver_in_container output: $output"
    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: install_nvidia_driver_in_container exit code: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA driver installed successfully in container $lxc_id"
        return 0
    else
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: Failed to install NVIDIA driver in container $lxc_id. Output: $output"
        return 1
    fi
}

# - Detect GPUs Inside Container -
# Checks if GPUs are accessible inside the container using nvidia-smi
detect_gpus_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: detect_gpus_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: Detecting GPUs in container $lxc_id..."

    local check_cmd="
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
    result=$(pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1)
    local exit_code=$?

    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: detect_gpus_in_container output: $result"
    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: detect_gpus_in_container exit code: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: GPUs detected successfully in container $lxc_id"
        return 0
    else
        log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: GPU detection failed in container $lxc_id. Output: $result"
        return 1
    fi
}

# - Verify LXC GPU Access Inside Container -
# Wraps detect_gpus_in_container to verify GPU driver status
verify_lxc_gpu_access_in_container() {
    local lxc_id="$1"
    local gpu_indices="$2" # Not actively used in the provided logic, but kept for signature consistency

    if [[ -z "$lxc_id" ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: verify_lxc_gpu_access_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: Verifying GPU access/passthrough for container $lxc_id..."

    if detect_gpus_in_container "$lxc_id"; then
        log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: GPU access verified successfully for container $lxc_id."
        return 0
    else
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: Failed to verify GPU access for container $lxc_id."
        return 1
    fi
}

# - Configures GPU passthrough by modifying the LXC config file directly -
# Adds cgroup allowances, mount entries, and swap settings for the specified GPUs
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

    log_info "DEBUG configure_lxc_gpu_passthrough: Adding GPU passthrough entries to $config_file for GPUs: $gpu_indices"

    # Remove any existing GPU-related entries to avoid duplicates
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 195/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 235/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 236/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 237/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: a/d' "$config_file"
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

    log_info "DEBUG configure_lxc_gpu_passthrough: GPU passthrough configured for container $lxc_id (GPUs: $gpu_indices)"
    return 0
}

# Signal that this library has been loaded (optional, good practice)
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "DEBUG phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."