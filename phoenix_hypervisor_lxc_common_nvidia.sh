#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh)
# Version: 1.7.4
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

    log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Installing/checking NVIDIA driver version $nvidia_driver_version in container $lxc_id..."

    # Check if drivers are already installed and match the version
    # Use the detect function
    if detect_gpus_in_container "$lxc_id"; then
        local existing_version
        existing_version=$(pct exec "$lxc_id" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ' | head -n 1)
        if [[ "$existing_version" == "$nvidia_driver_version" ]]; then
            log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Compatible NVIDIA driver ($existing_version) already installed in container $lxc_id."
            return 0
        else
            log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA driver version mismatch in container $lxc_id (expected $nvidia_driver_version, found $existing_version). Reinstalling..."
            # Fall through to installation
        fi
    else
         log_info "phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA drivers not found or not working in container $lxc_id. Proceeding with installation."
    fi

    # Proceed with installation
    local runfile_name="NVIDIA-Linux-x86_64-$nvidia_driver_version.run"

    local install_cmd="
        set -e
        cd /tmp
        export DEBIAN_FRONTEND=noninteractive
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

    if [[ $exit_code -ne 0 ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: Failed to install NVIDIA drivers in container $lxc_id. Output: $output"
        return 1
    else
        # Parse the driver version from the successful output
        local installed_version
        installed_version=$(echo "$output" | grep "\[SUCCESS\]" -A 1 | tail -n 1)
        if [[ -n "$installed_version" ]]; then
             log_info "phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA driver version $installed_version installed successfully in container $lxc_id."
        else
             # Fallback if parsing fails
             log_info "phoenix_hypervisor_lxc_common_nvidia.sh: NVIDIA driver installation completed (exit code 0) in container $lxc_id. Verifying..."
             if detect_gpus_in_container "$lxc_id"; then
                 local final_version
                 final_version=$(pct exec "$lxc_id" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ' | head -n 1)
                 log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Verified NVIDIA driver version $final_version in container $lxc_id."
             else
                 log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: Driver installation command succeeded, but GPU access could not be verified in container $lxc_id."
                 return 1
             fi
        fi
    fi
    return 0
}

# - Verify GPU Access Inside Container -
# This function checks if GPUs are accessible *inside* a running container
# It uses nvidia-smi to query GPUs
detect_gpus_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: detect_gpus_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Detecting NVIDIA GPUs inside container $lxc_id..."

    # Check if nvidia-smi is available and can query GPUs
    local check_cmd="
        if command -v nvidia-smi >/dev/null 2>&1; then
            # Try a simple query
            nvidia-smi --query-gpu=count --format=csv,noheader,nounits > /dev/null 2>&1
            if [[ \$? -eq 0 ]]; then
                # Query successful, get count
                count=\$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
                if [[ -n \"\$count\" ]] && [[ \"\$count\" -ge 1 ]]; then
                    echo \"[DETECTED] Found \$count NVIDIA GPU(s) accessible in container $lxc_id.\"
                    exit 0
                else
                    echo \"[WARNING] nvidia-smi available but reported 0 GPUs in container $lxc_id.\"
                    exit 1
                fi
            else
                echo \"[ERROR] nvidia-smi command failed inside container $lxc_id.\"
                exit 1
            fi
        else
            echo \"[ERROR] nvidia-smi not found inside container $lxc_id.\"
            exit 1
        fi
    "

    local result
    result=$(pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_info "phoenix_hypervisor_lxc_common_nvidia.sh: $result"
        return 0
    else
        log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: GPU detection failed in container $lxc_id. Output: $result"
        return 1
    fi
}

# - Verify LXC GPU Access Inside Container (Renamed for Clarity) -
# This function was named configure_lxc_gpu_passthrough in the original upload.
# It seems to verify driver status inside the container, not modify the LXC host config.
# Renaming to clarify its purpose and avoid conflict with the function in common.sh.
# This function essentially wraps detect_gpus_in_container for a specific use case context.
verify_lxc_gpu_access_in_container() {
    local lxc_id="$1"
    local gpu_indices="$2" # Not actively used in the provided logic, but kept for signature consistency

    if [[ -z "$lxc_id" ]]; then
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: verify_lxc_gpu_access_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Verifying GPU access/passthrough for container $lxc_id..."

    # The core logic from the original upload's configure_lxc_gpu_passthrough function
    # seems to be about checking driver status inside the container.
    # We'll delegate the detection part to detect_gpus_in_container.

    if detect_gpus_in_container "$lxc_id"; then
        log_info "phoenix_hypervisor_lxc_common_nvidia.sh: GPU access verified successfully for container $lxc_id."
        return 0
    else
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: Failed to verify GPU access for container $lxc_id."
        return 1
    fi
}

# --- Raw LXC Configuration Modification ---
# The original upload contained direct 'echo' commands to modify /etc/pve/lxc/$lxc_id.conf.
# This logic is powerful but bypasses structured configuration.
# It's kept here as a separate function, assuming it's needed for a specific type of setup.
# WARNING: Using this requires extreme care to avoid conflicts with phoenix_hypervisor_common.sh's configure_lxc_gpu_passthrough.

# configure_lxc_for_full_gpu_passthrough_raw() {
#     local lxc_id="$1"
#     local gpu_indices="$2" # e.g., "0", "1", "0,1"
#
#     if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
#         log_error "phoenix_hypervisor_lxc_common_nvidia.sh: configure_lxc_for_full_gpu_passthrough_raw: Missing lxc_id or gpu_indices"
#         return 1
#     fi
#
#     log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: Using raw LXC config modification. Ensure no conflicts with other GPU setup methods."
#     local config_file="/etc/pve/lxc/$lxc_id.conf"
#
#     if [[ ! -f "$config_file" ]]; then
#         log_error "phoenix_hypervisor_lxc_common_nvidia.sh: LXC config file not found: $config_file"
#         return 1
#     fi
#
#     # Remove existing potentially conflicting entries
#     # (Add specific patterns if needed)
#     # sed -i '/pattern/d' "$config_file"
#
#     # Add cgroup and mount entries for each GPU index
#     IFS=',' read -ra INDICES <<< "$gpu_indices"
#     for index in "${INDICES[@]}"; do
#         # Validate index is numeric?
#         echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$config_file"
#         echo "lxc.cgroup2.devices.allow: c 235:* rwm" >> "$config_file"
#         echo "lxc.cgroup2.devices.allow: c 236:$index rwm" >> "$config_file"
#         echo "lxc.cgroup2.devices.allow: c 237:$index rwm" >> "$config_file"
#         echo "lxc.mount.entry: /dev/nvidia$index dev/nvidia$index none bind,optional,create=file" >> "$config_file"
#     done
#     # Add common entries
#     echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file" >> "$config_file"
#     echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file" >> "$config_file"
#     echo "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file" >> "$config_file"
#     echo "lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file" >> "$config_file"
#
#     log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Raw GPU passthrough entries added to $config_file for indices: $gpu_indices"
#     return 0
# }

# Signal that this library has been loaded (optional, good practice)
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."
