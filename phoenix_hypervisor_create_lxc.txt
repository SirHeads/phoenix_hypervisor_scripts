#!/bin/bash
# phoenix_hypervisor_create_lxc.sh
# Creates LXC containers based on the configuration in phoenix_lxc_configs.json.
# Handles template location, basic configuration.
# Usage: ./phoenix_hypervisor_create_lxc.sh

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config # This loads LXC_CONFIGS and other variables
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "Starting phoenix_hypervisor_create_lxc.sh"

# --- Main Script Logic ---

# Check if LXC_CONFIGS is populated
if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
    log "ERROR" "No LXC configurations found. Ensure phoenix_lxc_configs.json is correctly loaded."
    exit 1
fi

echo "Found LXC configurations to process:"
configured_lxcs=()
for id in "${!LXC_CONFIGS[@]}"; do
    lxc_name=$(echo "${LXC_CONFIGS[$id]}" | cut -d',' -f1)
    echo "  - ID: $id, Name: $lxc_name"
    configured_lxcs+=("$id")
done

# Single confirmation prompt with option to skip specific LXCs
declare -A skip_lxcs
read -p "Enter LXC IDs to skip (comma-separated, e.g., 901,902) or press Enter to create all: " skip_ids
if [[ -n "$skip_ids" ]]; then
    IFS=',' read -ra skip_array <<< "$skip_ids"
    for id in "${skip_array[@]}"; do
        # Basic validation: check if ID was in the config
        if [[ " ${configured_lxcs[*]} " =~ " $id " ]]; then
            skip_lxcs["$id"]=1
            log "INFO" "User requested to skip LXC $id."
        else
            log "WARN" "User entered invalid LXC ID to skip: $id. Ignoring."
        fi
    done
fi

# Process each LXC configuration and create the container
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    if [[ -n "${skip_lxcs[$lxc_id]}" ]]; then
        log "INFO" "Skipping creation of LXC $lxc_id as requested."
        echo "Skipping LXC $lxc_id."
        continue
    fi

    marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_created.marker"
    if is_script_completed "$marker_file"; then
        log "INFO" "Skipping completed LXC creation for $lxc_id."
        continue
    fi

    # Parse configuration values for this LXC
    IFS=',' read -r lxc_name memory_mb balloon_min_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config <<< "${LXC_CONFIGS[$lxc_id]}"

    # --- Modified Template Validation (Use the specific path found) ---
    CUSTOM_TEMPLATE_DIR="/fastData/shared-iso/template/cache"
    TEMPLATE_PATH="$CUSTOM_TEMPLATE_DIR/$template"
    # Validate template existence in the custom directory
    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        log "ERROR" "Template $template not found in $CUSTOM_TEMPLATE_DIR/"
        exit 1
    fi
    # --- End of Template Validation ---

    # Parse network configuration
    network_bridge="vmbr0" # Default bridge
    if [[ "$network_config" == "dhcp" ]]; then
        ip_config="dhcp"
        gateway_config=""
        dns_config=""
        network_description="DHCP"
    else
        IFS=',' read -r ip_cidr gateway_config dns_config <<< "$network_config"
        ip_config="$ip_cidr"
        network_description="$network_config"
    fi

    echo "About to create LXC $lxc_id ($lxc_name) with the following configuration:"
    echo "  - Name: $lxc_name"
    echo "  - Memory: ${memory_mb}MB"
    echo "  - Balloon Min: ${balloon_min_mb}MB"
    echo "  - Cores: $cores"
    echo "  - Template: $template"
    echo "  - Storage Pool: $storage_pool"
    echo "  - Storage Size: ${storage_size_gb}GB"
    echo "  - Network: $network_description"

    log "INFO" "Creating LXC $lxc_id: $lxc_name"

    # --- Create LXC Container ---
    # Build the pct create command with initial options
    create_cmd="pct create $lxc_id $TEMPLATE_PATH -storage $storage_pool -memory $memory_mb -swap 0 -cores $cores -hostname $lxc_name -rootfs $storage_pool:${storage_size_gb}"

    # Handle network configuration in create command
    if [[ "$network_config" == "dhcp" ]]; then
        create_cmd="$create_cmd -net0 name=eth0,bridge=$network_bridge,ip=dhcp"
        log "INFO" "Network config set to DHCP for LXC $lxc_id."
    else
        # Add IP and Gateway to create command for static IP
        if [[ -n "$gateway_config" ]]; then
            create_cmd="$create_cmd -net0 name=eth0,bridge=$network_bridge,ip=$ip_config,gw=$gateway_config"
        else
            create_cmd="$create_cmd -net0 name=eth0,bridge=$network_bridge,ip=$ip_config"
        fi
        log "INFO" "Network config set for LXC $lxc_id: Static IP $ip_config, GW $gateway_config"
    fi

    log "INFO" "Running pct create for LXC $lxc_id (this may take a while)..."
    log "INFO" "Executing: $create_cmd"
    # Use retry_command for better reliability
    if ! retry_command "$create_cmd"; then
        log "ERROR" "Failed to create LXC $lxc_id: $create_cmd"
        exit 1
    fi
    log "INFO" "LXC $lxc_id created successfully."

    # --- Post-Creation Configuration ---
    # Configure DNS if static IP and DNS provided (using pct set)
    if [[ "$network_config" != "dhcp" && -n "$dns_config" ]]; then
        dns_set_cmd="pct set $lxc_id -nameserver $dns_config"
        log "INFO" "Configuring DNS for LXC $lxc_id..."
        log "INFO" "Executing: $dns_set_cmd"
        if ! retry_command "$dns_set_cmd"; then
            log "ERROR" "Failed to configure DNS for LXC $lxc_id: $dns_set_cmd"
            log "WARN" "DNS configuration for LXC $lxc_id might be incomplete."
        else
            log "INFO" "DNS configured for LXC $lxc_id: $dns_config"
        fi
    fi
    # --- End of Post-Creation Configuration ---

    # Mark the script as completed for this container
    mark_script_completed "$marker_file"
    log "INFO" "Marked LXC $lxc_id creation as completed."
done

log "INFO" "Completed phoenix_hypervisor_create_lxc.sh successfully."
exit 0