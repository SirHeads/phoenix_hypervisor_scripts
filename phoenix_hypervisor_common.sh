#!/bin/bash
# Phoenix Hypervisor Common Functions
# Provides shared functions and configuration loading for the Phoenix Hypervisor environment
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Root privileges for some operations
# Usage: source phoenix_hypervisor_common.sh
# Version: 1.7.4
# Author: Assistant

set -euo pipefail

# Source configuration first
if [[ -f "/usr/local/bin/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_config.sh
else
    echo "Configuration file not found: /usr/local/bin/phoenix_hypervisor_config.sh"
    exit 1
fi

# Source common functions
if [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
else
    echo "Common functions file not found: /usr/local/bin/phoenix_hypervisor_common.sh"
    exit 1
fi

# --- Enhanced Logging Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# --- Enhanced System Prerequisites Check ---
check_system_requirements() {
    local checks_passed=0
    local checks_failed=0
    
    # Check if running as root (optional for some operations)
    if [[ $EUID -eq 0 ]]; then
        log_info "Running with root privileges"
        ((checks_passed++))
    else
        log_warn "Not running with root privileges (may affect some operations)"
        ((checks_failed++))
    fi
    
    # Check Proxmox environment
    if command -v pct >/dev/null 2>&1; then
        log_info "Proxmox LXC tools available"
        ((checks_passed++))
    else
        log_error "Proxmox LXC tools not found"
        ((checks_failed++))
    fi
    
    # Check required tools
    local required_tools=("jq" "nvidia-smi")
    
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_info "Required tool available: $tool"
            ((checks_passed++))
        else
            log_warn "Required tool not found: $tool"
            ((checks_failed++))
        fi
    done
    
    # Check configuration file accessibility
    if [[ -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_info "Configuration file accessible"
        ((checks_passed++))
    else
        log_error "Cannot access configuration file: $PHOENIX_LXC_CONFIG_FILE"
        ((checks_failed++))
    fi
    
    # Check NVIDIA driver if available
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            local gpu_count
            gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
            log_info "NVIDIA driver available with $gpu_count GPU(s)"
            ((checks_passed++))
        else
            log_warn "NVIDIA driver found but cannot access GPUs"
            ((checks_failed++))
        fi
    else
        log_warn "NVIDIA driver not installed on host system"
        ((checks_failed++))
    fi
    
    log_info "System checks: $checks_passed passed, $checks_failed failed"
    
    if [[ $checks_failed -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# --- Enhanced Configuration Loading ---
load_configuration() {
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    local schema_file="${PHOENIX_LXC_SCHEMA_FILE:-/usr/local/etc/phoenix_lxc_configs.schema.json}"
    
    # Validate configuration file exists
    if [[ ! -f "$config_file" ]]; then
        log_warn "Configuration file not found: $config_file"
        return 1
    fi
    
    # Validate configuration is valid JSON
    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $config_file"
        return 1
    fi
    
    # Set global variables from config
    export PHOENIX_LXC_CONFIG_FILE="$config_file"
    export PHOENIX_LXC_SCHEMA_FILE="$schema_file"
    
    # Load NVIDIA settings if available
    if command -v jq >/dev/null 2>&1; then
        local nvidia_driver_version
        nvidia_driver_version=$(jq -r '.nvidia_driver_version // "580.65.06"' "$config_file" 2>/dev/null || echo "580.65.06")
        export NVIDIA_DRIVER_VERSION="$nvidia_driver_version"
        
        local nvidia_repo_url
        nvidia_repo_url=$(jq -r '.nvidia_repo_url // "http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/"' "$config_file" 2>/dev/null || echo "http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/")
        export NVIDIA_REPO_URL="$nvidia_repo_url"
    else
        log_warn "jq not available, using default NVIDIA settings"
        export NVIDIA_DRIVER_VERSION="580.65.06"
        export NVIDIA_REPO_URL="http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/"
    fi
    
    log_info "Configuration loaded successfully"
    return 0
}

# --- Enhanced Environment Setup ---
setup_environment() {
    log_info "Setting up environment..."
    
    # Set up paths for Phoenix hypervisor
    export PHOENIX_HYPERVISOR_HOME="/usr/local/lib/phoenix_hypervisor"
    export PHOENIX_HYPERVISOR_BIN="/usr/local/bin/phoenix_hypervisor"
    
    # Create necessary directories
    local dirs=("$PHOENIX_HYPERVISOR_HOME" "$PHOENIX_HYPERVISOR_BIN" "/var/lib/phoenix_hypervisor/containers")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
        fi
    done
    
    # Set proper permissions
    chmod 755 "$PHOENIX_HYPERVISOR_HOME"
    chmod 755 "$PHOENIX_HYPERVISOR_BIN"
    
    log_info "Environment setup completed successfully"
}

# --- Enhanced Logging Setup ---
setup_logging() {
    # Ensure log directory exists
    local log_dir="/var/log/phoenix_hypervisor"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
    
    # Set up log file permissions
    chmod 755 "$log_dir"
    
    log_info "Logging system initialized"
}

# --- Enhanced Container Validation ---
validate_container_config() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    
    # Check if container exists in configuration
    if command -v jq >/dev/null 2>&1; then
        local config_exists
        config_exists=$(jq -e ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "false")
        
        if [[ "$config_exists" == "false" ]]; then
            log_warn "No configuration found for container ID: $container_id"
            return 1
        fi
    else
        log_warn "jq not available, skipping detailed validation"
        return 0
    fi
    
    return 0
}

# --- Enhanced GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    
    # Get GPU assignment from configuration file
    if command -v jq >/dev/null 2>&1; then
        local gpu_assignment
        gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "none")
        echo "$gpu_assignment"
    else
        log_warn "jq not available, returning default GPU assignment"
        echo "none"
    fi
}

# --- Enhanced Configuration Validation ---
validate_configuration() {
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    
    # Validate JSON structure
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    
    # Validate NVIDIA settings
    if command -v jq >/dev/null 2>&1; then
        local nvidia_driver_version
        nvidia_driver_version=$(jq -r '.nvidia_driver_version' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "null")
        
        if [[ "$nvidia_driver_version" == "null" ]] || [[ -z "$nvidia_driver_version" ]]; then
            log_warn "NVIDIA driver version not specified in configuration"
        else
            log_info "Using NVIDIA driver version: $nvidia_driver_version"
        fi
        
        local nvidia_repo_url
        nvidia_repo_url=$(jq -r '.nvidia_repo_url' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "null")
        
        if [[ "$nvidia_repo_url" == "null" ]] || [[ -z "$nvidia_repo_url" ]]; then
            log_warn "NVIDIA repository URL not specified in configuration"
        else
            log_info "Using NVIDIA repository: $nvidia_repo_url"
        fi
    fi
    
    # Validate container configurations
    if command -v jq >/dev/null 2>&1; then
        local container_count
        container_count=$(jq '(.lxc_configs | keys | length)' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "0")
        
        if [[ "$container_count" -gt 0 ]]; then
            log_info "Configuration contains $container_count container(s)"
        else
            log_warn "No containers configured in configuration file"
        fi
    fi
    
    return 0
}

# --- Enhanced Utility Functions ---
prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

# --- Enhanced Error Handling ---
handle_error() {
    local error_code=$1
    local error_message="$2"
    
    log_error "$error_message"
    
    # Cleanup temporary files if any
    cleanup_temp_files
    
    exit $error_code
}

# --- Enhanced Version Compatibility Check ---
check_version_compatibility() {
    local required_version="1.7.4"
    local current_version="1.7.4"
    
    if [[ "$current_version" == "$required_version" ]]; then
        log_info "Version compatibility check passed: $current_version"
        return 0
    else
        log_warn "Version mismatch: expected $required_version, found $current_version"
        return 1
    fi
}

# --- Enhanced Container Status Functions ---
get_container_status() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        return 1
    fi
    
    # Check if container exists in Proxmox
    if pct status "$container_id" >/dev/null 2>&1; then
        local status
        status=$(pct status "$container_id" | grep -E '^status:' | awk '{print $2}')
        echo "$status"
        return 0
    else
        echo "not_found"
        return 1
    fi
}

# --- Enhanced System Information Display ---
show_system_info() {
    log_info "System Information:"
    log_info "-------------------"
    
    # Show Proxmox version if available
    if command -v pct >/dev/null 2>&1; then
        log_info "Proxmox LXC tools: Available"
    else
        log_info "Proxmox LXC tools: Not found"
    fi
    
    # Show NVIDIA status if available
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ')
        log_info "NVIDIA Driver: $driver_version"
        
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
        log_info "GPU Count: $gpu_count"
    else
        log_info "NVIDIA Driver: Not installed"
    fi
    
    # Show configuration file info
    if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_info "Configuration File: $PHOENIX_LXC_CONFIG_FILE"
    else
        log_info "Configuration File: Not found"
    fi
    
    log_info "-------------------"
}

# --- Enhanced LXC ID Validation ---
validate_lxc_id() {
    local container_id="$1"
    
    if [[ -z "$container_id" ]]; then
        return 1
    fi
    
    # Check if it's a valid numeric ID
    if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Check if it's within reasonable range for Proxmox
    if [[ "$container_id" -lt 100 ]] || [[ "$container_id" -gt 999999 ]]; then
        return 1
    fi
    
    return 0
}

# --- Enhanced Temporary File Cleanup ---
cleanup_temp_files() {
    local temp_dir="${1:-/tmp/phoenix_hypervisor}"
    
    if [[ -d "$temp_dir" ]]; then
        log_info "Cleaning up temporary files in $temp_dir"
        rm -rf "$temp_dir" 2>/dev/null || true
    fi
}

# --- Enhanced Container ID Generation ---
generate_container_id() {
    # Generate a unique container ID based on timestamp
    echo "lxc-$(date +%s%N | cut -b1-12)"
}

# --- Enhanced Main Initialization ---
initialize_common_functions() {
    # Setup logging first
    setup_logging
    
    # Load configuration
    if ! load_configuration; then
        log_error "Failed to load configuration"
        return 1
    fi
    
    # Setup environment
    setup_environment
    
    # Validate system requirements
    if ! check_system_requirements; then
        log_warn "System requirements check failed, but continuing..."
    fi
    
    # Validate configuration
    if ! validate_configuration; then
        log_warn "Configuration validation failed, but continuing..."
    fi
    
    # Show system info
    show_system_info
    
    # Check version compatibility
    check_version_compatibility
    
    log_info "Common functions initialized successfully"
    return 0
}

# --- Execute Initialization if Called Directly ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # This script is being executed directly, not sourced
    log_info "Initializing Phoenix Hypervisor common functions..."
    initialize_common_functions "$@"
fi