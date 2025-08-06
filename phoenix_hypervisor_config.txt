#!/bin/bash
# Configuration variables for Phoenix Hypervisor scripts
# Version: 1.7.4
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

# --- Enhanced NVIDIA Configuration ---
# NVIDIA driver version to use across all containers
export NVIDIA_DRIVER_VERSION="580.65.06"

# NVIDIA repository URL for driver installation
export NVIDIA_REPO_URL="http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/"

# Default GPU assignment for containers (empty = no GPUs, "0" = GPU 0, "0,1" = both GPUs)
export DEFAULT_GPU_ASSIGNMENT=""

# --- Enhanced GPU Passthrough Configuration ---
# Associative array defining GPU assignments for LXCs
# Key: LXC ID, Value: Comma-separated GPU indices (e.g., "0", "1", "0,1")
declare -gA PHOENIX_GPU_ASSIGNMENTS

# Initialize with the assignment for LXC 901
# This should be customized for your specific setup
PHOENIX_GPU_ASSIGNMENTS["901"]="0"

# Rollback on failure flag
export ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-false}"

# --- Enhanced Security Settings ---
# Default container security settings
export DEFAULT_CONTAINER_SECURITY="unconfined"
export DEFAULT_CONTAINER_NESTING="1"

# --- Enhanced Debugging Settings ---
# Enable verbose logging for development
export DEBUG_MODE="${DEBUG_MODE:-false}"

# --- Configuration Validation and Setup ---
echo "Validating configuration settings..."
echo "------------------------------------"

# Validate that required paths exist
if [[ ! -d "/usr/local/etc" ]]; then
    mkdir -p "/usr/local/etc"
fi

if [[ ! -d "/var/log/phoenix_hypervisor" ]]; then
    mkdir -p "/var/log/phoenix_hypervisor"
fi

if [[ ! -d "/var/lib/phoenix_hypervisor" ]]; then
    mkdir -p "/var/lib/phoenix_hypervisor"
fi

# Validate configuration files exist or create defaults
if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
    echo "Creating default configuration file: $PHOENIX_LXC_CONFIG_FILE"
    
    # Create a basic default configuration with NVIDIA settings
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
            "vllm_model": "mistralai/Devstral-Small-2507-Q5_K_M.gguf",
            "vllm_tensor_parallel_size": "1",
            "vllm_max_model_len": "16384",
            "vllm_kv_cache_dtype": "fp8",
            "vllm_shm_size": "10.24gb",
            "vllm_gpu_count": "1",
            "vllm_quantization": "bitsandbytes",
            "vllm_quantization_config_type": "int8",
            "vllm_api_port": 8000,
            "setup_script": "/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh",
            "gpu_assignment": "0"
        }
    }
}
EOF
    echo "Default configuration created."
fi

# Validate schema file exists
if [[ ! -f "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" ]]; then
    echo "Creating default schema file: $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    
    # Create a basic schema with NVIDIA support
    cat > "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" << EOF
{
    "\$schema": "https://json-schema.org/draft/2020-12/schema",
    "\$id": "https://example.com/phoenix_lxc_configs.schema.json",
    "title": "Phoenix Hypervisor LXC Configuration",
    "description": "Schema for defining LXC containers and their configurations for the Phoenix Hypervisor",
    "type": "object",
    "properties": {
        "\$schema": {
            "type": "string",
            "description": "Optional reference to this schema file"
        },
        "nvidia_driver_version": {
            "type": "string",
            "description": "NVIDIA driver version to use for all containers",
            "default": "580.65.06"
        },
        "nvidia_repo_url": {
            "type": "string",
            "description": "NVIDIA repository URL for driver installation",
            "default": "http://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/"
        },
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
                        "storage_size_gb": {"type": ["integer", "string"]},
                        "network_config": {"type": "string"},
                        "features": {"type": "string"},
                        "gpu_assignment": {
                            "type": "string",
                            "description": "GPU assignment for the container (e.g., '0', '1', or '0,1')",
                            "pattern": "^(0|1|2|3|0,1|0,2|0,3|1,2|1,3|2,3|0,1,2|0,1,3|0,2,3|1,2,3|0,1,2,3)$"
                        },
                        "setup_script": {"type": "string"}
                    },
                    "required": ["name", "memory_mb", "cores", "template", "storage_pool", "storage_size_gb", "network_config", "features", "vllm_api_port"],
                    "additionalProperties": false
                }
            },
            "additionalProperties": false
        }
    },
    "required": ["lxc_configs"],
    "additionalProperties": false
}
EOF
    echo "Default schema created."
fi

echo "Configuration validation completed successfully"