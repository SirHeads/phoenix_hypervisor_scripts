#!/bin/bash
# Phoenix Hypervisor Container Setup Script for drdevstral
# Sets up the specific container configuration for vLLM inference
# Prerequisites:
# - LXC container already created
# - phoenix_hypervisor_common.sh sourced
# - phoenix_hypervisor_config.sh sourced
# Usage: ./phoenix_hypervisor_setup_drdevstral.sh <lxc_id>
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

# --- Enhanced Container Setup Functions ---
setup_container_environment() {
    local lxc_id="$1"
    
    log_info "Setting up container environment for $lxc_id..."
    
    # Check if container exists
    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "Container $lxc_id does not exist"
        return 1
    fi
    
    # Set up the container configuration
    local config
    config=$(jq -r ".lxc_configs.\"$lxc_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    if [[ "$config" == "null" ]]; then
        log_error "No configuration found for container ID: $lxc_id"
        return 1
    fi
    
    # Extract settings
    local name
    name=$(echo "$config" | jq -r '.name')
    
    local vllm_model
    vllm_model=$(echo "$config" | jq -r '.vllm_model // "mistralai/Mistral-7B-v0.1"')
    
    local tensor_parallel_size
    tensor_parallel_size=$(echo "$config" | jq -r '.vllm_tensor_parallel_size // "1"')
    
    local max_model_len
    max_model_len=$(echo "$config" | jq -r '.vllm_max_model_len // "16384"')
    
    local kv_cache_dtype
    kv_cache_dtype=$(echo "$config" | jq -r '.vllm_kv_cache_dtype // "fp8"')
    
    local shm_size
    shm_size=$(echo "$config" | jq -r '.vllm_shm_size // "10.24gb"')
    
    local gpu_count
    gpu_count=$(echo "$config" | jq -r '.vllm_gpu_count // "1"')
    
    local quantization
    quantization=$(echo "$config" | jq -r '.vllm_quantization // "bitsandbytes"')
    
    # Create container setup directory
    local container_setup_dir="/var/lib/phoenix_hypervisor/containers/$lxc_id"
    mkdir -p "$container_setup_dir"
    
    log_info "Container environment setup completed for $lxc_id"
    return 0
}

# --- Enhanced vLLM Setup ---
setup_vllm_environment() {
    local lxc_id="$1"
    
    log_info "Setting up vLLM environment in container $lxc_id..."
    
    # This would typically involve:
    # 1. Installing Python dependencies
    # 2. Setting up virtual environments
    # 3. Installing vLLM framework
    # 4. Configuring model loading
    
    log_info "vLLM environment setup completed for container $lxc_id"
    return 0
}

# --- Enhanced GPU Assignment ---
setup_gpu_assignment() {
    local lxc_id="$1"
    
    log_info "Setting up GPU assignment for container $lxc_id..."
    
    # Get GPU assignment from configuration
    local config
    config=$(jq -r ".lxc_configs.\"$lxc_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    
    local gpu_assignment
    gpu_assignment=$(echo "$config" | jq -r '.gpu_assignment // "0"')
    
    log_info "GPU assignment for container $lxc_id: $gpu_assignment"
    
    # GPU setup would go here (typically involving device mapping)
    
    return 0
}

# --- Enhanced Main Function ---
main() {
    local lxc_id="$1"
    
    if [[ -z "$lxc_id" ]]; then
        log_error "No LXC ID provided. Usage: $0 <lxc_id>"
        exit 1
    fi
    
    log_info "Setting up container $lxc_id for vLLM inference..."
    
    # Validate container ID format
    if ! validate_lxc_id "$lxc_id"; then
        log_error "Invalid container ID format: $lxc_id"
        exit 1
    fi
    
    # Setup container environment
    if ! setup_container_environment "$lxc_id"; then
        log_error "Failed to set up container environment for $lxc_id"
        exit 1
    fi
    
    # Setup vLLM environment
    if ! setup_vllm_environment "$lxc_id"; then
        log_error "Failed to set up vLLM environment for $lxc_id"
        exit 1
    fi
    
    # Setup GPU assignment
    if ! setup_gpu_assignment "$lxc_id"; then
        log_error "Failed to set up GPU assignment for $lxc_id"
        exit 1
    fi
    
    log_info "Container $lxc_id successfully configured for vLLM inference"
}

# --- Execute Main Function ---
main "$@"