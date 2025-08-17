#!/bin/bash
# Main script to establish Phoenix Hypervisor
# Creates and configures LXC containers based on phoenix_lxc_configs.json
# Version: 1.7.10
# Author: Assistant

set -euo pipefail
set -x  # Enable tracing for debugging

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
    if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
        log_error "Initial setup not completed. Run phoenix_hypervisor_initial_setup.sh first."
    fi
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
    if ! jq -e . "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&4; then
        log_error "Invalid JSON in $PHOENIX_LXC_CONFIG_FILE."
    fi
    log_info "Environment validated successfully."
}

# --- Create Containers ---
create_containers() {
    log_info "Creating LXC containers from $PHOENIX_LXC_CONFIG_FILE..."
    local container_ids
    container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>&4) || {
        log_error "Failed to parse $PHOENIX_LXC_CONFIG_FILE with jq."
    }
    for id in $container_ids; do
        log_info "Processing container $id..."
        if pct status "$id" >/dev/null 2>&1; then
            log_info "Container $id already exists, skipping creation."
            continue
        fi
        if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
            log_error "Failed to create container $id."
            if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                log_info "Rolling back by destroying container $id..."
                /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
            fi
            exit 1
        fi
        if [[ "$id" == "901" ]]; then
            log_info "Setting up drdevstral container $id..."
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_drdevstral.sh "$id"; then
                log_error "Failed to set up drdevstral container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back by destroying container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                fi
                exit 1
            fi
        fi
        log_info "Container $id created and configured successfully."
    done
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
    echo "Check container status with: pct status 901"
    echo "Access vLLM service at: http://10.0.0.111:8000/health"
}

main