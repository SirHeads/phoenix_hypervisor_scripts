#!/bin/bash
# Phoenix Hypervisor LXC Creation Script
# Creates LXC containers (e.g., drdevstral) based on configurations in /usr/local/etc/phoenix_lxc_configs.json.
# Ensures each LXC has a corresponding setup script in LXC_SETUP_SCRIPTS.
# Configures GPU passthrough, networking, and storage.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - /usr/local/etc/phoenix_lxc_configs.json configured with required fields
# Usage: ./phoenix_hypervisor_create_lxc.sh
# Version: 1.6.9 (Removed defaults, added password support)

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

log "INFO" "$0: Starting phoenix_hypervisor_create_lxc.sh"

# --- Function: create_lxc_container ---
# Description: Creates a single LXC container based on provided configuration.
# Parameters: lxc_id, config (delimited string from LXC_CONFIGS)
# Returns: Exits with status 1 on failure
create_lxc_container() {
    local lxc_id="$1"
    local config="$2"
    local marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_created.marker"

    if is_script_completed "$marker_file"; then
        log "INFO" "$0: LXC $lxc_id already created. Skipping."
        return 0
    fi

    # Validate setup script existence
    if [[ -z "${LXC_SETUP_SCRIPTS[$lxc_id]}" ]]; then
        log "ERROR" "$0: No setup script defined for LXC $lxc_id in LXC_SETUP_SCRIPTS"
        return 1
    fi
    local setup_script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
    if [[ ! -x "$setup_script" ]]; then
        log "ERROR" "$0: Setup script for LXC $lxc_id is not executable: $setup_script"
        return 1
    fi
    log "DEBUG" "$0: Valid setup script for LXC $lxc_id: $setup_script"

    # Parse config
    IFS='|' read -r name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type <<< "$config"

    log "DEBUG" "$0: Creating LXC $lxc_id with config: name=$name, memory_mb=$memory_mb, cores=$cores, storage_pool=$storage_pool, gpu_assignment=$gpu_assignment"

    # Validate required fields
    local required_fields=("name" "memory_mb" "cores" "template" "storage_pool" "storage_size_gb" "network_config" "features")
    for field in "${required_fields[@]}"; do
        if [[ -z "${!field}" ]]; then
            log "ERROR" "$0: Missing required field '$field' for LXC $lxc_id"
            return 1
        fi
    done

    # Validate storage pool
    if ! pvesm status | grep -q "^$storage_pool.*active.*1"; then
        log "ERROR" "$0: Storage pool $storage_pool is not active for LXC $lxc_id"
        pvesm status | while read -r line; do log "DEBUG" "$0: pvesm: $line"; done
        return 1
    fi

    if [[ "$storage_pool" == "lxc-disks" ]]; then
        if ! validate_zfs_pool "quickOS/lxc-disks"; then
            log "ERROR" "$0: ZFS pool validation failed for quickOS/lxc-disks for LXC $lxc_id"
            return 1
        fi
    fi

    # Parse network configuration
    IFS=',' read -r ip_cidr gateway dns <<< "$network_config"
    if [[ -z "$ip_cidr" ]] || [[ -z "$gateway" ]]; then
        log "ERROR" "$0: Invalid network configuration for LXC $lxc_id: $network_config"
        return 1
    fi

    # Construct pct create command
    local pct_cmd="pct create $lxc_id \"$template\" \
        -cores $cores \
        -memory $memory_mb \
        -hostname \"$name\" \
        -storage $storage_pool \
        -rootfs $storage_pool:$storage_size_gb \
        -net0 name=eth0,bridge=vmbr0,ip=$ip_cidr,gw=$gateway \
        -features $features"
    
    if [[ -n "${LXC_ROOT_PASSWORD:-}" ]]; then
        pct_cmd="$pct_cmd -password \"$LXC_ROOT_PASSWORD\""
    fi

    log "DEBUG" "$0: Executing pct create command: $pct_cmd"

    # Create LXC container
    if ! retry_command "$pct_cmd"; then
        log "ERROR" "$0: Failed to create LXC $lxc_id"
        return 1
    fi

    # Configure GPU passthrough
    if [[ -n "$gpu_assignment" ]]; then
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log "ERROR" "$0: Failed to configure GPU passthrough for LXC $lxc_id"
            return 1
        fi
    fi

    # Start the container
    log "INFO" "$0: Starting LXC $lxc_id..."
    if ! retry_command "pct start $lxc_id"; then
        log "ERROR" "$0: Failed to start LXC $lxc_id"
        return 1
    fi

    # Wait for the container to be running
    if ! wait_for_lxc_running "$lxc_id"; then
        log "ERROR" "$0: LXC $lxc_id failed to reach running state"
        return 1
    fi

    # Wait for networking
    if ! wait_for_lxc_network "$lxc_id"; then
        log "ERROR" "$0: Networking failed to become available for LXC $lxc_id"
        return 1
    fi

    # Mark container creation as complete
    mark_script_completed "$marker_file"
    log "INFO" "$0: LXC $lxc_id ($name) created and started successfully"
}

# --- Main execution ---
# Re-validate JSON config
validate_json_config "$PHOENIX_LXC_CONFIG_FILE"

# Check if LXC_CONFIGS is populated
if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
    log "ERROR" "$0: No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
    exit 1
fi

# Iterate over LXC configurations
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    create_lxc_container "$lxc_id" "${LXC_CONFIGS[$lxc_id]}"
done

log "INFO" "$0: Completed phoenix_hypervisor_create_lxc.sh successfully"
exit 0