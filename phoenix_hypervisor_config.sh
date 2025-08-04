#!/bin/bash
# phoenix_hypervisor_config.sh
# Configuration variables for the Hypervisor Prep Scripts project.
# Version: 1.6.3 (Removed balloon_min_mb for compatibility)
# Author: Assistant

########################################################
# Configuration Section
########################################################

# --- Core Paths ---
# Directory for storing marker files to track script completion
export HYPERVISOR_MARKER_DIR="/var/log/phoenix_hypervisor_markers"

# Log file for hypervisor setup and management scripts
export HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/phoenix_hypervisor.log"

# Path to the JSON configuration file for LXC containers
export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"

# --- Proxmox Settings ---
# Storage pool for LXC containers (must exist in Proxmox)
export DEFAULT_LXC_STORAGE_POOL="lxc-disks"

# Default storage size for LXC containers if not specified in config
export DEFAULT_LXC_STORAGE_SIZE_GB="32"

# Default LXC template path
export DEFAULT_LXC_TEMPLATE="/fastData/shared-iso/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# --- LXC Defaults ---
# Default CPU cores for LXC containers
export DEFAULT_LXC_CORES="2"

# Default memory (RAM) in MB for LXC containers
export DEFAULT_LXC_MEMORY_MB="2048"

# Default network configuration (CIDR, Gateway, DNS)
# Format: <IP/CIDR>,<Gateway>,<DNS1;DNS2>
export DEFAULT_LXC_NETWORK_CONFIG="10.0.0.110/24,10.0.0.1,8.8.8.8"

# Default LXC features (e.g., nesting=1,keyctl=1)
export DEFAULT_LXC_FEATURES="nesting=1"

# --- vLLM Defaults ---
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
export DEFAULT_VLLM_GPU_COUNT="all"

########################################################
# Function: check_required_tools
# Description: Ensures essential tools are installed.
# Parameters: None
# Returns: Exits with status 1 if a tool is missing.
########################################################
check_required_tools() {
    local required_tools=("jq" "pct" "pveversion")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "Error: Required tools are missing: ${missing_tools[*]}" >&2
        echo "Please install them (e.g., 'apt-get install jq')."
        exit 1
    fi
}

########################################################
# Function: load_hypervisor_config
# Description: Loads configuration variables and parses LXC configs from JSON.
# Parameters: None
# Inputs: PHOENIX_LXC_CONFIG_FILE
# Outputs: Exports configuration variables and LXC_CONFIGS associative array
# Returns: Exits with status 1 if jq is missing or config file parsing fails
# Example: load_hypervisor_config
########################################################
load_hypervisor_config() {
    # Ensure required tools are present
    check_required_tools

    # --- LXC Container Definitions (Loaded from JSON) ---
    # Associative array to hold LXC configurations, loaded from JSON file
    # JSON file format (stored in /usr/local/etc/phoenix_lxc_configs.json):
    # {
    #   "lxc_configs": {
    #     "<lxc_id>": {
    #       "name": "<container_name>",
    #       "memory_mb": <integer>,
    #       "cores": <integer>,
    #       "template": "<template_path_or_name>",
    #       "storage_pool": "<pve_storage_pool>",
    #       "storage_size_gb": <integer>,
    #       "nvidia_pci_ids": "<comma_separated_pci_ids_or_empty>", # Optional/Deprecated
    #       "network_config": "<ip/cidr,gw,dns>",
    #       "features": "<lxc_features_string>",
    #       "gpu_assignment": "<space_separated_gpu_indices_or_empty>",
    #       "vllm_model": "<model_name>",
    #       "vllm_tensor_parallel_size": <integer>,
    #       "vllm_max_model_len": <integer>,
    #       "vllm_kv_cache_dtype": "<dtype>",
    #       "vllm_shm_size": "<size>",
    #       "vllm_gpu_count": "<count>"
    #     },
    #     ...
    #   }
    # }
    # Internal representation format after loading:
    # LXC_CONFIGS[lxc_id]="name|memory_mb|cores|template|storage_pool|storage_size_gb|nvidia_pci_ids|network_config|features|gpu_assignment|vllm_model|vllm_tensor_parallel_size|vllm_max_model_len|vllm_kv_cache_dtype|vllm_shm_size|vllm_gpu_count

    declare -gA LXC_CONFIGS

    # --- Use the environment variable for config file path, with a default ---
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/etc/phoenix_lxc_configs.json}"

    # --- LXC Setup Script Mappings ---
    # Associative array mapping LXC ID to its specific setup script
    # Format: [lxc_id]="script_path"
    # Example: [901]="/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh"
    # Constraints:
    # - lxc_id: Must match a key in LXC_CONFIGS
    # - script_path: Valid, executable script file
    declare -gA LXC_SETUP_SCRIPTS

    # Example mapping - populate based on your actual setup scripts
    if [[ -z "${LXC_SETUP_SCRIPTS[901]+isset}" ]]; then
        LXC_SETUP_SCRIPTS[901]="/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh"
    fi

    # Check if the JSON config file exists
    if [[ -f "$config_file" ]]; then
        # Use jq to parse the JSON and populate the LXC_CONFIGS associative array
        if command -v jq &> /dev/null; then
            while IFS='|' read -r id name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count; do
                # Store the parsed values as a delimited string in the associative array
                LXC_CONFIGS["$id"]="$name|$memory_mb|$cores|$template|$storage_pool|$storage_size_gb|$nvidia_pci_ids|$network_config|$features|$gpu_assignment|$vllm_model|$vllm_tensor_parallel_size|$vllm_max_model_len|$vllm_kv_cache_dtype|$vllm_shm_size|$vllm_gpu_count"
            done < <(jq -r '.lxc_configs | to_entries[] |
                "\(.key)|\(.value.name // "")|\(.value.memory_mb // "")|\(.value.cores // "")|\(.value.template // "")|\(.value.storage_pool // "")|\(.value.storage_size_gb // "")|\(.value.nvidia_pci_ids // "")|\(.value.network_config // "")|\(.value.features // "nesting=1")|\(.value.gpu_assignment // "")|\(.value.vllm_model // "")|\(.value.vllm_tensor_parallel_size // "")|\(.value.vllm_max_model_len // "")|\(.value.vllm_kv_cache_dtype // "")|\(.value.vllm_shm_size // "")|\(.value.vllm_gpu_count // "")"' "$config_file")

            if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
                echo "Warning: No LXC configurations found in $config_file" >&2
            fi
        else
            echo "Error: 'jq' is required to parse the JSON configuration file but is not installed." >&2
            exit 1
        fi
    else
        # Fallback logic
        echo "Warning: LXC configuration file not found at $config_file." >&2
        if [[ -f "/etc/phoenix_lxc_configs.json" ]]; then
            echo "Warning: Found config file at fallback location /etc/phoenix_lxc_configs.json. Consider updating PHOENIX_LXC_CONFIG_FILE." >&2
            config_file="/etc/phoenix_lxc_configs.json"
            if command -v jq &> /dev/null; then
                while IFS='|' read -r id name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count; do
                    LXC_CONFIGS["$id"]="$name|$memory_mb|$cores|$template|$storage_pool|$storage_size_gb|$nvidia_pci_ids|$network_config|$features|$gpu_assignment|$vllm_model|$vllm_tensor_parallel_size|$vllm_max_model_len|$vllm_kv_cache_dtype|$vllm_shm_size|$vllm_gpu_count"
                done < <(jq -r '.lxc_configs | to_entries[] |
                    "\(.key)|\(.value.name // "")|\(.value.memory_mb // "")|\(.value.cores // "")|\(.value.template // "")|\(.value.storage_pool // "")|\(.value.storage_size_gb // "")|\(.value.nvidia_pci_ids // "")|\(.value.network_config // "")|\(.value.features // "nesting=1")|\(.value.gpu_assignment // "")|\(.value.vllm_model // "")|\(.value.vllm_tensor_parallel_size // "")|\(.value.vllm_max_model_len // "")|\(.value.vllm_kv_cache_dtype // "")|\(.value.vllm_shm_size // "")|\(.value.vllm_gpu_count // "")"' "$config_file")
                if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
                    echo "Warning: No LXC configurations found in fallback $config_file" >&2
                fi
            else
                echo "Error: 'jq' is required to parse the JSON configuration file but is not installed." >&2
                exit 1
            fi
        else
            echo "Warning: LXC-specific configs will not be loaded." >&2
        fi
    fi
    # Export the populated LXC_CONFIGS array
    export LXC_CONFIGS
    export LXC_SETUP_SCRIPTS

    echo "INFO" "Phoenix Hypervisor configuration variables loaded and validated"
}

# End of phoenix_hypervisor_config.sh