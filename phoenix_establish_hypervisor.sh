#!/bin/bash
# Main script to establish Phoenix Hypervisor
# Creates and configures LXC containers based on phoenix_lxc_configs.json
# Version: 1.7.11 (Added support for container ID 902)
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

    # --- CRITICAL CHECK: Initial Setup Marker ---
    if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
        log_info "Marker file '$HYPERVISOR_MARKER' not found. Running initial setup script..."
        if [[ -x "/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh" ]]; then
            /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh || {
                log_error "Initial setup script failed. Check logs at /var/log/phoenix_hypervisor/phoenix_hypervisor_initial_setup.log."
                exit 1
            }
        else
            echo "[CRITICAL ERROR] Initial setup script not found at /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh." >&2
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
    # Use eval to safely construct the command with the redirection
    if ! eval "jq -e . \"\$PHOENIX_LXC_CONFIG_FILE\" >/dev/null $jq_stderr_redirect"; then
        log_error "Invalid JSON in $PHOENIX_LXC_CONFIG_FILE."
    fi
    # --- End Other Environment Checks ---

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
        # Specific setup for container ID 901
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
        elif [[ "$id" == "900" ]]; then
            log_info "Setting up DrCuda container $id..."
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_drcuda.sh "$id"; then
                log_error "Failed to set up DrCuda container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back by destroying container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                fi
                exit 1
            fi
        # --- NEW: Specific setup for container ID 902 ---
        elif [[ "$id" == "902" ]]; then
            log_info "Setting up llamacpp container $id..."
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_llamacpp.sh "$id"; then
                log_error "Failed to set up llamacpp container $id."
                if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
                    log_info "Rolling back by destroying container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id"
                fi
                exit 1
            fi
        # --- END NEW ---
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
    echo "Access vLLM service at: http://10.0.0.111:8000/health" # This IP comes from the config for container 901
}

main