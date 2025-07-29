#!/bin/bash

# Phoenix Hypervisor Create LXC Script

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "Starting phoenix_create_lxc.sh"

# Create marker directory
mkdir -p "$HYPERVISOR_MARKER_DIR"

# List all LXC configurations to process
echo "Found LXC configurations to process:"
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    config_string="${LXC_CONFIGS[$lxc_id]}"
    IFS=',' read -r lxc_name memory_mb balloon_min_mb cores template storage_pool storage_size_gb nvidia_pci_ids ip_address_cidr gateway dns_server <<< "$config_string"
    echo "  - ID: $lxc_id, Name: $lxc_name"
done

# Confirm with the user before proceeding
read -p "Do you want to proceed with creating these LXCs? (y/N): " confirm_all
if [[ ! "$confirm_all" =~ ^[Yy]$ ]]; then
    log "INFO" "User cancelled LXC creation process."
    echo "LXC creation cancelled."
    exit 0
fi

# Process each LXC configuration and create the container
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_created.marker"
    if is_script_completed "$marker_file"; then
        log "INFO" "Skipping completed LXC creation for $lxc_id."
        continue
    fi

    config_string="${LXC_CONFIGS[$lxc_id]}"
    IFS=',' read -r lxc_name memory_mb balloon_min_mb cores template storage_pool storage_size_gb nvidia_pci_ids ip_address_cidr gateway dns_server <<< "$config_string"

    echo "About to create LXC $lxc_id ($lxc_name) with the following configuration:"
    echo "  - Name: $lxc_name"
    echo "  - Memory: ${memory_mb}MB"
    echo "  - Balloon Min: ${balloon_min_mb}MB"
    echo "  - Cores: $cores"
    echo "  - Template: $template"
    echo "  - Storage Pool: $storage_pool"
    echo "  - Storage Size: ${storage_size_gb}GB"
    echo "  - NVIDIA PCI IDs: $nvidia_pci_ids"
    echo "  - Network: IP=$ip_address_cidr, GW=$gateway, DNS=$dns_server"

    # Confirm creation for this specific LXC
    read -p "Proceed with creating LXC $lxc_id? (y/N): " confirm_single
    if [[ ! "$confirm_single" =~ ^[Yy]$ ]]; then
        log "INFO" "User skipped creation of LXC $lxc_id."
        echo "Skipping LXC $lxc_id."
        mark_script_completed "$marker_file"
        continue
    fi

    # Ensure storage exists in Proxmox
    if ! pvesm status | grep -q "^$storage_pool "; then
        log "ERROR" "Storage '$storage_pool' does not exist in Proxmox. Please create it first."
        exit 1
    fi

    log "INFO" "Creating LXC $lxc_id: $lxc_name"

    # Basic LXC Creation Command
    create_cmd="pct create $lxc_id /var/lib/vz/template/cache/$template"
    create_cmd+=" -hostname $lxc_name"
    create_cmd+=" -memory $memory_mb"
    create_cmd+=" -balloon $balloon_min_mb"
    create_cmd+=" -cores $cores"
    create_cmd+=" -unprivileged 1" # As requested
    create_cmd+=" -onboot 1" # Start on boot by default
    create_cmd+=" -storage $storage_pool" # Use the Proxmox storage ID
    create_cmd+=" -rootfs $storage_size_gb" # Size in GB

    # Execute creation command
    eval "$create_cmd"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Failed to create LXC $lxc_id (Exit code: $exit_code): $create_cmd"
        exit 1
    fi

    # Configure network settings
    net_config_cmd="pct set $lxc_id --net0 name=eth0,ip=$ip_address_cidr,gw=$gateway,dns=$dns_server"
    eval "$net_config_cmd"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to configure network for LXC $lxc_id: $net_config_cmd"
        exit 1
    fi

    # Configure NVIDIA PCI IDs (if specified)
    if [[ -n "$nvidia_pci_ids" ]]; then
        pci_config_cmd="pct set $lxc_id --hostpci$nvidia_pci_ids"
        eval "$pci_config_cmd"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to configure NVIDIA PCI IDs for LXC $lxc_id: $pci_config_cmd"
            exit 1
        fi
    fi

    # Mark the script as completed for this container
    mark_script_completed "$marker_file"
done

log "INFO" "Completed phoenix_create_lxc.sh successfully."