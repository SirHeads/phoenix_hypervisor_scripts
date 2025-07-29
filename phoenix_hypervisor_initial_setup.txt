#!/bin/bash

# Phoenix Hypervisor Initial Setup Script

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

# Ensure the system is updated
log "INFO" "Performing system update and upgrade (this may take a while)..."
retry_command "apt-get update" || { log "ERROR" "Failed to update package lists"; exit 1; }
retry_command "apt-get dist-upgrade -y" || { log "ERROR" "Failed to upgrade system"; exit 1; }

# Refresh Proxmox boot tool if needed
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    retry_command "proxmox-boot-tool refresh" || { log "WARN" "Failed to refresh proxmox-boot-tool (might not be critical)"; }
fi

retry_command "update-initramfs -u" || { log "ERROR" "Failed to update initramfs"; exit 1; }

# Install/Update LXC Tools
log "INFO" "Installing/Updating LXC tools..."
retry_command "apt-get install -y lxc lxc-templates" || { log "ERROR" "Failed to install/update LXC tools"; exit 1; }

# Optional Docker Engine installation
if ! command -v docker >/dev/null 2>&1; then
    log "INFO" "Installing Docker Engine on the host..."
    retry_command "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg" || { log "ERROR" "Failed to add Docker GPG key"; exit 1; }
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    retry_command "apt-get update" || { log "ERROR" "Failed to update package lists after adding Docker repo"; exit 1; }
    retry_command "apt-get install -y docker-ce docker-ce-cli containerd.io" || { log "ERROR" "Failed to install Docker Engine"; exit 1; }

    # Enable and start Docker service
    retry_command "systemctl enable --now docker" || { log "WARN" "Failed to enable Docker service (might not be critical)"; }
fi

# Mark the script as completed
mark_script_completed "${HYPERVISOR_MARKER_DIR}/initial_setup.marker"

log "INFO" "Completed phoenix_hypervisor_initial_setup.sh successfully."
exit 0