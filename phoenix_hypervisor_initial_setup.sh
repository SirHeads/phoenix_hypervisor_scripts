#!/bin/bash
# Phoenix Hypervisor Initial Setup Script
# Performs initial system setup for the Phoenix Hypervisor environment
# This script should be run before creating any LXC containers
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Root privileges
# - NVIDIA drivers installed on host
# Usage: ./phoenix_hypervisor_initial_setup.sh
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

# --- Enhanced System Prerequisites Check ---
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check if we're running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check Proxmox environment
    if ! command -v pct >/dev/null 2>&1; then
        log_error "Proxmox Container Toolkit (pct) not found. This script requires Proxmox VE."
        exit 1
    fi
    
    # Get Proxmox version
    local proxmox_version
    proxmox_version=$(pveversion | grep -o 'pve-manager/[0-9.]*' | cut -d'/' -f2)
    
    if [[ -z "$proxmox_version" ]]; then
        log_warn "Could not determine Proxmox version"
    else
        log_info "Proxmox VE environment verified (Version: $proxmox_version)"
    fi
    
    # Check for required tools
    local required_tools=("jq" "nvidia-smi" "docker")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Required tool '$tool' not found"
        fi
    done
    
    # Check NVIDIA driver availability
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ')
        log_info "NVIDIA driver version: $driver_version"
        
        # Check if we have at least one GPU available
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
        log_info "Available NVIDIA GPUs: $gpu_count"
    else
        log_warn "NVIDIA driver not found on host system"
    fi
    
    # Check if we have sufficient disk space
    local root_space
    root_space=$(df / | tail -1 | awk '{print $4}')
    log_info "Available space on root partition: ${root_space} KB"
    
    log_info "System requirements check completed"
}

# --- Enhanced Directory Setup ---
setup_directories() {
    log_info "Setting up Phoenix Hypervisor directories..."
    
    # Create main directories
    local dirs=(
        "/usr/local/lib/phoenix_hypervisor"
        "/usr/local/bin/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor/containers"
        "/var/lib/phoenix_hypervisor/markers"
        "/usr/local/etc"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        else
            log_info "Directory already exists: $dir"
        fi
    done
    
    # Set proper permissions
    chmod 755 "/var/lib/phoenix_hypervisor"
    chmod 755 "/var/log/phoenix_hypervisor"
    
    log_info "Directory setup completed"
}

# --- Enhanced NVIDIA Driver Setup ---
setup_nvidia_drivers() {
    log_info "Setting up NVIDIA drivers for host system..."
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "NVIDIA driver not found on host. Please install NVIDIA drivers manually."
        return 1
    fi
    
    # Get current driver version
    local current_driver_version
    current_driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ')
    
    log_info "Host NVIDIA driver version: $current_driver_version"
    
    # Check if we have the required NVIDIA driver version for our system
    local required_driver="580.65.06"
    
    if [[ "$current_driver_version" == "$required_driver" ]]; then
        log_info "Required NVIDIA driver version ($required_driver) is already installed"
    else
        log_warn "Host driver version ($current_driver_version) differs from required version ($required_driver)"
        log_info "Please ensure the correct NVIDIA drivers are installed on the host system"
    fi
    
    # Verify GPU access
    if ! nvidia-smi >/dev/null 2>&1; then
        log_error "Cannot access NVIDIA GPUs. Please verify driver installation."
        return 1
    fi
    
    # Check GPU capabilities
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
    
    if [[ "$gpu_count" -gt 0 ]]; then
        log_info "GPU access verified. Found $gpu_count NVIDIA GPU(s)."
        
        # List GPUs
        local gpu_list
        gpu_list=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | head -5)
        log_info "GPU details:"
        echo "$gpu_list" | while read -r gpu; do
            log_info "  - $gpu"
        done
    else
        log_warn "No NVIDIA GPUs detected on system"
    fi
    
    return 0
}

# --- Enhanced Configuration Setup ---
setup_configurations() {
    log_info "Setting up configuration files..."
    
    # Create default configuration if needed
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_info "Creating default configuration file: $PHOENIX_LXC_CONFIG_FILE"
        
        # Create a basic default configuration with NVIDIA support
        cat > "$PHOENIX_LXC_CONFIG_FILE" << EOF
{
    "\$schema": "./phoenix_lxc_configs.schema.json",
    "nvidia_driver_version": "580.65.06",
    "nvidia_repo_url": "http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/",
    "lxc_configs": {
        "901": {
            "name": "drdevstral",
            "memory_mb": 32768,
            "cores": 8,
            "template": "/fastData/shared-iso/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst",
            "storage_pool": "lxc-disks",
            "storage_size_gb": "64",
            "network_config": "10.0.0.111/24,10.0.0.1,8.8.8.8",
            "features": "nesting=1,keyctl=1",
            "vllm_model": "mistralai/Devstral-7B-v0.5",
            "setup_script": "/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh",
            "gpu_assignment": "0"
        }
    }
}
EOF
        log_info "Default configuration created"
    fi
    
    # Create schema if needed
    if [[ ! -f "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" ]]; then
        log_info "Creating default schema file: $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
        
        cat > "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" << EOF
{
    "\$schema": "https://json-schema.org/draft/2020-12/schema",
    "\$id": "https://example.com/phoenix_lxc_configs.schema.json",
    "title": "Phoenix LXC Configuration",
    "description": "Configuration schema for Phoenix Hypervisor LXC containers",
    "type": "object",
    "properties": {
        "nvidia_driver_version": {
            "type": "string",
            "description": "NVIDIA driver version to use"
        },
        "nvidia_repo_url": {
            "type": "string",
            "format": "uri",
            "description": "NVIDIA repository URL for driver installation"
        },
        "lxc_configs": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "memory_mb": {"type": "integer"},
                    "cores": {"type": "integer"},
                    "template": {"type": "string"},
                    "storage_pool": {"type": "string"},
                    "storage_size_gb": {"type": "string"},
                    "network_config": {"type": "string"},
                    "features": {"type": "string"},
                    "vllm_model": {"type": "string"},
                    "setup_script": {"type": "string"},
                    "gpu_assignment": {"type": "string"}
                },
                "required": ["name", "memory_mb", "cores", "template", "storage_pool", "network_config"]
            }
        }
    },
    "required": ["lxc_configs"]
}
EOF
        log_info "Default schema created"
    fi
    
    # Create token file if needed
    if [[ ! -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        log_info "Creating empty token file: $PHOENIX_HF_TOKEN_FILE"
        touch "$PHOENIX_HF_TOKEN_FILE"
        chmod 600 "$PHOENIX_HF_TOKEN_FILE"
        log_info "Token file created with restricted permissions"
    fi
    
    log_info "Configuration setup completed"
}

# --- Enhanced Service Setup ---
setup_services() {
    log_info "Setting up service configurations..."
    
    # Create systemd service files if needed
    local service_dirs=("/etc/systemd/system" "/lib/systemd/system")
    
    for dir in "${service_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Service directory found: $dir"
            break
        fi
    done
    
    # Create marker file to indicate setup completion
    mkdir -p "$HYPERVISOR_MARKER_DIR"
    touch "$HYPERVISOR_MARKER"
    
    log_info "Service setup completed"
}

# --- Enhanced Cleanup and Validation ---
validate_setup() {
    log_info "Validating setup..."
    
    # Check that all required directories exist
    local required_dirs=(
        "/usr/local/lib/phoenix_hypervisor"
        "/usr/local/bin/phoenix_hypervisor" 
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/usr/local/etc"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Required directory missing: $dir"
            return 1
        fi
    done
    
    # Check configuration files exist
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file missing: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    
    if [[ ! -f "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" ]]; then
        log_error "Schema file missing: $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
        return 1
    fi
    
    # Validate configuration JSON
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    
    log_info "Setup validation completed successfully"
}

# --- Enhanced Main Function ---
main() {
    log_info "Starting Phoenix Hypervisor initial setup..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR INITIAL SETUP"
    echo "==============================================="
    echo ""
    
    # Verify prerequisites
    check_system_requirements
    
    # Setup directories
    setup_directories
    
    # Setup NVIDIA drivers (if available)
    if command -v nvidia-smi >/dev/null 2>&1; then
        log_info "NVIDIA driver detected, setting up GPU support..."
        setup_nvidia_drivers || { log_error "NVIDIA driver setup failed"; exit 1; }
    else
        log_info "No NVIDIA drivers detected, continuing with CPU-only setup"
    fi
    
    # Setup configurations
    setup_configurations
    
    # Setup services
    setup_services
    
    # Validate setup
    validate_setup
    
    # Show completion summary
    echo ""
    echo "==============================================="
    echo "SETUP COMPLETED SUCCESSFULLY"
    echo "==============================================="
    echo "Directories created:"
    echo "- /usr/local/lib/phoenix_hypervisor"
    echo "- /usr/local/bin/phoenix_hypervisor"
    echo "- /var/lib/phoenix_hypervisor"
    echo "- /var/log/phoenix_hypervisor"
    echo "- /usr/local/etc"
    echo ""
    echo "Configuration files created:"
    echo "- $PHOENIX_LXC_CONFIG_FILE"
    echo "- $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    echo "- $PHOENIX_HF_TOKEN_FILE"
    echo ""
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "NVIDIA GPU support enabled"
    else
        echo "NVIDIA GPU support: Not detected on system"
    fi
    echo "==============================================="
    
    log_info "Phoenix Hypervisor initial setup completed successfully"
}

main "$@"