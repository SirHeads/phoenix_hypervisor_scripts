#!/bin/bash
# Main script to establish Phoenix Hypervisor
# Creates and configures LXC containers based on phoenix_lxc_configs.json
# Version: 1.7.14 (Added token permissions, resource checks, Portainer validation, QUIET_MODE, assumes install_portainer_agent in phoenix_hypervisor_setup_portainer.sh)
# Author: Assistant
# Integration: Uses phoenix_hypervisor_common.sh (v2.1.2), phoenix_hypervisor_create_lxc.sh (v1.7.9)

set -euo pipefail

# --- Terminal Handling ---
if [[ -t 0 ]]; then
    trap 'stty sane; [[ "$QUIET_MODE" != "true" ]] && echo "Terminal reset"' EXIT
else
    trap '[[ "$QUIET_MODE" != "true" ]] && echo "Terminal reset (non-interactive)"' EXIT
fi

# --- Sourcing Check ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
    source ./phoenix_hypervisor_config.sh
    log_warn "Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh."
else
    log_error "Configuration file not found."
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
else
    log_error "phoenix_hypervisor_common.sh not found."
    exit 1
fi

# --- Quiet Mode Check ---
QUIET_MODE="${QUIET_MODE:-false}"
log_debug "Starting Phoenix Hypervisor setup. QUIET_MODE=$QUIET_MODE"


# --- Validate Environment ---
validate_environment() {
    log_info "Validating environment..."

    # Check and create critical directories
    local required_dirs=(
        "/usr/local/etc"
        "/usr/local/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "$HYPERVISOR_MARKER_DIR"
    )
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Directory '$dir' not found, attempting to create it..."
            if ! mkdir -p "$dir" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Failed to create directory '$dir'. Check permissions."
                exit 1
            fi
            log_info "Directory '$dir' created successfully."
        fi
    done

    # Check token files and permissions
    check_token_permissions() {
        local file="$1"
        if [[ ! -f "$file" ]]; then
            log_error "Critical token file missing: $file"
            exit 1
        fi
        if [[ ! -r "$file" ]]; then
            log_error "Token file not readable: $file"
            exit 1
        fi
        local permissions
        permissions=$(stat -c "%a" "$file")
        if [[ "$permissions" != "600" ]]; then
            log_warn "Insecure permissions on $file ($permissions). Setting to 600."
            chmod 600 "$file" || log_error "Failed to set permissions on $file"
        fi
    }
    local critical_files=(
        "$PHOENIX_HF_TOKEN_FILE"
        "$PHOENIX_DOCKER_TOKEN_FILE"
    )
    for file in "${critical_files[@]}"; do
        check_token_permissions "$file"
    done

    # Check initial setup marker
    if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
        log_info "Marker file '$HYPERVISOR_MARKER' not found. Running initial setup script..."
        local setup_script="/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh"
        if [[ -x "$setup_script" ]]; then
            if ! "$setup_script"; then
                log_error "Initial setup script failed. Check logs at /var/log/phoenix_hypervisor/phoenix_hypervisor_initial_setup.log."
                exit 1
            fi
        else
            log_error "Initial setup script not found at $setup_script."
            exit 1
        fi
        if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
            log_error "Initial setup completed but marker file '$HYPERVISOR_MARKER' not found."
            exit 1
        fi
    fi

    # Other environment checks
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not installed."
        exit 1
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "pct not installed."
        exit 1
    fi
    if ! systemctl is-active --quiet apparmor; then
        log_error "apparmor service not active."
        exit 1
    fi
    if ! zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>&1; then
        log_error "ZFS pool $PHOENIX_ZFS_LXC_POOL not found."
        exit 1
    fi
    if ! nvidia-smi >/dev/null 2>&1; then
        log_error "NVIDIA GPUs not detected."
        exit 1
    fi
    if [[ -e /proc/self/fd/4 ]]; then
        jq_stderr_redirect="2>&4"
    else
        log_warn "File descriptor 4 (debug log) not available during validation. jq errors will go to stderr."
    fi
    if ! eval "jq -e . \"\$PHOENIX_LXC_CONFIG_FILE\" >/dev/null $jq_stderr_redirect"; then
        log_error "Invalid JSON in $PHOENIX_LXC_CONFIG_FILE."
        exit 1
    fi

    log_info "Environment validated successfully."
}

# --- Create Containers with Priority ---
create_containers() {
    log_info "Creating LXC containers from $PHOENIX_LXC_CONFIG_FILE with priority..."

    # Load LXC configurations
    if ! load_hypervisor_config; then
        log_error "Failed to load hypervisor configuration."
        exit 1
    fi

    # Check Proxmox resources
    check_proxmox_resources() {
        local id="$1"
        local memory_mb cores storage_size_gb
        memory_mb=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.memory_mb')
        cores=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.cores')
        storage_size_gb=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.storage_size_gb')
        log_info "Checking resources for container $id (memory: $memory_mb MB, cores: $cores, storage: $storage_size_gb GB)"

        if ! command -v pvesh >/dev/null 2>&1; then
            log_warn "pvesh not found. Skipping resource checks."
            return 0
        fi

        local node=$(hostname)
        local available_memory_mb available_cores available_storage_gb
        available_memory_mb=$(pvesh get /nodes/"$node"/hardware/memory --output-format=json | jq -r '.free / 1024 / 1024')
        available_cores=$(pvesh get /nodes/"$node"/hardware/cpuinfo --output-format=json | jq -r '.cores')
        available_storage_gb=$(pvesh get /nodes/"$node"/storage/"$PHOENIX_ZFS_LXC_POOL" --output-format=json | jq -r '.avail / 1024 / 1024 / 1024')

        if [[ $(echo "$available_memory_mb < $memory_mb" | bc -l) -eq 1 ]]; then
            log_error "Insufficient memory: $available_memory_mb MB available, $memory_mb MB required"
            return 1
        fi
        if [[ $(echo "$available_cores < $cores" | bc -l) -eq 1 ]]; then
            log_error "Insufficient CPU cores: $available_cores available, $cores required"
            return 1
        fi
        if [[ $(echo "$available_storage_gb < $storage_size_gb" | bc -l) -eq 1 ]]; then
            log_error "Insufficient storage: $available_storage_gb GB available, $storage_size_gb GB required"
            return 1
        fi
        log_info "Resources sufficient for container $id"
        return 0
    }

    # Identify core and standard containers
    local core_container_ids=()
    local standard_container_ids=()
    for id in "${!LXC_CONFIGS[@]}"; do
        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
            log_warn "Skipping non-numeric container ID: $id"
            continue
        fi
        if [[ "$id" -ge 990 && "$id" -le 999 ]]; then
            log_info "Identified core container ID: $id"
            core_container_ids+=("$id")
        else
            # Validate ai_framework for 900-902
            if [[ "$id" -ge 900 && "$id" -le 902 ]]; then
                local ai_framework
                ai_framework=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.ai_framework // "vllm"')
                if [[ ! "$ai_framework" =~ ^(vllm|llamacpp|ollama)$ ]]; then
                    log_error "Invalid ai_framework '$ai_framework' for container $id. Must be vllm, llamacpp, or ollama."
                    exit 1
                fi
                log_info "AI framework for container $id: $ai_framework"
                if ! validate_ai_workload_config "$id"; then
                    log_error "AI workload configuration validation failed for container $id"
                    exit 1
                fi
            fi
            standard_container_ids+=("$id")
        fi
    done

    if command -v sort >/dev/null 2>&1; then
        mapfile -t core_container_ids < <(printf '%s\n' "${core_container_ids[@]}" | sort -n)
        mapfile -t standard_container_ids < <(printf '%s\n' "${standard_container_ids[@]}" | sort -n)
    else
        log_warn "'sort' command not found. Container order might be inconsistent."
    fi

    # Process core containers
    if [[ ${#core_container_ids[@]} -gt 0 ]]; then
        log_info "Starting creation of core containers: ${core_container_ids[*]}"
        for id in "${core_container_ids[@]}"; do
            log_info "Processing core container $id..."
            if ! check_proxmox_resources "$id"; then
                log_error "Resource check failed for container $id"
                exit 1
            fi
            if pct status "$id" >/dev/null 2>&1; then
                log_info "Core container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
                log_error "Failed to create core container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back core container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            if [[ "$id" == "999" ]]; then
                log_info "Setting up Portainer server container $id..."
                local portainer_script="/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_setup_portainer.sh"
                if ! "$portainer_script" "$id"; then
                    local exit_code=$?
                    log_error "Failed to set up Portainer server container $id (exit code $exit_code)."
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "Rolling back core container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit $exit_code
                fi
                if ! validate_portainer_network_in_container "$id"; then
                    log_error "Portainer server network validation failed for container $id"
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "Rolling back core container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
            fi
            if ! validate_container_status "$id"; then
                log_error "Container $id status validation failed"
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back core container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            log_info "Core container $id created and configured successfully."
        done
        log_info "All core containers created successfully."
    else
        log_info "No core containers (IDs 990-999) found in configuration."
    fi

    # Process standard containers
    if [[ ${#standard_container_ids[@]} -gt 0 ]]; then
        log_info "Starting creation of standard containers: ${standard_container_ids[*]}"
        for id in "${standard_container_ids[@]}"; do
            log_info "Processing standard container $id..."
            if ! check_proxmox_resources "$id"; then
                log_error "Resource check failed for container $id"
                exit 1
            fi
            if pct status "$id" >/dev/null 2>&1; then
                log_info "Standard container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
                log_error "Failed to create standard container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back standard container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            if [[ "$id" -ge 900 && "$id" -le 902 ]]; then
                log_info "Setting up Portainer agent container $id..."
                if ! install_portainer_agent "$id"; then
                    log_error "Failed to set up Portainer agent container $id."
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "Rolling back standard container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
                if ! validate_portainer_network_in_container "$id"; then
                    log_error "Portainer agent network validation failed for container $id"
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "Rolling back standard container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
            fi
            if ! validate_container_status "$id"; then
                log_error "Container $id status validation failed"
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back standard container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            log_info "Standard container $id created and configured successfully."
        done
        log_info "All standard containers created successfully."
    else
        log_info "No standard containers found in configuration."
    fi
}

# --- Main Execution ---
main() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR SETUP"
        echo "==============================================="
    fi
    log_info "Starting Phoenix Hypervisor setup..."

    validate_environment
    create_containers

    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR SETUP COMPLETED"
        echo "==============================================="
        echo "Check container status with: pct status <ID>"
        echo "Access Portainer server at: http://$PORTAINER_SERVER_IP:$PORTAINER_SERVER_PORT"
        echo "Access Portainer agents at: http://$PORTAINER_SERVER_IP:$PORTAINER_AGENT_PORT"
    fi
    log_info "Phoenix Hypervisor setup completed successfully."
}

main "$@"