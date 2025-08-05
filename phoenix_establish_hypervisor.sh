#!/bin/bash
# Main script to establish the Phoenix Hypervisor on Proxmox
# Orchestrates LXC creation and setup (e.g., drdevstral with vLLM) based on phoenix_lxc_configs.json
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - NVIDIA drivers installed on host
# Usage: ./phoenix_establish_hypervisor.sh [--hf-token <token>]
# Version: 1.7.2
# Author: Assistant
set -euo pipefail

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

prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

# --- Enhanced Logging Function ---
log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: HYPERVISOR_LOGFILE variable not set" >&2
        exit 1
    fi
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$HYPERVISOR_LOGFILE")
    mkdir -p "$log_dir" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to create log directory: $log_dir" >&2; exit 1; }
    # Log to file via fd 4
    if [[ ! -e /proc/self/fd/4 ]]; then
        exec 4>>"$HYPERVISOR_LOGFILE"
        chmod 600 "$HYPERVISOR_LOGFILE" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $0: Failed to set permissions on $HYPERVISOR_LOGFILE" >&2; }
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&4
    # Output INFO, WARN, ERROR to stderr for terminal visibility
    if [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&2
    fi
}

# --- Source Configuration for Paths ---
# Ensure phoenix_hypervisor_config.sh is sourced by the caller
if [[ -z "${HYPERVISOR_MARKER_DIR:-}" ]] || [[ -z "${HYPERVISOR_LOGFILE:-}" ]] || [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
    log_error "phoenix_hypervisor_config.sh must be sourced first."
    exit 1
fi

# --- Check if setup is already completed ---
if is_script_completed "$HYPERVISOR_MARKER"; then
    log_info "Hypervisor setup already completed. Exiting."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Hypervisor setup already completed. Exiting." >&2
    exit 0
fi

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
    
    # Load configuration
    log_info "Loading configuration..."
    load_hypervisor_config
    
    # Show configuration summary
    echo ""
    echo "Configuration Summary:"
    echo "----------------------"
    echo "LXC configs found: ${#LXC_CONFIGS[@]}"
    echo "Default storage pool: $DEFAULT_LXC_STORAGE_POOL"
    echo "Default memory: $DEFAULT_LXC_MEMORY_MB MB"
    echo "Default cores: $DEFAULT_LXC_CORES"
    echo ""
    
    # Confirm with user before proceeding
    read -p "Do you want to proceed with the setup? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Setup cancelled by user."
        exit 0
    fi
    
    echo ""
    log_info "Starting initial system setup..."
    
    # Run initial setup
    log_info "Running initial setup script..."
    if ! retry_command 5 10 "/usr/local/bin/phoenix_hypervisor_initial_setup.sh" 2>&1 | while read -r line; do 
        log_info "phoenix_hypervisor_initial_setup.sh: $line"
    done; then
        log_error "Initial setup script failed."
        if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
            log_warn "No LXC-specific rollback needed for initial setup failure."
        fi
        exit 1
    fi
    
    # Create LXC containers
    log_info "Creating LXC containers..."
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        log_info "Creating container $lxc_id..."
        if ! /usr/local/bin/phoenix_hypervisor_create_lxc.sh "$lxc_id"; then
            log_error "Failed to create container $lxc_id"
            exit 1
        fi
        log_info "Container $lxc_id created successfully."
    done
    
    # Setup each container with vLLM
    log_info "Setting up containers with vLLM services..."
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        local config="${LXC_CONFIGS[$lxc_id]}"
        local name=$(echo "$config" | jq -r '.name')
        log_info "Setting up container $lxc_id ($name) with vLLM..."
        
        # Get the setup script path from config
        local setup_script=$(echo "$config" | jq -r '.setup_script // empty')
        if [[ -n "$setup_script" && "$setup_script" != "null" ]]; then
            if ! "$setup_script" "$lxc_id"; then
                log_error "Failed to set up container $lxc_id with vLLM"
                exit 1
            fi
            log_info "Container $lxc_id ($name) setup with vLLM completed."
        else
            log_warn "No setup script defined for container $lxc_id"
        fi
    done
    
    # Mark completion
    log_info "Marking hypervisor setup as complete..."
    mark_script_completed "$HYPERVISOR_MARKER"
    log_info "Phoenix Hypervisor setup completed successfully."
    
    echo ""
    echo "==============================================="
    echo "SETUP COMPLETED SUCCESSFULLY!"
    echo "==============================================="
    echo "Containers created:"
    pct list
    echo ""
    echo "To check vLLM service status in container 901:"
    echo "  pct exec 901 -- systemctl status vllm-drdevstral.service"
    echo ""
}

# --- Enhanced Error Handling ---
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# --- Parse command-line arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hf-token)
            HF_TOKEN_OVERRIDE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--hf-token <token>]"
            exit 1
            ;;
    esac
done

# Execute main function
main