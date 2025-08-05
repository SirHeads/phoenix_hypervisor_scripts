#!/bin/bash
# Configuration variables for Phoenix Hypervisor scripts
# Version: 1.7.3
# Author: Assistant

# --- Enhanced User Experience ---
echo "Loading Phoenix Hypervisor configuration..."
echo "============================================"

# --- Core Configuration Paths ---
# Default configuration file path
export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"
export PHOENIX_LXC_CONFIG_SCHEMA_FILE="/usr/local/etc/phoenix_lxc_configs.schema.json"

# Default token file location
export PHOENIX_HF_TOKEN_FILE="/usr/local/etc/phoenix_hf_token.conf"

# Marker directory for idempotency tracking
export HYPERVISOR_MARKER_DIR="/var/lib/phoenix_hypervisor/markers"
export HYPERVISOR_MARKER="$HYPERVISOR_MARKER_DIR/hypervisor_setup_complete"

# Default log file location
export HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/hypervisor.log"

# --- Enhanced Proxmox Settings ---
# Storage pool for LXC containers (must exist in Proxmox)
export DEFAULT_LXC_STORAGE_POOL="lxc-disks"
# Default storage size for LXC containers if not specified in config
export DEFAULT_LXC_STORAGE_SIZE_GB="32"
# Default LXC template path
export DEFAULT_LXC_TEMPLATE="/fastData/shared-iso/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
# ZFS pool for LXC storage
export PHOENIX_ZFS_LXC_POOL="quickOS/lxc-disks"

# --- Enhanced LXC Defaults ---
# Default CPU cores for LXC containers
export DEFAULT_LXC_CORES="2"
# Default memory (RAM) in MB for LXC containers
export DEFAULT_LXC_MEMORY_MB="2048"
# Default network configuration (CIDR, Gateway, DNS)
export DEFAULT_LXC_NETWORK_CONFIG="10.0.0.110/24,10.0.0.1,8.8.8.8"
# Default LXC features (e.g., nesting=1,keyctl=1)
export DEFAULT_LXC_FEATURES="nesting=1"

# --- Enhanced vLLM Defaults ---
# Default vLLM model to load
export DEFAULT_VLLM_MODEL="NousResearch/Hermes-3-Llama-3.1-8B"
# Default tensor parallel size for vLLM
export DEFAULT_VLLM_TENSOR_PARALLEL_SIZE="1"
# Default maximum model length for vLLM
export DEFAULT_VLLM_MAX_MODEL_LEN="20000"
# Default KV cache data type for vLLM
export DEFAULT_VLLM_KV_CACHE_DTYPE="fp8"
# Default shared memory size for vLLM Docker container
export DEFAULT_VLLM_SHM_SIZE="10.24gb"
# Default GPU count for vLLM Docker container
export DEFAULT_VLLM_GPU_COUNT="1"
# Default vLLM API port
export DEFAULT_VLLM_API_PORT="8000"
# Default vLLM quantization
export DEFAULT_VLLM_QUANTIZATION="none"
# Default vLLM quantization config type
export DEFAULT_VLLM_QUANTIZATION_CONFIG_TYPE="none"

# --- Enhanced GPU Passthrough Configuration ---
# Associative array defining GPU assignments for LXCs
# Key: LXC ID, Value: Comma-separated GPU indices (e.g., "0", "1", "0,1")
# Example:
# declare -gA PHOENIX_GPU_ASSIGNMENTS=( ["901"]="0" ["902"]="1" )
# Use declare -gA to ensure it's a global associative array accessible by other scripts
declare -gA PHOENIX_GPU_ASSIGNMENTS

# Initialize with the assignment for LXC 901
# This should be customized for your specific setup
PHOENIX_GPU_ASSIGNMENTS["901"]="0"

# Rollback on failure flag
export ROLLBACK_ON_FAILURE=true

# --- Enhanced Security Settings ---
# Default container security settings
export DEFAULT_CONTAINER_SECURITY="unconfined"
export DEFAULT_CONTAINER_NESTING="1"

# --- Enhanced Debugging Settings ---
# Enable verbose logging for development
export DEBUG_MODE="${DEBUG_MODE:-false}"

# --- Configuration Validation ---
echo "Validating configuration settings..."
echo "------------------------------------"

# Validate required directories exist
if [[ ! -d "/usr/local/etc" ]]; then
    echo "Warning: /usr/local/etc directory not found. Creating it..."
    mkdir -p "/usr/local/etc"
fi

if [[ ! -d "/var/log/phoenix_hypervisor" ]]; then
    echo "Creating log directory..."
    mkdir -p "/var/log/phoenix_hypervisor"
fi

# Validate configuration file exists (optional)
if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
    echo ""
    echo "Warning: Configuration file not found at $PHOENIX_LXC_CONFIG_FILE"
    echo "This is expected if you're setting up the system for the first time."
    echo "You'll need to create this file with your container specifications."
    echo ""
fi

# Validate token file location
if [[ ! -d "$(dirname "$PHOENIX_HF_TOKEN_FILE")" ]]; then
    mkdir -p "$(dirname "$PHOENIX_HF_TOKEN_FILE")"
fi

echo "Configuration validation complete."
echo ""

# --- Enhanced Function to Load Configuration ---
# This function can be called by scripts that source this file
load_config() {
    echo "Loading configuration variables..."
    
    # --- SMB Configuration ---
    # SMB User (for Samba shares)
    SMB_USER="${SMB_USER:-heads}"
    export SMB_USER
    
    # --- Check if we're in debug mode ---
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "Debug mode enabled - configuration will be verbose"
        echo "Configuration variables loaded:"
        echo "  PHOENIX_LXC_CONFIG_FILE: $PHOENIX_LXC_CONFIG_FILE"
        echo "  PHOENIX_HF_TOKEN_FILE: $PHOENIX_HF_TOKEN_FILE"
        echo "  HYPERVISOR_MARKER_DIR: $HYPERVISOR_MARKER_DIR"
        echo "  DEFAULT_LXC_STORAGE_POOL: $DEFAULT_LXC_STORAGE_POOL"
        echo "  DEFAULT_LXC_CORES: $DEFAULT_LXC_CORES"
        echo "  DEFAULT_LXC_MEMORY_MB: $DEFAULT_LXC_MEMORY_MB"
        echo ""
    fi
    
    echo "Configuration variables loaded and validated"
}

# Call load_config if not already called by orchestrator
# This makes the file standalone testable
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    load_config
fi

echo "Phoenix Hypervisor configuration loaded successfully."
echo ""