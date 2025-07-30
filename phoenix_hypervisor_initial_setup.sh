#!/bin/bash

# Phoenix Hypervisor Initial Setup Script
# Performs initial setup of the Proxmox host, including system updates, LXC tools installation, and Proxmox-specific checks.
# Prerequisites:
# - Proxmox VE 7.0 or higher
# - Internet access for package downloads
# - Root privileges
# Usage: ./phoenix_hypervisor_initial_setup.sh

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "Starting phoenix_hypervisor_initial_setup.sh"

# Validate Proxmox version and kernel
log "INFO" "Checking Proxmox version and kernel compatibility..."
if ! pveversion | grep -q "pve-manager/[7-8]\."; then
    log "ERROR" "Proxmox VE 7.0 or higher required"
    exit 1
fi
kernel_version=$(uname -r)
if [[ ! "$kernel_version" =~ ^[5-6]\. ]]; then
    log "ERROR" "Kernel version 5.x or 6.x required for Proxmox VE compatibility"
    exit 1
fi
log "INFO" "Proxmox version and kernel check passed"

# Ensure the system is updated
log "INFO" "Performing system update and upgrade (this may take a while)..."
retry_command "apt-get update" || { log "ERROR" "Failed to update package lists"; exit 1; }
retry_command "apt-get dist-upgrade -y" || { log "ERROR" "Failed to upgrade system"; exit 1; }

# Refresh Proxmox boot tool if needed
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    retry_command "proxmox-boot-tool refresh" || { log "WARN" "Failed to refresh proxmox-boot-tool (might not be critical)"; }
fi

retry_command "update-initramfs -u" || { log "ERROR" "Failed to update initramfs"; exit 1; }

# Install/Update LXC Tools with version pinning
log "INFO" "Installing/Updating LXC tools with version pinning..."
retry_command "apt-get install -y lxc-pve" || { log "ERROR" "Failed to install/update LXC tools"; exit 1; }

# Mark the script as completed
mark_script_completed "${HYPERVISOR_MARKER_DIR}/initial_setup.marker"

log "INFO" "Completed phoenix_hypervisor_initial_setup.sh successfully."
exit 0