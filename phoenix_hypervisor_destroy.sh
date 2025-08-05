#!/bin/bash
# Phoenix Hypervisor Destroy Script
# Destroys LXC containers and associated resources for the Phoenix Hypervisor.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Root privileges
# - phoenix_hypervisor_common.sh sourced (for paths/defaults)
# Usage: ./phoenix_hypervisor_destroy.sh [--force] [--cleanup-only]
# Version: 1.7.3
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

# --- Enhanced Main Function ---
main() {
    log_info "Starting Phoenix Hypervisor destruction process..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR DESTROY"
    echo "==============================================="
    echo ""
    
    # Parse command line arguments
    local force=false
    local cleanup_only=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            --cleanup-only)
                cleanup_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--force] [--cleanup-only]"
                echo ""
                echo "Options:"
                echo "  --force        Skip confirmation prompts"
                echo "  --cleanup-only  Only remove LXC containers, keep configuration files"
                echo ""
                exit 1
                ;;
        esac
    done
    
    # Check if we have the required prerequisites
    log_info "Checking system prerequisites..."
    check_root
    check_proxmox_environment
    
    # Show system information
    echo ""
    echo "System Information:"
    echo "-------------------"
    show_system_info
    
    # Get list of LXC containers to destroy
    local lxc_ids=()
    if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_info "Loading configuration from $PHOENIX_LXC_CONFIG_FILE"
        # Load all container IDs from config file
        lxc_ids=$(jq -r 'if (.lxc_configs | type == "object") then .lxc_configs | keys[] else empty end' "$PHOENIX_LXC_CONFIG_FILE")
        
        if [[ -z "$lxc_ids" ]]; then
            log_warn "No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
            echo ""
        fi
    else
        log_warn "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        # Try to get containers manually from Proxmox
        lxc_ids=$(pct list | grep -E '^[0-9]+' | awk '{print $1}' | head -n 20)
    fi
    
    # Show what we're going to destroy
    echo ""
    echo "Containers to be destroyed:"
    echo "---------------------------"
    
    if [[ ${#lxc_ids[@]} -eq 0 ]]; then
        echo "No containers found in configuration file."
        echo ""
        read -p "Do you want to proceed with cleanup anyway? (yes/no): " proceed_anyway
        if [[ "$proceed_anyway" != "yes" ]]; then
            log_info "Destruction cancelled by user."
            exit 0
        fi
    else
        for lxc_id in $lxc_ids; do
            echo "  - Container $lxc_id"
        done
        echo ""
    fi
    
    # Confirm destruction unless --force is specified
    if [[ "$force" == false ]]; then
        read -p "Do you want to proceed with destroying these containers? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Destruction cancelled by user."
            echo ""
            echo "Destruction cancelled. No changes were made."
            echo ""
            exit 0
        fi
    else
        echo "Force mode enabled - proceeding without confirmation..."
    fi
    
    echo ""
    echo "Starting destruction process..."
    echo "-------------------------------"
    
    # Stop and destroy containers in reverse order (if cleanup_only is false)
    if [[ "$cleanup_only" == false ]]; then
        log_info "Destroying LXC containers..."
        
        local destroyed_containers=0
        for lxc_id in $lxc_ids; do
            if validate_lxc_id "$lxc_id"; then
                echo ""
                log_info "Processing container $lxc_id..."
                
                # Check if container exists
                if pct status "$lxc_id" >/dev/null 2>&1; then
                    # Stop container if running
                    echo "Stopping container $lxc_id..."
                    pct stop "$lxc_id" >/dev/null 2>&1 || true
                    
                    # Wait a moment for graceful shutdown
                    sleep 2
                    
                    # Destroy the container
                    echo "Destroying container $lxc_id..."
                    if pct destroy "$lxc_id" --force >/dev/null 2>&1; then
                        log_info "Container $lxc_id destroyed successfully"
                        ((destroyed_containers++))
                    else
                        log_warn "Failed to destroy container $lxc_id"
                    fi
                else
                    log_info "Container $lxc_id not found or already destroyed"
                fi
            else
                log_warn "Skipping invalid LXC ID: $lxc_id"
            fi
        done
        
        echo ""
        echo "Destroyed containers: $destroyed_containers"
    else
        log_info "Cleanup-only mode - only removing markers and logs..."
    fi
    
    # Remove marker files (if cleanup_only is false)
    if [[ "$cleanup_only" == false ]]; then
        log_info "Removing completion markers..."
        
        # Remove LXC creation markers
        if [[ -d "$HYPERVISOR_MARKER_DIR" ]]; then
            echo "Removing LXC creation markers..."
            find "$HYPERVISOR_MARKER_DIR" -name "*lxc_*_created" -delete 2>/dev/null || true
        fi
        
        # Remove container setup markers
        if [[ -d "$HYPERVISOR_MARKER_DIR" ]]; then
            echo "Removing container setup markers..."
            find "$HYPERVISOR_MARKER_DIR" -name "*container_*_setup_complete" -delete 2>/dev/null || true
        fi
        
        # Remove main setup marker
        if [[ -f "$HYPERVISOR_MARKER" ]]; then
            echo "Removing main setup marker..."
            rm -f "$HYPERVISOR_MARKER"
        fi
    fi
    
    # Clean up log files (if cleanup_only is false)
    if [[ "$cleanup_only" == false ]]; then
        log_info "Cleaning up log files..."
        
        if [[ -f "$HYPERVISOR_LOGFILE" ]]; then
            echo "Removing log file: $HYPERVISOR_LOGFILE"
            rm -f "$HYPERVISOR_LOGFILE"
        fi
        
        # Remove log directory if empty
        local log_dir=$(dirname "$HYPERVISOR_LOGFILE")
        if [[ -d "$log_dir" ]] && [[ -z "$(ls -A "$log_dir")" ]]; then
            echo "Removing empty log directory: $log_dir"
            rmdir "$log_dir" 2>/dev/null || true
        fi
        
        # Remove marker directory if empty (except for the main marker)
        if [[ -d "$HYPERVISOR_MARKER_DIR" ]] && [[ -z "$(ls -A "$HYPERVISOR_MARKER_DIR")" ]]; then
            echo "Removing empty marker directory: $HYPERVISOR_MARKER_DIR"
            rmdir "$HYPERVISOR_MARKER_DIR" 2>/dev/null || true
        fi
    fi
    
    # Clean up token file (if cleanup_only is false)
    if [[ "$cleanup_only" == false ]] && [[ -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        log_info "Removing Hugging Face token file..."
        rm -f "$PHOENIX_HF_TOKEN_FILE"
        echo "Removed token file: $PHOENIX_HF_TOKEN_FILE"
    fi
    
    # Final confirmation
    log_info "Destruction process completed"
    
    echo ""
    echo "==============================================="
    echo "DESTRUCTION COMPLETED SUCCESSFULLY!"
    echo "==============================================="
    echo ""
    echo "What was removed:"
    if [[ "$cleanup_only" == false ]]; then
        echo "- LXC containers (if any)"
        echo "- Completion markers"
        echo "- Log files"
        echo "- Hugging Face token file"
    else
        echo "- Completion markers"
        echo "- Log files"
        echo "- Token file"
    fi
    echo ""
    
    if [[ "$cleanup_only" == false ]]; then
        echo "To recreate the hypervisor:"
        echo "  /usr/local/bin/phoenix_establish_hypervisor.sh"
        echo ""
    else
        echo "To recreate the hypervisor:"
        echo "  /usr/local/bin/phoenix_establish_hypervisor.sh"
        echo ""
    fi
}

# --- Enhanced Prerequisite Functions ---
check_root() {
    log_info "Checking if running as root..."
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_info "Script is running with root privileges"
}

check_proxmox_environment() {
    log_info "Checking Proxmox VE environment..."
    
    if ! command -v pveversion >/dev/null 2>&1; then
        log_error "pveversion command not found. Ensure this script is running on a Proxmox VE system."
        exit 1
    fi
    
    local proxmox_version
    proxmox_version=$(pveversion | cut -d'/' -f2 | cut -d'-' -f1)
    
    if [[ ! "$proxmox_version" =~ ^8\..* ]]; then
        log_warn "This script is designed for Proxmox VE 8.x. Found Proxmox VE version: $proxmox_version"
        echo "Proceeding anyway, but compatibility may not be guaranteed."
    fi
    
    local debian_version
    debian_version=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
    
    if [[ ! "$debian_version" =~ ^12\..* ]]; then
        log_warn "This script is designed for Debian 12. Found Debian version: $debian_version"
        echo "Proceeding anyway, but compatibility may not be guaranteed."
    fi
    
    log_info "Proxmox VE environment verified (Version: $proxmox_version, Debian: $debian_version)"
}

show_system_info() {
    echo ""
    echo "System Information:"
    echo "-------------------"
    
    # Get system architecture
    local arch
    arch=$(uname -m)
    echo "Architecture: $arch"
    
    # Get OS version
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "OS: $NAME $VERSION_ID"
    fi
    
    # Get Proxmox version
    if command -v pveversion >/dev/null 2>&1; then
        echo "Proxmox VE Version: $(pveversion)"
    fi
    
    # Show available containers (if any)
    local container_count
    container_count=$(pct list | grep -c '^[0-9]')
    if [[ "$container_count" -gt 0 ]]; then
        echo "Containers found: $container_count"
    else
        echo "No containers found"
    fi
    
    echo ""
}

# --- Enhanced Validation Functions ---
validate_lxc_id() {
    local lxc_id="$1"
    
    # Check if it's a valid numeric ID
    if ! [[ "$lxc_id" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Check if ID is in valid range (typically 100-999 for containers)
    if [[ "$lxc_id" -lt 100 ]] || [[ "$lxc_id" -gt 999 ]]; then
        log_warn "LXC ID $lxc_id is outside typical range (100-999)"
    fi
    
    return 0
}

# --- Enhanced Error Handling ---
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# --- Execute Main Function ---
main "$@"