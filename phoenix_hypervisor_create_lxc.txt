#!/bin/bash
# Phoenix Hypervisor Create LXC Script
# Creates LXC containers based on the configuration in phoenix_lxc_configs.json.
# Prerequisites:
# - Proxmox host configured
# - JSON config file available at $PHOENIX_LXC_CONFIG_FILE
# - jq installed (checked by config script)
# - Root privileges
# Usage: ./phoenix_hypervisor_create_lxc.sh <lxc_id>
# Example: ./phoenix_hypervisor_create_lxc.sh 901

set -euo pipefail # Exit on error, undefined vars, pipe failures

# --- Source common functions ---
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }

# Check root early
check_root

# --- Source configuration ---
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# --- Script Initialization ---
# Load config AFTER sourcing common and config scripts to ensure LXC_CONFIGS is populated
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

# Get LXC ID from command-line argument
LXC_ID="$1"
if [[ -z "$LXC_ID" ]]; then
    log "ERROR" "LXC ID not provided. Usage: $0 <lxc_id>"
    exit 1
fi

log "INFO" "Starting phoenix_hypervisor_create_lxc.sh for LXC $LXC_ID"

# Define the marker file path for this script's completion status
marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${LXC_ID}_created.marker"

# Skip if the creation has already been completed (marker file exists)
if is_script_completed "$marker_file"; then
    log "INFO" "LXC $LXC_ID already created (marker found). Skipping creation."
    exit 0
fi

# --- Load LXC Configuration from Associative Array ---
# Access the configuration string for the specific LXC ID
config_string="${LXC_CONFIGS[$LXC_ID]}"

if [[ -z "$config_string" ]]; then
    log "ERROR" "Configuration for LXC ID $LXC_ID not found in LXC_CONFIGS array. Ensure it exists in $PHOENIX_LXC_CONFIG_FILE."
    exit 1
fi

# --- Parse the configuration string using IFS ---
# The order of fields in the string (from jq in phoenix_hypervisor_config.sh):
# name|memory_mb|cores|template|storage_pool|storage_size_gb|nvidia_pci_ids|network_config|features|gpu_assignment|vllm_model|vllm_tensor_parallel_size|vllm_max_model_len|vllm_kv_cache_dtype|vllm_shm_size|vllm_gpu_count
IFS='|' read -r \
    LXC_NAME \
    LXC_MEMORY_MB \
    LXC_CORES \
    LXC_TEMPLATE \
    LXC_STORAGE_POOL \
    LXC_STORAGE_SIZE_GB \
    LXC_NVIDIA_PCI_IDS \
    LXC_NETWORK_CONFIG \
    LXC_FEATURES \
    LXC_GPU_ASSIGNMENT \
    VLLM_MODEL \
    VLLM_TENSOR_PARALLEL_SIZE \
    VLLM_MAX_MODEL_LEN \
    VLLM_KV_CACHE_DTYPE \
    VLLM_SHM_SIZE \
    VLLM_GPU_COUNT \
    <<< "$config_string"

# --- Parse Network Configuration ---
# Expected format in LXC_NETWORK_CONFIG: "IP/CIDR,GATEWAY,DNS"
# e.g., "10.0.0.100/24,10.0.0.1,8.8.8.8"
IFS=',' read -r LXC_IP_CIDR LXC_GATEWAY LXC_DNS <<< "$LXC_NETWORK_CONFIG"

# Use defaults if values are empty from config
LXC_NAME="${LXC_NAME:-lxc-$LXC_ID}"
LXC_MEMORY_MB="${LXC_MEMORY_MB:-$DEFAULT_LXC_MEMORY_MB}"
LXC_CORES="${LXC_CORES:-$DEFAULT_LXC_CORES}"
LXC_TEMPLATE="${LXC_TEMPLATE:-$DEFAULT_LXC_TEMPLATE}"
LXC_STORAGE_POOL="${LXC_STORAGE_POOL:-$DEFAULT_LXC_STORAGE_POOL}"
LXC_STORAGE_SIZE_GB="${LXC_STORAGE_SIZE_GB:-$DEFAULT_LXC_STORAGE_SIZE_GB}"
LXC_NETWORK_CONFIG="${LXC_NETWORK_CONFIG:-$DEFAULT_LXC_NETWORK_CONFIG}"
LXC_FEATURES="${LXC_FEATURES:-$DEFAULT_LXC_FEATURES}"
LXC_IP_CIDR="${LXC_IP_CIDR:-$(echo "$DEFAULT_LXC_NETWORK_CONFIG" | cut -d',' -f1)}"
LXC_GATEWAY="${LXC_GATEWAY:-$(echo "$DEFAULT_LXC_NETWORK_CONFIG" | cut -d',' -f2)}"

# Log the parsed configuration for debugging
log "INFO" "Parsed configuration for LXC $LXC_ID: name=$LXC_NAME, memory_mb=$LXC_MEMORY_MB, cores=$LXC_CORES, template=$LXC_TEMPLATE, storage_pool=$LXC_STORAGE_POOL, storage_size_gb=$LXC_STORAGE_SIZE_GB, network_config=$LXC_NETWORK_CONFIG, features=$LXC_FEATURES, gpu_assignment=$LXC_GPU_ASSIGNMENT"

# --- Validate critical parameters ---
if [[ -z "$LXC_IP_CIDR" ]] || [[ -z "$LXC_GATEWAY" ]]; then
    log "ERROR" "Invalid network configuration for LXC $LXC_ID: IP/CIDR or Gateway missing."
    exit 1
fi

if [[ ! -f "$LXC_TEMPLATE" ]]; then
    log "ERROR" "LXC template file not found: $LXC_TEMPLATE"
    exit 1
fi

# --- Create the LXC Container ---
log "INFO" "Creating LXC container $LXC_ID ($LXC_NAME)..."

# Construct the pct create command
create_cmd="pct create $LXC_ID '$LXC_TEMPLATE' \
  --storage '$LXC_STORAGE_POOL' \
  --memory $LXC_MEMORY_MB \
  --cores $LXC_CORES \
  --hostname '$LXC_NAME' \
  --net0 name=eth0,bridge=vmbr0,ip=$LXC_IP_CIDR,gw=$LXC_GATEWAY \
  --features '$LXC_FEATURES' \
  --rootfs $LXC_STORAGE_POOL:$LXC_STORAGE_SIZE_GB \
  --password \$(echo \$LXC_DEFAULT_ROOT_PASSWORD | base64 -d) \
  --start 1"

log "DEBUG" "Executing: $create_cmd"
# Execute the command
if eval "$create_cmd"; then
    log "INFO" "LXC container $LXC_ID created successfully."
    mark_script_completed "$marker_file"
else
    log "ERROR" "Failed to create LXC container $LXC_ID."
    exit 1
fi

log "INFO" "Completed phoenix_hypervisor_create_lxc.sh for LXC $LXC_ID."
exit 0