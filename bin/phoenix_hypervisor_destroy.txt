#!/bin/bash
# Phoenix Hypervisor Container Destruction Script
# Destroys containers and cleans up all associated resources
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Root privileges
# - phoenix_hypervisor_common.sh sourced
# Usage: ./phoenix_hypervisor_destroy.sh [--force] [<container_id>]
# Version: 1.7.4
# Author: Assistant

set -euo pipefail

# --- Enhanced Sourcing ---
# Source configuration from the standard location
# Ensures paths like PHOENIX_LXC_CONFIG_FILE are available
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    # Fallback to current directory if standard location not found (less ideal)
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        echo "[WARN] phoenix_hypervisor_destroy.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
    else
        echo "[ERROR] phoenix_hypervisor_destroy.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
        exit 1
    fi
fi

# Source common functions from the standard location (as defined in corrected common.sh)
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
# This provides access to logging functions (log_info, etc.) and other utilities if needed.
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_destroy.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_destroy.sh: Sourced common functions from current directory. Prefer standard locations." >&2
else
    # Define minimal fallback logging if common functions can't be sourced
    # This ensures the script can report basic errors even if sourcing fails completely
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2; }
    log_warn "phoenix_hypervisor_destroy.sh: Common functions file not found in standard locations. Using minimal logging."
fi
# --- END Enhanced Sourcing ---

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

# Validates that a given string is a valid LXC container ID (numeric)
validate_lxc_id() {
    local id="$1"
    if [[ -z "$id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    # Check if the ID consists only of digits
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        return 0 # Valid
    else
        log_error "Invalid container ID format: $id (must be numeric)"
        return 1 # Invalid
    fi
}

# - Enhanced Container Destruction -
destroy_container() {
    local container_id="$1"
    local force="${2:-false}" # Default to false if not provided

    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi

    # Check container existence and get its status
    local status_output
    local status_exit_code
    status_output=$(pct status "$container_id" 2>&1)
    status_exit_code=$?

    if [[ $status_exit_code -ne 0 ]]; then
        # Container does not exist or is inaccessible
        if [[ "$status_output" == *"does not exist"* ]] || [[ $status_exit_code -eq 1 ]]; then
            log_warn "Container $container_id does not exist or is not accessible"
            return 0 # Consider it a success if it's already gone
        else
            # Some other error occurred getting status
            log_error "Failed to get status for container $container_id: $status_output"
            return 1
        fi
    fi

    # If we get here, the container exists. Check if it's running.
    # The output of `pct status` is typically just "status: running" or "status: stopped"
    if echo "$status_output" | grep -q "running"; then
        log_info "Container $container_id is currently running. Initiating shutdown..."
        # Stop container if running (with retry logic)
        local max_attempts=5
        local attempt=1
        local stop_success=false
        while [[ $attempt -le $max_attempts ]]; do
            log_info "Stopping container $container_id (attempt $attempt/$max_attempts)..."
            if pct stop "$container_id"; then
                log_info "Stop command issued successfully for container $container_id"
                # Wait a bit and then verify it stopped
                sleep 2
                local verify_status
                verify_status=$(pct status "$container_id" 2>&1)
                if echo "$verify_status" | grep -q "stopped"; then
                    log_info "Container $container_id confirmed stopped."
                    stop_success=true
                    break
                else
                    log_warn "Container $container_id might still be stopping (status: $verify_status)"
                fi
            else
                log_warn "Failed to issue stop command for container $container_id on attempt $attempt"
            fi
            sleep 2
            ((attempt++))
        done

        if [[ "$stop_success" != "true" ]]; then
            log_warn "Failed to stop container $container_id after $max_attempts attempts"
            if [[ "$force" == "true" ]]; then
                log_info "Force destruction requested, continuing with purge..."
            else
                log_error "Failed to stop container $container_id. Use --force to proceed anyway."
                return 1
            fi
        fi
    else
        # Container exists but is not running (likely stopped)
        log_info "Container $container_id is already stopped."
    fi

    # Destroy container with purge
    log_info "Destroying container $container_id with purge..."
    if pct destroy "$container_id" --purge; then
        log_info "Container $container_id destroyed successfully"
        # Remove marker file if it exists
        local marker_file="$HYPERVISOR_MARKER_DIR/container_${container_id}_created"
        if [[ -f "$marker_file" ]]; then
            rm -f "$marker_file"
            log_info "Removed container marker file: $marker_file"
        fi
        return 0
    else
        log_error "Failed to destroy container $container_id"
        return 1
    fi
}

# --- Enhanced Cleanup Functions ---
cleanup_container_resources() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        return 1
    fi
    
    log_info "Cleaning up resources for container $container_id..."
    
    # Remove any remaining directories
    local dirs_to_clean=(
        "/var/lib/lxc/$container_id"
        "/var/lib/phoenix_hypervisor/containers/$container_id"
        "/home/vllm/models/$container_id"
    )
    
    for dir in "${dirs_to_clean[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Cleaning up directory: $dir"
            rm -rf "$dir"
        fi
    done
    
    # Remove any associated configuration files
    local config_files=(
        "/usr/local/etc/container_$container_id.json"
        "/var/lib/phoenix_hypervisor/configs/$container_id.conf"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_info "Removing configuration file: $file"
            rm -f "$file"
        fi
    done
    
    log_info "Resource cleanup completed for container $container_id"
}

# --- Enhanced Validation ---
validate_destruction() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        return 1
    fi
    
    # Verify container is completely gone
    if pct status "$container_id" >/dev/null 2>&1; then
        log_error "Container $container_id still exists after destruction"
        return 1
    fi
    
    # Check for any remaining directories
    local remaining_dirs=(
        "/var/lib/lxc/$container_id"
        "/var/lib/phoenix_hypervisor/containers/$container_id"
    )
    
    for dir in "${remaining_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_warn "Remaining directory found after destruction: $dir"
        fi
    done
    
    log_info "Destruction validation passed for container $container_id"
    return 0
}

# --- Enhanced Main Function ---
main() {
    log_info "Starting Phoenix Hypervisor container destruction process..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR CONTAINER DESTRUCTION"
    echo "==============================================="
    echo ""
    
    # Verify prerequisites
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    if ! command -v pct >/dev/null 2>&1; then
        log_error "Proxmox Container Toolkit (pct) is required but not installed"
        exit 1
    fi
    
    # Parse arguments
    local force=false
    local container_id=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                shift
                ;;
            *)
                container_id="$1"
                shift
                ;;
        esac
    done
    
    # Validate container ID
    if [[ -z "$container_id" ]]; then
        log_error "Container ID is required as argument"
        echo "Usage: $0 [--force] <container_id>"
        echo "  --force     Force destruction even if stop fails"
        echo "  <container_id>  Container ID to destroy (e.g., 901)"
        exit 1
    fi
    
    # Validate LXC ID format
    if ! validate_lxc_id "$container_id"; then
        log_error "Invalid container ID format: $container_id"
        exit 1
    fi
    
    # Show destruction summary
    echo ""
    echo "Destruction Configuration:"
    echo "--------------------------"
    echo "Container ID: $container_id"
    echo "Force Mode: $force"
    echo ""
    
    # Confirm with user before proceeding
    read -p "Do you want to proceed with destruction of container $container_id? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Destruction cancelled by user."
        exit 0
    fi
    
    # Destroy the container
    if destroy_container "$container_id" "$force"; then
        log_info "Container $container_id destroyed successfully"
        
        # Cleanup resources
        if cleanup_container_resources "$container_id"; then
            log_info "Resource cleanup completed for container $container_id"
        else
            log_warn "Resource cleanup encountered issues for container $container_id"
        fi
        
        # Validate destruction
        if validate_destruction "$container_id"; then
            echo ""
            echo "==============================================="
            echo "DESTRUCTION COMPLETE"
            echo "Container ID: $container_id"
            echo "Status: SUCCESS"
            echo "==============================================="
            log_info "All operations completed successfully for container $container_id"
            exit 0
        else
            log_error "Validation failed for container $container_id"
            exit 1
        fi
    else
        log_error "Failed to destroy container $container_id"
        exit 1
    fi
}

# --- Enhanced Cleanup ---
cleanup() {
    # Cleanup logic would go here if needed
    log_info "Cleanup completed"
}

main "$@"