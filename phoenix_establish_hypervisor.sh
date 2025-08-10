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

# Source configuration first
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    echo "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh"
    exit 1
fi

# Source common functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
else
    echo "Common functions file not found: /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
    exit 1
fi

# --- Enhanced User Experience Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2
}

# --- Enhanced Initialization ---
initialize_hypervisor() {
    log_info "Initializing Phoenix Hypervisor environment..."
    # Create marker directory if needed
    mkdir -p "$HYPERVISOR_MARKER_DIR" || { log_error "Failed to create marker directory: $HYPERVISOR_MARKER_DIR"; exit 1; }
    # Set up logging
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/hypervisor.log"
        mkdir -p "$(dirname "$HYPERVISOR_LOGFILE")" || { log_error "Failed to create log directory: $(dirname "$HYPERVISOR_LOGFILE")"; exit 1; }
    fi
    # Set permissions on log file
    touch "$HYPERVISOR_LOGFILE" || { log_error "Failed to create log file: $HYPERVISOR_LOGFILE"; exit 1; }
    chmod 600 "$HYPERVISOR_LOGFILE"
    log_info "Phoenix Hypervisor environment initialized"
}

# --- Enhanced Configuration Loading ---
load_hypervisor_config() {
    # Add guard to prevent multiple calls
    if [[ "${CONFIG_LOADED:-false}" == "true" ]]; then
        log_info "Configuration already loaded, skipping..."
        return 0
    fi
    
    log_info "Loading hypervisor configuration..."
    
    # Validate configuration file exists
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Validate JSON format (only once)
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Load configuration into arrays
    declare -gA LXC_CONFIGS=()
    declare -gA LXC_SETUP_SCRIPTS=()
    
    # Get all LXC IDs from the config
    local lxc_ids
    lxc_ids=$(jq -r 'if (.lxc_configs | type == "object") then .lxc_configs | keys[] else empty end' "$PHOENIX_LXC_CONFIG_FILE")
    
    if [[ -z "$lxc_ids" ]]; then
        log_warn "No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
        CONFIG_LOADED=true
        return 0
    fi
    
    # Process each LXC configuration
    while IFS= read -r lxc_id; do
        if [[ -n "$lxc_id" ]]; then
            local config
            config=$(jq -r ".lxc_configs.\"$lxc_id\"" "$PHOENIX_LXC_CONFIG_FILE")
            if [[ "$config" != "null" ]]; then
                LXC_CONFIGS["$lxc_id"]="$config"
                # Extract setup script path if specified
                local setup_script
                setup_script=$(echo "$config" | jq -r '.setup_script // empty')
                if [[ -n "$setup_script" && "$setup_script" != "null" ]]; then
                    LXC_SETUP_SCRIPTS["$lxc_id"]="$setup_script"
                fi
            fi
        fi
    done <<< "$lxc_ids"
    
    log_info "Loaded ${#LXC_CONFIGS[@]} LXC configurations"
    CONFIG_LOADED=true
}

# --- Enhanced Main Function ---
main() {
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
    
    # Validate configuration file exists and is readable
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Load configuration (once)
    log_info "Loading configuration..."
    load_hypervisor_config
    
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
    
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        local config="${LXC_CONFIGS[$lxc_id]}"
        
        echo ""
        log_info "Processing container $lxc_id..."
        
        # Create the LXC container
        if /usr/local/bin/phoenix_hypervisor_create_lxc.sh "$lxc_id"; then
            ((created_count++))
            log_info "Container $lxc_id created successfully"
            
            # Run setup script if specified
            if [[ -n "${LXC_SETUP_SCRIPTS[$lxc_id]:-}" ]]; then
                log_info "Running setup script for container $lxc_id..."
                if ! /usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh "$lxc_id"; then
                    log_warn "Setup script failed for container $lxc_id"
                    ((failed_count++))
                fi
            fi
        else
            log_error "Failed to create container $lxc_id"
            ((failed_count++))
        fi
    done
    
    echo ""
    echo "==============================================="
    echo "SETUP SUMMARY"
    echo "==============================================="
    echo "Created containers: $created_count"
    echo "Failed containers: $failed_count"
    echo "==============================================="
    
    if [[ $failed_count -eq 0 ]]; then
        log_info "Phoenix Hypervisor setup completed successfully!"
    else
        log_error "Some containers failed to set up. Check logs for details."
        exit 1
    fi
}

# --- Enhanced Retry Command Function ---
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

# --- Execute Main Function ---
main "$@"