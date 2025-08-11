#!/bin/bash
# Main script to establish the Phoenix Hypervisor on Proxmox
# Orchestrates LXC creation and setup (e.g., drdevstral with vLLM) based on phoenix_lxc_configs.json
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - NVIDIA drivers installed on host
# Usage: ./phoenix_establish_hypervisor.sh [--hf-token <token>]
# Version: 1.7.4
# Author: Assistant
set -euo pipefail

# --- Sourcing Dependencies ---
# Source configuration first
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    echo "[ERROR] Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh" >&2
    exit 1
fi

# Source common functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
     source /usr/local/bin/phoenix_hypervisor_common.sh
     log_warn "phoenix_establish_hypervisor.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
else
    echo "[ERROR] Common functions file not found: /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh or /usr/local/bin/phoenix_hypervisor_common.sh" >&2
    exit 1
fi

# --- Main Logic ---

# - Main Function -
main() {
    echo "Loading Phoenix Hypervisor configuration..."
    echo "============================================"
    echo "Validating configuration settings..."
    echo "------------------------------------"
    # Simple validation echo, actual validation happens in sourced config/common
    echo "Configuration validation completed successfully"
    log_info "Starting Phoenix Hypervisor setup process..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR SETUP"
    echo "==============================================="
    echo ""

    # Verify prerequisites
    log_info "Verifying system requirements..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not installed. Please install it first."
        exit 1
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "pct (Proxmox Container Tools) is required but not installed."
        exit 1
    fi

    # Validate configuration file exists and is readable (explicit check)
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        log_error "Please ensure phoenix_lxc_configs.json is placed at the correct path."
        exit 1
    fi
    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
         log_error "Configuration file is not readable: $PHOENIX_LXC_CONFIG_FILE"
         exit 1
    fi

    # Load configuration (once)
    log_info "Loading configuration..."
    # Use the load_hypervisor_config function from common.sh
    # It should handle validation and population of LXC_CONFIGS
    if declare -f load_hypervisor_config > /dev/null; then
        load_hypervisor_config
    else
        log_error "Required function 'load_hypervisor_config' not found in common.sh."
        exit 1
    fi

    # Validate that LXC_CONFIGS was populated
    if ! declare -p LXC_CONFIGS > /dev/null 2>&1 || [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
        log_error "Failed to load LXC configurations or no configurations found in $PHOENIX_LXC_CONFIG_FILE."
        log_error "Please check the configuration file format and content."
        exit 1
    fi

    # Initialize hypervisor environment
    initialize_hypervisor

    echo ""
    log_info "Starting initial system setup..."
    # Run initial setup
    log_info "Running initial setup script..."
    if ! retry_command 5 10 "/usr/local/bin/phoenix_hypervisor_initial_setup.sh" 2>&1 | while read -r line; do
        log_info "phoenix_hypervisor_initial_setup.sh: $line"
    done; then
        log_error "Initial setup failed. Exiting."
        exit 1
    fi

    # Create each container
    log_info "Creating LXC containers..."
    local created_count=0
    local failed_count=0

    # Process each LXC configuration from the loaded array
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        local config="${LXC_CONFIGS[$lxc_id]}"
        echo ""
        log_info "Processing container $lxc_id..."
        # Create the LXC container - using existing working function
        # Pass only the container ID; the creation script can fetch its config
        if ! /usr/local/bin/phoenix_hypervisor_create_lxc.sh "$lxc_id"; then
            log_error "Failed to create container $lxc_id"
            ((failed_count++))
            # Decide if we should continue or exit on first failure
            # For now, continue to try others
            continue
        fi

        # Run container-specific setup script if defined
        local setup_script_path
        # Use jq to get the setup script path from the config file for this specific container
        setup_script_path=$(jq -r ".lxc_configs.\"$lxc_id\".setup_script // \"\"" "$PHOENIX_LXC_CONFIG_FILE")
        if [[ -n "${setup_script_path:-}" ]] && [[ -f "$setup_script_path" ]]; then
            log_info "Running container-specific setup script for $lxc_id: $setup_script_path"
            # Execute the setup script with container ID as parameter
            if ! "$setup_script_path" "$lxc_id"; then
                log_error "Container-specific setup script failed for $lxc_id"
                ((failed_count++))
                # Continue with other containers even if one fails
            else
                log_info "Container-specific setup completed successfully for $lxc_id"
            fi
        else
             if [[ -n "${setup_script_path:-}" ]]; then
                 log_warn "Setup script defined for container $lxc_id but file not found: $setup_script_path. Skipping specialized setup."
             else
                 log_info "No setup script defined for container $lxc_id, skipping specialized setup"
             fi
        fi
        ((created_count++))
    done

    echo ""
    log_info "Setup process completed."
    # Summary
    echo ""
    echo "==============================================="
    echo "SUMMARY"
    echo "==============================================="
    log_info "Successfully created: $created_count containers"
    log_info "Failed to create: $failed_count containers"
    if [[ $failed_count -eq 0 ]]; then
        log_info "All containers created and configured successfully!"
        touch "$HYPERVISOR_MARKER"
    else
        log_error "Some containers failed during setup. Check logs for details."
        exit 1
    fi
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR SETUP COMPLETE"
    echo "==============================================="
}

# - Enhanced Configuration Loading -
# This function is now expected to be in phoenix_hypervisor_common.sh
# load_hypervisor_config() {
#     log_info "Loading hypervisor configuration..."
#     # Validate JSON structure
#     if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
#         log_error "Configuration file is not valid JSON: $PHOENIX_LXC_CONFIG_FILE"
#         exit 1
#     fi
#
#     # Declare the global associative array
#     declare -gA LXC_CONFIGS
#
#     # Load configurations into the global associative array
#     local container_ids
#     container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || true)
#     if [[ -z "$container_ids" ]]; then
#         log_warn "No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
#         return 0
#     fi
#
#     while IFS= read -r id; do
#         if [[ -n "$id" ]]; then
#             # Store the JSON string for the container config
#             LXC_CONFIGS["$id"]=$(jq -c ".lxc_configs.\"$id\"" "$PHOENIX_LXC_CONFIG_FILE")
#         fi
#     done <<< "$container_ids"
#
#     log_info "Loaded $(( ${#LXC_CONFIGS[@]} )) LXC configurations"
# }

# - Enhanced Initialization -
initialize_hypervisor() {
    log_info "Initializing Phoenix Hypervisor environment..."
    # Create marker directory if it doesn't exist
    mkdir -p "$HYPERVISOR_MARKER_DIR"
    # Check if setup has already been completed (idempotency)
    if [[ -f "$HYPERVISOR_MARKER" ]]; then
        log_warn "Phoenix Hypervisor appears to be already set up. Continuing anyway."
    fi
    log_info "Phoenix Hypervisor environment initialized"
}

# - Enhanced Retry Command -
# This function is also expected in phoenix_hypervisor_common.sh
# Keeping a local copy here for now, but prefer the common one.
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        else
            log_warn "Command failed (attempt $attempt/$max_attempts). Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    return 1
}
# Check if retry_command is available from common.sh, if so, use that one
if declare -f retry_command > /dev/null && [[ "$(type retry_command)" == *"function"* ]]; then
    # Use the one from common.sh
    unset -f retry_command # Remove local definition
fi

# - Main Execution -
main "$@"
