#!/bin/bash
# Phoenix Hypervisor LXC Creation Script
# Creates a single LXC container based on provided arguments.
# Configures GPU passthrough, networking, and storage.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - /usr/local/etc/phoenix_lxc_configs.json configured with required fields
# - NVIDIA GPU(s) validated on the host
# Usage: ./phoenix_hypervisor_create_lxc.sh <lxc_id> <template> <storage_pool> <storage_size_gb> <memory_mb> <cores> <hostname> <network_config> <gpu_enabled>
# Version: 1.7.3
# Author: Assistant
set -euo pipefail

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check root privileges
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Checking root privileges..." >&2
check_root
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Root check passed." >&2

# Log start of script
log "INFO" "$0: Starting phoenix_hypervisor_create_lxc.sh"

# --- Function: create_lxc_container ---
# Description: Creates a single LXC container based on provided arguments.
# Parameters: lxc_id, template, storage_pool, storage_size_gb, memory_mb, cores, hostname, network_config, gpu_enabled
# Returns: Exits with status 1 on failure
create_lxc_container() {
    local lxc_id="$1"
    local template="$2"
    local storage_pool="$3"
    local storage_size_gb="$4"
    local memory_mb="$5"
    local cores="$6"
    local hostname="$7"
    local network_config="$8"
    local gpu_enabled="$9"
    local marker_file="${PHOENIX_HYPERVISOR_LXC_MARKER/lxc_id/$lxc_id}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Processing LXC $lxc_id..." >&2

    if is_script_completed "$marker_file"; then
        log "INFO" "$0: LXC $lxc_id already created. Skipping."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $lxc_id already created. Skipping." >&2
        return 0
    fi

    # Validate LXC ID format
    if ! validate_lxc_id "$lxc_id"; then
        log "ERROR" "$0: Invalid LXC ID format: '$lxc_id'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid LXC ID format: '$lxc_id'." >&2
        return 1
    fi

    # Validate template file
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Validating template file $template..." >&2
    if [[ ! -f "$template" ]]; then
        log "ERROR" "$0: Template file not found: $template"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Template file not found: $template." >&2
        return 1
    fi

    # Validate required fields
    local required_fields=("template" "storage_pool" "storage_size_gb" "memory_mb" "cores" "hostname" "network_config")
    for field in "${required_fields[@]}"; do
        if [[ -z "${!field}" ]]; then
            log "ERROR" "$0: Missing required field '$field' for LXC $lxc_id"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Missing required field '$field' for LXC $lxc_id." >&2
            return 1
        fi
        local sanitized_value
        sanitized_value=$(sanitize_input "${!field}")
        if [[ "$sanitized_value" != "${!field}" ]]; then
            if [[ "$field" == "hostname" ]]; then
                log "ERROR" "$0: Hostname '$hostname' for LXC $lxc_id contains invalid characters."
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Hostname '$hostname' for LXC $lxc_id contains invalid characters." >&2
                return 1
            fi
        fi
    done

    # Validate numeric fields
    if ! validate_numeric "$memory_mb"; then
        log "ERROR" "$0: Invalid memory_mb value for LXC $lxc_id: '$memory_mb'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid memory_mb value for LXC $lxc_id: '$memory_mb'." >&2
        return 1
    fi
    if ! validate_numeric "$cores"; then
        log "ERROR" "$0: Invalid cores value for LXC $lxc_id: '$cores'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid cores value for LXC $lxc_id: '$cores'." >&2
        return 1
    fi
    if ! validate_numeric "$storage_size_gb"; then
        log "ERROR" "$0: Invalid storage_size_gb value for LXC $lxc_id: '$storage_size_gb'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid storage_size_gb value for LXC $lxc_id: '$storage_size_gb'." >&2
        return 1
    fi

    # Validate storage pool
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Validating storage pool $storage_pool..." >&2
    if ! pvesm status | grep -q "^$storage_pool.*active.*1"; then
        log "ERROR" "$0: Storage pool $storage_pool is not active for LXC $lxc_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Storage pool $storage_pool is not active for LXC $lxc_id." >&2
        pvesm status | while read -r line; do log "DEBUG" "$0: pvesm: $line"; done
        return 1
    fi
    if [[ "$storage_pool" == "lxc-disks" ]]; then
        local zfs_pool_name_to_check="${PHOENIX_ZFS_LXC_POOL:-quickOS/lxc-disks}"
        if ! validate_zfs_pool "$zfs_pool_name_to_check"; then
            log "ERROR" "$0: ZFS pool validation failed for $zfs_pool_name_to_check for LXC $lxc_id"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] ZFS pool validation failed for $zfs_pool_name_to_check." >&2
            return 1
        fi
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Storage pool validated." >&2

    # Parse network configuration and validate
    IFS=',' read -r ip_cidr gateway dns <<< "$network_config"
    if [[ -z "$ip_cidr" ]] || [[ -z "$gateway" ]]; then
        log "ERROR" "$0: Invalid network configuration for LXC $lxc_id: $network_config"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid network configuration for LXC $lxc_id: $network_config." >&2
        return 1
    fi
    if ! validate_network_cidr "$ip_cidr"; then
        log "ERROR" "$0: Invalid IP CIDR format for LXC $lxc_id: '$ip_cidr'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid IP CIDR format for LXC $lxc_id: '$ip_cidr'." >&2
        return 1
    fi
    if ! validate_network_cidr "$gateway"; then
        log "WARN" "$0: Gateway '$gateway' for LXC $lxc_id might not be in standard CIDR format."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Gateway '$gateway' for LXC $lxc_id might not be in standard CIDR format." >&2
    fi
    if [[ -n "$dns" ]] && ! validate_network_cidr "$dns"; then
        log "WARN" "$0: DNS '$dns' for LXC $lxc_id might not be in standard IP format."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] DNS '$dns' for LXC $lxc_id might not be in standard IP format." >&2
    fi

    # Check for LXC_ROOT_PASSWORD in non-interactive environment
    if [[ ! -t 0 ]] && [[ -z "${LXC_ROOT_PASSWORD:-}" ]]; then
        log "ERROR" "$0: Non-interactive environment detected and no LXC_ROOT_PASSWORD provided for LXC $lxc_id."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Non-interactive environment detected and no LXC_ROOT_PASSWORD provided for LXC $lxc_id." >&2
        return 1
    fi

    # Construct pct create command
    local features="${DEFAULT_LXC_FEATURES:-nesting=1}"
    local pct_cmd="pct create $lxc_id \"$template\" \
        -cores $cores \
        -memory $memory_mb \
        -hostname \"$hostname\" \
        -storage $storage_pool \
        -rootfs $storage_pool:$storage_size_gb \
        -net0 name=eth0,bridge=vmbr0,ip=$ip_cidr,gw=$gateway \
        -features \"$features\""
    if [[ -n "${LXC_ROOT_PASSWORD:-}" ]]; then
        pct_cmd="$pct_cmd -password \"$LXC_ROOT_PASSWORD\""
    fi
    log "DEBUG" "$0: Executing pct create command: $pct_cmd"

    # Create LXC container
    if ! retry_command "$pct_cmd" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct create: $line" >&2; done; then
        log "ERROR" "$0: Failed to create LXC $lxc_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to create LXC $lxc_id." >&2
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
            else
                log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
            fi
        fi
        return 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $lxc_id created." >&2

    # Configure GPU passthrough
    if [[ "$gpu_enabled" == "true" ]]; then
        local gpu_assignment="${PHOENIX_GPU_ASSIGNMENTS[$lxc_id]}"
        if [[ -z "$gpu_assignment" ]]; then
            log "ERROR" "$0: GPU enabled for LXC $lxc_id but no assignment found in PHOENIX_GPU_ASSIGNMENTS."
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] GPU enabled for LXC $lxc_id but no assignment found in PHOENIX_GPU_ASSIGNMENTS." >&2
            if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                    log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
                else
                    log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
                fi
            fi
            return 1
        fi
        log "INFO" "$0: Found GPU assignment '$gpu_assignment' for LXC $lxc_id from PHOENIX_GPU_ASSIGNMENTS."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Validating GPU assignment for LXC $lxc_id..." >&2
        if ! detect_gpu_details "$gpu_assignment"; then
            log "ERROR" "$0: Failed to validate GPU details for assignment: $gpu_assignment"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to validate GPU details for assignment: $gpu_assignment." >&2
            if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                    log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
                else
                    log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
                fi
            fi
            return 1
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Configuring GPU passthrough for LXC $lxc_id..." >&2
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log "ERROR" "$0: Failed to configure GPU passthrough for LXC $lxc_id"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to configure GPU passthrough for LXC $lxc_id." >&2
            if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                    log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
                else
                    log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
                fi
            fi
            return 1
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] GPU passthrough configured for LXC $lxc_id." >&2
    fi

    # Start the container
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Starting LXC $lxc_id..." >&2
    log "INFO" "$0: Starting LXC $lxc_id..."
    if ! retry_command "pct start $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct start: $line" >&2; done; then
        log "ERROR" "$0: Failed to start LXC $lxc_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to start LXC $lxc_id." >&2
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
            else
                log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
            fi
        fi
        return 1
    fi

    # Wait for the container to be running
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Waiting for LXC $lxc_id to start..." >&2
    if ! wait_for_lxc_running "$lxc_id"; then
        log "ERROR" "$0: LXC $lxc_id failed to reach running state"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LXC $lxc_id failed to reach running state." >&2
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
            else
                log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
            fi
        fi
        return 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $lxc_id is running." >&2

    # Wait for networking
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Waiting for LXC $lxc_id network..." >&2
    if ! wait_for_lxc_network "$lxc_id"; then
        log "ERROR" "$0: Networking failed to become available for LXC $lxc_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Networking failed to become available for LXC $lxc_id." >&2
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            if ! retry_command "pct destroy $lxc_id" 2>&1 | while read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [DEBUG] pct destroy: $line" >&2; done; then
                log "WARN" "$0: Failed to rollback by destroying LXC $lxc_id"
            else
                log "INFO" "$0: Rolled back by destroying LXC $lxc_id"
            fi
        fi
        return 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $lxc_id network is available." >&2

    # Mark container creation as complete
    mark_script_completed "$marker_file"
    log "INFO" "$0: LXC $lxc_id ($hostname) created and started successfully"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC $lxc_id ($hostname) created and started successfully." >&2
}

# --- Main execution ---
if [[ $# -ne 9 ]]; then
    log "ERROR" "$0: Incorrect number of arguments. Expected 9, got $#"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Usage: $0 <lxc_id> <template> <storage_pool> <storage_size_gb> <memory_mb> <cores> <hostname> <network_config> <gpu_enabled>" >&2
    exit 1
fi

lxc_id="$1"
template="$2"
storage_pool="$3"
storage_size_gb="$4"
memory_mb="$5"
cores="$6"
hostname="$7"
network_config="$8"
gpu_enabled="$9"

create_lxc_container "$lxc_id" "$template" "$storage_pool" "$storage_size_gb" "$memory_mb" "$cores" "$hostname" "$network_config" "$gpu_enabled"

log "INFO" "$0: Completed phoenix_hypervisor_create_lxc.sh successfully"
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Phoenix Hypervisor LXC creation completed successfully." >&2
exit 0