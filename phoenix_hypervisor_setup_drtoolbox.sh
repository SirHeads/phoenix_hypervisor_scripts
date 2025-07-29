#!/bin/bash

# Phoenix Hypervisor Setup DrToolbox Script

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "Starting phoenix_lxc_setup_drtoolbox.sh for LXC $DRTOOLBOX_LXC_ID"

# Create marker directory if not exists
mkdir -p "$HYPERVISOR_MARKER_DIR"

# Define the marker file path for this script's completion status
marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${DRTOOLBOX_LXC_ID}_setup_drtoolbox.marker"

# Skip if the setup has already been completed (marker file exists)
if is_script_completed "$marker_file"; then
    log "INFO" "DrToolbox LXC $DRTOOLBOX_LXC_ID already set up (marker found). Skipping setup."
    exit 0
fi

# Function to install Docker in an LXC container
install_docker_in_lxc() {
    local lxc_id="$1"

    log "INFO" "Setting up DrToolbox LXC $lxc_id with Docker..."

    # Ensure the LXC is running before attempting setup
    execute_in_lxc "$lxc_id" "systemctl start networking"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to start networking in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Update package lists and install necessary packages for Docker installation
    execute_in_lxc "$lxc_id" "apt-get update"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to update package lists in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    execute_in_lxc "$lxc_id" "apt-get install -y apt-transport-https ca-certificates curl software-properties-common"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install prerequisites for Docker in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Add Docker GPG key
    execute_in_lxc "$lxc_id" 'curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg'
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to add Docker GPG key in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Add Docker repository
    execute_in_lxc "$lxc_id" 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list'
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to add Docker repository in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Update package lists after adding Docker repo
    execute_in_lxc "$lxc_id" "apt-get update"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to update package lists after adding Docker repository in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install Docker Engine
    execute_in_lxc "$lxc_id" "apt-get install -y docker-ce docker-ce-cli containerd.io"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install Docker Engine in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Enable and start the Docker service within the container
    execute_in_lxc "$lxc_id" "systemctl enable --now docker"
    if [[ $? -ne 0 ]]; then
        log "WARN" "Failed to enable Docker service in LXC $lxc_id (might not be critical)."
    fi

    # Test Docker installation by running a simple container
    log "INFO" "Running Docker Hello World test in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "docker run --rm hello-world"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Docker Hello World test failed in LXC $lxc_id. Docker setup might be incomplete."
        exit 1
    else
        log "INFO" "Docker Hello World test successful in LXC $lxc_id."
    fi

    # Mark the completion of DrToolbox setup for this container
    mark_script_completed "$marker_file"
}

# Install Docker in the specified DrToolbox LXC container
install_docker_in_lxc "$DRTOOLBOX_LXC_ID"

log "INFO" "Completed phoenix_lxc_setup_drtoolbox.sh successfully for LXC $DRTOOLBOX_LXC_ID."
exit 0