#!/bin/bash
# Phoenix Hypervisor Initial Setup Script
# Performs initial setup of the Proxmox host, including system updates, LXC tools installation, ZFS validation, and NVIDIA driver checks.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Internet access for package downloads
# - Root privileges
# Usage: ./phoenix_hypervisor_initial_setup.sh
# Version: 1.6.8 (Added ZFS/NVIDIA validation, enhanced debugging)

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

log "INFO" "$0: Starting phoenix_hypervisor_initial_setup.sh"

# --- Validate required tools ---
check_required_tools() {
    local required_tools=("jq" "pct" "pveversion" "zfs" "nvidia-smi")
    local missing_tools=()

    log "DEBUG" "$0: Checking required tools: ${required_tools[*]}"
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "$0: Required tools missing: ${missing_tools[*]}"
        log "INFO" "$0: Install them (e.g., 'apt-get install zfsutils-linux nvidia-driver')."
        exit 1
    fi
    log "INFO" "$0: All required tools are installed"
}

# --- Validate Proxmox environment ---
validate_proxmox_environment() {
    log "INFO" "$0: Checking Proxmox version and kernel compatibility..."
    if ! pveversion | grep -q "pve-manager/8\.[0-9]\+\.[0-9]\+"; then
        log "ERROR" "$0: Proxmox VE 8.x required (detected: $(pveversion))"
        exit 1
    fi
    local kernel_version
    kernel_version=$(uname -r)
    if [[ ! "$kernel_version" =~ ^[6-8]\. ]]; then
        log "ERROR" "$0: Kernel version 6.x or higher required (detected: $kernel_version)"
        exit 1
    fi
    log "INFO" "$0: Proxmox version and kernel check passed"
}

# --- Validate NVIDIA drivers ---
validate_nvidia_drivers() {
    log "INFO" "$0: Checking NVIDIA driver functionality..."
    local nvidia_output
    nvidia_output=$(nvidia-smi 2>&1)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "$0: NVIDIA driver check failed: $nvidia_output"
        exit 1
    fi
    log "DEBUG" "$0: nvidia-smi output: $nvidia_output"
    log "INFO" "$0: NVIDIA drivers are functional"
}

# --- Main execution ---
check_required_tools

validate_proxmox_environment

# Validate ZFS pool
validate_zfs_pool "quickOS/lxc-disks"

# Validate NVIDIA drivers
validate_nvidia_drivers

# Ensure the system is updated
log "INFO" "$0: Performing system update and upgrade..."
if ! retry_command "apt-get update"; then
    log "ERROR" "$0: Failed to update package lists"
    exit 1
fi
if ! retry_command "apt-get dist-upgrade -y"; then
    log "ERROR" "$0: Failed to upgrade system"
    exit 1
fi
log "INFO" "$0: System update and upgrade completed"

# Refresh Proxmox boot tool if needed
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    log "DEBUG" "$0: Refreshing proxmox-boot-tool"
    retry_command "proxmox-boot-tool refresh" || { log "WARN" "$0: Failed to refresh proxmox-boot-tool (might not be critical)"; }
fi

# Update initramfs
log "DEBUG" "$0: Updating initramfs"
retry_command "update-initramfs -u" || { log "ERROR" "$0: Failed to update initramfs"; exit 1; }

# Install/Update LXC Tools
log "INFO" "$0: Installing/Updating LXC tools..."
retry_command "apt-get install -y lxc-pve" || { log "ERROR" "$0: Failed to install/update LXC tools"; exit 1; }

# Mark the script as completed
mark_script_completed "${HYPERVISOR_MARKER_DIR}/initial_setup.marker"

log "INFO" "$0: Completed phoenix_hypervisor_initial_setup.sh successfully"
exit 0