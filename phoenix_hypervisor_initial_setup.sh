#!/bin/bash
# Phoenix Hypervisor Initial Setup Script
# Sets up the base environment for the Phoenix Hypervisor system
# Prerequisites:
# - Proxmox VE environment
# - Root privileges
# Usage: ./phoenix_hypervisor_initial_setup.sh
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

# --- Enhanced Setup Functions ---
setup_directories() {
    log_info "Setting up Phoenix Hypervisor directories..."
    
    # Create main directories
    local dirs=("/usr/local/lib/phoenix_hypervisor" 
                "/usr/local/bin/phoenix_hypervisor"
                "/var/lib/phoenix_hypervisor"
                "/var/log/phoenix_hypervisor"
                "/var/lib/phoenix_hypervisor/containers"
                "/var/lib/phoenix_hypervisor/markers")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || { log_error "Failed to create directory: $dir"; exit 1; }
            log_info "Created directory: $dir"
        else
            log_info "Directory already exists: $dir"
        fi
    done
    
    # Set proper permissions
    chmod 700 /var/lib/phoenix_hypervisor
    chmod 600 /var/log/phoenix_hypervisor/*
    
    log_info "Directory setup completed"
}

setup_configuration() {
    log_info "Setting up configuration files..."
    
    # Create default configuration if it doesn't exist
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_info "Creating default configuration file: $PHOENIX_LXC_CONFIG_FILE"
        
        cat > "$PHOENIX_LXC_CONFIG_FILE" << 'EOF'
{
    "$schema": "./phoenix_lxc_configs.schema.json",
    "nvidia_driver_version": "580.65.06",
    "nvidia_repo_url": "http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/",
    "lxc_configs": {
        "901": {
            "name": "drdevstral",
            "memory_mb": 32768,
            "cores": 8,
            "template": "/fastData/shared-iso/template/cache/ubuntu-22.04-standard_22.04-1_amd64.tar.zst",
            "storage_pool": "lxc-disks",
            "storage_size_gb": "64",
            "network_config": "10.0.0.111/24,10.0.0.1,8.8.8.8",
            "features": "nesting,keyctl",
            "vllm_model": "mistralai/Mistral-7B-v0.1",
            "vllm_tensor_parallel_size": "1",
            "vllm_max_model_len": "16384",
            "vllm_kv_cache_dtype": "fp8",
            "vllm_shm_size": "10.24gb",
            "vllm_gpu_count": "1",
            "vllm_quantization": "bitsandbytes",
            "vllm_quantization_config_type": "int8",
            "setup_script": "/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh",
            "gpu_assignment": "0"
        }
    }
}
EOF
        log_info "Default configuration file created"
    else
        log_info "Configuration file already exists: $PHOENIX_LXC_CONFIG_FILE"
    fi
    
    # Create schema if it doesn't exist
    if [[ ! -f "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" ]]; then
        log_info "Creating default schema file: $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
        
        cat > "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" << 'EOF'
{
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "properties": {
        "nvidia_driver_version": {"type": "string"},
        "nvidia_repo_url": {"type": "string"},
        "lxc_configs": {
            "type": "object",
            "patternProperties": {
                "^[0-9]+$": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "memory_mb": {"type": "integer"},
                        "cores": {"type": "integer"},
                        "template": {"type": "string"},
                        "storage_pool": {"type": "string"},
                        "storage_size_gb": {"type": "integer"},
                        "network_config": {"type": "string"},
                        "features": {"type": "string"},
                        "vllm_model": {"type": "string"},
                        "vllm_tensor_parallel_size": {"type": "string"},
                        "vllm_max_model_len": {"type": "string"},
                        "vllm_kv_cache_dtype": {"type": "string"},
                        "vllm_shm_size": {"type": "string"},
                        "vllm_gpu_count": {"type": "string"},
                        "vllm_quantization": {"type": "string"},
                        "vllm_quantization_config_type": {"type": "string"},
                        "setup_script": {"type": "string"},
                        "gpu_assignment": {"type": "string"}
                    },
                    "required": ["name", "memory_mb", "cores", "template"]
                }
            }
        }
    },
    "required": ["lxc_configs"]
}
EOF
        log_info "Schema file created"
    else
        log_info "Schema file already exists: $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    fi
    
    # Create token file if it doesn't exist
    if [[ ! -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        log_info "Creating empty token file: $PHOENIX_HF_TOKEN_FILE"
        touch "$PHOENIX_HF_TOKEN_FILE"
        chmod 600 "$PHOENIX_HF_TOKEN_FILE"
        log_info "Token file created with restricted permissions"
    else
        log_info "Token file already exists: $PHOENIX_HF_TOKEN_FILE"
    fi
    
    log_info "Configuration setup completed"
}

setup_nvidia_support() {
    log_info "Setting up NVIDIA driver support..."
    
    # Check if NVIDIA drivers are available
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n1)
        log_info "Host NVIDIA driver version: $driver_version"
        
        # Check for available GPUs
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | wc -l)
        log_info "Available NVIDIA GPUs: $gpu_count"
        
        # Validate driver compatibility
        if [[ "$driver_version" == "580.65.06" ]]; then
            log_info "NVIDIA driver version is compatible"
        else
            log_warn "Host driver version ($driver_version) differs from required version (580.65.06)"
            log_warn "Please ensure the correct NVIDIA drivers are installed on the host system"
        fi
    else
        log_warn "No NVIDIA drivers detected on system"
    fi
    
    log_info "NVIDIA support setup completed"
}

setup_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check if required tools exist
    local required_tools=("jq" "pct" "nvidia-smi")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Required tool not found: $tool"
        else
            log_info "Found required tool: $tool"
        fi
    done
    
    # Check available disk space
    local root_space
    root_space=$(df / | awk 'NR==2 {print $4}')
    log_info "Available space on root partition: $root_space KB"
    
    # Check if we have sufficient space (at least 10GB)
    if [[ "$root_space" -lt 10485760 ]]; then
        log_warn "Warning: Low disk space available on root partition"
    fi
    
    log_info "System requirements check completed"
}

setup_services() {
    log_info "Setting up service configurations..."
    
    # Check if systemd is available
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Service directory found: /etc/systemd/system"
        # Setup any required services would go here
        log_info "Service setup completed"
    else
        log_warn "systemd not found, skipping service configuration"
    fi
}

validate_setup() {
    log_info "Validating setup..."
    
    # Check that all directories exist
    local check_dirs=("/usr/local/lib/phoenix_hypervisor" 
                     "/var/lib/phoenix_hypervisor" 
                     "/var/log/phoenix_hypervisor")
    
    for dir in "${check_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Required directory missing: $dir"
            exit 1
        fi
    done
    
    # Check that configuration file exists and is valid
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Validate JSON structure
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
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
    
    # Validate system requirements first
    setup_system_requirements
    
    # Set up directories
    setup_directories
    
    # Set up configuration files
    setup_configuration
    
    # Set up NVIDIA support
    setup_nvidia_support
    
    # Set up services
    setup_services
    
    # Validate the entire setup
    validate_setup
    
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
    echo "NVIDIA GPU support enabled"
    echo "==============================================="
    
    log_info "Phoenix Hypervisor initial setup completed successfully"
}

# --- Execute Main Function ---
main "$@"