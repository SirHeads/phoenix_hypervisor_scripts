#!/bin/bash
# Main script to establish Phoenix Hypervisor
# Creates and configures LXC containers based on phoenix_lxc_configs.json
# Version: 1.7.13 (Replaced DrSwarm with Portainer for container 999, updated 900-902 for Portainer agents, added token file validation)
# Author: Assistant

set -euo pipefail
# Note: set -x is kept for debugging, but error messages are now explicitly directed to stderr

# --- Terminal Handling ---
if [[ -t 0 ]]; then
    trap 'stty sane; echo "Terminal reset"' EXIT
else
    trap 'echo "Terminal reset (non-interactive)"' EXIT
fi

# --- Sourcing Check ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
    source ./phoenix_hypervisor_config.sh
    echo "[WARN] phoenix_establish_hypervisor.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh." >&2
else
    echo "[ERROR] phoenix_establish_hypervisor.sh: Configuration file not found." >&2
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    log_warn "phoenix_establish_hypervisor.sh: Sourced common functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
else
    echo "[ERROR] phoenix_hypervisor_common.sh not found." >&2
    exit 1
fi

# --- Validate Environment ---
validate_environment() {
    log_info "Validating environment..."

    # --- Check and Create Critical Directories ---
    local required_dirs=(
        "/usr/local/etc"
        "/usr/local/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "$HYPERVISOR_MARKER_DIR"
    )
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Directory '$dir' not found, attempting to create it..."
            if ! mkdir -p "$dir" 2>&4; then
                log_error "Failed to create directory '$dir'. Check permissions."
            else
                log_info "Directory '$dir' created successfully."
            fi
        fi
    done

    # --- NEW: Check Token Files ---
    local critical_files=(
        "$PHOENIX_HF_TOKEN_FILE"
        "$PHOENIX_DOCKER_TOKEN_FILE"
    )
    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Critical token file missing: $file"
        fi
        if [[ ! -r "$file" ]]; then
            log_error "Token file not readable: $file"
        fi
    done
    # --- END NEW ---

    # --- CRITICAL CHECK: Initial Setup Marker ---
    if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
        log_info "Marker file '$HYPERVISOR_MARKER' not found. Running initial setup script..."
        if [[ -x "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh" ]]; then
            /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh || {
                log_error "Initial setup script failed. Check logs at /var/log/phoenix_hypervisor/phoenix_hypervisor_initial_setup.log."
                exit 1
            }
        else
            echo "[CRITICAL ERROR] Initial setup script not found at /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh." >&2
            log_error "Initial setup script not found."
            exit 1
        fi
        # Verify marker file was created
        if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
            echo "[CRITICAL ERROR] Initial setup completed but marker file '$HYPERVISOR_MARKER' still not found." >&2
            log_error "Initial setup marker file not created."
            exit 1
        fi
    fi

    # --- Other Environment Checks ---
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "pct not installed."
    fi
    if ! systemctl is-active --quiet apparmor; then
        log_error "apparmor service not active."
    fi
    if ! zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>&1; then
        log_error "ZFS pool $PHOENIX_ZFS_LXC_POOL not found."
    fi
    if ! nvidia-smi >/dev/null 2>&1; then
        log_error "NVIDIA GPUs not detected."
    fi
    if [[ -e /proc/self/fd/4 ]]; then
        jq_stderr_redirect="2>&4" # Use debug log if fd 4 is available
    else
        log_warn "File descriptor 4 (debug log) not available during validation. jq errors will go to stderr."
    fi
    if ! eval "jq -e . \"\$PHOENIX_LXC_CONFIG_FILE\" >/dev/null $jq_stderr_redirect"; then
        log_error "Invalid JSON in $PHOENIX_LXC_CONFIG_FILE."
    fi
    # --- End Other Environment Checks ---

    log_info "Environment validated successfully."
}

# --- Create Containers with Priority ---
create_containers() {
    log_info "Creating LXC containers from $PHOENIX_LXC_CONFIG_FILE with priority..."

    # --- Load LXC Configurations ---
    if ! load_hypervisor_config; then
        log_error "create_containers: Failed to load hypervisor configuration."
    fi

    # --- Identify Core and Standard Containers ---
    local core_container_ids=()
    local standard_container_ids=()

    for id in "${!LXC_CONFIGS[@]}"; do
        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
            log_warn "create_containers: Skipping non-numeric container ID: $id"
            continue
        fi
        if [[ "$id" -ge 990 && "$id" -le 999 ]]; then
            log_info "create_containers: Identified core container ID: $id"
            core_container_ids+=("$id")
        else
            standard_container_ids+=("$id")
        fi
    done

    if command -v sort >/dev/null 2>&1; then
        mapfile -t core_container_ids < <(printf '%s\n' "${core_container_ids[@]}" | sort -n)
        mapfile -t standard_container_ids < <(printf '%s\n' "${standard_container_ids[@]}" | sort -n)
    else
        log_warn "'sort' command not found. Core/Standard container order might be inconsistent."
    fi

    # --- Process Core Containers First ---
    if [[ ${#core_container_ids[@]} -gt 0 ]]; then
        log_info "create_containers: Starting creation of core containers: ${core_container_ids[*]}"
        for id in "${core_container_ids[@]}"; do
            log_info "create_containers: Processing core container $id..."
            if pct status "$id" >/dev/null 2>&1; then
                log_info "create_containers: Core container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
                log_error "create_containers: Failed to create core container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "create_containers: Rolling back by destroying core container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                fi
                exit 1
            fi
            # --- UPDATED: Portainer Server Setup for ID 999 ---
            if [[ "$id" == "999" ]]; then
                log_info "create_containers: Setting up Portainer server container $id..."
                if ! /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_setup_portainer.sh "$id"; then
                    log_error "create_containers: Failed to set up Portainer server container $id."
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "create_containers: Rolling back by destroying Portainer server container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                    fi
                    exit 1
                fi
            fi
            log_info "create_containers: Core container $id created and configured successfully."
        done
        log_info "create_containers: All core containers created successfully."
    else
        log_info "create_containers: No core containers (IDs 990-999) found in configuration."
    fi
    # --- END Process Core Containers ---

    # --- Process Standard Containers ---
    if [[ ${#standard_container_ids[@]} -gt 0 ]]; then
        log_info "create_containers: Starting creation of standard containers: ${standard_container_ids[*]}"
        for id in "${standard_container_ids[@]}"; do
            log_info "create_containers: Processing standard container $id..."
            if pct status "$id" >/dev/null 2>&1; then
                log_info "create_containers: Standard container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
                log_error "create_containers: Failed to create standard container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "create_containers: Rolling back by destroying standard container $id..."
                    /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                fi
                exit 1
            fi
            # --- UPDATED: Portainer Agent Setup for IDs 900-902 ---
            if [[ "$id" -ge 900 && "$id" -le 902 ]]; then
                log_info "create_containers: Setting up Portainer agent container $id..."
                if ! install_portainer_agent "$id"; then
                    log_error "create_containers: Failed to set up Portainer agent container $id."
                    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                        log_info "create_containers: Rolling back by destroying Portainer agent container $id..."
                        /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                    fi
                    exit 1
                fi
            fi
            log_info "create_containers: Standard container $id created and configured successfully."
        done
        log_info "create_containers: All standard containers created successfully."
    else
        log_info "create_containers: No standard containers found in configuration."
    fi
    # --- END Process Standard Containers ---
}

# --- Main Execution ---
main() {
    echo "==============================================="
    echo "PHOENIX HYPERVISOR SETUP"
    echo "==============================================="
    log_info "Starting Phoenix Hypervisor setup..."

    validate_environment
    create_containers

    echo "==============================================="
    echo "PHOENIX HYPERVISOR SETUP COMPLETED"
    echo "==============================================="
    log_info "Phoenix Hypervisor setup completed successfully."
    echo "Check container status with: pct status <ID>"
    echo "Access Portainer server at: http://$PORTAINER_SERVER_IP:$PORTAINER_SERVER_PORT"
    echo "Access Portainer agents at: http://$PORTAINER_SERVER_IP:$PORTAINER_AGENT_PORT"
}

main "$@"